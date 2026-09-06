const std = @import("std");

pub const PlatformCallbacks = extern struct {
    on_scroll: ?*const fn (delta_x: f32, delta_y: f32, hovered_block_id: c_int) callconv(.c) void,
    on_resize: ?*const fn (width: c_int, height: c_int) callconv(.c) void,
    on_key: ?*const fn (key_code: c_int, hovered_block_id: c_int) callconv(.c) void,
    on_draw: ?*const fn (width: c_int, height: c_int) callconv(.c) void,
    /// Section-link clicks (`#fragment` URLs). Appended last so existing
    /// field offsets never shift across the FFI boundary.
    on_link: ?*const fn (url: [*]const u8, url_len: c_int) callconv(.c) void = null,
    /// Display-link tick for scroll smoothing (dt in ms). Returns 1 while
    /// more frames are needed, 0 when settled. Appended last for the same
    /// FFI stability reason.
    on_tick: ?*const fn (dt_ms: f32) callconv(.c) c_int = null,
};

pub extern "c" fn platform_init(
    title: [*:0]const u8,
    width: c_int,
    height: c_int,
    callbacks: PlatformCallbacks,
) c_int;

pub extern "c" fn platform_run_loop() void;
pub extern "c" fn platform_request_redraw() void;
pub extern "c" fn platform_request_redraw_rect(x: f32, y: f32, w: f32, h: f32) void;
/// Returns 1 and fills out the dirty rect AppKit reported for this draw,
/// or 0 when there is no pending damage (headless render, first draw).
pub extern "c" fn platform_get_pending_damage(x: *f32, y: *f32, w: *f32, h: *f32) c_int;
pub extern "c" fn platform_sync_scroll(scroll_y: f32) void;
/// Arm the 120Hz smoothing timer. No-op while it is already running; the
/// timer parks itself when on_tick reports settled, so a static screen
/// costs zero wakeups.
pub extern "c" fn platform_smooth_kick() void;

pub extern "c" fn platform_draw_rect(
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    r: u8,
    g: u8,
    b: u8,
    a: u8,
) void;

pub extern "c" fn platform_draw_text(
    text: [*]const u8,
    len: c_int,
    x: f32,
    y: f32,
    font_size: f32,
    is_bold: c_int,
    is_italic: c_int,
    is_mono: c_int,
    is_heading: c_int,
    r: u8,
    g: u8,
    b: u8,
    a: u8,
    link_url: ?[*]const u8,
    link_url_len: c_int,
) void;

pub extern "c" fn platform_draw_image(
    url: ?[*]const u8,
    url_len: c_int,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
) void;

pub extern "c" fn platform_get_image_size(
    url: ?[*]const u8,
    url_len: c_int,
    out_w: *f32,
    out_h: *f32,
) void;

pub extern "c" fn platform_set_test_damage(x: f32, y: f32, w: f32, h: f32, valid: c_int) void;
pub extern "c" fn platform_text_record_count() c_int;
pub extern "c" fn platform_set_test_selection(x1: f32, y1: f32, x2: f32, y2: f32, enable: c_int) void;
pub extern "c" fn platform_images_pending() c_int;
pub extern "c" fn platform_probe_px_add(x: c_int, y: c_int) void;

pub extern "c" fn platform_register_text_run(
    text: [*]const u8,
    len: c_int,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    font_size: f32,
    is_bold: c_int,
    is_italic: c_int,
    is_mono: c_int,
    is_heading: c_int,
    link_url: ?[*]const u8,
    link_url_len: c_int,
) void;

pub extern "c" fn platform_register_code_block(
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    code_text: [*]const u8,
    code_len: c_int,
) void;

pub extern "c" fn platform_register_scrollable_block(
    block_id: c_int,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    max_scroll_x: f32,
) void;

pub extern "c" fn platform_begin_clip(
    x: f32,
    y: f32,
    w: f32,
    h: f32,
) void;

pub extern "c" fn platform_end_clip() void;

pub extern "c" fn platform_measure_text(
    text: [*]const u8,
    len: c_int,
    font_size: f32,
    is_bold: c_int,
    is_mono: c_int,
) f32;

pub extern "c" fn platform_glyph_cache_stats(
    hits: *u64,
    misses: *u64,
    flushes: *u64,
) void;

pub extern "c" fn platform_test_image_draws() c_ulong;
pub extern "c" fn platform_test_image_primed(total_frames: *c_ulong, primed_frames: *c_ulong) void;
pub extern "c" fn platform_set_test_scale(s: f32) void;
pub extern "c" fn platform_render_select_drag_png(
    output_path: [*:0]const u8,
    width: c_int,
    height: c_int,
    render_fn: *const fn (width: c_int, height: c_int) callconv(.c) void,
    ax1: f32,
    ay1: f32,
    ax2: f32,
    ay2: f32,
    bx1: f32,
    by1: f32,
    bx2: f32,
    by2: f32,
) c_int;

pub extern "c" fn platform_render_to_png(
    output_path: [*:0]const u8,
    width: c_int,
    height: c_int,
    render_fn: *const fn (width: c_int, height: c_int) callconv(.c) void,
) c_int;
