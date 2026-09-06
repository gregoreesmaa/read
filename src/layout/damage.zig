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

/// Selection bounds in VIEW coordinates, expanded by pad.
/// Mirrors `selection_bounds_expanded` in macos.m: endpoints are stored in
/// document space, so y is shifted by scroll_y. The platform
/// drag/down/up handlers must invalidate this FULL box — never a
/// cursor-path strip: the flowing highlight spans full line widths between
/// the endpoints, far outside any strip around the cursor.
///
/// Multi-line selections (y-span over one row) expand to the full view
/// width: intermediate rows highlight edge-to-edge, outside the endpoint
/// x-range entirely. Single-line selections keep a tight box.
///
/// Companion invariant (enforced in main.zig, not here): the text-record
/// model backing selection/hover/link painting is rebuilt on EVERY draw,
/// including partial-damage draws that skip pixels (via
/// `platform_register_text_run`). Culling pixels must never starve state.
pub fn selectionBoundsBox(sx: f32, sy_doc: f32, ex: f32, ey_doc: f32, scroll_y: f32, pad: f32, full_w: f32) DirtyRect {
    const y1 = @min(sy_doc, ey_doc) - scroll_y - pad;
    const y2 = @max(sy_doc, ey_doc) - scroll_y + pad;
    if (@max(sy_doc, ey_doc) - @min(sy_doc, ey_doc) > 32.0) {
        return .{ .x = 0.0 - pad, .y = y1, .w = full_w + 2.0 * pad, .h = y2 - y1 };
    }
    const x1 = @min(sx, ex) - pad;
    const x2 = @max(sx, ex) + pad;
    return .{ .x = x1, .y = y1, .w = x2 - x1, .h = y2 - y1 };
}

/// Damage for one drag step: union of the full selection bounds before and
/// after the cursor-end moves. Mirrors `mouseDragged` in macos.m.
/// Regression (2026-09): invalidating only the prev-end→new-end cursor strip
/// left newly selected lines showing stale pixels, because the highlight
/// covers full line widths the strip never touches.
pub fn dragSelectionDamage(sx: f32, sy_doc: f32, old_ex: f32, old_ey_doc: f32, new_ex: f32, new_ey_doc: f32, scroll_y: f32, pad: f32, full_w: f32) DirtyRect {
    const old = selectionBoundsBox(sx, sy_doc, old_ex, old_ey_doc, scroll_y, pad, full_w);
    const new = selectionBoundsBox(sx, sy_doc, new_ex, new_ey_doc, scroll_y, pad, full_w);
    return old.united(new);
}

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
    var fence: simd.FenceState = .{};
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

test "damage: keeps() retains partially overlapped commands (no containment narrowing)" {
    // Regression (2026-09): narrowing keeps() to full containment dropped
    // highlight and text pixels on every partial redraw. Intersection of
    // command rect with damage is the contract — partial overlap MUST draw.
    const dmg = Damage.partial(.{ .x = 680.0, .y = 100.0, .w = 80.0, .h = 60.0 }, .selection);
    // Line body mostly outside the damage, touching it at the right edge.
    try std.testing.expect(dmg.keeps(200.0, 110.0, 500.0, 24.0));
    // Command fully inside the damage is kept.
    try std.testing.expect(dmg.keeps(690.0, 110.0, 50.0, 20.0));
    // Fully disjoint command is still culled (performance preserved).
    try std.testing.expect(!dmg.keeps(0.0, 500.0, 600.0, 24.0));
    // Touching at exactly one edge (zero-area overlap) draws nothing.
    try std.testing.expect(!dmg.keeps(760.0, 100.0, 40.0, 60.0));
}

test "damage: selection bounds mirror the platform formula" {
    // selectionBoundsBox must match macos.m selection_bounds_expanded:
    // doc-space endpoints, y shifted by scroll, expanded by pad.
    // Single-line selection keeps a tight box.
    const b = selectionBoundsBox(700.0, 500.0, 100.0, 520.0, 400.0, 24.0, 1200.0);
    try std.testing.expectEqual(@as(f32, 76.0), b.x);
    try std.testing.expectEqual(@as(f32, 76.0), b.y);
    try std.testing.expectEqual(@as(f32, 648.0), b.w);
    try std.testing.expectEqual(@as(f32, 68.0), b.h);
    // Multi-line selection expands to the full view width: intermediate
    // rows highlight edge-to-edge, outside the endpoint x-range.
    const m = selectionBoundsBox(700.0, 500.0, 100.0, 620.0, 400.0, 24.0, 1200.0);
    try std.testing.expectEqual(@as(f32, -24.0), m.x);
    try std.testing.expectEqual(@as(f32, 76.0), m.y);
    try std.testing.expectEqual(@as(f32, 1248.0), m.w);
    try std.testing.expectEqual(@as(f32, 168.0), m.h);
}

test "damage: drag invalidation covers full selection, not the cursor strip" {
    // Regression (2026-09): mouseDragged invalidated only the
    // prev-end→new-end cursor strip, leaving newly selected full-width
    // lines stale. Drag from (650,100) to (120,260): intermediate lines
    // span x=200..700, far outside any strip around the cursor path.
    const pad: f32 = 24.0;
    const scroll_y: f32 = 0.0;
    const full_w: f32 = 1200.0;
    const dmg = dragSelectionDamage(650.0, 100.0, 650.0, 130.0, 120.0, 260.0, scroll_y, pad, full_w);
    // Intermediate full-width line must lie inside the damage.
    const midline: DirtyRect = .{ .x = 200.0, .y = 160.0, .w = 500.0, .h = 24.0 };
    try std.testing.expect(DirtyRect.contains(dmg, midline));
    // Damage is exactly the union of the old and new full selection bounds.
    const old = selectionBoundsBox(650.0, 100.0, 650.0, 130.0, scroll_y, pad, full_w);
    const new = selectionBoundsBox(650.0, 100.0, 120.0, 260.0, scroll_y, pad, full_w);
    const u = old.united(new);
    try std.testing.expectEqual(u.x, dmg.x);
    try std.testing.expectEqual(u.y, dmg.y);
    try std.testing.expectEqual(u.w, dmg.w);
    try std.testing.expectEqual(u.h, dmg.h);
}

test "damage: drag reversal still covers released lines" {
    // Dragging back up must keep the abandoned lines inside the damage so
    // their highlight is cleared, not left stale.
    const dmg = dragSelectionDamage(650.0, 100.0, 120.0, 260.0, 650.0, 130.0, 0.0, 24.0, 1200.0);
    const released: DirtyRect = .{ .x = 200.0, .y = 230.0, .w = 500.0, .h = 24.0 };
    try std.testing.expect(DirtyRect.contains(dmg, released));
    const start_line: DirtyRect = .{ .x = 600.0, .y = 100.0, .w = 90.0, .h = 24.0 };
    try std.testing.expect(DirtyRect.contains(dmg, start_line));
}

test "damage: randomized keeps/clip agree with rect algebra" {
    // Seeded interaction fuzz at the algebra level: keeps() must match
    // intersects(), clip() must equal intersection(), united() must cover
    // both inputs, and fromPending() must collapse full/empty/missing rects.
    // Any disagreement here becomes a stale/residue pixel downstream.
    var prng = std.Random.DefaultPrng.init(0xda4a6e20260905);
    const rnd = prng.random();
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        const dr: DirtyRect = .{
            .x = rnd.float(f32) * 3000.0 - 750.0,
            .y = rnd.float(f32) * 3000.0 - 750.0,
            .w = rnd.float(f32) * 1300.0 - 50.0,
            .h = rnd.float(f32) * 1300.0 - 50.0,
        };
        const cr: DirtyRect = .{
            .x = rnd.float(f32) * 3000.0 - 750.0,
            .y = rnd.float(f32) * 3000.0 - 750.0,
            .w = rnd.float(f32) * 1300.0 - 50.0,
            .h = rnd.float(f32) * 1300.0 - 50.0,
        };
        const dmg = Damage.partial(dr, .unknown);
        try std.testing.expectEqual(DirtyRect.intersects(dr, cr), dmg.keeps(cr.x, cr.y, cr.w, cr.h));
        const clipped = dmg.clip(cr.x, cr.y, cr.w, cr.h);
        const inter = DirtyRect.intersection(dr, cr);
        try std.testing.expectEqual(inter.x, clipped.x);
        try std.testing.expectEqual(inter.y, clipped.y);
        try std.testing.expectEqual(inter.w, clipped.w);
        try std.testing.expectEqual(inter.h, clipped.h);
        try std.testing.expectEqual(clipped.isEmpty(), !dmg.keeps(cr.x, cr.y, cr.w, cr.h));
        // united()/contains() agree exactly on whole-number rects (the
        // production damage domain: boxes are pixel-quantized, so w = x1-x0
        // is exact; fractional inputs can differ by 1 ulp on recompute).
        const ir: DirtyRect = .{
            .x = @floor(rnd.float(f32) * 3000.0 - 750.0),
            .y = @floor(rnd.float(f32) * 3000.0 - 750.0),
            .w = @floor(rnd.float(f32) * 1300.0 - 50.0),
            .h = @floor(rnd.float(f32) * 1300.0 - 50.0),
        };
        const jr: DirtyRect = .{
            .x = @floor(rnd.float(f32) * 3000.0 - 750.0),
            .y = @floor(rnd.float(f32) * 3000.0 - 750.0),
            .w = @floor(rnd.float(f32) * 1300.0 - 50.0),
            .h = @floor(rnd.float(f32) * 1300.0 - 50.0),
        };
        const u = ir.united(jr);
        try std.testing.expect(u.contains(ir));
        try std.testing.expect(u.contains(jr));
        // Full-view and degenerate pending rects collapse to full redraws.
        const fv = Damage.fromPending(true, 0.0, 0.0, 1200.0, 900.0, 1200.0, 900.0);
        try std.testing.expect(fv.full);
        const ze = Damage.fromPending(true, 10.0, 10.0, 0.0, 50.0, 1200.0, 900.0);
        try std.testing.expect(ze.full);
        const no = Damage.fromPending(false, 10.0, 10.0, 50.0, 50.0, 1200.0, 900.0);
        try std.testing.expect(no.full);
    }
}
