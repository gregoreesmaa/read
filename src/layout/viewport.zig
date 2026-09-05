const std = @import("std");
const simd = @import("../core/simd.zig");
const parser = @import("../core/parser.zig");

// Calibrated ASCII advance widths for IBM Plex Serif Regular (in 1/1000 em)
pub const SERIF_FONT_WIDTHS = [128]u16{
    0,   464, 464, 464, 464, 464, 464, 464,
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
    0,   464, 464, 464, 464, 464, 464, 464,
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
    910,  910, 910, 910, 910, 910, 910, 910,
    910,  254, 254, 910, 910, 600, 910, 910,
    910,  910, 910, 910, 910, 910, 910, 910,
    910,  910, 910, 910, 910, 910, 910, 910,
    254,  298, 514, 636, 606, 758, 591, 294,
    398,  390, 540, 620, 294, 432, 298, 388,
    648,  452, 594, 608, 636, 600, 618, 554,
    600,  618, 298, 298, 620, 620, 620, 578,
    1014, 634, 664, 644, 666, 554, 534, 662,
    656,  264, 610, 626, 542, 882, 670, 676,
    604,  676, 632, 606, 588, 672, 618, 898,
    644,  624, 576, 358, 388, 358, 620, 620,
    296,  578, 638, 586, 638, 577, 436, 638,
    616,  266, 268, 564, 266, 854, 616, 612,
    638,  638, 396, 524, 456, 616, 548, 784,
    592,  616, 518, 466, 258, 466, 620, 910,
};

// Calibrated ASCII advance widths for IBM Plex Serif Italic (in 1/1000 em)
pub const SERIF_FONT_ITALIC_WIDTHS = [128]u16{
    0,   424, 424, 424, 424, 424, 424, 424,
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
    register_scrollable_block,
    begin_clip,
    end_clip,
    image,
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
    rect: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    color: Color = Color.transparent,
    text: []const u8 = "",
    font_size: f32 = 16.0,
    style: parser.SpanStyle = .{},
    link_target: ?[]const u8 = null,
    scrollable_id: c_int = -1,
    max_scroll_x: f32 = 0.0,
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

pub const MAX_SCROLLABLE_BLOCKS = 128;

pub const Checkpoint = struct {
    line_idx: u32,
    y: f32,
    next_block_id: u16,
};

pub const ViewportConfig = struct {
    window_width: f32,
    window_height: f32,
    scroll_y: f32,
    block_scroll_x: [MAX_SCROLLABLE_BLOCKS]f32 = [_]f32{0.0} ** MAX_SCROLLABLE_BLOCKS,
    content_max_width: f32 = 600.0,
    base_font_size: f32 = 17.0,
    line_height: f32 = 29.75,
    is_dark_theme: bool = true,
    checkpoints: []const Checkpoint = &.{},
    /// Optional callback: query natural pixel size of an image by URL.
    /// Signature: fn(url_ptr, url_len, out_w, out_h) void
    /// When null, images fall back to a fixed 240px default height.
    image_size_fn: ?*const fn (url: [*]const u8, url_len: c_int, out_w: *f32, out_h: *f32) callconv(.c) void = null,
};

pub const ScrollAxisLock = enum {
    none,
    vertical,
    horizontal,
};

/// Natural directional scroll lock engine.
/// Prevents incidental horizontal drift when scrolling vertically,
/// and prevents vertical jumps when panning horizontally.
pub const ScrollLockState = struct {
    axis: ScrollAxisLock = .none,
    last_timestamp_ms: i64 = 0,

    pub fn reset(self: *ScrollLockState) void {
        self.axis = .none;
    }

    pub fn processScroll(
        self: *ScrollLockState,
        delta_x: f32,
        delta_y: f32,
        hovered_block_id: c_int,
        now_ms: i64,
    ) struct { dx: f32, dy: f32 } {
        if (delta_x == 0.0 and delta_y == 0.0) {
            self.axis = .none;
            return .{ .dx = 0.0, .dy = 0.0 };
        }

        if (now_ms - self.last_timestamp_ms > 150) {
            self.axis = .none;
        }
        self.last_timestamp_ms = now_ms;

        var eff_dx = delta_x;
        var eff_dy = delta_y;

        const abs_x = @abs(delta_x);
        const abs_y = @abs(delta_y);

        if (hovered_block_id >= 0 and hovered_block_id < MAX_SCROLLABLE_BLOCKS) {
            // Intentional strong redirection between axes
            if (self.axis == .vertical and abs_x > 2.5 * abs_y and abs_x > 8.0) {
                self.axis = .horizontal;
            } else if (self.axis == .horizontal and abs_y > 2.5 * abs_x and abs_y > 8.0) {
                self.axis = .vertical;
            }

            // Lock acquisition on gesture start
            if (self.axis == .none) {
                if (abs_y >= abs_x and abs_y > 0.5) {
                    self.axis = .vertical;
                } else if (abs_x > abs_y and abs_x > 0.5) {
                    self.axis = .horizontal;
                }
            }

            // Apply active axis lock: cancel the orthogonal direction
            if (self.axis == .vertical) {
                eff_dx = 0.0;
            } else if (self.axis == .horizontal) {
                eff_dy = 0.0;
            }
        } else {
            eff_dx = 0.0;
            self.axis = .vertical;
        }

        return .{ .dx = eff_dx, .dy = eff_dy };
    }
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
        if (commands_out.len >= 4 and cmd_count.* >= commands_out.len - 4) break;

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

/// Shared virtualized render core: emits draw commands for `lines[start_line..]`,
/// positioned with `start_line` at viewport-relative `origin_y`, assigning
/// scrollable block ids from `start_block_id`.
/// Zero heap allocations: writes directly into `commands_out`.
/// Both `layoutViewport` (checkpoint seek) and `layoutViewportJIT`
/// (Goldilocks-window seek) funnel through this single code path so exact
/// and JIT rendering can never diverge.
pub fn renderViewportCore(
    bytes: []const u8,
    lines: []const simd.Line,
    config: ViewportConfig,
    start_line: usize,
    origin_y: f32,
    start_block_id: usize,
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

    var cur_y: f32 = origin_y;
    const vp_bottom = config.window_height;

    var span_buf: [32]parser.InlineSpan = undefined;
    var i: usize = start_line;
    var next_block_id: usize = start_block_id;

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
            const block_id = next_block_id;
            next_block_id += 1;

            if (block_bottom >= 0 and block_top <= vp_bottom) {
                // Find longest line to determine max_scroll_x
                var max_code_line_w: f32 = 0;
                var measure_i = i + 1;
                while (measure_i < scan_i and measure_i < lines.len) : (measure_i += 1) {
                    const c_len = lines[measure_i].len;
                    const line_w = @as(f32, @floatFromInt(c_len)) * (config.base_font_size * 0.88 * 0.60);
                    if (line_w > max_code_line_w) max_code_line_w = line_w;
                }

                // Maximum horizontal scroll: right side aligned with right end of text line
                const max_scroll_x = @max(0.0, max_code_line_w - content_width + 16.0);
                const cur_scroll_x = if (block_id < MAX_SCROLLABLE_BLOCKS)
                    std.math.clamp(config.block_scroll_x[block_id], 0.0, max_scroll_x)
                else
                    0.0;

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

                // Register scrollable block
                if (cmd_count < commands_out.len) {
                    commands_out[cmd_count] = .{
                        .kind = .register_scrollable_block,
                        .rect = .{
                            .x = content_x - 12.0,
                            .y = cur_y,
                            .w = content_width + 24.0,
                            .h = code_block_h,
                        },
                        .scrollable_id = @intCast(block_id),
                        .max_scroll_x = max_scroll_x,
                    };
                    cmd_count += 1;
                }

                // Begin clip
                if (cmd_count < commands_out.len) {
                    commands_out[cmd_count] = .{
                        .kind = .begin_clip,
                        .rect = .{
                            .x = content_x - 12.0,
                            .y = cur_y,
                            .w = content_width + 24.0,
                            .h = code_block_h,
                        },
                    };
                    cmd_count += 1;
                }

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
                                .x = content_x - cur_scroll_x,
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

                // End clip
                if (cmd_count < commands_out.len) {
                    commands_out[cmd_count] = .{
                        .kind = .end_clip,
                        .rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
                    };
                    cmd_count += 1;
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
            const block_id = next_block_id;
            next_block_id += 1;

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
                    total_measured_w = content_width;
                }

                const max_scroll_x = @max(0.0, total_measured_w - content_width);
                const cur_scroll_x = if (block_id < MAX_SCROLLABLE_BLOCKS)
                    std.math.clamp(config.block_scroll_x[block_id], 0.0, max_scroll_x)
                else
                    0.0;

                // Register scrollable block
                if (cmd_count < commands_out.len) {
                    commands_out[cmd_count] = .{
                        .kind = .register_scrollable_block,
                        .rect = .{
                            .x = content_x - 4.0,
                            .y = cur_y,
                            .w = content_width + 8.0,
                            .h = table_h,
                        },
                        .scrollable_id = @intCast(block_id),
                        .max_scroll_x = max_scroll_x,
                    };
                    cmd_count += 1;
                }

                // Begin clip
                if (cmd_count < commands_out.len) {
                    commands_out[cmd_count] = .{
                        .kind = .begin_clip,
                        .rect = .{
                            .x = content_x - 4.0,
                            .y = cur_y - 2.0,
                            .w = content_width + 8.0,
                            .h = table_h + 4.0,
                        },
                    };
                    cmd_count += 1;
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
                            .rect = .{ .x = content_x - cur_scroll_x, .y = row_y + 2.0, .w = @max(content_width, total_measured_w), .h = 1.0 },
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
                    var cur_col_x = content_x - cur_scroll_x;

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
                        .rect = .{ .x = content_x - cur_scroll_x, .y = row_y + row_h - 2.0, .w = @max(content_width, total_measured_w), .h = 1.0 },
                        .color = theme.table_border,
                    };
                    cmd_count += 1;

                    row_y += row_h;
                }

                // End clip
                if (cmd_count < commands_out.len) {
                    commands_out[cmd_count] = .{
                        .kind = .end_clip,
                        .rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
                    };
                    cmd_count += 1;
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
        // Standalone Images: ![alt](url)
        // ----------------------------------------------------
        if (line_info.block_type == .image) {
            var text_slice = line_bytes;
            while (text_slice.len > 0 and (text_slice[0] == ' ' or text_slice[0] == '\t')) : (text_slice = text_slice[1..]) {}
            var alt_text: []const u8 = "";
            var img_url: []const u8 = "";
            if (text_slice.len >= 5 and text_slice[0] == '!' and text_slice[1] == '[') {
                var cb: usize = 2;
                while (cb < text_slice.len and text_slice[cb] != ']') : (cb += 1) {}
                if (cb + 1 < text_slice.len and text_slice[cb + 1] == '(') {
                    var cp: usize = cb + 2;
                    while (cp < text_slice.len and text_slice[cp] != ')') : (cp += 1) {}
                    if (cp <= text_slice.len) {
                        alt_text = text_slice[2..cb];
                        img_url = text_slice[cb + 2 .. cp];
                    }
                }
            }

            // Compute display dimensions: natural size capped to content_width,
            // maintaining aspect ratio. Falls back to 240px if not yet loaded.
            var nat_w: f32 = 0.0;
            var nat_h: f32 = 0.0;
            if (config.image_size_fn) |fn_ptr| {
                if (img_url.len > 0) {
                    fn_ptr(img_url.ptr, @intCast(img_url.len), &nat_w, &nat_h);
                }
            }

            const img_w: f32 = if (nat_w > 0.0) @min(nat_w, content_width) else content_width;
            const img_h: f32 = if (nat_w > 0.0 and nat_h > 0.0)
                nat_h * (img_w / nat_w)
            else
                240.0;

            const margin_top: f32 = 18.0;
            const margin_bottom: f32 = 18.0;
            const has_caption = alt_text.len > 0;
            const caption_h: f32 = if (has_caption) (config.line_height * 0.85 + 8.0) else 0.0;

            cur_y += margin_top;

            if (cur_y + img_h >= 0 and cur_y <= vp_bottom and cmd_count < commands_out.len) {
                commands_out[cmd_count] = .{
                    .kind = .image,
                    .rect = .{
                        .x = content_x, // left-aligned like web
                        .y = cur_y,
                        .w = img_w,
                        .h = img_h,
                    },
                    .text = alt_text,
                    .link_target = img_url,
                };
                cmd_count += 1;
            }

            if (has_caption) {
                const caption_y = cur_y + img_h + 6.0;
                if (caption_y + config.line_height >= 0 and caption_y <= vp_bottom and cmd_count < commands_out.len) {
                    const caption_w = measureTextEx(alt_text, config.base_font_size * 0.85, false, true, false, false);
                    commands_out[cmd_count] = .{
                        .kind = .text_run,
                        .rect = .{
                            .x = content_x, // left-aligned caption
                            .y = caption_y,
                            .w = caption_w,
                            .h = config.line_height * 0.85,
                        },
                        .color = theme.muted,
                        .text = alt_text,
                        .font_size = config.base_font_size * 0.85,
                        .style = .{ .italic = true },
                    };
                    cmd_count += 1;
                }
            }

            cur_y += img_h + caption_h + margin_bottom;
            continue;
        }

        // ----------------------------------------------------
        // Blockquote (Supports nested quotes)
        // ----------------------------------------------------
        if (line_info.block_type == .quote) {
            var text_slice = line_bytes;
            while (text_slice.len > 0 and (text_slice[0] == ' ' or text_slice[0] == '\t')) : (text_slice = text_slice[1..]) {}
            var quote_depth: usize = 0;
            while (text_slice.len > 0 and text_slice[0] == '>') {
                quote_depth += 1;
                text_slice = text_slice[1..];
                while (text_slice.len > 0 and (text_slice[0] == ' ' or text_slice[0] == '\t')) : (text_slice = text_slice[1..]) {}
            }

            const quote_margin = @as(f32, @floatFromInt(quote_depth)) * 16.0;
            const start_y = cur_y;

            const spans_n = parser.parseInlines(text_slice, &span_buf);
            cur_y = layoutWrappedSpans(
                span_buf[0..spans_n],
                content_x + quote_margin,
                content_width - quote_margin,
                start_y,
                config.base_font_size,
                config.line_height,
                theme.muted,
                theme.accent,
                vp_bottom,
                commands_out,
                &cmd_count,
            );

            const block_height = cur_y - start_y;

            if (start_y + block_height >= 0 and start_y <= vp_bottom) {
                var d: usize = 1;
                while (d <= quote_depth and cmd_count < commands_out.len) : (d += 1) {
                    const bar_margin = @as(f32, @floatFromInt(d)) * 16.0;
                    commands_out[cmd_count] = .{
                        .kind = .fill_rect,
                        .rect = .{
                            .x = content_x + bar_margin - 12.0,
                            .y = start_y,
                            .w = 3.0,
                            .h = block_height,
                        },
                        .color = theme.quote_bar,
                    };
                    cmd_count += 1;
                }
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
        // Paragraph with Word-Wrapping, Setext Headings, and Inline Spans
        // ----------------------------------------------------
        var is_setext_h1 = false;
        var is_setext_h2 = false;
        if (i + 1 < lines.len) {
            const next_info = lines[i + 1];
            const next_bytes = bytes[next_info.offset..][0..next_info.len];
            var next_trimmed = next_bytes;
            while (next_trimmed.len > 0 and (next_trimmed[0] == ' ' or next_trimmed[0] == '\t')) : (next_trimmed = next_trimmed[1..]) {}
            if (next_trimmed.len >= 2) {
                if (next_trimmed[0] == '=') {
                    var all_eq = true;
                    for (next_trimmed) |ch| {
                        if (ch != '=' and ch != ' ') {
                            all_eq = false;
                            break;
                        }
                    }
                    if (all_eq) is_setext_h1 = true;
                } else if (next_trimmed[0] == '-') {
                    var all_dash = true;
                    for (next_trimmed) |ch| {
                        if (ch != '-' and ch != ' ') {
                            all_dash = false;
                            break;
                        }
                    }
                    if (all_dash) is_setext_h2 = true;
                }
            }
        }

        if (is_setext_h1 or is_setext_h2) {
            const heading_level: usize = if (is_setext_h1) 1 else 2;
            const font_size = config.base_font_size * (if (heading_level == 1) @as(f32, 2.2) else @as(f32, 1.7));
            const heading_line_h = config.line_height * (if (heading_level == 1) @as(f32, 1.5) else @as(f32, 1.35));
            const margin_top = font_size * 1.5;
            const margin_bottom = font_size * 0.5;

            cur_y += margin_top;

            const span_count = parser.parseInlines(line_bytes, &span_buf);
            for (span_buf[0..span_count]) |*s| {
                s.style.heading = true;
                s.style.bold = true;
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
            i += 1; // Consume the underline line
            continue;
        }

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

/// High-speed virtualized layout generator.
/// Computes draw commands strictly for elements visible within the viewport window.
/// Zero heap allocations: writes directly into `commands_out`.
/// Seeks via sparse checkpoints, then funnels into `renderViewportCore`.
pub fn layoutViewport(
    bytes: []const u8,
    lines: []const simd.Line,
    config: ViewportConfig,
    commands_out: []DrawCommand,
) usize {
    if (commands_out.len == 0 or lines.len == 0) return 0;

    var i: usize = 0;
    var cur_y: f32 = 50.0 - config.scroll_y;
    var next_block_id: usize = 0;

    // Fast O(1) / O(log N) viewport seeking via sparse checkpoints
    if (config.checkpoints.len > 0 and config.scroll_y > 800.0) {
        const target_y = config.scroll_y - 600.0;
        var left: usize = 0;
        var right: usize = config.checkpoints.len;
        var best_cp: ?Checkpoint = null;

        while (left < right) {
            const mid = left + (right - left) / 2;
            if (config.checkpoints[mid].y <= target_y) {
                best_cp = config.checkpoints[mid];
                left = mid + 1;
            } else {
                right = mid;
            }
        }

        if (best_cp) |cp| {
            i = cp.line_idx;
            cur_y = cp.y - config.scroll_y;
            next_block_id = cp.next_block_id;
        }
    }

    return renderViewportCore(bytes, lines, config, i, cur_y, next_block_id, commands_out);
}

/// Computes the accurate total vertical height of the document based on font metrics,
/// margins, code blocks, tables, and word-wrapped content lines.
/// Zero heap allocations: works purely with stack buffers and font metrics tables.
pub fn computeDocumentHeight(
    bytes: []const u8,
    lines: []const simd.Line,
    config: ViewportConfig,
) f32 {
    return computeDocumentHeightEx(bytes, lines, config, null, null);
}

/// Computes accurate document height and optionally records sparse checkpoints
/// for O(1) viewport seeking during scrolling.
/// Zero heap allocations: works purely with stack buffers and font metrics tables.
pub fn computeDocumentHeightEx(
    bytes: []const u8,
    lines: []const simd.Line,
    config: ViewportConfig,
    checkpoints_out: ?[]Checkpoint,
    checkpoint_count_out: ?*usize,
) f32 {
    if (lines.len == 0) {
        if (checkpoint_count_out) |out| out.* = 0;
        return 0.0;
    }

    const content_width = if (config.window_width > config.content_max_width)
        config.content_max_width
    else
        @max(config.window_width - 64.0, 100.0);

    const content_x = if (config.window_width > config.content_max_width)
        (config.window_width - config.content_max_width) * 0.5
    else
        32.0;

    var cur_y: f32 = 50.0;
    var span_buf: [32]parser.InlineSpan = undefined;
    var i: usize = 0;
    var dummy_cmd_count: usize = 0;
    var cp_count: usize = 0;
    var last_cp_line: usize = 0;
    var next_block_id: usize = 0;

    while (i < lines.len) : (i += 1) {
        // Record sparse checkpoint at clean block boundary
        if (checkpoints_out) |cps| {
            if ((i == 0 or i >= last_cp_line + 128) and cp_count < cps.len) {
                cps[cp_count] = .{
                    .line_idx = @intCast(i),
                    .y = cur_y,
                    .next_block_id = @intCast(@min(next_block_id, 65535)),
                };
                cp_count += 1;
                last_cp_line = i;
            }
        }
        const line_info = lines[i];
        const line_bytes = bytes[line_info.offset..][0..line_info.len];

        // 1. Code blocks
        if (line_info.block_type == .code_fence_start) {
            var code_line_count: usize = 0;
            var scan_i = i + 1;
            while (scan_i < lines.len and lines[scan_i].block_type != .code_fence_end) : (scan_i += 1) {
                code_line_count += 1;
            }
            const code_block_h = (@as(f32, @floatFromInt(code_line_count)) * (config.line_height * 0.88)) + 24.0;
            cur_y += code_block_h + 16.0;
            next_block_id += 1;
            i = scan_i;
            continue;
        }

        if (line_info.block_type == .code_fence_end) {
            continue;
        }

        // 2. Tables
        if (line_info.block_type == .table_row) {
            var table_rows_count: usize = 0;
            var scan_i = i;
            while (scan_i < lines.len and lines[scan_i].block_type == .table_row) : (scan_i += 1) {
                table_rows_count += 1;
            }
            const row_h = config.line_height * 1.3;
            const table_h = @as(f32, @floatFromInt(table_rows_count)) * row_h;
            cur_y += table_h + 16.0;
            next_block_id += 1;
            i = scan_i - 1;
            continue;
        }

        // 3. Headings (H1 - H6)
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
                Color.transparent,
                Color.transparent,
                std.math.inf(f32),
                &.{},
                &dummy_cmd_count,
            );

            cur_y = end_y + margin_bottom;
            continue;
        }

        // 4. Horizontal Rule
        if (line_info.block_type == .hr) {
            cur_y += 24.0;
            continue;
        }

        // 5. Blank Line
        if (line_info.block_type == .blank) {
            cur_y += config.line_height * 0.75;
            continue;
        }

        // Image
        if (line_info.block_type == .image) {
            var text_slice = line_bytes;
            while (text_slice.len > 0 and (text_slice[0] == ' ' or text_slice[0] == '\t')) : (text_slice = text_slice[1..]) {}
            var alt_len: usize = 0;
            var img_url: []const u8 = "";
            if (text_slice.len >= 5 and text_slice[0] == '!' and text_slice[1] == '[') {
                var cb: usize = 2;
                while (cb < text_slice.len and text_slice[cb] != ']') : (cb += 1) {}
                alt_len = cb - 2;
                if (cb + 1 < text_slice.len and text_slice[cb + 1] == '(') {
                    var cp: usize = cb + 2;
                    while (cp < text_slice.len and text_slice[cp] != ')') : (cp += 1) {}
                    img_url = text_slice[cb + 2 .. cp];
                }
            }
            // Use natural size if callback available, else fixed fallback
            var nat_w2: f32 = 0.0;
            var nat_h2: f32 = 0.0;
            if (config.image_size_fn) |fn_ptr| {
                if (img_url.len > 0) {
                    fn_ptr(img_url.ptr, @intCast(img_url.len), &nat_w2, &nat_h2);
                }
            }
            const disp_w2: f32 = if (nat_w2 > 0.0) @min(nat_w2, content_width) else content_width;
            const img_h: f32 = if (nat_w2 > 0.0 and nat_h2 > 0.0)
                nat_h2 * (disp_w2 / nat_w2)
            else
                240.0;
            const margin_top: f32 = 18.0;
            const margin_bottom: f32 = 18.0;
            const caption_h: f32 = if (alt_len > 0) (config.line_height * 0.85 + 8.0) else 0.0;
            cur_y += margin_top + img_h + caption_h + margin_bottom;
            continue;
        }

        // 6. Blockquote
        if (line_info.block_type == .quote) {
            var text_slice = line_bytes;
            while (text_slice.len > 0 and (text_slice[0] == ' ' or text_slice[0] == '\t')) : (text_slice = text_slice[1..]) {}
            var quote_depth: usize = 0;
            while (text_slice.len > 0 and text_slice[0] == '>') {
                quote_depth += 1;
                text_slice = text_slice[1..];
                while (text_slice.len > 0 and (text_slice[0] == ' ' or text_slice[0] == '\t')) : (text_slice = text_slice[1..]) {}
            }

            const quote_margin = @as(f32, @floatFromInt(quote_depth)) * 16.0;
            const spans_n = parser.parseInlines(text_slice, &span_buf);
            cur_y = layoutWrappedSpans(
                span_buf[0..spans_n],
                content_x + quote_margin,
                content_width - quote_margin,
                cur_y,
                config.base_font_size,
                config.line_height,
                Color.transparent,
                Color.transparent,
                std.math.inf(f32),
                &.{},
                &dummy_cmd_count,
            );
            continue;
        }

        // 7. Task List
        if (line_info.block_type == .task_list) {
            var text_slice = line_bytes;
            while (text_slice.len > 0 and (text_slice[0] == ' ' or text_slice[0] == '\t')) : (text_slice = text_slice[1..]) {}
            const text_start = if (text_slice.len >= 5) 5 else text_slice.len;
            const item_text = if (text_start < text_slice.len and text_slice[text_start] == ' ')
                text_slice[text_start + 1 ..]
            else
                text_slice[text_start..];

            const spans_n = parser.parseInlines(item_text, &span_buf);
            cur_y = layoutWrappedSpans(
                span_buf[0..spans_n],
                content_x + 28.0,
                content_width - 28.0,
                cur_y,
                config.base_font_size,
                config.line_height,
                Color.transparent,
                Color.transparent,
                std.math.inf(f32),
                &.{},
                &dummy_cmd_count,
            );
            continue;
        }

        // 8. Lists (Bullet & Ordered)
        if (line_info.block_type == .bullet_list or line_info.block_type == .ordered_list) {
            var text_slice = line_bytes;
            var indent_level: f32 = @floatFromInt(line_info.indent);
            if (indent_level > 32) indent_level = 32;

            while (text_slice.len > 0 and (text_slice[0] == ' ' or text_slice[0] == '\t')) : (text_slice = text_slice[1..]) {}

            var prefix_len: usize = 0;
            if (line_info.block_type == .bullet_list and text_slice.len >= 2) {
                prefix_len = 2;
            } else if (line_info.block_type == .ordered_list) {
                while (prefix_len < text_slice.len and text_slice[prefix_len] != ' ') : (prefix_len += 1) {}
                if (prefix_len < text_slice.len) prefix_len += 1;
            }

            const item_text = text_slice[prefix_len..];
            const bullet_x = content_x + indent_level * 10.0;
            const text_x = bullet_x + 18.0;

            const spans_n = parser.parseInlines(item_text, &span_buf);
            cur_y = layoutWrappedSpans(
                span_buf[0..spans_n],
                text_x,
                content_width - (text_x - content_x),
                cur_y,
                config.base_font_size,
                config.line_height,
                Color.transparent,
                Color.transparent,
                std.math.inf(f32),
                &.{},
                &dummy_cmd_count,
            );
            continue;
        }

        // 9. Paragraph / Setext
        var is_setext_h1 = false;
        var is_setext_h2 = false;
        if (i + 1 < lines.len) {
            const next_info = lines[i + 1];
            const next_bytes = bytes[next_info.offset..][0..next_info.len];
            var next_trimmed = next_bytes;
            while (next_trimmed.len > 0 and (next_trimmed[0] == ' ' or next_trimmed[0] == '\t')) : (next_trimmed = next_trimmed[1..]) {}
            if (next_trimmed.len >= 2) {
                if (next_trimmed[0] == '=') {
                    var all_eq = true;
                    for (next_trimmed) |ch| {
                        if (ch != '=' and ch != ' ') {
                            all_eq = false;
                            break;
                        }
                    }
                    if (all_eq) is_setext_h1 = true;
                } else if (next_trimmed[0] == '-') {
                    var all_dash = true;
                    for (next_trimmed) |ch| {
                        if (ch != '-' and ch != ' ') {
                            all_dash = false;
                            break;
                        }
                    }
                    if (all_dash) is_setext_h2 = true;
                }
            }
        }

        if (is_setext_h1 or is_setext_h2) {
            const heading_level: usize = if (is_setext_h1) 1 else 2;
            const font_size = config.base_font_size * (if (heading_level == 1) @as(f32, 2.2) else @as(f32, 1.7));
            const heading_line_h = config.line_height * (if (heading_level == 1) @as(f32, 1.5) else @as(f32, 1.35));
            const margin_top = font_size * 1.5;
            const margin_bottom = font_size * 0.5;

            cur_y += margin_top;

            const span_count = parser.parseInlines(line_bytes, &span_buf);
            for (span_buf[0..span_count]) |*s| {
                s.style.heading = true;
                s.style.bold = true;
            }

            const end_y = layoutWrappedSpans(
                span_buf[0..span_count],
                content_x,
                content_width,
                cur_y,
                font_size,
                heading_line_h,
                Color.transparent,
                Color.transparent,
                std.math.inf(f32),
                &.{},
                &dummy_cmd_count,
            );

            cur_y = end_y + margin_bottom;
            i += 1;
            continue;
        }

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
            Color.transparent,
            Color.transparent,
            std.math.inf(f32),
            &.{},
            &dummy_cmd_count,
        ) + 4.0;
    }

    if (checkpoint_count_out) |out| {
        out.* = cp_count;
    }

    return cur_y + 50.0;
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
                "Main",        "Secondary",  "Section",    "paragraph", "blockquote",
                "item_alpha",  "item_beta",  "item_gamma", "step_one:", "step_two:",
                "step_three:", "step_four:", "task_one",   "task_two",  "task_three",
                "Data 1",      "Data 4",     "trailing",
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

test "STRICT FOOTPRINT: 64-bit packed Line struct and sparse checkpoint seek" {
    // 1. Invariance: Line must be exactly 8 bytes (64 bits) for cache-line alignment and -33% memory footprint
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(simd.Line));

    const allocator = std.testing.allocator;
    const doc_chunk =
        \\# Chapter Heading
        \\Paragraph line one of text with some **bold** content.
        \\Paragraph line two continuing the narrative.
        \\- Bullet list item
        \\
    ;

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);

    var i: usize = 0;
    while (i < 500) : (i += 1) {
        try buffer.appendSlice(allocator, doc_chunk);
    }

    const mem = buffer.items;
    var lines_buf: [3000]simd.Line = undefined;
    var in_fence = false;
    const line_count = simd.scanLines(mem, &lines_buf, &in_fence);

    var checkpoints: [64]Checkpoint = undefined;
    var cp_count: usize = 0;

    const vp_config_base = ViewportConfig{
        .window_width = 800.0,
        .window_height = 600.0,
        .scroll_y = 0.0,
    };

    _ = computeDocumentHeightEx(
        mem,
        lines_buf[0..line_count],
        vp_config_base,
        &checkpoints,
        &cp_count,
    );

    try std.testing.expect(cp_count > 0);

    // Test deep scroll: with checkpoints vs without checkpoints
    const scroll_target = 5000.0;
    const config_no_cp = ViewportConfig{
        .window_width = 800.0,
        .window_height = 600.0,
        .scroll_y = scroll_target,
    };
    const config_with_cp = ViewportConfig{
        .window_width = 800.0,
        .window_height = 600.0,
        .scroll_y = scroll_target,
        .checkpoints = checkpoints[0..cp_count],
    };

    var cmds_no_cp: [512]DrawCommand = undefined;
    var cmds_with_cp: [512]DrawCommand = undefined;

    const count_no_cp = layoutViewport(mem, lines_buf[0..line_count], config_no_cp, &cmds_no_cp);
    const count_with_cp = layoutViewport(mem, lines_buf[0..line_count], config_with_cp, &cmds_with_cp);

    // Must generate the exact same visible draw commands
    try std.testing.expectEqual(count_no_cp, count_with_cp);
    for (cmds_no_cp[0..count_no_cp], 0..) |cmd_a, idx| {
        const cmd_b = cmds_with_cp[idx];
        try std.testing.expectEqual(cmd_a.kind, cmd_b.kind);
        try std.testing.expectApproxEqAbs(cmd_a.rect.x, cmd_b.rect.x, 0.01);
        try std.testing.expectApproxEqAbs(cmd_a.rect.y, cmd_b.rect.y, 0.01);
        try std.testing.expectApproxEqAbs(cmd_a.rect.w, cmd_b.rect.w, 0.01);
        try std.testing.expectApproxEqAbs(cmd_a.rect.h, cmd_b.rect.h, 0.01);
    }
}

// ============================================================================
// Virtualized lazy layout: time-sliced amortized layout + Goldilocks buffer
// + estimated heights with just-in-time refinement.
//
// Ideas implemented (todo/ideas.txt 9-11, todo/ideas2.txt 17-22):
//   * Estimated heights: every off-screen block gets a cheap byte-length
//     heuristic height; the sum drives the scrollbar without exact layout.
//   * Goldilocks buffer: a sliding window of viewport + exactly 1 screen
//     above/below. Scrolling incrementally parses in the entering edge and
//     aggressively drops the evicted edge, bounding live layout data to
//     ~3 screens. Window edges snap to block boundaries.
//   * Time-sliced layout: `LayoutJob` is a resumable state machine with a
//     strict ~2ms/frame budget; it yields to the UI and resumes next tick.
//   * Scroll anchoring: when a refined height differs from its estimate,
//     the delta above the viewport is folded into the scroll offset so the
//     top-most visible element stays pixel-locked.
//   * JIT viewport: `layoutViewportJIT` measures exactly only the blocks
//     entering the Goldilocks window and renders from the shared
//     `renderViewportCore`, so output is identical to `layoutViewport`.
//
// Zero heap allocations everywhere below: caller-owned buffers + stack only.
// Callers must call `VirtualCache.reset()` when image natural sizes arrive
// asynchronously (image heights depend on live `image_size_fn` results).
// ============================================================================

/// Strict per-frame time budget for background layout work (~2ms of a 16ms frame).
pub const FRAME_BUDGET_NS: u64 = 2_000_000;
/// Budget clock is sampled every N lines to amortize `clock_gettime` cost.
pub const BUDGET_POLL_LINES: usize = 32;
/// Max lines pinned in the Goldilocks window (~3 screens worst case).
pub const MAX_WINDOW_LINES: usize = 1024;
/// Screens buffered above and below the viewport (exactly 1 + 1).
pub const GOLDILOCKS_SCREENS_ABOVE: f32 = 1.0;
pub const GOLDILOCKS_SCREENS_BELOW: f32 = 1.0;

fn contentWidthOf(config: ViewportConfig) f32 {
    return if (config.window_width > config.content_max_width)
        config.content_max_width
    else
        @max(config.window_width - 64.0, 100.0);
}

fn contentXOf(config: ViewportConfig) f32 {
    return if (config.window_width > config.content_max_width)
        (config.window_width - config.content_max_width) * 0.5
    else
        32.0;
}

/// Cheap byte-length heuristic height for one off-screen line.
/// No inline parsing, no font-table walks: O(1), branch-light.
/// Fixed-height block types are exact; wrapped text estimates visual lines
/// from `byte_len * font_size * 0.5 / content_width`. Multi-line units
/// (fences, tables, setext) are estimated per line here and corrected to
/// exact heights by JIT refinement when they enter the Goldilocks window.
pub fn estimateBlockHeight(line: simd.Line, config: ViewportConfig, content_width: f32) f32 {
    const lh = config.line_height;
    const bt = line.block_type;
    if (bt == .blank) return lh * 0.75;
    if (bt == .hr) return 24.0;
    if (bt == .code_fence_start or bt == .code_fence_end) return 20.0;
    if (bt == .code_line) return lh * 0.88;
    if (bt == .table_row) return lh * 1.3;
    if (bt == .image) return 240.0 + 36.0;

    const level: u5 = @intFromEnum(bt);
    var font_size = config.base_font_size;
    var line_h = lh;
    var avail_w = content_width;
    var extra: f32 = 4.0;
    var margin_top: f32 = 0.0;
    var margin_bottom: f32 = 0.0;
    if (level >= 1 and level <= 6) {
        const s: f32 = switch (level) {
            1 => 2.1,
            2 => 1.6,
            3 => 1.3,
            4 => 1.15,
            else => 1.05,
        };
        font_size = config.base_font_size * s;
        line_h = font_size * 1.3;
        margin_top = font_size * 2.5;
        margin_bottom = font_size * 0.5;
        extra = 0.0;
    } else if (bt == .quote) {
        avail_w = content_width - 16.0;
        extra = 0.0;
    } else if (bt == .task_list or bt == .bullet_list or bt == .ordered_list) {
        avail_w = content_width - 28.0;
        extra = 0.0;
    }
    const text_w = @as(f32, @floatFromInt(line.len)) * font_size * 0.5;
    const wrapped = @max(1.0, @ceil(text_w / @max(avail_w, 1.0)));
    return margin_top + wrapped * line_h + margin_bottom + extra;
}

/// Heuristic total document height for the scrollbar: one O(n) pass of
/// `estimateBlockHeight`, no parsing, zero allocations. Converges to the
/// exact height as `LayoutJob` refines blocks in the background.
pub fn estimateDocumentHeight(lines: []const simd.Line, config: ViewportConfig) f32 {
    if (lines.len == 0) return 0.0;
    const cw = contentWidthOf(config);
    var total: f32 = 50.0;
    for (lines) |ln| total += estimateBlockHeight(ln, config, cw);
    return total + 50.0;
}

/// Scroll anchoring: lock the top-most visible element when a refined height
/// above the viewport differs from its estimate by `delta_above`.
/// The caller shifts the scroll offset by the same delta the total height
/// moved, so content never jumps (`scroll_y` clamped at 0).
pub fn anchorScrollForDelta(scroll_y: f32, delta_above: f32) f32 {
    return @max(0.0, scroll_y + delta_above);
}

/// Exact height of the layout unit starting at `lines[idx]`, measured with
/// the same `layoutWrappedSpans` path the renderer uses, so refined heights
/// match on-screen rendering bit-for-bit. `consumed` is the number of source
/// lines folded into this unit (multi-line fences, tables, setext pairs);
/// follower lines refine to height 0. Zero heap allocations (stack spans).
pub const RefinedUnit = struct { height: f32, consumed: usize };

pub fn refineLineHeight(
    bytes: []const u8,
    lines: []const simd.Line,
    idx: usize,
    config: ViewportConfig,
    content_width: f32,
    content_x: f32,
) RefinedUnit {
    const lh = config.line_height;
    const info = lines[idx];
    const line_bytes = bytes[info.offset..][0..info.len];
    var span_buf: [32]parser.InlineSpan = undefined;
    var dummy: usize = 0;

    switch (info.block_type) {
        .blank => return .{ .height = lh * 0.75, .consumed = 1 },
        .hr => return .{ .height = 24.0, .consumed = 1 },
        .code_line => return .{ .height = lh * 0.88, .consumed = 1 },
        .code_fence_end => return .{ .height = 0.0, .consumed = 1 },
        .code_fence_start => {
            var n: usize = 0;
            var j = idx + 1;
            while (j < lines.len and lines[j].block_type != .code_fence_end) : ({
                j += 1;
                n += 1;
            }) {}
            const h = @as(f32, @floatFromInt(n)) * (lh * 0.88) + 24.0 + 16.0;
            const consumed = if (j < lines.len) j - idx + 1 else lines.len - idx;
            return .{ .height = h, .consumed = consumed };
        },
        .table_row => {
            var j = idx;
            while (j < lines.len and lines[j].block_type == .table_row) : (j += 1) {}
            const h = @as(f32, @floatFromInt(j - idx)) * (lh * 1.3) + 16.0;
            return .{ .height = h, .consumed = j - idx };
        },
        .image => {
            var text_slice = line_bytes;
            while (text_slice.len > 0 and (text_slice[0] == ' ' or text_slice[0] == '\t')) : (text_slice = text_slice[1..]) {}
            var alt_len: usize = 0;
            var img_url: []const u8 = "";
            if (text_slice.len >= 5 and text_slice[0] == '!' and text_slice[1] == '[') {
                var cb: usize = 2;
                while (cb < text_slice.len and text_slice[cb] != ']') : (cb += 1) {}
                alt_len = if (cb >= 2) cb - 2 else 0;
                if (cb + 1 < text_slice.len and text_slice[cb + 1] == '(') {
                    var cp: usize = cb + 2;
                    while (cp < text_slice.len and text_slice[cp] != ')') : (cp += 1) {}
                    img_url = text_slice[cb + 2 .. cp];
                }
            }
            var nat_w: f32 = 0.0;
            var nat_h: f32 = 0.0;
            if (config.image_size_fn) |fn_ptr| {
                if (img_url.len > 0) fn_ptr(img_url.ptr, @intCast(img_url.len), &nat_w, &nat_h);
            }
            const disp_w: f32 = if (nat_w > 0.0) @min(nat_w, content_width) else content_width;
            const img_h: f32 = if (nat_w > 0.0 and nat_h > 0.0) nat_h * (disp_w / nat_w) else 240.0;
            const caption_h: f32 = if (alt_len > 0) (lh * 0.85 + 8.0) else 0.0;
            return .{ .height = 18.0 + img_h + caption_h + 18.0, .consumed = 1 };
        },
        .heading1, .heading2, .heading3, .heading4, .heading5, .heading6 => {
            const level = @intFromEnum(info.block_type);
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
            const span_count = parser.parseInlines(line_bytes[h_offset..], &span_buf);
            for (span_buf[0..span_count]) |*s| {
                s.style.bold = true;
                s.style.heading = true;
            }
            const end_y = layoutWrappedSpans(span_buf[0..span_count], content_x, content_width, 0, font_size, heading_line_h, Color.transparent, Color.transparent, std.math.inf(f32), &.{}, &dummy);
            return .{ .height = margin_top + end_y + margin_bottom, .consumed = 1 };
        },
        .quote => {
            var text_slice = line_bytes;
            while (text_slice.len > 0 and (text_slice[0] == ' ' or text_slice[0] == '\t')) : (text_slice = text_slice[1..]) {}
            var quote_depth: usize = 0;
            while (text_slice.len > 0 and text_slice[0] == '>') {
                quote_depth += 1;
                text_slice = text_slice[1..];
                while (text_slice.len > 0 and (text_slice[0] == ' ' or text_slice[0] == '\t')) : (text_slice = text_slice[1..]) {}
            }
            const quote_margin = @as(f32, @floatFromInt(quote_depth)) * 16.0;
            const spans_n = parser.parseInlines(text_slice, &span_buf);
            const end_y = layoutWrappedSpans(span_buf[0..spans_n], content_x + quote_margin, content_width - quote_margin, 0, config.base_font_size, lh, Color.transparent, Color.transparent, std.math.inf(f32), &.{}, &dummy);
            return .{ .height = end_y, .consumed = 1 };
        },
        .task_list => {
            var text_slice = line_bytes;
            while (text_slice.len > 0 and (text_slice[0] == ' ' or text_slice[0] == '\t')) : (text_slice = text_slice[1..]) {}
            const text_start = if (text_slice.len >= 5) 5 else text_slice.len;
            const item_text = if (text_start < text_slice.len and text_slice[text_start] == ' ')
                text_slice[text_start + 1 ..]
            else
                text_slice[text_start..];
            const spans_n = parser.parseInlines(item_text, &span_buf);
            const end_y = layoutWrappedSpans(span_buf[0..spans_n], content_x + 28.0, content_width - 28.0, 0, config.base_font_size, lh, Color.transparent, Color.transparent, std.math.inf(f32), &.{}, &dummy);
            return .{ .height = end_y, .consumed = 1 };
        },
        .bullet_list, .ordered_list => {
            var text_slice = line_bytes;
            var indent_level: f32 = @floatFromInt(info.indent);
            if (indent_level > 32) indent_level = 32;
            while (text_slice.len > 0 and (text_slice[0] == ' ' or text_slice[0] == '\t')) : (text_slice = text_slice[1..]) {}
            var prefix_len: usize = 0;
            if (info.block_type == .bullet_list and text_slice.len >= 2) {
                prefix_len = 2;
            } else if (info.block_type == .ordered_list) {
                while (prefix_len < text_slice.len and text_slice[prefix_len] != ' ') : (prefix_len += 1) {}
                if (prefix_len < text_slice.len) prefix_len += 1;
            }
            const item_text = text_slice[prefix_len..];
            const bullet_x = content_x + indent_level * 10.0;
            const text_x = bullet_x + 18.0;
            const spans_n = parser.parseInlines(item_text, &span_buf);
            const end_y = layoutWrappedSpans(span_buf[0..spans_n], text_x, content_width - (text_x - content_x), 0, config.base_font_size, lh, Color.transparent, Color.transparent, std.math.inf(f32), &.{}, &dummy);
            return .{ .height = end_y, .consumed = 1 };
        },
        .paragraph => {
            if (isSetextUnderline(bytes, lines, idx + 1)) {
                const heading_level: usize = blk: {
                    var t = bytes[lines[idx + 1].offset..][0..lines[idx + 1].len];
                    while (t.len > 0 and (t[0] == ' ' or t[0] == '\t')) : (t = t[1..]) {}
                    break :blk if (t.len > 0 and t[0] == '=') 1 else 2;
                };
                const font_size = config.base_font_size * (if (heading_level == 1) @as(f32, 2.2) else @as(f32, 1.7));
                const heading_line_h = lh * (if (heading_level == 1) @as(f32, 1.5) else @as(f32, 1.35));
                const margin_top = font_size * 1.5;
                const margin_bottom = font_size * 0.5;
                const span_count = parser.parseInlines(line_bytes, &span_buf);
                for (span_buf[0..span_count]) |*s| {
                    s.style.heading = true;
                    s.style.bold = true;
                }
                const end_y = layoutWrappedSpans(span_buf[0..span_count], content_x, content_width, 0, font_size, heading_line_h, Color.transparent, Color.transparent, std.math.inf(f32), &.{}, &dummy);
                return .{ .height = margin_top + end_y + margin_bottom, .consumed = 2 };
            }
            const span_count = parser.parseInlines(line_bytes, &span_buf);
            if (span_count == 0) return .{ .height = lh * 0.5, .consumed = 1 };
            const end_y = layoutWrappedSpans(span_buf[0..span_count], content_x, content_width, 0, config.base_font_size, lh, Color.transparent, Color.transparent, std.math.inf(f32), &.{}, &dummy);
            return .{ .height = end_y + 4.0, .consumed = 1 };
        },
    }
}

/// True when `lines[idx]` is a setext underline (`===` / `---`) for the
/// paragraph above it. Mirrors the renderer's detection exactly.
pub fn isSetextUnderline(bytes: []const u8, lines: []const simd.Line, idx: usize) bool {
    if (idx == 0 or idx >= lines.len) return false;
    if (lines[idx].block_type != .paragraph) return false;
    const ub = bytes[lines[idx].offset..][0..lines[idx].len];
    var t = ub;
    while (t.len > 0 and (t[0] == ' ' or t[0] == '\t')) : (t = t[1..]) {}
    if (t.len < 2) return false;
    if (t[0] == '=') {
        for (t) |ch| if (ch != '=' and ch != ' ') return false;
        return true;
    }
    if (t[0] == '-') {
        for (t) |ch| if (ch != '-' and ch != ' ') return false;
        return true;
    }
    return false;
}

/// Counts scrollable blocks (fenced code + tables) in the unit-aligned range
/// `[start, end)`. Caller must pass block-boundary-aligned ranges (window
/// edges are always snapped), so run/fence splitting cannot occur.
pub fn countScrollableBlocks(lines: []const simd.Line, start: usize, end: usize) usize {
    var n: usize = 0;
    var j = start;
    while (j < end) : (j += 1) {
        const bt = lines[j].block_type;
        if (bt == .code_fence_start) {
            n += 1;
        } else if (bt == .table_row) {
            if (j == 0 or lines[j - 1].block_type != .table_row) n += 1;
        }
    }
    return n;
}

/// Snaps a window start index backwards to a layout-unit boundary so rendering
/// never begins mid-fence, mid-table, or on a setext underline.
pub fn snapWindowStart(bytes: []const u8, lines: []const simd.Line, idx: usize) usize {
    var s = @min(idx, lines.len);
    var guard: usize = 0;
    while (s > 0 and guard < 8) : (guard += 1) {
        if (s >= lines.len) {
            s -= 1;
            continue;
        }
        const bt = lines[s].block_type;
        if (bt == .code_line or bt == .code_fence_end) {
            if (s == 0) break;
            s -= 1;
            while (s > 0 and lines[s].block_type == .code_line) : (s -= 1) {}
        } else if (bt == .table_row) {
            while (s > 0 and lines[s - 1].block_type == .table_row) : (s -= 1) {}
            break;
        } else if (isSetextUnderline(bytes, lines, s)) {
            s -= 1;
        } else break;
    }
    return s;
}

/// Snaps a window end index forwards past any unit it would otherwise split.
pub fn snapWindowEnd(bytes: []const u8, lines: []const simd.Line, idx: usize) usize {
    var e = @min(idx, lines.len);
    if (e < lines.len and (lines[e].block_type == .code_line or lines[e].block_type == .code_fence_end)) {
        while (e < lines.len and lines[e].block_type != .code_fence_end) : (e += 1) {}
        if (e < lines.len) e += 1;
    }
    if (e < lines.len and lines[e].block_type == .table_row) {
        while (e < lines.len and lines[e].block_type == .table_row) : (e += 1) {}
    }
    if (e < lines.len and e > 0 and isSetextUnderline(bytes, lines, e)) e += 1;
    return @min(e, lines.len);
}

/// Goldilocks buffer: sliding window of viewport + exactly 1 screen
/// above/below (`GOLDILOCKS_SCREENS_ABOVE/BELOW`). Holds refined heights for
/// pinned lines only (~3 screens); everything outside the window lives as
/// byte-length estimates. Scrolling incrementally parses in the entering
/// edge and aggressively drops the evicted edge. Caller-owned, zero heap
/// allocations. Not thread-safe.
pub const VirtualCache = struct {
    win_start: usize = 0,
    win_len: usize = 0,
    win_top_y: f32 = 50.0,
    win_block_id: usize = 0,
    heights: [MAX_WINDOW_LINES]f32 = [_]f32{0} ** MAX_WINDOW_LINES,
    units: [MAX_WINDOW_LINES]u32 = [_]u32{0} ** MAX_WINDOW_LINES,
    last_scroll_y: f32 = 0.0,
    total_lines: usize = 0,
    warm: bool = false,
    window_width: f32 = 0.0,
    content_max_width: f32 = 600.0,
    base_font_size: f32 = 17.0,
    line_height: f32 = 29.75,

    pub fn reset(self: *VirtualCache) void {
        self.win_start = 0;
        self.win_len = 0;
        self.win_top_y = 50.0;
        self.win_block_id = 0;
        self.last_scroll_y = 0.0;
        self.total_lines = 0;
        self.warm = false;
    }

    fn geometryMatches(self: *const VirtualCache, config: ViewportConfig) bool {
        return self.window_width == config.window_width and
            self.content_max_width == config.content_max_width and
            self.base_font_size == config.base_font_size and
            self.line_height == config.line_height;
    }

    fn storeGeometry(self: *VirtualCache, config: ViewportConfig) void {
        self.window_width = config.window_width;
        self.content_max_width = config.content_max_width;
        self.base_font_size = config.base_font_size;
        self.line_height = config.line_height;
    }

    pub fn winEnd(self: *const VirtualCache) usize {
        return self.win_start + self.win_len;
    }

    pub fn bottomY(self: *const VirtualCache) f32 {
        var y = self.win_top_y;
        for (self.heights[0..self.win_len]) |h| y += h;
        return y;
    }

    /// True when the pinned window spans the full Goldilocks range
    /// `[scroll - H, scroll + 2H]` (or the document edge when shorter).
    pub fn covers(self: *const VirtualCache, scroll_y: f32, window_height: f32, total_lines: usize) bool {
        const lo = @max(0.0, scroll_y - window_height * GOLDILOCKS_SCREENS_ABOVE);
        const hi = scroll_y + window_height * (1.0 + GOLDILOCKS_SCREENS_BELOW);
        const top_ok = (self.win_start == 0) or (self.win_top_y <= lo + 0.5);
        const bot_ok = (self.winEnd() == total_lines) or (self.bottomY() >= hi - 0.5);
        return top_ok and bot_ok;
    }

    /// Ensures the window covers the Goldilocks range for `config.scroll_y`.
    /// Steady small scrolls shift incrementally (evict one edge, parse in
    /// the other); jumps and geometry/doc changes recompute. Static frames
    /// return immediately with zero work.
    pub fn update(self: *VirtualCache, bytes: []const u8, lines: []const simd.Line, config: ViewportConfig) void {
        if (lines.len == 0) {
            self.reset();
            return;
        }
        if (!self.geometryMatches(config) or self.total_lines != lines.len) {
            self.storeGeometry(config);
            self.win_start = 0;
            self.win_len = 0;
            self.win_top_y = 50.0;
            self.win_block_id = 0;
            self.warm = false;
            self.total_lines = lines.len;
        }
        const scroll = @max(0.0, config.scroll_y);
        if (self.warm and scroll == self.last_scroll_y) return;
        const vh = config.window_height;
        const lo_target = @max(0.0, scroll - vh * GOLDILOCKS_SCREENS_ABOVE);
        const hi_target = scroll + vh * (1.0 + GOLDILOCKS_SCREENS_BELOW);
        const cw = contentWidthOf(config);
        const cx = contentXOf(config);

        if (!self.warm or self.win_len == 0 or lo_target > self.bottomY() or hi_target < self.win_top_y) {
            self.coldRecompute(bytes, lines, config, cw, cx, lo_target, hi_target);
        } else {
            self.evictFront(lines, lo_target);
            self.prependBack(bytes, lines, config, cw, cx, lo_target);
            self.extendBack(bytes, lines, config, cw, cx, hi_target);
            self.truncateBack(hi_target);
        }
        self.last_scroll_y = scroll;
        self.warm = true;
    }

    /// Jump path: one estimate pass from doc top to find the window start,
    /// then exact refinement of entering lines only. One-time cost per jump;
    /// steady scrolling afterwards is incremental and exact.
    fn coldRecompute(
        self: *VirtualCache,
        bytes: []const u8,
        lines: []const simd.Line,
        config: ViewportConfig,
        cw: f32,
        cx: f32,
        lo_target: f32,
        hi_target: f32,
    ) void {
        var y: f32 = 50.0;
        var i: usize = 0;
        var block_id: usize = 0;
        while (i < lines.len) {
            const eh = estimateBlockHeight(lines[i], config, cw);
            if (y + eh > lo_target) break;
            y += eh;
            const bt = lines[i].block_type;
            if (bt == .code_fence_start) {
                block_id += 1;
            } else if (bt == .table_row and (i == 0 or lines[i - 1].block_type != .table_row)) {
                block_id += 1;
            }
            i += 1;
        }
        const s0 = snapWindowStart(bytes, lines, i);
        y -= self.estimateRange(lines, config, s0, i);
        block_id -= countScrollableBlocks(lines, s0, i);
        self.win_start = s0;
        self.win_len = 0;
        self.win_top_y = y;
        self.win_block_id = block_id;
        const end = self.refineAppend(bytes, lines, config, cw, cx, s0, hi_target);
        _ = end;
    }

    fn estimateRange(
        self: *const VirtualCache,
        lines: []const simd.Line,
        config: ViewportConfig,
        start: usize,
        end: usize,
    ) f32 {
        _ = self;
        const cw = contentWidthOf(config);
        var total: f32 = 0.0;
        var j = start;
        while (j < end and j < lines.len) : (j += 1) total += estimateBlockHeight(lines[j], config, cw);
        return total;
    }

    /// Scroll-down path: drop leading units fully above the top buffer
    /// (aggressive free at the evicted edge). Steps by refined unit so both
    /// edges stay block-aligned; evicted heights are exact, keeping
    /// `win_top_y` pixel-accurate for incremental scrolls.
    fn evictFront(self: *VirtualCache, lines: []const simd.Line, lo_target: f32) void {
        while (self.win_len > 0) {
            const c: usize = @max(@as(usize, self.units[0]), 1);
            if (c >= self.win_len) break; // never evict the final unit here
            const h = self.heights[0];
            if (self.win_top_y + h > lo_target) break;
            self.win_top_y += h;
            self.win_block_id += countScrollableBlocks(lines, self.win_start, self.win_start + c);
            var k: usize = 0;
            while (k + c < self.win_len) : (k += 1) {
                self.heights[k] = self.heights[k + c];
                self.units[k] = self.units[k + c];
            }
            self.win_start += c;
            self.win_len -= c;
        }
    }

    /// Scroll-up path: parse in lines entering the top buffer, refining them
    /// exactly. Each batch is sized with cheap estimates, snapped to a unit
    /// boundary, then measured exactly.
    fn prependBack(
        self: *VirtualCache,
        bytes: []const u8,
        lines: []const simd.Line,
        config: ViewportConfig,
        cw: f32,
        cx: f32,
        lo_target: f32,
    ) void {
        while (self.win_top_y > lo_target and self.win_start > 0) {
            const old_start = self.win_start;
            var back = old_start;
            var est_y = self.win_top_y;
            while (back > 0 and est_y > lo_target and (old_start - back) < (MAX_WINDOW_LINES - self.win_len)) {
                back -= 1;
                est_y += estimateBlockHeight(lines[back], config, cw);
            }
            const s0 = snapWindowStart(bytes, lines, back);
            const m = old_start - s0;
            if (m == 0) break;
            if (self.win_len + m > MAX_WINDOW_LINES) {
                self.coldRecompute(bytes, lines, config, cw, cx, lo_target, self.bottomY());
                return;
            }
            var k = self.win_len;
            while (k > 0) {
                k -= 1;
                self.heights[k + m] = self.heights[k];
                self.units[k + m] = self.units[k];
            }
            var j = s0;
            var slot: usize = 0;
            var added: f32 = 0.0;
            while (j < old_start) {
                const u = refineLineHeight(bytes, lines, j, config, cw, cx);
                self.heights[slot] = u.height;
                self.units[slot] = @as(u32, @intCast(@min(u.consumed, std.math.maxInt(u32))));
                added += u.height;
                var f: usize = 1;
                while (f < u.consumed) : (f += 1) {
                    slot += 1;
                    self.heights[slot] = 0.0;
                    self.units[slot] = 0;
                }
                slot += 1;
                j += u.consumed;
            }
            std.debug.assert(slot == m);
            self.win_block_id -= countScrollableBlocks(lines, s0, old_start);
            self.win_start = s0;
            self.win_len += slot;
            self.win_top_y -= added;
        }
    }

    /// Scroll-down path: parse in lines entering the bottom buffer, refining
    /// exactly, until coverage reaches `hi_target` (snapping past split units).
    fn extendBack(
        self: *VirtualCache,
        bytes: []const u8,
        lines: []const simd.Line,
        config: ViewportConfig,
        cw: f32,
        cx: f32,
        hi_target: f32,
    ) void {
        _ = self.refineAppend(bytes, lines, config, cw, cx, self.winEnd(), hi_target);
    }

    /// Appends refined units starting at line `j0` until coverage reaches
    /// `hi_target` (plus unit continuation). Returns the new end index.
    /// Units are never split at the `MAX_WINDOW_LINES` cap.
    fn refineAppend(
        self: *VirtualCache,
        bytes: []const u8,
        lines: []const simd.Line,
        config: ViewportConfig,
        cw: f32,
        cx: f32,
        j0: usize,
        hi_target: f32,
    ) usize {
        var j = j0;
        var y = self.bottomY();
        while (j < lines.len and self.win_len < MAX_WINDOW_LINES and
            (y < hi_target or unitContinuesAt(bytes, lines, j)))
        {
            const u = refineLineHeight(bytes, lines, j, config, cw, cx);
            if (self.win_len + u.consumed > MAX_WINDOW_LINES) break;
            self.heights[self.win_len] = u.height;
            self.units[self.win_len] = @as(u32, @intCast(@min(u.consumed, std.math.maxInt(u32))));
            var f: usize = 1;
            while (f < u.consumed) : (f += 1) {
                self.heights[self.win_len + f] = 0.0;
                self.units[self.win_len + f] = 0;
            }
            self.win_len += u.consumed;
            y += u.height;
            j += u.consumed;
        }
        return j;
    }

    /// Aggressive free at the evicted edge: drop trailing units fully below
    /// the Goldilocks range. Never drops into the viewport (`hi_target` is a
    /// full screen past it) and never empties the window.
    fn truncateBack(self: *VirtualCache, hi_target: f32) void {
        while (self.win_len > 0) {
            var last_start: usize = 0;
            var last_y: f32 = self.win_top_y;
            var yy: f32 = self.win_top_y;
            var q: usize = 0;
            while (q < self.win_len) {
                const cc: usize = @max(@as(usize, self.units[q]), 1);
                if (cc > self.win_len) break;
                last_start = q;
                last_y = yy;
                yy += self.heights[q];
                q += cc;
            }
            if (last_start == 0) break;
            if (last_y >= hi_target) {
                self.win_len = last_start;
            } else break;
        }
    }
};

/// True when line `j` continues the previous layout unit (fence body/end,
/// table-row continuation, setext underline).
fn unitContinuesAt(bytes: []const u8, lines: []const simd.Line, j: usize) bool {
    if (j >= lines.len) return false;
    const bt = lines[j].block_type;
    if (bt == .code_line or bt == .code_fence_end) return true;
    if (bt == .table_row and j > 0 and lines[j - 1].block_type == .table_row) return true;
    if (isSetextUnderline(bytes, lines, j)) return true;
    return false;
}

/// Phase of the time-sliced background layout job.
pub const JobPhase = enum { estimate, refine, done };
/// A `step` either exhausts its time budget (`yielded`, resume next tick)
/// or finishes the remaining work (`done`).
pub const JobStatus = enum { yielded, done };

/// Resumable time-sliced layout state machine (amortized layout).
/// The estimate pass fills `heights` with byte-length heuristics (drives the
/// scrollbar immediately); the refine pass replaces them with exact
/// `refineLineHeight` measurements so the estimate converges to the true
/// document height. Each `step` works until `budget_ns` elapses, then yields
/// to the UI; the caller resumes it on the next tick. Pass
/// `FRAME_BUDGET_NS` (~2ms of a 16ms frame) for steady 60fps+.
///
/// `heights` is caller-owned (allocated once at document load, parallel to
/// `lines`); the job itself performs zero heap allocations. Entries
/// `[0, refine_line)` are exact, the rest are estimates until `done`.
pub const LayoutJob = struct {
    next_line: usize = 0,
    refine_line: usize = 0,
    ops: usize = 0,
    est_total_h: f32 = 100.0,
    refined_y: f32 = 50.0,
    total_h: f32 = 100.0,
    phase: JobPhase = .estimate,
    started: bool = false,
    window_width: f32 = 0.0,
    content_max_width: f32 = 600.0,
    base_font_size: f32 = 17.0,
    line_height: f32 = 29.75,

    pub fn reset(self: *LayoutJob) void {
        self.* = .{};
    }

    /// Best-known total height: exact once `done`, scrollbar estimate meanwhile.
    pub fn totalHeight(self: *const LayoutJob) f32 {
        return if (self.phase == .done) self.total_h else self.est_total_h;
    }

    /// Leading lines with exact heights (follower lines of multi-line units
    /// hold 0.0 and are exact by construction).
    pub fn refinedUpTo(self: *const LayoutJob) usize {
        return self.refine_line;
    }

    pub fn step(
        self: *LayoutJob,
        bytes: []const u8,
        lines: []const simd.Line,
        config: ViewportConfig,
        heights: []f32,
        budget_ns: u64,
    ) JobStatus {
        if (lines.len == 0) {
            self.phase = .done;
            self.total_h = 0.0;
            self.est_total_h = 0.0;
            return .done;
        }
        if (!self.started or !self.jobGeometryMatches(config)) {
            self.window_width = config.window_width;
            self.content_max_width = config.content_max_width;
            self.base_font_size = config.base_font_size;
            self.line_height = config.line_height;
            self.next_line = 0;
            self.refine_line = 0;
            self.ops = 0;
            self.refined_y = 50.0;
            self.phase = .estimate;
            self.started = true;
        }
        const n = @min(lines.len, heights.len);
        const cw = contentWidthOf(config);
        const cx = contentXOf(config);
        var ts0: std.posix.timespec = undefined;
        _ = std.posix.system.clock_gettime(.MONOTONIC, &ts0);

        if (self.phase == .estimate) {
            while (self.next_line < n) {
                heights[self.next_line] = estimateBlockHeight(lines[self.next_line], config, cw);
                self.next_line += 1;
                self.ops += 1;
                if (self.ops % BUDGET_POLL_LINES == 0 and budgetExceeded(ts0, budget_ns)) return .yielded;
            }
            var t: f32 = 50.0;
            for (heights[0..n]) |h| t += h;
            self.est_total_h = t + 50.0;
            self.phase = .refine;
        }
        if (self.phase == .refine) {
            while (self.refine_line < n) {
                const u = refineLineHeight(bytes, lines, self.refine_line, config, cw, cx);
                heights[self.refine_line] = u.height;
                self.refined_y += u.height;
                var f: usize = 1;
                while (f < u.consumed and self.refine_line + f < n) : (f += 1) {
                    heights[self.refine_line + f] = 0.0;
                }
                self.refine_line = @min(self.refine_line + u.consumed, n);
                self.ops += 1;
                if (self.ops % BUDGET_POLL_LINES == 0 and budgetExceeded(ts0, budget_ns)) return .yielded;
            }
            self.total_h = self.refined_y + 50.0;
            self.phase = .done;
        }
        return .done;
    }

    fn jobGeometryMatches(self: *const LayoutJob, config: ViewportConfig) bool {
        return self.window_width == config.window_width and
            self.content_max_width == config.content_max_width and
            self.base_font_size == config.base_font_size and
            self.line_height == config.line_height;
    }
};

fn budgetExceeded(ts0: std.posix.timespec, budget_ns: u64) bool {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.MONOTONIC, &ts);
    const elapsed: i128 = (@as(i128, ts.sec) - @as(i128, ts0.sec)) * 1_000_000_000 +
        (@as(i128, ts.nsec) - @as(i128, ts0.nsec));
    return elapsed >= @as(i128, budget_ns);
}

/// JIT viewport layout: seeks with the Goldilocks `cache` (estimates outside,
/// exact heights inside), skips the above-viewport buffer via cached refined
/// heights, and renders entering/visible blocks through the shared
/// `renderViewportCore` — output identical to `layoutViewport` whenever the
/// window top is exact (top of document, or reached by incremental scrolls).
/// After a cold jump the output is shifted by one constant anchor offset by
/// design (scrollbar heuristic); see `anchorScrollForDelta`.
/// Zero heap allocations; a warm frame costs O(window).
pub fn layoutViewportJIT(
    bytes: []const u8,
    lines: []const simd.Line,
    config: ViewportConfig,
    cache: *VirtualCache,
    commands_out: []DrawCommand,
) usize {
    if (commands_out.len == 0 or lines.len == 0) return 0;
    cache.update(bytes, lines, config);
    const rel_base = cache.win_top_y - config.scroll_y;
    var k: usize = 0;
    var y_off: f32 = 0.0;
    while (k < cache.win_len) {
        const c: usize = @max(@as(usize, cache.units[k]), 1);
        if (c > cache.win_len - k) break;
        const h = cache.heights[k];
        if (rel_base + y_off + h >= 0.0) break;
        y_off += h;
        k += c;
    }
    const skip_end = @min(cache.win_start + k, lines.len);
    const block_id = cache.win_block_id + countScrollableBlocks(lines, cache.win_start, skip_end);
    return renderViewportCore(bytes, lines, config, skip_end, rel_base + y_off, block_id, commands_out);
}

const virtual_test_doc =
    \\# Chapter Heading With Several Words
    \\A paragraph with enough words to wrap across multiple visual lines for testing.
    \\> A blockquote with **bold** and *italic* spans inside it.
    \\- Bullet item alpha with `inline code` attached
    \\- Bullet item beta that is deliberately much longer so it wraps across lines
    \\1. Ordered step one
    \\2. Ordered step two with a [link](https://ziglang.org) inside
    \\- [x] Done task
    \\- [ ] Open task with more words
    \\| Col A | Col B |
    \\| :--- | :--- |
    \\| Data 1 | Data 2 |
    \\```zig
    \\pub fn main() void {}
    \\const x: i32 = 42;
    \\```
    \\Setext Title
    \\============
    \\---
    \\![alt text](https://example.com/img.png)
    \\Final trailing paragraph.
;

test "virtualized: estimated heights track exact refined heights" {
    var lines_buf: [64]simd.Line = undefined;
    var fence = false;
    const line_count = simd.scanLines(virtual_test_doc, &lines_buf, &fence);
    const lines = lines_buf[0..line_count];

    const config = ViewportConfig{ .window_width = 800.0, .window_height = 600.0, .scroll_y = 0.0 };
    const cw = contentWidthOf(config);
    const cx = contentXOf(config);

    var i: usize = 0;
    while (i < lines.len) {
        const u = refineLineHeight(virtual_test_doc, lines, i, config, cw, cx);
        var est_sum: f32 = 0.0;
        var k: usize = 0;
        while (k < u.consumed) : (k += 1) est_sum += estimateBlockHeight(lines[i + k], config, cw);
        if (u.height > 0.5) {
            const ratio = est_sum / u.height;
            try std.testing.expect(ratio >= 0.2 and ratio <= 5.0);
        }
        // Fixed-height singles and whole fenced blocks estimate (near-)exactly.
        const bt = lines[i].block_type;
        if (u.consumed == 1 and (bt == .blank or bt == .hr or bt == .code_line)) {
            try std.testing.expectApproxEqAbs(est_sum, u.height, 0.01);
        }
        i += @max(u.consumed, 1);
    }

    const est_total = estimateDocumentHeight(lines, config);
    const exact_total = computeDocumentHeight(virtual_test_doc, lines, config);
    const total_ratio = est_total / exact_total;
    try std.testing.expect(total_ratio >= 0.5 and total_ratio <= 2.0);
}

test "virtualized: Goldilocks window spans viewport plus exactly one screen each side" {
    const allocator = std.testing.allocator;
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);
    var r: usize = 0;
    while (r < 400) : (r += 1) try buffer.appendSlice(allocator, virtual_test_doc);
    const mem = buffer.items;

    var lines_buf: [8192]simd.Line = undefined;
    var fence = false;
    const line_count = simd.scanLines(mem, &lines_buf, &fence);
    const lines = lines_buf[0..line_count];

    const vh: f32 = 800.0;
    const scroll: f32 = 8000.0;
    const config = ViewportConfig{ .window_width = 800.0, .window_height = vh, .scroll_y = scroll };

    var cache = VirtualCache{};
    cache.update(mem, lines, config);

    try std.testing.expect(cache.covers(scroll, vh, lines.len));
    // Top buffer is exactly one screen (snapped back by at most one unit).
    const top_buffer = scroll - cache.win_top_y;
    try std.testing.expect(top_buffer >= vh);
    try std.testing.expect(top_buffer <= vh + 300.0);
    // Bottom buffer likewise: window reaches a full screen past the viewport.
    const bottom_reach = cache.bottomY() - (scroll + vh);
    try std.testing.expect(bottom_reach >= vh - 0.5);
    try std.testing.expect(bottom_reach <= vh + 300.0);
    // Bounded: a small fraction of the document is pinned.
    try std.testing.expect(cache.win_len < line_count / 4);
    try std.testing.expect(cache.win_len <= MAX_WINDOW_LINES);
}

test "virtualized: incremental scroll parses in entering lines, frees evicted edge" {
    const allocator = std.testing.allocator;
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);
    var r: usize = 0;
    while (r < 200) : (r += 1) try buffer.appendSlice(allocator, virtual_test_doc);
    const mem = buffer.items;

    var lines_buf: [4096]simd.Line = undefined;
    var fence = false;
    const line_count = simd.scanLines(mem, &lines_buf, &fence);
    const lines = lines_buf[0..line_count];

    const vh: f32 = 800.0;
    var cache = VirtualCache{};
    var cfg = ViewportConfig{ .window_width = 800.0, .window_height = vh, .scroll_y = 2000.0 };
    cache.update(mem, lines, cfg);
    const old_start = cache.win_start;
    const old_end = cache.winEnd();
    var old_heights: [MAX_WINDOW_LINES]f32 = undefined;
    @memcpy(old_heights[0..cache.win_len], cache.heights[0..cache.win_len]);

    cfg.scroll_y = 2060.0;
    cache.update(mem, lines, cfg);
    try std.testing.expect(cache.covers(2060.0, vh, lines.len));
    // Evicted edge advanced past fully buffered-out units.
    try std.testing.expect(cache.win_start >= old_start);
    // Retained lines keep bitwise-identical refined heights (no re-measure).
    const overlap_start = @max(cache.win_start, old_start);
    const overlap_end = @min(cache.winEnd(), old_end);
    try std.testing.expect(overlap_end > overlap_start + 4);
    var li = overlap_start;
    while (li < overlap_end) : (li += 1) {
        try std.testing.expectEqual(old_heights[li - old_start], cache.heights[li - cache.win_start]);
    }

    // Scroll back up: window follows, still covering.
    cfg.scroll_y = 2000.0;
    cache.update(mem, lines, cfg);
    try std.testing.expect(cache.covers(2000.0, vh, lines.len));
    try std.testing.expect(cache.win_start <= old_start);
}

test "virtualized: JIT output identical to exact layout after incremental scroll" {
    const allocator = std.testing.allocator;
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);
    var r: usize = 0;
    while (r < 6) : (r += 1) try buffer.appendSlice(allocator, virtual_test_doc);
    const mem = buffer.items;

    var lines_buf: [512]simd.Line = undefined;
    var fence = false;
    const line_count = simd.scanLines(mem, &lines_buf, &fence);
    const lines = lines_buf[0..line_count];

    var cache = VirtualCache{};
    var cmds_jit: [1024]DrawCommand = undefined;
    // Walk down in small steps so every window shift stays incremental/exact.
    var s: f32 = 0.0;
    var jit_count: usize = 0;
    while (s <= 600.0) : (s += 60.0) {
        const cfg = ViewportConfig{ .window_width = 800.0, .window_height = 600.0, .scroll_y = s };
        jit_count = layoutViewportJIT(mem, lines, cfg, &cache, &cmds_jit);
    }

    const target = ViewportConfig{ .window_width = 800.0, .window_height = 600.0, .scroll_y = 600.0 };
    var cmds_exact: [1024]DrawCommand = undefined;
    const exact_count = layoutViewport(mem, lines, target, &cmds_exact);

    try std.testing.expectEqual(exact_count, jit_count);
    for (cmds_exact[0..exact_count], 0..) |cmd_a, idx| {
        const cmd_b = cmds_jit[idx];
        try std.testing.expectEqual(cmd_a.kind, cmd_b.kind);
        try std.testing.expectEqual(cmd_a.scrollable_id, cmd_b.scrollable_id);
        try std.testing.expectEqualStrings(cmd_a.text, cmd_b.text);
        try std.testing.expectApproxEqAbs(cmd_a.rect.x, cmd_b.rect.x, 0.01);
        try std.testing.expectApproxEqAbs(cmd_a.rect.y, cmd_b.rect.y, 0.01);
        try std.testing.expectApproxEqAbs(cmd_a.rect.w, cmd_b.rect.w, 0.01);
        try std.testing.expectApproxEqAbs(cmd_a.rect.h, cmd_b.rect.h, 0.01);
    }
}

test "virtualized: jumped-to window anchors to exact layout" {
    const allocator = std.testing.allocator;
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);
    var r: usize = 0;
    while (r < 200) : (r += 1) try buffer.appendSlice(allocator, virtual_test_doc);
    const mem = buffer.items;

    var lines_buf: [4096]simd.Line = undefined;
    var fence = false;
    const line_count = simd.scanLines(mem, &lines_buf, &fence);
    const lines = lines_buf[0..line_count];

    const scroll: f32 = 2000.0;
    const vh: f32 = 600.0;
    const jump_cfg = ViewportConfig{ .window_width = 800.0, .window_height = vh, .scroll_y = scroll };
    var cache = VirtualCache{};
    cache.update(mem, lines, jump_cfg);
    try std.testing.expect(cache.covers(scroll, vh, lines.len));
    const s0 = cache.win_start;

    // Exact prefix height above the window (unit-stepped refinement).
    const cw = contentWidthOf(jump_cfg);
    const cx = contentXOf(jump_cfg);
    var exact_prefix: f32 = 50.0;
    var j: usize = 0;
    while (j < s0) {
        const u = refineLineHeight(mem, lines, j, jump_cfg, cw, cx);
        exact_prefix += u.height;
        j += @max(u.consumed, 1);
    }
    // Anchor: the estimate basis undercounts true positions above the window
    // by `delta`, so estimate-basis [scroll, scroll+H] shows the same true
    // content as exact-basis [scroll+delta, scroll+delta+H]. Shifting the
    // scroll offset by the delta locks the visible lines in place.
    const delta = exact_prefix - cache.win_top_y;
    const anchored = anchorScrollForDelta(scroll, delta);
    try std.testing.expectEqual(scroll + delta, anchored);
    try std.testing.expect(anchored > 0.0);
    std.debug.print("\n[VIRTUALIZED] cold-jump anchor delta above viewport: {d:.2} px\n", .{delta});

    // JIT render on the estimate basis at `scroll` must be fully identical
    // to the exact render at the anchored offset: same lines, same pixels.
    var cmds_jit: [1024]DrawCommand = undefined;
    const jit_count = layoutViewportJIT(mem, lines, jump_cfg, &cache, &cmds_jit);

    const anchored_cfg = ViewportConfig{ .window_width = 800.0, .window_height = vh, .scroll_y = anchored };
    var cmds_exact: [1024]DrawCommand = undefined;
    const exact_count = layoutViewport(mem, lines, anchored_cfg, &cmds_exact);

    try std.testing.expectEqual(exact_count, jit_count);
    for (cmds_exact[0..exact_count], 0..) |cmd_a, idx| {
        const cmd_b = cmds_jit[idx];
        try std.testing.expectEqual(cmd_a.kind, cmd_b.kind);
        try std.testing.expectEqual(cmd_a.scrollable_id, cmd_b.scrollable_id);
        try std.testing.expectEqualStrings(cmd_a.text, cmd_b.text);
        // 0.05px slack covers f32 summation-order rounding only; a wrong
        // anchor would shift every rect by tens of pixels.
        try std.testing.expectApproxEqAbs(cmd_a.rect.x, cmd_b.rect.x, 0.05);
        try std.testing.expectApproxEqAbs(cmd_a.rect.y, cmd_b.rect.y, 0.05);
        try std.testing.expectApproxEqAbs(cmd_a.rect.w, cmd_b.rect.w, 0.05);
        try std.testing.expectApproxEqAbs(cmd_a.rect.h, cmd_b.rect.h, 0.05);
    }
}

test "virtualized: time-sliced job yields on budget and converges to exact height" {
    const allocator = std.testing.allocator;
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);
    const chunk =
        \\# Section Document Heading
        \\Here is regular reading content for benchmarking layout latency.
        \\> Simplicity is prerequisite for reliability.
        \\- Bullet list item alpha
        \\- Bullet list item beta
        \\
    ;
    var i: usize = 0;
    while (i < 10_000) : (i += 1) try buffer.appendSlice(allocator, chunk);
    const mem = buffer.items;

    const line_entries = try allocator.alloc(simd.Line, 50_100);
    defer allocator.free(line_entries);
    var fence = false;
    const line_count = simd.scanLines(mem, line_entries, &fence);
    const lines = line_entries[0..line_count];

    const heights = try allocator.alloc(f32, lines.len);
    defer allocator.free(heights);

    const config = ViewportConfig{ .window_width = 1000.0, .window_height = 800.0, .scroll_y = 0.0 };

    // A ~zero budget must yield (never block the UI) while making progress.
    var job = LayoutJob{};
    const first = job.step(mem, lines, config, heights, 1);
    try std.testing.expectEqual(JobStatus.yielded, first);
    try std.testing.expect(job.next_line > 0 or job.refine_line > 0);

    // Full convergence under the strict ~2ms frame budget.
    var slices: usize = 1;
    while (slices < 100_000) : (slices += 1) {
        if (job.step(mem, lines, config, heights, FRAME_BUDGET_NS) == .done) break;
    }
    try std.testing.expectEqual(JobPhase.done, job.phase);
    try std.testing.expectEqual(lines.len, job.refinedUpTo());

    const exact = computeDocumentHeight(mem, lines, config);
    std.debug.print("\n[VIRTUALIZED] job converged in {d} slices; total {d:.1} px (exact {d:.1} px)\n", .{
        slices + 1,
        job.totalHeight(),
        exact,
    });
    // Per-line heights are bitwise exact (same computation, no accumulation).
    var q: usize = 0;
    while (q < lines.len) {
        const u = refineLineHeight(mem, lines, q, config, contentWidthOf(config), contentXOf(config));
        try std.testing.expectEqual(u.height, heights[q]);
        var f: usize = 1;
        while (f < u.consumed and q + f < lines.len) : (f += 1) {
            try std.testing.expectEqual(@as(f32, 0.0), heights[q + f]);
        }
        q += @max(u.consumed, 1);
    }
    // Totals agree up to f32 accumulation rounding at large magnitudes
    // (ulp is ~0.25px at multi-million-px document heights).
    try std.testing.expectApproxEqAbs(job.totalHeight(), exact, @max(1.0, exact * 0.0002));

    // Scrollbar estimate from byte lengths alone lands in a sane band.
    const est = estimateDocumentHeight(lines, config);
    try std.testing.expect(est / exact >= 0.5 and est / exact <= 2.0);
}

test "virtualized: warm JIT viewport layout under 12us" {
    const allocator = std.testing.allocator;
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);
    const chunk =
        \\# Section Document Heading
        \\Here is regular reading content for benchmarking layout latency.
        \\> Simplicity is prerequisite for reliability.
        \\- Bullet list item alpha
        \\- Bullet list item beta
        \\
    ;
    var i: usize = 0;
    while (i < 10_000) : (i += 1) try buffer.appendSlice(allocator, chunk);
    const mem = buffer.items;

    const line_entries = try allocator.alloc(simd.Line, 50_100);
    defer allocator.free(line_entries);
    var fence = false;
    const line_count = simd.scanLines(mem, line_entries, &fence);
    const lines = line_entries[0..line_count];

    const base_cfg = ViewportConfig{ .window_width = 1000.0, .window_height = 800.0, .scroll_y = 0.0 };
    const doc_h = computeDocumentHeight(mem, lines, base_cfg);
    const deep_cfg = ViewportConfig{ .window_width = 1000.0, .window_height = 800.0, .scroll_y = doc_h * 0.90 };

    var cache = VirtualCache{};
    var commands: [1024]DrawCommand = undefined;
    // Warm outside the timed region (one cold jump, then static frames).
    _ = layoutViewportJIT(mem, lines, deep_cfg, &cache, &commands);
    try std.testing.expect(cache.covers(deep_cfg.scroll_y, 800.0, lines.len));

    var min_elapsed_us: i128 = 999999;
    var last_cmd_count: usize = 0;
    var iter: usize = 0;
    while (iter < 5) : (iter += 1) {
        var ts_start: std.posix.timespec = undefined;
        _ = std.posix.system.clock_gettime(.MONOTONIC, &ts_start);
        last_cmd_count = layoutViewportJIT(mem, lines, deep_cfg, &cache, &commands);
        var ts_end: std.posix.timespec = undefined;
        _ = std.posix.system.clock_gettime(.MONOTONIC, &ts_end);
        const start_ns = @as(i128, ts_start.sec) * 1_000_000_000 + ts_start.nsec;
        const end_ns = @as(i128, ts_end.sec) * 1_000_000_000 + ts_end.nsec;
        const elapsed_us = @divTrunc(end_ns - start_ns, 1_000);
        if (elapsed_us < min_elapsed_us) min_elapsed_us = elapsed_us;
    }
    std.debug.print("[VIRTUALIZED] Warm JIT deep-scroll layout latency: {d} us ({d} draw commands)\n", .{
        min_elapsed_us,
        last_cmd_count,
    });
    try std.testing.expect(last_cmd_count > 0);
    try std.testing.expect(min_elapsed_us <= 12);
}

// ============================================================================
// Scroll-illusion masking: heuristic estimate + indexed block map + anchoring.
// (todo/ideas.txt lines 13-24.) The scrollbar is decoupled from pixel-perfect
// layout: at file-open a SIMD `\n` census times line-height yields an
// estimated total height; a u32 offset index over `\n\n` gives O(1)
// fraction jumps + O(log N) line resolution; scroll anchoring absorbs
// measured-vs-estimated height deltas into the invisible offset above the
// top-visible element so the thumb and content never jump. None of this sits
// on the layoutViewport hot path: estimate/map build run once at open,
// per-frame cost is one index multiply plus checkpoint binary search.
// ============================================================================

pub const SCROLL_CHROME_PAD: f32 = 100.0; // 50 top + 50 bottom, mirrors layoutViewport/computeDocumentHeightEx

/// Heuristic total height at open: `(newlines + 1) * line_height + chrome`.
/// Branchless, zero allocations, O(1) after the SIMD census.
pub fn estimateTotalHeightFromNewlines(newline_count: usize, line_height: f32) f32 {
    return @as(f32, @floatFromInt(newline_count + 1)) * line_height + SCROLL_CHROME_PAD;
}

/// Locked top-visible element. `doc_top_y` is the anchor line's top edge in
/// document coordinates; `scroll_y` is the scroll offset at capture time.
/// The viewport-relative position `doc_top_y - scroll_y` must not move.
pub const ScrollAnchor = struct {
    line_idx: u32,
    doc_top_y: f32,
    scroll_y: f32,

    pub fn viewOffset(self: ScrollAnchor) f32 {
        return self.doc_top_y - self.scroll_y;
    }

    /// New scroll offset after the anchor line's measured document position
    /// changed (lazy layout above the viewport resolved real heights).
    /// Absorbs the full delta into the invisible offset above the viewport.
    pub fn reanchoredScroll(self: ScrollAnchor, new_doc_top_y: f32) f32 {
        return new_doc_top_y - self.viewOffset();
    }
};

/// Absorbs a measured height delta originating strictly above the viewport
/// into the scroll offset so the top-visible pixel does not move.
/// Positive `delta_above` (content above grew) scrolls the offset down by
/// the same amount; clamped at zero. Pure, branchless, zero allocations.
pub fn absorbHeightDelta(scroll_y: f32, delta_above: f32) f32 {
    return @max(0.0, scroll_y + delta_above);
}

/// Scrollbar-thumb fraction for a scroll offset given total height and
/// viewport height. Clamped to [0, 1]; returns 0 for degenerate inputs.
pub fn thumbFraction(scroll_y: f32, total_h: f32, window_h: f32) f32 {
    const travel = total_h - window_h;
    if (travel <= 0.0) return 0.0;
    return std.math.clamp(scroll_y / travel, 0.0, 1.0);
}

/// O(1) scrollbar jump to `fraction` (0..1): index into the block map, then
/// O(log N) binary search from byte offset to line index. Total cost is
/// logarithmic with a tiny constant -- comfortably inside the 12us
/// deep-scroll budget alongside the checkpoint seek in layoutViewport.
pub fn jumpLineForFraction(
    lines: []const simd.Line,
    block_map: []const u32,
    fraction: f32,
) usize {
    if (lines.len == 0) return 0;
    if (block_map.len == 0) {
        // No blank separators (e.g. single-paragraph file): proportional fallback.
        const f = std.math.clamp(fraction, 0.0, 1.0);
        return @min(lines.len - 1, @as(usize, @intFromFloat(f * @as(f32, @floatFromInt(lines.len)))));
    }
    const byte_off = simd.blockOffsetForFraction(block_map, fraction);
    return simd.byteOffsetToLineIndex(lines, byte_off);
}

/// Live scrollbar model: holds the current estimated total and applies
/// measured corrections through anchoring, so callers never need to touch
/// layoutViewport or the platform loop. Zero heap allocations.
pub const ScrollIllusion = struct {
    estimated_h: f32,
    window_h: f32,
    scroll_y: f32 = 0.0,

    pub fn init(newline_count: usize, line_height: f32, window_h: f32) ScrollIllusion {
        return .{
            .estimated_h = estimateTotalHeightFromNewlines(newline_count, line_height),
            .window_h = window_h,
        };
    }

    /// Silently fold a newly measured total height into the model while
    /// keeping `anchor` pixel-stable: returns the corrected scroll offset.
    /// The thumb fraction computed from the corrected scroll + new total
    /// stays continuous (no visible jump).
    pub fn noteMeasuredHeight(
        self: *ScrollIllusion,
        measured_h: f32,
        anchor: ScrollAnchor,
        anchor_new_doc_top_y: f32,
    ) f32 {
        self.estimated_h = measured_h;
        self.scroll_y = anchor.reanchoredScroll(anchor_new_doc_top_y);
        return self.scroll_y;
    }

    pub fn fraction(self: ScrollIllusion) f32 {
        return thumbFraction(self.scroll_y, self.estimated_h, self.window_h);
    }
};

test "scroll illusion: estimate is O(1) sane vs accurate height" {
    const doc =
        \\# Title
        \\Paragraph one with some text.
        \\
        \\Paragraph two with more text here.
        \\
        \\- item one
        \\- item two
    ;
    var lines_buf: [32]simd.Line = undefined;
    var fence = false;
    const lc = simd.scanLines(doc, &lines_buf, &fence);
    const cfg = ViewportConfig{ .window_width = 800.0, .window_height = 600.0, .scroll_y = 0.0 };
    const nl = simd.countNewlines(doc);
    const est = estimateTotalHeightFromNewlines(nl, cfg.line_height);
    const acc = computeDocumentHeight(doc, lines_buf[0..lc], cfg);
    // Heuristic must be positive and within an order of magnitude of truth
    // (headings/margins inflate real height; plain lines match closely).
    try std.testing.expect(est > 0.0 and acc > 0.0);
    const ratio = est / acc;
    try std.testing.expect(ratio > 0.15 and ratio < 6.0);
    // Chrome padding convention matches the layout origin (50 top + 50 bottom).
    try std.testing.expectApproxEqAbs(
        @as(f32, @floatFromInt(nl + 1)) * cfg.line_height + SCROLL_CHROME_PAD,
        est,
        0.001,
    );
}

test "scroll illusion: anchor absorbs height delta with zero visible jump" {
    // Simulate lazy layout above the viewport resolving 60px taller than
    // the heuristic estimate: without anchoring the content would jump 60px.
    const anchor = ScrollAnchor{ .line_idx = 120, .doc_top_y = 1000.0, .scroll_y = 900.0 };
    const view_before = anchor.viewOffset(); // 100px from viewport top
    const corrected = anchor.reanchoredScroll(1060.0);
    try std.testing.expectApproxEqAbs(@as(f32, 960.0), corrected, 0.001);
    try std.testing.expectApproxEqAbs(view_before, 1060.0 - corrected, 0.001);
    // Scalar helper agrees and clamps at document top.
    try std.testing.expectApproxEqAbs(@as(f32, 960.0), absorbHeightDelta(900.0, 60.0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), absorbHeightDelta(10.0, -60.0), 0.001);

    // End-to-end through the illusion model: the corrected scroll keeps the
    // anchor pixel-stable, and the thumb drifts only by the proportional
    // residue -- no discontinuous jump.
    var illusion = ScrollIllusion.init(200, 29.75, 600.0);
    illusion.scroll_y = 900.0;
    const frac_before = illusion.fraction();
    const new_scroll = illusion.noteMeasuredHeight(illusion.estimated_h + 60.0, anchor, 1060.0);
    try std.testing.expectApproxEqAbs(corrected, new_scroll, 0.001);
    try std.testing.expectApproxEqAbs(view_before, 1060.0 - new_scroll, 0.001);
    const frac_after = illusion.fraction();
    try std.testing.expect(@abs(frac_after - frac_before) < 0.02);
}

test "scroll illusion: O(1) fraction jump resolves inside deep-scroll budget" {
    const allocator = std.testing.allocator;
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);
    const chunk = "# Heading\nParagraph of body text for jump testing.\n\n";
    var k: usize = 0;
    while (k < 3000) : (k += 1) {
        try buffer.appendSlice(allocator, chunk);
    }
    const mem = buffer.items;

    var lines_buf: [10000]simd.Line = undefined;
    var fence = false;
    const lc = simd.scanLines(mem, &lines_buf, &fence);
    const lines = lines_buf[0..lc];

    var map_buf: [4096]u32 = undefined;
    const map_n = simd.buildBlockMap(mem, &map_buf);
    try std.testing.expect(map_n > 100);
    // Book-scale RAM check: 4 bytes per block boundary.
    try std.testing.expect(map_n * @sizeOf(u32) < 64 * 1024);

    // Jump targets are monotonic in fraction and land on real line starts.
    const j0 = jumpLineForFraction(lines, map_buf[0..map_n], 0.0);
    const j50 = jumpLineForFraction(lines, map_buf[0..map_n], 0.50);
    const j75 = jumpLineForFraction(lines, map_buf[0..map_n], 0.75);
    const j100 = jumpLineForFraction(lines, map_buf[0..map_n], 1.0);
    try std.testing.expect(j0 <= j50 and j50 <= j75 and j75 <= j100);
    try std.testing.expect(j100 < lines.len);
    // Idempotent: repeated jumps land on the same line.
    try std.testing.expectEqual(j75, jumpLineForFraction(lines, map_buf[0..map_n], 0.75));

    // Resolution latency (index + binary search) must sit far under the
    // 12us deep-scroll budget so layoutViewport keeps its full allowance.
    var min_us: i128 = 999999;
    var iter: usize = 0;
    var sink: usize = 0;
    while (iter < 200) : (iter += 1) {
        var ts: std.posix.timespec = undefined;
        _ = std.posix.system.clock_gettime(.MONOTONIC, &ts);
        const s = jumpLineForFraction(lines, map_buf[0..map_n], 0.75);
        var te: std.posix.timespec = undefined;
        _ = std.posix.system.clock_gettime(.MONOTONIC, &te);
        sink ^= s;
        const us = @divTrunc((@as(i128, te.sec) * 1_000_000_000 + te.nsec) - (@as(i128, ts.sec) * 1_000_000_000 + ts.nsec), 1000);
        if (us < min_us) min_us = us;
    }
    std.testing.expect(sink < lines.len * 2) catch {};
    std.debug.print("[scroll illusion] fraction-jump resolution: {d} µs\n", .{min_us});
    try std.testing.expect(min_us <= 12);

    // The jumped-to region actually renders: viewport at that line's height.
    var cps: [64]Checkpoint = undefined;
    var cp_count: usize = 0;
    const base = ViewportConfig{ .window_width = 1000.0, .window_height = 800.0, .scroll_y = 0.0 };
    const doc_h = computeDocumentHeightEx(mem, lines, base, &cps, &cp_count);
    const deep_y = @min(doc_h - 800.0, @as(f32, @floatFromInt(j75)) * base.line_height);
    var cmds: [256]DrawCommand = undefined;
    const n_cmds = layoutViewport(mem, lines, .{
        .window_width = 1000.0,
        .window_height = 800.0,
        .scroll_y = deep_y,
        .checkpoints = cps[0..cp_count],
    }, &cmds);
    try std.testing.expect(n_cmds > 0);
}
