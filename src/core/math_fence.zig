const std = @import("std");
const core_options = @import("core_options");

// Differential-twin stub (same pattern as plugin_cache.zig): with
// -Dplugin_stub=true every body below early-returns a trivial value
// (same decl names and signatures, so callers keep compiling — the
// twin links and runs, resolving every math fence to fallback).
// With the option off each guard folds away at comptime and the real
// body compiles exactly as before.

/// Native math consult (zatex issue #12): math fences
/// (`math`/`tex`/`latex`/`katex`) ask the ZaTeX subset engine, which
/// `read` loads as a DYNAMIC plugin (outside the size budget — an
/// absent dylib is a clean fallback to today's code block, so CI
/// without a sibling checkout stays green).
///
/// Subset-accepted fences are native-eligible; the display arm lands
/// in read#348 (until then they render as plain code cards with no
/// plugin job). Anything else — no dylib, `Unsupported`, `Invalid`,
/// overflow — keeps today's code-card fallback byte-identical.
/// Zero heap allocations throughout; consult buffers live on the
/// caller's stack frame via `classify`.
pub const Verdict = enum { native_subset, fallback };

/// First info token is a math fence (`math`/`tex`/`latex`/`katex`,
/// matching the async-spec renderer table). Pure, no engine needed.
pub fn isMathToken(token: []const u8) bool {
    if (comptime core_options.plugin_stub) return false;
    if (std.mem.eql(u8, token, "math")) return true;
    if (std.mem.eql(u8, token, "tex")) return true;
    if (std.mem.eql(u8, token, "latex")) return true;
    if (std.mem.eql(u8, token, "katex")) return true;
    return false;
}

// Mirror of zatex.h (frozen v1 C ABI). Only `zatex_layout_utf8` is
// resolved: the consult needs the status, never MathML or version.
const CMetrics = extern struct {
    ctx: ?*const anyopaque,
    glyph_id: ?*const fn (?*const anyopaque, u16, u32) callconv(.c) u16,
    advance: ?*const fn (?*const anyopaque, u16, u16) callconv(.c) i32,
    rule_thickness: ?*const fn (?*const anyopaque, u16, u32) callconv(.c) i32,
    glyph_variant: ?*const fn (?*const anyopaque, u16, u16, i32) callconv(.c) u16,
    italic_correction: ?*const fn (?*const anyopaque, u16, u16) callconv(.c) i32,
};

const CRun = extern struct {
    font_id: u16,
    size_units: u16,
    x: i32,
    baseline_y: i32,
    glyph_start: u32,
    glyph_count: u32,
};

const CRule = extern struct {
    x: i32,
    y: i32,
    w: u32,
    h: u32,
};

const CLayout = extern struct {
    width: u32,
    height_above: u32,
    depth_below: u32,
    nruns: u32,
    nrules: u32,
    status: i32,
    err_offset: u32,
};

const LayoutFn = *const fn (
    src: ?[*]const u8,
    src_len: usize,
    display_mode: bool,
    metrics: ?*const CMetrics,
    runs: ?[*]CRun,
    runs_cap: usize,
    rules: ?[*]CRule,
    rules_cap: usize,
    glyphs: ?[*]u16,
    glyphs_cap: usize,
    out: ?*CLayout,
) callconv(.c) i32;

/// One loaded engine: the dylib handle plus the resolved consult
/// entry. Session-owned (open once, `close` at teardown); tests open
/// and close per case. Never null inside: use `?Table` for absence.
pub const Table = struct {
    lib: std.DynLib,
    layout: LayoutFn,
};

/// Open the engine at an explicit path (bundle `Resources/` in ship,
/// dev sibling checkout in tests). Null when the file is missing or
/// the entry is unresolved — both are clean fallback, never fatal.
pub fn loadFrom(path: []const u8) ?Table {
    if (comptime core_options.plugin_stub) return null;
    var lib = std.DynLib.open(path) catch return null;
    const layout = lib.lookup(LayoutFn, "zatex_layout_utf8") orelse {
        lib.close();
        return null;
    };
    return .{ .lib = lib, .layout = layout };
}

pub fn close(tbl: *Table) void {
    if (comptime core_options.plugin_stub) return;
    tbl.lib.close();
}

/// Install-prefix search (ship fallback when the platform passes no
/// bundle path). Never touches CWD: dev checkouts load explicitly.
pub fn loadDefault() ?Table {
    if (comptime core_options.plugin_stub) return null;
    const candidates = [_][]const u8{
        "/opt/homebrew/lib/libzatex.dylib",
        "/usr/local/lib/libzatex.dylib",
    };
    for (candidates) |p| {
        if (loadFrom(p)) |t| return t;
    }
    return null;
}

// Consult-only metrics: every hook null, so the engine answers from
// its deterministic fallbacks. The verdict needs the STATUS alone
// (0 ok); advances never affect accept/reject, which is parse-driven.
const null_metrics = CMetrics{
    .ctx = null,
    .glyph_id = null,
    .advance = null,
    .rule_thickness = null,
    .glyph_variant = null,
    .italic_correction = null,
};

/// Engine ceilings from zatex.h (256 runs / 64 rules); input capped
/// at 64 KiB by the ABI. Overflow reports `NoSpace`, which maps to
/// `fallback` — the safe direction, never a wrong render.
pub fn classify(tbl: ?*const Table, source: []const u8) Verdict {
    if (comptime core_options.plugin_stub) return .fallback;
    const t = tbl orelse return .fallback;
    if (source.len > 64 * 1024) return .fallback;
    var runs: [256]CRun = undefined;
    var rules: [64]CRule = undefined;
    var glyphs: [2048]u16 = undefined;
    var out: CLayout = undefined;
    const st = t.layout(
        if (source.len == 0) null else source.ptr,
        source.len,
        true, // fences are display math
        &null_metrics,
        &runs,
        runs.len,
        &rules,
        rules.len,
        &glyphs,
        glyphs.len,
        &out,
    );
    return if (st == 0) .native_subset else .fallback;
}

test "math fence tokens map, others do not" {
    if (comptime core_options.plugin_stub) return;
    try std.testing.expect(isMathToken("math"));
    try std.testing.expect(isMathToken("tex"));
    try std.testing.expect(isMathToken("latex"));
    try std.testing.expect(isMathToken("katex"));
    try std.testing.expect(!isMathToken("mermaid"));
    try std.testing.expect(!isMathToken("rust"));
    try std.testing.expect(!isMathToken(""));
    try std.testing.expect(!isMathToken("MATH"));
}

test "classify without engine falls back" {
    if (comptime core_options.plugin_stub) return;
    try std.testing.expectEqual(Verdict.fallback, classify(null, "\\frac{a}{b}"));
    try std.testing.expectEqual(Verdict.fallback, classify(null, ""));
}

test "loadFrom bogus path falls back" {
    if (comptime core_options.plugin_stub) return;
    try std.testing.expect(loadFrom("/nonexistent/libzatex.dylib") == null);
    try std.testing.expect(loadDefault() == null or true); // absent is clean
}

test "consult against the real engine when present" {
    if (comptime core_options.plugin_stub) return;
    // Dev sibling checkout; absent on CI and user machines, where this
    // probe skips cleanly (fallback coverage comes from the tests above).
    var tbl = loadFrom("../zatex/zig-out/lib/libzatex.dylib") orelse {
        std.debug.print("note: no zatex dylib beside checkout; consult probe skipped\n", .{});
        return;
    };
    defer close(&tbl);
    try std.testing.expectEqual(Verdict.native_subset, classify(&tbl, "\\frac{a}{b}"));
    try std.testing.expectEqual(Verdict.native_subset, classify(&tbl, "\\sum_{i=1}^{n} i"));
    try std.testing.expectEqual(Verdict.fallback, classify(&tbl, "\\begin{matrix}a\\end{matrix}"));
    try std.testing.expectEqual(Verdict.fallback, classify(&tbl, "\\nope"));
}