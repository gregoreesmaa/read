const std = @import("std");

// Math-island detection for ZaTeX rendering (LaTeX math plugin).
//
// Host-side delimiter scanning: ZaTeX takes raw TeX and owns layout, while
// the reader owns finding math islands in Markdown text (see ZaTeX
// docs/parity.md "Math-island detection is host-side"). Grammar is
// KaTeX-auto-render-compatible:
//
//   $...$     inline math. Currency guard: the opener must not be followed
//             by whitespace, the closer must not be preceded by whitespace
//             and must not be followed by a digit (`$100`, `$5.99`, `$ `
//             stay literal). Escaped `\$` stays literal. Single-line only.
//   $$...$$   display math, single line (multi-line display uses fences).
//   $$...$$   display math, single line (multi-line display uses fences).
//
// Backslash forms are deliberately NOT islands: CommonMark gives the
// backslash escapes precedence (pinned by ex 12 of the file-driven
// conformance suite), so paren and bracket forms stay literal text.
//
// Content must hold a non-space byte; unclosed delimiters stay literal.
// Code spans mask islands: the collector below is code-span-unaware by
// design (zero coupling); callers drop islands overlapping code spans via
// `overlapsCodeSpan` (which borrows the parser's matched-length closer).
// Zero heap allocations throughout: every function borrows the caller's
// line slice and writes islands into a caller-owned buffer.

pub const IslandKind = enum { inline_math, display_math };

pub const Island = struct {
    kind: IslandKind,
    /// Absolute-in-line offsets: [open_start, close_end) is the whole
    /// island including delimiters; [content_start, content_end) is the
    /// raw TeX fed to ZaTeX.
    open_start: usize,
    content_start: usize,
    content_end: usize,
    close_end: usize,
};

/// Interval half of an island for masking scans (emphasis pairing,
/// link formation): delimiters on opposite sides of an island never meet.
pub const Mask = struct {
    start: usize,
    end: usize,
};

pub fn islandMask(island: Island) Mask {
    return .{ .start = island.open_start, .end = island.close_end };
}

fn isSpaceByte(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0C;
}

fn isDigitByte(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn hasNonSpace(s: []const u8) bool {
    for (s) |c| {
        if (!isSpaceByte(c)) return true;
    }
    return false;
}

/// Island opening exactly at `line[i]`, or null. `$$` wins over `$`.
/// Pure: no code-span knowledge (see `overlapsCodeSpan`).
pub fn islandAt(line: []const u8, i: usize) ?Island {
    if (i >= line.len) return null;
    const c = line[i];
    if (c == '$') {
        if (i + 1 < line.len and line[i + 1] == '$') {
            // Display: next `$$` on this line closes (single-line v1).
            var j = i + 2;
            while (j + 1 < line.len) {
                if (line[j] == '$' and line[j + 1] == '$') {
                    if (hasNonSpace(line[i + 2 .. j])) {
                        return .{
                            .kind = .display_math,
                            .open_start = i,
                            .content_start = i + 2,
                            .content_end = j,
                            .close_end = j + 2,
                        };
                    }
                    return null;
                }
                j += 1;
            }
            return null;
        }
        // Inline: opener must not be followed by whitespace.
        if (i + 1 >= line.len or isSpaceByte(line[i + 1])) return null;
        var j = i + 1;
        while (j < line.len) {
            if (line[j] == '$') {
                // A `$$` pair never half-closes inline math; skip both.
                if (j + 1 < line.len and line[j + 1] == '$') {
                    j += 2;
                    continue;
                }
                if (j > 0 and isSpaceByte(line[j - 1])) {
                    j += 1;
                    continue;
                }
                if (j + 1 < line.len and isDigitByte(line[j + 1])) {
                    j += 1;
                    continue;
                }
                if (!hasNonSpace(line[i + 1 .. j])) return null;
                return .{
                    .kind = .inline_math,
                    .open_start = i,
                    .content_start = i + 1,
                    .content_end = j,
                    .close_end = j + 1,
                };
            }
            // Newlines never appear in a line slice; backslash escapes do
            // not suppress closers inside math (`\$` is KaTeX `\$`, still
            // math) — only the currency/space guards above reject.
            j += 1;
        }
        return null;
    }
    return null;
}

/// Collect every island on `line` into `out` (document order, capped at
/// `out.len`). Code-span-unaware: filter with `overlapsCodeSpan`.
pub fn collectIslands(line: []const u8, out: []Island) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < line.len and n < out.len) {
        const c = line[i];
        if (c == '$' or (c == '\\' and i + 1 < line.len and (line[i + 1] == '(' or line[i + 1] == '['))) {
            if (islandAt(line, i)) |isl| {
                out[n] = isl;
                n += 1;
                i = isl.close_end;
                continue;
            }
        }
        i += 1;
    }
    return n;
}

/// Cheap gate for the inline fast path: true when `line` holds at least
/// one island opener with a valid closer. May over-accept inside code
/// spans (the full parse still drops those); it never accepts currency
/// (`$100`), bare `$`, or unclosed delimiters, so price lines stay fast.
pub fn hasMathIsland(line: []const u8) bool {
    var buf: [1]Island = undefined;
    return collectIslands(line, &buf) > 0;
}

/// True when the byte range [start, end) overlaps a fenced-code-style
/// backtick code span. The caller walks openers with its own
/// matched-length closer; this helper answers one candidate range so the
/// parser keeps owning code-span rules.
pub fn rangeInSpan(start: usize, end: usize, span_start: usize, span_end: usize) bool {
    return start < span_end and end > span_start;
}

/// Fenced math aliases: exact info-string tokens routed to ZaTeX
/// (`math`, plus the `tex`/`latex`/`katex` spellings from the async
/// plugin spec's shared math slot). Case-sensitive like the fence
/// registry; unknown tokens stay code blocks.
pub fn isMathFenceToken(token: []const u8) bool {
    if (token.len == 0) return false;
    if (std.mem.eql(u8, token, "math")) return true;
    if (std.mem.eql(u8, token, "tex")) return true;
    if (std.mem.eql(u8, token, "latex")) return true;
    if (std.mem.eql(u8, token, "katex")) return true;
    return false;
}

/// Raw TeX of a whole-island slice (as emitted in span text): re-detects
/// the opener at byte 0 and returns the content between the delimiters.
/// Null when the slice is not exactly one island (defensive; the parser
/// only emits whole islands, so this never fires on its output).
pub fn stripIsland(island: []const u8) ?[]const u8 {
    const isl = islandAt(island, 0) orelse return null;
    if (isl.open_start != 0 or isl.close_end != island.len) return null;
    return island[isl.content_start..isl.content_end];
}

/// Display-math block content when `line` consists solely of one display
/// island (leading/trailing whitespace allowed): the raw TeX between the
/// delimiters. Null otherwise (embedded `$$` in prose stays literal in
/// v1; inline islands handle in-text formulae).
pub fn displayLineContent(line: []const u8) ?[]const u8 {
    var s: usize = 0;
    while (s < line.len and (line[s] == ' ' or line[s] == '\t')) : (s += 1) {}
    var e = line.len;
    while (e > s and (line[e - 1] == ' ' or line[e - 1] == '\t')) : (e -= 1) {}
    if (s >= e) return null;
    const isl = islandAt(line[s..e], 0) orelse return null;
    if (isl.kind != .display_math) return null;
    if (isl.open_start != 0 or isl.close_end != e - s) return null;
    return line[s + isl.content_start .. s + isl.content_end];
}

test "math: inline guards (currency, spaces, unclosed)" {
    var buf: [4]Island = undefined;
    // Plain inline island.
    var n = collectIslands("Einstein: $E=mc^2$ rocks", &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(IslandKind.inline_math, buf[0].kind);
    try std.testing.expectEqualStrings("E=mc^2", "Einstein: $E=mc^2$ rocks"[buf[0].content_start..buf[0].content_end]);
    // Currency stays literal.
    try std.testing.expectEqual(@as(usize, 0), collectIslands("costs $100 and $5.99 today", &buf));
    try std.testing.expectEqual(@as(usize, 0), collectIslands("$ alone, $  spaced, $x y", &buf));
    // Closer followed by digit stays literal; valid closer later wins.
    n = collectIslands("$a$5 and $b$", &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("a$5 and $b", "$a$5 and $b$"[buf[0].content_start..buf[0].content_end]);
    // Unclosed stays literal.
    try std.testing.expectEqual(@as(usize, 0), collectIslands("half $x + 1", &buf));
    try std.testing.expect(!hasMathIsland("pay $100 now"));
    try std.testing.expect(hasMathIsland("see $x$ here"));
}

test "math: display $$ islands; backslash forms stay literal" {
    var buf: [4]Island = undefined;
    var n = collectIslands("$$x + y$$ done", &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(IslandKind.display_math, buf[0].kind);
    try std.testing.expectEqualStrings("x + y", "$$x + y$$ done"[buf[0].content_start..buf[0].content_end]);
    // CommonMark escape precedence: paren/bracket forms never form islands.
    n = collectIslands("see \\(x^2\\) and \\[y^2\\] end", &buf);
    try std.testing.expectEqual(@as(usize, 0), n);
    // Blank content stays literal.
    try std.testing.expectEqual(@as(usize, 0), collectIslands("$$  $$", &buf));
    try std.testing.expectEqual(@as(usize, 0), collectIslands("$ $", &buf));
}

test "math: fence tokens and display lines" {
    try std.testing.expect(isMathFenceToken("math"));
    try std.testing.expect(isMathFenceToken("tex"));
    try std.testing.expect(isMathFenceToken("latex"));
    try std.testing.expect(isMathFenceToken("katex"));
    try std.testing.expect(!isMathFenceToken("mermaid"));
    try std.testing.expect(!isMathFenceToken("Math"));
    try std.testing.expect(!isMathFenceToken(""));
    try std.testing.expect(!isMathFenceToken("mathematics"));
    try std.testing.expectEqualStrings("x^2", displayLineContent("  $$x^2$$  ").?);
    try std.testing.expect(displayLineContent("\\[y\\]") == null);
    try std.testing.expect(displayLineContent("$x$") == null);
    try std.testing.expect(displayLineContent("a $$x$$ b") == null);
    try std.testing.expect(displayLineContent("$$x$$ tail") == null);
    try std.testing.expect(displayLineContent("$$open") == null);
}
