const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const mmap = @import("core/mmap.zig");
const simd = @import("core/simd.zig");
const parser = @import("core/parser.zig");
const layout = @import("layout/viewport.zig");
const damage = @import("layout/damage.zig");
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
var g_lines_buffer: [MAX_LINES]simd.Line = undefined;
var g_commands_buffer: [MAX_COMMANDS]layout.DrawCommand = undefined;
var g_scroll_lock: layout.ScrollLockState = .{};
// Smooth-scroll animation state: inputs retarget, a 120Hz platform tick
// eases g_app.scroll_y (displayed) toward the target. Anchor jumps and
// resizes snap both so they stay 1:1.
var g_smooth: layout.SmoothScroll = .{};

/// Retarget the animated scroll offset and arm the platform tick while the
/// displayed offset is still settling. No-op when already settled.
fn retargetScroll(target: f32) void {
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
    const locked = g_scroll_lock.processScroll(delta_x, delta_y, hovered_block_id, now_ms);

    if (locked.dy != 0.0) {
        // Routing (precise 1:1 vs eased wheel) lives in
        // SmoothScroll.applyScrollDelta, pinned by strict tests; the full
        // rationale is documented there. Sync the displayed offset, then arm
        // the tick while unsettled (snaps settle synchronously, no timer).
        g_smooth = layout.SmoothScroll.applyScrollDelta(
            g_smooth.target,
            g_smooth.current,
            locked.dy,
            precise != 0,
            g_app.max_scroll_y,
        );
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
    g_smooth.setTarget(g_smooth.target, g_app.max_scroll_y);
    const settled = g_smooth.tick(dt_ms / 1000.0);
    g_app.scroll_y = g_smooth.current;
    return if (settled) 0 else 1;
}

fn updateDocumentMetrics() void {
    const vp_config = layout.ViewportConfig{
        .window_width = g_app.window_width,
        .window_height = g_app.window_height,
        .scroll_y = 0.0,
        .image_size_fn = bridge.platform_get_image_size,
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

fn onResize(w: c_int, h: c_int) callconv(.c) void {
    g_app.window_width = @floatFromInt(w);
    g_app.window_height = @floatFromInt(h);
    updateDocumentMetrics();
    snapScroll(g_app.scroll_y);
}

fn onLink(url_ptr: [*]const u8, url_len: c_int) callconv(.c) void {
    if (url_len <= 0) return;
    const url = url_ptr[0..@as(usize, @intCast(url_len))];
    // External links stay in the platform layer; only `#fragment`
    // section links scroll in-document.
    if (url.len == 0 or url[0] != '#') return;
    const frag = url[1..];
    const vp_config = layout.ViewportConfig{
        .window_width = g_app.window_width,
        .window_height = g_app.window_height,
        .scroll_y = 0.0,
        .image_size_fn = bridge.platform_get_image_size,
        .ref_defs = g_refdefs[0..g_refdef_count],
        .entities = &g_entities,
        .join_buf = &g_joinbuf,
    };
    const target = layout.anchorScrollY(
        g_app.bytes,
        g_app.lines[0..g_app.line_count],
        vp_config,
        frag,
    ) orelse return;
    snapScroll(target);
    bridge.platform_request_redraw();
}

fn onKey(key_code: c_int, hovered_block_id: c_int) callconv(.c) void {
    switch (key_code) {
        'j' => {
            retargetScroll(g_smooth.target + 40.0);
        },
        'k' => {
            retargetScroll(g_smooth.target - 40.0);
        },
        'h' => {
            if (hovered_block_id >= 0 and hovered_block_id < MAX_SCROLLABLE_BLOCKS) {
                const id: usize = @intCast(hovered_block_id);
                g_app.block_scroll_x[id] = std.math.clamp(
                    g_app.block_scroll_x[id] - 30.0,
                    0.0,
                    g_app.block_max_scroll_x[id],
                );
            }
        },
        'l' => {
            if (hovered_block_id >= 0 and hovered_block_id < MAX_SCROLLABLE_BLOCKS) {
                const id: usize = @intCast(hovered_block_id);
                g_app.block_scroll_x[id] = std.math.clamp(
                    g_app.block_scroll_x[id] + 30.0,
                    0.0,
                    g_app.block_max_scroll_x[id],
                );
            }
        },
        ' ' => {
            retargetScroll(g_smooth.target + g_app.window_height * 0.8);
        },
        't' => {
            g_app.is_dark_theme = !g_app.is_dark_theme;
        },
        'q' => {
            std.c.exit(0);
        },
        else => {},
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

    bridge.platform_sync_scroll(g_app.scroll_y);
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
        .block_scroll_x = g_app.block_scroll_x,
        .is_dark_theme = g_app.is_dark_theme,
        .checkpoints = g_checkpoints[0..g_checkpoint_count],
        .image_size_fn = bridge.platform_get_image_size,
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
            std.debug.print("CMD {s} {d:.1} {d:.1} {d:.1} {d:.1} kept={d} rgb={d},{d},{d} len={d} fs={d:.1} txt='{s}'\n", .{
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
                bridge.platform_register_scrollable_block(
                    cmd.scrollable_id,
                    cmd.rect.x,
                    cmd.rect.y,
                    cmd.rect.w,
                    cmd.rect.h,
                    cmd.max_scroll_x,
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
                    cmd.color.r,
                    cmd.color.g,
                    cmd.color.b,
                    cmd.color.a,
                    url_ptr,
                    url_len,
                );
            },
            .image => {
                if (!dmg.keeps(cmd.rect.x, cmd.rect.y, cmd.rect.w, cmd.rect.h)) continue;
                const url_ptr = if (cmd.link_target) |t| t.ptr else null;
                const url_len: c_int = if (cmd.link_target) |t| @intCast(t.len) else 0;
                bridge.platform_draw_image(
                    url_ptr,
                    url_len,
                    cmd.rect.x,
                    cmd.rect.y,
                    cmd.rect.w,
                    cmd.rect.h,
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

pub fn main(init: std.process.Init.Minimal) !void {
    var in_fence = false;
    var file_path: ?[]const u8 = null;

    // Parse command line arguments.
    // Production ships a positional document path only. The whole headless
    // test CLI (--screenshot, --scroll, --scroll-sweep, --damage,
    // --dump-*, --select*, --probe-px, --force-scale, --settle-images)
    // lives behind ONE comptime gate so the ship binary contains none of
    // it; it runs only in the read-test binary. Trust the compiler.
    var args_it = std.process.Args.Iterator.init(init.args);
    _ = args_it.next(); // skip exe name
    var screenshot_path: ?[*:0]const u8 = null;
    var dump_records = false;
    var settle_images_ms: i64 = 0;

    if (!build_options.test_hooks) {
        // Production owns no test flags; the reset stores keep the hook
        // vars observably settled on this path.
        screenshot_path = null;
        dump_records = false;
        settle_images_ms = 0;
        while (args_it.next()) |arg| {
            if (std.mem.startsWith(u8, arg, "--")) {
                const pre = "Unknown option (testing flags live in read-test): ";
                _ = std.c.write(std.posix.STDERR_FILENO, pre, pre.len);
                _ = std.c.write(std.posix.STDERR_FILENO, arg.ptr, arg.len);
                _ = std.c.write(std.posix.STDERR_FILENO, "\n", 1);
                std.c.exit(2);
            }
            file_path = arg;
        }
    } else {
        while (args_it.next()) |arg| {
            if (std.mem.eql(u8, arg, "--screenshot")) {
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
            if (!std.mem.startsWith(u8, arg, "--")) file_path = arg;
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
                }
            }
        }
        } // end while (test CLI arg parse)
    } // end test-CLI else (ship builds skip all of the above)

    if (file_path) |path| {
        const mapped = mmap.MappedFile.open(path) catch {
            // Ship-safe error path: raw writes only, so no std.fmt
            // error-formatting machinery is linked into ship builds.
            const pre = "Failed to open file: ";
            _ = std.c.write(std.posix.STDERR_FILENO, pre, pre.len);
            _ = std.c.write(std.posix.STDERR_FILENO, path.ptr, path.len);
            const nl = "\n";
            _ = std.c.write(std.posix.STDERR_FILENO, nl, nl.len);
            return;
        };
        g_app.mapped_file = mapped;
        g_app.bytes = mapped.bytes;
    } else {
        g_app.bytes = DEFAULT_DOC;
    }

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
