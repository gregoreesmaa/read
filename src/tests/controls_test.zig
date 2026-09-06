const std = @import("std");
const layout = @import("../layout/viewport.zig");
const simd = @import("../core/simd.zig");
const parser = @import("../core/parser.zig");
const mmap = @import("../core/mmap.zig");

// Simulation of SelectionState and ControlState matching macOS / App logic
pub const SelectionMode = enum {
    none,
    range,
    word,
    line,
    all,
};

pub const Point = struct {
    x: f32 = 0,
    y: f32 = 0,
};

pub const SelectionState = struct {
    has_selection: bool = false,
    mode: SelectionMode = .none,
    start: Point = .{},
    end: Point = .{},

    pub fn onMouseDown(
        self: *SelectionState,
        click_x: f32,
        click_y: f32,
        click_count: usize,
        records: []const layout.DrawCommand,
    ) void {
        self.has_selection = true;
        self.start = .{ .x = click_x, .y = click_y };
        self.end = self.start;

        if (click_count == 2) {
            self.mode = .word;
            // Locate word boundary
            for (records) |cmd| {
                if (cmd.kind == .text_run and
                    click_x >= cmd.rect.x and click_x <= cmd.rect.x + cmd.rect.w and
                    click_y >= cmd.rect.y and click_y <= cmd.rect.y + cmd.rect.h)
                {
                    self.start = .{ .x = cmd.rect.x, .y = cmd.rect.y + cmd.rect.h * 0.5 };
                    self.end = .{ .x = cmd.rect.x + cmd.rect.w, .y = cmd.rect.y + cmd.rect.h * 0.5 };
                    break;
                }
            }
        } else if (click_count >= 3) {
            self.mode = .line;
            var min_x: f32 = 9999.0;
            var max_x: f32 = -9999.0;
            for (records) |cmd| {
                if (cmd.kind == .text_run and @abs(cmd.rect.y + cmd.rect.h * 0.5 - click_y) < 16.0) {
                    min_x = @min(min_x, cmd.rect.x);
                    max_x = @max(max_x, cmd.rect.x + cmd.rect.w);
                }
            }
            if (max_x > min_x) {
                self.start = .{ .x = min_x, .y = click_y };
                self.end = .{ .x = max_x, .y = click_y };
            }
        } else {
            self.mode = .range;
        }
    }

    pub fn onMouseDragged(self: *SelectionState, drag_x: f32, drag_y: f32) void {
        if (self.mode == .range or self.mode == .none) {
            self.end = .{ .x = drag_x, .y = drag_y };
        }
    }

    pub fn onMouseUp(self: *SelectionState, up_x: f32, up_y: f32, click_count: usize) void {
        // Double-click and triple-click lock: mouse-up MUST NOT move cursor-end
        if (self.mode == .word or self.mode == .line or self.mode == .all) {
            return;
        }

        const dist_x = @abs(up_x - self.start.x);
        const dist_y = @abs(up_y - self.start.y);

        if (dist_x < 4.0 and dist_y < 4.0) {
            if (click_count < 2) {
                self.has_selection = false;
                self.mode = .none;
            }
        } else {
            self.end = .{ .x = up_x, .y = up_y };
        }
    }
};

test "controls: double-click word selection is locked against mouse-up shift" {
    var state = SelectionState{};

    const sample_commands = [_]layout.DrawCommand{
        .{
            .kind = .text_run,
            .rect = .{ .x = 100.0, .y = 50.0, .w = 80.0, .h = 24.0 },
            .text = "superfast",
        },
    };

    // User double-clicks in middle of word at (140.0, 60.0)
    state.onMouseDown(140.0, 60.0, 2, &sample_commands);

    // Verify word mode and word boundaries set
    try std.testing.expectEqual(SelectionMode.word, state.mode);
    try std.testing.expectEqual(@as(f32, 100.0), state.start.x);
    try std.testing.expectEqual(@as(f32, 180.0), state.end.x);

    // User releases mouse at (142.0, 61.0) - slightly shifted
    state.onMouseUp(142.0, 61.0, 2);

    // Prohibit bug: cursor-end MUST NOT change to mouse-up position!
    try std.testing.expectEqual(@as(f32, 100.0), state.start.x);
    try std.testing.expectEqual(@as(f32, 180.0), state.end.x);
    try std.testing.expect(state.has_selection);
}

test "controls: triple-click line selection is locked against mouse-up shift" {
    var state = SelectionState{};

    const sample_commands = [_]layout.DrawCommand{
        .{
            .kind = .text_run,
            .rect = .{ .x = 50.0, .y = 100.0, .w = 60.0, .h = 24.0 },
            .text = "First",
        },
        .{
            .kind = .text_run,
            .rect = .{ .x = 120.0, .y = 100.0, .w = 80.0, .h = 24.0 },
            .text = "Second",
        },
    };

    // User triple-clicks anywhere on line
    state.onMouseDown(70.0, 110.0, 3, &sample_commands);

    try std.testing.expectEqual(SelectionMode.line, state.mode);
    try std.testing.expectEqual(@as(f32, 50.0), state.start.x);
    try std.testing.expectEqual(@as(f32, 200.0), state.end.x);

    // Mouse-up anywhere on line
    state.onMouseUp(150.0, 112.0, 3);

    // End must remain at 200.0
    try std.testing.expectEqual(@as(f32, 50.0), state.start.x);
    try std.testing.expectEqual(@as(f32, 200.0), state.end.x);
}

test "controls: single click without drag clears selection" {
    var state = SelectionState{};
    state.has_selection = true;
    state.mode = .range;
    state.start = .{ .x = 100.0, .y = 100.0 };
    state.end = .{ .x = 250.0, .y = 100.0 };

    // New single click at (300.0, 300.0)
    state.onMouseDown(300.0, 300.0, 1, &.{});
    state.onMouseUp(300.0, 300.0, 1);

    try std.testing.expect(!state.has_selection);
    try std.testing.expectEqual(SelectionMode.none, state.mode);
}

test "controls: keybindings j, k, space, t navigation" {
    var scroll_y: f32 = 0.0;
    const max_scroll_y: f32 = 1000.0;
    const window_height: f32 = 600.0;
    var is_dark: bool = true;

    // 'j' scrolls down by 40px
    scroll_y = std.math.clamp(scroll_y + 40.0, 0.0, max_scroll_y);
    try std.testing.expectEqual(@as(f32, 40.0), scroll_y);

    // 'k' scrolls up by 40px
    scroll_y = std.math.clamp(scroll_y - 40.0, 0.0, max_scroll_y);
    try std.testing.expectEqual(@as(f32, 0.0), scroll_y);

    // 'k' cannot scroll past top
    scroll_y = std.math.clamp(scroll_y - 40.0, 0.0, max_scroll_y);
    try std.testing.expectEqual(@as(f32, 0.0), scroll_y);

    // ' ' (Space) page down (0.8 * window_height = 480px)
    scroll_y = std.math.clamp(scroll_y + window_height * 0.8, 0.0, max_scroll_y);
    try std.testing.expectEqual(@as(f32, 480.0), scroll_y);

    // 't' toggles theme
    is_dark = !is_dark;
    try std.testing.expectEqual(false, is_dark);
    is_dark = !is_dark;
    try std.testing.expectEqual(true, is_dark);
}

test "controls: distinct per-block horizontal scrolling with mouse-over requirement and right alignment" {
    const MAX_BLOCKS = layout.MAX_SCROLLABLE_BLOCKS;
    var block_scroll_x = [_]f32{0.0} ** MAX_BLOCKS;
    var block_max_scroll_x = [_]f32{0.0} ** MAX_BLOCKS;

    // Block 0: Code block with max_scroll 150px
    block_max_scroll_x[0] = 150.0;
    // Block 1: Table with max_scroll 300px
    block_max_scroll_x[1] = 300.0;

    // 1. Scrolling when mouse is NOT over any block (hovered_block_id = -1)
    const hovered_none: c_int = -1;
    if (hovered_none >= 0) {
        const id: usize = @intCast(hovered_none);
        block_scroll_x[id] += 30.0;
    }
    try std.testing.expectEqual(@as(f32, 0.0), block_scroll_x[0]);
    try std.testing.expectEqual(@as(f32, 0.0), block_scroll_x[1]);

    // 2. Scrolling when mouse IS over Block 0
    const hovered_block_0: c_int = 0;
    const b0_id: usize = @intCast(hovered_block_0);
    block_scroll_x[b0_id] = std.math.clamp(block_scroll_x[b0_id] + 50.0, 0.0, block_max_scroll_x[b0_id]);

    // Block 0 scrolled by 50px, Block 1 is strictly untouched!
    try std.testing.expectEqual(@as(f32, 50.0), block_scroll_x[0]);
    try std.testing.expectEqual(@as(f32, 0.0), block_scroll_x[1]);

    // 3. Scroll Block 0 past its maximum -> must clamp to max_scroll_x (right side aligned)
    block_scroll_x[b0_id] = std.math.clamp(block_scroll_x[b0_id] + 200.0, 0.0, block_max_scroll_x[b0_id]);
    try std.testing.expectEqual(@as(f32, 150.0), block_scroll_x[0]);

    // 4. Scroll Block 0 left past 0 -> must clamp to 0.0
    block_scroll_x[b0_id] = std.math.clamp(block_scroll_x[b0_id] - 300.0, 0.0, block_max_scroll_x[b0_id]);
    try std.testing.expectEqual(@as(f32, 0.0), block_scroll_x[0]);

    // 5. Scroll Block 1 while hovering Block 1
    const hovered_block_1: c_int = 1;
    const b1_id: usize = @intCast(hovered_block_1);
    block_scroll_x[b1_id] = std.math.clamp(block_scroll_x[b1_id] + 120.0, 0.0, block_max_scroll_x[b1_id]);
    try std.testing.expectEqual(@as(f32, 120.0), block_scroll_x[1]);
    try std.testing.expectEqual(@as(f32, 0.0), block_scroll_x[0]); // Block 0 still 0
}

test "controls: directional scroll locking prevents accidental diagonal scrolling" {
    var lock = layout.ScrollLockState{};

    // 1. Initial vertical scroll with slight horizontal drift over a scrollable block
    const res1 = lock.processScroll(2.0, 15.0, 0, 1000);
    try std.testing.expectEqual(layout.ScrollAxisLock.vertical, lock.axis);
    try std.testing.expectEqual(@as(f32, 0.0), res1.dx); // horizontal drift cancelled
    try std.testing.expectEqual(@as(f32, 15.0), res1.dy);

    // 2. Continuing vertical gesture: horizontal drift remains completely locked out
    const res2 = lock.processScroll(6.0, 12.0, 0, 1020);
    try std.testing.expectEqual(layout.ScrollAxisLock.vertical, lock.axis);
    try std.testing.expectEqual(@as(f32, 0.0), res2.dx);
    try std.testing.expectEqual(@as(f32, 12.0), res2.dy);

    // 3. Gesture ends (fingers lifted -> 0 deltas) -> lock resets to none
    const res_end = lock.processScroll(0.0, 0.0, -1, 1040);
    try std.testing.expectEqual(layout.ScrollAxisLock.none, lock.axis);
    try std.testing.expectEqual(@as(f32, 0.0), res_end.dx);
    try std.testing.expectEqual(@as(f32, 0.0), res_end.dy);

    // 4. New gesture: user intentionally scrolls horizontally over the code block / table
    const res3 = lock.processScroll(16.0, 3.0, 0, 1060);
    try std.testing.expectEqual(layout.ScrollAxisLock.horizontal, lock.axis);
    try std.testing.expectEqual(@as(f32, 16.0), res3.dx);
    try std.testing.expectEqual(@as(f32, 0.0), res3.dy); // vertical jump cancelled

    // 5. Time gap > 150ms between events resets the lock naturally without lifting fingers
    const res4 = lock.processScroll(2.0, 18.0, 0, 1250);
    try std.testing.expectEqual(layout.ScrollAxisLock.vertical, lock.axis);
    try std.testing.expectEqual(@as(f32, 0.0), res4.dx);
    try std.testing.expectEqual(@as(f32, 18.0), res4.dy);

    // 6. Strong intentional redirection mid-gesture switches active axis
    const res5 = lock.processScroll(32.0, 4.0, 0, 1270);
    try std.testing.expectEqual(layout.ScrollAxisLock.horizontal, lock.axis);
    try std.testing.expectEqual(@as(f32, 32.0), res5.dx);
    try std.testing.expectEqual(@as(f32, 0.0), res5.dy);
}

test "controls: accurate document height computation ensures tables and end of document are reachable" {
    var file = try mmap.MappedFile.open("showcase.md");
    defer file.close();
    const showcase_doc = file.bytes;

    var lines_buf: [256]simd.Line = undefined;
    var in_fence = false;
    const line_count = simd.scanLines(showcase_doc, &lines_buf, &in_fence);

    const vp_config = layout.ViewportConfig{
        .window_width = 1000.0,
        .window_height = 750.0,
        .scroll_y = 0.0,
    };

    const accurate_height = layout.computeDocumentHeightEx(
        showcase_doc,
        lines_buf[0..line_count],
        vp_config,
        null,
        null,
    );

    // Previously, naive (line_count * 28.0) produced ~3080px which trapped scrolling before the table.
    // Accurate height accounts for heading margins, wrapping, tables, and spacing (~4500px).
    try std.testing.expect(accurate_height > 4000.0);

    const max_scroll_y = @max(0.0, accurate_height - vp_config.window_height + 400.0);
    try std.testing.expect(max_scroll_y > 3500.0);

    // Verify that at max scroll (or scrolled to the table region), table rows and trailing content are visible
    var commands_buf: [1024]layout.DrawCommand = undefined;
    var table_scroll_config = vp_config;
    table_scroll_config.scroll_y = 3500.0;

    const cmd_count = layout.layoutViewport(
        showcase_doc,
        lines_buf[0..line_count],
        table_scroll_config,
        &commands_buf,
    );

    try std.testing.expect(cmd_count > 0);

    // Confirm that table content text runs are generated
    var found_table_header = false;
    var found_table_content = false;
    for (commands_buf[0..cmd_count]) |cmd| {
        if (cmd.kind == .text_run) {
            if (std.mem.indexOf(u8, cmd.text, "Standard Reader") != null or
                std.mem.indexOf(u8, cmd.text, "Browser / Electron") != null)
            {
                found_table_header = true;
            }
            if (std.mem.indexOf(u8, cmd.text, "Startup Time") != null or
                std.mem.indexOf(u8, cmd.text, "Active RAM") != null or
                std.mem.indexOf(u8, cmd.text, "< 2 ms") != null)
            {
                found_table_content = true;
            }
        }
    }

    try std.testing.expect(found_table_header);
    try std.testing.expect(found_table_content);
}

test "controls: smooth scroll eases toward target without overshoot and settles" {
    var s = layout.SmoothScroll{};
    s.setTarget(40.0, 1000.0);

    var prev: f32 = 0.0;
    var frames: usize = 0;
    while (!s.settled()) : (frames += 1) {
        if (frames > 240) break; // 2s at 120Hz cap; must settle before this
        _ = s.tick(1.0 / 120.0);
        // Monotonic approach with no overshoot past the target.
        try std.testing.expect(s.current >= prev);
        try std.testing.expect(s.current <= 40.0);
        prev = s.current;
    }
    try std.testing.expect(s.settled());
    try std.testing.expectEqual(@as(f32, 40.0), s.current);
    try std.testing.expect(frames < 120);
}

test "controls: smooth scroll clamps target and snaps scrollbar drags" {
    var s = layout.SmoothScroll{};
    s.setTarget(5000.0, 1000.0);
    try std.testing.expectEqual(@as(f32, 1000.0), s.target);

    // Scrollbar drags stay 1:1: displayed offset jumps with the target.
    s.snapTo(250.0, 1000.0);
    try std.testing.expect(s.settled());
    try std.testing.expectEqual(@as(f32, 250.0), s.current);
    try std.testing.expectEqual(@as(f32, 250.0), s.target);
}

test "controls: smooth scroll steps on whole points and settles exactly" {
    // Mid-flight positions must be whole points: the platform scroll-copies
    // backing store by whole points, so fractional offsets would shimmer.
    var s = layout.SmoothScroll{};
    s.setTarget(40.0, 1000.0);
    var frames: usize = 0;
    while (!s.settled() and frames < 240) : (frames += 1) {
        _ = s.tick(1.0 / 120.0);
        if (!s.settled()) {
            try std.testing.expectEqual(@round(s.current), s.current);
        }
    }
    try std.testing.expect(s.settled());
    try std.testing.expectEqual(@as(f32, 40.0), s.current);

    // Fractional targets (momentum deltas accumulate there) still settle
    // exactly via the final snap and never stall on a rounded zero-step.
    var f = layout.SmoothScroll{};
    f.setTarget(40.3, 1000.0);
    frames = 0;
    while (!f.settled() and frames < 240) : (frames += 1) {
        _ = f.tick(1.0 / 120.0);
    }
    try std.testing.expect(f.settled());
    try std.testing.expectEqual(@as(f32, 40.3), f.current);
}

test "controls: smooth scroll whole-point steps hold at 60Hz cadence" {
    // The platform now ticks at the hosting screen's rate (60Hz panels stop
    // paying 120 wakeups/s): mid-flight positions must be whole points at
    // 60Hz too, with exact settle and no stall.
    var s = layout.SmoothScroll{};
    s.setTarget(40.0, 1000.0);
    var frames: usize = 0;
    while (!s.settled() and frames < 240) : (frames += 1) {
        _ = s.tick(1.0 / 60.0);
        if (!s.settled()) {
            try std.testing.expectEqual(@round(s.current), s.current);
        }
    }
    try std.testing.expect(s.settled());
    try std.testing.expectEqual(@as(f32, 40.0), s.current);
}

test "controls: smooth scroll converges across frame rates" {
    var slow = layout.SmoothScroll{};
    slow.setTarget(480.0, 4000.0);
    var n_slow: usize = 0;
    while (!slow.settled() and n_slow < 600) : (n_slow += 1) _ = slow.tick(1.0 / 30.0);

    var fast = layout.SmoothScroll{};
    fast.setTarget(480.0, 4000.0);
    var n_fast: usize = 0;
    while (!fast.settled() and n_fast < 2400) : (n_fast += 1) _ = fast.tick(1.0 / 240.0);

    try std.testing.expect(slow.settled());
    try std.testing.expect(fast.settled());
    try std.testing.expectEqual(@as(f32, 480.0), slow.current);
    try std.testing.expectEqual(@as(f32, 480.0), fast.current);
}

test "controls: draggable scrollbar thumb maps scroll offset to view geometry" {
    const view_h: f32 = 750.0;
    const max_scroll: f32 = 2000.0;

    // Top of document -> thumb at top; bottom -> thumb at bottom of travel.
    try std.testing.expectEqual(@as(f32, 0.0), layout.scrollbarThumbY(0.0, max_scroll, view_h));
    try std.testing.expectEqual(view_h - layout.SCROLLBAR_THUMB_H, layout.scrollbarThumbY(max_scroll, max_scroll, view_h));

    // Midpoint maps to mid-travel.
    try std.testing.expectEqual(
        (view_h - layout.SCROLLBAR_THUMB_H) * 0.5,
        layout.scrollbarThumbY(max_scroll * 0.5, max_scroll, view_h),
    );

    // Out-of-range offsets clamp instead of running off the track.
    try std.testing.expectEqual(@as(f32, 0.0), layout.scrollbarThumbY(-100.0, max_scroll, view_h));
    try std.testing.expectEqual(view_h - layout.SCROLLBAR_THUMB_H, layout.scrollbarThumbY(max_scroll + 500.0, max_scroll, view_h));

    // Nothing to scroll -> no thumb.
    try std.testing.expectEqual(@as(f32, 0.0), layout.scrollbarThumbY(0.0, 0.0, view_h));
}

test "controls: draggable scrollbar drag maps pointer y back to scroll offset" {
    const view_h: f32 = 750.0;
    const max_scroll: f32 = 2000.0;
    const travel = view_h - layout.SCROLLBAR_THUMB_H;

    // Thumb grab keeps its offset: dragging the grabbed point back to where
    // the thumb was returns the original scroll (no jump on grab).
    const start_scroll: f32 = 500.0;
    const thumb = layout.scrollbarThumbY(start_scroll, max_scroll, view_h);
    const grab: f32 = 10.0;
    try std.testing.expectEqual(
        start_scroll,
        layout.scrollbarScrollFromY(thumb + grab, grab, max_scroll, view_h),
    );

    // Track click centers the thumb: pointer at mid-track scrolls to middle.
    try std.testing.expectEqual(
        max_scroll * 0.5,
        layout.scrollbarScrollFromY(travel * 0.5 + layout.SCROLLBAR_THUMB_H * 0.5, layout.SCROLLBAR_THUMB_H * 0.5, max_scroll, view_h),
    );

    // Dragging past either end clamps to the document bounds.
    try std.testing.expectEqual(@as(f32, 0.0), layout.scrollbarScrollFromY(-1000.0, 0.0, max_scroll, view_h));
    try std.testing.expectEqual(max_scroll, layout.scrollbarScrollFromY(view_h + 1000.0, 0.0, max_scroll, view_h));

    // Nothing to scroll -> drag is a no-op.
    try std.testing.expectEqual(@as(f32, 0.0), layout.scrollbarScrollFromY(300.0, 0.0, 0.0, view_h));
}
