const std = @import("std");

pub const PlatformCallbacks = extern struct {
    on_scroll: ?*const fn (delta_x: f32, delta_y: f32, hovered_block_id: c_int, precise: c_int) callconv(.c) void,
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
    /// Scrollbar drag target (absolute scroll_y, clamped by the Zig side).
    /// Appended last for the same FFI stability reason.
    on_scroll_to: ?*const fn (scroll_y: f32) callconv(.c) void = null,
    /// Async image natural sizes landed, with the above-viewport height
    /// delta (0 when the image is at/below the viewport top: nothing above
    /// moved). Appended last for the same FFI stability reason.
    on_images_changed: ?*const fn (delta_above: f32) callconv(.c) void = null,
    /// System appearance changed (effectiveAppearance): 1 = dark, 0 =
    /// light. Appended last for the same FFI stability reason.
    on_appearance: ?*const fn (is_dark: c_int) callconv(.c) void = null,
    /// Cmd+J outline picker key. Appended last for the same FFI reason.
    on_outline_open: ?*const fn () callconv(.c) void = null,
    /// Display preferences: system size class (0..4) and Reduce Motion
    /// flag (issue #315 removed user zoom). Pushed at launch, on motion
    /// flips, and on re-activation. Appended last for the same FFI
    /// stability reason.
    on_display: ?*const fn (category_class: c_int, reduce_motion: c_int) callconv(.c) void = null,
    /// Open-file pick (Cmd+O panel, window or Dock-icon drop, #43):
    /// absolute filesystem path, UTF-8. Appended last for the same
    /// FFI stability reason.
    on_open_file: ?*const fn (path: [*]const u8, path_len: c_int) callconv(.c) void = null,
    /// External file change (vnode event, #44). Appended last for the
    /// same FFI stability reason.
    on_file_changed: ?*const fn () callconv(.c) void = null,
    /// Find bar (issue #42): query text, cycle direction (prev != 0),
    /// bar dismissed. Appended last for the same FFI stability reason.
    on_find_query: ?*const fn (text: [*]const u8, text_len: c_int) callconv(.c) void = null,
    on_find_next: ?*const fn (prev: c_int) callconv(.c) void = null,
    on_find_closed: ?*const fn () callconv(.c) void = null,
};

pub extern "c" fn platform_outline_add(level: c_int, y: f32, text: [*]const u8, text_len: c_int) void;
pub extern "c" fn platform_outline_show() void;
pub extern "c" fn platform_test_outline_filter(text: [*]const u8, text_len: c_int, filter: [*]const u8, filter_len: c_int) c_int;
pub extern "c" fn platform_test_outline_build() c_int;

/// Current rubber-band overshoot in points (positive = content shifted
/// down). Synced every draw; the platform translates the frame by it.
pub extern "c" fn platform_sync_overshoot(overshoot: f32) void;

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
/// Scrollbar drag model: absolute offset plus the clamp range and view
/// height, so the platform can map pointer y to a scroll target with the
/// same geometry the Zig filament draws. Called every draw.
pub extern "c" fn platform_set_scroll_info(scroll_y: f32, max_scroll_y: f32, view_h: f32) void;
/// Overscroll strip theme sync (issue #104): the window background tracks
/// the app theme, which a `t` override can diverge from the system.
pub extern "c" fn platform_sync_theme(dark: c_int) void;
pub extern "c" fn platform_test_theme_synced() c_int;

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

/// Visited-link probe (issue #25): 1 when this URL was opened before.
pub extern "c" fn platform_link_visited(url: ?[*]const u8, url_len: c_int) c_int;

pub extern "c" fn platform_draw_image(
    url: ?[*]const u8,
    url_len: c_int,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    alt: ?[*]const u8,
    alt_len: c_int,
) void;

/// Inline-code pill: rounded-rect fill + 1px border (radius in px).
pub extern "c" fn platform_draw_pill(
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    radius: f32,
    fr: u8,
    fg: u8,
    fb: u8,
    fa: u8,
    br: u8,
    bg: u8,
    bb: u8,
    ba: u8,
) void;
pub extern "c" fn platform_set_document_dir(path: [*]const u8, path_len: c_int) void;
pub extern "c" fn platform_test_image_resolve(dir: [*]const u8, dirlen: c_int, rel: [*]const u8, rellen: c_int) c_int;
pub extern "c" fn platform_test_image_session() c_int;

pub extern "c" fn platform_get_image_size(
    url: ?[*]const u8,
    url_len: c_int,
    out_w: *f32,
    out_h: *f32,
) void;

pub extern "c" fn platform_set_test_damage(x: f32, y: f32, w: f32, h: f32, valid: c_int) void;
pub extern "c" fn platform_text_record_count() c_int;
pub extern "c" fn platform_set_test_selection(x1: f32, y1: f32, x2: f32, y2: f32, enable: c_int) void;
pub extern "c" fn platform_set_test_hover(x: f32, y: f32) void;
pub extern "c" fn platform_test_button_damage(bx: f32, by: f32, bw: f32, bh: f32, ox: *f32, oy: *f32, ow: *f32, oh: *f32) void;
pub extern "c" fn platform_images_pending() c_int;
pub extern "c" fn platform_arm_images() void;
/// Async plugin renderer launcher (issue #323, Task 3): non-blocking child
/// launch. Returns 1 active (slot spent), 0 queued (table full: retry
/// later, no error surfaced), -1 failed (binary unresolvable or not
/// launchable: no slot spent). Args are NUL-terminated; the caller stages
/// srcfile and hands over ownership until the terminal state. On the -1
/// and 0 paths nothing is transferred: the caller retains srcfile (the
/// 0-path is test-pinned: the rejected src stays present).
/// Cap note: at most 8 children in flight (PLUGIN_MAX_INFLIGHT in
/// macos.m) against the 16-entry Zig job table (MAX_PLUGIN_JOBS in
/// src/core/plugin_cache.zig); Task 5 keeps the overflow queued.
pub extern "c" fn launchPluginRender(renderer: [*:0]const u8, srcfile: [*:0]const u8, outfile: [*:0]const u8) c_int;
/// Main-loop reap drain: reaps exited render children without blocking and
/// frees their slots. Returns completions drained this call (>= 0).
/// Task 5 calls this only while the in-flight count is > 0.
pub extern "c" fn pollPluginCompletions() c_int;
/// Per-job outcome query for Task 5 (the drain count alone cannot carry
/// it: the slot is freed at reap). Query by outfile path promptly after
/// poll reports completions: 1 clean render, 0 renderer failed (nonzero
/// exit or bad outfile, even when bytes exist), -1 no record. Use it to
/// mark ready vs failed without re-statting or duplicating the mtime
/// check; an in-flight path may still show its prior generation.
pub extern "c" fn pluginOutcomeFor(outfile: [*:0]const u8) c_int;
/// Headless probe (TEST_HOOKS builds only): in-flight render child count.
pub extern "c" fn platform_test_plugin_active() c_int;
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
    scroll_x: f32,
) void;

pub extern "c" fn platform_begin_clip(
    x: f32,
    y: f32,
    w: f32,
    h: f32,
) void;

pub extern "c" fn platform_end_clip() void;

pub extern "c" fn platform_glyph_cache_stats(
    hits: *u64,
    misses: *u64,
    flushes: *u64,
) void;

pub extern "c" fn platform_test_image_draws() c_ulong;
pub extern "c" fn platform_test_tabbing() c_int;
pub extern "c" fn platform_test_appearance() c_int;
/// Modifier-gate probe (issue #32): 1 when the flag set reaches
/// plain-letter bindings. Test-hooks builds only.
pub extern "c" fn platform_test_key_plain(flags: c_ulong) c_int;
/// Drop the selection/highlight model (issue #43): called after swapping
/// the document, before redraw.
pub extern "c" fn platform_clear_selection() void;
/// External-change watcher (issue #44): event-driven vnode source.
pub extern "c" fn platform_watch_file(path: [*]const u8, path_len: c_int) void;
pub extern "c" fn platform_unwatch_file() void;
pub extern "c" fn platform_test_watch_active() c_int;
/// Extension-gate probe (issue #43): 1 when the path passes the Markdown
/// filter. Test-hooks builds only.
pub extern "c" fn platform_test_markdown_ext(path: [*]const u8, path_len: c_int) c_int;
/// Find bar push (issue #42): 1-based current match + total for the
/// count label; hide on document switch.
pub extern "c" fn platform_find_show_count(current: c_int, total: c_int) void;
pub extern "c" fn platform_find_hide() void;
pub extern "c" fn platform_open_url_external(url: [*]const u8, url_len: c_int) void;
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
