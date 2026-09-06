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

/// Ambient scrollbar geometry shared by the Zig filament and the platform
/// drag handling (macos.m mirrors this formula; tests pin it here).
/// Visual stays a 2px filament; the grab strip is wider for usability.
pub const SCROLLBAR_THUMB_H: f32 = 40.0;
pub const SCROLLBAR_HIT_W: f32 = 12.0;

/// Thumb top for a scroll offset. Returns 0 when there is nothing to scroll.
pub fn scrollbarThumbY(scroll_y: f32, max_scroll_y: f32, view_h: f32) f32 {
    if (max_scroll_y <= 0.0) return 0.0;
    const progress = std.math.clamp(scroll_y / max_scroll_y, 0.0, 1.0);
    return progress * (view_h - SCROLLBAR_THUMB_H);
}

/// Scroll offset for a drag pointer at view height `y` grabbed at `grab_delta`
/// below the thumb top (track clicks pass THUMB_H/2 to center the thumb).
pub fn scrollbarScrollFromY(y: f32, grab_delta: f32, max_scroll_y: f32, view_h: f32) f32 {
    if (max_scroll_y <= 0.0) return 0.0;
    const travel = view_h - SCROLLBAR_THUMB_H;
    if (travel <= 0.0) return 0.0;
    const progress = std.math.clamp((y - grab_delta) / travel, 0.0, 1.0);
    return progress * max_scroll_y;
}

pub const Checkpoint = struct {
    line_idx: u32,
    y: f32,
    next_block_id: u16,
};

/// Checkpoint grid density (lines between checkpoints). A deep seek lands on
/// the last checkpoint at/below target, then re-walks forward to the
/// viewport: worst-case walk ≈ 600px overscan + one grid cell. At 32 lines
/// (≈1.8k px) the walk stays under ~45 units, keeping deep-scroll layout
/// inside the strict microsecond budget even on slow shared CI cores.
/// Tightening the grid costs ~12 bytes per checkpoint (caller-owned).
pub const checkpoint_grid_lines: usize = 32;

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
    /// Caller-owned scratch for corrected ordered-list markers. When null
    /// (or full), markers echo the source text; otherwise sequential numbers
    /// ("1.", "2.", ...) per CommonMark. Geometry never depends on it.
    ordered_markers: ?*OrderedMarkerStore = null,
    /// Reference definitions scanned once per document (cold path). Empty
    /// disables `[t][l]` / `[t][]` / `[t]` resolution (spans stay literal).
    ref_defs: []const simd.RefDef = &.{},
    /// Caller-owned scratch for decoded `&entity;` text. When null, spans
    /// keep raw source text; measurement and rendering stay consistent
    /// either way because both flow the same slices.
    entities: ?*EntityStore = null,
    /// Caller-owned scratch for cross-line reference joints (`Foo [bar]` +
    /// `[1].` flows exactly like `Foo [bar] [1].`, Markdown 1.0). Null
    /// disables the joint (lines flow separately). Render and measurement
    /// share the config, so both always agree.
    join_buf: ?*[JOIN_BUF_LEN]u8 = null,
};

/// Cross-line reference joint scratch length: two source lines plus a space.
pub const JOIN_BUF_LEN: usize = 4096;

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

/// Display-synced scroll smoothing: input handlers retarget, a 120Hz platform
/// tick eases `current` toward `target`. Exponential approach (frame-rate
/// independent via dt), monotonic, no overshoot, exact snap under 0.5px.
/// Zero allocations; two f32 of state.
pub const SmoothScroll = struct {
    current: f32 = 0.0,
    target: f32 = 0.0,

    pub const RATE: f32 = 28.0;
    pub const SNAP_PX: f32 = 0.5;

    pub fn setTarget(self: *SmoothScroll, v: f32, max: f32) void {
        self.target = std.math.clamp(v, 0.0, @max(0.0, max));
    }

    /// Scrollbar drags stay 1:1 — the displayed offset jumps with the target.
    pub fn snapTo(self: *SmoothScroll, v: f32, max: f32) void {
        const c = std.math.clamp(v, 0.0, @max(0.0, max));
        self.target = c;
        self.current = c;
    }

    pub fn settled(self: *const SmoothScroll) bool {
        return self.current == self.target;
    }

    /// Advance toward the target by dt seconds. Returns true when settled.
    pub fn tick(self: *SmoothScroll, dt_s: f32) bool {
        const diff = self.target - self.current;
        if (diff == 0.0) return true;
        const dt = @max(0.0, dt_s);
        // 1 - e^(-RATE*dt): frame-rate independent exponential approach.
        const t = 1.0 - @exp(-RATE * dt);
        const next = self.current + diff * t;
        // Snap, then pin to the segment so float error can never overshoot.
        if (@abs(self.target - next) < SNAP_PX) {
            self.current = self.target;
        } else if (diff > 0.0) {
            self.current = @min(next, self.target);
        } else {
            self.current = @max(next, self.target);
        }
        return self.current == self.target;
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
    var pen = FlowPen{ .x = start_x, .y = base_y };
    const flow = FlowCtx{
        .font_size = font_size,
        .line_h = line_h,
        .default_color = default_color,
        .accent_color = accent_color,
        .start_x = start_x,
        .max_w = max_w,
        .vp_bottom = vp_bottom,
        .commands_out = commands_out,
        .cmd_count = cmd_count,
    };

    for (spans) |span| {
        if (commands_out.len >= 4 and cmd_count.* >= commands_out.len - 4) break;
        flowSpans(span.text, span.style, span.link_target, &pen, flow);
    }

    return pen.y + line_h;
}

/// Pen position for flowing word layout. Shared by single-line
/// `layoutWrappedSpans` and multi-line continuation runs (soft-break-joined
/// paragraphs, lazy quote/list followers) so both wrap identically.
pub const FlowPen = struct {
    x: f32,
    y: f32,
};

/// Emission context for the word-flow helpers. When `commands_out` is empty
/// (height/refine measurement) nothing is emitted but the pen advances
/// through the exact same wrap decisions, so measured heights match rendered
/// output bit-for-bit.
pub const FlowCtx = struct {
    font_size: f32,
    line_h: f32,
    default_color: Color,
    accent_color: Color,
    start_x: f32,
    max_w: f32,
    vp_bottom: f32,
    commands_out: []DrawCommand,
    cmd_count: *usize,
    defs: []const simd.RefDef = &.{},
    entities: ?*EntityStore = null,
};

/// Lays out one word at the pen: wraps to the next visual row on overflow,
/// emits a text_run when visible, and advances past the word. Conditions are
/// identical to the historical `layoutWrappedSpans` inner loop.
pub fn flowWord(
    word: []const u8,
    style: parser.SpanStyle,
    link_target: ?[]const u8,
    pen: *FlowPen,
    ctx: FlowCtx,
) void {
    const word_w = measureTextEx(
        word,
        ctx.font_size,
        style.bold,
        style.italic,
        style.code,
        style.heading,
    );

    if (pen.x + word_w > ctx.start_x + ctx.max_w and pen.x > ctx.start_x) {
        pen.y += ctx.line_h;
        pen.x = ctx.start_x;
    }

    if (pen.y + ctx.line_h >= 0 and pen.y <= ctx.vp_bottom and
        ctx.cmd_count.* < ctx.commands_out.len)
    {
        const span_color = if (style.link) ctx.accent_color else ctx.default_color;
        ctx.commands_out[ctx.cmd_count.*] = .{
            .kind = .text_run,
            .rect = .{
                .x = pen.x,
                .y = pen.y,
                .w = word_w,
                .h = ctx.line_h,
            },
            .color = span_color,
            .text = word,
            .font_size = ctx.font_size,
            .style = style,
            .link_target = link_target,
        };
        ctx.cmd_count.* += 1;
    }

    pen.x += word_w;
}

/// Advances the pen past one space (never wraps: matches historical layout).
pub fn flowSpace(pen: *FlowPen, space_w: f32) void {
    pen.x += space_w;
}

/// Flows words and spaces of one span-text at the pen.
pub fn flowSpans(
    span_text: []const u8,
    style: parser.SpanStyle,
    link_target: ?[]const u8,
    pen: *FlowPen,
    ctx: FlowCtx,
) void {
    const space_w = measureCharEx(' ', ctx.font_size, false, false, false, style.heading);
    var i: usize = 0;
    while (i < span_text.len) {
        if (span_text[i] == ' ') {
            flowSpace(pen, space_w);
            i += 1;
            continue;
        }
        const w_start = i;
        while (i < span_text.len and span_text[i] != ' ') : (i += 1) {}
        flowWord(span_text[w_start..i], style, link_target, pen, ctx);
    }
}

/// Flows one raw source line at the pen. Trims leading whitespace when
/// `strip_leading` (continuation lines of a flowed run) and always trims
/// trailing whitespace; the caller emits the single soft-break space between
/// joined lines. Per-line inline parsing matches `layoutWrappedSpans`
/// (markup never spans source lines). `force_code` / `force_heading` OR the
/// style into every span (quoted code blocks, quoted headings).
pub fn flowSourceLine(
    raw: []const u8,
    strip_leading: bool,
    force_code: bool,
    force_heading: bool,
    pen: *FlowPen,
    ctx: FlowCtx,
) void {
    var text = raw;
    if (strip_leading) {
        while (text.len > 0 and (text[0] == ' ' or text[0] == '\t')) : (text = text[1..]) {}
    }
    while (text.len > 0 and (text[text.len - 1] == ' ' or text[text.len - 1] == '\t')) : (text = text[0 .. text.len - 1]) {}
    if (text.len == 0) return;
    var span_buf: [32]parser.InlineSpan = undefined;
    const n = parser.parseInlinesWithDefs(text, &span_buf, ctx.defs);
    for (span_buf[0..n]) |span| {
        if (ctx.commands_out.len >= 4 and ctx.cmd_count.* >= ctx.commands_out.len - 4) break;
        var style = span.style;
        if (force_code) style.code = true;
        if (force_heading) {
            style.bold = true;
            style.heading = true;
        }
        var txt = span.text;
        var tgt = span.link_target;
        // Entities decode in rendered text (never in code spans, whose
        // `&amp;` is literal). Measurement flows the same decoded slices,
        // so wrap geometry always matches the draw.
        if (!style.code and ctx.entities != null) {
            if (std.mem.indexOfScalar(u8, txt, '&') != null) {
                if (ctx.entities.?.decodeInto(txt)) |d| txt = d;
            }
            if (tgt != null and std.mem.indexOfScalar(u8, tgt.?, '&') != null) {
                if (ctx.entities.?.decodeInto(tgt.?)) |d| tgt = d;
            }
        }
        flowSpans(txt, style, tgt, pen, ctx);
    }
}

/// Caller-owned scratch for decoded `&entity;` text (see `EntityStore` on
/// `ViewportConfig`). Slots are frame-lived like ordered-marker slots, so
/// draw commands and measurement pens can borrow them safely.
pub const MAX_ENTITY_SLOTS: usize = 32;
pub const MAX_ENTITY_BYTES: usize = 512;
pub const EntityStore = struct {
    buf: [MAX_ENTITY_SLOTS][MAX_ENTITY_BYTES]u8 = undefined,
    len: [MAX_ENTITY_SLOTS]u16 = undefined,
    count: usize = 0,

    pub fn reset(self: *EntityStore) void {
        self.count = 0;
    }

    /// Copies `text` with every valid `&...;` reference replaced by its
    /// UTF-8 decoding. Null when slots are exhausted or the decoded text
    /// overflows (caller keeps the raw slice; geometry stays consistent
    /// because both passes take the same fallback).
    pub fn decodeInto(self: *EntityStore, text: []const u8) ?[]const u8 {
        if (self.count >= MAX_ENTITY_SLOTS) return null;
        const out = &self.buf[self.count];
        var o: usize = 0;
        var i: usize = 0;
        while (i < text.len) {
            if (text[i] == '&') {
                const el = parser.entityLengthAt(text, i);
                if (el > 0) {
                    var tmp: [8]u8 = undefined;
                    const n = parser.decodeEntityAfterAmp(text[i + 1 ..], &tmp);
                    if (n > 0 and o + n <= out.len) {
                        @memcpy(out[o..][0..n], tmp[0..n]);
                        o += n;
                        i += el;
                        continue;
                    }
                }
            }
            if (o >= out.len) return null;
            out[o] = text[i];
            o += 1;
            i += 1;
        }
        self.len[self.count] = @intCast(o);
        self.count += 1;
        return out[0..o];
    }
};

/// Caller-owned scratch for corrected ordered-list markers ("1." .. "N.").
/// `DrawCommand.text` must borrow long-lived memory, so formatted numbers go
/// here (reset per frame) instead of stack buffers that would dangle.
/// Wired via `ViewportConfig.ordered_markers`; null keeps echoing source.
pub const MAX_ORDERED_MARKERS: usize = 64;
pub const OrderedMarkerStore = struct {
    buf: [MAX_ORDERED_MARKERS][12]u8 = undefined,
    len: [MAX_ORDERED_MARKERS]u8 = undefined,
    count: usize = 0,

    pub fn reset(self: *OrderedMarkerStore) void {
        self.count = 0;
    }

    /// Formats "N." / "N)" into the next slot. Null when full (caller echoes).
    /// Manual digits: std.io is gone in Zig 0.16 and a stream is overkill.
    pub fn push(self: *OrderedMarkerStore, n: u32, delim: u8) ?[]const u8 {
        if (self.count >= MAX_ORDERED_MARKERS) return null;
        const slot = &self.buf[self.count];
        var digits: [10]u8 = undefined;
        var nd: usize = 0;
        var v = n;
        if (v == 0) {
            digits[0] = '0';
            nd = 1;
        }
        while (v > 0) {
            digits[nd] = '0' + @as(u8, @intCast(v % 10));
            v /= 10;
            nd += 1;
        }
        if (nd + 1 > slot.len) return null;
        var i: usize = 0;
        while (nd > 0) {
            nd -= 1;
            slot[i] = digits[nd];
            i += 1;
        }
        slot[i] = delim;
        i += 1;
        self.len[self.count] = @intCast(i);
        self.count += 1;
        return slot[0..i];
    }
};

/// Visual indent width of a raw line: spaces count 1, tab counts 4.
/// (Line.indent counts tabs as 1 char, so raw bytes are measured here.)
fn indentWidth(raw: []const u8) usize {
    var w: usize = 0;
    for (raw) |c| {
        if (c == ' ') w += 1 else if (c == '\t') w += 4 else break;
    }
    return w;
}

fn lineIndentWidth(bytes: []const u8, line: simd.Line) usize {
    return indentWidth(bytes[line.offset..][0..line.len]);
}

/// True for a tab-indented or >= n-spaces-indented line.
fn isIndentedBy(bytes: []const u8, line: simd.Line, n: usize) bool {
    const raw = bytes[line.offset..][0..line.len];
    if (raw.len > 0 and raw[0] == '\t') return true;
    var w: usize = 0;
    for (raw) |c| {
        if (c != ' ') break;
        w += 1;
        if (w >= n) return true;
    }
    return w >= n;
}

/// CommonMark lazy continuation: a plain paragraph line that continues the
/// current block even without a marker. Only paragraph continuation text
/// qualifies — headings, lists, rules, tables, code, images, and blanks all
/// terminate. A setext `===` underline (or the paragraph line immediately
/// before one) is left alone so setext heading construction stays intact.
fn isLazyContinuation(bytes: []const u8, lines: []const simd.Line, j: usize) bool {
    if (j >= lines.len) return false;
    if (lines[j].block_type != .paragraph) return false;
    if (j > 0 and setextLevel(bytes, lines, j - 1) != null) return false;
    if (setextLevel(bytes, lines, j) != null) return false;
    return true;
}

/// Strips blockquote markers: '>' plus ONE optional space/tab per level
/// (CommonMark). Returns the nesting depth and the remaining body.
const StrippedQuote = struct {
    depth: usize,
    body: []const u8,
};

fn stripQuoteMarkers(line: []const u8) StrippedQuote {
    var t = line;
    while (t.len > 0 and (t[0] == ' ' or t[0] == '\t')) : (t = t[1..]) {}
    var depth: usize = 0;
    while (t.len > 0 and t[0] == '>') {
        depth += 1;
        t = t[1..];
        if (t.len > 0 and (t[0] == ' ' or t[0] == '\t')) t = t[1..];
    }
    return .{ .depth = depth, .body = t };
}

/// Skips marker padding spaces/tabs (`*   item`, `1.  item`, `#  title`)
/// so first-line text starts exactly at the flow origin (hanging indent).
fn skipSpaces(s: []const u8) usize {
    var n: usize = 0;
    while (n < s.len and (s[n] == ' ' or s[n] == '\t')) : (n += 1) {}
    return n;
}

/// Parses heading text with reference-link resolution, forces heading style,
/// and decodes entities through the frame store. Shared by render, height,
/// and refine so all three agree bit-for-bit.
fn resolveHeadingSpans(config: ViewportConfig, h_text: []const u8, span_buf: []parser.InlineSpan) usize {
    const n = parser.parseInlinesWithDefs(h_text, span_buf, config.ref_defs);
    for (span_buf[0..n]) |*s| {
        s.style.bold = true;
        s.style.heading = true;
    }
    const ents = config.entities orelse return n;
    for (span_buf[0..n]) |*s| {
        if (s.style.code) continue;
        if (std.mem.indexOfScalar(u8, s.text, '&') != null) {
            if (ents.decodeInto(s.text)) |d| s.text = d;
        }
        if (s.link_target != null and std.mem.indexOfScalar(u8, s.link_target.?, '&') != null) {
            if (ents.decodeInto(s.link_target.?)) |d| s.link_target = d;
        }
    }
    return n;
}

/// Content kind of a quote body (after marker stripping).
const QuoteBodyKind = enum { text, heading, bullet, ordered, task, code };

const QuoteBody = struct {
    kind: QuoteBodyKind,
    level: u8 = 0, // heading level
    prefix_len: usize = 0, // list/task marker length
    checked: bool = false, // task
    number: u32 = 0, // ordered value
    delim: u8 = '.', // ordered delimiter
    code_text: []const u8 = "", // code content (one indent level stripped)
};

/// Parses a decimal prefix, saturating (never overflows on adversarial input).
fn parseListNumber(text: []const u8) u32 {
    var n: u32 = 0;
    for (text) |c| {
        if (c < '0' or c > '9') break;
        const d = @as(u32, c - '0');
        if (n > 100_000_000) return 1_000_000_000;
        n = n * 10 + d;
    }
    return n;
}

/// Classifies stripped quote body text. Mirrors `classifyLine` precedence
/// (task -> bullet/ordered, heading needs "# ") so quoted blocks match
/// top-level blocks; 4-space/tab remainder is indented code.
fn classifyQuoteBody(body: []const u8) QuoteBody {
    if (body.len == 0) return .{ .kind = .text };
    if (body[0] == '\t' or (body.len >= 4 and body[0] == ' ' and body[1] == ' ' and body[2] == ' ' and body[3] == ' ')) {
        const rest = if (body[0] == '\t') body[1..] else body[4..];
        return .{ .kind = .code, .code_text = rest };
    }
    var t = body;
    while (t.len > 0 and (t[0] == ' ' or t[0] == '\t')) : (t = t[1..]) {}
    if (t.len == 0) return .{ .kind = .text };
    if (t[0] == '#') {
        var lvl: u8 = 0;
        while (lvl < 6 and lvl < t.len and t[lvl] == '#') : (lvl += 1) {}
        if (lvl < t.len and t[lvl] == ' ') {
            return .{ .kind = .heading, .level = lvl, .prefix_len = @intCast((body.len - t.len) + lvl + 1) };
        }
        return .{ .kind = .text };
    }
    if (t[0] == '-' or t[0] == '*' or t[0] == '+') {
        if (t.len >= 5 and (t[1] == ' ' or t[1] == '\t') and t[2] == '[' and
            (t[3] == ' ' or t[3] == 'x' or t[3] == 'X') and t[4] == ']')
        {
            return .{ .kind = .task, .prefix_len = @intCast((body.len - t.len) + 5), .checked = (t[3] == 'x' or t[3] == 'X') };
        }
        if (t.len >= 2 and (t[1] == ' ' or t[1] == '\t')) {
            return .{ .kind = .bullet, .prefix_len = @intCast((body.len - t.len) + 2) };
        }
        return .{ .kind = .text };
    }
    if (t[0] >= '0' and t[0] <= '9') {
        var d: usize = 1;
        while (d < t.len and t[d] >= '0' and t[d] <= '9') : (d += 1) {}
        if (d + 1 < t.len and (t[d] == '.' or t[d] == ')') and (t[d + 1] == ' ' or t[d + 1] == '\t')) {
            return .{
                .kind = .ordered,
                .prefix_len = @intCast((body.len - t.len) + d + 2),
                .number = parseListNumber(t[0..d]),
                .delim = t[d],
            };
        }
        return .{ .kind = .text };
    }
    return .{ .kind = .text };
}

/// True for list-item leader lines (bullets, ordered items, tasks).
fn isListLeader(bt: simd.BlockType) bool {
    return bt == .bullet_list or bt == .ordered_list or bt == .task_list;
}

/// Body of quote line `q` absorbs following lazy lines only for plain
/// paragraph text (and empty lines). Headings, lists, and code end the
/// absorbable run: their followers are standalone blocks.
fn quoteAbsorbsFollowers(body: QuoteBody) bool {
    return body.kind == .text;
}

/// Finds the list-item marker owning paragraph line `j`, or null.
/// Segment 0 (directly-connected lazy lines, any indent) plus post-blank
/// segments (each must start 4-space/tab indented; blanks inside the unit).
/// Iterative: no recursion depth risk on adversarial input.
fn listItemLeader(bytes: []const u8, lines: []const simd.Line, j: usize) ?usize {
    if (!isLazyContinuation(bytes, lines, j)) return null;
    var k = j;
    var crossed_blank = false;
    while (k > 0) {
        const pb = lines[k - 1].block_type;
        if (pb == .paragraph and isLazyContinuation(bytes, lines, k)) {
            k -= 1;
            continue;
        }
        if (pb == .blank) {
            const seg = k;
            while (k > 0 and lines[k - 1].block_type == .blank) k -= 1;
            // Every post-blank segment must start indented (4sp/tab);
            // a bare (col-0) line after a blank ends the item.
            if (!isIndentedBy(bytes, lines[seg], 4)) return null;
            crossed_blank = true;
            continue;
        }
        if (isListLeader(pb)) {
            if (!crossed_blank) return k - 1;
            // Post-blank leader hop: the segment just crossed was already
            // indent-checked above; any list marker owns it.
            return k - 1;
        }
        return null;
    }
    return null;
}

/// Finds the quote line owning lazy paragraph line `j`, or null. Only
/// paragraph-bodied quotes absorb (headings/lists/code do not).
fn quoteLeader(bytes: []const u8, lines: []const simd.Line, j: usize) ?usize {
    if (!isLazyContinuation(bytes, lines, j)) return null;
    var k = j;
    while (k > 0 and lines[k - 1].block_type == .paragraph and
        isLazyContinuation(bytes, lines, k))
    {
        k -= 1;
    }
    if (k == 0 or lines[k - 1].block_type != .quote) return null;
    const q = k - 1;
    const qb = bytes[lines[q].offset..][0..lines[q].len];
    if (!quoteAbsorbsFollowers(classifyQuoteBody(stripQuoteMarkers(qb).body))) return null;
    return q;
}

/// Line types an indented code block can claim (post-blank, indent >= 4).
/// Fences, tables, blanks, reference definitions, and comments keep their
/// own units. (Tab/4-space-indented defs and comments classify as plain
/// paragraphs, so they still flow to code through this path.)
fn isCodeClaimable(bt: simd.BlockType) bool {
    return switch (bt) {
        .blank, .code_fence_start, .code_fence_end, .code_line, .table_row, .link_def, .html_comment => false,
        else => true,
    };
}

/// True when line `k` is an in-item code row (8sp+/tab-indented inside a
/// list item). Top-level code never reaches here (handled by leaders).
fn inItemCodeRow(bytes: []const u8, lines: []const simd.Line, k: usize) bool {
    if (k >= lines.len) return false;
    if (!isCodeClaimable(lines[k].block_type)) return false;
    if (!isIndentedBy(bytes, lines[k], 8)) return false;
    return listContentMarker(bytes, lines, k, 8) != null;
}

/// Finds the indented-code start owning line `j` (blank gaps inside the code
/// included), or null. Code needs a blank (or non-paragraph block) boundary:
/// indented lines can never interrupt a paragraph, list item, or quote.
/// In-item code (inside list markers) is owned by the item instead.
fn indentedCodeLeader(bytes: []const u8, lines: []const simd.Line, j: usize) ?usize {
    if (j >= lines.len) return null;
    if (!isCodeClaimable(lines[j].block_type)) return null;
    if (!isIndentedBy(bytes, lines[j], 4)) return null;
    if (listContentMarker(bytes, lines, j, 8) != null) return null;
    // In-list quotes/headings/rules (4sp+) belong to the item, never code.
    const bt = lines[j].block_type;
    if ((bt == .quote or isHeadingType(bt) or bt == .hr) and
        listContentMarker(bytes, lines, j, 4) != null) return null;
    // Run start: step back over adjacent code rows only (inside blanks are
    // resolved forward by lookahead, never by crossing them here).
    var k = j;
    while (k > 0 and isCodeClaimable(lines[k - 1].block_type) and
        isIndentedBy(bytes, lines[k - 1], 4))
    {
        k -= 1;
    }
    // Valid code only after a blank, document start, or a non-paragraph
    // block (never interrupting text, quotes, or lists).
    if (k == 0) return k;
    const pb = lines[k - 1].block_type;
    if (pb == .blank) return k;
    if (pb == .paragraph or isListLeader(pb) or pb == .quote) return null;
    return k;
}

/// Unified setext detection: line `i` is a paragraph whose next line underlines
/// it (`===` H1 / `---` H2, either line type). The underline must be < 4sp
/// indented (an indented `===` is code, never a heading). Single source for
/// render, height, refine, and snapping.
fn setextLevel(bytes: []const u8, lines: []const simd.Line, i: usize) ?u8 {
    if (i + 1 >= lines.len) return null;
    if (lines[i].block_type != .paragraph) return null;
    const nb = bytes[lines[i + 1].offset..][0..lines[i + 1].len];
    var t = nb;
    var iw: usize = 0;
    while (t.len > 0 and (t[0] == ' ' or t[0] == '\t')) {
        iw += if (t[0] == '\t') 4 else 1;
        if (iw >= 4) return null;
        t = t[1..];
    }
    if (t.len < 2) return null;
    if (t[0] == '=') {
        for (t) |ch| if (ch != '=' and ch != ' ') return null;
        return 1;
    }
    if (t[0] == '-') {
        for (t) |ch| if (ch != '-' and ch != ' ') return null;
        return 2;
    }
    return null;
}

fn isHeadingType(bt: simd.BlockType) bool {
    const v = @intFromEnum(bt);
    return v >= @intFromEnum(simd.BlockType.heading1) and v <= @intFromEnum(simd.BlockType.heading6);
}

const HeadingMetrics = struct {
    font_size: f32,
    line_h: f32,
    margin_top: f32,
    margin_bottom: f32,
};

fn atxMetrics(config: ViewportConfig, level: u8) HeadingMetrics {
    const scale: f32 = switch (level) {
        1 => 2.1,
        2 => 1.6,
        3 => 1.3,
        4 => 1.15,
        else => 1.05,
    };
    const font_size = config.base_font_size * scale;
    return .{
        .font_size = font_size,
        .line_h = font_size * 1.3,
        .margin_top = font_size * 2.5,
        .margin_bottom = font_size * 0.5,
    };
}

fn setextMetrics(config: ViewportConfig, level: u8) HeadingMetrics {
    const font_size = config.base_font_size * (if (level == 1) @as(f32, 2.2) else @as(f32, 1.7));
    return .{
        .font_size = font_size,
        .line_h = config.line_height * (if (level == 1) @as(f32, 1.5) else @as(f32, 1.35)),
        .margin_top = font_size * 1.5,
        .margin_bottom = font_size * 0.5,
    };
}

/// Per-call layout context shared by every unit function below. Render passes
/// the real command buffer; height/refine pass an empty slice (same wrap
/// math, zero emissions), so all three can never diverge.
const UnitCx = struct {
    bytes: []const u8,
    lines: []const simd.Line,
    config: ViewportConfig,
    content_x: f32,
    content_width: f32,
    theme: Theme,
    vp_bottom: f32,
    commands_out: []DrawCommand,
    cmd_count: *usize,
    markers: ?*OrderedMarkerStore,
    ord_active: bool = false,
    ord_next: u32 = 0,
    qord_active: bool = false,
    qord_depth: usize = 0,
    qord_next: u32 = 0,
};

const UnitOut = struct {
    y: f32,
    consumed: usize,
};

fn flowCtxFor(ux: *UnitCx, tx: f32, tw: f32, font_size: f32, line_h: f32, color: Color) FlowCtx {
    return .{
        .font_size = font_size,
        .line_h = line_h,
        .default_color = color,
        .accent_color = ux.theme.accent,
        .start_x = tx,
        .max_w = tw,
        .vp_bottom = ux.vp_bottom,
        .commands_out = ux.commands_out,
        .cmd_count = ux.cmd_count,
        .defs = ux.config.ref_defs,
        .entities = ux.config.entities,
    };
}

fn textRight(ux: *UnitCx) f32 {
    return ux.content_x + ux.content_width;
}

/// Emits one command when capacity remains. No-op for measurement passes
/// (empty buffer), keeping their math identical to rendering.
fn emitCmd(ux: *UnitCx, cmd: DrawCommand) void {
    if (ux.cmd_count.* < ux.commands_out.len) {
        ux.commands_out[ux.cmd_count.*] = cmd;
        ux.cmd_count.* += 1;
    }
}

/// Single soft-break space between flowed lines (never wraps, like spaces).
fn softSpace(pen: *FlowPen, tx: f32, font_size: f32) void {
    if (pen.x > tx) flowSpace(pen, measureCharEx(' ', font_size, false, false, false, false));
}

/// Quote bars for one quote line: one bar per depth level spanning the whole
/// unit (leader line plus absorbed lazy tail).
fn quoteBars(ux: *UnitCx, base_x: f32, depth: usize, start_y: f32, end_y: f32) void {
    if (end_y < 0 or start_y > ux.vp_bottom) return;
    var d: usize = 1;
    while (d <= depth) : (d += 1) {
        emitCmd(ux, .{
            .kind = .fill_rect,
            .rect = .{
                .x = base_x + @as(f32, @floatFromInt(d)) * 16.0 - 12.0,
                .y = start_y,
                .w = 3.0,
                .h = end_y - start_y,
            },
            .color = ux.theme.quote_bar,
        });
    }
}

/// Backward seed for top-level ordered numbering (checkpoint mid-run starts
/// and stale state). Walks back over the same-indent run (capped) to the
/// first marker; beyond the cap the run restarts gracefully.
fn seedOrderedNumber(ux: *UnitCx, i: usize, indent: u7) u32 {
    var k = i;
    var steps: usize = 0;
    while (k > 0 and steps < 512) : (steps += 1) {
        const p = ux.lines[k - 1];
        if (p.block_type != .ordered_list or p.indent != indent) break;
        k -= 1;
    }
    const first = ux.bytes[ux.lines[k].offset..][0..ux.lines[k].len];
    var t = first;
    while (t.len > 0 and (t[0] == ' ' or t[0] == '\t')) : (t = t[1..]) {}
    var d: usize = 0;
    while (d < t.len and t[d] >= '0' and t[d] <= '9') : (d += 1) {}
    const base = parseListNumber(t[0..d]);
    // Count same-indent ordered lines from the run start to i.
    var count: u32 = 0;
    var m = k;
    while (m < i) : (m += 1) {
        if (ux.lines[m].block_type == .ordered_list and ux.lines[m].indent == indent) count += 1;
    }
    return base + count;
}

/// Resolves the display number for top-level ordered item `i` (own value
/// `own`). Carries forward state; re-seeds by backward scan after seeks.
fn orderedNumber(ux: *UnitCx, i: usize, own: u32, indent: u7) u32 {
    const continues = i > 0 and ux.lines[i - 1].block_type == .ordered_list and
        ux.lines[i - 1].indent == indent;
    var n: u32 = own;
    if (continues) {
        n = if (ux.ord_active) ux.ord_next else seedOrderedNumber(ux, i, indent);
    }
    ux.ord_active = true;
    ux.ord_next = if (n < std.math.maxInt(u32)) n + 1 else n;
    return n;
}

/// Backward seed for quoted ordered numbering. Same-indent rule becomes
/// same-depth quoted ordered bodies (capped walk).
fn seedQuotedNumber(ux: *UnitCx, i: usize, depth: usize) u32 {
    var k = i;
    var steps: usize = 0;
    while (k > 0 and steps < 512) : (steps += 1) {
        if (ux.lines[k - 1].block_type != .quote) break;
        const pb = ux.bytes[ux.lines[k - 1].offset..][0..ux.lines[k - 1].len];
        const sq = stripQuoteMarkers(pb);
        if (sq.depth != depth or classifyQuoteBody(sq.body).kind != .ordered) break;
        k -= 1;
    }
    const fb = ux.bytes[ux.lines[k].offset..][0..ux.lines[k].len];
    const fbody = classifyQuoteBody(stripQuoteMarkers(fb).body);
    var count: u32 = 0;
    var m = k;
    while (m < i) : (m += 1) {
        if (ux.lines[m].block_type != .quote) continue;
        const mb = ux.bytes[ux.lines[m].offset..][0..ux.lines[m].len];
        const msq = stripQuoteMarkers(mb);
        if (msq.depth == depth and classifyQuoteBody(msq.body).kind == .ordered) count += 1;
    }
    return fbody.number + count;
}

fn quotedNumber(ux: *UnitCx, i: usize, own: u32, depth: usize) u32 {
    var continues = false;
    if (i > 0 and ux.lines[i - 1].block_type == .quote) {
        const pb = ux.bytes[ux.lines[i - 1].offset..][0..ux.lines[i - 1].len];
        const sq = stripQuoteMarkers(pb);
        continues = (sq.depth == depth and classifyQuoteBody(sq.body).kind == .ordered);
    }
    var n: u32 = own;
    if (continues) {
        n = if (ux.qord_active and ux.qord_depth == depth) ux.qord_next else seedQuotedNumber(ux, i, depth);
    }
    ux.qord_active = true;
    ux.qord_depth = depth;
    ux.qord_next = if (n < std.math.maxInt(u32)) n + 1 else n;
    return n;
}

/// Marker text for an ordered item: corrected "N." / "N)" from the caller
/// store, or the source bytes when no store (or store full).
fn orderedMarkerText(ux: *UnitCx, n: u32, delim: u8, fallback: []const u8) []const u8 {
    if (ux.markers) |st| {
        if (st.push(n, delim)) |s| return s;
    }
    return fallback;
}

/// Flows a lead paragraph: first text plus lazy follower lines joined by
/// soft-break spaces. Never inlined (shared by quote/list units).
fn flowLeadPara(
    ux: *UnitCx,
    tx: f32,
    tw: f32,
    y: f32,
    color: Color,
    first: []const u8,
    from: usize,
) struct { y: f32, next: usize } {
    var pen = FlowPen{ .x = tx, .y = y };
    const ctx = flowCtxFor(ux, tx, tw, ux.config.base_font_size, ux.config.line_height, color);
    flowSourceLine(first, false, false, false, &pen, ctx);
    var j = from;
    while (j < ux.lines.len and isLazyContinuation(ux.bytes, ux.lines, j)) {
        softSpace(&pen, tx, ux.config.base_font_size);
        const lb = ux.bytes[ux.lines[j].offset..][0..ux.lines[j].len];
        flowSourceLine(lb, true, false, false, &pen, ctx);
        j += 1;
    }
    return .{ .y = pen.y + ux.config.line_height, .next = j };
}

/// Consumes blank-separated subsequent paragraphs at the item column.
/// Never inlined (shared by every list flavor).
fn flowListSubParagraphs(
    ux: *UnitCx,
    tx: f32,
    tw: f32,
    y: f32,
    from: usize,
) struct { y: f32, next: usize } {
    var yy = y;
    var j = from;
    while (true) {
        var b = j;
        while (b < ux.lines.len and ux.lines[b].block_type == .blank) b += 1;
        if (b == j or b >= ux.lines.len) {
            j = b;
            break;
        }
        // Subsequent paragraphs start 4-space/tab indented but below code
        // level: 8sp+ starts an in-item code block (own unit, next lines).
        if (ux.lines[b].block_type != .paragraph or !isIndentedBy(ux.bytes, ux.lines[b], 4) or
            isIndentedBy(ux.bytes, ux.lines[b], 8)) break;
        yy += @as(f32, @floatFromInt(b - j)) * ux.config.line_height * 0.75;
        j = b;
        var pen = FlowPen{ .x = tx, .y = yy };
        const ctx = flowCtxFor(ux, tx, tw, ux.config.base_font_size, ux.config.line_height, ux.theme.text);
        while (j < ux.lines.len and isLazyContinuation(ux.bytes, ux.lines, j)) {
            if (j > b) softSpace(&pen, tx, ux.config.base_font_size);
            const lb = ux.bytes[ux.lines[j].offset..][0..ux.lines[j].len];
            flowSourceLine(lb, true, false, false, &pen, ctx);
            j += 1;
        }
        yy = pen.y + ux.config.line_height + 4.0;
    }
    return .{ .y = yy, .next = j };
}

/// Checkbox adornment shared by top-level and quoted task items.
fn emitCheckbox(ux: *UnitCx, tx: f32, y: f32, checked: bool) void {
    if (y + ux.config.line_height < 0 or y > ux.vp_bottom) return;
    emitCmd(ux, .{
        .kind = .fill_rect,
        .rect = .{ .x = tx, .y = y + 4.0, .w = 16.0, .h = 16.0 },
        .color = if (checked) ux.theme.accent else ux.theme.code_bg,
    });
    emitCmd(ux, .{
        .kind = .text_run,
        .rect = .{ .x = tx + 3.0, .y = y + 2.0, .w = 14.0, .h = 16.0 },
        .color = if (checked) Color.white else ux.theme.muted,
        .text = if (checked) "✓" else " ",
        .font_size = 12.0,
        .style = .{ .bold = true },
    });
}

/// Content x for a list item's text given its marker line.
fn itemContentX(marker: simd.Line, content_x: f32) f32 {
    if (marker.block_type == .task_list) return content_x + 28.0;
    var indent_level: f32 = @floatFromInt(marker.indent);
    if (indent_level > 32) indent_level = 32;
    return content_x + indent_level * 10.0 + 18.0;
}

/// Owns paragraph line `j`: the list-item marker whose unit contains it, or
/// null. Ownership follows j's paragraph run: a run directly after a marker
/// is segment 0 (any indent, lazy text); otherwise the run must start
/// 4-space/tab indented but below code level (8sp+ is an in-item code block,
/// never paragraph text). Earlier segments resolve through blank gaps the
/// same way. Iterative and capped.
fn enclosingListMarker(bytes: []const u8, lines: []const simd.Line, j: usize) ?usize {
    if (!isLazyContinuation(bytes, lines, j)) return null;
    // Run containing j (direct lazy connections, no blanks crossed).
    var r = j;
    while (r > 0 and lines[r - 1].block_type == .paragraph and
        isLazyContinuation(bytes, lines, r))
    {
        r -= 1;
    }
    if (r > 0 and isListLeader(lines[r - 1].block_type)) return r - 1;
    // Post-blank run: indented content, never code-level.
    if (!isIndentedBy(bytes, lines[r], 4) or isIndentedBy(bytes, lines[r], 8)) return null;
    // Walk back over gaps and item content to the marker.
    var k = r;
    var guard: usize = 0;
    while (k > 0 and guard < 512) : (guard += 1) {
        while (k > 0 and lines[k - 1].block_type == .blank) k -= 1;
        if (k == 0) return null;
        const pk = k - 1;
        const pb = lines[pk].block_type;
        if (isListLeader(pb)) return pk;
        if (pb == .paragraph) {
            // Previous run: seg0-anchored, or indented non-code.
            var r2 = pk;
            while (r2 > 0 and lines[r2 - 1].block_type == .paragraph and
                isLazyContinuation(bytes, lines, r2))
            {
                r2 -= 1;
            }
            if (r2 > 0 and isListLeader(lines[r2 - 1].block_type)) return r2 - 1;
            if (!isIndentedBy(bytes, lines[r2], 4) or isIndentedBy(bytes, lines[r2], 8)) return null;
            k = r2;
            continue;
        }
        // Cross in-item quote / heading / hr (4sp+) and code (8sp+) lines.
        if ((pb == .quote or isHeadingType(pb) or pb == .hr) and
            isIndentedBy(bytes, lines[pk], 4))
        {
            k = pk;
            continue;
        }
        if (isCodeClaimable(pb) and isIndentedBy(bytes, lines[pk], 8)) {
            k = pk;
            continue;
        }
        return null;
    }
    return null;
}

/// Marker owning an indented non-paragraph content line (in-item quote /
/// heading / rule / code), or null. `need` = required indent (4 or 8).
/// Nested list markers are always own units (never claimed).
fn listContentMarker(bytes: []const u8, lines: []const simd.Line, i: usize, need: usize) ?usize {
    if (i >= lines.len) return null;
    if (!isIndentedBy(bytes, lines[i], need)) return null;
    if (isListLeader(lines[i].block_type)) return null;
    var k = i;
    var guard: usize = 0;
    while (k > 0 and guard < 512) : (guard += 1) {
        while (k > 0 and lines[k - 1].block_type == .blank) k -= 1;
        if (k == 0) return null;
        const pk = k - 1;
        const pb = lines[pk].block_type;
        if (isListLeader(pb)) return pk;
        if (pb == .paragraph) return enclosingListMarker(bytes, lines, pk);
        if ((pb == .quote or isHeadingType(pb) or pb == .hr) and
            isIndentedBy(bytes, lines[pk], 4))
        {
            return listContentMarker(bytes, lines, pk, 4);
        }
        if (isCodeClaimable(pb) and isIndentedBy(bytes, lines[pk], 8)) {
            return listContentMarker(bytes, lines, pk, 8);
        }
        return null;
    }
    return null;
}

/// Base x for an indented block line inside a list item (its text column),
/// or null when top-level.
fn listContentBase(ux: *UnitCx, i: usize, need: usize) ?f32 {
    if (listContentMarker(ux.bytes, ux.lines, i, need)) |m| {
        return itemContentX(ux.lines[m], ux.content_x);
    }
    return null;
}

/// Measurement context for height/refine passes: empty command buffer, no
/// marker store, infinite viewport bottom. Geometry matches rendering exactly.
fn measureCx(
    bytes: []const u8,
    lines: []const simd.Line,
    config: ViewportConfig,
    content_width: f32,
    content_x: f32,
    dummy: *usize,
) UnitCx {
    return .{
        .bytes = bytes,
        .lines = lines,
        .config = config,
        .content_x = content_x,
        .content_width = content_width,
        .theme = Theme.dark,
        .vp_bottom = std.math.inf(f32),
        .commands_out = &.{},
        .cmd_count = dummy,
        .markers = null,
    };
}

/// Lays out one quote source line plus its lazy tail. `base_x` is content_x
/// top-level or the item text column for in-list quotes. Returns the new y
/// and lines consumed (1 + lazy tail). Exactly one bar set spans the unit.
/// Never inlined: one copy serves render, height, and refine (binary budget).
fn layoutQuoteLine(ux: *UnitCx, i: usize, base_x: f32, start_y: f32) UnitOut {
    ux.ord_active = false;
    const qb = ux.bytes[ux.lines[i].offset..][0..ux.lines[i].len];
    const sq = stripQuoteMarkers(qb);
    const body = classifyQuoteBody(sq.body);
    const margin = @as(f32, @floatFromInt(sq.depth)) * 16.0;
    const tx = base_x + margin;
    const tw = ux.content_width - (tx - ux.content_x);
    var y = start_y;
    var consumed: usize = 1;

    switch (body.kind) {
        .text => {
            const f = flowLeadPara(ux, tx, tw, y, ux.theme.muted, sq.body, i + 1);
            y = f.y;
            consumed = f.next - i;
        },
        .code => {
            var pen = FlowPen{ .x = tx, .y = y };
            const ctx = flowCtxFor(ux, tx, tw, ux.config.base_font_size, ux.config.line_height, ux.theme.text);
            flowSourceLine(body.code_text, false, true, false, &pen, ctx);
            y = pen.y + ux.config.line_height;
        },
        .heading => {
            const m = atxMetrics(ux.config, body.level);
            y += m.margin_top;
            var pen = FlowPen{ .x = tx, .y = y };
            const ctx = flowCtxFor(ux, tx, tw, m.font_size, m.line_h, ux.theme.muted);
            const hp = @min(body.prefix_len, sq.body.len);
            const htext = sq.body[hp + skipSpaces(sq.body[hp..]) ..];
            flowSourceLine(htext, false, false, true, &pen, ctx);
            y = pen.y + m.line_h + m.margin_bottom;
            ux.qord_active = false;
        },
        .bullet => {
            if (y + ux.config.line_height >= 0 and y <= ux.vp_bottom) {
                emitCmd(ux, .{
                    .kind = .text_run,
                    .rect = .{ .x = tx, .y = y, .w = 14.0, .h = ux.config.line_height },
                    .color = ux.theme.accent,
                    .text = "•",
                    .font_size = ux.config.base_font_size * 1.1,
                    .style = .{ .bold = true },
                });
            }
            var pen = FlowPen{ .x = tx + 18.0, .y = y };
            const ctx = flowCtxFor(ux, tx + 18.0, tw - 18.0, ux.config.base_font_size, ux.config.line_height, ux.theme.muted);
            const bp = @min(body.prefix_len, sq.body.len);
            const item_text = sq.body[bp + skipSpaces(sq.body[bp..]) ..];
            flowSourceLine(item_text, false, false, false, &pen, ctx);
            y = pen.y + ux.config.line_height;
            ux.qord_active = false;
        },
        .ordered => {
            const num = quotedNumber(ux, i, body.number, sq.depth);
            const marker = orderedMarkerText(ux, num, body.delim, sq.body[0..@min(body.prefix_len, sq.body.len)]);
            if (y + ux.config.line_height >= 0 and y <= ux.vp_bottom) {
                emitCmd(ux, .{
                    .kind = .text_run,
                    .rect = .{ .x = tx, .y = y, .w = 18.0, .h = ux.config.line_height },
                    .color = ux.theme.muted,
                    .text = marker,
                    .font_size = ux.config.base_font_size * 0.95,
                });
            }
            var pen = FlowPen{ .x = tx + 18.0, .y = y };
            const ctx = flowCtxFor(ux, tx + 18.0, tw - 18.0, ux.config.base_font_size, ux.config.line_height, ux.theme.muted);
            const op = @min(body.prefix_len, sq.body.len);
            const item_text = sq.body[op + skipSpaces(sq.body[op..]) ..];
            flowSourceLine(item_text, false, false, false, &pen, ctx);
            y = pen.y + ux.config.line_height;
        },
        .task => {
            emitCheckbox(ux, tx, y, body.checked);
            var pen = FlowPen{ .x = tx + 28.0, .y = y };
            const ctx = flowCtxFor(ux, tx + 28.0, tw - 28.0, ux.config.base_font_size, ux.config.line_height, ux.theme.muted);
            const tp = @min(body.prefix_len, sq.body.len);
            const item_text = sq.body[tp + skipSpaces(sq.body[tp..]) ..];
            flowSourceLine(item_text, false, false, false, &pen, ctx);
            y = pen.y + ux.config.line_height;
            ux.qord_active = false;
        },
    }

    quoteBars(ux, base_x, sq.depth, start_y, y);
    return .{ .y = y, .consumed = consumed };
}

/// Lays out a top-level list item: marker adornment, flowed first paragraph
/// (marker line plus lazy followers), then blank-separated subsequent
/// paragraphs at the item indent. In-item quotes/code/headings are separate
/// units resolved by list context (never consumed here).
/// Never inlined (binary budget; see layoutQuoteLine).
fn layoutListUnit(ux: *UnitCx, i: usize, start_y: f32) UnitOut {
    ux.qord_active = false;
    const info = ux.lines[i];
    const raw = ux.bytes[info.offset..][0..info.len];
    var text_slice = raw;
    while (text_slice.len > 0 and (text_slice[0] == ' ' or text_slice[0] == '\t')) : (text_slice = text_slice[1..]) {}

    const tx = itemContentX(info, ux.content_x);
    const tw = textRight(ux) - tx;
    const y = start_y;
    var item_text: []const u8 = "";
    var bullet_x = tx;

    if (info.block_type == .task_list) {
        const is_checked = (text_slice.len >= 4 and (text_slice[3] == 'x' or text_slice[3] == 'X'));
        var text_start: usize = @min(5, text_slice.len);
        text_start += skipSpaces(text_slice[text_start..]);
        item_text = text_slice[text_start..];
        emitCheckbox(ux, ux.content_x, y, is_checked);
        const txt_color = if (is_checked) ux.theme.muted else ux.theme.text;
        const f = flowLeadPara(ux, tx, tw, y, txt_color, item_text, i + 1);
        const sub = flowListSubParagraphs(ux, tx, tw, f.y, f.next);
        ux.ord_active = false;
        return .{ .y = sub.y, .consumed = sub.next - i };
    }

    if (info.block_type == .bullet_list) {
        var indent_level: f32 = @floatFromInt(info.indent);
        if (indent_level > 32) indent_level = 32;
        bullet_x = ux.content_x + indent_level * 10.0;
        var text_start: usize = 1; // past the marker; skip all padding
        text_start += skipSpaces(text_slice[@min(text_start, text_slice.len)..]);
        item_text = text_slice[@min(text_start, text_slice.len)..];
        if (y + ux.config.line_height >= 0 and y <= ux.vp_bottom) {
            emitCmd(ux, .{
                .kind = .text_run,
                .rect = .{ .x = bullet_x, .y = y, .w = 14.0, .h = ux.config.line_height },
                .color = ux.theme.accent,
                .text = "•",
                .font_size = ux.config.base_font_size * 1.1,
                .style = .{ .bold = true },
            });
        }
        ux.ord_active = false;
    } else {
        // Ordered item: parse marker, resolve corrected number.
        var indent_level: f32 = @floatFromInt(info.indent);
        if (indent_level > 32) indent_level = 32;
        bullet_x = ux.content_x + indent_level * 10.0;
        var prefix_len: usize = 0;
        while (prefix_len < text_slice.len and text_slice[prefix_len] != ' ' and text_slice[prefix_len] != '\t') : (prefix_len += 1) {}
        if (prefix_len < text_slice.len) prefix_len += 1;
        const op_start = @min(prefix_len, text_slice.len);
        item_text = text_slice[op_start + skipSpaces(text_slice[op_start..]) ..];
        var d: usize = 0;
        while (d < text_slice.len and text_slice[d] >= '0' and text_slice[d] <= '9') : (d += 1) {}
        const own = parseListNumber(text_slice[0..d]);
        const delim: u8 = if (d < text_slice.len and text_slice[d] == ')') ')' else '.';
        const num = orderedNumber(ux, i, own, info.indent);
        const marker = orderedMarkerText(ux, num, delim, text_slice[0..@min(prefix_len, text_slice.len)]);
        if (y + ux.config.line_height >= 0 and y <= ux.vp_bottom) {
            emitCmd(ux, .{
                .kind = .text_run,
                .rect = .{ .x = bullet_x, .y = y, .w = 18.0, .h = ux.config.line_height },
                .color = ux.theme.muted,
                .text = marker,
                .font_size = ux.config.base_font_size * 0.95,
            });
        }
    }

    const list_tx = bullet_x + 18.0;
    const list_tw = textRight(ux) - list_tx;
    const f = flowLeadPara(ux, list_tx, list_tw, y, ux.theme.text, item_text, i + 1);
    const sub = flowListSubParagraphs(ux, list_tx, list_tw, f.y, f.next);
    return .{ .y = sub.y, .consumed = sub.next - i };
}

/// Own start number of an ordered-list line, or null when not ordered.
fn orderedOwnNumber(bytes: []const u8, line: simd.Line) ?u32 {
    if (line.block_type != .ordered_list) return null;
    var t = bytes[line.offset..][0..line.len];
    while (t.len > 0 and (t[0] == ' ' or t[0] == '\t')) : (t = t[1..]) {}
    var d: usize = 0;
    while (d < t.len and t[d] >= '0' and t[d] <= '9') : (d += 1) {}
    if (d == 0 or d + 1 >= t.len) return null;
    if (t[d] != '.' and t[d] != ')') return null;
    if (t[d + 1] != ' ' and t[d + 1] != '\t') return null;
    return parseListNumber(t[0..d]);
}

/// Start of the top-level paragraph run owning list line `j` as lazy
/// continuation text. Two marker kinds never interrupt a paragraph (Markdown
/// 1.0 reference: `Version\n8. x` and `bullet.\n* y` both stay one paragraph):
/// ordered markers numbered != 1, and `*` bullets (`-`/`+` keep interrupting,
/// matching the auto-links reference where the paragraph line is absorbed).
/// Null when the line starts its own list (blank/doc-start/non-paragraph
/// boundary, an intervening interrupting marker) or when the owning paragraph
/// belongs to a list or quote (those followers absorb paragraph lines only,
/// keeping every path that consumes this line in exact agreement).
/// Iterative: no recursion risk on adversarial input.
/// True for markers that never interrupt a paragraph: ordered numbers != 1
/// and `*` bullets (`-`/`+` keep interrupting).
fn isNonInterruptingMarker(bytes: []const u8, lines: []const simd.Line, m: usize) bool {
    if (m >= lines.len) return false;
    const b = lines[m].block_type;
    if (b == .ordered_list) return (orderedOwnNumber(bytes, lines[m]) orelse 1) != 1;
    if (b == .bullet_list) {
        const raw = bytes[lines[m].offset..][0..lines[m].len];
        var t = raw;
        while (t.len > 0 and (t[0] == ' ' or t[0] == '\t')) : (t = t[1..]) {}
        return t.len > 0 and t[0] == '*';
    }
    return false;
}

fn listContinuationStart(bytes: []const u8, lines: []const simd.Line, j: usize) ?usize {
    if (!isNonInterruptingMarker(bytes, lines, j)) return null;
    var k = j;
    while (k > 0) {
        const pb = lines[k - 1].block_type;
        if (pb == .blank) return null;
        if (pb == .paragraph) {
            if (enclosingListMarker(bytes, lines, k - 1) != null) return null;
            if (quoteLeader(bytes, lines, k - 1) != null) return null;
            return unitStartAt(bytes, lines, k - 1);
        }
        if (pb == .ordered_list or pb == .bullet_list) {
            if (isNonInterruptingMarker(bytes, lines, k - 1)) {
                k -= 1;
                continue;
            }
            return null;
        }
        return null;
    }
    return null;
}

/// Flows paragraph line `k` (leading-stripped per `strip`), joining it with
/// `k+1` when the pair forms a cross-line reference (`Foo [bar]` + `[1].`
/// flows exactly like `Foo [bar] [1].`, Markdown 1.0). The next line must be
/// a lazy continuation so setext pairs and foreign units never merge.
/// Returns the next unflowed index (`k+1` normally, `k+2` after a joint).
fn flowParaLineJoint(ux: *UnitCx, pen: *FlowPen, tx: f32, ctx: FlowCtx, k: usize, strip: bool) usize {
    const raw = ux.bytes[ux.lines[k].offset..][0..ux.lines[k].len];
    var lb = raw;
    if (strip) {
        while (lb.len > 0 and (lb[0] == ' ' or lb[0] == '\t')) : (lb = lb[1..]) {}
    }
    if (ux.config.join_buf) |jb| {
        const nk = k + 1;
        if (nk < ux.lines.len and isLazyContinuation(ux.bytes, ux.lines, nk) and
            setextLevel(ux.bytes, ux.lines, nk) == null)
        {
            var a = lb;
            while (a.len > 0 and (a[a.len - 1] == ' ' or a[a.len - 1] == '\t')) : (a = a[0 .. a.len - 1]) {}
            var b = ux.bytes[ux.lines[nk].offset..][0..ux.lines[nk].len];
            while (b.len > 0 and (b[0] == ' ' or b[0] == '\t')) : (b = b[1..]) {}
            if (a.len > 0 and a[a.len - 1] == ']' and b.len > 0 and b[0] == '[' and
                a.len + 1 + b.len <= jb.len)
            {
                @memcpy(jb[0..a.len], a);
                jb[a.len] = ' ';
                @memcpy(jb[a.len + 1 ..][0..b.len], b);
                // Head lines flow without a leading soft space; followers
                // take one exactly like the non-joint path.
                if (strip) softSpace(pen, tx, ux.config.base_font_size);
                flowSourceLine(jb[0 .. a.len + 1 + b.len], false, false, false, pen, ctx);
                return nk + 1;
            }
        }
    }
    if (strip) softSpace(pen, tx, ux.config.base_font_size);
    flowSourceLine(lb, strip, false, false, pen, ctx);
    return k + 1;
}

/// Lays out a paragraph unit: setext pair (consumes 2) or a flowed run of
/// soft-break-joined lines with a single trailing gap.
/// `base_x` is content_x, or the item column for list-owned runs past
/// intervening quote/code blocks.
fn layoutParagraphUnit(ux: *UnitCx, i: usize, base_x: f32, start_y: f32) UnitOut {
    ux.ord_active = false;
    ux.qord_active = false;
    const bw = ux.content_x + ux.content_width - base_x;
    if (setextLevel(ux.bytes, ux.lines, i)) |lvl| {
        const m = setextMetrics(ux.config, lvl);
        var y = start_y + m.margin_top;
        var pen = FlowPen{ .x = base_x, .y = y };
        const ctx = flowCtxFor(ux, base_x, bw, m.font_size, m.line_h, ux.theme.text);
        const lb = ux.bytes[ux.lines[i].offset..][0..ux.lines[i].len];
        flowSourceLine(lb, false, false, true, &pen, ctx);
        y = pen.y + m.line_h + m.margin_bottom;
        return .{ .y = y, .consumed = 2 };
    }
    var pen = FlowPen{ .x = base_x, .y = start_y };
    const ctx = flowCtxFor(ux, base_x, bw, ux.config.base_font_size, ux.config.line_height, ux.theme.text);
    // Cross-line reference joints only in top-level runs (list/quote-owned
    // followers absorb paragraph lines only, and unitStartAt agrees).
    const allow_joint = ux.config.join_buf != null and
        enclosingListMarker(ux.bytes, ux.lines, i) == null and
        quoteLeader(ux.bytes, ux.lines, i) == null;
    var j = i + 1;
    if (allow_joint) {
        j = flowParaLineJoint(ux, &pen, base_x, ctx, i, false);
    } else {
        const first = ux.bytes[ux.lines[i].offset..][0..ux.lines[i].len];
        flowSourceLine(first, false, false, false, &pen, ctx);
    }
    while (j < ux.lines.len and
        ((ux.lines[j].block_type == .paragraph and
            setextLevel(ux.bytes, ux.lines, j) == null) or
            ((listContinuationStart(ux.bytes, ux.lines, j) orelse (j + 1)) == i)))
    {
        if (allow_joint) {
            const strip = true;
            const before = j;
            j = flowParaLineJoint(ux, &pen, base_x, ctx, j, strip);
            if (j == before) {
                // Defensive: helper always advances; never spin.
                j += 1;
            }
        } else {
            softSpace(&pen, base_x, ux.config.base_font_size);
            const lb = ux.bytes[ux.lines[j].offset..][0..ux.lines[j].len];
            flowSourceLine(lb, true, false, false, &pen, ctx);
            j += 1;
        }
    }
    return .{ .y = pen.y + ux.config.line_height + 4.0, .consumed = j - i };
}

/// Strips one indent level (4 spaces or 1 tab) for code content.
fn stripCodeIndent(raw: []const u8) []const u8 {
    if (raw.len > 0 and raw[0] == '\t') return raw[1..];
    if (raw.len >= 4 and raw[0] == ' ' and raw[1] == ' ' and raw[2] == ' ' and raw[3] == ' ') return raw[4..];
    return raw;
}

/// Lays out an indented code block: card background (with copy text),
/// one mono row per line, blank rows preserved inside. No horizontal-scroll
/// registration (fixed card, clipped). `base_x` is content_x top-level or
/// the item column for in-list code.
/// Never inlined (binary budget; see layoutQuoteLine).
fn layoutIndentedCodeUnit(ux: *UnitCx, i: usize, base_x: f32, start_y: f32) UnitOut {
    ux.ord_active = false;
    ux.qord_active = false;
    // Extent: code lines plus inside blanks (a blank only when code follows).
    var j = i;
    while (j < ux.lines.len) {
        const bt = ux.lines[j].block_type;
        if (bt == .blank) {
            var nb = j + 1;
            while (nb < ux.lines.len and ux.lines[nb].block_type == .blank) nb += 1;
            if (nb < ux.lines.len and isCodeClaimable(ux.lines[nb].block_type) and
                isIndentedBy(ux.bytes, ux.lines[nb], 4))
            {
                j = nb + 1;
                continue;
            }
            break;
        }
        if (isCodeClaimable(bt) and isIndentedBy(ux.bytes, ux.lines[j], 4)) {
            j += 1;
            continue;
        }
        break;
    }
    const n = j - i;
    const row_h = ux.config.line_height * 0.88;
    const card_h = @as(f32, @floatFromInt(n)) * row_h + 24.0;
    const card_x = base_x - 12.0;
    const card_w = textRight(ux) - card_x;
    if (start_y + card_h >= 0 and start_y <= ux.vp_bottom) {
        const slice = ux.bytes[ux.lines[i].offset..][0 .. ux.lines[j - 1].offset + ux.lines[j - 1].len - ux.lines[i].offset];
        emitCmd(ux, .{
            .kind = .code_block_bg,
            .rect = .{ .x = card_x, .y = start_y, .w = card_w, .h = card_h },
            .color = ux.theme.code_bg,
            .text = slice,
        });
        emitCmd(ux, .{
            .kind = .begin_clip,
            .rect = .{ .x = card_x, .y = start_y, .w = card_w, .h = card_h },
        });
        var row_y = start_y + 12.0;
        var r = i;
        while (r < j) : (r += 1) {
            if (row_y + 20.0 >= 0 and row_y <= ux.vp_bottom) {
                var row_text: []const u8 = "";
                if (ux.lines[r].block_type != .blank) {
                    row_text = stripCodeIndent(ux.bytes[ux.lines[r].offset..][0..ux.lines[r].len]);
                }
                emitCmd(ux, .{
                    .kind = .text_run,
                    .rect = .{ .x = base_x, .y = row_y, .w = card_w, .h = row_h },
                    .color = ux.theme.text,
                    .text = row_text,
                    .font_size = ux.config.base_font_size * 0.88,
                    .style = .{ .code = true },
                });
            } else {
                // Capped row above the viewport still advances.
            }
            row_y += row_h;
        }
        emitCmd(ux, .{ .kind = .end_clip, .rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 } });
    }
    return .{ .y = start_y + card_h + 16.0, .consumed = n };
}

/// Shared virtualized render core: emits draw commands for `lines[start_line..]`,
/// positioned with `start_line` at viewport-relative `origin_y`, assigning
/// Scroll affordance shadows for horizontally scrollable code blocks and
/// tables: a short edge-fade strip painted inside the block's clip rect so
/// readers can see the block scrolls. Right shadow while content still hides
/// to the right; left shadow once scrolled right; none when the content fits.
/// The overlay contrasts with the surface (light in dark mode, dark in light
/// mode): a dark-on-dark shadow has almost no headroom (card 26 -> 22 at
/// full alpha), while a contrasting overlay swings ~32 levels in both
/// themes. Rendered as plain `fill_rect` strips: no new platform interface,
/// no allocation, identical live and headless output.
const scroll_shadow_strips: u32 = 4;
const scroll_shadow_strip_w: f32 = 3.0;
/// Edge -> inward alphas (strongest at the clipped edge, fading to content).
/// Kept low: the band should whisper, not shout.
const scroll_shadow_alphas = [_]u8{ 18, 11, 6, 3 };
/// Vertical end-insets per strip, outer -> inward. The outer strip runs full
/// height so the band sits flush and straight on the clip edge (like a real
/// shadow cast from a straight edge); inner strips recede, rounding the band
/// toward the content instead of cutting off in square corners.
const scroll_shadow_end_insets = [_]f32{ 0.0, 2.0, 5.0, 9.0 };

fn emitScrollShadows(
    commands_out: []DrawCommand,
    cmd_count: *usize,
    bx: f32,
    by: f32,
    bw: f32,
    bh: f32,
    cur_scroll_x: f32,
    max_scroll_x: f32,
    is_dark_theme: bool,
) void {
    if (max_scroll_x <= 1.0) return;
    // Contrasting overlay: light glow on dark surfaces, dark shade on light.
    const sh: u8 = if (is_dark_theme) 255 else 0;
    const total_w = scroll_shadow_strip_w * @as(f32, @floatFromInt(scroll_shadow_strips));
    // Clamp rounded ends to the band height so tiny blocks keep sane rects.
    const max_inset = @max(bh * 0.5 - 1.0, 0.0);
    // Right edge: more content hides to the right.
    if (cur_scroll_x < max_scroll_x - 0.5) {
        var s: u32 = 0;
        while (s < scroll_shadow_strips) : (s += 1) {
            if (cmd_count.* >= commands_out.len) return;
            const inset = @min(scroll_shadow_end_insets[scroll_shadow_strips - 1 - s], max_inset);
            const sh_h = bh - 2.0 * inset;
            if (sh_h <= 0.0) continue;
            commands_out[cmd_count.*] = .{
                .kind = .fill_rect,
                .rect = .{
                    .x = bx + bw - total_w + @as(f32, @floatFromInt(s)) * scroll_shadow_strip_w,
                    .y = by + inset,
                    .w = scroll_shadow_strip_w,
                    .h = sh_h,
                },
                .color = .{ .r = sh, .g = sh, .b = sh, .a = scroll_shadow_alphas[scroll_shadow_strips - 1 - s] },
            };
            cmd_count.* += 1;
        }
    }
    // Left edge: scrolled right, content hides to the left.
    if (cur_scroll_x > 0.5) {
        var s: u32 = 0;
        while (s < scroll_shadow_strips) : (s += 1) {
            if (cmd_count.* >= commands_out.len) return;
            const inset = @min(scroll_shadow_end_insets[s], max_inset);
            const sh_h = bh - 2.0 * inset;
            if (sh_h <= 0.0) continue;
            commands_out[cmd_count.*] = .{
                .kind = .fill_rect,
                .rect = .{
                    .x = bx + @as(f32, @floatFromInt(s)) * scroll_shadow_strip_w,
                    .y = by + inset,
                    .w = scroll_shadow_strip_w,
                    .h = sh_h,
                },
                .color = .{ .r = sh, .g = sh, .b = sh, .a = scroll_shadow_alphas[s] },
            };
            cmd_count.* += 1;
        }
    }
}

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

    var unit_cx = UnitCx{
        .bytes = bytes,
        .lines = lines,
        .config = config,
        .content_x = content_x,
        .content_width = content_width,
        .theme = theme,
        .vp_bottom = vp_bottom,
        .commands_out = commands_out,
        .cmd_count = &cmd_count,
        .markers = config.ordered_markers,
    };

    while (i < lines.len) : (i += 1) {
        if (cmd_count >= commands_out.len - 16) break;

        const line_info = lines[i];

        // Early exit if past bottom of viewport
        if (cur_y > vp_bottom) break;

        const line_bytes = bytes[line_info.offset..][0..line_info.len];

        // ----------------------------------------------------
        // Indented code blocks (4sp/1tab): in-list code at the item
        // column, otherwise top-level code cards with copy text.
        // Mid-unit seeks fall through to plain dispatch below; window
        // snapping keeps production starts on unit boundaries.
        // ----------------------------------------------------
        if (isCodeClaimable(line_info.block_type)) {
            if (listContentBase(&unit_cx, i, 8)) |item_base| {
                const r = layoutIndentedCodeUnit(&unit_cx, i, item_base, cur_y);
                cur_y = r.y;
                i += r.consumed - 1;
                continue;
            }
            if (indentedCodeLeader(bytes, lines, i)) |lead| {
                if (lead == i) {
                    const r = layoutIndentedCodeUnit(&unit_cx, i, content_x, cur_y);
                    cur_y = r.y;
                    i += r.consumed - 1;
                    continue;
                }
            }
        }

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
                    // Reserve room for scroll shadows + end clip below.
                    if (cmd_count >= commands_out.len - 16) break;
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

                // Scroll affordance shadows over the code text, inside the clip.
                emitScrollShadows(
                    commands_out,
                    &cmd_count,
                    content_x - 12.0,
                    cur_y,
                    content_width + 24.0,
                    code_block_h,
                    cur_scroll_x,
                    max_scroll_x,
                    config.is_dark_theme,
                );

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
                                        const w = measureTextEx(cell_text, config.base_font_size * 0.92, false, false, false, false) + 24.0;
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
                                            const w = measureTextEx(s.text, config.base_font_size * 0.90, s_style.bold, false, s_style.code, false);

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
                                            span_x += w + measureCharEx(' ', config.base_font_size * 0.90, false, false, false, false);
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

                // Scroll affordance shadows over the row cells, inside the clip.
                emitScrollShadows(
                    commands_out,
                    &cmd_count,
                    content_x - 4.0,
                    cur_y - 2.0,
                    content_width + 8.0,
                    table_h + 4.0,
                    cur_scroll_x,
                    max_scroll_x,
                    config.is_dark_theme,
                );

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

            // In-list headings (4sp+) render at the item column.
            const hx = if (lineIndentWidth(bytes, line_info) >= 4)
                listContentBase(&unit_cx, i, 4) orelse content_x
            else
                content_x;
            const hw = content_x + content_width - hx;

            cur_y += margin_top;

            const h_text = line_bytes[h_offset..];
            const span_count = resolveHeadingSpans(config, h_text, &span_buf);

            const end_y = layoutWrappedSpans(
                span_buf[0..span_count],
                hx,
                hw,
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
            // In-list rules (4sp+) align with the item column.
            const hx = if (lineIndentWidth(bytes, line_info) >= 4)
                listContentBase(&unit_cx, i, 4) orelse content_x
            else
                content_x;
            if (cur_y + 20.0 >= 0 and cur_y <= vp_bottom) {
                commands_out[cmd_count] = .{
                    .kind = .line,
                    .rect = .{ .x = hx, .y = cur_y + 10.0, .w = content_x + content_width - hx, .h = 1.0 },
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
        // Reference definitions and HTML comments never render.
        // ----------------------------------------------------
        if (line_info.block_type == .link_def or line_info.block_type == .html_comment) {
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
        // Blockquote (nested quotes, lazy tails, quoted blocks)
        // ----------------------------------------------------
        if (line_info.block_type == .quote) {
            const base_x = listContentBase(&unit_cx, i, 4) orelse content_x;
            const r = layoutQuoteLine(&unit_cx, i, base_x, cur_y);
            cur_y = r.y;
            i += r.consumed - 1;
            continue;
        }

        // ----------------------------------------------------
        // Lists (tasks, bullets, ordered with corrected numbers)
        // ----------------------------------------------------
        if (isListLeader(line_info.block_type)) {
            const r = layoutListUnit(&unit_cx, i, cur_y);
            cur_y = r.y;
            i += r.consumed - 1;
            continue;
        }
        // ----------------------------------------------------
        // Paragraph runs (soft-break flow) and setext headings.
        // List-owned runs past intervening quote/code blocks resolve
        // to the item column via backward context.
        // ----------------------------------------------------
        const pbase = if (enclosingListMarker(bytes, lines, i)) |m|
            itemContentX(lines[m], content_x)
        else
            content_x;
        const r = layoutParagraphUnit(&unit_cx, i, pbase, cur_y);
        cur_y = r.y;
        i += r.consumed - 1;
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
            // Snap back to the containing unit start (checkpoints land on
            // raw line granularity, possibly mid-run) and re-measure the
            // skipped prefix exactly so y and block ids stay truthful.
            const s0 = snapWindowStart(bytes, lines, cp.line_idx);
            const cw = contentWidthOf(config);
            const cx = contentXOf(config);
            var y_skip: f32 = 0.0;
            var id_skip: usize = 0;
            var k = s0;
            while (k < cp.line_idx and k < lines.len) {
                const u = refineLineHeight(bytes, lines, k, config, cw, cx);
                y_skip += u.height;
                id_skip += countScrollableBlocks(lines, k, @min(k + @max(u.consumed, 1), lines.len));
                k += @max(u.consumed, 1);
            }
            i = s0;
            cur_y = cp.y - y_skip - config.scroll_y;
            next_block_id = cp.next_block_id -| @min(id_skip, cp.next_block_id);
        }
    }

    return renderViewportCore(bytes, lines, config, i, cur_y, next_block_id, commands_out);
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

    var unit_cx = UnitCx{
        .bytes = bytes,
        .lines = lines,
        .config = config,
        .content_x = content_x,
        .content_width = content_width,
        .theme = Theme.dark,
        .vp_bottom = std.math.inf(f32),
        .commands_out = &.{},
        .cmd_count = &dummy_cmd_count,
        .markers = null,
    };

    while (i < lines.len) : (i += 1) {
        // Record sparse checkpoint at clean block boundary
        if (checkpoints_out) |cps| {
            if ((i == 0 or i >= last_cp_line + checkpoint_grid_lines) and cp_count < cps.len) {
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

        // 0. Indented code blocks (shared unit; no scrollable id consumed).
        if (isCodeClaimable(line_info.block_type)) {
            if (listContentBase(&unit_cx, i, 8)) |item_base| {
                const r = layoutIndentedCodeUnit(&unit_cx, i, item_base, cur_y);
                cur_y = r.y;
                i += r.consumed - 1;
                continue;
            }
            if (indentedCodeLeader(bytes, lines, i)) |lead| {
                if (lead == i) {
                    const r = layoutIndentedCodeUnit(&unit_cx, i, content_x, cur_y);
                    cur_y = r.y;
                    i += r.consumed - 1;
                    continue;
                }
            }
        }

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

            const hx = if (lineIndentWidth(bytes, line_info) >= 4)
                listContentBase(&unit_cx, i, 4) orelse content_x
            else
                content_x;
            const hw = content_x + content_width - hx;

            cur_y += margin_top;

            const h_text = line_bytes[h_offset..];
            const span_count = resolveHeadingSpans(config, h_text, &span_buf);

            const end_y = layoutWrappedSpans(
                span_buf[0..span_count],
                hx,
                hw,
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

        // Reference definitions and HTML comments take no space.
        if (line_info.block_type == .link_def or line_info.block_type == .html_comment) {
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

        // 6. Blockquote (shared unit: nested, lazy tails, quoted blocks)
        if (line_info.block_type == .quote) {
            const base_x = listContentBase(&unit_cx, i, 4) orelse content_x;
            const r = layoutQuoteLine(&unit_cx, i, base_x, cur_y);
            cur_y = r.y;
            i += r.consumed - 1;
            continue;
        }

        // 7+8. Lists (shared unit: markers, continuations, sub-paragraphs)
        if (isListLeader(line_info.block_type)) {
            const r = layoutListUnit(&unit_cx, i, cur_y);
            cur_y = r.y;
            i += r.consumed - 1;
            continue;
        }

        // 9. Paragraph runs and setext headings (shared unit)
        const pbase = if (enclosingListMarker(bytes, lines, i)) |m|
            itemContentX(lines[m], content_x)
        else
            content_x;
        const r = layoutParagraphUnit(&unit_cx, i, pbase, cur_y);
        cur_y = r.y;
        i += r.consumed - 1;
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

/// Counts scroll-shadow strips (`fill_rect`s of shadow-strip width in the
/// theme's overlay shade `sh`: 255 dark mode, 0 light mode) hugging the
/// left (`at_left = true`) or right edge of a block rect.
fn countShadowStrips(cmds: []const DrawCommand, edge_x: f32, at_left: bool, sh: u8) usize {
    var n: usize = 0;
    for (cmds) |c| {
        if (c.kind != .fill_rect) continue;
        if (c.color.r != sh or c.color.g != sh or c.color.b != sh or c.color.a == 0) continue;
        if (@abs(c.rect.w - scroll_shadow_strip_w) > 0.01) continue;
        const anchor = if (at_left) c.rect.x else c.rect.x + c.rect.w;
        if (@abs(anchor - edge_x) <= scroll_shadow_strip_w * @as(f32, @floatFromInt(scroll_shadow_strips)) + 0.01) n += 1;
    }
    return n;
}

test "scroll shadows: overflowing code block shows right-edge fade when unscrolled" {
    const test_doc =
        \\```zig
        \\this_is_a_very_long_code_line_that_far_exceeds_the_content_width_and_must_overflow_the_visible_card_area_abcdefghij
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

    var max_scroll: f32 = 0.0;
    for (cmds[0..count]) |c| {
        if (c.kind == .register_scrollable_block) max_scroll = c.max_scroll_x;
    }
    try std.testing.expect(max_scroll > 1.0);

    // Block card: content_x=100, content_width=600 -> x=88, right edge=712.
    try std.testing.expectEqual(@as(usize, scroll_shadow_strips), countShadowStrips(cmds[0..count], 712.0, false, 255));
    try std.testing.expectEqual(@as(usize, 0), countShadowStrips(cmds[0..count], 88.0, true, 255));
    try std.testing.expectEqual(@as(usize, 0), countShadowStrips(cmds[0..count], 712.0, false, 0));

    // Rounded ends, straight on the clip edge: the brightest (outermost)
    // strip runs full height while the dimmest (innermost) recedes.
    var outer: ?DrawCommand = null;
    var inner: ?DrawCommand = null;
    for (cmds[0..count]) |c| {
        if (c.kind != .fill_rect or c.color.r != 255 or c.color.g != 255 or c.color.b != 255) continue;
        if (@abs(c.rect.w - scroll_shadow_strip_w) > 0.01) continue;
        if (@abs((c.rect.x + c.rect.w) - 712.0) > 12.01) continue;
        if (outer == null or c.color.a > outer.?.color.a) outer = c;
        if (inner == null or c.color.a < inner.?.color.a) inner = c;
    }
    try std.testing.expect(outer != null and inner != null);
    try std.testing.expect(outer.?.rect.y < inner.?.rect.y);
    try std.testing.expect(outer.?.rect.h > inner.?.rect.h);
}

test "scroll shadows: scrolled-right code block shows left-edge fade, no right fade" {
    const test_doc =
        \\```zig
        \\this_is_a_very_long_code_line_that_far_exceeds_the_content_width_and_must_overflow_the_visible_card_area_abcdefghij
        \\```
    ;

    var lines_buf: [64]simd.Line = undefined;
    var fence = false;
    const line_count = simd.scanLines(test_doc, &lines_buf, &fence);

    var cmds: [256]DrawCommand = undefined;
    var config = ViewportConfig{
        .window_width = 800.0,
        .window_height = 1000.0,
        .scroll_y = 0.0,
    };
    config.block_scroll_x[0] = 1e9; // clamped to max inside layout
    const count = layoutViewport(test_doc, lines_buf[0..line_count], config, &cmds);

    try std.testing.expectEqual(@as(usize, scroll_shadow_strips), countShadowStrips(cmds[0..count], 88.0, true, 255));
    try std.testing.expectEqual(@as(usize, 0), countShadowStrips(cmds[0..count], 712.0, false, 255));
    try std.testing.expectEqual(@as(usize, 0), countShadowStrips(cmds[0..count], 88.0, true, 0));
}

test "scroll shadows: fitting code block shows no fade" {
    const test_doc =
        \\```zig
        \\short
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

    var max_scroll: f32 = 0.0;
    var strips: usize = 0;
    for (cmds[0..count]) |c| {
        if (c.kind == .register_scrollable_block) max_scroll = c.max_scroll_x;
        if (c.kind == .fill_rect and c.color.r == 255 and c.color.g == 255 and c.color.b == 255 and c.color.a != 0) strips += 1;
    }
    try std.testing.expectEqual(@as(f32, 0.0), max_scroll);
    try std.testing.expectEqual(@as(usize, 0), strips);
}

test "scroll shadows: overflowing table shows right-edge fade" {
    const test_doc =
        \\# Wide Table
        \\
        \\| Alpha Column One With Long Content Here | Beta Column Two With Long Content Here | Gamma Column Three With Long Content Here |
        \\| :--- | :--- | :--- |
        \\| averylongcellvalue_alpha_abcdefghijklmnopqrstuvwxyz | averylongcellvalue_beta_abcdefghijklmnopqrstuvwxyz | averylongcellvalue_gamma_abcdefghijklmnopqrstuvwxyz |
    ;

    var lines_buf: [64]simd.Line = undefined;
    var fence = false;
    const line_count = simd.scanLines(test_doc, &lines_buf, &fence);

    var cmds: [512]DrawCommand = undefined;
    const config = ViewportConfig{
        .window_width = 800.0,
        .window_height = 1000.0,
        .scroll_y = 0.0,
    };
    const count = layoutViewport(test_doc, lines_buf[0..line_count], config, &cmds);

    var max_scroll: f32 = 0.0;
    for (cmds[0..count]) |c| {
        if (c.kind == .register_scrollable_block) max_scroll = c.max_scroll_x;
    }
    try std.testing.expect(max_scroll > 1.0);

    // Table clip: content_x=100 -> x=96, w=608, right edge=704.
    try std.testing.expectEqual(@as(usize, scroll_shadow_strips), countShadowStrips(cmds[0..count], 704.0, false, 255));
    try std.testing.expectEqual(@as(usize, 0), countShadowStrips(cmds[0..count], 96.0, true, 255));
}

test "scroll shadows: light theme uses a dark overlay" {
    const test_doc =
        \\```zig
        \\this_is_a_very_long_code_line_that_far_exceeds_the_content_width_and_must_overflow_the_visible_card_area_abcdefghij
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
        .is_dark_theme = false,
    };
    const count = layoutViewport(test_doc, lines_buf[0..line_count], config, &cmds);

    // Dark strips at the right edge, no light strips anywhere near the block.
    try std.testing.expectEqual(@as(usize, scroll_shadow_strips), countShadowStrips(cmds[0..count], 712.0, false, 0));
    try std.testing.expectEqual(@as(usize, 0), countShadowStrips(cmds[0..count], 712.0, false, 255));
    try std.testing.expectEqual(@as(usize, 0), countShadowStrips(cmds[0..count], 88.0, true, 0));
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
    if (bt == .link_def or bt == .html_comment) return 0.0;
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

    // Indented code units (top-level and in-list) before type dispatch,
    // mirroring renderViewportCore and computeDocumentHeightEx.
    if (isCodeClaimable(info.block_type)) {
        var mux0 = measureCx(bytes, lines, config, content_width, content_x, &dummy);
        if (listContentMarker(bytes, lines, idx, 8)) |m| {
            const base = itemContentX(lines[m], content_x);
            const r = layoutIndentedCodeUnit(&mux0, idx, base, 0);
            return .{ .height = r.y, .consumed = r.consumed };
        }
        if (indentedCodeLeader(bytes, lines, idx)) |lead| {
            if (lead == idx) {
                const r = layoutIndentedCodeUnit(&mux0, idx, content_x, 0);
                return .{ .height = r.y, .consumed = r.consumed };
            }
            return .{ .height = 0.0, .consumed = 1 };
        }
    }

    switch (info.block_type) {
        .blank => return .{ .height = lh * 0.75, .consumed = 1 },
        // Reference definitions and HTML comments never render: their
        // block types exist so no paragraph, list, quote, or code unit can
        // absorb them (hiding is structural, not per-call).
        .link_def, .html_comment => return .{ .height = 0.0, .consumed = 1 },
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
            const span_count = resolveHeadingSpans(config, line_bytes[h_offset..], &span_buf);
            var mux_h = measureCx(bytes, lines, config, content_width, content_x, &dummy);
            const hx = if (lineIndentWidth(bytes, info) >= 4)
                listContentBase(&mux_h, idx, 4) orelse content_x
            else
                content_x;
            const end_y = layoutWrappedSpans(span_buf[0..span_count], hx, content_x + content_width - hx, 0, font_size, heading_line_h, Color.transparent, Color.transparent, std.math.inf(f32), &.{}, &dummy);
            return .{ .height = margin_top + end_y + margin_bottom, .consumed = 1 };
        },
        .quote => {
            var mux = measureCx(bytes, lines, config, content_width, content_x, &dummy);
            const base_x = listContentBase(&mux, idx, 4) orelse content_x;
            const r = layoutQuoteLine(&mux, idx, base_x, 0);
            return .{ .height = r.y, .consumed = r.consumed };
        },
        .task_list, .bullet_list, .ordered_list => {
            // Absorbed as paragraph-run text: the owning unit measures it.
            if ((info.block_type == .ordered_list or info.block_type == .bullet_list) and
                listContinuationStart(bytes, lines, idx) != null)
            {
                return .{ .height = 0.0, .consumed = 1 };
            }
            var mux = measureCx(bytes, lines, config, content_width, content_x, &dummy);
            const r = layoutListUnit(&mux, idx, 0);
            return .{ .height = r.y, .consumed = r.consumed };
        },
        .paragraph => {
            var mux = measureCx(bytes, lines, config, content_width, content_x, &dummy);
            // Paragraph lines claimed by quotes are measured as part of
            // those units (their own slots hold 0). Code lines are handled
            // by the pre-switch block above. List-owned runs measure at the
            // item column, wherever the forward scan reaches them.
            if (quoteLeader(bytes, lines, idx) != null) return .{ .height = 0.0, .consumed = 1 };
            const pbase = if (enclosingListMarker(bytes, lines, idx)) |m|
                itemContentX(lines[m], content_x)
            else
                content_x;
            const r = layoutParagraphUnit(&mux, idx, pbase, 0);
            return .{ .height = r.y, .consumed = r.consumed };
        },
    }
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

/// True when blank line `j` sits inside a list unit: the next content line is
/// list-owned and the previous content line belongs to the same item.
fn blankInsideListUnit(bytes: []const u8, lines: []const simd.Line, j: usize) bool {
    if (j >= lines.len or lines[j].block_type != .blank) return false;
    var n = j + 1;
    while (n < lines.len and lines[n].block_type == .blank) n += 1;
    if (n >= lines.len) return false;
    const next_owned = (lines[n].block_type == .paragraph and
        enclosingListMarker(bytes, lines, n) != null) or
        (listContentMarker(bytes, lines, n, 4) != null) or
        (isCodeClaimable(lines[n].block_type) and listContentMarker(bytes, lines, n, 8) != null);
    if (!next_owned) return false;
    var p = j;
    while (p > 0 and lines[p - 1].block_type == .blank) p -= 1;
    if (p == 0) return false;
    const pk = p - 1;
    const pb = lines[pk].block_type;
    if (isListLeader(pb)) return true;
    if (pb == .paragraph and enclosingListMarker(bytes, lines, pk) != null) return true;
    if ((pb == .quote or isHeadingType(pb) or pb == .hr) and
        isIndentedBy(bytes, lines[pk], 4) and
        listContentMarker(bytes, lines, pk, 4) != null) return true;
    if (isCodeClaimable(pb) and isIndentedBy(bytes, lines[pk], 8) and
        listContentMarker(bytes, lines, pk, 8) != null) return true;
    return false;
}

/// True when line `k` is a code row on either side of an inside blank:
/// top-level code (leader-resolved) or an in-item code row.
fn codeRowAt(bytes: []const u8, lines: []const simd.Line, k: usize) bool {
    if (k >= lines.len) return false;
    if (indentedCodeLeader(bytes, lines, k) != null) return true;
    return inItemCodeRow(bytes, lines, k);
}

/// Start of the indented-code unit containing code row `j`, walking back
/// over rows and inside blanks. Separate blank-adjacent code blocks always
/// merge forward, so any blank-adjacent chain is one unit.
fn codeUnitStart(bytes: []const u8, lines: []const simd.Line, j: usize) usize {
    var k = j;
    var guard: usize = 0;
    while (k > 0 and guard < 512) : (guard += 1) {
        if (codeRowAt(bytes, lines, k - 1)) {
            k -= 1;
            continue;
        }
        if (lines[k - 1].block_type == .blank) {
            var b = k - 1;
            while (b > 0 and lines[b - 1].block_type == .blank) b -= 1;
            if (b > 0 and codeRowAt(bytes, lines, b - 1)) {
                k = b - 1;
                continue;
            }
        }
        break;
    }
    return k;
}

/// True when blank line `j` sits inside an indented code unit: code rows on
/// both sides with no other block between.
fn blankInsideCodeUnit(bytes: []const u8, lines: []const simd.Line, j: usize) bool {
    if (j >= lines.len or lines[j].block_type != .blank) return false;
    var n = j + 1;
    while (n < lines.len and lines[n].block_type == .blank) n += 1;
    if (n >= lines.len) return false;
    if (!codeRowAt(bytes, lines, n)) return false;
    var p = j;
    while (p > 0 and lines[p - 1].block_type == .blank) p -= 1;
    if (p == 0) return false;
    return codeRowAt(bytes, lines, p - 1);
}

/// Start of the layout unit containing line `j`: leaders return themselves,
/// followers resolve to their unit start (quote/list/code/run/fence/table).
/// Single backward pass, no stepping, so adversarial runs stay linear.
pub fn unitStartAt(bytes: []const u8, lines: []const simd.Line, j: usize) usize {
    if (j >= lines.len) return lines.len;
    if (j == 0) return 0;
    const bt = lines[j].block_type;
    if (bt == .code_line or bt == .code_fence_end) {
        var s = j;
        if (lines[s].block_type == .code_fence_end and s > 0) s -= 1;
        while (s > 0 and lines[s].block_type == .code_line) : (s -= 1) {}
        return s;
    }
    if (bt == .table_row) {
        var s = j;
        while (s > 0 and lines[s - 1].block_type == .table_row) : (s -= 1) {}
        return s;
    }
    if (setextLevel(bytes, lines, j - 1) != null) return j - 1;
    // Non-interrupting markers flow as text inside the owning paragraph run.
    if (bt == .ordered_list or bt == .bullet_list) {
        if (listContinuationStart(bytes, lines, j)) |s| return s;
    }
    if (bt == .blank) {
        if (blankInsideListUnit(bytes, lines, j) or blankInsideCodeUnit(bytes, lines, j)) {
            var k = j;
            while (k > 0 and lines[k - 1].block_type == .blank) k -= 1;
            return unitStartAt(bytes, lines, k - 1);
        }
        return j;
    }
    if (bt == .paragraph) {
        if (quoteLeader(bytes, lines, j)) |q| return q;
        if (enclosingListMarker(bytes, lines, j)) |m| return m;
        if (isIndentedBy(bytes, lines[j], 4) and
            (indentedCodeLeader(bytes, lines, j) != null or inItemCodeRow(bytes, lines, j)))
        {
            return codeUnitStart(bytes, lines, j);
        }
        var k = j;
        while (k > 0 and lines[k - 1].block_type == .paragraph and
            setextLevel(bytes, lines, k - 1) == null and setextLevel(bytes, lines, k) == null)
        {
            k -= 1;
        }
        return k;
    }
    return j;
}

/// Snaps a window start index backwards to a layout-unit boundary so rendering
/// never begins mid-fence, mid-table, mid-run, or on a setext underline.
pub fn snapWindowStart(bytes: []const u8, lines: []const simd.Line, idx: usize) usize {
    return unitStartAt(bytes, lines, @min(idx, lines.len));
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
    if (e < lines.len and e > 0 and setextLevel(bytes, lines, e - 1) != null) e += 1;
    var guard: usize = 0;
    while (e < lines.len and guard < 4096 and unitContinuesAt(bytes, lines, e)) : ({
        e += 1;
        guard += 1;
    }) {}
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
    // Setext underline continues the heading unit started above it.
    if (j > 0 and setextLevel(bytes, lines, j - 1) != null) return true;
    // Non-interrupting markers absorbed as paragraph-run text continue it.
    if (bt == .ordered_list or bt == .bullet_list) {
        if (listContinuationStart(bytes, lines, j)) |s| return s < j;
    }
    // Blanks inside list/code units.
    if (bt == .blank) {
        return blankInsideListUnit(bytes, lines, j) or blankInsideCodeUnit(bytes, lines, j);
    }
    if (bt == .paragraph) {
        // Claimed followers continue their quote/list/code units.
        if (quoteLeader(bytes, lines, j)) |q| return q < j;
        if (enclosingListMarker(bytes, lines, j)) |m| return m < j;
        if (isCodeClaimable(bt) and isIndentedBy(bytes, lines[j], 4) and
            (indentedCodeLeader(bytes, lines, j) != null or inItemCodeRow(bytes, lines, j)))
        {
            return codeUnitStart(bytes, lines, j) < j;
        }
        // Paragraph-run continuation (never into/through setext pairs).
        if (j > 0 and lines[j - 1].block_type == .paragraph and
            setextLevel(bytes, lines, j - 1) == null and setextLevel(bytes, lines, j) == null)
        {
            return true;
        }
        return false;
    }
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

// ============================================================================
// Section-link anchors: `#fragment` links scroll to headings.
// ============================================================================

/// GitHub-style slug: lowercase ASCII, keep alnum/underscore/hyphen/space,
/// drop the rest, spaces become hyphens. Writes into the caller buffer.
pub fn slugifyHeading(text: []const u8, out: []u8) usize {
    var n: usize = 0;
    for (text) |c| {
        var ch = c;
        if (ch >= 'A' and ch <= 'Z') ch += 'a' - 'A';
        const keep = (ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9') or
            ch == '_' or ch == '-' or ch == ' ' or ch == '\t';
        if (!keep) continue;
        if (n >= out.len) break;
        out[n] = if (ch == ' ' or ch == '\t') '-' else ch;
        n += 1;
    }
    return n;
}

fn commonPrefixLen(a: []const u8, b: []const u8) usize {
    var n: usize = 0;
    while (n < a.len and n < b.len and a[n] == b[n]) : (n += 1) {}
    return n;
}

/// Light stemmer for compound matching ("escaping" -> "escap") so hand
/// anchors like "autoescape" resolve against suffixed slug words.
fn stemWord(word: []const u8) []const u8 {
    if (word.len > 5 and std.mem.endsWith(u8, word, "ing")) return word[0 .. word.len - 3];
    if (word.len > 4 and std.mem.endsWith(u8, word, "ed")) return word[0 .. word.len - 2];
    if (word.len > 4 and std.mem.endsWith(u8, word, "es")) return word[0 .. word.len - 2];
    if (word.len > 3 and std.mem.endsWith(u8, word, "s")) return word[0 .. word.len - 1];
    return word;
}

fn matchCompound(anchor: []const u8, slug: []const u8) bool {
    var ai: usize = 0;
    var si: usize = 0;
    var pieces: usize = 0;
    while (ai < anchor.len) {
        // Next slug word starting at si.
        var wend = si;
        while (wend < slug.len and slug[wend] != '-') : (wend += 1) {}
        const word = slug[si..wend];
        const stem = stemWord(word);
        // Longest valid piece first: shortest-valid would mis-split.
        // A piece matches when it shares the whole stem (or the whole
        // piece when shorter), with at least 3 chars in common.
        var k = anchor.len - ai;
        var found = false;
        while (k >= 3) : (k -= 1) {
            const cp = commonPrefixLen(anchor[ai..][0..k], word);
            const m = @min(k, stem.len);
            if (m >= 3 and cp >= m) {
                ai += k;
                found = true;
                break;
            }
        }
        if (!found) return false;
        pieces += 1;
        si = if (wend < slug.len) wend + 1 else wend;
        if (si >= slug.len and ai < anchor.len) return false;
    }
    return pieces >= 2;
}

/// Ordered character match ("img" resolves to "images"). Late fallback only.
fn isSubsequence(needle: []const u8, haystack: []const u8) bool {
    var ni: usize = 0;
    for (haystack) |c| {
        if (ni < needle.len and c == needle[ni]) ni += 1;
    }
    return ni == needle.len;
}

fn matchAcronym(anchor: []const u8, slug: []const u8) bool {
    if (anchor.len < 2) return false;
    var ai: usize = 0;
    var si: usize = 0;
    while (si < slug.len) {
        var wend = si;
        while (wend < slug.len and slug[wend] != '-') : (wend += 1) {}
        if (ai >= anchor.len or slug[si] != anchor[ai]) return false;
        ai += 1;
        si = if (wend < slug.len) wend + 1 else wend;
    }
    return ai == anchor.len;
}

/// Anchor-to-slug match tier (lower wins). Exact GitHub slugs beat every
/// legacy fallback so `#code` targets "Code" even past an earlier "Code
/// Blocks"; among prefix ties (`#p` vs "Philosophy"/"Paragraphs") document
/// order still decides. Both sides must already be lowercased.
pub fn anchorTier(anchor: []const u8, slug: []const u8) ?u3 {
    if (anchor.len == 0 or slug.len == 0) return null;
    if (std.mem.eql(u8, anchor, slug)) return 0;
    if (slug.len > anchor.len and std.mem.startsWith(u8, slug, anchor)) return 1;
    if (std.mem.lastIndexOfScalar(u8, slug, '-')) |li| {
        if (std.mem.eql(u8, anchor, slug[li + 1 ..])) return 2;
    }
    if (matchCompound(anchor, slug)) return 3;
    if (matchAcronym(anchor, slug)) return 4;
    if (anchor.len >= 3 and std.mem.indexOf(u8, slug, anchor) != null) return 5;
    // Ordered character match (hand abbreviations like "img" for "images").
    if (anchor.len >= 3 and isSubsequence(anchor, slug)) return 6;
    // A slug word affixes the anchor ("precode" ends with "code"). Affix
    // only: infix containment ("blockquote" holding "block") must not
    // outrank a later prefix match ("Blockquotes").
    var si: usize = 0;
    while (si < slug.len) {
        var wend = si;
        while (wend < slug.len and slug[wend] != '-') : (wend += 1) {}
        const word = slug[si..wend];
        if (word.len >= 4 and (std.mem.startsWith(u8, anchor, word) or
            std.mem.endsWith(u8, anchor, word))) return 7;
        si = if (wend < slug.len) wend + 1 else wend;
    }
    return null;
}

/// Anchor-to-slug matching: true when any tier matches.
pub fn anchorMatchesSlug(anchor: []const u8, slug: []const u8) bool {
    return anchorTier(anchor, slug) != null;
}

/// Plain text of an ATX heading line (strips markers and closing hashes).
fn atxHeadingText(line: []const u8) []const u8 {
    var t = line;
    while (t.len > 0 and (t[0] == ' ' or t[0] == '\t')) : (t = t[1..]) {}
    while (t.len > 0 and t[0] == '#') : (t = t[1..]) {}
    while (t.len > 0 and (t[0] == ' ' or t[0] == '\t')) : (t = t[1..]) {}
    while (t.len > 0 and (t[t.len - 1] == ' ' or t[t.len - 1] == '\t')) : (t = t[0 .. t.len - 1]) {}
    // Closing hash run ("## foo ##"): only when space-separated.
    var h = t.len;
    while (h > 0 and t[h - 1] == '#') : (h -= 1) {}
    if (h < t.len and h > 0 and (t[h - 1] == ' ' or t[h - 1] == '\t')) {
        t = t[0..h];
        while (t.len > 0 and (t[t.len - 1] == ' ' or t[t.len - 1] == '\t')) : (t = t[0 .. t.len - 1]) {}
    }
    return t;
}

/// Appends span plain text (markup stripped) joined by spaces into `out`.
/// Returns bytes written.
fn appendInlinePlain(text: []const u8, out: []u8, used: usize) usize {
    var span_buf: [32]parser.InlineSpan = undefined;
    const n = parser.parseInlines(text, &span_buf);
    var u = used;
    for (span_buf[0..n]) |span| {
        if (u > used) {
            if (u >= out.len) break;
            out[u] = ' ';
            u += 1;
        }
        const room = if (u < out.len) out.len - u else 0;
        const take = @min(span.text.len, room);
        @memcpy(out[u..][0..take], span.text[0..take]);
        u += take;
        if (take < span.text.len) break;
    }
    return u;
}

/// Document y (same basis as scroll offsets) of the heading unit targeted by
/// `#fragment`, or null when no heading matches. ATX and setext headings
/// both participate. Match tiers win globally: an exact slug anywhere beats
/// an earlier prefix (`#code` targets "Code", not "Code Blocks"), a prefix
/// beats an earlier affix (`#blockquote` targets "Blockquotes", not "Block
/// Elements"). Within one tier the first document match wins. Clicks are
/// rare, so replaying the pure height walk per tier is free. Empty = top.
pub fn anchorScrollY(
    bytes: []const u8,
    lines: []const simd.Line,
    config: ViewportConfig,
    fragment: []const u8,
) ?f32 {
    if (fragment.len == 0) return 0.0;
    var abuf: [128]u8 = undefined;
    const alen = slugifyHeading(fragment[0..@min(fragment.len, 128)], &abuf);
    const anchor = abuf[0..alen];

    const cw = contentWidthOf(config);
    const cx = contentXOf(config);
    var text_buf: [512]u8 = undefined;
    var slug_buf: [128]u8 = undefined;
    var tier: u3 = 0;
    while (true) {
        var y: f32 = 50.0;
        var i: usize = 0;
        while (i < lines.len) {
            const bt = lines[i].block_type;
            const is_head = isHeadingType(bt) or
                (bt == .paragraph and setextLevel(bytes, lines, i) != null);
            if (is_head) {
                var used: usize = 0;
                if (isHeadingType(bt)) {
                    used = appendInlinePlain(atxHeadingText(bytes[lines[i].offset..][0..lines[i].len]), &text_buf, 0);
                } else {
                    // Setext content may span lines: walk back over its run.
                    var k = i;
                    while (k > 0 and lines[k - 1].block_type == .paragraph and
                        quoteLeader(bytes, lines, k - 1) == null and
                        enclosingListMarker(bytes, lines, k - 1) == null and
                        indentedCodeLeader(bytes, lines, k - 1) == null)
                    {
                        // k-1 is another unit's underline: stop before crossing.
                        if (k >= 2 and setextLevel(bytes, lines, k - 2) != null) break;
                        // (k-1, k) forming a pair would make k an underline,
                        // impossible for content lines; kept as a guard.
                        if (setextLevel(bytes, lines, k - 1) != null) break;
                        k -= 1;
                    }
                    var m = k;
                    used = 0;
                    while (m <= i) : (m += 1) {
                        used = appendInlinePlain(bytes[lines[m].offset..][0..lines[m].len], &text_buf, used);
                    }
                }
                const slen = slugifyHeading(text_buf[0..used], &slug_buf);
                if (anchorTier(anchor, slug_buf[0..slen])) |t| {
                    if (t == tier) return y;
                }
            }
            const u = refineLineHeight(bytes, lines, i, config, cw, cx);
            y += u.height;
            i += @max(u.consumed, 1);
        }
        if (tier == 7) return null;
        tier += 1;
    }
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
    const exact_total = computeDocumentHeightEx(virtual_test_doc, lines, config, null, null);
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

    const exact = computeDocumentHeightEx(mem, lines, config, null, null);
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
    const doc_h = computeDocumentHeightEx(mem, lines, base_cfg, null, null);
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
    if (simd.enforce_timing_budgets) {
        try std.testing.expect(min_elapsed_us <= 12);
    }
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
    const acc = computeDocumentHeightEx(doc, lines_buf[0..lc], cfg, null, null);
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
    if (simd.enforce_timing_budgets) {
        try std.testing.expect(min_us <= 12);
    }

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
