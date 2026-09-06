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
// Headless command-stream probe flag (set by --dump-commands under TEST_HOOKS).
var g_dump_commands: bool = false;
var g_lines_buffer: [MAX_LINES]simd.Line = undefined;
var g_commands_buffer: [MAX_COMMANDS]layout.DrawCommand = undefined;
var g_scroll_lock: layout.ScrollLockState = .{};

const MAX_CHECKPOINTS = 2048;
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

// Headless scroll-sweep profiler state (needs -Dtest-hooks): renders a
// range of scroll offsets in one process — caches stay warm exactly like
// live scrolling — and prints per-offset phase timings. Compiled out of
// ship builds.
var g_sweep_active: bool = false;
var g_sweep_from: f32 = 0.0;
var g_sweep_to: f32 = 0.0;
var g_sweep_step: f32 = 0.0;

// Two-phase drag-back residue test state (needs -Dtest-hooks): selection A
// then shrink to B, painted incrementally on one bitmap. See --select-drag.
var g_drag_active: bool = false;
// First-paint gate for deferred image decodes (see platform_arm_images):
// image records park until the first frame is committed, then decode.
// Headless one-shot screenshots never arm (deterministic placeholders).
var g_first_paint_done: bool = false;
var g_headless_oneshot: bool = false;
var g_drag_vals: [8]f32 = [_]f32{0.0} ** 8;

fn onScroll(delta_x: f32, delta_y: f32, hovered_block_id: c_int) callconv(.c) void {
    const now_ms = getTimestampMs();
    const locked = g_scroll_lock.processScroll(delta_x, delta_y, hovered_block_id, now_ms);

    if (locked.dy != 0.0) {
        g_app.scroll_y = std.math.clamp(g_app.scroll_y - locked.dy, 0.0, g_app.max_scroll_y);
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

fn updateDocumentMetrics() void {
    const vp_config = layout.ViewportConfig{
        .window_width = g_app.window_width,
        .window_height = g_app.window_height,
        .scroll_y = 0.0,
        .image_size_fn = bridge.platform_get_image_size,
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
    g_app.scroll_y = std.math.clamp(g_app.scroll_y, 0.0, g_app.max_scroll_y);
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
    };
    const target = layout.anchorScrollY(
        g_app.bytes,
        g_app.lines[0..g_app.line_count],
        vp_config,
        frag,
    ) orelse return;
    g_app.scroll_y = std.math.clamp(target, 0.0, g_app.max_scroll_y);
    bridge.platform_request_redraw();
}

fn onKey(key_code: c_int, hovered_block_id: c_int) callconv(.c) void {
    switch (key_code) {
        'j' => {
            g_app.scroll_y = std.math.clamp(g_app.scroll_y + 40.0, 0.0, g_app.max_scroll_y);
        },
        'k' => {
            g_app.scroll_y = std.math.clamp(g_app.scroll_y - 40.0, 0.0, g_app.max_scroll_y);
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
            g_app.scroll_y = std.math.clamp(g_app.scroll_y + g_app.window_height * 0.8, 0.0, g_app.max_scroll_y);
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
    const vp_config = layout.ViewportConfig{
        .window_width = g_app.window_width,
        .window_height = g_app.window_height,
        .scroll_y = g_app.scroll_y,
        .block_scroll_x = g_app.block_scroll_x,
        .is_dark_theme = g_app.is_dark_theme,
        .checkpoints = g_checkpoints[0..g_checkpoint_count],
        .image_size_fn = bridge.platform_get_image_size,
        .ordered_markers = &g_markers,
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

    // Headless layout probe (needs -Dtest-hooks): dump the emitted command
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
        const progress = g_app.scroll_y / g_app.max_scroll_y;
        const bar_height: f32 = 40.0;
        const bar_y = progress * (g_app.window_height - bar_height);
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

    // Scroll-sweep profiler row (needs -Dtest-hooks): per-offset phase
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

    // Parse command line arguments
    var args_it = std.process.Args.Iterator.init(init.args);
    _ = args_it.next(); // skip exe name
    var screenshot_path: ?[*:0]const u8 = null;
    var dump_records = false;
    var settle_images_ms: i64 = 0;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--screenshot")) {
            if (args_it.next()) |sc_path| {
                screenshot_path = @ptrCast(sc_path.ptr);
            }
        } else if (std.mem.eql(u8, arg, "--scroll")) {
            if (args_it.next()) |sc_str| {
                g_app.scroll_y = parseF32(sc_str);
            }
        } else {
            // Document paths land in file_path from any position; hook
            // flags (and their consumed values, taken above) never do, so
            // a missing document still falls back to the default doc.
            if (!std.mem.startsWith(u8, arg, "--")) file_path = arg;
            // Headless test-hooks matching (needs -Dtest-hooks): ONE
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
    }

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

    // Compute accurate total document height and max scroll limit
    updateDocumentMetrics();

    // Headless screenshot mode
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
        // Drag-back residue test (needs -Dtest-hooks): incremental repaint
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
        // Scroll-sweep profiler (needs -Dtest-hooks): one render per offset,
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

    const callbacks = bridge.PlatformCallbacks{
        .on_scroll = onScroll,
        .on_resize = onResize,
        .on_key = onKey,
        .on_draw = onDraw,
        .on_link = onLink,
    };

    _ = bridge.platform_init("Read", 1000, 750, callbacks);
    bridge.platform_run_loop();
}
