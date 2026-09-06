const std = @import("std");
const layout = @import("viewport.zig");

/// Single source of truth for every keybinding (issue #54).
///
/// The key handler (`onKey` in `src/main.zig`) dispatches through
/// `actionFor` + an exhaustive `switch` over `Action` (no `else`), so
/// adding a row with a new `Action` fails to compile until the handler
/// covers it — the overlay and the handler cannot drift apart.
///
/// `key == null` marks platform-native bindings (handled in `macos.m`,
/// never delivered via `on_key`): listed so the sheet is complete, never
/// matched by `actionFor`.
pub const Action = enum {
    scroll_down,
    scroll_up,
    block_left,
    block_right,
    page_down,
    toggle_theme,
    toggle_help,
    dismiss_help,
    quit,
    native,
};

pub const Binding = struct {
    key: ?c_int,
    label: []const u8,
    desc: []const u8,
    action: Action,
};

pub const KEY_QUIT: c_int = 'q';
pub const KEY_HELP: c_int = '?';
pub const KEY_ESC: c_int = 27;

pub const BINDINGS: []const Binding = &.{
    .{ .key = 'j', .label = "j", .desc = "Scroll down (40px)", .action = .scroll_down },
    .{ .key = 'k', .label = "k", .desc = "Scroll up (40px)", .action = .scroll_up },
    .{ .key = ' ', .label = "Space", .desc = "Page down (80% window height)", .action = .page_down },
    .{ .key = 't', .label = "t", .desc = "Toggle dark / light theme", .action = .toggle_theme },
    .{ .key = 'h', .label = "h", .desc = "Scroll hovered code block or table left", .action = .block_left },
    .{ .key = 'l', .label = "l", .desc = "Scroll hovered code block or table right", .action = .block_right },
    .{ .key = '?', .label = "?", .desc = "Toggle this cheat sheet", .action = .toggle_help },
    .{ .key = 27, .label = "Esc", .desc = "Dismiss cheat sheet", .action = .dismiss_help },
    .{ .key = 'q', .label = "q", .desc = "Quit", .action = .quit },
    .{ .key = null, .label = "Cmd+C", .desc = "Copy selection to clipboard", .action = .native },
    .{ .key = null, .label = "Cmd+A", .desc = "Select all text in document", .action = .native },
};

/// Table lookup for the key handler. Null when the key has no binding.
pub fn actionFor(key_code: c_int) ?Binding {
    for (BINDINGS) |b| {
        if (b.key) |k| {
            if (k == key_code) return b;
        }
    }
    return null;
}

pub const OVERLAY_FONT_SIZE: f32 = 15.0;
pub const OVERLAY_TITLE_SIZE: f32 = 17.0;
pub const OVERLAY_LINE_H: f32 = OVERLAY_FONT_SIZE * 1.75;
pub const OVERLAY_PAD_X: f32 = 28.0;
pub const OVERLAY_PAD_Y: f32 = 24.0;
pub const OVERLAY_TITLE_GAP: f32 = 12.0;
pub const OVERLAY_LABEL_GAP: f32 = 16.0;

/// Pure overlay layout (issue #54): writes a dim fullscreen rect, a
/// centered card, a title, and one label+description run pair per table
/// row into `commands`. Zero allocations, no platform calls — the caller
/// executes the commands through the normal `platform_draw_*` path, so
/// overlay pixels and text records match every other text run (overlay
/// text lands in the recorded-text model that #29 will expose to
/// VoiceOver; full AX roles await #29, still open).
/// Returns the command count (3 + 2 rows). Truncates rows, never
/// overflows, when the buffer is short.
pub fn emitOverlay(
    commands: []layout.DrawCommand,
    view_w: f32,
    view_h: f32,
    theme: layout.Theme,
) usize {
    const n_rows = BINDINGS.len;
    var label_w: f32 = 0.0;
    var row_w: f32 = 0.0;
    for (BINDINGS) |b| {
        const lw = layout.measureTextEx(b.label, OVERLAY_FONT_SIZE, true, false, false, false);
        if (lw > label_w) label_w = lw;
        const dw = layout.measureTextEx(b.desc, OVERLAY_FONT_SIZE, false, false, false, false);
        const w = lw + OVERLAY_LABEL_GAP + dw;
        if (w > row_w) row_w = w;
    }
    const title_text = "Keyboard shortcuts  ( ? / Esc to dismiss )";
    const title_w = layout.measureTextEx(title_text, OVERLAY_TITLE_SIZE, true, false, false, false);

    var card_w = @max(row_w, title_w) + OVERLAY_PAD_X * 2.0;
    card_w = @min(card_w, @max(0.0, view_w - 32.0));
    const card_h = OVERLAY_PAD_Y * 2.0 + OVERLAY_TITLE_SIZE * 1.75 +
        OVERLAY_TITLE_GAP + @as(f32, @floatFromInt(n_rows)) * OVERLAY_LINE_H;
    const card_x = (view_w - card_w) * 0.5;
    const card_y = (view_h - card_h) * 0.5;

    var count: usize = 0;
    // Dim the document behind the modal card.
    if (count < commands.len) {
        commands[count] = .{
            .kind = .fill_rect,
            .rect = .{ .x = 0, .y = 0, .w = view_w, .h = view_h },
            .color = .{ .r = 0, .g = 0, .b = 0, .a = 140 },
        };
        count += 1;
    }
    if (count < commands.len) {
        commands[count] = .{
            .kind = .fill_rect,
            .rect = .{ .x = card_x, .y = card_y, .w = card_w, .h = card_h },
            .color = theme.code_bg,
        };
        count += 1;
    }
    if (count < commands.len) {
        commands[count] = .{
            .kind = .text_run,
            .rect = .{ .x = card_x + OVERLAY_PAD_X, .y = card_y + OVERLAY_PAD_Y, .w = title_w, .h = OVERLAY_TITLE_SIZE * 1.75 },
            .color = theme.text,
            .text = title_text,
            .font_size = OVERLAY_TITLE_SIZE,
            .style = .{ .bold = true },
        };
        count += 1;
    }
    var row_y = card_y + OVERLAY_PAD_Y + OVERLAY_TITLE_SIZE * 1.75 + OVERLAY_TITLE_GAP;
    for (BINDINGS) |b| {
        if (count + 2 > commands.len) break;
        const lw = layout.measureTextEx(b.label, OVERLAY_FONT_SIZE, true, false, false, false);
        const dw = layout.measureTextEx(b.desc, OVERLAY_FONT_SIZE, false, false, false, false);
        commands[count] = .{
            .kind = .text_run,
            .rect = .{ .x = card_x + OVERLAY_PAD_X, .y = row_y, .w = lw, .h = OVERLAY_LINE_H },
            .color = theme.accent,
            .text = b.label,
            .font_size = OVERLAY_FONT_SIZE,
            .style = .{ .bold = true },
        };
        count += 1;
        commands[count] = .{
            .kind = .text_run,
            .rect = .{ .x = card_x + OVERLAY_PAD_X + label_w + OVERLAY_LABEL_GAP, .y = row_y, .w = dw, .h = OVERLAY_LINE_H },
            .color = theme.text,
            .text = b.desc,
            .font_size = OVERLAY_FONT_SIZE,
        };
        count += 1;
        row_y += OVERLAY_LINE_H;
    }
    return count;
}

test "help overlay: table covers every documented binding exactly once" {
    // AGENTS.md §4 navigation bindings.
    const required = [_]c_int{ 'j', 'k', ' ', 't', 'h', 'l', 'q' };
    for (required) |k| {
        var hits: usize = 0;
        for (BINDINGS) |b| {
            if (b.key) |bk| {
                if (bk == k) hits += 1;
            }
        }
        try std.testing.expectEqual(@as(usize, 1), hits);
    }
    // Overlay controls themselves.
    try std.testing.expect(actionFor(KEY_HELP) != null);
    try std.testing.expect(actionFor(KEY_ESC) != null);
    // No duplicate keys, no empty labels/descriptions.
    for (BINDINGS, 0..) |a, i| {
        try std.testing.expect(a.label.len > 0);
        try std.testing.expect(a.desc.len > 0);
        if (a.key) |ak| {
            for (BINDINGS[i + 1 ..]) |b| {
                if (b.key) |bk| try std.testing.expect(ak != bk);
            }
        } else {
            // Keyless rows are platform-native only.
            try std.testing.expectEqual(Action.native, a.action);
        }
    }
    // Native clipboard rows are listed for completeness.
    var found_copy = false;
    var found_all = false;
    for (BINDINGS) |b| {
        if (std.mem.eql(u8, b.label, "Cmd+C")) found_copy = true;
        if (std.mem.eql(u8, b.label, "Cmd+A")) found_all = true;
    }
    try std.testing.expect(found_copy and found_all);
}

test "help overlay: every Action variant is represented in the table" {
    inline for (std.meta.fields(Action)) |f| {
        const want: Action = @enumFromInt(f.value);
        var found = false;
        for (BINDINGS) |b| {
            if (b.action == want) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

test "help overlay: actionFor lookup" {
    const j = actionFor('j').?;
    try std.testing.expectEqual(Action.scroll_down, j.action);
    try std.testing.expectEqual(Action.quit, actionFor('q').?.action);
    try std.testing.expectEqual(Action.toggle_help, actionFor('?').?.action);
    try std.testing.expectEqual(Action.dismiss_help, actionFor(KEY_ESC).?.action);
    try std.testing.expectEqual(Action.page_down, actionFor(' ').?.action);
    // Unknown keys fall through to no-op, exactly like the old else branch.
    try std.testing.expect(actionFor('z') == null);
    try std.testing.expect(actionFor(0) == null);
    try std.testing.expect(actionFor('Q') == null);
}

test "help overlay: geometry centered and inside viewport, both themes" {
    const themes = [_]layout.Theme{ layout.Theme.dark, layout.Theme.light };
    for (themes) |theme| {
        var cmds: [32]layout.DrawCommand = undefined;
        const n = emitOverlay(&cmds, 1200.0, 900.0, theme);
        try std.testing.expectEqual(3 + 2 * BINDINGS.len, n);
        // Dim covers the viewport.
        try std.testing.expectEqual(layout.DrawCommandKind.fill_rect, cmds[0].kind);
        try std.testing.expectEqual(@as(f32, 1200.0), cmds[0].rect.w);
        try std.testing.expectEqual(@as(f32, 900.0), cmds[0].rect.h);
        // Card uses the theme card color and is centered with margin.
        const card = cmds[1].rect;
        try std.testing.expectEqual(theme.code_bg.r, cmds[1].color.r);
        try std.testing.expectEqual(theme.code_bg.b, cmds[1].color.b);
        try std.testing.expectApproxEqAbs((1200.0 - card.w) * 0.5, card.x, 0.01);
        try std.testing.expectApproxEqAbs((900.0 - card.h) * 0.5, card.y, 0.01);
        try std.testing.expect(card.x >= 16.0 and card.y >= 0.0);
        try std.testing.expect(card.x + card.w <= 1200.0);
        try std.testing.expect(card.y + card.h <= 900.0);
        // Title + every row present; labels use the accent color.
        try std.testing.expect(cmds[2].text.len > 0);
        var row: usize = 3;
        for (BINDINGS) |b| {
            try std.testing.expectEqualStrings(b.label, cmds[row].text);
            try std.testing.expectEqualStrings(b.desc, cmds[row + 1].text);
            try std.testing.expectEqual(theme.accent.r, cmds[row].color.r);
            try std.testing.expectEqual(theme.text.r, cmds[row + 1].color.r);
            // Rows sit inside the card, strictly top-to-bottom.
            try std.testing.expect(cmds[row].rect.x >= card.x);
            try std.testing.expect(cmds[row].rect.x + cmds[row].rect.w <= card.x + card.w + 1.0);
            try std.testing.expect(cmds[row].rect.y >= card.y);
            try std.testing.expect(cmds[row + 1].rect.y == cmds[row].rect.y);
            if (row > 3) try std.testing.expect(cmds[row].rect.y > cmds[row - 2].rect.y);
            row += 2;
        }
    }
}

test "help overlay: tiny viewport clamps the card inside" {
    var cmds: [32]layout.DrawCommand = undefined;
    const n = emitOverlay(&cmds, 200.0, 150.0, layout.Theme.dark);
    try std.testing.expect(n > 3);
    const card = cmds[1].rect;
    try std.testing.expect(card.w <= 200.0 - 32.0 + 0.01);
    try std.testing.expect(card.x >= 0.0);
}

test "help overlay: short buffer truncates rows without overflow" {
    var cmds: [5]layout.DrawCommand = undefined;
    const n = emitOverlay(&cmds, 1200.0, 900.0, layout.Theme.dark);
    try std.testing.expectEqual(@as(usize, 5), n);
}
