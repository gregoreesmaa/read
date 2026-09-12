const std = @import("std");
const layout = @import("../layout/viewport.zig");
const simd = @import("hot");
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

/// Word classification for double-click selection (mirrored by
/// word_char_byte in src/platform/macos.m — keep the two in sync).
/// ASCII letters/digits plus `_` and `'`; every non-ASCII byte (>= 0x80,
/// i.e. UTF-8 leads and continuations) counts as a word byte so
/// multibyte sequences are never split. No tables: O(n) scan, zero heap.
pub fn isWordByte(b: u8) bool {
    if (b >= 0x80) return true;
    return (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or
        (b >= '0' and b <= '9') or b == '_' or b == '\'';
}

pub fn wordStart(text: []const u8, idx: usize) usize {
    var i = @min(idx, text.len);
    while (i > 0 and isWordByte(text[i - 1])) : (i -= 1) {}
    return i;
}

pub fn wordEnd(text: []const u8, idx: usize) usize {
    var i = @min(idx, text.len);
    while (i < text.len and isWordByte(text[i])) : (i += 1) {}
    return i;
}

/// Proportional byte->x map for the simulation (the platform uses
/// CoreText-precise get_x_for_char_index; the contract pinned here is
/// anchor stability + snap-to-boundary semantics, not pixel mapping).
fn xForByte(rect: layout.Rect, text_len: usize, byte_idx: usize) f32 {
    if (text_len == 0) return rect.x;
    return rect.x + rect.w * @as(f32, @floatFromInt(byte_idx)) / @as(f32, @floatFromInt(text_len));
}

fn byteAtX(rect: layout.Rect, text_len: usize, x: f32) usize {
    if (rect.w <= 0.0 or text_len == 0) return 0;
    const frac = std.math.clamp((x - rect.x) / rect.w, 0.0, 1.0);
    return @intFromFloat(frac * @as(f32, @floatFromInt(text_len)));
}

pub const SelectionState = struct {
    has_selection: bool = false,
    mode: SelectionMode = .none,
    start: Point = .{},
    end: Point = .{},
    anchor: Point = .{},

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
        self.anchor = self.start;

        if (click_count == 2) {
            self.mode = .word;
            // Snap to the Unicode word under the cursor (not the whole run).
            for (records) |cmd| {
                if (cmd.kind == .text_run and
                    click_x >= cmd.rect.x and click_x <= cmd.rect.x + cmd.rect.w and
                    click_y >= cmd.rect.y and click_y <= cmd.rect.y + cmd.rect.h)
                {
                    const idx = byteAtX(cmd.rect, cmd.text.len, click_x);
                    const ws = wordStart(cmd.text, idx);
                    const we = wordEnd(cmd.text, idx);
                    const mid_y = cmd.rect.y + cmd.rect.h * 0.5;
                    if (we > ws) {
                        self.start = .{ .x = xForByte(cmd.rect, cmd.text.len, ws), .y = mid_y };
                        self.end = .{ .x = xForByte(cmd.rect, cmd.text.len, we), .y = mid_y };
                    } else {
                        // Whitespace/punctuation click: keep the run snap.
                        self.start = .{ .x = cmd.rect.x, .y = mid_y };
                        self.end = .{ .x = cmd.rect.x + cmd.rect.w, .y = mid_y };
                    }
                    self.anchor = self.start;
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

    pub fn onMouseDragged(
        self: *SelectionState,
        drag_x: f32,
        drag_y: f32,
        records: []const layout.DrawCommand,
    ) void {
        switch (self.mode) {
            .range, .none => {
                self.end = .{ .x = drag_x, .y = drag_y };
            },
            // Word-wise extension: the anchor never moves; the free end
            // snaps to the word boundary under the cursor (word start when
            // dragging back past the anchor, word end when dragging on).
            .word => {
                for (records) |cmd| {
                    if (cmd.kind == .text_run and
                        drag_x >= cmd.rect.x and drag_x <= cmd.rect.x + cmd.rect.w and
                        drag_y >= cmd.rect.y and drag_y <= cmd.rect.y + cmd.rect.h)
                    {
                        const idx = byteAtX(cmd.rect, cmd.text.len, drag_x);
                        const mid_y = cmd.rect.y + cmd.rect.h * 0.5;
                        if (drag_x < self.anchor.x) {
                            const ws = wordStart(cmd.text, idx);
                            self.end = .{ .x = xForByte(cmd.rect, cmd.text.len, ws), .y = mid_y };
                        } else {
                            const we = wordEnd(cmd.text, idx);
                            const ws = wordStart(cmd.text, idx);
                            if (we > ws) {
                                self.end = .{ .x = xForByte(cmd.rect, cmd.text.len, we), .y = mid_y };
                            }
                        }
                        break;
                    }
                }
            },
            // Line-wise extension: the free end snaps to the row band under
            // the cursor; dragging above the anchor re-seats the start.
            .line => {
                var min_x: f32 = 9999.0;
                var max_x: f32 = -9999.0;
                for (records) |cmd| {
                    if (cmd.kind == .text_run and @abs(cmd.rect.y + cmd.rect.h * 0.5 - drag_y) < 16.0) {
                        min_x = @min(min_x, cmd.rect.x);
                        max_x = @max(max_x, cmd.rect.x + cmd.rect.w);
                    }
                }
                if (max_x > min_x) {
                    if (drag_y < self.anchor.y) {
                        self.start = .{ .x = min_x, .y = drag_y };
                    } else {
                        self.end = .{ .x = max_x, .y = drag_y };
                    }
                }
            },
            // Select-all is fully locked: drags change nothing.
            .all => {},
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

test "controls: word boundaries keep UTF-8 sequences whole" {
    try std.testing.expect(isWordByte('a'));
    try std.testing.expect(isWordByte('Z'));
    try std.testing.expect(isWordByte('7'));
    try std.testing.expect(isWordByte('_'));
    try std.testing.expect(isWordByte('\''));
    try std.testing.expect(!isWordByte(' '));
    try std.testing.expect(!isWordByte(','));
    try std.testing.expect(!isWordByte('-'));
    try std.testing.expect(!isWordByte('.'));
    // Every non-ASCII byte is a word byte: multibyte runs never split.
    try std.testing.expect(isWordByte(0xC3));
    try std.testing.expect(isWordByte(0xAF));

    // "naïve café": ï (2B) and é (2B) stay inside their words.
    const text = "naïve café";
    try std.testing.expectEqual(@as(usize, 0), wordStart(text, 2));
    try std.testing.expectEqual(@as(usize, 6), wordEnd(text, 2));
    try std.testing.expectEqual(@as(usize, 7), wordStart(text, 9));
    try std.testing.expectEqual(@as(usize, text.len), wordEnd(text, 9));
    // Comma splits ASCII words.
    const csv = "hello,world";
    try std.testing.expectEqual(@as(usize, 5), wordEnd(csv, 1));
    try std.testing.expectEqual(@as(usize, 6), wordStart(csv, 8));
}

test "controls: double-click snaps to word, drag extends word-wise with locked anchor" {
    var state = SelectionState{};

    const sample_commands = [_]layout.DrawCommand{
        .{
            .kind = .text_run,
            .rect = .{ .x = 100.0, .y = 50.0, .w = 220.0, .h = 24.0 },
            .text = "hello brave world",
        },
    };

    // Double-click inside "brave" (bytes 6..11): x=205 maps to byte 8.
    state.onMouseDown(205.0, 60.0, 2, &sample_commands);
    try std.testing.expectEqual(SelectionMode.word, state.mode);
    const anchor_x = state.start.x;
    try std.testing.expect(state.end.x > state.start.x);
    // "brave" spans bytes 6..11 of 17.
    try std.testing.expectEqual(@as(f32, 100.0 + 220.0 * 6.0 / 17.0), state.start.x);
    try std.testing.expectEqual(@as(f32, 100.0 + 220.0 * 11.0 / 17.0), state.end.x);

    // Drag on into "world" (bytes 12..17): end snaps to the word end,
    // the anchor never moves.
    state.onMouseDragged(300.0, 60.0, &sample_commands);
    try std.testing.expectEqual(anchor_x, state.start.x);
    try std.testing.expectEqual(@as(f32, 100.0 + 220.0), state.end.x);

    // Release: the mouseUp-overwrite lock still holds after a word drag.
    state.onMouseUp(300.0, 60.0, 2);
    try std.testing.expectEqual(anchor_x, state.start.x);
    try std.testing.expectEqual(@as(f32, 100.0 + 220.0), state.end.x);
    try std.testing.expect(state.has_selection);
}

test "controls: triple-click drag extends line-wise up and down" {
    var state = SelectionState{};

    const sample_commands = [_]layout.DrawCommand{
        .{ .kind = .text_run, .rect = .{ .x = 60.0, .y = 60.0, .w = 70.0, .h = 24.0 }, .text = "Top row" },
        .{ .kind = .text_run, .rect = .{ .x = 50.0, .y = 100.0, .w = 60.0, .h = 24.0 }, .text = "First" },
        .{ .kind = .text_run, .rect = .{ .x = 120.0, .y = 100.0, .w = 80.0, .h = 24.0 }, .text = "Second" },
        .{ .kind = .text_run, .rect = .{ .x = 50.0, .y = 140.0, .w = 90.0, .h = 24.0 }, .text = "Third row" },
    };

    state.onMouseDown(70.0, 110.0, 3, &sample_commands);
    try std.testing.expectEqual(SelectionMode.line, state.mode);
    try std.testing.expectEqual(@as(f32, 50.0), state.start.x);
    try std.testing.expectEqual(@as(f32, 200.0), state.end.x);

    // Drag down to the next row: end snaps to that row's band.
    state.onMouseDragged(80.0, 150.0, &sample_commands);
    try std.testing.expectEqual(@as(f32, 50.0), state.start.x);
    try std.testing.expectEqual(@as(f32, 140.0), state.end.x);

    // Drag above the anchor row: start re-seats to the top band.
    state.onMouseDragged(70.0, 72.0, &sample_commands);
    try std.testing.expectEqual(@as(f32, 60.0), state.start.x);
    try std.testing.expectEqual(@as(f32, 140.0), state.end.x);

    // Drag over empty space (no row band near y=10): selection unchanged.
    state.onMouseDragged(70.0, 10.0, &sample_commands);
    try std.testing.expectEqual(@as(f32, 60.0), state.start.x);
    try std.testing.expectEqual(@as(f32, 140.0), state.end.x);

    // Release anywhere: line lock holds.
    state.onMouseUp(80.0, 150.0, 3);
    try std.testing.expectEqual(@as(f32, 60.0), state.start.x);
    try std.testing.expectEqual(@as(f32, 140.0), state.end.x);
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

/// Native editing validation contract (mirrored by
/// edit_action_available + validateMenuItem: in src/platform/macos.m).
/// Copy/Look Up/Search need a live selection and refuse while Secure
/// Input is active; Select All is always available. Pure, zero heap.
pub const EditPolicy = struct {
    pub fn selectionActionEnabled(has_selection: bool, select_all: bool, secure_input: bool) bool {
        return (has_selection or select_all) and !secure_input;
    }

    pub fn copyEnabled(has_selection: bool, select_all: bool, secure_input: bool) bool {
        return selectionActionEnabled(has_selection, select_all, secure_input);
    }

    pub fn lookupEnabled(has_selection: bool, select_all: bool, secure_input: bool) bool {
        return selectionActionEnabled(has_selection, select_all, secure_input);
    }

    pub fn searchEnabled(has_selection: bool, select_all: bool, secure_input: bool) bool {
        return selectionActionEnabled(has_selection, select_all, secure_input);
    }

    pub fn selectAllEnabled() bool {
        return true;
    }
};

test "controls: editing validation disables copy without selection or under secure input" {
    // No selection, no select-all: everything selection-scoped is off.
    try std.testing.expect(!EditPolicy.copyEnabled(false, false, false));
    try std.testing.expect(!EditPolicy.lookupEnabled(false, false, false));
    try std.testing.expect(!EditPolicy.searchEnabled(false, false, false));

    // Live range selection: on.
    try std.testing.expect(EditPolicy.copyEnabled(true, false, false));
    try std.testing.expect(EditPolicy.lookupEnabled(true, false, false));
    try std.testing.expect(EditPolicy.searchEnabled(true, false, false));

    // Select-all counts as a selection.
    try std.testing.expect(EditPolicy.copyEnabled(false, true, false));

    // Secure Input (a password field elsewhere is focused): all
    // selection-scoped actions refuse, even with a selection.
    try std.testing.expect(!EditPolicy.copyEnabled(true, false, true));
    try std.testing.expect(!EditPolicy.lookupEnabled(false, true, true));
    try std.testing.expect(!EditPolicy.searchEnabled(true, true, true));

    // Select All never disables.
    try std.testing.expect(EditPolicy.selectAllEnabled());
}

test "controls: text scale classes (issue #315: user zoom removed)" {
    // Identity: default class == the historical 17pt base, so screenshots
    // stay pixel-identical; with no user zoom there is nothing to persist.
    var ts = layout.TextScale{};
    try std.testing.expectEqual(@as(f32, 17.0), ts.effectiveBase());

    // System-size ratio snaps to discrete classes.
    try std.testing.expectEqual(@as(u3, 1), layout.TextScale.classForRatio(1.0));
    try std.testing.expectEqual(@as(u3, 0), layout.TextScale.classForRatio(0.85));
    try std.testing.expectEqual(@as(u3, 2), layout.TextScale.classForRatio(1.15));
    try std.testing.expectEqual(@as(u3, 4), layout.TextScale.classForRatio(2.0));
    ts.class = 2;
    try std.testing.expectEqual(@as(f32, 17.0 * 1.15), ts.effectiveBase());
    // Remaining multipliers in f32 epsilon: the comptime product rounds
    // differently than the runtime f32 multiply in the last ulp.
    ts.class = 0;
    try std.testing.expectApproxEqAbs(@as(f32, 17.0 * 0.85), ts.effectiveBase(), 1e-4);
    ts.class = 4;
    try std.testing.expectApproxEqAbs(@as(f32, 17.0 * 1.50), ts.effectiveBase(), 1e-4);
}

test "controls: reduced motion lands scroll inputs synchronously" {
    // Reduced: wheel and precise inputs snap, no glide, no timer needed.
    var s = layout.MotionPolicy.applyVertical(0.0, 100.0, -40.0, false, 1000.0, true);
    try std.testing.expectEqual(@as(f32, 140.0), s.current);
    try std.testing.expectEqual(@as(f32, 140.0), s.target);
    try std.testing.expect(s.settled());
    s = layout.MotionPolicy.applyVertical(500.0, 500.0, 30.0, true, 1000.0, true);
    try std.testing.expectEqual(@as(f32, 470.0), s.current);
    try std.testing.expect(s.settled());
    // Reduced still clamps to the document.
    s = layout.MotionPolicy.applyVertical(0.0, 990.0, -50.0, false, 1000.0, true);
    try std.testing.expectEqual(@as(f32, 1000.0), s.current);

    // Normal motion delegates to the existing routing untouched.
    const wheel = layout.MotionPolicy.applyVertical(100.0, 100.0, -40.0, false, 1000.0, false);
    const direct = layout.SmoothScroll.applyScrollDelta(100.0, 100.0, -40.0, false, 1000.0);
    try std.testing.expectEqual(direct.target, wheel.target);
    try std.testing.expectEqual(direct.current, wheel.current);
}

test "controls: gesture filter passes precise 1:1, quantizes wheel jitter" {
    var f = layout.GestureFilter{};

    // Precise devices (trackpad / Magic Mouse): bit-exact, even sub-point.
    const p = f.filter(0.1, -0.3, true);
    try std.testing.expectEqual(@as(f32, 0.1), p.dx);
    try std.testing.expectEqual(@as(f32, -0.3), p.dy);

    // Classic wheel jitter accumulates without loss and emits whole points.
    const a = f.filter(0.3, 0.3, false);
    try std.testing.expectEqual(@as(f32, 0.0), a.dx);
    try std.testing.expectEqual(@as(f32, 0.0), a.dy);
    const b = f.filter(0.4, 0.4, false);
    try std.testing.expectEqual(@as(f32, 0.0), b.dx);
    try std.testing.expectEqual(@as(f32, 0.0), b.dy);
    const c = f.filter(0.3, 0.5, false);
    try std.testing.expectEqual(@as(f32, 1.0), c.dx); // 0.3+0.4+0.3
    try std.testing.expectEqual(@as(f32, 1.0), c.dy); // 0.3+0.4+0.5
    // Residue carries: 0.0 x, 0.2 y left.
    const d = f.filter(-2.7, -0.2, false);
    try std.testing.expectEqual(@as(f32, -2.0), d.dx);
    try std.testing.expectEqual(@as(f32, 0.0), d.dy);

    // Large notches pass through (quantized, residue kept).
    const e = f.filter(0.0, 40.0, false);
    try std.testing.expectEqual(@as(f32, 40.0), e.dy);
}

test "controls: precise input mid-glide cancels the glide from the displayed offset" {
    // A wheel glide is in flight toward 500 while 300 is displayed.
    const gliding = layout.SmoothScroll{ .current = 300.0, .target = 500.0 };
    // A precise trackpad delta snaps 1:1 from DISPLAYED (300), cancelling
    // the in-flight glide with no teleport: inertia stays Finder-like.
    const s = layout.SmoothScroll.applyScrollDelta(gliding.target, gliding.current, -20.0, true, 1000.0);
    try std.testing.expectEqual(@as(f32, 320.0), s.current);
    try std.testing.expectEqual(@as(f32, 320.0), s.target);
    try std.testing.expect(s.settled());
}

test "controls: edge spring absorbs bound residual and decays without overshoot" {
    var e = layout.EdgeSpring{};

    // Pushed past the top (over<0): content shifts down, capped at 48px.
    e.absorb(-10.0);
    try std.testing.expect(e.active());
    try std.testing.expectEqual(@as(f32, 3.5), e.overshoot);
    for (0..100) |_| e.absorb(-100.0);
    try std.testing.expectEqual(@as(f32, 48.0), e.overshoot);

    // Pushed past the bottom: sign flips, still capped.
    var b = layout.EdgeSpring{};
    b.absorb(200.0);
    try std.testing.expectEqual(@as(f32, -48.0), b.overshoot);

    // Decay is monotonic toward zero with no overshoot past zero, and
    // settles exactly (timer parks).
    var prev: f32 = 48.0;
    var frames: usize = 0;
    while (!e.tick(1.0 / 120.0)) : (frames += 1) {
        if (frames > 1200) break;
        try std.testing.expect(e.overshoot >= 0.0);
        try std.testing.expect(e.overshoot <= prev);
        prev = e.overshoot;
    }
    try std.testing.expect(!e.active());
    try std.testing.expect(e.tick(1.0 / 120.0));
}

test "controls: no zoom affordance remains (issue #315)" {
    // PinchState is gone: pinch input has nowhere to accumulate, so the
    // declaration itself must not resolve. TextScale carries no zoom
    // factor: only the five discrete size classes scale the base.
    try std.testing.expect(!@hasDecl(layout, "PinchState"));
    try std.testing.expect(!@hasField(layout.TextScale, "zoom"));
    var ts = layout.TextScale{};
    ts.class = 3;
    try std.testing.expectApproxEqAbs(@as(f32, 17.0 * 1.30), ts.effectiveBase(), 1e-4);
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
    var in_fence: simd.FenceState = .{};
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

// Image size stubs: async load pending (0,0 -> 240px fallback box) vs a
// resolved 400x400 animated GIF (e.g. assets/images/sample_animated.gif).
fn gifSizeLoading(url: [*]const u8, url_len: c_int, out_w: *f32, out_h: *f32) callconv(.c) void {
    _ = url;
    _ = url_len;
    out_w.* = 0.0;
    out_h.* = 0.0;
}

fn gifSizeLoaded(url: [*]const u8, url_len: c_int, out_w: *f32, out_h: *f32) callconv(.c) void {
    _ = url;
    _ = url_len;
    out_w.* = 400.0;
    out_h.* = 400.0;
}

fn trailingY(doc: []const u8, size_fn: *const fn ([*]const u8, c_int, *f32, *f32) callconv(.c) void) !f32 {
    var lines_buf: [32]simd.Line = undefined;
    var in_fence: simd.FenceState = .{};
    const n = simd.scanLines(doc, &lines_buf, &in_fence);
    var commands_buf: [256]layout.DrawCommand = undefined;
    const count = layout.layoutViewport(
        doc,
        lines_buf[0..n],
        .{
            .window_width = 1000.0,
            .window_height = 750.0,
            .scroll_y = 0.0,
            .image_size_fn = size_fn,
        },
        &commands_buf,
    );
    for (commands_buf[0..count]) |cmd| {
        if (cmd.kind == .text_run and std.mem.indexOf(u8, cmd.text, "Trailing") != null) {
            return cmd.rect.y;
        }
    }
    return error.TrailingNotFound;
}

test "controls: async gif arrival shifts content below under fixed scroll" {
    // Reproduces the live jump: while the GIF decodes, layout reserves the
    // 240px fallback; when natural size (400x400) lands, everything below
    // moves down under a stationary scroll offset.
    const doc =
        \\# Title
        \\![Earth](assets/images/sample_animated.gif)
        \\Trailing below the image.
    ;
    const y_loading = try trailingY(doc, gifSizeLoading);
    const y_loaded = try trailingY(doc, gifSizeLoaded);
    try std.testing.expectEqual(@as(f32, 160.0), y_loaded - y_loading);
}

test "controls: image arrival anchors scroll by above-viewport deltas" {
    // Fix for the live jump: when async natural sizes land, the scroll
    // offset must absorb the height deltas of images fully above the
    // viewport top so on-screen content stays pixel-locked.
    const boxes = [_]layout.ImageBox{
        .{ .doc_y = 100.0, .h = 240.0 }, // fully above: 240 -> 400
        .{ .doc_y = 400.0, .h = 240.0 }, // straddles top: contributes nothing
        .{ .doc_y = 900.0, .h = 240.0 }, // below: contributes nothing
    };
    const new_h = [_]f32{ 400.0, 400.0, 400.0 };
    try std.testing.expectEqual(@as(f32, 160.0), layout.imageArrivalShift(500.0, &boxes, &new_h));

    // Stacked arrivals compose: each box is tested against the running shift.
    const stacked = [_]layout.ImageBox{
        .{ .doc_y = 100.0, .h = 240.0 },
        .{ .doc_y = 300.0, .h = 240.0 }, // 300+160+240 = 700 <= 700: above
    };
    const stacked_h = [_]f32{ 400.0, 300.0 };
    try std.testing.expectEqual(@as(f32, 220.0), layout.imageArrivalShift(700.0, &stacked, &stacked_h));

    // Still loading (new == old) contributes nothing.
    const pending_h = [_]f32{240.0};
    try std.testing.expectEqual(@as(f32, 0.0), layout.imageArrivalShift(500.0, boxes[0..1], &pending_h));
}

fn layoutAt(doc: []const u8, scroll: f32, size_fn: *const fn ([*]const u8, c_int, *f32, *f32) callconv(.c) void, out: []layout.DrawCommand) usize {
    var lines_buf: [32]simd.Line = undefined;
    var in_fence: simd.FenceState = .{};
    const n = simd.scanLines(doc, &lines_buf, &in_fence);
    return layout.layoutViewport(
        doc,
        lines_buf[0..n],
        .{
            .window_width = 1000.0,
            .window_height = 750.0,
            .scroll_y = scroll,
            .image_size_fn = size_fn,
        },
        out,
    );
}

test "controls: anchored arrival keeps below-content pixel-locked" {
    // End-to-end: the shift computed from laid-out boxes exactly cancels
    // the content movement measured across the loading->loaded transition,
    // so the live handler (shift + snap) leaves the viewport stable.
    const doc =
        \\# Title
        \\![Earth](assets/images/sample_animated.gif)
        \\Filler one for document height.
        \\Filler two for document height.
        \\Filler three for document height.
        \\Filler four for document height.
        \\Filler five for document height.
        \\Filler six for document height.
        \\Filler seven for document height.
        \\Filler eight for document height.
        \\Filler nine for document height.
        \\Filler ten for document height.
        \\Trailing below the image.
    ;
    // Image box in document coords (scroll 0: view == document).
    var cmds0: [256]layout.DrawCommand = undefined;
    const n0 = layoutAt(doc, 0.0, gifSizeLoading, &cmds0);
    var img_y: f32 = -1.0;
    var img_h: f32 = -1.0;
    for (cmds0[0..n0]) |cmd| {
        if (cmd.kind == .image) {
            img_y = cmd.rect.y;
            img_h = cmd.rect.h;
        }
    }
    try std.testing.expect(img_y >= 0.0);

    const scroll: f32 = 600.0;
    try std.testing.expect(img_y + img_h <= scroll); // image fully above
    var cmds_before: [256]layout.DrawCommand = undefined;
    const n_before = layoutAt(doc, scroll, gifSizeLoading, &cmds_before);
    var view_before: f32 = -1.0;
    for (cmds_before[0..n_before]) |cmd| {
        if (cmd.kind == .text_run and std.mem.indexOf(u8, cmd.text, "Trailing") != null) {
            view_before = cmd.rect.y;
        }
    }
    try std.testing.expect(view_before >= 0.0);

    var cmds_loaded: [256]layout.DrawCommand = undefined;
    const n_loaded = layoutAt(doc, 0.0, gifSizeLoaded, &cmds_loaded);
    var new_h: f32 = -1.0;
    for (cmds_loaded[0..n_loaded]) |cmd| {
        if (cmd.kind == .image) new_h = cmd.rect.h;
    }
    try std.testing.expect(new_h > 0.0);

    const boxes = [_]layout.ImageBox{.{ .doc_y = img_y, .h = img_h }};
    const heights = [_]f32{new_h};
    const shift = layout.imageArrivalShift(scroll, &boxes, &heights);
    try std.testing.expect(shift > 0.0);

    var cmds_after: [256]layout.DrawCommand = undefined;
    const n_after = layoutAt(doc, scroll + shift, gifSizeLoaded, &cmds_after);
    var view_after: f32 = -1.0;
    for (cmds_after[0..n_after]) |cmd| {
        if (cmd.kind == .text_run and std.mem.indexOf(u8, cmd.text, "Trailing") != null) {
            view_after = cmd.rect.y;
        }
    }
    try std.testing.expect(view_after >= 0.0);
    // Exact f32 equality is too strict: shifting document math by +160 then
    // re-subtracting the scroll rounds 1 ulp differently (~6e-5px at these
    // magnitudes). 0.01px tolerance is 1/100th of a pixel — invisible —
    // while a real anchoring miss would read ~160px.
    try std.testing.expect(@abs(view_before - view_after) < 0.01);
}

fn layoutDoc(doc: []const u8, out: []layout.DrawCommand) usize {
    var lines_buf: [64]simd.Line = undefined;
    var in_fence: simd.FenceState = .{};
    const n = simd.scanLines(doc, &lines_buf, &in_fence);
    return layout.layoutViewport(doc, lines_buf[0..n], .{
        .window_width = 1000.0,
        .window_height = 750.0,
        .scroll_y = 0.0,
    }, out);
}

test "controls: rtl paragraph right-aligns, ltr paragraph stays left (issue #50)" {
    // 1000px window, 600px column: content spans x in [200, 800].
    var cmds: [64]layout.DrawCommand = undefined;
    const n_rtl = layoutDoc("שלום עולם\n", &cmds);
    try std.testing.expect(n_rtl > 0);
    // Per visual row, the row's first word ends exactly at the right
    // column edge (later words extend left); nothing escapes the column.
    var row_y: [8]f32 = [_]f32{-1} ** 8;
    var row_right: [8]f32 = [_]f32{0} ** 8;
    var row_count: usize = 0;
    var rtl_runs: usize = 0;
    for (cmds[0..n_rtl]) |c| {
        if (c.kind != .text_run) continue;
        rtl_runs += 1;
        try std.testing.expect(c.rect.x >= 200.0 - 0.05);
        try std.testing.expect(c.rect.x + c.rect.w <= 800.0 + 0.05);
        var ri: usize = 0;
        while (ri < row_count and @abs(row_y[ri] - c.rect.y) > 0.01) : (ri += 1) {}
        if (ri == row_count and row_count < row_y.len) {
            row_y[row_count] = c.rect.y;
            row_count += 1;
        }
        if (ri < row_right.len) row_right[ri] = @max(row_right[ri], c.rect.x + c.rect.w);
    }
    try std.testing.expect(rtl_runs == 2);
    try std.testing.expect(row_count == 1);
    for (row_right[0..row_count]) |r| {
        try std.testing.expectApproxEqAbs(@as(f32, 800.0), r, 0.05);
    }

    const n_ltr = layoutDoc("Hello world\n", &cmds);
    var ltr_runs: usize = 0;
    var min_x: f32 = 1e9;
    for (cmds[0..n_ltr]) |c| {
        if (c.kind != .text_run) continue;
        ltr_runs += 1;
        min_x = @min(min_x, c.rect.x);
        try std.testing.expect(c.rect.x + c.rect.w <= 800.0 + 0.05);
    }
    try std.testing.expect(ltr_runs == 2);
    // LTR still starts exactly at the left column edge (pen-start guard).
    try std.testing.expectApproxEqAbs(@as(f32, 200.0), min_x, 0.05);
}

test "controls: rtl direction is per-paragraph (issue #50)" {
    var cmds: [128]layout.DrawCommand = undefined;
    const n = layoutDoc("Hello\n\nשלום עולם\n\nWorld\n", &cmds);
    var saw_left = false;
    var saw_right = false;
    for (cmds[0..n]) |c| {
        if (c.kind != .text_run) continue;
        if (c.rect.x <= 200.05) saw_left = true;
        if (c.rect.x + c.rect.w >= 799.95) saw_right = true;
    }
    try std.testing.expect(saw_left and saw_right);
}

test "controls: rtl list markers mirror right (issue #50)" {
    var cmds: [64]layout.DrawCommand = undefined;
    const n_rtl = layoutDoc("- שלום\n", &cmds);
    var marker_x: f32 = -1;
    var text_x: f32 = -1;
    for (cmds[0..n_rtl]) |c| {
        if (c.kind != .text_run) continue;
        if (std.mem.eql(u8, c.text, "•")) {
            marker_x = c.rect.x;
        } else if (text_x < 0) {
            text_x = c.rect.x;
        }
    }
    try std.testing.expect(marker_x > 0 and text_x > 0);
    // Mirrored: bullet sits right of the item text (PR #324: 14px dot
    // centered +8 in its 30px gutter, so the LTR dot is at 208 and its
    // mirror at 2*200+600-208-14 = 778).
    try std.testing.expect(marker_x > text_x);
    try std.testing.expectApproxEqAbs(@as(f32, 778.0), marker_x, 0.05);

    const n_ltr = layoutDoc("- Hello\n", &cmds);
    marker_x = -1;
    text_x = -1;
    for (cmds[0..n_ltr]) |c| {
        if (c.kind != .text_run) continue;
        if (std.mem.eql(u8, c.text, "•")) {
            marker_x = c.rect.x;
        } else if (text_x < 0) {
            text_x = c.rect.x;
        }
    }
    try std.testing.expect(marker_x >= 0 and text_x >= 0);
    try std.testing.expectApproxEqAbs(@as(f32, 208.0), marker_x, 0.05);
    try std.testing.expect(marker_x < text_x);
}

test "controls: rtl quote bars mirror right (issue #50)" {
    var cmds: [64]layout.DrawCommand = undefined;
    const n_rtl = layoutDoc("> שלום\n", &cmds);
    var bar_x: f32 = -1;
    for (cmds[0..n_rtl]) |c| {
        if (c.kind == .fill_rect and c.rect.w == 3.0) bar_x = c.rect.x;
    }
    // LTR bar sits at content_x + 16 - 12 - 3 = 201 (quote-bar polish,
    // issue #24); the RTL bar is its exact column mirror:
    // 2*200 + 600 - 201 - 3 = 796.
    try std.testing.expectApproxEqAbs(@as(f32, 796.0), bar_x, 0.05);

    const n_ltr = layoutDoc("> Hello\n", &cmds);
    bar_x = -1;
    for (cmds[0..n_ltr]) |c| {
        if (c.kind == .fill_rect and c.rect.w == 3.0) bar_x = c.rect.x;
    }
    try std.testing.expectApproxEqAbs(@as(f32, 201.0), bar_x, 0.05);
}

test "controls: rtl heading right-aligns (issue #50)" {
    var cmds: [64]layout.DrawCommand = undefined;
    const n_rtl = layoutDoc("# שלום\n", &cmds);
    var max_right: f32 = 0;
    var runs: usize = 0;
    for (cmds[0..n_rtl]) |c| {
        if (c.kind != .text_run) continue;
        runs += 1;
        max_right = @max(max_right, c.rect.x + c.rect.w);
    }
    try std.testing.expect(runs > 0);
    try std.testing.expectApproxEqAbs(@as(f32, 800.0), max_right, 0.05);

    const n_ltr = layoutDoc("# Hello\n", &cmds);
    var min_x: f32 = 1e9;
    for (cmds[0..n_ltr]) |c| {
        if (c.kind != .text_run) continue;
        min_x = @min(min_x, c.rect.x);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 200.0), min_x, 0.05);
}
