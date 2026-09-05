const std = @import("std");
const builtin = @import("builtin");
const mmap = @import("core/mmap.zig");
const simd = @import("core/simd.zig");
const parser = @import("core/parser.zig");
const layout = @import("layout/viewport.zig");
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

pub const AppState = struct {
    bytes: []const u8 = "",
    mapped_file: ?mmap.MappedFile = null,
    lines: []simd.Line = &.{},
    line_count: usize = 0,
    window_width: f32 = 1000.0,
    window_height: f32 = 750.0,
    scroll_y: f32 = 0.0,
    max_scroll_y: f32 = 0.0,
    table_scroll_x: f32 = 0.0,
    is_dark_theme: bool = true,
};

var g_app: AppState = .{};
var g_lines_buffer: [MAX_LINES]simd.Line = undefined;
var g_commands_buffer: [MAX_COMMANDS]layout.DrawCommand = undefined;

fn onScroll(delta_x: f32, delta_y: f32) callconv(.c) void {
    g_app.scroll_y = std.math.clamp(g_app.scroll_y - delta_y, 0.0, g_app.max_scroll_y);
    if (delta_x != 0.0) {
        g_app.table_scroll_x = @max(0.0, g_app.table_scroll_x - delta_x);
    }
}

fn onResize(w: c_int, h: c_int) callconv(.c) void {
    g_app.window_width = @floatFromInt(w);
    g_app.window_height = @floatFromInt(h);
}

fn onKey(key_code: c_int) callconv(.c) void {
    switch (key_code) {
        'j' => {
            g_app.scroll_y = std.math.clamp(g_app.scroll_y + 40.0, 0.0, g_app.max_scroll_y);
        },
        'k' => {
            g_app.scroll_y = std.math.clamp(g_app.scroll_y - 40.0, 0.0, g_app.max_scroll_y);
        },
        'h' => {
            g_app.table_scroll_x = @max(0.0, g_app.table_scroll_x - 30.0);
        },
        'l' => {
            g_app.table_scroll_x += 30.0;
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
    g_app.window_width = @floatFromInt(w);
    g_app.window_height = @floatFromInt(h);

    bridge.platform_sync_scroll(g_app.scroll_y);

    const vp_config = layout.ViewportConfig{
        .window_width = g_app.window_width,
        .window_height = g_app.window_height,
        .scroll_y = g_app.scroll_y,
        .table_scroll_x = g_app.table_scroll_x,
        .is_dark_theme = g_app.is_dark_theme,
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
            .code_block_bg => {
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
                bridge.platform_register_code_block(
                    cmd.rect.x,
                    cmd.rect.y,
                    cmd.rect.w,
                    cmd.rect.h,
                    cmd.text.ptr,
                    @intCast(cmd.text.len),
                );
            },
            .line => {
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

                const url_ptr = if (cmd.link_target) |t| t.ptr else null;
                const url_len: c_int = if (cmd.link_target) |t| @intCast(t.len) else 0;

                bridge.platform_draw_text(
                    cmd.text.ptr,
                    @intCast(cmd.text.len),
                    cmd.rect.x,
                    cmd.rect.y,
                    cmd.font_size,
                    is_bold,
                    is_italic,
                    is_mono,
                    cmd.color.r,
                    cmd.color.g,
                    cmd.color.b,
                    cmd.color.a,
                    url_ptr,
                    url_len,
                );
            },
        }
    }

    // Draw minimalist ambient reading progress indicator (thin 2px filament on right)
    if (g_app.max_scroll_y > 0) {
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

    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--screenshot")) {
            if (args_it.next()) |sc_path| {
                screenshot_path = @ptrCast(sc_path.ptr);
            }
        } else if (std.mem.eql(u8, arg, "--scroll")) {
            if (args_it.next()) |sc_str| {
                g_app.scroll_y = std.fmt.parseFloat(f32, sc_str) catch 0.0;
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

    // Compute estimated total document height
    const total_height = @as(f32, @floatFromInt(g_app.line_count)) * 28.0;
    g_app.max_scroll_y = @max(0.0, total_height - g_app.window_height + 400.0);

    // Headless screenshot mode
    if (screenshot_path) |sc_path| {
        g_app.window_width = 1200.0;
        g_app.window_height = 900.0;
        const rc = bridge.platform_render_to_png(sc_path, 1200, 900, onDraw);
        if (rc == 0) {
            std.debug.print("Screenshot successfully generated: {s}\n", .{sc_path});
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
