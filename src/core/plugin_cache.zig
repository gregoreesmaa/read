const std = @import("std");
const simd = @import("hot");
const core_options = @import("core_options");

// Differential-twin stub (AGENTS.md §7): with -Dplugin_stub=true every body
// below early-returns a trivial value (same decl names and signatures, so
// all callers in src/main.zig and src/layout/viewport.zig keep compiling —
// the twin links and runs, resolving every fence to its non-plugin path).
// With the option off each guard folds away at comptime and the real body
// compiles exactly as before (ship __TEXT byte-identical, proven by the
// size gate). Types (Renderer, JobState, PluginJob, MAX_PLUGIN_JOBS) are
// identical in both modes: they cost zero bytes and keep call-site codegen
// stable.

/// Content-driven async plugin pipeline, stage 1: pure-Zig cache state
/// machine (issue #323, PR 1 of 6). No threads, no spawning, no file I/O
/// here — this file only maps fence info tokens to renderers, hashes fence
/// sources for cache filenames, and collects bounded job lists from scanned
/// lines. Readiness (`ready` for cache hit, `rendering` while in flight,
/// `naive` fallback for probe failure, `failed` for terminal render errors)
/// is decided by the launcher flow in a later PR, never here.
/// Zero heap allocations throughout: every function borrows slices of the
/// caller's document/scan buffers or writes into a caller-owned `out` span.

pub const Renderer = enum { mermaid, plantuml };
pub const MAX_PLUGIN_JOBS: usize = 16;

pub fn pluginRendererOf(info_token: []const u8) ?Renderer {
    if (comptime core_options.plugin_stub) return null;
    if (std.mem.eql(u8, info_token, "mermaid")) return .mermaid;
    if (std.mem.eql(u8, info_token, "plantuml")) return .plantuml;
    if (std.mem.eql(u8, info_token, "puml")) return .plantuml;
    return null;
}

pub fn fenceHash(renderer: Renderer, source: []const u8) u64 {
    if (comptime core_options.plugin_stub) return 0;
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
        .plantuml => "plantuml",
    };
}

pub fn cachePath(cache_root: []const u8, renderer: Renderer, hash: u64, out: []u8) ?[]u8 {
    if (comptime core_options.plugin_stub) return null;
    var hex: [16]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x:0>16}", .{hash}) catch return null;
    const name = rendererName(renderer);
    const tail = "/read/plugins/";
    const ext = ".png";
    // "<root>/read/plugins/<name>/<hex>.png"
    const need = cache_root.len + tail.len + name.len + 1 + hex.len + ext.len;
    if (out.len < need) return null;
    var s: usize = 0;
    @memcpy(out[s..][0..cache_root.len], cache_root);
    s += cache_root.len;
    @memcpy(out[s..][0..tail.len], tail);
    s += tail.len;
    @memcpy(out[s..][0..name.len], name);
    s += name.len;
    out[s] = '/';
    s += 1;
    @memcpy(out[s..][0..hex.len], hex[0..]);
    s += hex.len;
    @memcpy(out[s..][0..ext.len], ext);
    s += ext.len;
    return out[0..s];
}

/// Lifecycle of one plugin job. `collectPluginJobs` below always emits
/// `.queued`; the launcher flow (later PR) promotes cache hits to `.ready`,
/// marks in-flight launches `.rendering`, demotes probe failures to `.naive`
/// (plain code-block fallback rendering) and terminal render errors to
/// `.failed`.
pub const JobState = enum { naive, queued, rendering, ready, failed };

/// One render unit: the scan index of its opening fence plus the content
/// hash, renderer, and current state. Later stages re-derive bytes via
/// `fenceSource(doc, lines, job.fence_line)` and rebuild paths via
/// `cachePath(cache_root, job.renderer, job.hash, &buf)` — both thread
/// their buffers at call time, so a job owns no borrowed slices and never
/// aliases the document or root strings: only `fence_line` needs the scan
/// to still match the document. All fields are plain values — no copies,
/// no allocations, no lifetime obligations beyond the index mapping.
pub const PluginJob = struct {
    fence_line: usize,
    hash: u64,
    renderer: Renderer,
    state: JobState,
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
    if (comptime core_options.plugin_stub) return "";
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
    if (comptime core_options.plugin_stub) return false;
    for (lines) |line| {
        if (line.block_type != .code_fence_start) continue;
        if (pluginRendererOf(fenceInfoToken(doc, line)) != null) return true;
    }
    return false;
}

/// Fill `jobs_out` with one `.queued` job per plugin fence, in document
/// order; unknown info tokens are skipped without consuming a slot. Stops
/// at `min(jobs_out.len, MAX_PLUGIN_JOBS)` so callers can never overflow.
/// Returns the number of jobs written. Each job anchors its fence by scan
/// index (`fence_line`); bytes are re-derived later via `fenceSource`.
/// `cache_root` is accepted for call-site uniformity but intentionally
/// unused: file-exists/readiness checks are deliberately NOT done here —
/// the launcher flow threads the root into `cachePath` itself and sets
/// `ready`/`rendering`/`naive`/`failed`.
pub fn collectPluginJobs(doc: []const u8, lines: []const simd.Line, cache_root: []const u8, jobs_out: []PluginJob) usize {
    if (comptime core_options.plugin_stub) return 0;
    _ = cache_root;
    const cap = @min(jobs_out.len, MAX_PLUGIN_JOBS);
    var n: usize = 0;
    for (lines, 0..) |line, i| {
        if (n >= cap) break;
        if (line.block_type != .code_fence_start) continue;
        const renderer = pluginRendererOf(fenceInfoToken(doc, line)) orelse continue;
        const source = fenceSource(doc, lines, i);
        jobs_out[n] = .{
            .fence_line = i,
            .hash = fenceHash(renderer, source),
            .renderer = renderer,
            .state = .queued,
        };
        n += 1;
    }
    return n;
}

test "plugin: mermaid info token maps, others do not" {
    // Twin builds stub every body above: pin nothing there.
    if (comptime core_options.plugin_stub) return;
    try std.testing.expectEqual(Renderer.mermaid, pluginRendererOf("mermaid").?);
    try std.testing.expect(pluginRendererOf("d2") == null); // later PR
    try std.testing.expectEqual(Renderer.plantuml, pluginRendererOf("plantuml").?);
    try std.testing.expectEqual(Renderer.plantuml, pluginRendererOf("puml").?);
    try std.testing.expect(pluginRendererOf("foobar") == null);
    try std.testing.expect(pluginRendererOf("") == null);
}

test "plugin: hash golden vector + cache path shape" {
    if (comptime core_options.plugin_stub) return;
    const h = fenceHash(.mermaid, "flowchart TD\n    A-->B\n");
    try std.testing.expectEqual(@as(u64, 0xec4fa197df3351dc), h);
    var buf: [256]u8 = undefined;
    const p = cachePath("/tmp/C", .mermaid, h, &buf).?;
    try std.testing.expectEqualStrings("/tmp/C/read/plugins/mermaid/ec4fa197df3351dc.png", p);
}

test "plugin: collect finds fences, caps at 16, skips unknown" {
    if (comptime core_options.plugin_stub) return;
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

test "plugin: collect stops at 16 with 17 fences, unknown tokens skip slots" {
    if (comptime core_options.plugin_stub) return;
    // 17 mermaid fences with two unknown-token (rust) fences interleaved
    // before the 6th and 13th mermaid fence; each fence spans 3 scan lines.
    var doc_buf: [4096]u8 = undefined;
    var doc_len: usize = 0;
    var k: usize = 0;
    while (k < 17) : (k += 1) {
        if (k == 5 or k == 12) {
            const u = "```rust\nlet x = 1;\n```\n";
            @memcpy(doc_buf[doc_len..][0..u.len], u);
            doc_len += u.len;
        }
        const f = "```mermaid\nA-->B\n```\n";
        @memcpy(doc_buf[doc_len..][0..f.len], f);
        doc_len += f.len;
    }
    const doc = doc_buf[0..doc_len];
    var lines: [128]simd.Line = undefined;
    var fence: simd.FenceState = .{};
    const n = simd.scanLines(doc, &lines, &fence);
    try std.testing.expect(hasPluginFences(doc, lines[0..n]));
    var jobs: [MAX_PLUGIN_JOBS]PluginJob = undefined;
    const nj = collectPluginJobs(doc, lines[0..n], "/tmp/C", &jobs);
    try std.testing.expectEqual(@as(usize, MAX_PLUGIN_JOBS), nj);
    // First fence anchors scan line 0; anchors strictly increase.
    try std.testing.expectEqual(@as(usize, 0), jobs[0].fence_line);
    var i: usize = 0;
    while (i + 1 < nj) : (i += 1) {
        try std.testing.expect(jobs[i].fence_line < jobs[i + 1].fence_line);
    }
    // The rust fence at scan line 15 consumed no slot: the 6th mermaid job
    // still anchors its opener at line 18, with bytes re-derivable via
    // fenceSource and matching the stored hash.
    try std.testing.expectEqual(@as(usize, 18), jobs[5].fence_line);
    try std.testing.expectEqualStrings("A-->B", fenceSource(doc, lines[0..n], jobs[5].fence_line));
    try std.testing.expectEqual(
        fenceHash(.mermaid, fenceSource(doc, lines[0..n], jobs[5].fence_line)),
        jobs[5].hash,
    );
    for (jobs[0..nj]) |job| {
        try std.testing.expectEqual(JobState.queued, job.state);
        try std.testing.expectEqual(Renderer.mermaid, job.renderer);
    }
}

test "plugin: plantuml info tokens map + cache path shape" {
    try std.testing.expectEqual(Renderer.plantuml, pluginRendererOf("plantuml").?);
    try std.testing.expectEqual(Renderer.plantuml, pluginRendererOf("puml").?);
    var buf: [256]u8 = undefined;
    const h = fenceHash(.plantuml, "@startuml\na -> b\n@enduml\n");
    const p = cachePath("/tmp/C", .plantuml, h, &buf).?;
    var expect_buf: [128]u8 = undefined;
    const expect = try std.fmt.bufPrint(&expect_buf, "/tmp/C/read/plugins/plantuml/{x:0>16}.png", .{h});
    try std.testing.expectEqualStrings(expect, p);
}
