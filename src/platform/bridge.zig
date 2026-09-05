const std = @import("std");

pub const PlatformCallbacks = extern struct {
    on_scroll: ?*const fn (delta_x: f32, delta_y: f32) callconv(.c) void,
    on_resize: ?*const fn (width: c_int, height: c_int) callconv(.c) void,
    on_key: ?*const fn (key_code: c_int) callconv(.c) void,
    on_draw: ?*const fn (width: c_int, height: c_int) callconv(.c) void,
};

pub extern "c" fn platform_init(
    title: [*:0]const u8,
    width: c_int,
    height: c_int,
    callbacks: PlatformCallbacks,
) c_int;

pub extern "c" fn platform_run_loop() void;
pub extern "c" fn platform_request_redraw() void;
pub extern "c" fn platform_sync_scroll(scroll_y: f32) void;

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
    r: u8,
    g: u8,
    b: u8,
    a: u8,
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

pub extern "c" fn platform_measure_text(
    text: [*]const u8,
    len: c_int,
    font_size: f32,
    is_bold: c_int,
    is_mono: c_int,
) f32;

pub extern "c" fn platform_render_to_png(
    output_path: [*:0]const u8,
    width: c_int,
    height: c_int,
    render_fn: *const fn (width: c_int, height: c_int) callconv(.c) void,
) c_int;
