const std = @import("std");
const simd = @import("../core/simd.zig");
const parser = @import("../core/parser.zig");

// Calibrated ASCII advance widths for Apple SF Pro system font (in 1/1000 em)
pub const SYSTEM_FONT_WIDTHS = [128]u16{
    // 0-7
    0, 0, 0, 0, 0, 0, 0, 0,
    // 8-15
    0, 0, 0, 0, 0, 0, 0, 0,
    // 16-23
    0, 0, 0, 0, 0, 0, 0, 0,
    // 24-31
    0, 0, 0, 0, 0, 0, 0, 0,
    // 32-39: space ! " # $ % & '
    256, 286, 453, 605, 605, 900, 687, 272,
    // 40-47: ( ) * + , - . /
    357, 357, 447, 605, 272, 447, 272, 280,
    // 48-55: 0 1 2 3 4 5 6 7
    605, 439, 579, 602, 619, 593, 612, 544,
    // 56-63: 8 9 : ; < = > ?
    614, 612, 272, 272, 605, 605, 605, 488,
    // 64-71: @ A B C D E F G
    893, 649, 632, 691, 702, 571, 547, 722,
    // 72-79: H I J K L M N O
    717, 243, 513, 634, 543, 849, 717, 747,
    // 80-87: P Q R S T U V W
    610, 747, 628, 612, 609, 712, 649, 943,
    // 88-95: X Y Z [ \ ] ^ _
    654, 630, 637, 357, 280, 357, 605, 559,
    // 96-103: ` a b c d e f g
    475, 527, 589, 535, 589, 546, 337, 584,
    // 104-111: h i j k l m n o
    563, 222, 222, 518, 228, 845, 559, 566,
    // 112-119: p q r s t u v w
    585, 584, 356, 499, 338, 559, 517, 750,
    // 120-127: x y z { | } ~ DEL
    500, 518, 514, 357, 234, 357, 605, 0,
};

pub const SYSTEM_FONT_BOLD_WIDTHS = [128]u16{
    // 0-7
    0, 0, 0, 0, 0, 0, 0, 0,
    // 8-15
    0, 0, 0, 0, 0, 0, 0, 0,
    // 16-23
    0, 0, 0, 0, 0, 0, 0, 0,
    // 24-31
    0, 0, 0, 0, 0, 0, 0, 0,
    // 32-39: space ! " # $ % & '
    256, 331, 544, 646, 646, 1011, 719, 323,
    // 40-47: ( ) * + , - . /
    404, 404, 459, 646, 323, 459, 323, 310,
    // 48-55: 0 1 2 3 4 5 6 7
    660, 487, 618, 644, 662, 638, 659, 580,
    // 56-63: 8 9 : ; < = > ?
    669, 659, 323, 323, 646, 646, 646, 532,
    // 64-71: @ A B C D E F G
    902, 708, 668, 716, 722, 597, 573, 735,
    // 72-79: H I J K L M N O
    758, 293, 576, 684, 570, 882, 743, 761,
    // 80-87: P Q R S T U V W
    649, 761, 669, 650, 635, 735, 696, 984,
    // 88-95: X Y Z [ \ ] ^ _
    705, 683, 651, 404, 310, 404, 646, 602,
    // 96-103: ` a b c d e f g
    475, 565, 626, 563, 626, 576, 383, 620,
    // 104-111: h i j k l m n o
    607, 262, 262, 576, 270, 907, 602, 595,
    // 112-119: p q r s t u v w
    622, 623, 410, 542, 388, 602, 558, 822,
    // 120-127: x y z { | } ~ DEL
    556, 572, 542, 404, 274, 404, 646, 0,
};

pub fn measureChar(c: u8, font_size: f32, is_bold: bool, is_mono: bool) f32 {
    if (is_mono) return font_size * 0.60;
    const idx = if (c < 128) c else 32;
    const width_table = if (is_bold) SYSTEM_FONT_BOLD_WIDTHS else SYSTEM_FONT_WIDTHS;
    return @as(f32, @floatFromInt(width_table[idx])) * font_size / 1000.0;
}

pub fn measureText(text: []const u8, font_size: f32, is_bold: bool, is_mono: bool) f32 {
    if (is_mono) return @as(f32, @floatFromInt(text.len)) * font_size * 0.60;
    var total: f32 = 0;
    const width_table = if (is_bold) SYSTEM_FONT_BOLD_WIDTHS else SYSTEM_FONT_WIDTHS;
    for (text) |c| {
        const idx = if (c < 128) c else 32;
        total += @as(f32, @floatFromInt(width_table[idx])) * font_size / 1000.0;
    }
    return total;
}

pub const DrawCommandKind = enum {
    fill_rect,
    text_run,
    line,
    code_block_bg,
};

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    pub const white = Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
    pub const black = Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
    pub const transparent = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };

    // Zen Dark theme palette
    pub const bg_dark = Color{ .r = 20, .g = 20, .b = 22, .a = 255 };
    pub const text_dark = Color{ .r = 232, .g = 232, .b = 236, .a = 255 };
    pub const text_muted_dark = Color{ .r = 145, .g = 145, .b = 155, .a = 255 };
    pub const accent_dark = Color{ .r = 96, .g = 165, .b = 250, .a = 255 };
    pub const code_bg_dark = Color{ .r = 28, .g = 28, .b = 32, .a = 255 };
    pub const quote_bar_dark = Color{ .r = 80, .g = 80, .b = 95, .a = 255 };
    pub const hr_dark = Color{ .r = 45, .g = 45, .b = 52, .a = 255 };
    pub const table_border_dark = Color{ .r = 50, .g = 50, .b = 60, .a = 255 };
    pub const table_header_bg_dark = Color{ .r = 30, .g = 30, .b = 36, .a = 255 };

    // Zen Light theme palette
    pub const bg_light = Color{ .r = 252, .g = 252, .b = 252, .a = 255 };
    pub const text_light = Color{ .r = 28, .g = 28, .b = 32, .a = 255 };
    pub const text_muted_light = Color{ .r = 115, .g = 115, .b = 125, .a = 255 };
    pub const accent_light = Color{ .r = 37, .g = 99, .b = 235, .a = 255 };
    pub const code_bg_light = Color{ .r = 243, .g = 244, .b = 246, .a = 255 };
    pub const quote_bar_light = Color{ .r = 203, .g = 213, .b = 225, .a = 255 };
    pub const hr_light = Color{ .r = 226, .g = 232, .b = 240, .a = 255 };
    pub const table_border_light = Color{ .r = 226, .g = 232, .b = 240, .a = 255 };
    pub const table_header_bg_light = Color{ .r = 248, .g = 250, .b = 252, .a = 255 };
};

pub const Rect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

pub const DrawCommand = struct {
    kind: DrawCommandKind,
    rect: Rect,
    color: Color,
    text: []const u8 = "",
    font_size: f32 = 16.0,
    style: parser.SpanStyle = .{},
    link_target: ?[]const u8 = null,
};

pub const Theme = struct {
    bg: Color,
    text: Color,
    muted: Color,
    accent: Color,
    code_bg: Color,
    quote_bar: Color,
    hr: Color,
    table_border: Color,
    table_header_bg: Color,

    pub const dark = Theme{
        .bg = Color.bg_dark,
        .text = Color.text_dark,
        .muted = Color.text_muted_dark,
        .accent = Color.accent_dark,
        .code_bg = Color.code_bg_dark,
        .quote_bar = Color.quote_bar_dark,
        .hr = Color.hr_dark,
        .table_border = Color.table_border_dark,
        .table_header_bg = Color.table_header_bg_dark,
    };

    pub const light = Theme{
        .bg = Color.bg_light,
        .text = Color.text_light,
        .muted = Color.text_muted_light,
        .accent = Color.accent_light,
        .code_bg = Color.code_bg_light,
        .quote_bar = Color.quote_bar_light,
        .hr = Color.hr_light,
        .table_border = Color.table_border_light,
        .table_header_bg = Color.table_header_bg_light,
    };
};

pub const ViewportConfig = struct {
    window_width: f32,
    window_height: f32,
    scroll_y: f32,
    table_scroll_x: f32 = 0.0,
    content_max_width: f32 = 760.0,
    base_font_size: f32 = 17.0,
    line_height: f32 = 28.0,
    is_dark_theme: bool = true,
};

/// Renders a series of inline spans with automatic word wrapping and exact typography.
pub fn layoutWrappedSpans(
    spans: []const parser.InlineSpan,
    start_x: f32,
    max_w: f32,
    base_y: f32,
    font_size: f32,
    line_h: f32,
    default_color: Color,
    accent_color: Color,
    vp_bottom: f32,
    commands_out: []DrawCommand,
    cmd_count: *usize,
) f32 {
    var cur_x = start_x;
    var cur_y = base_y;

    const space_w = measureChar(' ', font_size, false, false);

    for (spans) |span| {
        if (cmd_count.* >= commands_out.len - 4) break;

        const is_mono = span.style.code;
        const is_bold = span.style.bold;
        const span_color = if (span.style.link) accent_color else default_color;
        const span_text = span.text;

        var i: usize = 0;
        while (i < span_text.len) {
            // Check for spaces
            if (span_text[i] == ' ') {
                cur_x += space_w;
                i += 1;
                continue;
            }

            // Extract word
            const w_start = i;
            while (i < span_text.len and span_text[i] != ' ') : (i += 1) {}
            const word = span_text[w_start..i];
            const word_w = measureText(word, font_size, is_bold, is_mono);

            // Wrap to next visual line if exceeding max width
            if (cur_x + word_w > start_x + max_w and cur_x > start_x) {
                cur_y += line_h;
                cur_x = start_x;
            }

            // Emit draw command if visible
            if (cur_y + line_h >= 0 and cur_y <= vp_bottom and cmd_count.* < commands_out.len) {
                commands_out[cmd_count.*] = .{
                    .kind = .text_run,
                    .rect = .{
                        .x = cur_x,
                        .y = cur_y,
                        .w = word_w,
                        .h = line_h,
                    },
                    .color = span_color,
                    .text = word,
                    .font_size = font_size,
                    .style = span.style,
                    .link_target = span.link_target,
                };
                cmd_count.* += 1;
            }

            cur_x += word_w;
        }
    }

    return cur_y + line_h;
}

/// High-speed virtualized layout generator.
/// Computes draw commands strictly for elements visible within the viewport window.
/// Zero heap allocations: writes directly into `commands_out`.
pub fn layoutViewport(
    bytes: []const u8,
    lines: []const simd.Line,
    config: ViewportConfig,
    commands_out: []DrawCommand,
) usize {
    if (commands_out.len == 0 or lines.len == 0) return 0;

    var cmd_count: usize = 0;

    const content_x = if (config.window_width > config.content_max_width)
        (config.window_width - config.content_max_width) * 0.5
    else
        32.0;
    const content_width = if (config.window_width > config.content_max_width)
        config.content_max_width
    else
        @max(config.window_width - 64.0, 100.0);

    const theme = if (config.is_dark_theme) Theme.dark else Theme.light;

    // 1. Fill background (fullscreen)
    commands_out[cmd_count] = .{
        .kind = .fill_rect,
        .rect = .{ .x = 0, .y = 0, .w = config.window_width, .h = config.window_height },
        .color = theme.bg,
    };
    cmd_count += 1;

    var cur_y: f32 = 50.0 - config.scroll_y;
    const vp_bottom = config.window_height;

    var span_buf: [32]parser.InlineSpan = undefined;
    var i: usize = 0;

    while (i < lines.len) : (i += 1) {
        if (cmd_count >= commands_out.len - 16) break;

        const line_info = lines[i];

        // Early exit if past bottom of viewport
        if (cur_y > vp_bottom) break;

        const line_bytes = bytes[line_info.offset..][0..line_info.len];

        // ----------------------------------------------------
        // Handle Code Blocks: ```start ... lines ... ```end
        // ----------------------------------------------------
        if (line_info.block_type == .code_fence_start) {
            var code_line_count: usize = 0;
            var scan_i = i + 1;
            while (scan_i < lines.len and lines[scan_i].block_type != .code_fence_end) : (scan_i += 1) {
                code_line_count += 1;
            }

            const code_block_h = (@as(f32, @floatFromInt(code_line_count)) * (config.line_height * 0.88)) + 24.0;
            const block_top = cur_y;
            const block_bottom = cur_y + code_block_h;

            if (block_bottom >= 0 and block_top <= vp_bottom) {
                // Extract entire code block slice for the Copy button
                const code_slice = if (scan_i > i + 1)
                    bytes[lines[i + 1].offset .. lines[scan_i - 1].offset + lines[scan_i - 1].len]
                else
                    "";

                // Code block background card
                commands_out[cmd_count] = .{
                    .kind = .code_block_bg,
                    .rect = .{
                        .x = content_x - 12.0,
                        .y = cur_y,
                        .w = content_width + 24.0,
                        .h = code_block_h,
                    },
                    .color = theme.code_bg,
                    .text = code_slice,
                };
                cmd_count += 1;

                var code_y = cur_y + 12.0;
                var draw_i = i + 1;
                while (draw_i < scan_i and draw_i < lines.len) : (draw_i += 1) {
                    if (cmd_count >= commands_out.len - 4) break;
                    const c_line = lines[draw_i];
                    const c_bytes = bytes[c_line.offset..][0..c_line.len];

                    if (code_y + 20.0 >= 0 and code_y <= vp_bottom) {
                        commands_out[cmd_count] = .{
                            .kind = .text_run,
                            .rect = .{
                                .x = content_x,
                                .y = code_y,
                                .w = content_width,
                                .h = config.line_height * 0.88,
                            },
                            .color = theme.text,
                            .text = c_bytes,
                            .font_size = config.base_font_size * 0.88,
                            .style = .{ .code = true },
                        };
                        cmd_count += 1;
                    }
                    code_y += config.line_height * 0.88;
                }
            }

            cur_y += code_block_h + 16.0;
            i = scan_i; // Skip past code_fence_end
            continue;
        }

        if (line_info.block_type == .code_fence_end) {
            continue;
        }

        // ----------------------------------------------------
        // Handle Tables (Dynamic column widths & inline parsing)
        // ----------------------------------------------------
        if (line_info.block_type == .table_row) {
            var table_rows_count: usize = 0;
            var scan_i = i;
            while (scan_i < lines.len and lines[scan_i].block_type == .table_row) : (scan_i += 1) {
                table_rows_count += 1;
            }

            const row_h = config.line_height * 1.3;
            const table_h = @as(f32, @floatFromInt(table_rows_count)) * row_h;

            if (cur_y + table_h >= 0 and cur_y <= vp_bottom) {
                // Pass 1: measure column count and column widths
                var col_widths: [8]f32 = [_]f32{80.0} ** 8;
                var col_count: usize = 0;

                var r_scan = i;
                while (r_scan < scan_i) : (r_scan += 1) {
                    const r_bytes = bytes[lines[r_scan].offset..][0..lines[r_scan].len];
                    var cell_start: usize = 0;
                    var c_idx: usize = 0;

                    for (r_bytes, 0..) |c, char_idx| {
                        if (c == '|') {
                            if (char_idx > cell_start) {
                                var cell_text = r_bytes[cell_start..char_idx];
                                while (cell_text.len > 0 and cell_text[0] == ' ') : (cell_text = cell_text[1..]) {}
                                while (cell_text.len > 0 and cell_text[cell_text.len - 1] == ' ') : (cell_text = cell_text[0 .. cell_text.len - 1]) {}

                                // Skip separator row from width calculations
                                if (cell_text.len > 0 and cell_text[0] != '-' and cell_text[0] != ':') {
                                    if (c_idx < 8) {
                                        const w = measureText(cell_text, config.base_font_size * 0.92, false, false) + 24.0;
                                        col_widths[c_idx] = @max(col_widths[c_idx], w);
                                        if (c_idx + 1 > col_count) col_count = c_idx + 1;
                                    }
                                }
                                c_idx += 1;
                            }
                            cell_start = char_idx + 1;
                        }
                    }
                }

                if (col_count == 0) col_count = 1;

                // Scale columns to fill content_width comfortably
                var total_measured_w: f32 = 0;
                for (0..col_count) |ci| total_measured_w += col_widths[ci];
                if (total_measured_w < content_width) {
                    const extra_per_col = (content_width - total_measured_w) / @as(f32, @floatFromInt(col_count));
                    for (0..col_count) |ci| col_widths[ci] += extra_per_col;
                }

                var row_y = cur_y;
                var is_header = true;

                var r_idx = i;
                while (r_idx < scan_i) : (r_idx += 1) {
                    if (cmd_count >= commands_out.len - 16) break;
                    const r_bytes = bytes[lines[r_idx].offset..][0..lines[r_idx].len];

                    // Check if separator row
                    var is_sep = true;
                    for (r_bytes) |c| {
                        if (c != '|' and c != '-' and c != ':' and c != ' ' and c != '\t') {
                            is_sep = false;
                            break;
                        }
                    }

                    if (is_sep) {
                        commands_out[cmd_count] = .{
                            .kind = .line,
                            .rect = .{ .x = content_x, .y = row_y + 2.0, .w = @max(content_width, total_measured_w), .h = 1.0 },
                            .color = theme.table_border,
                        };
                        cmd_count += 1;
                        row_y += 8.0;
                        is_header = false;
                        continue;
                    }

                    // Render row cells with inline parsing
                    var cell_start: usize = 0;
                    var c_idx: usize = 0;
                    var cur_col_x = content_x - if (total_measured_w > content_width) config.table_scroll_x else 0.0;

                    for (r_bytes, 0..) |c, char_idx| {
                        if (c == '|') {
                            if (char_idx > cell_start) {
                                var cell_text = r_bytes[cell_start..char_idx];
                                while (cell_text.len > 0 and cell_text[0] == ' ') : (cell_text = cell_text[1..]) {}
                                while (cell_text.len > 0 and cell_text[cell_text.len - 1] == ' ') : (cell_text = cell_text[0 .. cell_text.len - 1]) {}

                                if (c_idx < col_count) {
                                    const this_col_w = col_widths[c_idx];
                                    if (cell_text.len > 0 and cmd_count < commands_out.len) {
                                        const cell_spans = parser.parseInlines(cell_text, &span_buf);
                                        const cell_color = if (is_header) theme.accent else theme.text;

                                        var span_x = cur_col_x + 8.0;
                                        for (span_buf[0..cell_spans]) |s| {
                                            if (cmd_count >= commands_out.len) break;
                                            var s_style = s.style;
                                            if (is_header) s_style.bold = true;
                                            const w = measureText(s.text, config.base_font_size * 0.90, s_style.bold, s_style.code);

                                            commands_out[cmd_count] = .{
                                                .kind = .text_run,
                                                .rect = .{
                                                    .x = span_x,
                                                    .y = row_y,
                                                    .w = w,
                                                    .h = row_h,
                                                },
                                                .color = cell_color,
                                                .text = s.text,
                                                .font_size = config.base_font_size * 0.90,
                                                .style = s_style,
                                            };
                                            cmd_count += 1;
                                            span_x += w + measureChar(' ', config.base_font_size * 0.90, false, false);
                                        }
                                    }
                                    cur_col_x += this_col_w;
                                    c_idx += 1;
                                }
                            }
                            cell_start = char_idx + 1;
                        }
                    }

                    // Row divider line
                    commands_out[cmd_count] = .{
                        .kind = .line,
                        .rect = .{ .x = content_x, .y = row_y + row_h - 2.0, .w = content_width, .h = 1.0 },
                        .color = theme.table_border,
                    };
                    cmd_count += 1;

                    row_y += row_h;
                }
            }

            cur_y += table_h + 16.0;
            i = scan_i - 1;
            continue;
        }

        // ----------------------------------------------------
        // Headings (H1 - H6)
        // ----------------------------------------------------
        if (@intFromEnum(line_info.block_type) >= @intFromEnum(simd.BlockType.heading1) and
            @intFromEnum(line_info.block_type) <= @intFromEnum(simd.BlockType.heading6))
        {
            const level = @intFromEnum(line_info.block_type);
            const scale: f32 = switch (level) {
                1 => 2.1,
                2 => 1.6,
                3 => 1.3,
                4 => 1.15,
                else => 1.05,
            };
            const font_size = config.base_font_size * scale;
            const block_height = config.line_height * scale * 1.15;

            var h_offset: usize = 0;
            while (h_offset < line_bytes.len and line_bytes[h_offset] == '#') : (h_offset += 1) {}
            if (h_offset < line_bytes.len and line_bytes[h_offset] == ' ') h_offset += 1;

            if (cur_y + block_height >= 0 and cur_y <= vp_bottom) {
                commands_out[cmd_count] = .{
                    .kind = .text_run,
                    .rect = .{
                        .x = content_x,
                        .y = cur_y + 8.0,
                        .w = content_width,
                        .h = block_height,
                    },
                    .color = theme.text,
                    .text = line_bytes[h_offset..],
                    .font_size = font_size,
                    .style = .{ .bold = true },
                };
                cmd_count += 1;
            }

            cur_y += block_height + 12.0;
            continue;
        }

        // ----------------------------------------------------
        // Horizontal Rule
        // ----------------------------------------------------
        if (line_info.block_type == .hr) {
            if (cur_y + 20.0 >= 0 and cur_y <= vp_bottom) {
                commands_out[cmd_count] = .{
                    .kind = .line,
                    .rect = .{ .x = content_x, .y = cur_y + 10.0, .w = content_width, .h = 1.0 },
                    .color = theme.hr,
                };
                cmd_count += 1;
            }
            cur_y += 24.0;
            continue;
        }

        // ----------------------------------------------------
        // Blank Line
        // ----------------------------------------------------
        if (line_info.block_type == .blank) {
            cur_y += config.line_height * 0.75;
            continue;
        }

        // ----------------------------------------------------
        // Blockquote (Supports nested quotes)
        // ----------------------------------------------------
        if (line_info.block_type == .quote) {
            var text_slice = line_bytes;
            var quote_depth: usize = 0;
            while (text_slice.len > 0 and text_slice[0] == '>') {
                quote_depth += 1;
                text_slice = text_slice[1..];
                if (text_slice.len > 0 and text_slice[0] == ' ') text_slice = text_slice[1..];
            }

            const quote_margin = @as(f32, @floatFromInt(quote_depth)) * 16.0;
            const block_height = config.line_height * 1.1;

            if (cur_y + block_height >= 0 and cur_y <= vp_bottom) {
                // Accent left bar
                commands_out[cmd_count] = .{
                    .kind = .fill_rect,
                    .rect = .{
                        .x = content_x + quote_margin - 12.0,
                        .y = cur_y,
                        .w = 3.0,
                        .h = block_height,
                    },
                    .color = theme.quote_bar,
                };
                cmd_count += 1;

                const spans_n = parser.parseInlines(text_slice, &span_buf);
                cur_y = layoutWrappedSpans(
                    span_buf[0..spans_n],
                    content_x + quote_margin,
                    content_width - quote_margin,
                    cur_y,
                    config.base_font_size,
                    config.line_height,
                    theme.muted,
                    theme.accent,
                    vp_bottom,
                    commands_out,
                    &cmd_count,
                );
            } else {
                cur_y += block_height;
            }
            continue;
        }

        // ----------------------------------------------------
        // Task List Checkboxes
        // ----------------------------------------------------
        if (line_info.block_type == .task_list) {
            var text_slice = line_bytes;
            while (text_slice.len > 0 and (text_slice[0] == ' ' or text_slice[0] == '\t')) : (text_slice = text_slice[1..]) {}
            const is_checked = (text_slice.len >= 4 and (text_slice[3] == 'x' or text_slice[3] == 'X'));
            const text_start = if (text_slice.len >= 5) 5 else text_slice.len;
            const item_text = if (text_start < text_slice.len and text_slice[text_start] == ' ')
                text_slice[text_start + 1 ..]
            else
                text_slice[text_start..];

            const block_height = config.line_height;

            if (cur_y + block_height >= 0 and cur_y <= vp_bottom) {
                // Checkbox box
                commands_out[cmd_count] = .{
                    .kind = .fill_rect,
                    .rect = .{ .x = content_x, .y = cur_y + 4.0, .w = 16.0, .h = 16.0 },
                    .color = if (is_checked) theme.accent else theme.code_bg,
                };
                cmd_count += 1;

                // Checkbox mark
                commands_out[cmd_count] = .{
                    .kind = .text_run,
                    .rect = .{ .x = content_x + 3.0, .y = cur_y + 2.0, .w = 14.0, .h = 16.0 },
                    .color = if (is_checked) Color.white else theme.muted,
                    .text = if (is_checked) "✓" else " ",
                    .font_size = 12.0,
                    .style = .{ .bold = true },
                };
                cmd_count += 1;

                const spans_n = parser.parseInlines(item_text, &span_buf);
                const txt_color = if (is_checked) theme.muted else theme.text;
                cur_y = layoutWrappedSpans(
                    span_buf[0..spans_n],
                    content_x + 28.0,
                    content_width - 28.0,
                    cur_y,
                    config.base_font_size,
                    config.line_height,
                    txt_color,
                    theme.accent,
                    vp_bottom,
                    commands_out,
                    &cmd_count,
                );
            } else {
                cur_y += block_height;
            }
            continue;
        }

        // ----------------------------------------------------
        // Bullet and Ordered Lists (With Inline formatting)
        // ----------------------------------------------------
        if (line_info.block_type == .bullet_list or line_info.block_type == .ordered_list) {
            var text_slice = line_bytes;
            var indent_level: f32 = @floatFromInt(line_info.indent);
            if (indent_level > 32) indent_level = 32;

            while (text_slice.len > 0 and (text_slice[0] == ' ' or text_slice[0] == '\t')) : (text_slice = text_slice[1..]) {}

            var prefix_len: usize = 0;
            if (line_info.block_type == .bullet_list and text_slice.len >= 2) {
                prefix_len = 2; // "- "
            } else if (line_info.block_type == .ordered_list) {
                while (prefix_len < text_slice.len and text_slice[prefix_len] != ' ') : (prefix_len += 1) {}
                if (prefix_len < text_slice.len) prefix_len += 1;
            }

            const item_text = text_slice[prefix_len..];
            const bullet_x = content_x + indent_level * 10.0;
            const text_x = bullet_x + 18.0;
            const block_height = config.line_height;

            if (cur_y + block_height >= 0 and cur_y <= vp_bottom) {
                if (line_info.block_type == .bullet_list) {
                    commands_out[cmd_count] = .{
                        .kind = .text_run,
                        .rect = .{ .x = bullet_x, .y = cur_y, .w = 14.0, .h = block_height },
                        .color = theme.accent,
                        .text = "•",
                        .font_size = config.base_font_size * 1.1,
                        .style = .{ .bold = true },
                    };
                    cmd_count += 1;
                } else {
                    commands_out[cmd_count] = .{
                        .kind = .text_run,
                        .rect = .{ .x = bullet_x, .y = cur_y, .w = 18.0, .h = block_height },
                        .color = theme.muted,
                        .text = text_slice[0..prefix_len],
                        .font_size = config.base_font_size * 0.95,
                    };
                    cmd_count += 1;
                }

                const spans_n = parser.parseInlines(item_text, &span_buf);
                cur_y = layoutWrappedSpans(
                    span_buf[0..spans_n],
                    text_x,
                    content_width - (text_x - content_x),
                    cur_y,
                    config.base_font_size,
                    config.line_height,
                    theme.text,
                    theme.accent,
                    vp_bottom,
                    commands_out,
                    &cmd_count,
                );
            } else {
                cur_y += block_height;
            }
            continue;
        }

        // ----------------------------------------------------
        // Paragraph with Word-Wrapping and Accurate Inline Spans
        // ----------------------------------------------------
        const span_count = parser.parseInlines(line_bytes, &span_buf);
        if (span_count == 0) {
            cur_y += config.line_height * 0.5;
            continue;
        }

        cur_y = layoutWrappedSpans(
            span_buf[0..span_count],
            content_x,
            content_width,
            cur_y,
            config.base_font_size,
            config.line_height,
            theme.text,
            theme.accent,
            vp_bottom,
            commands_out,
            &cmd_count,
        ) + 4.0;
    }

    return cmd_count;
}
