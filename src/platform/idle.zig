const std = @import("std");
const mmap = @import("../core/mmap.zig");

// ============================================================================
// Event-Driven Idling Policy (todo/ideas.txt line 5: "Event-Driven Idling").
//
// The platform run loop ([NSApp run] in src/platform/macos.m) blocks inside
// the OS kernel event wait. It never spins, polls, or runs a persistent
// frame clock: there is intentionally NO CADisplayLink / CVDisplayLink /
// repeating NSTimer anywhere. Redraws and the GIF frame driver below are
// armed ONLY by real OS events (scroll, key, resize, mouse-state change,
// async image arrival, GIF tick while visible). When the screen is static,
// nothing is scheduled and the process sleeps at 0% CPU.
//
// This file holds the pure, zero-allocation predicates that macos.m mirrors
// in ObjC. Tests pin the truth tables; a source-audit test pins the
// structural invariants on macos.m itself.
// ============================================================================

/// Hover state relevant to mouse-motion redraws.
pub const HoverState = struct {
    over_link: bool = false,
    over_code_button: bool = false,
    selection_active: bool = false, // drag/select gesture in progress
    has_records: bool = false, // any text records hit-testable this frame
};

/// Mouse motion alone must never redraw. Only a hover-state transition
/// (link or copy-button highlight flipping) justifies a redraw from
/// mouseMoved. Selection drags redraw via mouseDragged, not mouseMoved.
pub fn shouldRedrawOnHover(prev: HoverState, next: HoverState) bool {
    if (!next.has_records) return false;
    if (next.selection_active) return false;
    return (prev.over_link != next.over_link) or
        (prev.over_code_button != next.over_code_button);
}

/// Models the on-demand animation driver. The driver (GIF dispatch_after
/// chain / momentum redraws) is wanted ONLY while a multi-frame image is
/// visibly animating or a kinetic-scroll momentum stream is in flight.
/// The instant both clear, the driver must be fully parked: no timer, no
/// callback, no wakeup.
pub const AnimDriver = struct {
    gif_frames_pending: u32 = 0, // visible, unparked multi-frame images
    momentum_active: bool = false, // trackpad momentum event stream live

    pub fn wantsDriver(self: AnimDriver) bool {
        return self.gif_frames_pending > 0 or self.momentum_active;
    }
};

/// Per-GIF gate evaluated on every frame tick. A tick advances (and
/// reschedules) only if the window is actually visible AND the image was
/// painted in the latest pass (i.e. inside the drawn viewport). Otherwise
/// the chain parks; the next genuine draw re-arms it.
pub const GifGate = struct {
    window_visible: bool = false, // not miniaturized/hidden/occluded
    drawn_since_last_tick: bool = false, // frame painted in latest pass
    frame_count: u32 = 0,

    pub fn shouldAdvance(self: GifGate) bool {
        if (self.frame_count <= 1) return false;
        if (!self.window_visible) return false;
        if (!self.drawn_since_last_tick) return false;
        return true;
    }
};

/// End-of-gesture detection for scroll events. Both the finger phase and
/// the kinetic momentum phase ending must return the loop to idle; neither
/// may leave the driver armed.
pub fn isGestureEnd(phase_ended_or_cancelled: bool, momentum_ended_or_cancelled: bool) bool {
    return phase_ended_or_cancelled or momentum_ended_or_cancelled;
}

// ---------------------------------------------------------------------------
// Tests: hover gating
// ---------------------------------------------------------------------------

test "idle: mouse motion without hover change never redraws" {
    const prev = HoverState{ .has_records = true };
    const next = HoverState{ .has_records = true };
    try std.testing.expect(!shouldRedrawOnHover(prev, next));
}

test "idle: hover transitions redraw exactly once" {
    const base = HoverState{ .has_records = true };
    try std.testing.expect(shouldRedrawOnHover(base, .{ .has_records = true, .over_link = true }));
    try std.testing.expect(shouldRedrawOnHover(base, .{ .has_records = true, .over_code_button = true }));
    // Steady hovered state: no further redraws.
    const hovered = HoverState{ .has_records = true, .over_link = true };
    try std.testing.expect(!shouldRedrawOnHover(hovered, hovered));
    // Hover leaving: one final redraw to clear the highlight.
    try std.testing.expect(shouldRedrawOnHover(hovered, base));
}

test "idle: no records or active selection suppresses mouseMoved redraw" {
    const prev = HoverState{};
    try std.testing.expect(!shouldRedrawOnHover(prev, .{ .has_records = false, .over_link = true }));
    try std.testing.expect(!shouldRedrawOnHover(prev, .{ .has_records = true, .selection_active = true }));
}

// ---------------------------------------------------------------------------
// Tests: animation driver arming
// ---------------------------------------------------------------------------

test "idle: driver fully parked when screen is static" {
    const driver = AnimDriver{};
    try std.testing.expect(!driver.wantsDriver());
}

test "idle: driver armed only during animation or momentum" {
    try std.testing.expect((AnimDriver{ .gif_frames_pending = 1 }).wantsDriver());
    try std.testing.expect((AnimDriver{ .momentum_active = true }).wantsDriver());
    try std.testing.expect((AnimDriver{ .gif_frames_pending = 2, .momentum_active = true }).wantsDriver());
    // Momentum over, no GIFs: parked the same instant.
    try std.testing.expect(!(AnimDriver{ .gif_frames_pending = 0, .momentum_active = false }).wantsDriver());
}

// ---------------------------------------------------------------------------
// Tests: GIF tick gate
// ---------------------------------------------------------------------------

test "idle: gif advances only when visible and drawn" {
    try std.testing.expect(!(GifGate{ .frame_count = 1, .window_visible = true, .drawn_since_last_tick = true }).shouldAdvance());
    try std.testing.expect(!(GifGate{ .frame_count = 4, .window_visible = false, .drawn_since_last_tick = true }).shouldAdvance());
    try std.testing.expect(!(GifGate{ .frame_count = 4, .window_visible = true, .drawn_since_last_tick = false }).shouldAdvance());
    try std.testing.expect((GifGate{ .frame_count = 4, .window_visible = true, .drawn_since_last_tick = true }).shouldAdvance());
}

test "idle: scroll gesture end returns loop to idle" {
    try std.testing.expect(isGestureEnd(true, false));
    try std.testing.expect(isGestureEnd(false, true));
    try std.testing.expect(isGestureEnd(true, true));
    try std.testing.expect(!isGestureEnd(false, false));
}

// ---------------------------------------------------------------------------
// Test: structural audit of the platform run loop.
// Pins "strictly OS blocking events, no spin/poll, no persistent frame
// clock" directly on src/platform/macos.m.
// ---------------------------------------------------------------------------

test "idle: platform run loop is strictly event-driven (source audit)" {
    // Same convention as controls_test.zig ("showcase.md"): tests run with the
    // project root as cwd, so the platform source is read by relative path.
    var mapped = try mmap.MappedFile.open("src/platform/macos.m");
    defer mapped.close();
    const src = mapped.bytes;

    // Banned: any persistent frame clock, repeating timer, or spin/poll loop.
    const banned = [_][]const u8{
        "CADisplayLink",
        "CVDisplayLink",
        "scheduledTimerWithTimeInterval",
        "NSTimer",
        "usleep(",
        "nanosleep(",
        "kevent(",
        "kqueue(",
        "poll(",
        "while (1)",
        "while(1)",
        "while (true)",
        "while(true)",
    };
    for (banned) |token| {
        try std.testing.expectEqual(
            null,
            std.mem.indexOf(u8, src, token),
        );
    }

    // Required: blocking NSApp run loop, gated hover redraw, momentum-phase
    // handling, occlusion-gated GIF driver with park/resume.
    const required = [_][]const u8{
        "[NSApp run]",
        "momentumPhase",
        "occlusionState",
        "parked",
        "g_last_link_hover",
    };
    for (required) |token| {
        try std.testing.expect(std.mem.indexOf(u8, src, token) != null);
    }
}

test "idle: zero background threads on the hot path (issue #14 source audit)" {
    // The #14 contract is structural: one thread, vsync-coalesced, fully
    // asleep when idle. Any worker-thread creation or process forking in the
    // hot-path Zig sources (scan/layout/render/startup) would break App Nap
    // and 1:1 trackpad feel, so the construction tokens are banned by audit —
    // same convention as the run-loop test above. (src/tests/ is excluded:
    // the CommonMark conformance harness may use worker threads; it never
    // ships. Tokens are split so this very list does not self-match.)
    const hot = [_][]const u8{
        "src/core/simd.zig",
        "src/core/mmap.zig",
        "src/core/parser.zig",
        "src/core/block_index.zig",
        "src/core/strict_benchmarks.zig",
        "src/layout/viewport.zig",
        "src/layout/damage.zig",
        "src/main.zig",
        "src/platform/bridge.zig",
        "src/platform/glyph_cache.zig",
        "src/platform/idle.zig",
    };
    const banned = [_][]const u8{
        "std.Thr" ++ "ead",
        "Thr" ++ "ead.spawn",
        "pthr" ++ "ead",
        "for" ++ "k(",
        "spa" ++ "wn(",
    };
    for (hot) |path| {
        var mapped = try mmap.MappedFile.open(path);
        defer mapped.close();
        for (banned) |token| {
            try std.testing.expectEqual(null, std.mem.indexOf(u8, mapped.bytes, token));
        }
    }
}
