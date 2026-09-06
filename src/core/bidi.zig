const std = @import("std");

/// Paragraph base-direction detection (issue #50): the Unicode bidi rule
/// P2/P3 reduced to "first strong directional character wins", over a
/// tiny range table — no ICU, no tables in the binary beyond a few
/// comparisons, zero allocations, pure slice scan.
///
/// Coverage is deliberately narrow: Hebrew + Arabic-family scripts
/// (the issue's scope) on the RTL side, and the major LTR scripts on the
/// other. Unlisted scripts (e.g. Thaana beyond the Arabic-Supplement
/// span, historic RTL scripts) scan as neutral: a paragraph starting in
/// one still resolves correctly as soon as ANY listed strong character
/// appears, and all-neutral text defaults to LTR exactly like today.
pub const Direction = enum { ltr, rtl };

/// A strong directional class found while scanning, in order.
pub const Strong = enum { l, r };

fn strongOf(codepoint: u21) ?Strong {
    // ASCII fast lane: letters are strong-LTR; everything else
    // (digits, spaces, markdown markers like `#`, `>`, `-`) is
    // weak/neutral and skipped by the rule.
    if (codepoint < 0x80) {
        if ((codepoint >= 'A' and codepoint <= 'Z') or
            (codepoint >= 'a' and codepoint <= 'z')) return .l;
        return null;
    }
    // RTL: Hebrew, Arabic + supplements. Arabic-Indic digits carve out
    // as neutral (bidi class EN): "42" must not flip a paragraph RTL.
    if (codepoint >= 0x0590 and codepoint <= 0x05FF) return .r;
    if (codepoint >= 0x0600 and codepoint <= 0x08FF) {
        if (codepoint >= 0x0660 and codepoint <= 0x0669) return null;
        if (codepoint >= 0x06F0 and codepoint <= 0x06F9) return null;
        return .r;
    }
    // RTL presentation forms (visual-order legacy text still decodes here).
    if (codepoint >= 0xFB1D and codepoint <= 0xFDFD) return .r;
    if (codepoint >= 0xFE70 and codepoint <= 0xFEFF) return .r;
    // LTR: Latin/Greek/Cyrillic/Armenian blocks, Indic + Thai/Lao,
    // Georgian through NKo, CJK + Hangul + fullwidth forms.
    if (codepoint >= 0x00C0 and codepoint <= 0x058F) return .l;
    if (codepoint >= 0x0900 and codepoint <= 0x0EFF) return .l;
    if (codepoint >= 0x10A0 and codepoint <= 0x1FFF) return .l;
    if (codepoint >= 0x3040 and codepoint <= 0x9FFF) return .l;
    if (codepoint >= 0xAC00 and codepoint <= 0xD7AF) return .l;
    if (codepoint >= 0xFF00 and codepoint <= 0xFFEF) return .l;
    return null;
}

/// First strong directional character in logical order, or null when the
/// text holds none (neutral-only: digits, punctuation, spaces).
/// Outlined: called from every flow site, but the loop body stays in one
/// place (binary budget); scans exit at the first strong character.
pub noinline fn firstStrong(text: []const u8) ?Strong {
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c < 0x80) {
            if (c >= 'A' and c <= 'Z') return .l;
            if (c >= 'a' and c <= 'z') return .l;
            i += 1;
            continue;
        }
        var cp: u21 = 0xFFFD;
        var adv: usize = 1;
        if ((c & 0xE0) == 0xC0 and i + 1 < text.len) {
            cp = (@as(u21, c & 0x1F) << 6) | (text[i + 1] & 0x3F);
            adv = 2;
        } else if ((c & 0xF0) == 0xE0 and i + 2 < text.len) {
            cp = (@as(u21, c & 0x0F) << 12) |
                (@as(u21, text[i + 1] & 0x3F) << 6) |
                (text[i + 2] & 0x3F);
            adv = 3;
        } else if ((c & 0xF8) == 0xF0 and i + 3 < text.len) {
            cp = (@as(u21, c & 0x07) << 18) |
                (@as(u21, text[i + 1] & 0x3F) << 12) |
                (@as(u21, text[i + 2] & 0x3F) << 6) |
                (text[i + 3] & 0x3F);
            adv = 4;
        }
        if (strongOf(cp)) |s| return s;
        i += adv;
    }
    return null;
}

/// Paragraph base direction: first strong character wins, default LTR.
pub fn baseDirection(text: []const u8) Direction {
    if (firstStrong(text)) |s| {
        return if (s == .r) .rtl else .ltr;
    }
    return .ltr;
}

test "bidi: hebrew and arabic paragraphs resolve rtl" {
    try std.testing.expectEqual(Direction.rtl, baseDirection("שלום עולם"));
    try std.testing.expectEqual(Direction.rtl, baseDirection("مرحبا بالعالم"));
    // Leading neutrals (spaces, digits, markdown markers) are skipped.
    try std.testing.expectEqual(Direction.rtl, baseDirection("  123 שלום"));
    try std.testing.expectEqual(Direction.rtl, baseDirection("# כותרת"));
    try std.testing.expectEqual(Direction.rtl, baseDirection("> مرحبا"));
    try std.testing.expectEqual(Direction.rtl, baseDirection("- [ ] שלום"));
}

test "bidi: latin-first and neutral-only text stays ltr" {
    try std.testing.expectEqual(Direction.ltr, baseDirection("Hello world"));
    try std.testing.expectEqual(Direction.ltr, baseDirection("Hello שלום"));
    try std.testing.expectEqual(Direction.ltr, baseDirection(""));
    try std.testing.expectEqual(Direction.ltr, baseDirection("123 ... ---"));
    try std.testing.expectEqual(Direction.ltr, baseDirection("# Heading 1"));
    try std.testing.expectEqual(Direction.ltr, baseDirection("日本語テスト"));
    try std.testing.expectEqual(Direction.ltr, baseDirection("Ελληνικά"));
    try std.testing.expectEqual(Direction.ltr, baseDirection("Привет"));
}

test "bidi: rtl-first mixed lines resolve rtl" {
    try std.testing.expectEqual(Direction.rtl, baseDirection("שלום hello"));
    try std.testing.expectEqual(Direction.rtl, baseDirection("مرحبا 123 hello"));
    // Presentation forms and Arabic-Supplement letters count as strong.
    try std.testing.expectEqual(Direction.rtl, baseDirection("ﺷﻠﻮﻡ"));
    // Arabic-Indic digits are weak: skipped, never decisive alone.
    try std.testing.expectEqual(Direction.ltr, baseDirection("٤٢"));
    try std.testing.expectEqual(Direction.rtl, baseDirection("٤٢ שלום"));
    // Invalid UTF-8 never panics and never resolves RTL by itself.
    try std.testing.expectEqual(Direction.ltr, baseDirection("\xFF\xFE invalid"));
    try std.testing.expectEqual(Direction.rtl, baseDirection("\xFF שלום"));
}
