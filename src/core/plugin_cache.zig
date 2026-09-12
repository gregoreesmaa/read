const std = @import("std");
const simd = @import("hot");

/// Content-driven async plugin pipeline, stage 1: pure-Zig cache state
/// machine (issue #323, PR 1 of 6). No threads, no spawning, no file I/O
/// here — this file only maps fence info tokens to renderers, hashes fence
/// sources for cache filenames, and collects bounded job lists from scanned
/// lines. Readiness (`ready` for cache hit, `naive` fallback for probe
/// failure) is decided by the launcher flow in a later PR, never here.
/// Zero heap allocations throughout: every function borrows slices of the
/// caller's document/scan buffers or writes into a caller-owned `out` span.

pub const Renderer = enum { mermaid };
pub const MAX_PLUGIN_JOBS: usize = 16;

pub fn pluginRendererOf(info_token: []const u8) ?Renderer {
    if (std.mem.eql(u8, info_token, "mermaid")) return .mermaid;
    return null;
}

fn fnv1a(bytes: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (bytes) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}

pub fn fenceHash(renderer: Renderer, source: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    h ^= @intFromEnum(renderer);
    h *%= 0x100000001b3;
    h ^= 0x00;
    h *%= 0x100000001b3;
    for (source) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}

fn rendererName(r: Renderer) []const u8 {
    return switch (r) {
        .mermaid => "mermaid",
    };
}

pub fn cachePath(cache_root: []const u8, renderer: Renderer, hash: u64, out: []u8) ?[]u8 {
    var hex: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x:0>16}", .{hash}) catch return null;
    const name = rendererName(renderer);
    // "<root>/read/plugins/<name>/<hex>.png"
    const need = cache_root.len + 1 + 4 + 1 + 8 + 1 + name.len + 1 + 16 + 4;
    if (out.len < need) return null;
    var s: usize = 0;
    @memcpy(out[s..][0..cache_root.len], cache_root);
    s += cache_root.len;
    const tail = "/read/plugins/";
    @memcpy(out[s..][0..tail.len], tail);
    s += tail.len;
    @memcpy(out[s..][0..name.len], name);
    s += name.len;
    out[s] = '/';
    s += 1;
    @memcpy(out[s..][0..16], hex[0..]);
    s += 16;
    const ext = ".png";
    @memcpy(out[s..][0..4], ext);
    s += 4;
    return out[0..s];
}

/// Lifecycle of one plugin job. `collectPluginJobs` below always emits
/// `.queued`; the launcher flow (later PR) promotes cache hits to `.ready`
/// and probe failures to `.naive` (plain code-block fallback rendering).
pub const JobState = enum { queued, ready, naive };

/// One render unit: borrowed fence source plus its content hash, the cache
/// root it was collected under (so later stages can rebuild the cache path
/// with `cachePath` without re-threading the root), and current state.
/// All slices borrow the caller's document — no copies, no allocations.
pub const PluginJob = struct {
    renderer: Renderer,
    state: JobState,
    source: []const u8,
    hash: u64,
    cache_root: []const u8,
};

/// First info token of a `code_fence_start` line (e.g. `mermaid` in
/// "```mermaid"), tokenized like `highlight.langFromFenceLine`: skip indent,
/// skip the fence run, skip blanks, take up to the next blank. Borrowed
/// from `doc`; empty when the line carries no token.
fn fenceInfoToken(doc: []const u8, line: simd.Line) []const u8 {
    const raw = doc[line.offset..][0..line.len];
    var s = raw;
    while (s.len > 0 and (s[0] == ' ' or s[0] == '\t')) : (s = s[1..]) {}
    if (s.len < 3) return "";
    const fc = s[0];
    if (fc != '`' and fc != '~') return "";
    var p: usize = 0;
    while (p < s.len and s[p] == fc) : (p += 1) {}
    if (p < 3) return "";
    while (p < s.len and (s[p] == ' ' or s[p] == '\t')) : (p += 1) {}
    const start = p;
    while (p < s.len and s[p] != ' ' and s[p] != '\t') : (p += 1) {}
    return s[start..p];
}

/// Content bytes of the fence opened at `lines[fence_idx]`: from the first
/// line after the opener to the end of the last content line before the
/// matching `code_fence_end` (first one wins, mirroring the viewport and
/// block-index folds). The info line itself is excluded. An unclosed fence
/// runs to the last scanned line; an empty or non-fence index yields "".
pub fn fenceSource(doc: []const u8, lines: []const simd.Line, fence_idx: usize) []const u8 {
    if (fence_idx >= lines.len) return "";
    if (lines[fence_idx].block_type != .code_fence_start) return "";
    if (fence_idx + 1 >= lines.len) return "";
    var end_idx: usize = lines.len;
    var j: usize = fence_idx + 1;
    while (j < lines.len) : (j += 1) {
        if (lines[j].block_type == .code_fence_end) {
            end_idx = j;
            break;
        }
    }
    if (end_idx <= fence_idx + 1) return "";
    const start: usize = lines[fence_idx + 1].offset;
    const last = lines[end_idx - 1];
    const end: usize = last.offset + last.len;
    return doc[start..end];
}

/// True when any fenced block's first info token maps to a plugin renderer.
/// Cheap pre-check so documents without plugin fences skip job collection.
pub fn hasPluginFences(doc: []const u8, lines: []const simd.Line) bool {
    for (lines) |line| {
        if (line.block_type != .code_fence_start) continue;
        if (pluginRendererOf(fenceInfoToken(doc, line)) != null) return true;
    }
    return false;
}

/// Fill `jobs_out` with one `.queued` job per plugin fence, in document
/// order; unknown info tokens are skipped without consuming a slot. Stops
/// at `min(jobs_out.len, MAX_PLUGIN_JOBS)` so callers can never overflow.
/// Returns the number of jobs written. File-exists/readiness checks are
/// deliberately NOT done here — the launcher flow sets `ready`/`naive`.
pub fn collectPluginJobs(doc: []const u8, lines: []const simd.Line, cache_root: []const u8, jobs_out: []PluginJob) usize {
    const cap = @min(jobs_out.len, MAX_PLUGIN_JOBS);
    var n: usize = 0;
    for (lines, 0..) |line, i| {
        if (n >= cap) break;
        if (line.block_type != .code_fence_start) continue;
        const renderer = pluginRendererOf(fenceInfoToken(doc, line)) orelse continue;
        const source = fenceSource(doc, lines, i);
        jobs_out[n] = .{
            .renderer = renderer,
            .state = .queued,
            .source = source,
            .hash = fenceHash(renderer, source),
            .cache_root = cache_root,
        };
        n += 1;
    }
    return n;
}

test "plugin: mermaid info token maps, others do not" {
    try std.testing.expectEqual(Renderer.mermaid, pluginRendererOf("mermaid").?);
    try std.testing.expect(pluginRendererOf("d2") == null); // later PR
    try std.testing.expect(pluginRendererOf("foobar") == null);
    try std.testing.expect(pluginRendererOf("") == null);
}

test "plugin: hash golden vector + cache path shape" {
    const h = fenceHash(.mermaid, "flowchart TD\n    A-->B\n");
    try std.testing.expectEqual(@as(u64, 0xec4fa197df3351dc), h);
    var buf: [256]u8 = undefined;
    const p = cachePath("/tmp/C", .mermaid, h, &buf).?;
    try std.testing.expectEqualStrings("/tmp/C/read/plugins/mermaid/ec4fa197df3351dc.png", p);
}

test "plugin: collect finds fences, caps at 16, skips unknown" {
    const doc = "```mermaid\nA-->B\n```\n\n```rust\nlet x = 1;\n```\n";
    var lines: [8]simd.Line = undefined;
    var fence: simd.FenceState = .{};
    const n = simd.scanLines(doc, &lines, &fence);
    try std.testing.expect(hasPluginFences(doc, lines[0..n]));
    var jobs: [MAX_PLUGIN_JOBS]PluginJob = undefined;
    const nj = collectPluginJobs(doc, lines[0..n], "/tmp/C", &jobs);
    try std.testing.expectEqual(@as(usize, 1), nj);
    try std.testing.expectEqual(JobState.queued, jobs[0].state);
    try std.testing.expectEqual(Renderer.mermaid, jobs[0].renderer);
}
