//! Damage tracking (dirty rectangles) for the renderer/compositor path.
//!
//! Policy: full-screen redraw only when every pixel may have changed
//! (resize, scroll offset change, theme toggle). Cursor blink, selection
//! caret moves, single-line keystrokes, animated GIF ticks, and hover
//! affordances each compute an exact bounding box that is submitted to the
//! OS compositor via `platform_request_redraw_rect`, and the compositor loop
//! in `main.zig` skips pixel commands that do not intersect the damage.
//!
//! Zero heap allocations: fixed-size stack arrays only, no allocator.

const std = @import("std");

/// Classifies what changed; drives the full-vs-partial redraw policy.
pub const DamageCause = enum {
    resize,
    scroll,
    theme_toggle,
    cursor_blink,
    selection,
    keystroke,
    gif_tick,
    hover,
    unknown,
};

/// A dirty rectangle in view coordinates (matches DrawCommand rect space).
pub const DirtyRect = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    w: f32 = 0.0,
    h: f32 = 0.0,

    pub const empty: DirtyRect = .{};

    pub fn isEmpty(self: DirtyRect) bool {
        return self.w <= 0.0 or self.h <= 0.0;
    }

    pub fn intersects(a: DirtyRect, b: DirtyRect) bool {
        if (a.isEmpty() or b.isEmpty()) return false;
        return a.x < b.x + b.w and b.x < a.x + a.w and
            a.y < b.y + b.h and b.y < a.y + a.h;
    }

    pub fn intersection(a: DirtyRect, b: DirtyRect) DirtyRect {
        const x0 = @max(a.x, b.x);
        const y0 = @max(a.y, b.y);
        const x1 = @min(a.x + a.w, b.x + b.w);
        const y1 = @min(a.y + a.h, b.y + b.h);
        if (x1 <= x0 or y1 <= y0) return .empty;
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }

    /// Smallest rect covering both inputs; empty inputs are absorbed.
    /// (`union` is a Zig keyword, hence the name.)
    pub fn united(a: DirtyRect, b: DirtyRect) DirtyRect {
        if (a.isEmpty()) return b;
        if (b.isEmpty()) return a;
        const x0 = @min(a.x, b.x);
        const y0 = @min(a.y, b.y);
        const x1 = @max(a.x + a.w, b.x + b.w);
        const y1 = @max(a.y + a.h, b.y + b.h);
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }

    pub fn contains(outer: DirtyRect, inner: DirtyRect) bool {
        if (inner.isEmpty()) return true;
        if (outer.isEmpty()) return false;
        return outer.x <= inner.x and outer.y <= inner.y and
            outer.x + outer.w >= inner.x + inner.w and
            outer.y + outer.h >= inner.y + inner.h;
    }

    pub fn coversView(self: DirtyRect, view_w: f32, view_h: f32) bool {
        return !self.isEmpty() and self.x <= 0.0 and self.y <= 0.0 and
            self.x + self.w >= view_w and self.y + self.h >= view_h;
    }
};

/// Exact bounding box for a blinking text caret: 2px caret plus 1px pad.
pub fn cursorBlinkRect(caret_x: f32, line_y: f32, line_h: f32) DirtyRect {
    return .{ .x = caret_x - 1.0, .y = line_y, .w = 4.0, .h = line_h };
}

/// Exact bounding box for a single edited line after a keystroke.
pub fn keystrokeRect(line_x: f32, line_y: f32, line_w: f32, line_h: f32) DirtyRect {
    return .{ .x = line_x, .y = line_y, .w = line_w, .h = line_h };
}

/// Exact bounding box for an animated GIF frame tick.
pub fn gifFrameRect(img_x: f32, img_y: f32, img_w: f32, img_h: f32) DirtyRect {
    return .{ .x = img_x, .y = img_y, .w = img_w, .h = img_h };
}

/// A single damage region handed to the compositor for one frame.
pub const Damage = struct {
    rect: DirtyRect,
    full: bool,
    cause: DamageCause = .unknown,

    pub fn fullView(view_w: f32, view_h: f32, cause: DamageCause) Damage {
        return .{
            .rect = .{ .x = 0.0, .y = 0.0, .w = view_w, .h = view_h },
            .full = true,
            .cause = cause,
        };
    }

    pub fn partial(rect: DirtyRect, cause: DamageCause) Damage {
        return .{ .rect = rect, .full = false, .cause = cause };
    }

    /// Build frame damage from the dirty rect AppKit reported for this draw.
    /// No pending rect (headless render, first draw) means full redraw.
    /// A pending rect covering the whole view collapses to full.
    pub fn fromPending(has_pending: bool, x: f32, y: f32, w: f32, h: f32, view_w: f32, view_h: f32) Damage {
        if (!has_pending) return .fullView(view_w, view_h, .unknown);
        const r: DirtyRect = .{ .x = x, .y = y, .w = w, .h = h };
        if (r.coversView(view_w, view_h)) return .fullView(view_w, view_h, .unknown);
        if (r.isEmpty()) return .fullView(view_w, view_h, .unknown);
        return .partial(r, .unknown);
    }

    /// True when a pixel-producing command must be submitted to the GPU.
    pub fn keeps(self: Damage, x: f32, y: f32, w: f32, h: f32) bool {
        if (self.full) return true;
        return DirtyRect.intersects(self.rect, .{ .x = x, .y = y, .w = w, .h = h });
    }

    /// Clip a background fill to the damage; full damage returns it unchanged.
    pub fn clip(self: Damage, x: f32, y: f32, w: f32, h: f32) DirtyRect {
        const r: DirtyRect = .{ .x = x, .y = y, .w = w, .h = h };
        if (self.full) return r;
        return self.rect.intersection(r);
    }
};

/// Full-vs-partial policy shared by the Zig compositor and the platform layer.
/// Resize, scroll, and theme toggle repaint every pixel, so they go full.
/// Cursor blink, selection, keystroke, GIF tick, and hover submit the exact box.
pub fn damageForCause(cause: DamageCause, exact: DirtyRect, view_w: f32, view_h: f32) Damage {
    return switch (cause) {
        .resize, .scroll, .theme_toggle => Damage.fullView(view_w, view_h, cause),
        .cursor_blink, .selection, .keystroke, .gif_tick, .hover, .unknown => Damage.partial(exact, cause),
    };
}

pub const MAX_DAMAGE_RECTS = 16;

/// Accumulates dirty rects within one frame without allocating.
/// Overflow coalesces into slot 0 so coverage is never lost, only merged.
pub const DamageTracker = struct {
    rects: [MAX_DAMAGE_RECTS]DirtyRect = [_]DirtyRect{.empty} ** MAX_DAMAGE_RECTS,
    count: usize = 0,
    full: bool = false,

    pub fn clear(self: *DamageTracker) void {
        self.count = 0;
        self.full = false;
    }

    pub fn markFull(self: *DamageTracker) void {
        self.full = true;
        self.count = 0;
    }

    pub fn addRect(self: *DamageTracker, r: DirtyRect) void {
        if (self.full or r.isEmpty()) return;
        if (self.count < MAX_DAMAGE_RECTS) {
            self.rects[self.count] = r;
            self.count += 1;
        } else {
            self.rects[0] = self.rects[0].united(r);
        }
    }

    pub fn markCause(self: *DamageTracker, cause: DamageCause, exact: DirtyRect, view_w: f32, view_h: f32) void {
        const d = damageForCause(cause, exact, view_w, view_h);
        if (d.full) {
            self.markFull();
        } else {
            self.addRect(d.rect);
        }
    }

    pub fn boundingBox(self: *const DamageTracker) DirtyRect {
        var box: DirtyRect = .empty;
        for (self.rects[0..self.count]) |r| box = box.united(r);
        return box;
    }

    pub fn isEmpty(self: *const DamageTracker) bool {
        return !self.full and self.count == 0;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "damage: full-screen redraw only on resize-class events" {
    const view_w: f32 = 1000.0;
    const view_h: f32 = 750.0;
    const tiny: DirtyRect = .{ .x = 10, .y = 10, .w = 4, .h = 20 };

    const rsz = damageForCause(.resize, tiny, view_w, view_h);
    try std.testing.expect(rsz.full);
    try std.testing.expectEqual(view_w, rsz.rect.w);
    try std.testing.expectEqual(view_h, rsz.rect.h);

    // Scroll and theme toggle also repaint every pixel (documented full).
    try std.testing.expect(damageForCause(.scroll, tiny, view_w, view_h).full);
    try std.testing.expect(damageForCause(.theme_toggle, tiny, view_w, view_h).full);

    // Cursor blink, keystroke, GIF tick stay partial with the exact box.
    const caret = damageForCause(.cursor_blink, tiny, view_w, view_h);
    try std.testing.expect(!caret.full);
    try std.testing.expectEqual(tiny.x, caret.rect.x);
    try std.testing.expectEqual(tiny.w, caret.rect.w);

    const keys = damageForCause(.keystroke, tiny, view_w, view_h);
    try std.testing.expect(!keys.full);
    try std.testing.expectEqual(tiny.h, keys.rect.h);

    const gif = damageForCause(.gif_tick, tiny, view_w, view_h);
    try std.testing.expect(!gif.full);
    try std.testing.expectEqual(tiny.x, gif.rect.x);
    try std.testing.expectEqual(tiny.y, gif.rect.y);
    try std.testing.expectEqual(tiny.w, gif.rect.w);
    try std.testing.expectEqual(tiny.h, gif.rect.h);
}

test "damage: exact bounding boxes for cursor blink, keystroke, GIF tick" {
    const caret = cursorBlinkRect(100.0, 50.0, 24.0);
    try std.testing.expectEqual(@as(f32, 99.0), caret.x);
    try std.testing.expectEqual(@as(f32, 50.0), caret.y);
    try std.testing.expectEqual(@as(f32, 4.0), caret.w);
    try std.testing.expectEqual(@as(f32, 24.0), caret.h);

    const line = keystrokeRect(32.0, 200.0, 600.0, 29.75);
    try std.testing.expectEqual(@as(f32, 32.0), line.x);
    try std.testing.expectEqual(@as(f32, 200.0), line.y);
    try std.testing.expectEqual(@as(f32, 600.0), line.w);
    try std.testing.expectEqual(@as(f32, 29.75), line.h);

    const frame = gifFrameRect(200.0, 300.0, 400.0, 240.0);
    try std.testing.expectEqual(@as(f32, 200.0), frame.x);
    try std.testing.expectEqual(@as(f32, 300.0), frame.y);
    try std.testing.expectEqual(@as(f32, 400.0), frame.w);
    try std.testing.expectEqual(@as(f32, 240.0), frame.h);
}

test "damage: tracker unions rects and survives overflow without losing coverage" {
    var t = DamageTracker{};
    try std.testing.expect(t.isEmpty());

    const a: DirtyRect = .{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const b: DirtyRect = .{ .x = 100, .y = 200, .w = 30, .h = 40 };
    t.addRect(a);
    t.addRect(b);
    // Empty rects are ignored.
    t.addRect(.empty);
    try std.testing.expectEqual(@as(usize, 2), t.count);

    const box = t.boundingBox();
    try std.testing.expect(DirtyRect.contains(box, a));
    try std.testing.expect(DirtyRect.contains(box, b));
    try std.testing.expectEqual(@as(f32, 0.0), box.x);
    try std.testing.expectEqual(@as(f32, 130.0), box.x + box.w);

    // Overflow: 20 disjoint rects into 16 slots; coverage must hold.
    var t2 = DamageTracker{};
    var added: [20]DirtyRect = undefined;
    for (0..20) |k| {
        const f: f32 = @floatFromInt(k);
        added[k] = .{ .x = f * 50.0, .y = f * 10.0, .w = 20.0, .h = 8.0 };
        t2.addRect(added[k]);
    }
    const box2 = t2.boundingBox();
    for (added) |r| {
        try std.testing.expect(DirtyRect.contains(box2, r));
    }

    // Full swallows adds; clear resets.
    t2.markFull();
    try std.testing.expect(t2.full);
    t2.addRect(a);
    try std.testing.expectEqual(@as(usize, 0), t2.count);
    t2.clear();
    try std.testing.expect(t2.isEmpty());

    // markCause routes resize to full, gif tick to partial.
    var t3 = DamageTracker{};
    t3.markCause(.gif_tick, b, 1000.0, 750.0);
    try std.testing.expect(!t3.full);
    try std.testing.expectEqual(@as(usize, 1), t3.count);
    t3.markCause(.resize, b, 1000.0, 750.0);
    try std.testing.expect(t3.full);
}

test "damage: fromPending collapses full-view and missing rects to full" {
    const full = Damage.fromPending(false, 0, 0, 0, 0, 800.0, 600.0);
    try std.testing.expect(full.full);

    const appkit_full = Damage.fromPending(true, 0, 0, 800, 600, 800.0, 600.0);
    try std.testing.expect(appkit_full.full);

    const part = Damage.fromPending(true, 200, 300, 400, 240, 800.0, 600.0);
    try std.testing.expect(!part.full);
    try std.testing.expect(!part.keeps(0, 0, 50, 50));
    try std.testing.expect(part.keeps(210, 310, 50, 50));

    const clipped = part.clip(0, 0, 800, 600);
    try std.testing.expectEqual(@as(f32, 200.0), clipped.x);
    try std.testing.expectEqual(@as(f32, 400.0), clipped.w);
}

test "damage: redraw-region verification against real layout output" {
    const viewport = @import("viewport.zig");
    const simd = @import("../core/simd.zig");

    const doc =
        \\# Title
        \\
        \\Hello world line one.
        \\
        \\```zig
        \\const x = 1;
        \\```
    ;
    var lines_buf: [32]simd.Line = undefined;
    var fence = false;
    const n = simd.scanLines(doc, &lines_buf, &fence);
    try std.testing.expect(n > 0);

    var cmds: [256]viewport.DrawCommand = undefined;
    const cfg = viewport.ViewportConfig{
        .window_width = 800.0,
        .window_height = 600.0,
        .scroll_y = 0.0,
    };
    const count = viewport.layoutViewport(doc, lines_buf[0..n], cfg, &cmds);
    try std.testing.expect(count > 0);

    // Simulate a keystroke on the first text run: damage is its exact box.
    var target: ?viewport.Rect = null;
    for (cmds[0..count]) |c| {
        if (c.kind == .text_run) {
            target = c.rect;
            break;
        }
    }
    try std.testing.expect(target != null);
    const dmg = Damage.partial(
        .{ .x = target.?.x, .y = target.?.y, .w = target.?.w, .h = target.?.h },
        .keystroke,
    );

    var kept: usize = 0;
    var culled: usize = 0;
    for (cmds[0..count]) |c| {
        switch (c.kind) {
            .fill_rect, .text_run, .line, .code_block_bg, .image => {
                if (dmg.keeps(c.rect.x, c.rect.y, c.rect.w, c.rect.h)) {
                    try std.testing.expect(DirtyRect.intersects(
                        dmg.rect,
                        .{ .x = c.rect.x, .y = c.rect.y, .w = c.rect.w, .h = c.rect.h },
                    ));
                    kept += 1;
                } else {
                    culled += 1;
                }
            },
            else => {},
        }
    }
    try std.testing.expect(kept > 0);
    // Partial damage must actually avoid repainting off-region pixels.
    try std.testing.expect(culled > 0);

    // Resize damage keeps every pixel command.
    const full = Damage.fullView(800.0, 600.0, .resize);
    for (cmds[0..count]) |c| {
        switch (c.kind) {
            .fill_rect, .text_run, .line, .code_block_bg, .image => {
                try std.testing.expect(full.keeps(c.rect.x, c.rect.y, c.rect.w, c.rect.h));
            },
            else => {},
        }
    }
}
