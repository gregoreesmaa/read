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
var g_lines_buffer: [MAX_LINES]simd.Line = undefined;
var g_commands_buffer: [MAX_COMMANDS]layout.DrawCommand = undefined;
var g_scroll_lock: layout.ScrollLockState = .{};

const MAX_CHECKPOINTS = 2048;
var g_checkpoints: [MAX_CHECKPOINTS]layout.Checkpoint = undefined;
var g_checkpoint_count: usize = 0;

fn getTimestampMs() i64 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

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

    const vp_config = layout.ViewportConfig{
        .window_width = g_app.window_width,
        .window_height = g_app.window_height,
        .scroll_y = g_app.scroll_y,
        .block_scroll_x = g_app.block_scroll_x,
        .is_dark_theme = g_app.is_dark_theme,
        .checkpoints = g_checkpoints[0..g_checkpoint_count],
        .image_size_fn = bridge.platform_get_image_size,
    };

    const cmd_count = layout.layoutViewport(
        g_app.bytes,
        g_app.lines[0..g_app.line_count],
        vp_config,
        &g_commands_buffer,
    );

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
}

pub fn main(init: std.process.Init.Minimal) !void {
    var in_fence = false;
    var file_path: ?[]const u8 = null;

    // Parse command line arguments
    var args_it = std.process.Args.Iterator.init(init.args);
    _ = args_it.next(); // skip exe name
    var screenshot_path: ?[*:0]const u8 = null;
    var dump_records = false;

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--screenshot")) {
            if (args_it.next()) |sc_path| {
                screenshot_path = @ptrCast(sc_path.ptr);
            }
        } else if (std.mem.eql(u8, arg, "--scroll")) {
            if (args_it.next()) |sc_str| {
                g_app.scroll_y = std.fmt.parseFloat(f32, sc_str) catch 0.0;
            }
        } else if (std.mem.eql(u8, arg, "--damage")) {
            // Headless parity-test hook (needs -Dtest-hooks): inject
            // synthetic pending damage. Compiled out of ship builds.
            if (build_options.test_hooks) {
                if (args_it.next()) |dmg_str| {
                    var it = std.mem.splitScalar(u8, dmg_str, ',');
                    const dx = std.fmt.parseFloat(f32, it.next() orelse "0") catch 0.0;
                    const dy = std.fmt.parseFloat(f32, it.next() orelse "0") catch 0.0;
                    const dw = std.fmt.parseFloat(f32, it.next() orelse "0") catch 0.0;
                    const dh = std.fmt.parseFloat(f32, it.next() orelse "0") catch 0.0;
                    bridge.platform_set_test_damage(dx, dy, dw, dh, 1);
                }
            } else {
                file_path = arg;
            }
        } else if (std.mem.eql(u8, arg, "--dump-records")) {
            if (build_options.test_hooks) {
                dump_records = true;
            } else {
                file_path = arg;
            }
        } else if (std.mem.eql(u8, arg, "--select")) {
            // Headless selection screenshot: doc-space endpoints x1,y1,x2,y2.
            if (build_options.test_hooks) {
                if (args_it.next()) |sel_str| {
                    var it = std.mem.splitScalar(u8, sel_str, ',');
                    const x1 = std.fmt.parseFloat(f32, it.next() orelse "0") catch 0.0;
                    const y1 = std.fmt.parseFloat(f32, it.next() orelse "0") catch 0.0;
                    const x2 = std.fmt.parseFloat(f32, it.next() orelse "0") catch 0.0;
                    const y2 = std.fmt.parseFloat(f32, it.next() orelse "0") catch 0.0;
                    bridge.platform_set_test_selection(x1, y1, x2, y2, 1);
                }
            } else {
                file_path = arg;
            }
        } else {
            file_path = arg;
        }
    }

    if (file_path) |path| {
        const mapped = mmap.MappedFile.open(path) catch |err| {
            std.debug.print("Failed to open file '{s}': {any}\n", .{ path, err });
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
        const rc = bridge.platform_render_to_png(sc_path, 1200, 900, onDraw);
        if (rc == 0) {
            std.debug.print("Screenshot successfully generated: {s}\n", .{sc_path});
            if (build_options.test_hooks and dump_records) {
                std.debug.print("Text records rebuilt: {d}\n", .{bridge.platform_text_record_count()});
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
    };

    _ = bridge.platform_init("Read", 1000, 750, callbacks);
    bridge.platform_run_loop();
}
