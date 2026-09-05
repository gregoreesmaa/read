const std = @import("std");
const simd = @import("../core/simd.zig");
const parser = @import("../core/parser.zig");

// Calibrated ASCII advance widths for IBM Plex Serif Regular (in 1/1000 em)
pub const SERIF_FONT_WIDTHS = [128]u16{
    0, 464, 464, 464, 464, 464, 464, 464,
    464, 232, 232, 464, 464, 232, 464, 464,
    464, 464, 464, 464, 464, 464, 464, 464,
    464, 464, 464, 464, 464, 464, 464, 464,
    232, 280, 415, 695, 592, 913, 710, 241,
    329, 329, 442, 600, 268, 393, 268, 366,
    600, 600, 600, 600, 600, 600, 600, 600,
    600, 600, 288, 288, 600, 600, 600, 487,
    923, 686, 670, 649, 706, 641, 626, 721,
    787, 346, 457, 707, 594, 872, 778, 716,
    625, 716, 672, 588, 652, 735, 664, 968,
    669, 634, 637, 284, 365, 284, 600, 564,
    600, 546, 598, 516, 608, 536, 342, 544,
    624, 315, 303, 584, 300, 953, 639, 564,
    613, 598, 443, 488, 353, 619, 534, 777,
    561, 534, 508, 327, 298, 327, 600, 464,
};

// Calibrated ASCII advance widths for IBM Plex Serif Bold (in 1/1000 em)
pub const SERIF_FONT_BOLD_WIDTHS = [128]u16{
    0, 464, 464, 464, 464, 464, 464, 464,
    464, 232, 232, 464, 464, 232, 464, 464,
    464, 464, 464, 464, 464, 464, 464, 464,
    464, 464, 464, 464, 464, 464, 464, 464,
    232, 312, 480, 639, 595, 924, 747, 266,
    355, 355, 590, 600, 283, 398, 282, 428,
    600, 600, 600, 600, 600, 600, 600, 600,
    600, 600, 303, 304, 600, 600, 600, 519,
    904, 699, 704, 665, 755, 658, 639, 775,
    812, 384, 514, 767, 620, 896, 791, 760,
    681, 760, 735, 629, 710, 769, 694, 1027,
    727, 688, 653, 355, 428, 355, 600, 560,
    600, 571, 626, 535, 632, 566, 385, 580,
    651, 335, 322, 622, 326, 971, 662, 582,
    633, 626, 493, 508, 373, 647, 564, 868,
    588, 571, 514, 385, 374, 385, 600, 464,
};

// Calibrated ASCII advance widths for Space Grotesk Bold headings (in 1/1000 em)
pub const HEADING_FONT_WIDTHS = [128]u16{
    910, 910, 910, 910, 910, 910, 910, 910,
    910, 254, 254, 910, 910, 600, 910, 910,
    910, 910, 910, 910, 910, 910, 910, 910,
    910, 910, 910, 910, 910, 910, 910, 910,
    254, 298, 514, 636, 606, 758, 591, 294,
    398, 390, 540, 620, 294, 432, 298, 388,
    648, 452, 594, 608, 636, 600, 618, 554,
    600, 618, 298, 298, 620, 620, 620, 578,
    1014, 634, 664, 644, 666, 554, 534, 662,
    656, 264, 610, 626, 542, 882, 670, 676,
    604, 676, 632, 606, 588, 672, 618, 898,
    644, 624, 576, 358, 388, 358, 620, 620,
    296, 578, 638, 586, 638, 577, 436, 638,
    616, 266, 268, 564, 266, 854, 616, 612,
    638, 638, 396, 524, 456, 616, 548, 784,
    592, 616, 518, 466, 258, 466, 620, 910,
};

// Calibrated ASCII advance widths for IBM Plex Serif Italic (in 1/1000 em)
pub const SERIF_FONT_ITALIC_WIDTHS = [128]u16{
    0, 424, 424, 424, 424, 424, 424, 424,
    424, 212, 212, 424, 424, 212, 424, 424,
    424, 424, 424, 424, 424, 424, 424, 424,
    424, 424, 424, 424, 424, 424, 424, 424,
    212, 254, 387, 641, 539, 836, 655, 216,
    298, 298, 420, 550, 244, 360, 244, 350,
    550, 550, 550, 550, 550, 550, 550, 550,
    550, 550, 258, 258, 550, 550, 550, 444,
    836, 638, 617, 591, 664, 591, 567, 679,
    723, 314, 436, 661, 547, 800, 711, 674,
    583, 674, 622, 549, 599, 674, 605, 889,
    605, 583, 576, 281, 351, 281, 550, 523,
    600, 544, 516, 428, 543, 445, 301, 472,
    551, 300, 270, 530, 281, 843, 568, 496,
    533, 518, 437, 370, 355, 567, 453, 697,
    570, 453, 453, 299, 312, 299, 550, 424,
};

pub fn measureChar(c: u8, font_size: f32, is_bold: bool, is_mono: bool) f32 {
    return measureCharEx(c, font_size, is_bold, false, is_mono, false);
}

pub fn measureCharEx(c: u8, font_size: f32, is_bold: bool, is_italic: bool, is_mono: bool, is_heading: bool) f32 {
    if (is_mono) return font_size * 0.60;
    const idx = if (c < 128) c else 32;
    if (is_heading) {
        return @as(f32, @floatFromInt(HEADING_FONT_WIDTHS[idx])) * font_size / 1000.0;
    }
    const width_table = if (is_bold)
        &SERIF_FONT_BOLD_WIDTHS
    else if (is_italic)
        &SERIF_FONT_ITALIC_WIDTHS
    else
        &SERIF_FONT_WIDTHS;
    return @as(f32, @floatFromInt(width_table[idx])) * font_size / 1000.0;
}

pub fn measureText(text: []const u8, font_size: f32, is_bold: bool, is_mono: bool) f32 {
    return measureTextEx(text, font_size, is_bold, false, is_mono, false);
}

pub fn measureTextEx(text: []const u8, font_size: f32, is_bold: bool, is_italic: bool, is_mono: bool, is_heading: bool) f32 {
    if (is_mono) return @as(f32, @floatFromInt(text.len)) * font_size * 0.60;
    var total: f32 = 0;
    const width_table = if (is_heading)
        &HEADING_FONT_WIDTHS
    else if (is_bold)
        &SERIF_FONT_BOLD_WIDTHS
    else if (is_italic)
        &SERIF_FONT_ITALIC_WIDTHS
    else
        &SERIF_FONT_WIDTHS;
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

    // Dark theme palette (#121212 bg, #E0E0E0 text)
    pub const bg_dark = Color{ .r = 18, .g = 18, .b = 18, .a = 255 };
    pub const text_dark = Color{ .r = 224, .g = 224, .b = 224, .a = 255 };
    pub const text_muted_dark = Color{ .r = 140, .g = 140, .b = 145, .a = 255 };
    pub const accent_dark = Color{ .r = 96, .g = 165, .b = 250, .a = 255 };
    pub const code_bg_dark = Color{ .r = 26, .g = 26, .b = 28, .a = 255 };
    pub const quote_bar_dark = Color{ .r = 70, .g = 70, .b = 80, .a = 255 };
    pub const hr_dark = Color{ .r = 40, .g = 40, .b = 45, .a = 255 };
    pub const table_border_dark = Color{ .r = 45, .g = 45, .b = 52, .a = 255 };
    pub const table_header_bg_dark = Color{ .r = 28, .g = 28, .b = 32, .a = 255 };

    // Light theme palette (#FAFAFA bg, #1E2022 text)
    pub const bg_light = Color{ .r = 250, .g = 250, .b = 250, .a = 255 };
    pub const text_light = Color{ .r = 30, .g = 32, .b = 34, .a = 255 };
    pub const text_muted_light = Color{ .r = 105, .g = 110, .b = 118, .a = 255 };
    pub const accent_light = Color{ .r = 37, .g = 99, .b = 235, .a = 255 };
    pub const code_bg_light = Color{ .r = 240, .g = 241, .b = 243, .a = 255 };
    pub const quote_bar_light = Color{ .r = 203, .g = 213, .b = 225, .a = 255 };
    pub const hr_light = Color{ .r = 226, .g = 232, .b = 240, .a = 255 };
    pub const table_border_light = Color{ .r = 226, .g = 232, .b = 240, .a = 255 };
    pub const table_header_bg_light = Color{ .r = 244, .g = 245, .b = 247, .a = 255 };
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
    content_max_width: f32 = 600.0,
    base_font_size: f32 = 17.0,
    line_height: f32 = 29.75,
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

    for (spans) |span| {
        if (cmd_count.* >= commands_out.len - 4) break;

        const is_mono = span.style.code;
        const is_bold = span.style.bold;
        const is_italic = span.style.italic;
        const is_heading = span.style.heading;
        const span_color = if (span.style.link) accent_color else default_color;
        const span_text = span.text;
        const space_w = measureCharEx(' ', font_size, false, false, false, is_heading);

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
            const word_w = measureTextEx(word, font_size, is_bold, is_italic, is_mono, is_heading);

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
            const heading_line_h = font_size * 1.3;
            const margin_top = font_size * 2.5;
            const margin_bottom = font_size * 0.5;

            var h_offset: usize = 0;
            while (h_offset < line_bytes.len and line_bytes[h_offset] == '#') : (h_offset += 1) {}
            while (h_offset < line_bytes.len and line_bytes[h_offset] == ' ') : (h_offset += 1) {}

            cur_y += margin_top;

            const h_text = line_bytes[h_offset..];
            const span_count = parser.parseInlines(h_text, &span_buf);
            for (span_buf[0..span_count]) |*s| {
                s.style.bold = true;
                s.style.heading = true;
            }

            const end_y = layoutWrappedSpans(
                span_buf[0..span_count],
                content_x,
                content_width,
                cur_y,
                font_size,
                heading_line_h,
                theme.text,
                theme.accent,
                vp_bottom,
                commands_out,
                &cmd_count,
            );

            cur_y = end_y + margin_bottom;
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

            if (cur_y + block_height >= 0 and cur_y <= vp_bottom and cmd_count < commands_out.len) {
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
            }

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

            if (cur_y + block_height >= 0 and cur_y <= vp_bottom and cmd_count < commands_out.len - 2) {
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
            }

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

            if (cur_y + block_height >= 0 and cur_y <= vp_bottom and cmd_count < commands_out.len) {
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

test "strict scroll smoothness across enumerations, lists, headings, and mixed blocks" {
    const test_doc =
        \\# Main Heading 1
        \\## Secondary Heading 2
        \\### Section 3
        \\
        \\A normal paragraph with enough words to verify multi-line wrapping and baseline alignment across lines.
        \\
        \\> A blockquote that spans across multiple sentences and tests whether quoting margins and bars scroll with zero jitter.
        \\> Second line of blockquote.
        \\
        \\* Enumeration item_alpha with short text
        \\* Enumeration item_beta with a significantly longer description that wraps across multiple lines in the viewport to test multi-line list scroll stability
        \\* Enumeration item_gamma with `inline code` and **bold formatting** to verify inline styles during scroll
        \\
        \\1. Ordered step_one: initialize memory map
        \\2. Ordered step_two: scan SIMD vector chunk line boundaries with microsecond throughput
        \\3. Ordered step_three: calculate visible viewport draw commands strictly without layout jitter or jumps
        \\4. Ordered step_four: render frame to native macOS Cocoa CoreText buffer
        \\
        \\- [x] Completed task_one with checkmark
        \\- [ ] Incomplete task_two that requires user action and spans across several words
        \\- [x] Another completed task_three testing multi-item task list smoothness
        \\
        \\| Col A | Col B | Col C |
        \\| :--- | :--- | :--- |
        \\| Data 1 | Data 2 | Data 3 |
        \\| Data 4 | Data 5 | Data 6 |
        \\
        \\```zig
        \\pub fn main() void {
        \\    std.debug.print("Hello smooth scroll!\n", .{});
        \\}
        \\```
        \\
        \\Final trailing paragraph at the bottom of the document.
    ;

    var lines_buf: [256]simd.Line = undefined;
    var fence = false;
    const line_count = simd.scanLines(test_doc, &lines_buf, &fence);
    const lines = lines_buf[0..line_count];

    var cmds_a: [512]DrawCommand = undefined;
    var cmds_b: [512]DrawCommand = undefined;

    const step_sizes = [_]f32{ 1.0, 3.0, 7.0, 14.0, 28.0 };

    for (step_sizes) |delta_s| {
        var s: f32 = 0.0;
        while (s < 1200.0) : (s += delta_s) {
            const config_a = ViewportConfig{
                .window_width = 800.0,
                .window_height = 600.0,
                .scroll_y = s,
            };
            const count_a = layoutViewport(test_doc, lines, config_a, &cmds_a);

            const config_b = ViewportConfig{
                .window_width = 800.0,
                .window_height = 600.0,
                .scroll_y = s + delta_s,
            };
            const count_b = layoutViewport(test_doc, lines, config_b, &cmds_b);

            // Verify that all distinct anchor words across lists, enumerations, headings, and quotes
            // scroll with mathematical smoothness (diff == delta_s exactly within 0.01 px)
            const anchor_words = [_][]const u8{
                "Main", "Secondary", "Section", "paragraph", "blockquote",
                "item_alpha", "item_beta", "item_gamma",
                "step_one:", "step_two:", "step_three:", "step_four:",
                "task_one", "task_two", "task_three",
                "Data 1", "Data 4", "trailing",
            };

            for (anchor_words) |word| {
                var ya: ?f32 = null;
                var yb: ?f32 = null;

                for (cmds_a[0..count_a]) |ca| {
                    if (ca.kind == .text_run and std.mem.eql(u8, ca.text, word)) {
                        ya = ca.rect.y;
                        break;
                    }
                }
                for (cmds_b[0..count_b]) |cb| {
                    if (cb.kind == .text_run and std.mem.eql(u8, cb.text, word)) {
                        yb = cb.rect.y;
                        break;
                    }
                }

                if (ya != null and yb != null) {
                    const actual_diff = ya.? - yb.?;
                    const jitter = @abs(actual_diff - delta_s);
                    try std.testing.expect(jitter < 0.01);
                }
            }
        }
    }
}

pub fn getCharIndexAtX(text: []const u8, font_size: f32, is_bold: bool, is_italic: bool, is_mono: bool, is_heading: bool, x_offset: f32) usize {
    if (x_offset <= 0) return 0;
    var acc: f32 = 0;
    for (text, 0..) |c, i| {
        const w = measureCharEx(c, font_size, is_bold, is_italic, is_mono, is_heading);
        if (acc + w * 0.5 > x_offset) return i;
        acc += w;
    }
    return text.len;
}

pub fn getXForCharIndex(text: []const u8, font_size: f32, is_bold: bool, is_italic: bool, is_mono: bool, is_heading: bool, char_idx: usize) f32 {
    if (char_idx == 0) return 0.0;
    const clamped = @min(char_idx, text.len);
    return measureTextEx(text[0..clamped], font_size, is_bold, is_italic, is_mono, is_heading);
}

pub const Point = struct {
    x: f32,
    y: f32,
};

/// Extracts plaintext string corresponding to selected text range across draw commands.
/// Accurately formats spaces, line wraps, and paragraph/element breaks.
pub fn extractSelectionText(
    commands: []const DrawCommand,
    p1: Point,
    p2: Point,
    out_buf: []u8,
) []const u8 {
    const is_downward = (p1.y < p2.y or (p1.y == p2.y and p1.x <= p2.x));
    const top_pt = if (is_downward) p1 else p2;
    const bot_pt = if (is_downward) p2 else p1;

    const min_y = top_pt.y;
    const max_y = bot_pt.y;

    var out_pos: usize = 0;
    var last_doc_y: f32 = -9999.0;

    for (commands) |cmd| {
        if (cmd.kind != .text_run or cmd.text.len == 0) continue;

        const r_top = cmd.rect.y;
        const r_bot = cmd.rect.y + cmd.rect.h;

        if (r_bot < min_y - 4.0 or r_top > max_y + 4.0) continue;

        const is_first_line = (min_y >= r_top and min_y <= r_bot);
        const is_last_line = (max_y >= r_top and max_y <= r_bot);

        var c_start: usize = 0;
        var c_end: usize = cmd.text.len;

        if (is_first_line and is_last_line) {
            const left_x = @min(top_pt.x, bot_pt.x);
            const right_x = @max(top_pt.x, bot_pt.x);
            if (cmd.rect.x + cmd.rect.w < left_x or cmd.rect.x > right_x) continue;
            c_start = getCharIndexAtX(cmd.text, cmd.font_size, cmd.style.bold, cmd.style.italic, cmd.style.code, cmd.style.heading, left_x - cmd.rect.x);
            c_end = getCharIndexAtX(cmd.text, cmd.font_size, cmd.style.bold, cmd.style.italic, cmd.style.code, cmd.style.heading, right_x - cmd.rect.x);
        } else if (is_first_line) {
            const start_x = top_pt.x;
            if (cmd.rect.x + cmd.rect.w < start_x) continue;
            c_start = getCharIndexAtX(cmd.text, cmd.font_size, cmd.style.bold, cmd.style.italic, cmd.style.code, cmd.style.heading, start_x - cmd.rect.x);
            c_end = cmd.text.len;
        } else if (is_last_line) {
            const end_x = bot_pt.x;
            if (cmd.rect.x > end_x) continue;
            c_start = 0;
            c_end = getCharIndexAtX(cmd.text, cmd.font_size, cmd.style.bold, cmd.style.italic, cmd.style.code, cmd.style.heading, end_x - cmd.rect.x);
        } else {
            c_start = 0;
            c_end = cmd.text.len;
        }

        if (c_end > c_start and c_end <= cmd.text.len) {
            const slice = cmd.text[c_start..c_end];
            if (last_doc_y > -9000.0 and @abs(cmd.rect.y - last_doc_y) > 10.0) {
                if (@abs(cmd.rect.y - last_doc_y) > 35.0) {
                    if (out_pos + 2 <= out_buf.len) {
                        out_buf[out_pos] = '\n';
                        out_buf[out_pos + 1] = '\n';
                        out_pos += 2;
                    }
                } else {
                    if (out_pos + 1 <= out_buf.len) {
                        out_buf[out_pos] = '\n';
                        out_pos += 1;
                    }
                }
            } else if (last_doc_y > -9000.0) {
                if (out_pos + 1 <= out_buf.len) {
                    out_buf[out_pos] = ' ';
                    out_pos += 1;
                }
            }

            const copy_len = @min(slice.len, out_buf.len - out_pos);
            @memcpy(out_buf[out_pos..][0..copy_len], slice[0..copy_len]);
            out_pos += copy_len;
            last_doc_y = cmd.rect.y;
        }
    }

    return out_buf[0..out_pos];
}

test "strict cross-element copying across headings, paragraphs, lists, tables, and code blocks" {
    const test_doc =
        \\# Fast Markdown Architecture
        \\
        \\Read is built strictly with zero runtime allocations.
        \\
        \\* Ultra high throughput
        \\* Precise typography
        \\
        \\```zig
        \\pub fn main() void {}
        \\```
    ;

    var lines_buf: [64]simd.Line = undefined;
    var fence = false;
    const line_count = simd.scanLines(test_doc, &lines_buf, &fence);

    var cmds: [256]DrawCommand = undefined;
    const config = ViewportConfig{
        .window_width = 800.0,
        .window_height = 1000.0,
        .scroll_y = 0.0,
    };
    const count = layoutViewport(test_doc, lines_buf[0..line_count], config, &cmds);

    var text_buf: [1024]u8 = undefined;

    // 1. Selection spanning from Heading across Paragraph
    var h_cmd: ?DrawCommand = null;
    var p_cmd: ?DrawCommand = null;
    for (cmds[0..count]) |c| {
        if (c.kind == .text_run and std.mem.eql(u8, c.text, "Architecture")) h_cmd = c;
        if (c.kind == .text_run and std.mem.eql(u8, c.text, "strictly")) p_cmd = c;
    }

    try std.testing.expect(h_cmd != null);
    try std.testing.expect(p_cmd != null);

    const sel1 = extractSelectionText(
        cmds[0..count],
        .{ .x = h_cmd.?.rect.x + 2.0, .y = h_cmd.?.rect.y + 5.0 },
        .{ .x = p_cmd.?.rect.x + p_cmd.?.rect.w - 1.0, .y = p_cmd.?.rect.y + 5.0 },
        &text_buf,
    );
    try std.testing.expect(std.mem.indexOf(u8, sel1, "Architecture\n\nRead is built strictly") != null);

    // 2. Selection spanning Paragraph across List item
    var p2_cmd: ?DrawCommand = null;
    var list_cmd: ?DrawCommand = null;
    for (cmds[0..count]) |c| {
        if (c.kind == .text_run and std.mem.eql(u8, c.text, "allocations.")) p2_cmd = c;
        if (c.kind == .text_run and std.mem.eql(u8, c.text, "throughput")) list_cmd = c;
    }
    try std.testing.expect(p2_cmd != null);
    try std.testing.expect(list_cmd != null);

    const sel2 = extractSelectionText(
        cmds[0..count],
        .{ .x = p2_cmd.?.rect.x + 2.0, .y = p2_cmd.?.rect.y + 5.0 },
        .{ .x = list_cmd.?.rect.x + list_cmd.?.rect.w - 1.0, .y = list_cmd.?.rect.y + 5.0 },
        &text_buf,
    );
    try std.testing.expect(std.mem.indexOf(u8, sel2, "allocations.\n\n• Ultra high throughput") != null);

    // 3. Selection across list items
    var l1_cmd: ?DrawCommand = null;
    var l2_cmd: ?DrawCommand = null;
    for (cmds[0..count]) |c| {
        if (c.kind == .text_run and std.mem.eql(u8, c.text, "Ultra")) l1_cmd = c;
        if (c.kind == .text_run and std.mem.eql(u8, c.text, "Precise")) l2_cmd = c;
    }
    try std.testing.expect(l1_cmd != null);
    try std.testing.expect(l2_cmd != null);

    const sel3 = extractSelectionText(
        cmds[0..count],
        .{ .x = l1_cmd.?.rect.x + 2.0, .y = l1_cmd.?.rect.y + 5.0 },
        .{ .x = l2_cmd.?.rect.x + l2_cmd.?.rect.w - 1.0, .y = l2_cmd.?.rect.y + 5.0 },
        &text_buf,
    );
    try std.testing.expect(std.mem.indexOf(u8, sel3, "Ultra high throughput\n• Precise") != null);
}
