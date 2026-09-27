const std = @import("std");
const simd = @import("hot");

// Math-island detection for ZaTeX rendering (LaTeX math plugin).
//
// Host-side delimiter scanning: ZaTeX takes raw TeX and owns layout, while
// the reader owns finding math islands in Markdown text (see ZaTeX
// docs/parity.md "Math-island detection is host-side"). No engine helper
// exists by upstream decision (zatex#277: deliberately no zatex_detect /
// zatex_scan entry — detection stays host-owned), so the canonical guard
// layer from ZaTeX docs/delimiter-scan.md §2 is mirrored locally for the
// host's $-only scope, with conformance pinned by the guard-vector tests
// below (provenance: packages/zatex/goldens/delimiter_vectors.json).
// Grammar is KaTeX-auto-render-compatible with four deliberate host
// deviations (documented, pinned by tests — never "fixed" to match):
//
//   $...$     inline math. G-open (canonical): `$` glued to a following
//             digit (or `.` plus a digit) opens prices, never math
//             (`$0.00`, `$.99` never open); a price opener is rejected
//             and the scan continues past it, so a later `$x$` still
//             islands (D4, no orphaning). Escaped `\$` stays literal.
//             Space guards (D1): the opener must not be followed by
//             whitespace, the closer must not be preceded by whitespace.
//             A closer followed by a digit extends the scan to a later
//             closer (D2: `$a$5 and $b$` islands as `a$5 and $b`);
//             unclosed delimiters stay literal. Single-line only.
//   $$...$$   display math, whole-line single-line islands center as
//             blocks (displayLineContent); multi-line `$$` opener/closer
//             line pairs form display blocks (displayBlock below).
//
// Normalization owner (issue #374): the HOST normalizes, once, at the
// engine-call boundary (src/platform/macos_zatex.m, ASCII fast path plus
// NSString NFC for non-ASCII) — never at island parse, never per frame.
// The engine performs no normalization (upstream issue #265,
// docs/unicode.md: NFC and NFD are different inputs and lay out
// differently), so logically identical input must reach it as identical
// bytes. Full NFC tables would cost ~100KB in the ship binary and are
// deliberately NOT carried here (AGENTS.md §5): the platform's own
// normalizer owns the table. isAsciiOnly below is the shared fast-path
// predicate (pinned by test); the ObjC boundary mirrors it.
//
// Canonical rules adopted:
//
//   $...$     inline math. G-open: `$` glued to a following digit (or `.`
//             plus a digit) opens prices, never math (`$0.00`, `$.99`
//             never open). Escaped `\$` never opens.
//   $$...$$   display math, single line (multi-line display uses fences).
//             An opener glued to a preceding `\` stays literal.
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
            // G-display/escape (canonical): an opener glued to `\`
            // stays literal text, never an island.
            if (i > 0 and line[i - 1] == '\\') return null;
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
        // Inline: opener must not be followed by whitespace (D1).
        if (i + 1 >= line.len or isSpaceByte(line[i + 1])) return null;
        // G-open (canonical): `$` glued to a following digit (or `.`
        // plus a digit) opens prices, never math. Escaped `\$` never
        // opens either. Both reject the opener and rescan past it (D4:
        // no orphaning — a later `$x$` still islands, unlike the
        // canonical filter; documented, pinned below).
        if (isDigitByte(line[i + 1]) or
            (line[i + 1] == '.' and i + 2 < line.len and isDigitByte(line[i + 2])) or
            (i > 0 and line[i - 1] == '\\')) return null;
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
            // not suppress closers inside math (future KaTeX-parity work:
            // findEndOfMath skips `\` + next) — only the guards above
            // reject (D1/D2/D4).
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
        if (line[i] == '$') {
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

/// Fenced math: only the exact `math` info-string token routes to ZaTeX.
/// The `tex`/`latex`/`katex` spellings stay LaTeX syntax-highlighted code
/// blocks (highlight.Lang.latex), never plugin renders. Case-sensitive
/// like the fence registry; unknown tokens stay code blocks.
pub fn isMathFenceToken(token: []const u8) bool {
    if (token.len == 0) return false;
    if (std.mem.eql(u8, token, "math")) return true;
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

/// True when every byte of `s` is ASCII. Fast-path predicate for the NFC
/// handoff (issue #374): ASCII bytes are already NFC, so the engine-call
/// boundary skips normalization zero-copy exactly when this holds. The
/// ObjC boundary mirrors this loop; the two are pinned by the same test.
pub fn isAsciiOnly(s: []const u8) bool {
    for (s) |c| {
        if (c >= 0x80) return false;
    }
    return true;
}

/// Multiline display-math blocks (issue #373): a `$$` opener line through
/// a `$$` closer line, each trimmed of surrounding whitespace. The opener
/// starts with `$$` and holds no closing `$$` (whole-line single-line
/// `$$...$$` stays on displayLineContent); returns the byte offset just
/// past the opener within the trimmed line. Null otherwise.
pub fn displayBlockOpener(line: []const u8) ?usize {
    var s: usize = 0;
    while (s < line.len and (line[s] == ' ' or line[s] == '\t' or line[s] == '\r')) : (s += 1) {}
    var e = line.len;
    while (e > s and (line[e - 1] == ' ' or line[e - 1] == '\t' or line[e - 1] == '\r')) : (e -= 1) {}
    if (e - s < 2 or line[s] != '$' or line[s + 1] != '$') return null;
    if (std.mem.indexOf(u8, line[s + 2 .. e], "$$") != null) return null;
    return s + 2;
}

/// First `$$` in the trimmed line, as its byte offset: content before it
/// is the block tail. A `$$`-free line is a middle line (the whole line is
/// content). Like fences, the first `$$` always closes.
pub fn displayBlockCloser(line: []const u8) ?usize {
    var s: usize = 0;
    while (s < line.len and (line[s] == ' ' or line[s] == '\t' or line[s] == '\r')) : (s += 1) {}
    var e = line.len;
    while (e > s and (line[e - 1] == ' ' or line[e - 1] == '\t' or line[e - 1] == '\r')) : (e -= 1) {}
    if (e - s < 2) return null;
    const rel = std.mem.indexOf(u8, line[s..e], "$$") orelse return null;
    return s + rel;
}

/// A multiline display block opening at scan line `open_idx`: the opener
/// line plus following lines through the first closer line. Middle and
/// closer lines must be plain paragraph text (blank lines, fences, setext
/// underlines, and headings never belong to a block); every joint must be
/// one document newline (`\n`, tolerating `\r\n`) so the TeX below borrows
/// the document bytes zero-copy. Returns the closer index, or null when
/// the block never closes (stays literal text).
pub fn displayBlockClose(doc: []const u8, lines: []const simd.Line, open_idx: usize) ?usize {
    if (open_idx >= lines.len) return null;
    if (lines[open_idx].block_type != .paragraph) return null;
    const open_raw = doc[lines[open_idx].offset..][0..lines[open_idx].len];
    if (displayBlockOpener(open_raw) == null) return null;
    var j = open_idx + 1;
    while (j < lines.len) : (j += 1) {
        if (lines[j].block_type != .paragraph) return null;
        // Contiguity: the joint is exactly the newline the scan split on.
        const prev = lines[j - 1];
        const joint = lines[j].offset - (prev.offset + prev.len);
        if (joint < 1 or joint > 2) return null;
        if (doc[prev.offset + prev.len] == '\r') {
            if (joint != 2 or doc[prev.offset + prev.len + 1] != '\n') return null;
        } else if (joint != 1 or doc[prev.offset + prev.len] != '\n') return null;
        const raw = doc[lines[j].offset..][0..lines[j].len];
        if (displayBlockCloser(raw) != null) return j;
    }
    return null;
}

/// Raw TeX of the block `open_idx..close_idx`: the document span from just
/// past the opener to just before the closer, newlines included (TeX
/// treats them as spaces). Borrowed from `doc` — zero-copy, zero
/// allocation, lifetime of the document. Null with no non-space content.
pub fn displayBlockTex(
    doc: []const u8,
    lines: []const simd.Line,
    open_idx: usize,
    close_idx: usize,
) ?[]const u8 {
    if (open_idx >= close_idx or close_idx >= lines.len) return null;
    const open_raw = doc[lines[open_idx].offset..][0..lines[open_idx].len];
    const after_open = displayBlockOpener(open_raw) orelse return null;
    const close_raw = doc[lines[close_idx].offset..][0..lines[close_idx].len];
    const at_close = displayBlockCloser(close_raw) orelse return null;
    const start = lines[open_idx].offset + after_open;
    const end = lines[close_idx].offset + at_close;
    if (end <= start) return null;
    const tex = doc[start..end];
    if (!hasNonSpace(tex)) return null;
    return tex;
}

/// Fused open..close+tex for the viewport block path: the displayBlockClose
/// scan above with the displayBlockTex derivation folded into the closer
/// arm, so ship emits one pass instead of the close-then-re-parse pair.
/// Step-identical to calling displayBlockClose then displayBlockTex (same
/// opener/closer/contiguity/content checks, no re-parse); the split pair
/// stays for the unit tests below.
pub const DisplayBlock = struct { close_idx: usize, tex: []const u8 };

pub fn displayBlock(doc: []const u8, lines: []const simd.Line, open_idx: usize) ?DisplayBlock {
    if (open_idx >= lines.len) return null;
    if (lines[open_idx].block_type != .paragraph) return null;
    const open_raw = doc[lines[open_idx].offset..][0..lines[open_idx].len];
    const after_open = displayBlockOpener(open_raw) orelse return null;
    var j = open_idx + 1;
    while (j < lines.len) : (j += 1) {
        if (lines[j].block_type != .paragraph) return null;
        // Contiguity: the joint is exactly the newline the scan split on.
        const prev = lines[j - 1];
        const joint = lines[j].offset - (prev.offset + prev.len);
        if (joint < 1 or joint > 2) return null;
        if (doc[prev.offset + prev.len] == '\r') {
            if (joint != 2 or doc[prev.offset + prev.len + 1] != '\n') return null;
        } else if (joint != 1 or doc[prev.offset + prev.len] != '\n') return null;
        const raw = doc[lines[j].offset..][0..lines[j].len];
        if (displayBlockCloser(raw)) |at_close| {
            const start = lines[open_idx].offset + after_open;
            const end = lines[j].offset + at_close;
            if (end <= start) return null;
            const tex = doc[start..end];
            if (!hasNonSpace(tex)) return null;
            return .{ .close_idx = j, .tex = tex };
        }
    }
    return null;
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

test "math: guard vectors (issue #379, zatex delimiter_vectors.json guards:true)" {
    // Host behavior on the upstream conformance vectors ($-only scope,
    // D3): prices never open (G-open), escapes never open, display takes
    // no currency guards. D2/D4 deviations pinned explicitly: the
    // canonical filter yields `y` / nothing where the host yields
    // `x$2 or $y` / `$x$`.
    var buf: [4]Island = undefined;
    try std.testing.expectEqual(@as(usize, 0), collectIslands("$100 and $200", &buf));
    var n = collectIslands("pay $0.00 and $x$ now", &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("x", "pay $0.00 and $x$ now"[buf[0].content_start..buf[0].content_end]);
    n = collectIslands("only $.99 or $x$ ok", &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("x", "only $.99 or $x$ ok"[buf[0].content_start..buf[0].content_end]);
    n = collectIslands("take $x$2 or $y$", &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("x$2 or $y", "take $x$2 or $y$"[buf[0].content_start..buf[0].content_end]);
    n = collectIslands("let $x^2$ and $a_1$ be", &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("x^2", "let $x^2$ and $a_1$ be"[buf[0].content_start..buf[0].content_end]);
    try std.testing.expectEqualStrings("a_1", "let $x^2$ and $a_1$ be"[buf[1].content_start..buf[1].content_end]);
    n = collectIslands("big $$x^2$$ and $$5$$ ok", &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(IslandKind.display_math, buf[0].kind);
    try std.testing.expectEqual(IslandKind.display_math, buf[1].kind);
    try std.testing.expectEqual(@as(usize, 0), collectIslands("owe $5 today", &buf));
    // Escaped openers stay literal; the later `$x$` still islands.
    n = collectIslands("a \\$b\\$ c $x$ d", &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("x", "a \\$b\\$ c $x$ d"[buf[0].content_start..buf[0].content_end]);
    try std.testing.expectEqual(@as(usize, 0), collectIslands("\\$x\\$", &buf));
    try std.testing.expectEqual(@as(usize, 0), collectIslands("a \\$$x$$ b", &buf));
    // Backslash forms stay literal (D3); the `$b$` still islands.
    n = collectIslands("see \\(a\\) plus $b$ end", &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("b", "see \\(a\\) plus $b$ end"[buf[0].content_start..buf[0].content_end]);
}

test "math: fence tokens and display lines" {
    try std.testing.expect(isMathFenceToken("math"));
    // tex/latex/katex are highlighted code, never plugin renders.
    try std.testing.expect(!isMathFenceToken("tex"));
    try std.testing.expect(!isMathFenceToken("latex"));
    try std.testing.expect(!isMathFenceToken("katex"));
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

test "math: ascii fast-path predicate for the NFC handoff (issue #374)" {
    try std.testing.expect(isAsciiOnly("E=mc^2"));
    try std.testing.expect(isAsciiOnly(""));
    try std.testing.expect(isAsciiOnly("$$\\frac{a}{b}$$"));
    // Any non-ASCII byte needs the platform NFC pass.
    try std.testing.expect(!isAsciiOnly("caf\xc3\xa9"));
    try std.testing.expect(!isAsciiOnly("e\xcc\x81"));
    try std.testing.expect(!isAsciiOnly("\xff"));
}

test "math: NFC-vs-NFD pin (issue #374)" {
    // é precomposed (NFC, U+00E9) vs e + combining acute (NFD): same
    // logical character, DIFFERENT bytes. The engine lays them out
    // differently (upstream #265: 1 run/1 glyph vs 2 runs/2 glyphs), so
    // the host must converge them to one form before the engine call —
    // owner: host, at the engine-call boundary (see header). This test
    // pins the divergence the handoff exists to prevent: if these two
    // ever compared equal, the normalization decision would be moot.
    const nfc = "caf\xc3\xa9";
    const nfd = "cafe\xcc\x81";
    try std.testing.expect(!std.mem.eql(u8, nfc, nfd));
    try std.testing.expect(!isAsciiOnly(nfc));
    try std.testing.expect(!isAsciiOnly(nfd));
    // Both are non-empty, non-space island contents either way: the
    // guards below must agree so normalization (not detection) is the
    // only thing standing between the two code paths.
    try std.testing.expect(hasNonSpace(nfc));
    try std.testing.expect(hasNonSpace(nfd));
}

test "math: multiline display blocks open/close (issue #373)" {
    // Bare opener, opener with head text, indented opener.
    try std.testing.expectEqual(@as(?usize, 2), displayBlockOpener("$$"));
    try std.testing.expectEqual(@as(?usize, 2), displayBlockOpener("$$ open"));
    try std.testing.expectEqual(@as(?usize, 4), displayBlockOpener("  $$"));
    // Whole-line single-line islands are NOT openers (old path owns them).
    try std.testing.expect(displayBlockOpener("$$x$$") == null);
    try std.testing.expect(displayBlockOpener("$$x$$ tail") == null);
    try std.testing.expect(displayBlockOpener("a $$x$$ b") == null);
    try std.testing.expect(displayBlockOpener("$x$") == null);
    try std.testing.expect(displayBlockOpener("") == null);
    // Closer is the first `$$`: bare, tailed, and mid-line forms.
    try std.testing.expectEqual(@as(?usize, 0), displayBlockCloser("$$"));
    try std.testing.expectEqual(@as(?usize, 6), displayBlockCloser("close $$"));
    try std.testing.expectEqual(@as(?usize, 1), displayBlockCloser("x$$y$$"));
    try std.testing.expect(displayBlockCloser("no closer") == null);
    try std.testing.expect(displayBlockCloser("") == null);
}

test "math: multiline display block scan borrows document bytes (issue #373)" {
    const doc = "para\n\n$$\n\\frac{a}{b}\n$$\n\nafter\n";
    var lines: [16]simd.Line = undefined;
    var fence: simd.FenceState = .{};
    const n = simd.scanLines(doc, &lines, &fence);
    // opener at 2, closer at 4.
    const close = displayBlockClose(doc, lines[0..n], 2).?;
    try std.testing.expectEqual(@as(usize, 4), close);
    try std.testing.expectEqualStrings("\n\\frac{a}{b}\n", displayBlockTex(doc, lines[0..n], 2, close).?);
    // Single-line islands never open blocks; unclosed openers stay literal.
    try std.testing.expect(displayBlockClose(doc, lines[0..n], 0) == null);
    const doc2 = "$$\nnever closes\nstill open\n";
    var lines2: [8]simd.Line = undefined;
    var fence2: simd.FenceState = .{};
    const n2 = simd.scanLines(doc2, &lines2, &fence2);
    try std.testing.expect(displayBlockClose(doc2, lines2[0..n2], 0) == null);
    // Blank line inside aborts the block (stays literal).
    const doc3 = "$$\nbody\n\n$$\n";
    var lines3: [8]simd.Line = undefined;
    var fence3: simd.FenceState = .{};
    const n3 = simd.scanLines(doc3, &lines3, &fence3);
    try std.testing.expect(displayBlockClose(doc3, lines3[0..n3], 0) == null);
    // Blank-content block borrows nothing.
    const doc4 = "$$\n$$\n";
    var lines4: [8]simd.Line = undefined;
    var fence4: simd.FenceState = .{};
    const n4 = simd.scanLines(doc4, &lines4, &fence4);
    const c4 = displayBlockClose(doc4, lines4[0..n4], 0).?;
    try std.testing.expect(displayBlockTex(doc4, lines4[0..n4], 0, c4) == null);
}
