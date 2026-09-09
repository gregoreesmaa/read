const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const mmap = @import("core/mmap.zig");
const simd = @import("hot");
const parser = @import("core/parser.zig");
const layout = @import("layout/viewport.zig");
const damage = @import("layout/damage.zig");
const help_overlay = @import("layout/help_overlay.zig");
const remote_policy = @import("core/remote_policy.zig");
const bridge = @import("platform/bridge.zig");

const DEFAULT_DOC =
    \\# Read
    \\
    \\An ultra-minimalist, zero-dependency, microsecond-grade Markdown reader.
    \\
    \\## The Philosophy of Speed
    \\
    \\Computers are exceptionally fast, but modern document readers often hide layers of virtual DOMs, heavy JavaScript bundles, garbage collectors, and complex AST allocations.
    \\
    \\**Read** takes the opposite approach:
    \\
    \\- **Zero-copy memory mapping**: Files are mapped directly into virtual address space via `mmap`.
    \\- **SIMD block classification**: Over 15 million lines per second scanned in hardware vector registers.
    \\- **Virtualized Viewport**: Only lines physically on screen are tokenized and rendered.
    \\- **Zero dependencies**: No Electron, no Qt, no external bloat.
    \\
    \\## Keybindings
    \\
    \\- `j` / `k` : Scroll down / up
    \\- `Space` : Page down
    \\- `t` : Toggle Dark / Light theme
    \\- `q` : Quit
    \\
    \\> "Simplicity is a prerequisite for reliability."
    \\> — Edsger W. Dijkstra
    \\
    \\```zig
    \\// Microsecond SIMD vector classification
    \\const chunk: ByteVec = bytes[i..][0..VecSize].*;
    \\const matches: @Vector(VecSize, bool) = (chunk == nl_vec);
    \\```
    \\
    \\---
    \\Enjoy pure, distraction-free reading.
;

const MAX_LINES = 200_000;
const MAX_COMMANDS = 2048;

pub const MAX_SCROLLABLE_BLOCKS = layout.MAX_SCROLLABLE_BLOCKS;

pub const AppState = struct {
    bytes: []const u8 = "",
    mapped_file: ?mmap.MappedFile = null,
    lines: []simd.Line = &.{},
    line_count: usize = 0,
    window_width: f32 = 1000.0,
    window_height: f32 = 750.0,
    scroll_y: f32 = 0.0,
    max_scroll_y: f32 = 0.0,
    block_scroll_x: [MAX_SCROLLABLE_BLOCKS]f32 = [_]f32{0.0} ** MAX_SCROLLABLE_BLOCKS,
    block_max_scroll_x: [MAX_SCROLLABLE_BLOCKS]f32 = [_]f32{0.0} ** MAX_SCROLLABLE_BLOCKS,
    is_dark_theme: bool = true,
    /// Manual `t` override of the system appearance (#47). Null = following
    /// the system; set by `t`, cleared by the next system change (or launch).
    theme_override: ?bool = null,
    /// Remote-image privacy (issue #52): loads by default per #45, one-key
    /// toggle (`i`) drops all remote content to placeholders.
    remote_images: bool = remote_policy.RemoteEnabledDefault,
};

var g_app: AppState = .{};
// Caller-owned scratch for corrected ordered-list markers, reset per frame.
var g_markers: layout.OrderedMarkerStore = .{};
// Caller-owned scratch for decoded entities, reset per frame.
var g_entities: layout.EntityStore = .{};
// Cross-line reference joint scratch (frame-lived borrows like markers).
var g_joinbuf: [layout.JOIN_BUF_LEN]u8 = undefined;
// Reference definitions scanned once per document load (cold path).
var g_refdefs: [simd.MAX_REF_DEFS]simd.RefDef = undefined;
var g_refdef_count: usize = 0;
// Headless command-stream probe flag (set by --dump-commands under TEST_HOOKS).
var g_dump_commands: bool = false;
// Latched when any remote image is laid out (sticky per document, reset on
// document load): drives the privacy indicator. Set inside gatedImageSize
// so even the cold metrics pass latches it before first paint.
var g_remote_seen: bool = false;

/// Privacy-gated image sizing (issue #52): blocked URLs report 0x0 so
/// layout takes the placeholder path AND — critically — the platform
/// loader is never asked (`platform_get_image_size` is what kicks async
/// loads, so gating here means no fetch is ever started for blocked
/// content). Local content passes straight through.
fn gatedImageSize(url: [*]const u8, url_len: c_int, out_w: *f32, out_h: *f32) callconv(.c) void {
    out_w.* = 0;
    out_h.* = 0;
    if (url_len <= 0) return;
    const slice = url[0..@as(usize, @intCast(url_len))];
    if (remote_policy.isRemoteUrl(slice)) g_remote_seen = true;
    if (remote_policy.blockedByPolicy(slice, g_app.remote_images)) return;
    bridge.platform_get_image_size(url, url_len, out_w, out_h);
}

var g_lines_buffer: [MAX_LINES]simd.Line = undefined;
var g_commands_buffer: [MAX_COMMANDS]layout.DrawCommand = undefined;
var g_scroll_lock: layout.ScrollLockState = .{};
// Gesture conditioning (#31): precise 1:1 untouched, wheel jitter
// quantized. Edge rubber-band overshoot.
var g_gesture_filter: layout.GestureFilter = .{};
var g_edge: layout.EdgeSpring = .{};
// Smooth-scroll animation state: inputs retarget, a 120Hz platform tick
// eases g_app.scroll_y (displayed) toward the target. Anchor jumps and
// resizes snap both so they stay 1:1.
var g_smooth: layout.SmoothScroll = .{};
// Display text scaling (system size class) and the OS Reduce Motion
// switch, both pushed by the platform via onDisplay.
var g_text_scale: layout.TextScale = .{};
var g_reduce_motion: bool = false;

/// Retarget the animated scroll offset and arm the platform tick while the
/// displayed offset is still settling. No-op when already settled.
/// Under Reduce Motion every step lands synchronously instead.
fn retargetScroll(target: f32) void {
    if (g_reduce_motion) {
        snapScroll(target);
        return;
    }
    g_smooth.setTarget(target, g_app.max_scroll_y);
    if (!g_smooth.settled()) bridge.platform_smooth_kick();
}

/// Snap displayed and target offsets together (anchor jumps, resizes,
/// startup offsets): no animation, never diverged.
fn snapScroll(v: f32) void {
    g_smooth.snapTo(v, g_app.max_scroll_y);
    g_app.scroll_y = g_smooth.current;
}

/// Async image natural sizes landed (platform completion): recompute metrics
/// with live sizes (stale checkpoints would misplace content), then absorb
/// the above-viewport height delta so content below stays put instead of
/// jumping. The platform computes the delta from its last drawn rect
/// (same laidOutImageHeight/above-viewport math, pinned by contract tests
/// in controls_test.zig — see the scrollbar mirror precedent). Cold path:
/// one metrics walk; zero allocations. No animation — snapScroll lands it
/// synchronously and clamps to the fresh max.
fn onImagesChanged(delta_above: f32) callconv(.c) void {
    updateDocumentMetrics();
    if (delta_above != 0.0) {
        snapScroll(g_app.scroll_y + delta_above);
    }
}

// 8192 checkpoints x 32-line grid = 262,144 covered lines, matching the
// previous 2048 x 128-line coverage exactly (~98 KB static, zero heap).
const MAX_CHECKPOINTS = 8192;
var g_checkpoints: [MAX_CHECKPOINTS]layout.Checkpoint = undefined;
var g_checkpoint_count: usize = 0;

// Tiny hand-rolled atof: ship builds must not link std.fmt.parseFloat,
// whose float tables cost kilobytes of __TEXT. Handles optional sign,
// integer digits, and an optional fraction; anything else parses as prefix.
fn parseF32(s: []const u8) f32 {
    var i: usize = 0;
    var neg = false;
    if (i < s.len and (s[i] == '+' or s[i] == '-')) {
        neg = s[i] == '-';
        i += 1;
    }
    var val: f32 = 0.0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
        val = val * 10.0 + @as(f32, @floatFromInt(s[i] - '0'));
    }
    if (i < s.len and s[i] == '.') {
        i += 1;
        var place: f32 = 0.1;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {
            val += @as(f32, @floatFromInt(s[i] - '0')) * place;
            place *= 0.1;
        }
    }
    return if (neg) -val else val;
}

fn getTimestampMs() i64 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

fn nowNs() u64 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

// Headless scroll-sweep profiler state (read-test binary only): renders a
// range of scroll offsets in one process — caches stay warm exactly like
// live scrolling — and prints per-offset phase timings. Compiled out of
// ship builds.
var g_sweep_active: bool = false;
var g_sweep_from: f32 = 0.0;
var g_sweep_to: f32 = 0.0;
var g_sweep_step: f32 = 0.0;

// Two-phase drag-back residue test state (read-test binary only): selection A
// then shrink to B, painted incrementally on one bitmap. See --select-drag.
var g_drag_active: bool = false;
// First-paint gate for deferred image decodes (see platform_arm_images):
// image records park until the first frame is committed, then decode.
// Headless one-shot screenshots never arm (deterministic placeholders).
var g_first_paint_done: bool = false;
var g_headless_oneshot: bool = false;
var g_drag_vals: [8]f32 = [_]f32{0.0} ** 8;

fn onScrollTo(scroll_y: f32) callconv(.c) void {
    // Scrollbar drag target from the platform layer. Already clamped there
    // against the synced max, but clamp again: metrics may have moved.
    // Syncs the easing state too so the next tick cannot yank back.
    snapScroll(scroll_y);
}

fn onScroll(delta_x: f32, delta_y: f32, hovered_block_id: c_int, precise: c_int) callconv(.c) void {
    const now_ms = getTimestampMs();
    // Gesture conditioning first: precise deltas pass bit-exact (1:1
    // sync preserved); absorbed wheel jitter feeds the lock a zero so a
    // lifted gesture still resets cleanly, then returns (nothing moved).
    const cond = g_gesture_filter.filter(delta_x, delta_y, precise != 0);
    if (cond.dx == 0.0 and cond.dy == 0.0) {
        _ = g_scroll_lock.processScroll(0.0, 0.0, hovered_block_id, now_ms);
        return;
    }
    const locked = g_scroll_lock.processScroll(cond.dx, cond.dy, hovered_block_id, now_ms);

    if (locked.dy != 0.0) {
        // Routing (precise 1:1 vs eased wheel) lives in
        // MotionPolicy.applyVertical, pinned by strict tests; the full
        // rationale is documented there. Reduce Motion snaps here, so no
        // timer is armed. Sync the displayed offset, then arm the tick
        // while unsettled (snaps settle synchronously, no timer).
        const target_before = g_smooth.target;
        const current_before = g_smooth.current;
        g_smooth = layout.MotionPolicy.applyVertical(
            g_smooth.target,
            g_smooth.current,
            locked.dy,
            precise != 0,
            g_app.max_scroll_y,
            g_reduce_motion,
        );
        // Bound residual becomes rubber-band overshoot (capped, decaying):
        // desired minus actual, in scroll coords. Also arm the tick so the
        // spring decay runs even when the scroll itself already settled.
        const desired = if (precise != 0) current_before - locked.dy else target_before - locked.dy;
        const actual = if (precise != 0) g_smooth.current else g_smooth.target;
        const over = desired - actual;
        if (over != 0.0) {
            g_edge.absorb(over);
            bridge.platform_smooth_kick();
        }
        g_app.scroll_y = g_smooth.current;
        if (!g_smooth.settled()) bridge.platform_smooth_kick();
    }
    if (locked.dx != 0.0 and hovered_block_id >= 0 and hovered_block_id < MAX_SCROLLABLE_BLOCKS) {
        const id: usize = @intCast(hovered_block_id);
        g_app.block_scroll_x[id] = std.math.clamp(
            g_app.block_scroll_x[id] - locked.dx,
            0.0,
            g_app.block_max_scroll_x[id],
        );
    }
}

/// Display-link tick (dt in ms): ease the displayed offset toward the
/// target. Returns 1 while more frames are needed, 0 when settled (the
/// platform parks its timer on 0, so a static screen costs zero wakeups).
fn onTick(dt_ms: f32) callconv(.c) c_int {
    // Reduce Motion parks the timer immediately: nothing should have armed
    // it, but a shrunk max could leave a stale target behind.
    if (g_reduce_motion) {
        snapScroll(g_smooth.target);
        return 0;
    }
    g_smooth.setTarget(g_smooth.target, g_app.max_scroll_y);
    const settled = g_smooth.tick(dt_ms / 1000.0);
    g_app.scroll_y = g_smooth.current;
    // Rubber-band decay keeps the timer alive past scroll settle (full
    // redraws: the translate moves every pixel) and parks exactly at zero.
    if (!g_edge.tick(dt_ms / 1000.0)) {
        bridge.platform_request_redraw();
        return 1;
    }
    return if (settled) 0 else 1;
}

/// Display preferences pushed by the platform (launch, Reduce Motion
/// flips, re-activation): size class and motion flag (issue #315 removed
/// user zoom). Re-wraps via the metrics walk and clamps the offset;
/// enabling Reduce Motion also lands any in-flight glide instantly.
fn onDisplay(category_class: c_int, reduce_motion: c_int) callconv(.c) void {
    g_text_scale.class = @intCast(std.math.clamp(category_class, 0, 4));
    const was_reduced = g_reduce_motion;
    g_reduce_motion = reduce_motion != 0;
    updateDocumentMetrics();
    if (g_reduce_motion and !was_reduced) {
        snapScroll(g_smooth.target);
    } else {
        snapScroll(g_app.scroll_y);
    }
}

fn updateDocumentMetrics() void {
    const vp_config = layout.ViewportConfig{
        .window_width = g_app.window_width,
        .window_height = g_app.window_height,
        .scroll_y = 0.0,
        // Size-class re-wrap here (metrics) and in onDraw below.
        .base_font_size = g_text_scale.effectiveBase(),
        .image_size_fn = gatedImageSize,
        .ref_defs = g_refdefs[0..g_refdef_count],
        .entities = &g_entities,
        .join_buf = &g_joinbuf,
    };
    const total_height = layout.computeDocumentHeightEx(
        g_app.bytes,
        g_app.lines[0..g_app.line_count],
        vp_config,
        &g_checkpoints,
        &g_checkpoint_count,
    );
    g_app.max_scroll_y = @max(0.0, total_height - g_app.window_height + 400.0);
}

/// Overscroll strip (#104): the rubber-band translate uncovers window
/// background the view never paints, so the window must track the APP
/// theme (a `t` override can diverge it from system appearance). Cached:
/// the FFI call (itself cached platform-side) runs only on a real flip.
var g_synced_theme_dark: ?bool = null;
fn syncThemeToPlatform() void {
    if (g_synced_theme_dark == g_app.is_dark_theme) return;
    g_synced_theme_dark = g_app.is_dark_theme;
    bridge.platform_sync_theme(if (g_app.is_dark_theme) 1 else 0);
}

/// System appearance changed (platform effectiveAppearance, #47):
/// override-until-next-system-change — any manual `t` override is dropped
/// and the system value wins. Redraws only on a real flip.
fn onAppearance(is_dark: c_int) callconv(.c) void {
    g_app.theme_override = null;
    const d = is_dark != 0;
    if (g_app.is_dark_theme != d) {
        g_app.is_dark_theme = d;
        bridge.platform_request_redraw();
    }
}

fn onResize(w: c_int, h: c_int) callconv(.c) void {
    g_app.window_width = @floatFromInt(w);
    g_app.window_height = @floatFromInt(h);
    updateDocumentMetrics();
    snapScroll(g_app.scroll_y);
}

// Document directory for resolving relative `.md` links (#46): dirname of
// the currently open file, empty when reading the built-in default doc.
// Fixed buffer, cold path only — zero hot-path allocations.
var g_doc_dir_buf: [2048]u8 = undefined;
var g_doc_dir: []const u8 = "";

fn setDocDir(path: []const u8) void {
    const dir = if (std.mem.lastIndexOfScalar(u8, path, '/')) |li| path[0..li] else "";
    const take = @min(dir.len, g_doc_dir_buf.len);
    @memcpy(g_doc_dir_buf[0..take], dir[0..take]);
    g_doc_dir = g_doc_dir_buf[0..take];
}

pub const LinkKind = enum { anchor, md_file, external };

fn hasSchemePrefix(url: []const u8, scheme: []const u8) bool {
    if (url.len < scheme.len) return false;
    for (scheme, 0..) |c, i| {
        var u = url[i];
        if (u >= 'A' and u <= 'Z') u += 'a' - 'A';
        if (u != c) return false;
    }
    return true;
}

fn endsWithFold(path: []const u8, suffix: []const u8) bool {
    if (path.len < suffix.len) return false;
    const tail = path[path.len - suffix.len ..];
    for (tail, suffix) |a, b| {
        var x = a;
        if (x >= 'A' and x <= 'Z') x += 'a' - 'A';
        if (x != b) return false;
    }
    return true;
}

/// Route a clicked link (#46): `#frag` scrolls in-app, local `.md` files
/// open in the same window, everything else (http(s), other schemes,
/// non-md locals) opens externally. Pure: unit-tested below.
pub fn classifyLink(url: []const u8) LinkKind {
    if (url.len == 0) return .external;
    if (url[0] == '#') return .anchor;
    var path = url;
    if (std.mem.indexOfScalar(u8, path, '#')) |hi| path = path[0..hi];
    if (std.mem.indexOfScalar(u8, path, '?')) |qi| path = path[0..qi];
    // External http(s) behavior is unchanged — even `https://…/x.md`.
    if (hasSchemePrefix(path, "http://") or hasSchemePrefix(path, "https://")) return .external;
    var local = path;
    if (hasSchemePrefix(local, "file://")) local = local["file://".len..];
    // Any other URI scheme (mailto:, ftp:, app:) stays external: only
    // scheme-less paths and file:// URLs open in-app.
    if (std.mem.indexOfScalar(u8, local, ':')) |ci| {
        if (std.mem.indexOfScalar(u8, local, '/')) |si| {
            if (ci < si) return .external;
        } else return .external;
    }
    if (endsWithFold(local, ".md") or endsWithFold(local, ".markdown")) return .md_file;
    return .external;
}

/// Split a same-window `.md` target into filesystem path + `#fragment`
/// (`doc.md#sec` opens the doc, then lands on the section). Strips
/// `file://` and query strings. Pure: unit-tested below.
pub fn splitLinkTarget(url: []const u8) struct { path: []const u8, frag: []const u8 } {
    var rest = url;
    if (hasSchemePrefix(rest, "file://")) rest = rest["file://".len..];
    var frag: []const u8 = "";
    if (std.mem.indexOfScalar(u8, rest, '#')) |hi| {
        frag = rest[hi + 1 ..];
        rest = rest[0..hi];
    }
    if (std.mem.indexOfScalar(u8, rest, '?')) |qi| rest = rest[0..qi];
    return .{ .path = rest, .frag = frag };
}

/// Resolve a link path against the document directory (absolute paths pass
/// through; the kernel resolves ./ and ../). Null on empty/overlong input.
fn resolveDocPath(rel: []const u8, out: []u8) ?[]const u8 {
    if (rel.len == 0 or rel.len > out.len) return null;
    if (rel[0] == '/' or g_doc_dir.len == 0) {
        @memcpy(out[0..rel.len], rel);
        return out[0..rel.len];
    }
    if (g_doc_dir.len + 1 + rel.len > out.len) return null;
    @memcpy(out[0..g_doc_dir.len], g_doc_dir);
    out[g_doc_dir.len] = '/';
    @memcpy(out[g_doc_dir.len + 1 ..][0..rel.len], rel);
    return out[0 .. g_doc_dir.len + 1 + rel.len];
}

/// Document y of the heading targeted by `#fragment` (null = missing).
fn anchorTargetY(frag: []const u8) ?f32 {
    const vp_config = layout.ViewportConfig{
        .window_width = g_app.window_width,
        .window_height = g_app.window_height,
        .scroll_y = 0.0,
        .base_font_size = g_text_scale.effectiveBase(),
        .image_size_fn = gatedImageSize,
        .ref_defs = g_refdefs[0..g_refdef_count],
        .entities = &g_entities,
        .join_buf = &g_joinbuf,
    };
    return layout.anchorScrollY(
        g_app.bytes,
        g_app.lines[0..g_app.line_count],
        vp_config,
        frag,
    );
}

/// Shared measure config for document walks that need live geometry
/// (anchor jumps, outline enumeration): zero scroll, live image sizes.
fn measureConfig() layout.ViewportConfig {
    return layout.ViewportConfig{
        .window_width = g_app.window_width,
        .window_height = g_app.window_height,
        .scroll_y = 0.0,
        .image_size_fn = gatedImageSize,
        .ref_defs = g_refdefs[0..g_refdef_count],
        .entities = &g_entities,
        .join_buf = &g_joinbuf,
    };
}

/// Activate an already-opened mapping: rescan, reset per-document state,
/// re-derive metrics, redraw. Shared by in-place opens (#46), the open
/// panel / drops (#43), and external-change reloads (#44): the swap is
/// open-new-then-replace, so the view is always a complete consistent
/// render — never torn, never a crash on truncation.
fn activateMappedFile(mapped: mmap.MappedFile, reset_scroll: bool) void {
    if (g_app.mapped_file) |*m| m.close();
    g_app.mapped_file = mapped;
    g_app.bytes = mapped.bytes;
    var in_fence: simd.FenceState = .{};
    g_app.line_count = simd.scanLines(g_app.bytes, &g_lines_buffer, &in_fence);
    g_app.lines = g_lines_buffer[0..g_app.line_count];
    g_refdef_count = simd.scanRefDefs(g_app.bytes, g_app.lines, &g_refdefs);
    for (&g_app.block_scroll_x) |*s| s.* = 0.0;
    for (&g_app.block_max_scroll_x) |*s| s.* = 0.0;
    // The old selection belongs to the old text model (#43): drop it so
    // the first redraw of the new document highlights nothing stale.
    bridge.platform_clear_selection();
    // A new document ends any find session (issue #42): matches belong
    // to the old bytes. (External reloads keep the query; see #44.)
    clearFind();
    updateDocumentMetrics();
    if (reset_scroll) snapScroll(0.0) else snapScroll(g_app.scroll_y);
    bridge.platform_request_redraw();
}

/// Open a sibling `.md` document in the same window (#46): swap the mmap,
/// rescan, reset viewport state, optionally land on `#frag`. Any failure
/// (missing file, overlong path) is a silent no-op — never an error dialog.
/// Reports success so callers can re-anchor path-dependent state (#44).
fn openDocumentInPlace(link_path: []const u8, frag: []const u8) bool {
    var abs_buf: [2048]u8 = undefined;
    const abs = resolveDocPath(link_path, &abs_buf) orelse return false;
    const mapped = mmap.MappedFile.open(abs) catch return false;
    // Swap only after the new mapping opens: a missing file keeps the
    // current document untouched.
    setDocDir(abs);
    activateMappedFile(mapped, true);
    if (frag.len > 0) {
        // `doc.md#sec`: land on the section (missing anchor stays on top).
        if (anchorTargetY(frag)) |target| snapScroll(target);
    }
    bridge.platform_request_redraw();
    return true;
}

// Current document's filesystem path for external-change reloads (#44).
// Empty for the built-in doc and stdin spools (unlinked): unwatched.
var g_doc_path_buf: [2048]u8 = undefined;
var g_doc_path: []const u8 = "";

fn setDocPath(path: []const u8) void {
    const take = @min(path.len, g_doc_path_buf.len);
    @memcpy(g_doc_path_buf[0..take], path[0..take]);
    g_doc_path = g_doc_path_buf[0..take];
}

/// (Re)arm the external-change watcher on the current document (#44).
/// No path (built-in/spool) or a vanished path simply disarms: the next
/// successful open re-arms. Cold path only.
fn watchCurrentDocument() void {
    if (g_doc_path.len == 0) {
        bridge.platform_unwatch_file();
        return;
    }
    bridge.platform_watch_file(g_doc_path.ptr, @intCast(g_doc_path.len));
}

/// External file change (platform vnode event, #44): re-arm first
/// (editors replace files, killing the watched fd), then reload with
/// scroll preserved and clamped. A vanished or momentarily unreadable
/// file keeps the old document; the next event converges.
fn onFileChanged() callconv(.c) void {
    watchCurrentDocument();
    if (g_doc_path.len == 0) return;
    const mapped = mmap.MappedFile.open(g_doc_path) catch return;
    activateMappedFile(mapped, false);
}

// Cheat-sheet overlay visibility (issue #54), toggled by `?`.
var g_show_help: bool = false;

// Key dispatch goes through the shared binding table in
// layout/help_overlay.zig: the overlay lists exactly these rows, and the
// switch below is exhaustive over Action (no else), so a new table row
// fails to compile until it is handled here — handler and sheet cannot
// drift apart. Unknown keys are a no-op, as before.

/// Open-file pick from the platform (Cmd+O panel, window or Dock-icon
/// drop, #43): an absolute path, pre-validated (readable Markdown). Swap
/// in place with scroll/selection reset; anything unmappable keeps the
/// current document untouched, never a crash.
fn onOpenFile(path_ptr: [*]const u8, path_len: c_int) callconv(.c) void {
    if (path_len <= 0) return;
    const path = path_ptr[0..@as(usize, @intCast(path_len))];
    if (openDocumentInPlace(path, "")) {
        // The panel/drop hands absolute paths: anchor reloads (#44) here.
        setDocPath(path);
        watchCurrentDocument();
    }
}

/// Find in document (issue #42): case-insensitive matches over the mmap'd
/// source, painted as washes under text runs in the draw pass. State is
/// static BSS (zero allocations on every path, including per-keystroke
/// research); the search itself is the cold pure `layout.findAll`.
const FIND_MAX_MATCHES = 4096;
const FIND_QUERY_MAX = 256;
var g_find_matches: [FIND_MAX_MATCHES]layout.FindMatch = undefined;
var g_find_query: [FIND_QUERY_MAX]u8 = undefined;
var g_find_folded: [FIND_QUERY_MAX]u8 = undefined;
var g_find_count: usize = 0;
var g_find_current: usize = 0;
var g_find_query_len: usize = 0;
// Chase state (issue #42): findOffsetY lands block-exact; when wrapping
// pushes the match below the viewport, up to 4 viewport-steps follow the
// painted wash. painted is set by the highlight pass when the current
// match draws any rect this frame.
var g_find_chase_armed: bool = false;
var g_find_chase_left: u8 = 0;
var g_find_painted: bool = false;

fn pushFindCount() void {
    const shown: c_int = if (g_find_count == 0) 0 else @intCast(g_find_current + 1);
    bridge.platform_find_show_count(shown, @intCast(g_find_count));
}

fn applyFindQuery(raw: []const u8) void {
    // Single-line field: truncate at the first newline, then at the cap.
    var len: usize = @min(raw.len, FIND_QUERY_MAX);
    for (raw[0..len], 0..) |c, i| {
        if (c == '\n' or c == '\r') {
            len = i;
            break;
        }
    }
    @memcpy(g_find_query[0..len], raw[0..len]);
    g_find_query_len = len;
    const folded_len = layout.foldAscii(&g_find_folded, g_find_query[0..len]);
    g_find_count = layout.findAll(g_app.bytes, g_find_folded[0..folded_len], &g_find_matches);
    g_find_current = 0;
    pushFindCount();
    if (g_find_count > 0) scrollFindTo(g_find_current);
}

/// Exact document y for a match offset (issue #42): the same block walk
/// the metrics pass uses, so cycling lands precisely even for wrapped
/// lines and tall blocks. Cold path (per cycle/Enter press only).
fn findMatchY(offset: usize) ?f32 {
    const vp_config = layout.ViewportConfig{
        .window_width = g_app.window_width,
        .window_height = g_app.window_height,
        .scroll_y = 0.0,
        .base_font_size = g_text_scale.effectiveBase(),
        .image_size_fn = gatedImageSize,
        .ref_defs = g_refdefs[0..g_refdef_count],
        .entities = &g_entities,
        .join_buf = &g_joinbuf,
    };
    return layout.findOffsetY(g_app.bytes, g_app.lines, vp_config, offset);
}

fn scrollFindTo(idx: usize) void {
    if (idx >= g_find_count) return;
    if (findMatchY(g_find_matches[idx].start)) |y| {
        // Coarse landing on the match's block top; the draw pass refines
        // (see the chase below) when wrapping puts the match lower.
        g_find_chase_armed = true;
        g_find_chase_left = 4;
        g_find_painted = false;
        snapScroll(@max(0.0, y - g_app.window_height / 3.0));
    }
}

fn onFindQuery(path_ptr: [*]const u8, path_len: c_int) callconv(.c) void {
    if (path_len < 0) return;
    applyFindQuery(path_ptr[0..@as(usize, @intCast(path_len))]);
    bridge.platform_request_redraw();
}

fn onFindNext(prev: c_int) callconv(.c) void {
    if (g_find_count == 0) return;
    g_find_current = if (prev != 0)
        (g_find_current + g_find_count - 1) % g_find_count
    else
        (g_find_current + 1) % g_find_count;
    pushFindCount();
    scrollFindTo(g_find_current);
    bridge.platform_request_redraw();
}

fn onFindClosed() callconv(.c) void {
    clearFind();
}

fn clearFind() void {
    g_find_count = 0;
    g_find_current = 0;
    g_find_query_len = 0;
    g_find_chase_armed = false;
    g_find_chase_left = 0;
    g_find_painted = false;
    bridge.platform_find_hide();
    bridge.platform_request_redraw();
}

/// Find highlight wash (issue #42): intersects one text run's source
/// range with the match list and paints theme washes UNDER the glyphs
/// (call before platform_draw_text). Whole-run matches use the run rect
/// exactly (direction-proof); partial matches measure the byte prefix
/// with the same estimator layout used. Culled runs never reach here,
/// so partial-damage draws stay pixel-identical to full draws.
fn paintFindHighlights(cmd: *const layout.DrawCommand, find_bg: *const layout.Color, find_current: *const layout.Color) void {
    const bytes = g_app.bytes;
    if (bytes.len == 0 or g_find_count == 0) return;
    const base = @intFromPtr(bytes.ptr);
    const rp = @intFromPtr(cmd.text.ptr);
    if (rp < base or rp - base + cmd.text.len > bytes.len) return;
    const rs = rp - base;
    const re = rs + cmd.text.len;
    // Matches are offset-ordered and disjoint: binary search the first
    // one ending past the run start, then walk while overlapping.
    var lo: usize = 0;
    var hi: usize = g_find_count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (g_find_matches[mid].start + g_find_matches[mid].len > rs) hi = mid else lo = mid + 1;
    }
    var mi = lo;
    while (mi < g_find_count and g_find_matches[mi].start < re) : (mi += 1) {
        const m = g_find_matches[mi];
        const ms = @max(m.start, rs);
        const me = @min(m.start + m.len, re);
        if (me <= ms) continue;
        const col = if (mi == g_find_current) find_current.* else find_bg.*;
        if (mi == g_find_current) g_find_painted = true;
        var hx: f32 = cmd.rect.x;
        var hw: f32 = cmd.rect.w;
        if (ms != rs or me != re) {
            hx = cmd.rect.x + layout.measureTextEx(
                cmd.text[0 .. ms - rs],
                cmd.font_size,
                cmd.style.bold,
                cmd.style.italic,
                cmd.style.code,
                cmd.style.heading,
            );
            hw = layout.measureTextEx(
                cmd.text[ms - rs .. me - rs],
                cmd.font_size,
                cmd.style.bold,
                cmd.style.italic,
                cmd.style.code,
                cmd.style.heading,
            );
        }
        // Same wash geometry as mark (2px line-box insets): one coherent
        // highlighter language instead of two competing ones.
        bridge.platform_draw_rect(hx, cmd.rect.y + 2.0, hw, cmd.rect.h - 4.0, col.r, col.g, col.b, col.a);
    }
}

fn onLink(url_ptr: [*]const u8, url_len: c_int) callconv(.c) void {
    if (url_len <= 0) return;
    const url = url_ptr[0..@as(usize, @intCast(url_len))];
    switch (classifyLink(url)) {
        .anchor => {
            // `#fragment` section links scroll in-document; a missing
            // anchor is a no-op, never an error dialog.
            const target = anchorTargetY(url[1..]) orelse return;
            snapScroll(target);
            bridge.platform_request_redraw();
        },
        .md_file => {
            // Relative `.md` links open in the same window, replacing the
            // document (history/back navigation is out of scope).
            const tgt = splitLinkTarget(url);
            if (openDocumentInPlace(tgt.path, tgt.frag)) {
                // Follow the new file for external-change reloads (#44).
                var abs_buf: [2048]u8 = undefined;
                if (resolveDocPath(tgt.path, &abs_buf)) |abs| {
                    setDocPath(abs);
                    watchCurrentDocument();
                }
            }
        },
        .external => {
            // http(s), other schemes, non-md locals: unchanged behavior —
            // the platform opens them outside the reader.
            bridge.platform_open_url_external(url_ptr, url_len);
        },
    }
}

// Outline picker model (#48): caller-owned mark + text arenas (BSS, zero
// file cost). 512 headings cover any realistic doc; enumeration caps, the
// panel shows the prefix.
var g_outline_marks: [512]layout.HeadingMark = undefined;
var g_outline_arena: [512 * layout.OUTLINE_TEXT_MAX]u8 = undefined;

/// Cmd+J pressed (platform panel key): enumerate headings and hand them to
/// the native picker. Jumps reuse on_scroll_to (exact y, no slug roundtrip,
/// so duplicate headings land precisely). Cold path: zero heap.
fn onOutlineOpen() callconv(.c) void {
    const n = layout.collectHeadings(
        g_app.bytes,
        g_app.lines[0..g_app.line_count],
        measureConfig(),
        &g_outline_arena,
        &g_outline_marks,
    );
    for (g_outline_marks[0..n]) |m| {
        bridge.platform_outline_add(m.level, m.y, m.text.ptr, @intCast(m.text.len));
    }
    bridge.platform_outline_show();
}

fn onKey(key_code: c_int, hovered_block_id: c_int) callconv(.c) void {
    const binding = help_overlay.actionFor(key_code) orelse return;
    switch (binding.action) {
        .scroll_down => {
            retargetScroll(g_smooth.target + 40.0);
        },
        .scroll_up => {
            retargetScroll(g_smooth.target - 40.0);
        },
        .block_left => {
            if (hovered_block_id >= 0 and hovered_block_id < MAX_SCROLLABLE_BLOCKS) {
                const id: usize = @intCast(hovered_block_id);
                g_app.block_scroll_x[id] = std.math.clamp(
                    g_app.block_scroll_x[id] - 30.0,
                    0.0,
                    g_app.block_max_scroll_x[id],
                );
            }
        },
        .block_right => {
            if (hovered_block_id >= 0 and hovered_block_id < MAX_SCROLLABLE_BLOCKS) {
                const id: usize = @intCast(hovered_block_id);
                g_app.block_scroll_x[id] = std.math.clamp(
                    g_app.block_scroll_x[id] + 30.0,
                    0.0,
                    g_app.block_max_scroll_x[id],
                );
            }
        },
        .page_down => {
            retargetScroll(g_smooth.target + g_app.window_height * 0.8);
        },
        .toggle_theme => {
            // Manual override (#47): wins until the next system change.
            g_app.is_dark_theme = !g_app.is_dark_theme;
            g_app.theme_override = g_app.is_dark_theme;
        },
        .toggle_help => {
            g_show_help = !g_show_help;
        },
        .dismiss_help => {
            g_show_help = false;
        },
        // Remote-image privacy toggle (issue #52): dropping remote content
        // changes laid-out image heights (real size <-> placeholder), so
        // metrics are recomputed and the offset re-clamped, exactly like a
        // resize. The platform repaints (full damage on key events).
        .toggle_images => {
            g_app.remote_images = !g_app.remote_images;
            updateDocumentMetrics();
            snapScroll(g_app.scroll_y);
        },
        .quit => {
            std.c.exit(0);
        },
        .native => {},
    }
}

// Centered cheat-sheet overlay (issue #54): geometry comes from the same
// table as the key handler (see help_overlay.emitOverlay). Painted after
// the damage clip closes so the modal card is never partially culled;
// pixels reuse platform_draw_text, which also records the runs in the
// text model (selection and clipboard).
fn drawHelpOverlay() void {
    const theme = if (g_app.is_dark_theme) layout.Theme.dark else layout.Theme.light;
    var cmds: [32]layout.DrawCommand = undefined;
    const n = help_overlay.emitOverlay(&cmds, g_app.window_width, g_app.window_height, theme);
    for (cmds[0..n]) |cmd| {
        switch (cmd.kind) {
            .fill_rect => {
                bridge.platform_draw_rect(
                    cmd.rect.x,
                    cmd.rect.y,
                    cmd.rect.w,
                    cmd.rect.h,
                    cmd.color.r,
                    cmd.color.g,
                    cmd.color.b,
                    cmd.color.a,
                );
            },
            .text_run => {
                const is_bold: c_int = if (cmd.style.bold) 1 else 0;
                bridge.platform_draw_text(
                    cmd.text.ptr,
                    @intCast(cmd.text.len),
                    cmd.rect.x,
                    cmd.rect.y,
                    cmd.font_size,
                    is_bold,
                    0,
                    0,
                    0,
                    cmd.color.r,
                    cmd.color.g,
                    cmd.color.b,
                    cmd.color.a,
                    null,
                    0,
                );
            },
            else => {},
        }
    }
}

// Open a damage clip for partial passes; full passes paint unclipped.
// Out-of-line (not inlined into onDraw) so the branch and call setup live
// here, not in the hot function body: __TEXT sits near a page boundary.
// Nest-safe: block clips save/restore inside this one; register-only paths
// are unaffected since a clip gates pixels, never state. Returns whether
// the caller must close the clip.
fn clipPassToDamage(dmg: damage.Damage) bool {
    if (dmg.full) return false;
    bridge.platform_begin_clip(dmg.rect.x, dmg.rect.y, dmg.rect.w, dmg.rect.h);
    return true;
}

fn onDraw(w: c_int, h: c_int) callconv(.c) void {
    const fw: f32 = @floatFromInt(w);
    const fh: f32 = @floatFromInt(h);
    if (fw != g_app.window_width or fh != g_app.window_height) {
        g_app.window_width = fw;
        g_app.window_height = fh;
        updateDocumentMetrics();
    }

    syncThemeToPlatform();
    bridge.platform_sync_scroll(g_app.scroll_y);
    bridge.platform_sync_overshoot(g_edge.overshoot);
    bridge.platform_set_scroll_info(g_app.scroll_y, g_app.max_scroll_y, g_app.window_height);

    // Damage tracking: AppKit reports the dirty rect for this draw.
    // Full-screen redraw happens only when the pending rect covers the view
    // (resize, scroll, theme toggle) or is absent (headless, first draw).
    // Partial damage culls off-region pixel commands below.
    var pdx: f32 = 0.0;
    var pdy: f32 = 0.0;
    var pdw: f32 = 0.0;
    var pdh: f32 = 0.0;
    const has_pending = bridge.platform_get_pending_damage(&pdx, &pdy, &pdw, &pdh) != 0;
    const dmg = damage.Damage.fromPending(has_pending, pdx, pdy, pdw, pdh, g_app.window_width, g_app.window_height);

    g_markers.reset();
    g_entities.reset();
    const vp_config = layout.ViewportConfig{
        .window_width = g_app.window_width,
        .window_height = g_app.window_height,
        .scroll_y = g_app.scroll_y,
        .base_font_size = g_text_scale.effectiveBase(),
        .block_scroll_x = g_app.block_scroll_x,
        .is_dark_theme = g_app.is_dark_theme,
        .checkpoints = g_checkpoints[0..g_checkpoint_count],
        .image_size_fn = gatedImageSize,
        .ordered_markers = &g_markers,
        .ref_defs = g_refdefs[0..g_refdef_count],
        .entities = &g_entities,
        .join_buf = &g_joinbuf,
    };

    var t_layout_ns: u64 = 0;
    if (build_options.test_hooks and g_sweep_active) t_layout_ns = nowNs();
    const cmd_count = layout.layoutViewport(
        g_app.bytes,
        g_app.lines[0..g_app.line_count],
        vp_config,
        &g_commands_buffer,
    );
    var t_paint_ns: u64 = 0;
    if (build_options.test_hooks and g_sweep_active) t_paint_ns = nowNs();

    // Headless layout probe (read-test binary only): dump the emitted command
    // stream so partial-damage renders can be diffed against the full
    // stream. Compiled out of ship builds.
    if (build_options.test_hooks and g_dump_commands) {
        std.debug.print("Commands: {d}\n", .{cmd_count});
        for (g_commands_buffer[0..cmd_count]) |cmd| {
            const kept: u8 = if (dmg.keeps(cmd.rect.x, cmd.rect.y, cmd.rect.w, cmd.rect.h)) 1 else 0;
            const tlen: usize = @min(cmd.text.len, 48);
            const showlen: usize = if (cmd.text.len > 100000) 0 else tlen;
            std.debug.print("CMD {s} {d:.1} {d:.1} {d:.1} {d:.1} kept={d} rgb={d},{d},{d} len={d} fs={d:.1} txt='{s}' sid={d} max={d:.1}\n", .{
                @tagName(cmd.kind),
                cmd.rect.x,
                cmd.rect.y,
                cmd.rect.w,
                cmd.rect.h,
                kept,
                cmd.color.r,
                cmd.color.g,
                cmd.color.b,
                cmd.text.len,
                cmd.font_size,
                cmd.text[0..showlen],
                cmd.scrollable_id,
                cmd.max_scroll_x,
            });
        }
    }

    // Partial-damage passes hard-clip to the damage rect (see clipPassToDamage:
    // translucent pixels are not idempotent under src-over, so unclipped
    // repaints of boundary-crossing records accumulated an extra coat on
    // every partial draw — flicker during GIF ticks/selection drags, residue
    // on drag-back, proven by --select-drag differing from a fresh render).
    const clipped_pass = @call(.never_inline, clipPassToDamage, .{dmg});
    for (g_commands_buffer[0..cmd_count]) |cmd| {
        switch (cmd.kind) {
            .fill_rect => {
                // Background fills are clipped to the damage; off-region
                // pixels are skipped entirely on partial redraws.
                const r = dmg.clip(cmd.rect.x, cmd.rect.y, cmd.rect.w, cmd.rect.h);
                if (r.isEmpty()) continue;
                bridge.platform_draw_rect(
                    r.x,
                    r.y,
                    r.w,
                    r.h,
                    cmd.color.r,
                    cmd.color.g,
                    cmd.color.b,
                    cmd.color.a,
                );
            },
            .code_block_bg => {
                // Hit-test registration is state, not pixels: always process
                // so hover survives partial redraws. Only pixels are culled.
                const r = dmg.clip(cmd.rect.x, cmd.rect.y, cmd.rect.w, cmd.rect.h);
                if (!r.isEmpty()) {
                    bridge.platform_draw_rect(
                        r.x,
                        r.y,
                        r.w,
                        r.h,
                        cmd.color.r,
                        cmd.color.g,
                        cmd.color.b,
                        cmd.color.a,
                    );
                }
                bridge.platform_register_code_block(
                    cmd.rect.x,
                    cmd.rect.y,
                    cmd.rect.w,
                    cmd.rect.h,
                    cmd.text.ptr,
                    @intCast(cmd.text.len),
                );
            },
            .register_scrollable_block => {
                // #314: push the live offset so ObjC maps document-space
                // selection endpoints back to view space after h-scroll.
                const live_off: f32 = if (cmd.scrollable_id >= 0 and cmd.scrollable_id < MAX_SCROLLABLE_BLOCKS)
                    std.math.clamp(g_app.block_scroll_x[@intCast(cmd.scrollable_id)], 0.0, cmd.max_scroll_x)
                else
                    0.0;
                bridge.platform_register_scrollable_block(
                    cmd.scrollable_id,
                    cmd.rect.x,
                    cmd.rect.y,
                    cmd.rect.w,
                    cmd.rect.h,
                    cmd.max_scroll_x,
                    live_off,
                );
                if (cmd.scrollable_id >= 0 and cmd.scrollable_id < MAX_SCROLLABLE_BLOCKS) {
                    const id: usize = @intCast(cmd.scrollable_id);
                    g_app.block_max_scroll_x[id] = cmd.max_scroll_x;
                }
            },
            .begin_clip => {
                bridge.platform_begin_clip(
                    cmd.rect.x,
                    cmd.rect.y,
                    cmd.rect.w,
                    cmd.rect.h,
                );
            },
            .end_clip => {
                bridge.platform_end_clip();
            },
            .line => {
                if (!dmg.keeps(cmd.rect.x, cmd.rect.y, cmd.rect.w, cmd.rect.h)) continue;
                bridge.platform_draw_rect(
                    cmd.rect.x,
                    cmd.rect.y,
                    cmd.rect.w,
                    cmd.rect.h,
                    cmd.color.r,
                    cmd.color.g,
                    cmd.color.b,
                    cmd.color.a,
                );
            },
            .text_run => {
                const is_bold: c_int = if (cmd.style.bold) 1 else 0;
                const is_italic: c_int = if (cmd.style.italic) 1 else 0;
                const is_mono: c_int = if (cmd.style.code) 1 else 0;
                const is_heading: c_int = if (cmd.style.heading) 1 else 0;

                const url_ptr = if (cmd.link_target) |t| t.ptr else null;
                const url_len: c_int = if (cmd.link_target) |t| @intCast(t.len) else 0;

                if (!dmg.keeps(cmd.rect.x, cmd.rect.y, cmd.rect.w, cmd.rect.h)) {
                    // Pixels culled, but the selection/hover/link record model
                    // must still be rebuilt (regression: partial draws starved
                    // it, breaking highlight painting — see damage.zig).
                    bridge.platform_register_text_run(
                        cmd.text.ptr,
                        @intCast(cmd.text.len),
                        cmd.rect.x,
                        cmd.rect.y,
                        cmd.rect.w,
                        cmd.rect.h,
                        cmd.font_size,
                        is_bold,
                        is_italic,
                        is_mono,
                        is_heading,
                        url_ptr,
                        url_len,
                    );
                    continue;
                }

                // Visited-link state (issue #25): the platform owns the
                // clicked-URL set; linked runs query it and take the theme
                // visited color. Link runs are rare, so the FFI round-trip
                // never touches the hot path.
                var run_color = cmd.color;
                if (cmd.link_target) |t| {
                    if (t.len > 0 and
                        bridge.platform_link_visited(t.ptr, @intCast(t.len)) != 0)
                    {
                        run_color = if (g_app.is_dark_theme)
                            layout.Theme.dark.link_visited
                        else
                            layout.Theme.light.link_visited;
                    }
                }
                // Find washes paint first, glyphs over them (#42). Theme
                // taken by pointer so the per-run call moves 24 bytes,
                // not a whole Theme struct.
                if (g_find_count > 0) {
                    const th = if (g_app.is_dark_theme) &layout.Theme.dark else &layout.Theme.light;
                    paintFindHighlights(&cmd, &th.find_bg, &th.find_current);
                }
                bridge.platform_draw_text(
                    cmd.text.ptr,
                    @intCast(cmd.text.len),
                    cmd.rect.x,
                    cmd.rect.y,
                    cmd.font_size,
                    is_bold,
                    is_italic,
                    is_mono,
                    is_heading,
                    run_color.r,
                    run_color.g,
                    run_color.b,
                    run_color.a,
                    url_ptr,
                    url_len,
                );
            },
            .image => {
                if (!dmg.keeps(cmd.rect.x, cmd.rect.y, cmd.rect.w, cmd.rect.h)) continue;
                const url_ptr = if (cmd.link_target) |t| t.ptr else null;
                const url_len: c_int = if (cmd.link_target) |t| @intCast(t.len) else 0;
                // Privacy gate (issue #52): blocked remote URLs never reach
                // the platform loader (which is what would fetch them).
                // They degrade to the same muted placeholder box the loader
                // draws for failures — pixels only, no fetch, no hang.
                // Alt text rides along for the muted placeholder box (#45);
                // loaded images ignore it.
                if (cmd.link_target) |t| {
                    if (remote_policy.blockedByPolicy(t, g_app.remote_images)) {
                        bridge.platform_draw_rect(cmd.rect.x, cmd.rect.y, cmd.rect.w, cmd.rect.h, 28, 28, 32, 255);
                        bridge.platform_draw_rect(cmd.rect.x, cmd.rect.y, cmd.rect.w, 1.0, 80, 40, 40, 255);
                        continue;
                    }
                }
                bridge.platform_draw_image(
                    url_ptr,
                    url_len,
                    cmd.rect.x,
                    cmd.rect.y,
                    cmd.rect.w,
                    cmd.rect.h,
                    cmd.text.ptr,
                    @intCast(cmd.text.len),
                );
            },
            .inline_code_bg => {
                // Inline-code pill: rounded fill + 1px border. Culled like
                // text runs; the partial-damage hard clip confines pixels.
                if (!dmg.keeps(cmd.rect.x, cmd.rect.y, cmd.rect.w, cmd.rect.h)) continue;
                const bd = if (g_app.is_dark_theme)
                    layout.Theme.dark.code_border
                else
                    layout.Theme.light.code_border;
                bridge.platform_draw_pill(
                    cmd.rect.x,
                    cmd.rect.y,
                    cmd.rect.w,
                    cmd.rect.h,
                    layout.inline_code_radius,
                    cmd.color.r,
                    cmd.color.g,
                    cmd.color.b,
                    cmd.color.a,
                    bd.r,
                    bd.g,
                    bd.b,
                    bd.a,
                );
            },
        }
    }

    // Draw minimalist ambient reading progress indicator (thin 2px filament on right)
    if (g_app.max_scroll_y > 0 and dmg.keeps(g_app.window_width - 3.0, 0.0, 2.0, g_app.window_height)) {
        const bar_height: f32 = layout.SCROLLBAR_THUMB_H;
        const bar_y = layout.scrollbarThumbY(g_app.scroll_y, g_app.max_scroll_y, g_app.window_height);
        const bar_color = if (g_app.is_dark_theme)
            layout.Color{ .r = 90, .g = 160, .b = 255, .a = 180 }
        else
            layout.Color{ .r = 40, .g = 120, .b = 240, .a = 180 };

        bridge.platform_draw_rect(
            g_app.window_width - 3.0,
            bar_y,
            2.0,
            bar_height,
            bar_color.r,
            bar_color.g,
            bar_color.b,
            bar_color.a,
        );
    }
    if (clipped_pass) {
        bridge.platform_end_clip();
    }

    // Find chase (issue #42): the cycle scrolled to the match's block
    // top; if wrapping kept the current wash off-viewport (nothing
    // painted this frame), step down and redraw — bounded, then rest.
    if (g_find_chase_armed) {
        if (g_find_painted or g_find_chase_left == 0) {
            g_find_chase_armed = false;
        } else {
            g_find_chase_left -= 1;
            snapScroll(g_app.scroll_y + g_app.window_height * 0.8);
            bridge.platform_request_redraw();
        }
    }

    // Modal cheat sheet paints above everything, unclipped (see
    // drawHelpOverlay: never culled by partial damage).
    if (g_show_help) drawHelpOverlay();
    // Remote-image privacy indicator (issue #52): visible whenever the
    // document contains remote content. Painted last and unclipped so a
    // partial damage pass can never leave it half-drawn.
    if (g_remote_seen) {
        const ind_on = g_app.remote_images;
        const ind_text = if (ind_on) "remote images on (i to block)" else "remote images off (i to allow)";
        const ind_fs: f32 = 12.0;
        const ind_w = layout.measureTextEx(ind_text, ind_fs, false, false, false, false);
        const ind_x = g_app.window_width - ind_w - 14.0;
        const ind_color = if (g_app.is_dark_theme)
            layout.Color{ .r = 140, .g = 140, .b = 145, .a = 255 }
        else
            layout.Color{ .r = 105, .g = 110, .b = 118, .a = 255 };
        bridge.platform_draw_text(
            ind_text.ptr,
            @intCast(ind_text.len),
            ind_x,
            8.0,
            ind_fs,
            0,
            0,
            0,
            0,
            ind_color.r,
            ind_color.g,
            ind_color.b,
            ind_color.a,
            null,
            0,
        );
    }

    // First frame committed: image decodes may start now, off the startup
    // critical path. Headless one-shots skip this (placeholders are the
    // deterministic expected output there); settle runs arm explicitly.
    if (!g_first_paint_done) {
        g_first_paint_done = true;
        if (!g_headless_oneshot) bridge.platform_arm_images();
    }

    // Scroll-sweep profiler row (read-test binary only): per-offset phase
    // timings plus workload counters. Compiled out of ship builds.
    if (build_options.test_hooks and g_sweep_active) {
        const t_end_ns = nowNs();
        var shape_hits: u64 = 0;
        var shape_misses: u64 = 0;
        var atlas_flushes: u64 = 0;
        bridge.platform_glyph_cache_stats(&shape_hits, &shape_misses, &atlas_flushes);
        std.debug.print("SWEEP off={d:.0} layout_us={d} paint_us={d} cmds={d} img={d} hits={d} miss={d} flush={d}\n", .{
            g_app.scroll_y,
            (t_paint_ns - t_layout_ns) / 1000,
            (t_end_ns - t_paint_ns) / 1000,
            cmd_count,
            bridge.platform_test_image_draws(),
            shape_hits,
            shape_misses,
            atlas_flushes,
        });
    }
}

// ---------------------------------------------------------------------------
// Minimal production CLI surface (issue #55): --help, --version, one
// positional document path, and `-`/piped stdin via bounded temp-file
// buffering (mmap needs a real file). Anything outside this interface is
// rejected with a usage hint, never silently absorbed. Raw std.c.write
// only: no std.fmt linkage may leak into ship builds (__TEXT budget).
const READ_VERSION = "0.1.0";
const CLI_USAGE =
    \\Usage: read [--help] [--version] [file]
    \\  file       Markdown document to open (default: built-in welcome doc)
    \\  -          Read Markdown from stdin (max 32 MiB)
    \\  --help     Print this help and exit
    \\  --version  Print version and exit
    \\
    \\With no file and piped stdin (`curl … | read`), stdin is read instead.
    \\
;
const CLI_VERSION_LINE = "read " ++ READ_VERSION ++ "\n";
/// Bounded stdin spool: mmap needs a seekable file, so piped input lands in
/// a temp file first. Caps temp/resident cost; larger input is a clean
/// error, never a hang or OOM.
const STDIN_MAX_BYTES: usize = 32 * 1024 * 1024;

fn cliIsHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help");
}

fn cliIsVersion(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--version");
}

fn cliIsStdinDash(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-");
}

fn cliWriteStderr(msg: []const u8) void {
    _ = std.c.write(std.posix.STDERR_FILENO, msg.ptr, msg.len);
}

fn cliWriteStdout(msg: []const u8) void {
    _ = std.c.write(std.posix.STDOUT_FILENO, msg.ptr, msg.len);
}

fn cliUsageError(detail: ?[]const u8) noreturn {
    if (detail) |msg| {
        cliWriteStderr("read: ");
        cliWriteStderr(msg);
        cliWriteStderr("\n");
    }
    cliWriteStderr(CLI_USAGE);
    std.c.exit(2);
}

/// fstat mode carries a piped/redirected document (FIFO, regular file,
/// socket) as opposed to an interactive terminal, /dev/null, or TTY.
fn stdinCarriesDocument(mode: std.posix.mode_t) bool {
    return switch (mode & std.posix.S.IFMT) {
        std.posix.S.IFIFO, std.posix.S.IFREG, std.posix.S.IFSOCK => true,
        else => false,
    };
}

/// fstat mode of stdin, or null when it cannot be queried (closed stdin,
/// Windows). Darwin uses libc fstat; Linux uses statx(AT_EMPTY_PATH) — the
/// same split as MappedFile.open (see mmap.zig), because Zig 0.16 leaves
/// libc fstat void on Linux.
fn stdinMode() ?std.posix.mode_t {
    if (builtin.os.tag == .windows) return null;
    if (builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var sx = std.mem.zeroes(linux.Statx);
        const err = linux.errno(linux.statx(
            std.posix.STDIN_FILENO,
            "",
            linux.AT.EMPTY_PATH,
            .{ .MODE = true },
            &sx,
        ));
        if (err != .SUCCESS or !sx.mask.MODE) return null;
        return @intCast(sx.mode & 0xFFFF);
    } else {
        var st: std.c.Stat = undefined;
        if (std.c.fstat(std.posix.STDIN_FILENO, &st) != 0) return null;
        return st.mode;
    }
}

/// True when stdin is a pipe/file/socket (i.e. `curl … | read` should read
/// it). Terminals and character devices keep the default welcome doc.
fn stdinPiped() bool {
    const mode = stdinMode() orelse return false;
    return stdinCarriesDocument(mode);
}

/// Spool stdin (bounded by STDIN_MAX_BYTES) into a temp file and return its
/// path (borrowed from `buf`). The name embeds our pid, so no live process
/// shares it; stale files from crashed runs are unlinked before create.
fn spoolStdinToTemp(buf: *[std.fs.max_path_bytes:0]u8) ![:0]const u8 {
    const tmpdir = if (std.c.getenv("TMPDIR")) |z| std.mem.span(z) else "/tmp";
    const stem = "/read-stdin-";
    const suffix = ".md";
    // 20 digits of pid + slack; fall back to /tmp when TMPDIR is absurd.
    const need = tmpdir.len + stem.len + 20 + suffix.len;
    const dir: []const u8 = if (need <= buf.len) tmpdir else "/tmp";
    var len: usize = 0;
    @memcpy(buf[len..][0..dir.len], dir);
    len += dir.len;
    @memcpy(buf[len..][0..stem.len], stem);
    len += stem.len;
    var pid: u32 = @bitCast(std.c.getpid());
    var digits: [20]u8 = undefined;
    var ndigits: usize = 0;
    if (pid == 0) {
        digits[0] = '0';
        ndigits = 1;
    } else {
        while (pid > 0) : (pid /= 10) {
            digits[ndigits] = @intCast('0' + (pid % 10));
            ndigits += 1;
        }
        std.mem.reverse(u8, digits[0..ndigits]);
    }
    @memcpy(buf[len..][0..ndigits], digits[0..ndigits]);
    len += ndigits;
    @memcpy(buf[len..][0..suffix.len], suffix);
    len += suffix.len;
    buf[len] = 0;
    const path = buf[0..len :0];

    _ = std.c.unlink(path);
    const fd = try std.posix.openat(
        std.posix.AT.FDCWD,
        path,
        .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true },
        0o600,
    );
    defer _ = std.c.close(fd);
    var chunk: [64 * 1024]u8 = undefined;
    var total: usize = 0;
    while (true) {
        const n = try std.posix.read(std.posix.STDIN_FILENO, &chunk);
        if (n == 0) break;
        total += n;
        if (total > STDIN_MAX_BYTES) {
            _ = std.c.unlink(path);
            return error.StdinTooLarge;
        }
        var off: usize = 0;
        while (off < n) {
            const w: isize = std.c.write(fd, chunk[off..n].ptr, n - off);
            if (w <= 0 or w > @as(isize, @intCast(n - off))) return error.StdinSpoolFailed;
            off += @intCast(w);
        }
    }
    return path;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var in_fence: simd.FenceState = .{};
    var file_path: ?[]const u8 = null;
    var stdin_dash = false;

    // Parse command line arguments.
    // Production surface is --help, --version, one positional path, and `-`
    // for stdin. The whole headless test CLI (--screenshot, --scroll,
    // --scroll-sweep, --damage, --dump-*, --select*, --probe-px,
    // --force-scale, --settle-images) lives behind ONE comptime gate so the
    // ship binary contains none of it; it runs only in the read-test
    // binary. Trust the compiler.
    var args_it = std.process.Args.Iterator.init(init.args);
    _ = args_it.next(); // skip exe name
    var screenshot_path: ?[*:0]const u8 = null;
    var find_cli_query: ?[]const u8 = null;
    var dump_records = false;
    var settle_images_ms: i64 = 0;

    if (!build_options.test_hooks) {
        // Production owns no test flags; the reset stores keep the hook
        // vars observably settled on this path.
        screenshot_path = null;
        dump_records = false;
        settle_images_ms = 0;
        while (args_it.next()) |arg| {
            if (cliIsHelp(arg)) {
                cliWriteStdout(CLI_USAGE);
                std.c.exit(0);
            } else if (cliIsVersion(arg)) {
                cliWriteStdout(CLI_VERSION_LINE);
                std.c.exit(0);
            } else if (cliIsStdinDash(arg)) {
                if (stdin_dash or file_path != null) cliUsageError("unexpected extra document argument");
                stdin_dash = true;
            } else if (arg.len > 0 and arg[0] == '-') {
                cliUsageError(arg);
            } else if (file_path != null) {
                cliUsageError("unexpected extra document argument");
            } else {
                file_path = arg;
            }
        }
    } else {
        while (args_it.next()) |arg| {
            if (cliIsHelp(arg)) {
                cliWriteStdout(CLI_USAGE);
                std.c.exit(0);
            } else if (cliIsVersion(arg)) {
                cliWriteStdout(CLI_VERSION_LINE);
                std.c.exit(0);
            } else if (cliIsStdinDash(arg)) {
                if (stdin_dash or file_path != null) cliUsageError("unexpected extra document argument");
                stdin_dash = true;
            } else if (std.mem.eql(u8, arg, "--screenshot")) {
                if (args_it.next()) |sc_path| {
                    screenshot_path = @ptrCast(sc_path.ptr);
                }
            } else if (std.mem.eql(u8, arg, "--scroll")) {
                if (args_it.next()) |sc_str| {
                    g_app.scroll_y = parseF32(sc_str);
                    g_smooth.snapTo(g_app.scroll_y, std.math.inf(f32));
                }
            } else if (std.mem.eql(u8, arg, "--scroll-x-end")) {
                // Screenshot affordance (mirrors --scroll): park every
                // horizontal block at its end so end-state shadows (left
                // edge) can be captured. Layout clamps each to its max.
                for (&g_app.block_scroll_x) |*s| s.* = std.math.inf(f32);
            } else {
            // Document paths land in file_path from any position; hook
            // flags (and their consumed values, taken above) never do, so
            // a missing document still falls back to the default doc.
            // Single-dash non-`-` tokens are rejected (never absorbed as a
            // path); same for a second positional and unknown `--` flags
            // (the chain below ends in a usage error for those).
            if (arg.len > 0 and arg[0] == '-') {
                if (!std.mem.startsWith(u8, arg, "--")) cliUsageError(arg);
            } else if (file_path != null) {
                cliUsageError("unexpected extra document argument");
            } else {
                file_path = arg;
            }
            // Headless test-hooks matching (read-test binary only): ONE
            // comptime gate for the whole tail, so ship builds emit zero
            // bytes here — no per-flag scaffolding, no flag literals, no
            // page-boundary cascade (__TEXT budget; see size_gate.sh).
            // New hooks flags belong in this chain, in the same shape:
            // parse values only, never touch file_path.
            if (build_options.test_hooks) {
                if (std.mem.eql(u8, arg, "--scroll-sweep")) {
                    // Scroll profiler: render offsets from,to,step in one
                    // process (+ --screenshot as scratch output).
                    if (args_it.next()) |sw_str| {
                        var it = std.mem.splitScalar(u8, sw_str, ',');
                        var vals: [3]f32 = [_]f32{0.0} ** 3;
                        var i: usize = 0;
                        while (it.next()) |num| {
                            if (i >= vals.len) break;
                            vals[i] = std.fmt.parseFloat(f32, num) catch 0.0;
                            i += 1;
                        }
                        g_sweep_from = vals[0];
                        g_sweep_to = vals[1];
                        g_sweep_step = vals[2];
                        g_sweep_active = true;
                    }
                } else if (std.mem.eql(u8, arg, "--damage")) {
                    // Parity-test hook: inject synthetic pending damage.
                    if (args_it.next()) |dmg_str| {
                        var it = std.mem.splitScalar(u8, dmg_str, ',');
                        const dx = std.fmt.parseFloat(f32, it.next() orelse "0") catch 0.0;
                        const dy = std.fmt.parseFloat(f32, it.next() orelse "0") catch 0.0;
                        const dw = std.fmt.parseFloat(f32, it.next() orelse "0") catch 0.0;
                        const dh = std.fmt.parseFloat(f32, it.next() orelse "0") catch 0.0;
                        bridge.platform_set_test_damage(dx, dy, dw, dh, 1);
                    }
                } else if (std.mem.eql(u8, arg, "--dump-records")) {
                    dump_records = true;
                } else if (std.mem.eql(u8, arg, "--dump-commands")) {
                    g_dump_commands = true;
                } else if (std.mem.eql(u8, arg, "--settle-images")) {
                    settle_images_ms = 3000;
                } else if (std.mem.startsWith(u8, arg, "--probe-px=")) {
                    var it = std.mem.splitScalar(u8, arg["--probe-px=".len..], ',');
                    const qx = std.fmt.parseInt(c_int, it.next() orelse "0", 10) catch 0;
                    const qy = std.fmt.parseInt(c_int, it.next() orelse "0", 10) catch 0;
                    bridge.platform_probe_px_add(qx, qy);
                } else if (std.mem.startsWith(u8, arg, "--find=")) {
                    // Find screenshot: apply the query post-load (needs
                    // bytes + metrics), driving the same path as the bar.
                    find_cli_query = arg["--find=".len..];
                } else if (std.mem.eql(u8, arg, "--select")) {
                    // Selection screenshot: doc-space endpoints x1,y1,x2,y2.
                    if (args_it.next()) |sel_str| {
                        var it = std.mem.splitScalar(u8, sel_str, ',');
                        const x1 = std.fmt.parseFloat(f32, it.next() orelse "0") catch 0.0;
                        const y1 = std.fmt.parseFloat(f32, it.next() orelse "0") catch 0.0;
                        const x2 = std.fmt.parseFloat(f32, it.next() orelse "0") catch 0.0;
                        const y2 = std.fmt.parseFloat(f32, it.next() orelse "0") catch 0.0;
                        bridge.platform_set_test_selection(x1, y1, x2, y2, 1);
                    }
                } else if (std.mem.eql(u8, arg, "--hover")) {
                    // Copy-button ghost probe: park the hover point (view
                    // space x,y) so the button paints headlessly.
                    if (args_it.next()) |hov_str| {
                        var it = std.mem.splitScalar(u8, hov_str, ',');
                        const hx = std.fmt.parseFloat(f32, it.next() orelse "0") catch 0.0;
                        const hy = std.fmt.parseFloat(f32, it.next() orelse "0") catch 0.0;
                        bridge.platform_set_test_hover(hx, hy);
                    }
                } else if (std.mem.eql(u8, arg, "--button-damage")) {
                    // Damage-contract query: print the rect a button
                    // visibility flip invalidates for block bx,by,bw,bh.
                    if (args_it.next()) |bd_str| {
                        var it = std.mem.splitScalar(u8, bd_str, ',');
                        const bx = std.fmt.parseFloat(f32, it.next() orelse "0") catch 0.0;
                        const by = std.fmt.parseFloat(f32, it.next() orelse "0") catch 0.0;
                        const bw = std.fmt.parseFloat(f32, it.next() orelse "0") catch 0.0;
                        const bh = std.fmt.parseFloat(f32, it.next() orelse "0") catch 0.0;
                        var ox: f32 = 0;
                        var oy: f32 = 0;
                        var ow: f32 = 0;
                        var oh: f32 = 0;
                        bridge.platform_test_button_damage(bx, by, bw, bh, &ox, &oy, &ow, &oh);
                        std.debug.print("BTNDMG={d:.1},{d:.1},{d:.1},{d:.1}\n", .{ ox, oy, ow, oh });
                    }
                } else if (std.mem.eql(u8, arg, "--force-scale")) {
                    // Force the headless output scale (e.g. 2 for the live
                    // Retina atlas path) to diff per-frame pixels.
                    if (args_it.next()) |sc_str| {
                        bridge.platform_set_test_scale(std.fmt.parseFloat(f32, sc_str) catch 0.0);
                    }
                } else if (std.mem.eql(u8, arg, "--select-drag")) {
                    // Drag-back residue test: caret baseline, extend to A,
                    // shrink to B — every phase after the first incremental
                    // with live drag damage on one bitmap, each dumped to
                    // /tmp/drag_phase_N.png. Doc-space x1,y1,x2,y2,x3,y3,x4,y4.
                    if (args_it.next()) |sel_str| {
                        var it = std.mem.splitScalar(u8, sel_str, ',');
                        var i: usize = 0;
                        while (it.next()) |num| {
                            if (i >= g_drag_vals.len) break;
                            g_drag_vals[i] = std.fmt.parseFloat(f32, num) catch 0.0;
                            i += 1;
                        }
                        g_drag_active = true;
                    }
                } else if (std.mem.startsWith(u8, arg, "--")) {
                    // Unknown `--` flags are rejected, never silently
                    // absorbed (issue #55; previously fell through to the
                    // default doc). Positional paths never reach here:
                    // they don't start with `--`.
                    cliUsageError(arg);
                }
            }
        }
        } // end while (test CLI arg parse)
    } // end test-CLI else (ship builds skip all of the above)

    // Stdin decision (issue #55): explicit `-` always reads stdin; with no
    // positional, a pipe/file/socket on stdin (`curl … | read`) is read
    // instead of showing the welcome doc. Terminals and character devices
    // (/dev/null, TTYs) keep the default doc. Bounded temp spool: mmap
    // needs a real file.
    var stdin_tmp: [std.fs.max_path_bytes:0]u8 = undefined;
    var stdin_tmp_c: ?[*:0]const u8 = null;
    if (stdin_dash or (file_path == null and stdinPiped())) {
        const spooled = spoolStdinToTemp(&stdin_tmp) catch {
            cliWriteStderr("read: failed to read stdin (or exceeds 32 MiB limit)\n");
            std.c.exit(1);
        };
        stdin_tmp_c = spooled;
        file_path = spooled;
    }

    if (file_path) |path| {
        const mapped = mmap.MappedFile.open(path) catch {
            // Ship-safe error path: raw writes only, so no std.fmt
            // error-formatting machinery is linked into ship builds.
            if (stdin_tmp_c) |cpath| _ = std.c.unlink(cpath);
            const pre = "Failed to open file: ";
            _ = std.c.write(std.posix.STDERR_FILENO, pre, pre.len);
            _ = std.c.write(std.posix.STDERR_FILENO, path.ptr, path.len);
            const nl = "\n";
            _ = std.c.write(std.posix.STDERR_FILENO, nl, nl.len);
            return;
        };
        g_app.mapped_file = mapped;
        g_app.bytes = mapped.bytes;
        // Cold-start prefetch (issue #11): SEQUENTIAL readahead over the
        // whole file plus WILLNEED on the leading window, once per open.
        // No read()/copy anywhere on this path — the scan below walks the
        // mapping in place.
        mapped.adviseSequential();
        // The spool has served its purpose: the mapping and open fd survive
        // the unlink, and no temp file lingers after startup.
        if (stdin_tmp_c) |cpath| _ = std.c.unlink(cpath);
        // Anchor relative `.md` links (and image paths) to this file's dir.
        setDocDir(path);
        // Anchor external-change reloads (#44), unless this is an
        // already-unlinked stdin spool (nothing to watch).
        if (stdin_tmp_c == null) {
            setDocPath(path);
            watchCurrentDocument();
        }
        // Document directory for relative image paths (#45). The platform
        // takes the full path and keeps the dirname; empty clears it.
        bridge.platform_set_document_dir(path.ptr, @intCast(path.len));
    } else {
        g_app.bytes = DEFAULT_DOC;
    }
    // Fresh document: privacy indicator latch re-arms (relatched by the
    // metrics pass below when the doc actually contains remote images).
    g_remote_seen = false;

    // Index lines with SIMD scanner
    g_app.line_count = simd.scanLines(g_app.bytes, &g_lines_buffer, &in_fence);
    g_app.lines = g_lines_buffer[0..g_app.line_count];
    // Reference definitions once per load (cold; geometry depends on them).
    g_refdef_count = simd.scanRefDefs(g_app.bytes, g_app.lines, &g_refdefs);

    // Compute accurate total document height and max scroll limit
    updateDocumentMetrics();

    // Headless screenshot mode (test binary only: the comptime gate keeps
    // this block out of ship-build analysis entirely).
    if (build_options.test_hooks) {
        if (screenshot_path) |sc_path| {
        g_app.window_width = 1200.0;
        g_app.window_height = 900.0;
        updateDocumentMetrics();
        // Find screenshot hook (see --find= above): same entry point the
        // panel drives, after bytes + metrics exist.
        if (find_cli_query) |fq| applyFindQuery(fq);
        // Let async image decodes finish, then relayout with real sizes.
        // TEST_HOOKS only; ship screenshots render immediately.
        if (build_options.test_hooks and settle_images_ms > 0) {
            // Settle runs want images: arm the parked decodes first, then
            // wait for them to drain as before.
            bridge.platform_arm_images();
            const t0 = getTimestampMs();
            const req = std.posix.timespec{ .sec = 0, .nsec = 20 * 1_000_000 };
            while (bridge.platform_images_pending() > 0 and
                getTimestampMs() - t0 < settle_images_ms)
            {
                _ = std.c.nanosleep(&req, null);
            }
            if (build_options.test_hooks) {
                std.debug.print("SETTLE pending={d} elapsed_ms={d}\n", .{
                    bridge.platform_images_pending(),
                    getTimestampMs() - t0,
                });
            }
            updateDocumentMetrics();
        }
        // Drag-back residue test (read-test binary only): incremental repaint
        // of A-then-B on one bitmap, compared by the caller against a fresh
        // full render of B. Any byte difference is leftover highlight.
        if (build_options.test_hooks and g_drag_active) {
            // Multi-phase determinism: like plain one-shots, the drag
            // residue test compares incremental vs fresh renders pixel-wise,
            // so decodes must not land mid-test. Placeholders throughout.
            g_headless_oneshot = true;
            const v = g_drag_vals;
            const r = bridge.platform_render_select_drag_png(sc_path, 1200, 900, onDraw,
                v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7]);
            if (r == 0) {
                std.debug.print("Drag capture generated: {s}\n", .{sc_path});
                std.c.exit(0);
            } else {
                std.debug.print("Drag capture failed (code {d})\n", .{r});
                std.c.exit(1);
            }
        }
        // Scroll-sweep profiler (read-test binary only): one render per offset,
        // caches warm across offsets exactly like live scrolling. Each
        // render prints a SWEEP timing row from onDraw.
        if (build_options.test_hooks and g_sweep_active) {
            if (g_sweep_step > 0.0 and g_sweep_to >= g_sweep_from) {
                var off = g_sweep_from;
                while (off <= g_sweep_to) : (off += g_sweep_step) {
                    g_app.scroll_y = off;
                    const r = bridge.platform_render_to_png(sc_path, 1200, 900, onDraw);
                    if (r != 0) {
                        std.debug.print("Sweep render failed at offset {d:.0} (code {d})\n", .{ off, r });
                        std.c.exit(1);
                    }
                }
            } else {
                g_app.scroll_y = g_sweep_from;
                const r = bridge.platform_render_to_png(sc_path, 1200, 900, onDraw);
                if (r != 0) std.c.exit(1);
            }
            std.c.exit(0);
        }
        // Plain one-shot: placeholders are the expected output (decodes
        // never win the race today either); suppress the first-paint arm
        // so no decode CPU lands in the startup window at all.
        g_headless_oneshot = true;
        const rc = bridge.platform_render_to_png(sc_path, 1200, 900, onDraw);
        if (rc == 0) {
            std.debug.print("Screenshot successfully generated: {s}\n", .{sc_path});
            if (build_options.test_hooks and dump_records) {
                std.debug.print("Text records rebuilt: {d}\n", .{bridge.platform_text_record_count()});
                var total: c_ulong = 0;
                var primed: c_ulong = 0;
                bridge.platform_test_image_primed(&total, &primed);
                std.debug.print("Image frames primed: {d}/{d}\n", .{ primed, total });
            }
            std.c.exit(0);
        } else {
            std.debug.print("Failed to generate screenshot (code {d})\n", .{rc});
            std.c.exit(1);
        }
        }
    }

    const callbacks = bridge.PlatformCallbacks{
        .on_scroll = onScroll,
        .on_resize = onResize,
        .on_key = onKey,
        .on_draw = onDraw,
        .on_link = onLink,
        .on_tick = onTick,
        .on_scroll_to = onScrollTo,
        .on_images_changed = onImagesChanged,
        .on_appearance = onAppearance,
        .on_outline_open = onOutlineOpen,
        .on_display = onDisplay,
        .on_open_file = onOpenFile,
        .on_file_changed = onFileChanged,
        .on_find_query = onFindQuery,
        .on_find_next = onFindNext,
        .on_find_closed = onFindClosed,
    };

    _ = bridge.platform_init("Read", 1000, 750, callbacks);
    bridge.platform_run_loop();
}

// ---------------------------------------------------------------------------
// No-blur regression: the Retina atlas blit path must stay crisp. Renders a
// few text runs at fractional origins (what real layout always produces)
// through the live 2x atlas path headlessly, decodes the PNG in-test with
// zero new platform API, and asserts edge acutance. Blurry blits smear glyph
// edges over 4-6px of mid-gray; snapped 1:1 blits hold 1-2px transitions.
// Runs only in the read-test binary (needs --force-scale plumbing).
// ---------------------------------------------------------------------------

const CRISP_PNG_W: c_int = 600;
const CRISP_PNG_H: c_int = 260;
const CRISP_PNG_PATH = "/tmp/crisp_regression.png";
// Calibrated (2026-09, arm64, bundled IBM Plex Serif / Space Grotesk /
// JetBrains Mono): blurry atlas blits score acutance 155.2 with edge_frac
// 0.1340 (stable across runs); snapped 1:1 blits score 182.5 with 0.0765.
// Thresholds sit at the midpoints with margin on both sides.
const CRISP_ACUTANCE_MIN: f64 = 169.0;
const CRISP_EDGE_FRAC_MAX: f64 = 0.105;

fn crispRenderFn(w: c_int, h: c_int) callconv(.c) void {
    bridge.platform_draw_rect(0, 0, @floatFromInt(w), @floatFromInt(h), 0x12, 0x12, 0x12, 255);
    const R: u8 = 0xE0;
    const G: u8 = 0xE0;
    const B: u8 = 0xE0;
    const A: u8 = 255;
    const Run = struct {
        text: []const u8,
        x: f32,
        y: f32,
        size: f32,
        bold: c_int,
        italic: c_int,
        mono: c_int,
        heading: c_int,
    };
    // Fractional origins on purpose: integer-aligned runs can look crisp
    // even through a blurry blit path, which would neuter this test.
    const runs = [_]Run{
        .{ .text = "Pack my box with five dozen liquor jugs.", .x = 50.33, .y = 40.67, .size = 17.0, .bold = 0, .italic = 0, .mono = 0, .heading = 0 },
        .{ .text = "The quick brown fox jumps over.", .x = 50.71, .y = 90.29, .size = 17.0, .bold = 1, .italic = 0, .mono = 0, .heading = 0 },
        .{ .text = "const crisp = pixels * 2;", .x = 50.17, .y = 140.83, .size = 14.96, .bold = 0, .italic = 0, .mono = 1, .heading = 0 },
        .{ .text = "Crisp Headings", .x = 50.55, .y = 190.41, .size = 28.9, .bold = 1, .italic = 0, .mono = 0, .heading = 1 },
    };
    for (runs) |r| {
        bridge.platform_draw_text(r.text.ptr, @intCast(r.text.len), r.x, r.y, r.size, r.bold, r.italic, r.mono, r.heading, R, G, B, A, null, 0);
    }
}

const CrispMetrics = struct {
    acutance: f64,
    edge_frac: f64,
};

fn crispPngMetrics(allocator: std.mem.Allocator, path: []const u8) !CrispMetrics {
    // Zero-copy read through the app's own mmap layer (no std.fs dependency).
    var mapped = try mmap.MappedFile.open(path);
    defer mapped.close();
    const bytes = mapped.bytes;
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return error.NotPng;

    var img_w: usize = 0;
    var img_h: usize = 0;
    var color_type: u8 = 0;
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(allocator);
    var pos: usize = 8;
    while (pos + 8 <= bytes.len) {
        const ln = std.mem.readInt(u32, bytes[pos..][0..4], .big);
        const typ = bytes[pos + 4 ..][0..4];
        if (bytes.len < pos + 12 + ln) return error.TruncatedPng;
        const body = bytes[pos + 8 ..][0..ln];
        pos += 12 + ln;
        if (std.mem.eql(u8, typ, "IHDR")) {
            img_w = std.mem.readInt(u32, body[0..4], .big);
            img_h = std.mem.readInt(u32, body[4..8], .big);
            if (body[8] != 8 or body[12] != 0) return error.UnsupportedPng;
            color_type = body[9];
        } else if (std.mem.eql(u8, typ, "IDAT")) {
            try idat.appendSlice(allocator, body);
        } else if (std.mem.eql(u8, typ, "IEND")) {
            break;
        }
    }
    const ch: usize = switch (color_type) {
        2 => 3,
        6 => 4,
        else => return error.UnsupportedPng,
    };
    if (img_w == 0 or img_h == 0) return error.EmptyPng;
    const stride = img_w * ch;

    const window = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(window);
    var input: std.Io.Reader = .fixed(idat.items);
    var decomp = std.compress.flate.Decompress.init(&input, .zlib, window);
    const raw = try decomp.reader.readAlloc(allocator, (stride + 1) * img_h);
    defer allocator.free(raw);

    // Unfilter scanlines to luma, then score gradient energy over the
    // central content band (margins carry no text).
    const prev = try allocator.alloc(u8, stride);
    defer allocator.free(prev);
    @memset(prev, 0);
    var edge_sum: f64 = 0;
    var edge_n: usize = 0;
    var total: usize = 0;
    const x0 = img_w / 4;
    const x1 = 3 * img_w / 4;
    const luma_prev_row = try allocator.alloc(u8, img_w);
    defer allocator.free(luma_prev_row);
    @memset(luma_prev_row, 0);
    const luma_row = try allocator.alloc(u8, img_w);
    defer allocator.free(luma_row);
    var y: usize = 0;
    while (y < img_h) : (y += 1) {
        const f = raw[y * (stride + 1)];
        const line = raw[y * (stride + 1) + 1 ..][0..stride];
        var i: usize = 0;
        while (i < stride) : (i += 1) {
            const a: u16 = if (i >= ch) line[i - ch] else 0;
            const b: u16 = prev[i];
            const c: u16 = if (i >= ch) prev[i - ch] else 0;
            const filt: u16 = switch (f) {
                0 => 0,
                1 => a,
                2 => b,
                3 => (a + b) >> 1,
                4 => blk: {
                    const pa: u16 = if (b >= c) b - c else c - b;
                    const pb: u16 = if (a >= c) a - c else c - a;
                    const ac: u16 = if (a >= b) a - b else b - a;
                    const pc: u16 = ac + (if ((a + b) >= 2 * c) (a + b - 2 * c) else (2 * c - a - b));
                    break :blk if (pa <= pb and pa <= pc) a else if (pb <= pc) b else c;
                },
                else => return error.UnsupportedPng,
            };
            line[i] = @intCast((@as(u16, line[i]) + filt) & 255);
        }
        @memcpy(prev, line);
        var x: usize = 0;
        while (x < img_w) : (x += 1) {
            const r = line[ch * x];
            const g = line[ch * x + 1];
            const bl = line[ch * x + 2];
            luma_row[x] = @intCast((@as(u16, r) * 77 + @as(u16, g) * 150 + @as(u16, bl) * 29) >> 8);
        }
        if (y > 0) {
            var x2: usize = x0;
            while (x2 < x1) : (x2 += 1) {
                const gx: u16 = if (luma_row[x2 + 1] >= luma_row[x2 - 1]) luma_row[x2 + 1] - luma_row[x2 - 1] else luma_row[x2 - 1] - luma_row[x2 + 1];
                const gy: u16 = if (luma_row[x2] >= luma_prev_row[x2]) luma_row[x2] - luma_prev_row[x2] else luma_prev_row[x2] - luma_row[x2];
                const grad = @as(f64, @floatFromInt(gx + gy));
                total += 1;
                if (grad > 60.0) {
                    edge_n += 1;
                    edge_sum += grad;
                }
            }
        }
        @memcpy(luma_prev_row, luma_row);
    }
    if (edge_n == 0) return error.NoTextFound;
    return .{
        .acutance = edge_sum / @as(f64, @floatFromInt(edge_n)),
        .edge_frac = @as(f64, @floatFromInt(edge_n)) / @as(f64, @floatFromInt(total)),
    };
}

test "retina atlas text stays crisp (no-blur regression)" {
    // Ship builds carry no test hooks: the whole body below is comptime-dead
    // there (same gate pattern as main(), so TEST_HOOKS-only symbols never
    // leak into the ship link) and the test passes trivially. Only the
    // read-test binary executes it. NOTE: do not "fix" this with
    // `return error.Skip` — this toolchain counts a skipped test as failed.
    if (build_options.test_hooks) {
        const t = std.testing;
        const alloc = t.allocator;

        // Prove the render below actually exercises the atlas blit path
        // (rasterizations performed), not a direct-draw fallback.
        var misses0: u64 = 0;
        var tmp: u64 = 0;
        bridge.platform_glyph_cache_stats(&tmp, &misses0, &tmp);
        bridge.platform_set_test_scale(2.0);
        defer bridge.platform_set_test_scale(0.0);
        const rc = bridge.platform_render_to_png(CRISP_PNG_PATH, CRISP_PNG_W, CRISP_PNG_H, crispRenderFn);
        try t.expectEqual(@as(c_int, 0), rc);
        var misses1: u64 = 0;
        bridge.platform_glyph_cache_stats(&tmp, &misses1, &tmp);
        try t.expect(misses1 > misses0);

        const m = try crispPngMetrics(alloc, CRISP_PNG_PATH);
        std.debug.print("\n[CRISP] acutance={d:.1} edge_frac={d:.4}\n", .{ m.acutance, m.edge_frac });
        try t.expect(m.acutance >= CRISP_ACUTANCE_MIN);
        try t.expect(m.edge_frac <= CRISP_EDGE_FRAC_MAX);
    }
}

test "native window tabbing enabled (two-call contract, #49)" {
    // Ship builds carry no test hooks: trivially passes there (same gate
    // pattern as the crisp test above). Only the read-test binary executes
    // it, against the exact helper platform_init uses.
    if (build_options.test_hooks) {
        try std.testing.expectEqual(
            @as(c_int, 1),
            bridge.platform_test_tabbing(),
        );
    }
}

test "cli surface: help/version/dash classification (issue #55)" {
    // Pure classification shared by both binaries; runs everywhere.
    const t = std.testing;
    try t.expect(cliIsHelp("--help"));
    try t.expect(!cliIsHelp("--help=x"));
    try t.expect(!cliIsHelp("-h"));
    try t.expect(!cliIsHelp("--heap"));
    try t.expect(!cliIsHelp(""));
    try t.expect(cliIsVersion("--version"));
    try t.expect(!cliIsVersion("--v"));
    try t.expect(!cliIsVersion("--version=x"));
    try t.expect(cliIsStdinDash("-"));
    try t.expect(!cliIsStdinDash("--"));
    try t.expect(!cliIsStdinDash("-x"));
    try t.expect(!cliIsStdinDash(""));
    // --help/--version/- must not be mistaken for each other.
    try t.expect(!cliIsVersion("--help"));
    try t.expect(!cliIsHelp("--version"));
    try t.expect(!cliIsHelp("-"));
    // Version line carries the single-source version constant.
    try t.expect(std.mem.startsWith(u8, CLI_VERSION_LINE, "read "));
    try t.expect(std.mem.indexOf(u8, CLI_VERSION_LINE, READ_VERSION) != null);
}

test "cli surface: piped-stdin mode decision (issue #55)" {
    // Pipes, redirected files, and sockets carry a document; terminals,
    // /dev/null (char device), directories, and mode 0 keep the welcome doc.
    const t = std.testing;
    const S = std.posix.S;
    try t.expect(stdinCarriesDocument(S.IFIFO));
    try t.expect(stdinCarriesDocument(S.IFREG));
    try t.expect(stdinCarriesDocument(S.IFSOCK));
    try t.expect(!stdinCarriesDocument(S.IFCHR));
    try t.expect(!stdinCarriesDocument(S.IFDIR));
    try t.expect(!stdinCarriesDocument(S.IFBLK));
    try t.expect(!stdinCarriesDocument(S.IFLNK));
    try t.expect(!stdinCarriesDocument(0));
    // Spool bound is a real cap, not zero and not unbounded.
    try t.expect(STDIN_MAX_BYTES == 32 * 1024 * 1024);
}

test "theme follows system, t overrides until next change (#47)" {
    // Pure Zig state machine: no platform needed, runs in every binary.
    const t = std.testing;
    const saved_dark = g_app.is_dark_theme;
    const saved_ov = g_app.theme_override;
    defer {
        g_app.is_dark_theme = saved_dark;
        g_app.theme_override = saved_ov;
    }
    g_app.is_dark_theme = true;
    g_app.theme_override = null;

    onAppearance(0); // system -> light
    try t.expect(!g_app.is_dark_theme);
    try t.expect(g_app.theme_override == null);

    onKey('t', -1); // user override -> dark
    try t.expect(g_app.is_dark_theme);
    try t.expect(g_app.theme_override != null and g_app.theme_override.?);

    onAppearance(0); // system re-affirms light: override cleared, system wins
    try t.expect(!g_app.is_dark_theme);
    try t.expect(g_app.theme_override == null);

    onKey('t', -1); // override again -> dark
    try t.expect(g_app.is_dark_theme);
    onAppearance(1); // system -> dark: override cleared (already in sync)
    try t.expect(g_app.is_dark_theme);
    try t.expect(g_app.theme_override == null);
}

test "appearance mapping contract: DarkAqua dark, Aqua light (#47)" {
    // Ship builds carry no test hooks: trivially passes there (same gate
    // pattern as the crisp test). Only the read-test binary executes it.
    if (build_options.test_hooks) {
        try std.testing.expectEqual(
            @as(c_int, 1),
            bridge.platform_test_appearance(),
        );
    }
}

test "overscroll strip tracks app theme, not system (#104)" {
    // The window background must follow every app-theme change — `t`
    // override, system appearance, first draw — or the rubber-band strip
    // shows the wrong shade. Drives the real sync helper; the platform
    // probe reports the last synced value (headless-safe, no window).
    if (build_options.test_hooks) {
        const t = std.testing;
        const saved_app = g_app.is_dark_theme;
        const saved_sync = g_synced_theme_dark;
        defer {
            g_app.is_dark_theme = saved_app;
            g_synced_theme_dark = saved_sync;
            syncThemeToPlatform();
        }
        g_synced_theme_dark = null;
        g_app.is_dark_theme = true;
        syncThemeToPlatform();
        try t.expectEqual(@as(c_int, 1), bridge.platform_test_theme_synced());
        // Idempotent: no-op re-sync keeps the value.
        syncThemeToPlatform();
        try t.expectEqual(@as(c_int, 1), bridge.platform_test_theme_synced());
        // A `t` override to light (system still dark) must still sync.
        g_app.is_dark_theme = false;
        syncThemeToPlatform();
        try t.expectEqual(@as(c_int, 0), bridge.platform_test_theme_synced());
    }
}

test "plain keys never hijack modified combos (#32)" {
    // The platform modifier gate (macos.m key_combo_plain) decides what
    // reaches on_key. AppKit NSEventModifierFlags, stable documented
    // values; the probe is pure and headless-safe.
    if (build_options.test_hooks) {
        const t = std.testing;
        const shift: c_ulong = 1 << 17;
        const control: c_ulong = 1 << 18;
        const option: c_ulong = 1 << 19;
        const command: c_ulong = 1 << 20;
        const caps: c_ulong = 1 << 16;
        const numpad: c_ulong = 1 << 21;
        try t.expectEqual(@as(c_int, 1), bridge.platform_test_key_plain(0));
        try t.expectEqual(@as(c_int, 1), bridge.platform_test_key_plain(shift));
        try t.expectEqual(@as(c_int, 1), bridge.platform_test_key_plain(caps));
        try t.expectEqual(@as(c_int, 1), bridge.platform_test_key_plain(numpad));
        try t.expectEqual(@as(c_int, 1), bridge.platform_test_key_plain(shift | caps));
        try t.expectEqual(@as(c_int, 0), bridge.platform_test_key_plain(command));
        try t.expectEqual(@as(c_int, 0), bridge.platform_test_key_plain(control));
        try t.expectEqual(@as(c_int, 0), bridge.platform_test_key_plain(option));
        try t.expectEqual(@as(c_int, 0), bridge.platform_test_key_plain(command | shift));
        try t.expectEqual(@as(c_int, 0), bridge.platform_test_key_plain(control | option));
    }
}

test "open file: extension gate, overlay row, bad path keeps doc (#43)" {
    // Extension gate is a pure platform probe (headless-safe); the
    // overlay row is a table entry; a bad path must leave the current
    // document (and its text model) completely untouched.
    if (build_options.test_hooks) {
        const t = std.testing;
        const yes = [_][]const u8{ "a.md", "A.MD", "doc.markdown", "n.mdown", "n.mkd", "r.txt", "R.TEXT" };
        for (yes) |p| {
            try t.expectEqual(@as(c_int, 1), bridge.platform_test_markdown_ext(p.ptr, @intCast(p.len)));
        }
        const no = [_][]const u8{ "a.png", "md", "a.md.bak", "a", ".mdfoo", "a.md " };
        for (no) |p| {
            try t.expectEqual(@as(c_int, 0), bridge.platform_test_markdown_ext(p.ptr, @intCast(p.len)));
        }
        try t.expectEqual(@as(c_int, 0), bridge.platform_test_markdown_ext("", 0));
        var listed = false;
        for (help_overlay.BINDINGS) |b| {
            if (b.key == null and std.mem.eql(u8, b.label, "Cmd+O")) listed = true;
        }
        try t.expect(listed);
        const before_bytes = g_app.bytes;
        const before_lines = g_app.line_count;
        onOpenFile("/nonexistent-dir-xyz/nope.md", 27);
        try t.expectEqual(before_bytes.ptr, g_app.bytes.ptr);
        try t.expectEqual(before_bytes.len, g_app.bytes.len);
        try t.expectEqual(before_lines, g_app.line_count);
        onOpenFile("", 0);
        try t.expectEqual(before_bytes.len, g_app.bytes.len);
    }
}

test "open file swaps document and resets viewport, restores cleanly (#43)" {
    // Positive path with full save/restore: the swap mechanics are
    // deterministic from g_app.bytes (metrics recompute), so restoring
    // the saved fields + one recompute leaves zero trace for other tests.
    if (build_options.test_hooks) {
        const t = std.testing;
        const doc = "# Hi\n\nhello\n";
        const tmp_name = "read_open_test.md";
        const wfd = try std.posix.openat(
            std.posix.AT.FDCWD,
            tmp_name,
            .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
            0o644,
        );
        _ = std.c.write(wfd, doc.ptr, doc.len);
        _ = std.c.close(wfd);
        const s_bytes = g_app.bytes;
        const s_mapped = g_app.mapped_file;
        var s_dir: [2048]u8 = undefined;
        @memcpy(s_dir[0..g_doc_dir.len], g_doc_dir);
        const s_dir_len = g_doc_dir.len;
        const s_scroll = g_app.scroll_y;
        const s_target = g_smooth.target;
        const s_current = g_smooth.current;
        var s_blocks: [MAX_SCROLLABLE_BLOCKS]f32 = undefined;
        var s_maxblocks: [MAX_SCROLLABLE_BLOCKS]f32 = undefined;
        @memcpy(&s_blocks, &g_app.block_scroll_x);
        @memcpy(&s_maxblocks, &g_app.block_max_scroll_x);
        defer {
            // Restore is a re-scan, not a field copy: the swap overwrote
            // the shared lines/refdef/checkpoint buffers, and all three
            // rebuild deterministically from the restored bytes.
            if (g_app.mapped_file) |*m| m.close();
            g_app.mapped_file = s_mapped;
            g_app.bytes = s_bytes;
            var in_fence: simd.FenceState = .{};
            g_app.line_count = simd.scanLines(g_app.bytes, &g_lines_buffer, &in_fence);
            g_app.lines = g_lines_buffer[0..g_app.line_count];
            g_refdef_count = simd.scanRefDefs(g_app.bytes, g_app.lines, &g_refdefs);
            @memcpy(g_doc_dir_buf[0..s_dir_len], s_dir[0..s_dir_len]);
            g_doc_dir = g_doc_dir_buf[0..s_dir_len];
            g_app.scroll_y = s_scroll;
            g_smooth.target = s_target;
            g_smooth.current = s_current;
            @memcpy(&g_app.block_scroll_x, &s_blocks);
            @memcpy(&g_app.block_max_scroll_x, &s_maxblocks);
            updateDocumentMetrics();
            _ = std.c.unlink(tmp_name);
        }
        onOpenFile(tmp_name, @intCast(tmp_name.len));
        try t.expectEqualStrings(doc, g_app.bytes);
        try t.expectEqual(@as(usize, 3), g_app.line_count);
        try t.expectEqual(@as(f32, 0.0), g_app.scroll_y);
        try t.expectEqualStrings("", g_doc_dir);
    }
}

test "external change reloads in place, scroll kept, vanish keeps doc (#44)" {
    // Drives the real onFileChanged against a temp current-document, with
    // the same save/restore discipline as the open test. Watcher arm and
    // disarm go through the platform probe (armless firing needs a run
    // loop, so only arm state is asserted headless).
    if (build_options.test_hooks) {
        const t = std.testing;
        const tmp_name = "read_reload_test.md";
        const v1 = "# One\n";
        var v2_buf: [2048]u8 = undefined;
        var v2_len: usize = 0;
        var li: usize = 0;
        while (li < 200) : (li += 1) {
            const line = "# Line\n";
            @memcpy(v2_buf[v2_len..][0..line.len], line);
            v2_len += line.len;
        }
        const v2 = v2_buf[0..v2_len];
        const wfd = try std.posix.openat(
            std.posix.AT.FDCWD,
            tmp_name,
            .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
            0o644,
        );
        _ = std.c.write(wfd, v1.ptr, v1.len);
        _ = std.c.close(wfd);
        const s_bytes = g_app.bytes;
        const s_mapped = g_app.mapped_file;
        var s_path: [2048]u8 = undefined;
        @memcpy(s_path[0..g_doc_path.len], g_doc_path);
        const s_path_len = g_doc_path.len;
        const s_scroll = g_app.scroll_y;
        const s_target = g_smooth.target;
        const s_current = g_smooth.current;
        defer {
            bridge.platform_unwatch_file();
            if (g_app.mapped_file) |*m| m.close();
            g_app.mapped_file = s_mapped;
            g_app.bytes = s_bytes;
            var in_fence: simd.FenceState = .{};
            g_app.line_count = simd.scanLines(g_app.bytes, &g_lines_buffer, &in_fence);
            g_app.lines = g_lines_buffer[0..g_app.line_count];
            g_refdef_count = simd.scanRefDefs(g_app.bytes, g_app.lines, &g_refdefs);
            @memcpy(g_doc_path_buf[0..s_path_len], s_path[0..s_path_len]);
            g_doc_path = g_doc_path_buf[0..s_path_len];
            g_app.scroll_y = s_scroll;
            g_smooth.target = s_target;
            g_smooth.current = s_current;
            updateDocumentMetrics();
            _ = std.c.unlink(tmp_name);
        }
        setDocPath(tmp_name);
        watchCurrentDocument();
        try t.expectEqual(@as(c_int, 1), bridge.platform_test_watch_active());
        // External modify: content swaps, scroll offset is preserved.
        const afd = try std.posix.openat(
            std.posix.AT.FDCWD,
            tmp_name,
            .{ .ACCMODE = .WRONLY, .TRUNC = true },
            0o644,
        );
        _ = std.c.write(afd, v2.ptr, v2.len);
        _ = std.c.close(afd);
        g_app.scroll_y = 40.0;
        onFileChanged();
        try t.expectEqualStrings(v2, g_app.bytes);
        try t.expectEqual(@as(usize, 200), g_app.line_count);
        try t.expectEqual(@as(f32, 40.0), g_app.scroll_y);
        // Vanished file: the last good document stays, no crash.
        _ = std.c.unlink(tmp_name);
        onFileChanged();
        try t.expectEqualStrings(v2, g_app.bytes);
        // Empty path disarms.
        setDocPath("");
        watchCurrentDocument();
        try t.expectEqual(@as(c_int, 0), bridge.platform_test_watch_active());
    }
}

test "find: query, cycle, close state machine (#42)" {
    // Drives the real callbacks against a static doc (save/restore keeps
    // other tests hermetic). Scroll assertions stay coarse: exact landing
    // is pinned headless by the --find probes and by findOffsetY below.
    if (build_options.test_hooks) {
        const t = std.testing;
        const doc = "foo bar foo\nbaz foo\n";
        const s_bytes = g_app.bytes;
        const s_mapped = g_app.mapped_file;
        defer {
            if (g_app.mapped_file) |*m| m.close();
            g_app.mapped_file = s_mapped;
            g_app.bytes = s_bytes;
            var in_fence: simd.FenceState = .{};
            g_app.line_count = simd.scanLines(g_app.bytes, &g_lines_buffer, &in_fence);
            g_app.lines = g_lines_buffer[0..g_app.line_count];
            g_refdef_count = simd.scanRefDefs(g_app.bytes, g_app.lines, &g_refdefs);
            updateDocumentMetrics();
            clearFind();
        }
        g_app.mapped_file = null;
        g_app.bytes = doc;
        var in_fence: simd.FenceState = .{};
        g_app.line_count = simd.scanLines(doc, &g_lines_buffer, &in_fence);
        g_app.lines = g_lines_buffer[0..g_app.line_count];
        g_refdef_count = 0;
        updateDocumentMetrics();
        onFindQuery("foo", 3);
        try t.expectEqual(@as(usize, 3), g_find_count);
        try t.expectEqual(@as(usize, 0), g_find_current);
        try t.expectEqualStrings("foo", g_find_query[0..g_find_query_len]);
        onFindNext(0);
        try t.expectEqual(@as(usize, 1), g_find_current);
        onFindNext(0);
        try t.expectEqual(@as(usize, 2), g_find_current);
        onFindNext(0); // wraps to first
        try t.expectEqual(@as(usize, 0), g_find_current);
        onFindNext(1); // previous wraps to last
        try t.expectEqual(@as(usize, 2), g_find_current);
        onFindNext(0);
        try t.expectEqual(@as(usize, 0), g_find_current);
        // Empty query and misses clear the match list, never crash.
        onFindQuery("", 0);
        try t.expectEqual(@as(usize, 0), g_find_count);
        onFindNext(0);
        try t.expectEqual(@as(usize, 0), g_find_current);
        onFindQuery("zzz", 3);
        try t.expectEqual(@as(usize, 0), g_find_count);
        // Newlines truncate (single-line field); overlay lists Cmd+F.
        onFindQuery("foo\nbar", 7);
        try t.expectEqual(@as(usize, 3), g_find_count);
        var listed = false;
        for (help_overlay.BINDINGS) |b| {
            if (b.key == null and std.mem.eql(u8, b.label, "Cmd+F")) listed = true;
        }
        try t.expect(listed);
        onFindClosed();
        try t.expectEqual(@as(usize, 0), g_find_count);
        try t.expectEqual(@as(usize, 0), g_find_query_len);
    }
}

test "find washes differ per theme and from mark (#42)" {
    const t = std.testing;
    for ([2]layout.Theme{ layout.Theme.dark, layout.Theme.light }) |th| {
        try t.expect(!std.meta.eql(th.find_bg, th.bg));
        try t.expect(!std.meta.eql(th.find_current, th.bg));
        try t.expect(!std.meta.eql(th.find_current, th.find_bg));
        try t.expect(!std.meta.eql(th.find_bg, th.mark_bg));
        try t.expect(!std.meta.eql(th.find_current, th.mark_bg));
    }
}

test "cheatsheet overlay: ? toggles, Esc dismisses, unknown keys no-op" {
    // Drives the real onKey dispatch (same table the overlay lists), but
    // only through side-effect-free actions: no scroll (needs the platform
    // timer), no theme flip, no quit. Runs in the exe test binaries.
    const prev = g_show_help;
    defer g_show_help = prev;
    g_show_help = false;
    onKey('?', -1);
    try std.testing.expect(g_show_help);
    onKey('?', -1);
    try std.testing.expect(!g_show_help);
    onKey('?', -1);
    onKey(27, -1);
    try std.testing.expect(!g_show_help);
    onKey('z', -1);
    try std.testing.expect(!g_show_help);
    // Overlay paint path runs headless without crashing (platform draws
    // early-return with no live context; geometry is pinned in
    // help_overlay.zig tests).
    g_show_help = true;
    drawHelpOverlay();
}

test "remote images: i toggles through the shared key table" {
    // Drives the real onKey dispatch (same table row the overlay and the
    // indicator name). updateDocumentMetrics/snapScroll are pure layout
    // math, safe headless. Runs in the exe test binaries.
    const prev = g_app.remote_images;
    defer g_app.remote_images = prev;
    g_app.remote_images = true;
    onKey('i', -1);
    try std.testing.expect(!g_app.remote_images);
    onKey('i', -1);
    try std.testing.expect(g_app.remote_images);
}

test "link routing: anchors, local .md, external (#46)" {
    const t = std.testing;
    // Anchors scroll in-app (bare `#` = top, same as empty fragment).
    try t.expectEqual(LinkKind.anchor, classifyLink("#section"));
    try t.expectEqual(LinkKind.anchor, classifyLink("#"));
    // Local .md files open in the same window (case, nesting, fragment).
    try t.expectEqual(LinkKind.md_file, classifyLink("other.md"));
    try t.expectEqual(LinkKind.md_file, classifyLink("./sub/doc.MD"));
    try t.expectEqual(LinkKind.md_file, classifyLink("../a/b.markdown"));
    try t.expectEqual(LinkKind.md_file, classifyLink("other.md#sec"));
    try t.expectEqual(LinkKind.md_file, classifyLink("/abs/path.md"));
    try t.expectEqual(LinkKind.md_file, classifyLink("file:///abs/path.md"));
    try t.expectEqual(LinkKind.md_file, classifyLink("other.md?x=1"));
    // External http(s) is unchanged — even an .md URL on the web.
    try t.expectEqual(LinkKind.external, classifyLink("https://example.com/x.md"));
    try t.expectEqual(LinkKind.external, classifyLink("HTTP://EXAMPLE.COM/"));
    try t.expectEqual(LinkKind.external, classifyLink("mailto:foo@bar.com"));
    try t.expectEqual(LinkKind.external, classifyLink("ftp://h/x.md"));
    // Non-md locals keep the open-externally path.
    try t.expectEqual(LinkKind.external, classifyLink("image.png"));
    try t.expectEqual(LinkKind.external, classifyLink(""));
    // Target splitting: path + fragment for the in-place opener.
    const a = splitLinkTarget("other.md#sec");
    try t.expectEqualStrings("other.md", a.path);
    try t.expectEqualStrings("sec", a.frag);
    const b = splitLinkTarget("sub/a.md?x=1#f");
    try t.expectEqualStrings("sub/a.md", b.path);
    try t.expectEqualStrings("f", b.frag);
    const c = splitLinkTarget("file:///abs/p.md");
    try t.expectEqualStrings("/abs/p.md", c.path);
    try t.expectEqualStrings("", c.frag);
    // Doc-relative resolution against the open file's directory.
    const saved_dir = g_doc_dir;
    var saved_buf: [2048]u8 = undefined;
    @memcpy(saved_buf[0..saved_dir.len], saved_dir);
    defer g_doc_dir = saved_buf[0..saved_dir.len];
    setDocDir("/docs/sub/file.md");
    var rbuf: [128]u8 = undefined;
    try t.expectEqualStrings("/docs/sub/other.md", resolveDocPath("other.md", &rbuf).?);
    try t.expectEqualStrings("/docs/sub/sub/nested.md", resolveDocPath("sub/nested.md", &rbuf).?);
    try t.expectEqualStrings("/abs/x.md", resolveDocPath("/abs/x.md", &rbuf).?);
    try t.expect(resolveDocPath("", &rbuf) == null);
}
test "image completeness contracts: doc-dir resolve + URL session (#45)" {
    // Ship builds carry no test hooks: trivially passes there (same gate
    // pattern as the crisp test). Only the read-test binary executes it.
    if (build_options.test_hooks) {
        const t = std.testing;
        // Doc-dir join: ("/","tmp") exists on any macOS; nonsense does not.
        try t.expectEqual(
            @as(c_int, 1),
            bridge.platform_test_image_resolve("/", 1, "tmp", 3),
        );
        try t.expectEqual(
            @as(c_int, 0),
            bridge.platform_test_image_resolve("/", 1, "read-definitely-missing-zzz", 25),
        );
        try t.expectEqual(@as(c_int, -1), bridge.platform_test_image_resolve("", 0, "tmp", 3));
        // Session: shared, ephemeral, no shared cache, bounded timeouts.
        try t.expectEqual(@as(c_int, 1), bridge.platform_test_image_session());
    }
}

fn outlineFilterCase(text: []const u8, filter: []const u8) c_int {
    return bridge.platform_test_outline_filter(
        text.ptr,
        @intCast(text.len),
        filter.ptr,
        @intCast(filter.len),
    );
}

test "outline picker contracts: filter + panel build (#48)" {
    // Ship builds carry no test hooks: trivially passes there (same gate
    // pattern as the crisp test). Only the read-test binary executes it.
    if (build_options.test_hooks) {
        const t = std.testing;
        // Plain-substring filter: case-insensitive, empty matches all.
        try t.expectEqual(@as(c_int, 1), outlineFilterCase("Hello World", "hello"));
        try t.expectEqual(@as(c_int, 1), outlineFilterCase("Hello World", "WORLD"));
        try t.expectEqual(@as(c_int, 1), outlineFilterCase("Hello World", ""));
        try t.expectEqual(@as(c_int, 1), outlineFilterCase("abc", "b"));
        try t.expectEqual(@as(c_int, 0), outlineFilterCase("Hello World", "xyz"));
        try t.expectEqual(@as(c_int, 0), outlineFilterCase("Hi", "hello"));
        // Panel construction: two adds build two native rows headlessly.
        try t.expectEqual(@as(c_int, 1), bridge.platform_test_outline_build());
    }
}
