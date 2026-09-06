const std = @import("std");
const simd = @import("simd.zig");

pub const SpanStyle = packed struct {
    bold: bool = false,
    italic: bool = false,
    code: bool = false,
    strikethrough: bool = false,
    link: bool = false,
    heading: bool = false,
    image: bool = false,
    autolink: bool = false,
};

pub const InlineSpan = struct {
    text: []const u8,
    style: SpanStyle,
    link_target: ?[]const u8 = null,
};

pub fn isAsciiPunct(ch: u8) bool {
    return switch (ch) {
        '!', '"', '#', '$', '%', '&', '\'', '(', ')', '*', '+', ',', '-', '.', '/', ':', ';', '<', '=', '>', '?', '@', '[', '\\', ']', '^', '_', '`', '{', '|', '}', '~' => true,
        else => false,
    };
}

/// Email half of `<...>` autolink detection, shared by both inline passes
/// (parseInlines / parseInlinesWithDefs): `user@domain` with no spaces.
/// One non-inline copy; the two scans inside stay `inline` via findByte.
fn isEmailAutolink(inner: []const u8) bool {
    return simd.findByte(inner, 0, '@') != null and simd.findByte(inner, 0, ' ') == null;
}

/// Closing run for a code span opened with `run_len` backticks starting at
/// `from` (index just past the opener). Only a run of exactly `run_len`
/// closes; shorter/longer runs are content (so `` \ `` yields "`").
/// Returns content bounds plus the index past the closer.
fn codeSpanClose(line: []const u8, from: usize, run_len: usize) ?struct { start: usize, end: usize, close_end: usize } {
    var p = from;
    while (p < line.len) {
        if (line[p] != '`') {
            p += 1;
            continue;
        }
        var q = p;
        while (q < line.len and line[q] == '`') : (q += 1) {}
        if (q - p == run_len) return .{ .start = from, .end = p, .close_end = q };
        p = q;
    }
    return null;
}

/// Strips one leading/trailing space when the content is not all spaces
/// (code spans render `` ` `` as "`", not " ").
fn stripCodeSpan(content: []const u8) []const u8 {
    // Reference code-span normalization: line endings count as spaces for
    // the edge test, and any non-space byte (including the newline itself)
    // defeats the all-spaces exemption.
    const edge = struct {
        fn is(c: u8) bool {
            return c == ' ' or c == '\n';
        }
    }.is;
    if (content.len >= 1 and edge(content[0]) and edge(content[content.len - 1])) {
        for (content) |ch| {
            if (ch != ' ') return if (content.len >= 2) content[1 .. content.len - 1] else content[0..0];
        }
    }
    return content;
}

/// Bracket-balanced `]` search that steps over escapes, nested brackets,
/// and code spans (a `]` inside backticks never closes link text).
fn balancedClose(line: []const u8, from: usize) ?usize {
    var p = from;
    var depth: usize = 0;
    while (p < line.len) {
        const c = line[p];
        if (c == '\\' and p + 1 < line.len) {
            p += 2;
            continue;
        }
        if (c == '`') {
            var run: usize = 0;
            while (p + run < line.len and line[p + run] == '`') : (run += 1) {}
            if (codeSpanClose(line, p + run, run)) |cs| {
                p = cs.close_end;
                continue;
            }
            p += 1;
            continue;
        }
        if (c == '[') {
            depth += 1;
        } else if (c == ']') {
            if (depth == 0) return p;
            depth -= 1;
        }
        p += 1;
    }
    return null;
}

/// Title-end scanner lives in simd.zig (shared with reference definitions
/// without an import cycle).
const parseTitleEnd = simd.parseTitleEnd;

/// Parsed `(destination "optional title")` tail of an inline link or image.
/// `dest_start..dest_end` bounds the URL (angle brackets excluded); `close`
/// is the index of the final `)`. Titles are validated but dropped: the
/// reader has no tooltip surface. Returns null when the tail is malformed,
/// in which case the caller must leave the source as literal text.
const LinkTail = struct {
    dest_start: usize,
    dest_end: usize,
    close: usize,
};

/// Whitespace between inline-link parts: the reference spacechar class
/// (space, tab, LF, VT, FF, CR).
fn isTailSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\x0B' or c == '\x0C' or c == '\r';
}

fn parseLinkTail(line: []const u8, paren_open: usize) ?LinkTail {
    if (paren_open >= line.len or line[paren_open] != '(') return null;
    var pos = paren_open + 1;
    while (pos < line.len and isTailSpace(line[pos])) : (pos += 1) {}
    if (pos >= line.len) return null;

    var dest_start: usize = pos;
    var dest_end: usize = pos;
    if (line[pos] == '<') {
        // Angle destination: backslash skips any next byte, newline and a
        // second `<` invalidate, first other `>` closes.
        var end = pos + 1;
        var found = false;
        while (end < line.len) {
            const c = line[end];
            if (c == '\\') {
                end += 2;
                continue;
            }
            if (c == '\n' or c == '<') return null;
            if (c == '>') {
                found = true;
                break;
            }
            end += 1;
        }
        if (!found) return null;
        dest_start = pos + 1;
        dest_end = end;
        pos = end + 1;
    } else {
        // Bare destination: backslash escapes ASCII punctuation (kept raw
        // here, unescaped at render), parens balance to depth 32,
        // whitespace ends the scan. An empty destination is valid.
        var depth: usize = 0;
        var end = pos;
        var ok = false;
        while (end < line.len) {
            const c = line[end];
            if (c == '\\' and end + 1 < line.len and isAsciiPunct(line[end + 1])) {
                end += 2;
                continue;
            } else if (c == '(') {
                depth += 1;
                if (depth > 32) return null;
            } else if (c == ')') {
                if (depth == 0) {
                    ok = true;
                    break;
                }
                depth -= 1;
            } else if (isTailSpace(c)) {
                if (end == pos) return null;
                break;
            }
            end += 1;
        }
        if (end >= line.len or depth != 0) {
            // Ran off the end or left parens unbalanced: valid only when a
            // closer was found (empty `()` hits `ok` with end == pos).
            if (!ok) return null;
        }
        dest_start = pos;
        dest_end = end;
        pos = end;
    }

    while (pos < line.len and isTailSpace(line[pos])) : (pos += 1) {}
    if (pos >= line.len) return null;
    if (line[pos] == ')') return .{ .dest_start = dest_start, .dest_end = dest_end, .close = pos };

    // Optional title ("...", '...', or (...)), validated but dropped.
    const title_end = parseTitleEnd(line, pos, true) orelse return null;
    pos = title_end + 1;

    while (pos < line.len and isTailSpace(line[pos])) : (pos += 1) {}
    if (pos >= line.len or line[pos] != ')') return null;
    return .{ .dest_start = dest_start, .dest_end = dest_end, .close = pos };
}

/// Pending-segment style: positional emphasis union plus threaded strike.
fn segStyle(runs: []const DelimRun, pairs: []const EmPair, pos: usize, strike_holder: SpanStyle) SpanStyle {
    var st = activeStyle(runs, pairs, pos);
    st.strikethrough = strike_holder.strikethrough;
    return st;
}

/// High-speed inline parser for viewport lines.
/// Zero heap allocations: tokens are stored directly into caller's slice.
/// Reference links need document state; use `parseInlinesWithDefs` when a
/// definition table is available (the plain form resolves inline links,
/// code, emphasis, and autolinks only).
///
/// Emphasis uses CommonMark delimiter runs (spec rules 1-10 + principles
/// 13-17): runs are collected with left/right-flanking classes, closers
/// match the nearest eligible opener (odd-rule on current lengths, no
/// crossing of formed pairs), openers consume from the run end and closers
/// from the run start so leftovers nest outside (`***foo***` is em-outside
/// strong-outside per principle 14). Fixed buffers, zero heap allocations.

// ============================================================================
// CommonMark emphasis: delimiter runs + flanking matcher.
// ============================================================================

/// Flanking character classes. Non-ASCII defaults to alphanumeric-like
/// (correct for letters/CJK/emoji); explicit exceptions below cover the
/// whitespace the spec examples need. Punctuation beyond ASCII is added
/// only as the conformance suite demands it.
const FlankClass = enum { ws, punct, other };

fn flankAscii(c: u8) FlankClass {
    if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0C) return .ws;
    if (isAsciiPunct(c)) return .punct;
    return .other;
}

// Unicode General Categories P* and S* (non-ASCII), generated from
// UCD 13.0.0 via Python unicodedata. Binary-searched, zero-alloc;
// ~2.6 KiB. Replaces hand classification for flanking (CommonMark
// "Unicode punctuation character").
const WIDE_PUNCT: []const [2]u21 = &.{
    .{ 0x000A1, 0x000A9 },
    .{ 0x000AB, 0x000AC },
    .{ 0x000AE, 0x000B1 },
    .{ 0x000B4, 0x000B4 },
    .{ 0x000B6, 0x000B8 },
    .{ 0x000BB, 0x000BB },
    .{ 0x000BF, 0x000BF },
    .{ 0x000D7, 0x000D7 },
    .{ 0x000F7, 0x000F7 },
    .{ 0x002C2, 0x002C5 },
    .{ 0x002D2, 0x002DF },
    .{ 0x002E5, 0x002EB },
    .{ 0x002ED, 0x002ED },
    .{ 0x002EF, 0x002FF },
    .{ 0x00375, 0x00375 },
    .{ 0x0037E, 0x0037E },
    .{ 0x00384, 0x00385 },
    .{ 0x00387, 0x00387 },
    .{ 0x003F6, 0x003F6 },
    .{ 0x00482, 0x00482 },
    .{ 0x0055A, 0x0055F },
    .{ 0x00589, 0x0058A },
    .{ 0x0058D, 0x0058F },
    .{ 0x005BE, 0x005BE },
    .{ 0x005C0, 0x005C0 },
    .{ 0x005C3, 0x005C3 },
    .{ 0x005C6, 0x005C6 },
    .{ 0x005F3, 0x005F4 },
    .{ 0x00606, 0x0060F },
    .{ 0x0061B, 0x0061B },
    .{ 0x0061E, 0x0061F },
    .{ 0x0066A, 0x0066D },
    .{ 0x006D4, 0x006D4 },
    .{ 0x006DE, 0x006DE },
    .{ 0x006E9, 0x006E9 },
    .{ 0x006FD, 0x006FE },
    .{ 0x00700, 0x0070D },
    .{ 0x007F6, 0x007F9 },
    .{ 0x007FE, 0x007FF },
    .{ 0x00830, 0x0083E },
    .{ 0x0085E, 0x0085E },
    .{ 0x00964, 0x00965 },
    .{ 0x00970, 0x00970 },
    .{ 0x009F2, 0x009F3 },
    .{ 0x009FA, 0x009FB },
    .{ 0x009FD, 0x009FD },
    .{ 0x00A76, 0x00A76 },
    .{ 0x00AF0, 0x00AF1 },
    .{ 0x00B70, 0x00B70 },
    .{ 0x00BF3, 0x00BFA },
    .{ 0x00C77, 0x00C77 },
    .{ 0x00C7F, 0x00C7F },
    .{ 0x00C84, 0x00C84 },
    .{ 0x00D4F, 0x00D4F },
    .{ 0x00D79, 0x00D79 },
    .{ 0x00DF4, 0x00DF4 },
    .{ 0x00E3F, 0x00E3F },
    .{ 0x00E4F, 0x00E4F },
    .{ 0x00E5A, 0x00E5B },
    .{ 0x00F01, 0x00F17 },
    .{ 0x00F1A, 0x00F1F },
    .{ 0x00F34, 0x00F34 },
    .{ 0x00F36, 0x00F36 },
    .{ 0x00F38, 0x00F38 },
    .{ 0x00F3A, 0x00F3D },
    .{ 0x00F85, 0x00F85 },
    .{ 0x00FBE, 0x00FC5 },
    .{ 0x00FC7, 0x00FCC },
    .{ 0x00FCE, 0x00FDA },
    .{ 0x0104A, 0x0104F },
    .{ 0x0109E, 0x0109F },
    .{ 0x010FB, 0x010FB },
    .{ 0x01360, 0x01368 },
    .{ 0x01390, 0x01399 },
    .{ 0x01400, 0x01400 },
    .{ 0x0166D, 0x0166E },
    .{ 0x0169B, 0x0169C },
    .{ 0x016EB, 0x016ED },
    .{ 0x01735, 0x01736 },
    .{ 0x017D4, 0x017D6 },
    .{ 0x017D8, 0x017DB },
    .{ 0x01800, 0x0180A },
    .{ 0x01940, 0x01940 },
    .{ 0x01944, 0x01945 },
    .{ 0x019DE, 0x019FF },
    .{ 0x01A1E, 0x01A1F },
    .{ 0x01AA0, 0x01AA6 },
    .{ 0x01AA8, 0x01AAD },
    .{ 0x01B5A, 0x01B6A },
    .{ 0x01B74, 0x01B7C },
    .{ 0x01BFC, 0x01BFF },
    .{ 0x01C3B, 0x01C3F },
    .{ 0x01C7E, 0x01C7F },
    .{ 0x01CC0, 0x01CC7 },
    .{ 0x01CD3, 0x01CD3 },
    .{ 0x01FBD, 0x01FBD },
    .{ 0x01FBF, 0x01FC1 },
    .{ 0x01FCD, 0x01FCF },
    .{ 0x01FDD, 0x01FDF },
    .{ 0x01FED, 0x01FEF },
    .{ 0x01FFD, 0x01FFE },
    .{ 0x02010, 0x02027 },
    .{ 0x02030, 0x0205E },
    .{ 0x0207A, 0x0207E },
    .{ 0x0208A, 0x0208E },
    .{ 0x020A0, 0x020BF },
    .{ 0x02100, 0x02101 },
    .{ 0x02103, 0x02106 },
    .{ 0x02108, 0x02109 },
    .{ 0x02114, 0x02114 },
    .{ 0x02116, 0x02118 },
    .{ 0x0211E, 0x02123 },
    .{ 0x02125, 0x02125 },
    .{ 0x02127, 0x02127 },
    .{ 0x02129, 0x02129 },
    .{ 0x0212E, 0x0212E },
    .{ 0x0213A, 0x0213B },
    .{ 0x02140, 0x02144 },
    .{ 0x0214A, 0x0214D },
    .{ 0x0214F, 0x0214F },
    .{ 0x0218A, 0x0218B },
    .{ 0x02190, 0x02426 },
    .{ 0x02440, 0x0244A },
    .{ 0x0249C, 0x024E9 },
    .{ 0x02500, 0x02775 },
    .{ 0x02794, 0x02B73 },
    .{ 0x02B76, 0x02B95 },
    .{ 0x02B97, 0x02BFF },
    .{ 0x02CE5, 0x02CEA },
    .{ 0x02CF9, 0x02CFC },
    .{ 0x02CFE, 0x02CFF },
    .{ 0x02D70, 0x02D70 },
    .{ 0x02E00, 0x02E2E },
    .{ 0x02E30, 0x02E52 },
    .{ 0x02E80, 0x02E99 },
    .{ 0x02E9B, 0x02EF3 },
    .{ 0x02F00, 0x02FD5 },
    .{ 0x02FF0, 0x02FFB },
    .{ 0x03001, 0x03004 },
    .{ 0x03008, 0x03020 },
    .{ 0x03030, 0x03030 },
    .{ 0x03036, 0x03037 },
    .{ 0x0303D, 0x0303F },
    .{ 0x0309B, 0x0309C },
    .{ 0x030A0, 0x030A0 },
    .{ 0x030FB, 0x030FB },
    .{ 0x03190, 0x03191 },
    .{ 0x03196, 0x0319F },
    .{ 0x031C0, 0x031E3 },
    .{ 0x03200, 0x0321E },
    .{ 0x0322A, 0x03247 },
    .{ 0x03250, 0x03250 },
    .{ 0x03260, 0x0327F },
    .{ 0x0328A, 0x032B0 },
    .{ 0x032C0, 0x033FF },
    .{ 0x04DC0, 0x04DFF },
    .{ 0x0A490, 0x0A4C6 },
    .{ 0x0A4FE, 0x0A4FF },
    .{ 0x0A60D, 0x0A60F },
    .{ 0x0A673, 0x0A673 },
    .{ 0x0A67E, 0x0A67E },
    .{ 0x0A6F2, 0x0A6F7 },
    .{ 0x0A700, 0x0A716 },
    .{ 0x0A720, 0x0A721 },
    .{ 0x0A789, 0x0A78A },
    .{ 0x0A828, 0x0A82B },
    .{ 0x0A836, 0x0A839 },
    .{ 0x0A874, 0x0A877 },
    .{ 0x0A8CE, 0x0A8CF },
    .{ 0x0A8F8, 0x0A8FA },
    .{ 0x0A8FC, 0x0A8FC },
    .{ 0x0A92E, 0x0A92F },
    .{ 0x0A95F, 0x0A95F },
    .{ 0x0A9C1, 0x0A9CD },
    .{ 0x0A9DE, 0x0A9DF },
    .{ 0x0AA5C, 0x0AA5F },
    .{ 0x0AA77, 0x0AA79 },
    .{ 0x0AADE, 0x0AADF },
    .{ 0x0AAF0, 0x0AAF1 },
    .{ 0x0AB5B, 0x0AB5B },
    .{ 0x0AB6A, 0x0AB6B },
    .{ 0x0ABEB, 0x0ABEB },
    .{ 0x0FB29, 0x0FB29 },
    .{ 0x0FBB2, 0x0FBC1 },
    .{ 0x0FD3E, 0x0FD3F },
    .{ 0x0FDFC, 0x0FDFD },
    .{ 0x0FE10, 0x0FE19 },
    .{ 0x0FE30, 0x0FE52 },
    .{ 0x0FE54, 0x0FE66 },
    .{ 0x0FE68, 0x0FE6B },
    .{ 0x0FF01, 0x0FF0F },
    .{ 0x0FF1A, 0x0FF20 },
    .{ 0x0FF3B, 0x0FF40 },
    .{ 0x0FF5B, 0x0FF65 },
    .{ 0x0FFE0, 0x0FFE6 },
    .{ 0x0FFE8, 0x0FFEE },
    .{ 0x0FFFC, 0x0FFFD },
    .{ 0x10100, 0x10102 },
    .{ 0x10137, 0x1013F },
    .{ 0x10179, 0x10189 },
    .{ 0x1018C, 0x1018E },
    .{ 0x10190, 0x1019C },
    .{ 0x101A0, 0x101A0 },
    .{ 0x101D0, 0x101FC },
    .{ 0x1039F, 0x1039F },
    .{ 0x103D0, 0x103D0 },
    .{ 0x1056F, 0x1056F },
    .{ 0x10857, 0x10857 },
    .{ 0x10877, 0x10878 },
    .{ 0x1091F, 0x1091F },
    .{ 0x1093F, 0x1093F },
    .{ 0x10A50, 0x10A58 },
    .{ 0x10A7F, 0x10A7F },
    .{ 0x10AC8, 0x10AC8 },
    .{ 0x10AF0, 0x10AF6 },
    .{ 0x10B39, 0x10B3F },
    .{ 0x10B99, 0x10B9C },
    .{ 0x10EAD, 0x10EAD },
    .{ 0x10F55, 0x10F59 },
    .{ 0x11047, 0x1104D },
    .{ 0x110BB, 0x110BC },
    .{ 0x110BE, 0x110C1 },
    .{ 0x11140, 0x11143 },
    .{ 0x11174, 0x11175 },
    .{ 0x111C5, 0x111C8 },
    .{ 0x111CD, 0x111CD },
    .{ 0x111DB, 0x111DB },
    .{ 0x111DD, 0x111DF },
    .{ 0x11238, 0x1123D },
    .{ 0x112A9, 0x112A9 },
    .{ 0x1144B, 0x1144F },
    .{ 0x1145A, 0x1145B },
    .{ 0x1145D, 0x1145D },
    .{ 0x114C6, 0x114C6 },
    .{ 0x115C1, 0x115D7 },
    .{ 0x11641, 0x11643 },
    .{ 0x11660, 0x1166C },
    .{ 0x1173C, 0x1173F },
    .{ 0x1183B, 0x1183B },
    .{ 0x11944, 0x11946 },
    .{ 0x119E2, 0x119E2 },
    .{ 0x11A3F, 0x11A46 },
    .{ 0x11A9A, 0x11A9C },
    .{ 0x11A9E, 0x11AA2 },
    .{ 0x11C41, 0x11C45 },
    .{ 0x11C70, 0x11C71 },
    .{ 0x11EF7, 0x11EF8 },
    .{ 0x11FD5, 0x11FF1 },
    .{ 0x11FFF, 0x11FFF },
    .{ 0x12470, 0x12474 },
    .{ 0x16A6E, 0x16A6F },
    .{ 0x16AF5, 0x16AF5 },
    .{ 0x16B37, 0x16B3F },
    .{ 0x16B44, 0x16B45 },
    .{ 0x16E97, 0x16E9A },
    .{ 0x16FE2, 0x16FE2 },
    .{ 0x1BC9C, 0x1BC9C },
    .{ 0x1BC9F, 0x1BC9F },
    .{ 0x1D000, 0x1D0F5 },
    .{ 0x1D100, 0x1D126 },
    .{ 0x1D129, 0x1D164 },
    .{ 0x1D16A, 0x1D16C },
    .{ 0x1D183, 0x1D184 },
    .{ 0x1D18C, 0x1D1A9 },
    .{ 0x1D1AE, 0x1D1E8 },
    .{ 0x1D200, 0x1D241 },
    .{ 0x1D245, 0x1D245 },
    .{ 0x1D300, 0x1D356 },
    .{ 0x1D6C1, 0x1D6C1 },
    .{ 0x1D6DB, 0x1D6DB },
    .{ 0x1D6FB, 0x1D6FB },
    .{ 0x1D715, 0x1D715 },
    .{ 0x1D735, 0x1D735 },
    .{ 0x1D74F, 0x1D74F },
    .{ 0x1D76F, 0x1D76F },
    .{ 0x1D789, 0x1D789 },
    .{ 0x1D7A9, 0x1D7A9 },
    .{ 0x1D7C3, 0x1D7C3 },
    .{ 0x1D800, 0x1D9FF },
    .{ 0x1DA37, 0x1DA3A },
    .{ 0x1DA6D, 0x1DA74 },
    .{ 0x1DA76, 0x1DA83 },
    .{ 0x1DA85, 0x1DA8B },
    .{ 0x1E14F, 0x1E14F },
    .{ 0x1E2FF, 0x1E2FF },
    .{ 0x1E95E, 0x1E95F },
    .{ 0x1ECAC, 0x1ECAC },
    .{ 0x1ECB0, 0x1ECB0 },
    .{ 0x1ED2E, 0x1ED2E },
    .{ 0x1EEF0, 0x1EEF1 },
    .{ 0x1F000, 0x1F02B },
    .{ 0x1F030, 0x1F093 },
    .{ 0x1F0A0, 0x1F0AE },
    .{ 0x1F0B1, 0x1F0BF },
    .{ 0x1F0C1, 0x1F0CF },
    .{ 0x1F0D1, 0x1F0F5 },
    .{ 0x1F10D, 0x1F1AD },
    .{ 0x1F1E6, 0x1F202 },
    .{ 0x1F210, 0x1F23B },
    .{ 0x1F240, 0x1F248 },
    .{ 0x1F250, 0x1F251 },
    .{ 0x1F260, 0x1F265 },
    .{ 0x1F300, 0x1F6D7 },
    .{ 0x1F6E0, 0x1F6EC },
    .{ 0x1F6F0, 0x1F6FC },
    .{ 0x1F700, 0x1F773 },
    .{ 0x1F780, 0x1F7D8 },
    .{ 0x1F7E0, 0x1F7EB },
    .{ 0x1F800, 0x1F80B },
    .{ 0x1F810, 0x1F847 },
    .{ 0x1F850, 0x1F859 },
    .{ 0x1F860, 0x1F887 },
    .{ 0x1F890, 0x1F8AD },
    .{ 0x1F8B0, 0x1F8B1 },
    .{ 0x1F900, 0x1F978 },
    .{ 0x1F97A, 0x1F9CB },
    .{ 0x1F9CD, 0x1FA53 },
    .{ 0x1FA60, 0x1FA6D },
    .{ 0x1FA70, 0x1FA74 },
    .{ 0x1FA78, 0x1FA7A },
    .{ 0x1FA80, 0x1FA86 },
    .{ 0x1FA90, 0x1FAA8 },
    .{ 0x1FAB0, 0x1FAB6 },
    .{ 0x1FAC0, 0x1FAC2 },
    .{ 0x1FAD0, 0x1FAD6 },
    .{ 0x1FB00, 0x1FB92 },
    .{ 0x1FB94, 0x1FBCA },
};

/// Unicode Zs (non-ASCII) whitespace for flanking.
const WIDE_WS: []const [2]u21 = &.{
    .{ 0x000A0, 0x000A0 },
    .{ 0x01680, 0x01680 },
    .{ 0x02000, 0x0200A },
    .{ 0x0202F, 0x0202F },
    .{ 0x0205F, 0x0205F },
    .{ 0x03000, 0x03000 },
};

fn inRanges(ranges: []const [2]u21, cp: u21) bool {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (cp < ranges[mid][0]) { hi = mid; } else if (cp > ranges[mid][1]) { lo = mid + 1; } else return true;
    }
    return false;
}

fn classBefore(line: []const u8, pos: usize) FlankClass {
    // BOL counts as whitespace for flanking (but never as punctuation):
    // `_foo_` opens here while intraword `_` stays shut.
    if (pos == 0) return .ws;
    var s = pos - 1;
    if (line[s] < 0x80) return flankAscii(line[s]);
    while (s > 0 and (line[s] & 0xC0) == 0x80) : (s -= 1) {}
    const len = std.unicode.utf8ByteSequenceLength(line[s]) catch return .other;
    if (s + len > line.len) return .other;
    const cp = std.unicode.utf8Decode(line[s .. s + len]) catch return .other;
    if (inRanges(WIDE_WS[0..], cp)) return .ws;
    if (inRanges(WIDE_PUNCT[0..], cp)) return .punct;
    return .other;
}

fn classAfter(line: []const u8, pos: usize) FlankClass {
    // EOL counts as whitespace for flanking (symmetric with BOL).
    if (pos >= line.len) return .ws;
    if (line[pos] < 0x80) return flankAscii(line[pos]);
    const len = std.unicode.utf8ByteSequenceLength(line[pos]) catch return .other;
    if (pos + len > line.len) return .other;
    const cp = std.unicode.utf8Decode(line[pos .. pos + len]) catch return .other;
    if (inRanges(WIDE_WS[0..], cp)) return .ws;
    if (inRanges(WIDE_PUNCT[0..], cp)) return .punct;
    return .other;
}

pub const MAX_RUNS = 96;
pub const MAX_PAIRS = 64;

pub const DelimRun = struct {
    pos: usize,
    len: u16,
    star: bool,
    can_open: bool,
    can_close: bool,
    open_rem: u16,
    close_rem: u16,
};

/// Collect `*`/`_` runs, skipping backslash escapes and code spans (rule 17:
/// code groups more tightly than emphasis). Runs past the cap are left
/// literal. Returns run count.
pub fn collectRuns(line: []const u8, runs: []DelimRun) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < line.len and n < runs.len) {
        const c = line[i];
        if (c == '\\' and i + 1 < line.len and isAsciiPunct(line[i + 1])) {
            i += 2;
            continue;
        }
        if (c == '`') {
            var run: usize = 0;
            while (i + run < line.len and line[i + run] == '`') : (run += 1) {}
            if (codeSpanClose(line, i + run, run)) |cs| {
                i = cs.close_end;
                continue;
            }
            // No matching closer: the whole opener run is literal text.
            i += run;
            continue;
        }
        if (c == '*' or c == '_') {
            var j = i + 1;
            while (j < line.len and line[j] == c) : (j += 1) {}
            const before = classBefore(line, i);
            const after = classAfter(line, j);
            const left = after != .ws and (after != .punct or before == .ws or before == .punct);
            const right = before != .ws and (before != .punct or after == .ws or after == .punct);
            var can_open = false;
            var can_close = false;
            if (c == '*') {
                can_open = left;
                can_close = right;
            } else {
                can_open = left and (!right or before == .punct);
                can_close = right and (!left or after == .punct);
            }
            const capped: u16 = @min(j - i, std.math.maxInt(u16));
            runs[n] = .{
                .pos = i,
                .len = capped,
                .star = c == '*',
                .can_open = can_open,
                .can_close = can_close,
                .open_rem = capped,
                .close_rem = capped,
            };
            n += 1;
            i = j;
            continue;
        }
        i += 1;
    }
    return n;
}

pub const EmPair = struct {
    open: usize, // run index
    close: usize, // run index
    open_off: u16, // first consumed delim offset within opener run
    close_off: u16, // first consumed delim offset within closer run
    use: u16,
    strong: bool,
};

fn pairCrosses(pairs: []const EmPair, open: usize, close: usize) bool {
    for (pairs) |p| {
        const a_in = open > p.open and open < p.close;
        const b_in = close > p.open and close < p.close;
        if (a_in != b_in) return true; // principle 15: first span wins
    }
    return false;
}

/// Match closers to nearest eligible openers (principles 15/16, rules 9/10).
/// Returns pair count. Openers consume from the run end, closers from the
/// run start, so leftovers nest outside (principle 14).
pub fn matchRuns(runs: []DelimRun, n: usize, pairs: []EmPair) usize {
    var m: usize = 0;
    var ci: usize = 0;
    while (ci < n and m < pairs.len) : (ci += 1) {
        if (!runs[ci].can_close or runs[ci].close_rem == 0) continue;
        while (runs[ci].close_rem > 0 and m < pairs.len) {
            var oi_opt: ?usize = null;
            var oi = ci;
            while (oi > 0) {
                oi -= 1;
                if (runs[oi].star != runs[ci].star) continue;
                if (!runs[oi].can_open or runs[oi].open_rem == 0) continue;
                const either_both = (runs[ci].can_open and runs[ci].can_close) or
                    (runs[oi].can_open and runs[oi].can_close);
                if (either_both) {
                    const s = @as(u32, runs[oi].open_rem) + runs[ci].close_rem;
                    if (s % 3 == 0 and !((runs[oi].open_rem % 3 == 0) and (runs[ci].close_rem % 3 == 0))) {
                        continue; // odd-rule violation: try an earlier opener
                    }
                }
                if (pairCrosses(pairs[0..m], oi, ci)) continue;
                oi_opt = oi;
                break;
            }
            const found = oi_opt orelse break;
            const use: u16 = if (runs[found].open_rem >= 2 and runs[ci].close_rem >= 2) 2 else 1;
            pairs[m] = .{
                .open = found,
                .close = ci,
                .open_off = runs[found].open_rem - use,
                .close_off = runs[ci].len - runs[ci].close_rem,
                .use = use,
                .strong = use == 2,
            };
            m += 1;
            runs[found].open_rem -= use;
            runs[ci].close_rem -= use;
        }
    }
    return m;
}

/// Bracket/angle intervals that bind tighter than emphasis. A formed
/// link's text brackets fence delimiter matching (interior closers never
/// see outside openers and vice versa: `*[bar*](/url)` stays literal);
/// autolink interiors never hold delimiters at all (`**a<url**>`). This
/// mirrors the link acceptance in parseInlinesWithDefs exactly (same
/// helpers, same order) so pair filtering agrees with emitted link spans.
pub const LinkSeg = struct {
    start: usize, // inclusive (`[`, or `<`)
    end: usize, // exclusive (past `]` or `>`)
    angle: bool, // autolink: interiors hold no runs
};
pub const MAX_LINK_SEGS = 16;

/// One formed inline construct from the single-pass bracket scan:
/// `[text](tail)`, `[text][label]`, `[text][]`, `[text]`, the `![...]`
/// image equivalents, or a `<...>` autolink. `open` is the `[` (or `<`);
/// images remember the `!` via `bang`. Reference matches resolve the URL
/// eagerly into `ref_url`; inline and autolink targets stay slices.
pub const LinkMatch = struct {
    open: usize,
    bang: bool = false,
    image: bool = false,
    autolink: bool = false,
    text_start: usize = 0,
    text_end: usize = 0,
    dest_start: usize = 0,
    dest_end: usize = 0,
    ref_url: ?[]const u8 = null,
    end: usize = 0,
};

/// Reference label `[label]` scan at `pos` (which holds `[`): no unescaped
/// `[`/`]` inside, backslash escapes consumed, 1000 raw characters max.
/// Returns the label slice (empty for `[]`) and the exclusive end past `]`.
pub fn scanRefLabel(line: []const u8, pos: usize) ?struct { label: []const u8, end: usize } {
    if (pos >= line.len or line[pos] != '[') return null;
    var p = pos + 1;
    var length: usize = 0;
    while (p < line.len) {
        const c = line[p];
        if (c == '\\' and p + 1 < line.len and isAsciiPunct(line[p + 1])) {
            p += 2;
            length += 2;
        } else if (c == '[' or c == ']') {
            break;
        } else {
            p += 1;
            length += 1;
        }
        if (length > 1000) return null;
    }
    if (p >= line.len or line[p] != ']') return null;
    return .{ .label = line[pos + 1 .. p], .end = p + 1 };
}

fn isAlphaNumDot(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '.' or c == '+' or c == '-';
}

fn isEmailAtom(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or switch (c) {
        '.', '!', '#', '$', '%', '&', '\'', '*', '+', '/', '=', '?', '^', '_', '`', '{', '|', '}', '~', '-' => true,
        else => false,
    };
}

/// Autolink probe shared with the layout raw-HTML fallback (issue #26):
/// true when `<` at `lt` opens a URI/email autolink.
pub fn isAutolinkAt(line: []const u8, lt: usize) bool {
    if (lt >= line.len or line[lt] != '<') return false;
    return matchAutolink(line, lt) != null;
}

/// Autolink `<...>` end (exclusive past `>`) per the reference scanners:
/// any 2-32 byte `scheme:` (letter-led) plus space/control/`<>`-free body,
/// else the strict email atom pattern. Backslash never escapes here, so
/// `<foo\+@bar...>` stays literal text.
fn matchAutolink(line: []const u8, lt: usize) ?usize {
    const i = lt + 1;
    // URI form: scheme then body.
    if (i < line.len and ((line[i] >= 'a' and line[i] <= 'z') or (line[i] >= 'A' and line[i] <= 'Z'))) {
        var j = i + 1;
        while (j < line.len and isAlphaNumDot(line[j])) : (j += 1) {}
        const scheme_len = j - i;
        if (scheme_len >= 2 and scheme_len <= 32 and j < line.len and line[j] == ':') {
            var k = j + 1;
            while (k < line.len and line[k] != '>' and line[k] > 0x20 and line[k] != '<') : (k += 1) {}
            if (k < line.len and line[k] == '>') return k + 1;
        }
    }
    // Email form: atom+ `@` dotted labels.
    var p = i;
    var atom = false;
    while (p < line.len and isEmailAtom(line[p])) : (p += 1) {
        atom = true;
    }
    if (!atom or p >= line.len or line[p] != '@') return null;
    p += 1;
    var labels: usize = 0;
    while (true) {
        if (p >= line.len or !((line[p] >= 'a' and line[p] <= 'z') or
            (line[p] >= 'A' and line[p] <= 'Z') or (line[p] >= '0' and line[p] <= '9'))) return null;
        p += 1;
        var hyphens: usize = 0;
        while (p < line.len and ((line[p] >= 'a' and line[p] <= 'z') or
            (line[p] >= 'A' and line[p] <= 'Z') or (line[p] >= '0' and line[p] <= '9') or line[p] == '-'))
        {
            if (line[p] == '-') hyphens += 1 else hyphens = 0;
            p += 1;
            if (hyphens > 61) return null;
        }
        // Trailing hyphen is not a valid label end; the reference allows up
        // to 61 interior hyphens, so rewind a trailing run conservatively.
        if (line[p - 1] == '-') return null;
        labels += 1;
        if (p < line.len and line[p] == '.') {
            p += 1;
            continue;
        }
        break;
    }
    if (labels == 0 or p >= line.len or line[p] != '>') return null;
    return p + 1;
}

const Opener = struct {
    pos: usize,
    image: bool,
    bracket_after: bool = false,
};

/// Single-pass bracket scan mirroring the reference inline lexer: `[`
/// pushes a link opener (resetting the no-link flag), `![` pushes an image
/// opener, `<` matches autolinks eagerly so their interiors never dispatch,
/// and each `]` matches the nearest opener. A formed link deactivates outer
/// link openers (links never nest); images deactivate nothing. Matches come
/// out ordered by opener for the main loop to consume.
pub fn collectLinkMatches(line: []const u8, defs: []const simd.RefDef, matches: []LinkMatch) usize {
    var n: usize = 0;
    var stack: [32]Opener = undefined;
    var top: usize = 0;
    var no_link = false;
    var i: usize = 0;
    while (i < line.len and n < matches.len) {
        const c = line[i];
        if (c == '\\' and i + 1 < line.len and isAsciiPunct(line[i + 1])) {
            i += 2;
            continue;
        }
        if (c == '`') {
            var run: usize = 0;
            while (i + run < line.len and line[i + run] == '`') : (run += 1) {}
            if (codeSpanClose(line, i + run, run)) |cs| {
                i = cs.close_end;
                continue;
            }
            // No matching closer: the whole opener run is literal text.
            i += run;
            continue;
        }
        if (c == '!' and i + 1 < line.len and line[i + 1] == '[') {
            if (top < stack.len) {
                if (top > 0) stack[top - 1].bracket_after = true;
                stack[top] = .{ .pos = i + 1, .image = true };
                top += 1;
            }
            i += 2;
            continue;
        }
        if (c == '[') {
            if (top < stack.len) {
                if (top > 0) stack[top - 1].bracket_after = true;
                stack[top] = .{ .pos = i, .image = false };
                top += 1;
            }
            no_link = false;
            i += 1;
            continue;
        }
        if (c == '<') {
            if (matchAutolink(line, i)) |end| {
                matches[n] = .{
                    .open = i,
                    .autolink = true,
                    .text_start = i + 1,
                    .text_end = end - 1,
                    .dest_start = i + 1,
                    .dest_end = end - 1,
                    .end = end,
                };
                n += 1;
                i = end;
                continue;
            }
            i += 1;
            continue;
        }
        if (c == ']') {
            if (top == 0) {
                i += 1;
                continue;
            }
            top -= 1;
            const o = stack[top];
            if (!o.image and no_link) {
                i += 1;
                continue;
            }
            const tstart = o.pos + 1;
            var mend: ?usize = null;
            var ds: usize = 0;
            var de: usize = 0;
            var rurl: ?[]const u8 = null;
            if (i + 1 < line.len and line[i + 1] == '(') {
                if (parseLinkTail(line, i + 1)) |tail| {
                    mend = tail.close + 1;
                    ds = tail.dest_start;
                    de = tail.dest_end;
                }
            }
            if (mend == null and i + 1 < line.len and line[i + 1] == '[') {
                // Explicit label: full `[t][l]`, collapsed `[t][]`. A
                // present-but-undefined label kills the match outright
                // (no shortcut fallback: `[foo][bar][baz]` leaves `[foo]`
                // literal when only `baz` is defined).
                if (scanRefLabel(line, i + 1)) |lab| {
                    const want: []const u8 = if (lab.label.len == 0) line[tstart..i] else lab.label;
                    if (simd.findRefDef(defs, want)) |def| {
                        mend = lab.end;
                        rurl = def.url;
                    } else {
                        // Undefined explicit label: opener already popped,
                        // `]` stays literal, no shortcut fallback.
                        i += 1;
                        continue;
                    }
                }
            }
            if (mend == null and (i + 1 >= line.len or line[i + 1] != '[') and !o.bracket_after) {
                if (simd.findRefDef(defs, line[tstart..i])) |def| {
                    mend = i + 1;
                    rurl = def.url;
                }
            }
            if (mend) |mend_v| {
                matches[n] = .{
                    .open = o.pos,
                    .bang = o.image,
                    .image = o.image,
                    .text_start = tstart,
                    .text_end = i,
                    .dest_start = ds,
                    .dest_end = de,
                    .ref_url = rurl,
                    .end = mend_v,
                };
                n += 1;
                if (!o.image) no_link = true;
                i = mend_v;
                continue;
            }
            i += 1;
            continue;
        }
        i += 1;
    }
    // Order by opener for the main loop's cursor consumption (matches are
    // appended in closer order; nested inners sort after their outers and
    // are skipped when an outer jumps past them).
    var a: usize = 1;
    while (a < n) : (a += 1) {
        var b = a;
        while (b > 0 and matches[b].open < matches[b - 1].open) {
            const t = matches[b];
            matches[b] = matches[b - 1];
            matches[b - 1] = t;
            b -= 1;
        }
    }
    return n;
}

/// Collect link intervals ahead of delimiter matching from the shared
/// single-pass scan (ranges only; kinds resolved by the main loop).
pub fn linkIntervals(line: []const u8, defs: []const simd.RefDef, segs: []LinkSeg) usize {
    var tmp: [MAX_LINK_SEGS]LinkMatch = undefined;
    const n = collectLinkMatches(line, defs, &tmp);
    var m: usize = 0;
    for (tmp[0..n]) |mt| {
        if (m >= segs.len) break;
        if (mt.autolink) {
            segs[m] = .{ .start = mt.open, .end = mt.end, .angle = true };
        } else {
            segs[m] = .{ .start = mt.open, .end = mt.text_end + 1, .angle = false };
        }
        m += 1;
    }
    return m;
}

/// Drop pairs with exactly one endpoint inside a formed link's text
/// brackets (reference: delimiters on opposite sides of a link boundary
/// never meet). Compacts in place; returns the surviving count.
pub fn filterCrossingPairs(runs: []const DelimRun, pairs: []EmPair, n: usize, segs: []const LinkSeg) usize {
    var w: usize = 0;
    var r: usize = 0;
    while (r < n) : (r += 1) {
        const p = pairs[r];
        const op = runs[p.open].pos;
        const cp = runs[p.close].pos;
        var cross = false;
        for (segs) |sg| {
            if (sg.angle) continue;
            const o_in = op >= sg.start and op < sg.end;
            const c_in = cp >= sg.start and cp < sg.end;
            if (o_in != c_in) {
                cross = true;
                break;
            }
        }
        if (!cross) {
            pairs[w] = p;
            w += 1;
        }
    }
    return w;
}

/// Collect runs, skipping autolink interiors (their delimiters never reach
/// the reference matcher: `<a@*b*c>` keeps literal stars).
pub fn collectRunsMasked(line: []const u8, runs: []DelimRun, segs: []const LinkSeg) usize {
    const n = collectRuns(line, runs);
    var w: usize = 0;
    var r: usize = 0;
    while (r < n) : (r += 1) {
        var masked = false;
        for (segs) |sg| {
            if (!sg.angle) continue;
            if (runs[r].pos >= sg.start and runs[r].pos < sg.end) {
                masked = true;
                break;
            }
        }
        if (!masked) {
            runs[w] = runs[r];
            w += 1;
        }
    }
    return w;
}

/// Style active at text offset `pos`: union of pairs whose regions cover it.
/// Recomputed positionally (never threaded) so outer pairs survive inner
/// closes (`*(*foo*)*` keeps `(` emphasized). Bold/italic only; strike,
/// code, and link flags keep their existing handling.
fn activeStyle(runs: []const DelimRun, pairs: []const EmPair, pos: usize) SpanStyle {
    var st = SpanStyle{};
    for (pairs) |p| {
        const o = runs[p.open];
        const cl = runs[p.close];
        if (o.pos + o.len <= pos and pos < cl.pos) {
            if (p.strong) st.bold = true else st.italic = true;
        }
    }
    return st;
}
pub fn parseInlines(
    line: []const u8,
    spans_out: []InlineSpan,
) usize {
    return parseInlinesWithDefs(line, spans_out, &.{});
}

/// Full inline parser with reference-link resolution (`[t][l]`, `[t][]`,
/// `[t]`, and the single-space Markdown.pl form `[t] [l]`). `defs` borrows
/// the same document buffer as `line` (zero-copy link targets). Cross-line
/// references (`[t]` newline `[l]`) stay literal text.
pub fn parseInlinesWithDefs(
    line: []const u8,
    spans_out: []InlineSpan,
    defs: []const simd.RefDef,
) usize {
    if (line.len == 0 or spans_out.len == 0) return 0;

    var span_count: usize = 0;
    var i: usize = 0;
    var span_start: usize = 0;

    var cur_style = SpanStyle{};

    // CommonMark emphasis events for this line (fixed buffers, no heap).
    // Link intervals first: pairs never cross formed brackets, and
    // autolink interiors hold no runs. The presence gate keeps prose
    // lines (no brackets/angles) on the single-scan fast path.
    var seg_buf: [MAX_LINK_SEGS]LinkSeg = undefined;
    const n_segs = if (std.mem.indexOfAny(u8, line, "[!<") != null)
        linkIntervals(line, defs, seg_buf[0..])
    else
        0;
    // Formed links/images/autolinks from the shared scan, ordered by
    // opener; the main loop consumes them positionally.
    var match_buf: [MAX_LINK_SEGS]LinkMatch = undefined;
    const n_matches = if (std.mem.indexOfAny(u8, line, "[!<") != null)
        collectLinkMatches(line, defs, match_buf[0..])
    else
        0;
    var match_cursor: usize = 0;
    var run_buf: [MAX_RUNS]DelimRun = undefined;
    const n_runs = collectRunsMasked(line, run_buf[0..], seg_buf[0..n_segs]);
    var pair_buf: [MAX_PAIRS]EmPair = undefined;
    var n_pairs = matchRuns(run_buf[0..n_runs], n_runs, pair_buf[0..]);
    n_pairs = filterCrossingPairs(run_buf[0..n_runs], pair_buf[0..n_pairs], n_pairs, seg_buf[0..n_segs]);
    const pairs = pair_buf[0..n_pairs];
    var run_cursor: usize = 0;

    while (i < line.len and span_count < spans_out.len) {
        const c = line[i];

        // Backslash escape for Markdown punctuation: \* \_ \[ \] \` etc.
        if (c == '\\' and i + 1 < line.len) {
            const next_c = line[i + 1];
            if (isAsciiPunct(next_c)) {
                if (i > span_start) {
                    spans_out[span_count] = .{
                        .text = line[span_start..i],
                        .style = segStyle(run_buf[0..n_runs], pairs, span_start, cur_style),
                    };
                    span_count += 1;
                    if (span_count >= spans_out.len) break;
                }
                spans_out[span_count] = .{
                    .text = line[i + 1 .. i + 2],
                    .style = segStyle(run_buf[0..n_runs], pairs, span_start, cur_style),
                };
                span_count += 1;
                i += 2;
                span_start = i;
                continue;
            }
        }

        // Inline code `...` (matched-length closer, stripped padding).
        if (c == '`') {
            var run: usize = 0;
            while (i + run < line.len and line[i + run] == '`') : (run += 1) {}
            if (codeSpanClose(line, i + run, run)) |cs| {
                if (i > span_start) {
                    spans_out[span_count] = .{
                        .text = line[span_start..i],
                        .style = segStyle(run_buf[0..n_runs], pairs, span_start, cur_style),
                    };
                    span_count += 1;
                    if (span_count >= spans_out.len) break;
                }

                spans_out[span_count] = .{
                    .text = stripCodeSpan(line[cs.start..cs.end]),
                    .style = .{ .code = true },
                };
                span_count += 1;
                i = cs.close_end;
                span_start = i;
                continue;
            } else {
                // No matching closer: the whole opener run is literal text.
                i += run;
                continue;
            }
        }

        // Emphasis runs: CommonMark-matched open/close events drive the
        // style flags (no toggling). Unmatched runs stay literal text and
        // are absorbed into the pending span (no fragmentation).
        if (c == '*' or c == '_') {
            while (run_cursor < n_runs and
                run_buf[run_cursor].pos + run_buf[run_cursor].len <= i) : (run_cursor += 1)
            {
            }
            if (run_cursor < n_runs and run_buf[run_cursor].pos == i) {
                const rlen: usize = run_buf[run_cursor].len;
                // Does this run carry any event? If not, absorb it whole.
                var has_event = false;
                for (pairs) |p| {
                    if (p.close == run_cursor or p.open == run_cursor) {
                        has_event = true;
                        break;
                    }
                }
                if (has_event) {
                    // Closer delims occupy [0, close_end), opener delims
                    // [open_start, rlen); the gap stays literal text.
                    // Styles recompute positionally so outer pairs survive
                    // inner closes; only strike still threads.
                    var close_end: usize = 0;
                    var open_start: usize = rlen;
                    for (pairs) |p| {
                        if (p.close == run_cursor) close_end = @max(close_end, p.close_off + p.use);
                        if (p.open == run_cursor) open_start = @min(open_start, p.open_off);
                    }
                    // Flush text before the run.
                    if (i > span_start) {
                        var st = activeStyle(run_buf[0..n_runs], pairs, span_start);
                        st.strikethrough = cur_style.strikethrough;
                        spans_out[span_count] = .{ .text = line[span_start..i], .style = st };
                        span_count += 1;
                        if (span_count >= spans_out.len) {
                            i += rlen;
                            break;
                        }
                    }
                    // Gap literals under the mid-run style.
                    if (open_start > close_end and span_count < spans_out.len) {
                        var st = activeStyle(run_buf[0..n_runs], pairs, i + close_end);
                        st.strikethrough = cur_style.strikethrough;
                        spans_out[span_count] = .{
                            .text = line[i + close_end .. i + open_start],
                            .style = st,
                        };
                        span_count += 1;
                    }
                    span_start = i + rlen;
                }
                run_cursor += 1;
                i += rlen;
                continue;
            }
            // Uncollected run (past the cap): literal text.
            var runlen: usize = 1;
            while (i + runlen < line.len and line[i + runlen] == c) : (runlen += 1) {}
            i += runlen;
            continue;
        }

        // Strikethrough ~~
        if (c == '~' and i + 1 < line.len and line[i + 1] == '~') {
            if (i > span_start) {
                spans_out[span_count] = .{
                    .text = line[span_start..i],
                    .style = segStyle(run_buf[0..n_runs], pairs, span_start, cur_style),
                };
                span_count += 1;
                if (span_count >= spans_out.len) break;
            }

            cur_style.strikethrough = !cur_style.strikethrough;
            i += 2;
            span_start = i;
            continue;
        }

        // Links, images, and autolinks from the shared single-pass scan:
        // consume the match opening here (images open at the `[`, so a
        // leading `!` reaches the same match one byte later).
        while (match_cursor < n_matches and match_buf[match_cursor].open < i) : (match_cursor += 1) {}
        if (match_cursor < n_matches and (match_buf[match_cursor].open == i or
            (match_buf[match_cursor].bang and match_buf[match_cursor].open == i + 1 and c == '!')))
        {
            const m = match_buf[match_cursor];
            match_cursor += 1;
            if (i > span_start) {
                spans_out[span_count] = .{
                    .text = line[span_start..i],
                    .style = segStyle(run_buf[0..n_runs], pairs, span_start, cur_style),
                };
                span_count += 1;
                if (span_count >= spans_out.len) break;
            }

            var mstyle = segStyle(run_buf[0..n_runs], pairs, i, cur_style);
            mstyle.link = true;
            if (m.image) mstyle.image = true;
            if (m.autolink) mstyle.autolink = true;

            spans_out[span_count] = .{
                .text = line[m.text_start..m.text_end],
                .style = mstyle,
                .link_target = m.ref_url orelse line[m.dest_start..m.dest_end],
            };
            span_count += 1;

            i = m.end;
            span_start = i;
            continue;
        }

        i += 1;
    }

    // Flush remaining text
    if (span_start < line.len and span_count < spans_out.len) {
        spans_out[span_count] = .{
            .text = line[span_start..line.len],
            .style = segStyle(run_buf[0..n_runs], pairs, span_start, cur_style),
        };
        span_count += 1;
    }

    return span_count;
}

// ============================================================================
// Pass 2 (refinement): SAX-style streaming inline tokens for lazy viewport
// parsing. Instead of building spans, the state machine below emits tokens
// directly as it reads the mmap buffer — parsing RAM stays near zero because
// only the current token stream (in the caller's fixed buffer) exists.
//
// Text nodes are (u32 start, u16 len) absolute offsets into the mmap buffer:
// resolve them with tokenSlice(bytes, tok). No string data is copied and the
// hot path performs zero heap allocations.
// ============================================================================

/// SAX-style inline token kinds. Markup boundaries are zero-width events;
/// content tokens carry absolute mmap offsets (see Token).
pub const TokenKind = enum(u8) {
    text = 0,
    code_span = 1,
    start_bold = 2,
    end_bold = 3,
    start_italic = 4,
    end_italic = 5,
    start_strike = 6,
    end_strike = 7,
    start_link = 8, // (start, len) -> link URL bytes in the mmap buffer
    end_link = 9,
    image = 10, // (start, len) -> alt-text bytes; always followed by image_src
    image_src = 11, // (start, len) -> image URL bytes
};

/// One streaming token. Exactly 8 bytes: no padding waste, no pointers, no
/// ownership — everything borrows from the mmap buffer via absolute offsets.
pub const Token = struct {
    kind: TokenKind,
    _pad: u8 = 0,
    start: u32 = 0,
    len: u16 = 0,
};

comptime {
    if (@sizeOf(Token) != 8) @compileError("Token must stay 8 bytes");
}

/// Resolves a content token (text, code_span, start_link, image, image_src)
/// to its byte slice. Bounds-clamped so a stale token can never trap.
pub fn tokenSlice(bytes: []const u8, tok: Token) []const u8 {
    const s: usize = @min(@as(usize, tok.start), bytes.len);
    const e: usize = @min(s + @as(usize, tok.len), bytes.len);
    return bytes[s..e];
}

/// Viewport-triggered Pass-2 refinement for a single block line: slices one
/// line out of the mmap buffer and streams its inline tokens. Zero heap
/// allocations; writes only into the caller's tokens_out.
pub fn parseLineStream(
    bytes: []const u8,
    offset: u32,
    len: usize,
    tokens_out: []Token,
) usize {
    const base: usize = @min(@as(usize, offset), bytes.len);
    const end: usize = @min(base + len, bytes.len);
    return parseInlinesStream(offset, bytes[base..end], tokens_out);
}

/// Zero-allocation fixed-buffer emitter shared by the streaming state
/// machine. Text runs longer than 0xFFFF bytes are split across tokens.
const StreamEmitter = struct {
    base: u32,
    out: []Token,
    n: usize = 0,

    fn emit(self: *StreamEmitter, kind: TokenKind, abs_start: u32, abs_len: u16) void {
        if (self.n >= self.out.len) return;
        self.out[self.n] = .{ .kind = kind, .start = abs_start, .len = abs_len };
        self.n += 1;
    }

    fn emitEvent(self: *StreamEmitter, kind: TokenKind) void {
        self.emit(kind, 0, 0);
    }

    fn emitText(self: *StreamEmitter, rel_start: usize, rel_end: usize) void {
        var s = rel_start;
        while (s < rel_end) {
            const chunk_len: usize = @min(rel_end - s, std.math.maxInt(u16));
            self.emit(.text, self.base + @as(u32, @intCast(s)), @intCast(chunk_len));
            if (self.n >= self.out.len) return;
            s += chunk_len;
        }
    }

    fn emitSlice(self: *StreamEmitter, kind: TokenKind, rel_start: usize, rel_end: usize) void {
        const abs = self.base + @as(u32, @intCast(rel_start));
        const clamped: usize = @min(rel_end - rel_start, std.math.maxInt(u16));
        self.emit(kind, abs, @intCast(clamped));
    }

    fn flushText(self: *StreamEmitter, span_start: usize, i: usize) void {
        if (i > span_start) self.emitText(span_start, i);
    }
};

/// SAX-style streaming twin of parseInlines: same CommonMark inline grammar
/// (escapes, code spans, delimiter-run emphasis, ~~strike~~, images, links,
/// autolinks), but emits tokens with absolute mmap offsets instead of
/// borrowed slices. line_base is the absolute offset of line[0] in the mmap
/// buffer (u32, matching simd.Line.offset). Zero heap allocations.
pub fn parseInlinesStream(
    line_base: u32,
    line: []const u8,
    tokens_out: []Token,
) usize {
    if (line.len == 0 or tokens_out.len == 0) return 0;

    var em = StreamEmitter{ .base = line_base, .out = tokens_out };
    var i: usize = 0;
    var span_start: usize = 0;

    var seg_buf: [MAX_LINK_SEGS]LinkSeg = undefined;
    const n_segs = if (std.mem.indexOfAny(u8, line, "[!<") != null)
        linkIntervals(line, &.{}, seg_buf[0..])
    else
        0;
    var run_buf: [MAX_RUNS]DelimRun = undefined;
    const n_runs = collectRunsMasked(line, run_buf[0..], seg_buf[0..n_segs]);
    var pair_buf: [MAX_PAIRS]EmPair = undefined;
    var n_pairs = matchRuns(run_buf[0..n_runs], n_runs, pair_buf[0..]);
    n_pairs = filterCrossingPairs(run_buf[0..n_runs], pair_buf[0..n_pairs], n_pairs, seg_buf[0..n_segs]);
    const pairs = pair_buf[0..n_pairs];
    var run_cursor: usize = 0;

    var strike_on = false;

    while (i < line.len) {
        const c = line[i];

        // Backslash escape for Markdown punctuation: \* \_ \[ \] \` etc.
        if (c == '\\' and i + 1 < line.len) {
            const next_c = line[i + 1];
            if (isAsciiPunct(next_c)) {
                em.flushText(span_start, i);
                em.emitText(i + 1, i + 2);
                i += 2;
                span_start = i;
                continue;
            }
        }

        // Inline code `...` (matched-length closer, stripped padding).
        if (c == '`') {
            var run: usize = 0;
            while (i + run < line.len and line[i + run] == '`') : (run += 1) {}
            if (codeSpanClose(line, i + run, run)) |cs| {
                em.flushText(span_start, i);
                const stripped = stripCodeSpan(line[cs.start..cs.end]);
                const rel = @intFromPtr(stripped.ptr) - @intFromPtr(line.ptr);
                em.emitSlice(.code_span, rel, rel + stripped.len);
                i = cs.close_end;
                span_start = i;
                continue;
            } else {
                // No matching closer: the whole opener run is literal text.
                i += run;
                continue;
            }
        }

        // Emphasis runs: matched events drive start/end tokens. Unmatched
        // runs stay literal text (absorbed into surrounding text tokens).
        if (c == '*' or c == '_') {
            while (run_cursor < n_runs and
                run_buf[run_cursor].pos + run_buf[run_cursor].len <= i) : (run_cursor += 1)
            {
            }
            if (run_cursor < n_runs and run_buf[run_cursor].pos == i) {
                const rlen: usize = run_buf[run_cursor].len;
                var has_event = false;
                for (pairs) |p| {
                    if (p.close == run_cursor or p.open == run_cursor) {
                        has_event = true;
                        break;
                    }
                }
                if (has_event) {
                    var close_end: usize = 0;
                    var open_start: usize = rlen;
                    for (pairs) |p| {
                        if (p.close == run_cursor) close_end = @max(close_end, p.close_off + p.use);
                        if (p.open == run_cursor) open_start = @min(open_start, p.open_off);
                    }
                    em.flushText(span_start, i);
                    span_start = i;
                    for (pairs) |p| {
                        if (p.close == run_cursor) {
                            em.emitEvent(if (p.strong) .end_bold else .end_italic);
                        }
                    }
                    if (open_start > close_end) {
                        em.emitText(i + close_end, i + open_start);
                        span_start = i + open_start;
                    }
                    for (pairs) |p| {
                        if (p.open == run_cursor and p.strong) em.emitEvent(.start_bold);
                    }
                    for (pairs) |p| {
                        if (p.open == run_cursor and !p.strong) em.emitEvent(.start_italic);
                    }
                    span_start = i + rlen;
                }
                run_cursor += 1;
                i += rlen;
                continue;
            }
            var runlen: usize = 1;
            while (i + runlen < line.len and line[i + runlen] == c) : (runlen += 1) {}
            i += runlen;
            continue;
        }

        // Strikethrough ~~
        if (c == '~' and i + 1 < line.len and line[i + 1] == '~') {
            em.flushText(span_start, i);
            strike_on = !strike_on;
            em.emitEvent(if (strike_on) .start_strike else .end_strike);
            i += 2;
            span_start = i;
            continue;
        }

        // Image ![alt](url "optional title")
        if (c == '!' and i + 1 < line.len and line[i + 1] == '[') {
            const close_bracket = balancedClose(line, i + 2) orelse line.len;

            if (close_bracket < line.len and close_bracket + 1 < line.len and line[close_bracket + 1] == '(') {
                if (parseLinkTail(line, close_bracket + 1)) |tail| {
                    em.flushText(span_start, i);
                    // Empty alt text yields an image token with len 0; the
                    // renderer substitutes the fallback label (parseInlines
                    // uses "🖼 Image") without any string copy here.
                    em.emitSlice(.image, i + 2, close_bracket);
                    em.emitSlice(.image_src, tail.dest_start, tail.dest_end);
                    i = tail.close + 1;
                    span_start = i;
                    continue;
                }
            }
        }

        // Link [text](url "optional title")
        if (c == '[') {
            var close_bracket = i + 1;
            while (close_bracket < line.len and line[close_bracket] != ']') : (close_bracket += 1) {}

            if (close_bracket + 1 < line.len and line[close_bracket + 1] == '(') {
                if (parseLinkTail(line, close_bracket + 1)) |tail| {
                    em.flushText(span_start, i);
                    em.emitSlice(.start_link, tail.dest_start, tail.dest_end);
                    em.emitText(i + 1, close_bracket);
                    em.emitEvent(.end_link);
                    i = tail.close + 1;
                    span_start = i;
                    continue;
                }
            }
        }

        // Autolink <http://...>, <https://...>, <user@domain.com>
        if (c == '<') {
            var close_angle = i + 1;
            while (close_angle < line.len and line[close_angle] != '>') : (close_angle += 1) {}

            if (close_angle < line.len) {
                const inner = line[i + 1 .. close_angle];
                const is_url = std.mem.startsWith(u8, inner, "http://") or
                    std.mem.startsWith(u8, inner, "https://") or
                    std.mem.startsWith(u8, inner, "mailto:") or
                    isEmailAutolink(inner);

                if (is_url) {
                    em.flushText(span_start, i);
                    em.emitSlice(.start_link, i + 1, close_angle);
                    em.emitText(i + 1, close_angle);
                    em.emitEvent(.end_link);
                    i = close_angle + 1;
                    span_start = i;
                    continue;
                }
            }
        }

        i += 1;
    }

    // Flush remaining text
    em.flushText(span_start, line.len);

    return em.n;
}

test "pass2: stream tokens mirror parseInlines spans" {
    const line = "Here is **bold**, *italic*, `code`, and a [link](https://ziglang.org)!";
    const base: u32 = 1000;
    const base_usize: usize = base;
    // Simulate an mmap buffer holding the line at an absolute offset.
    var backing: [2048]u8 = [_]u8{0} ** 2048;
    @memcpy(backing[base_usize..][0..line.len], line);

    var toks: [32]Token = undefined;
    const n = parseInlinesStream(base, line, &toks);
    try std.testing.expect(n > 0);

    var seen_bold = false;
    var seen_italic = false;
    var seen_code = false;
    var seen_link = false;
    var depth_bold: i32 = 0;
    var depth_italic: i32 = 0;
    for (toks[0..n]) |t| {
        switch (t.kind) {
            .start_bold => depth_bold += 1,
            .end_bold => {
                depth_bold -= 1;
                seen_bold = true;
            },
            .start_italic => depth_italic += 1,
            .end_italic => {
                depth_italic -= 1;
                seen_italic = true;
            },
            .code_span => {
                try std.testing.expectEqualStrings("code", tokenSlice(&backing, t));
                seen_code = true;
            },
            .start_link => {
                try std.testing.expectEqualStrings("https://ziglang.org", tokenSlice(&backing, t));
            },
            .end_link => seen_link = true,
            .text => {
                // Every text token must resolve inside the line.
                const s = tokenSlice(&backing, t);
                try std.testing.expect(s.len > 0);
                try std.testing.expect(@intFromPtr(s.ptr) >= @intFromPtr(backing[base_usize..].ptr));
            },
            else => {},
        }
    }
    try std.testing.expect(seen_bold and seen_italic and seen_code and seen_link);
    try std.testing.expectEqual(@as(i32, 0), depth_bold);
    try std.testing.expectEqual(@as(i32, 0), depth_italic);
}

test "pass2: escapes, strikethrough, autolink, triple emphasis stream" {
    var backing: [512]u8 = [_]u8{0} ** 512;

    const line1 = "***both*** and ~~gone~~ plus \\*esc\\*";
    @memcpy(backing[64..][0..line1.len], line1);
    var toks1: [32]Token = undefined;
    const n1 = parseInlinesStream(64, line1, &toks1);
    try std.testing.expect(n1 > 0);
    var kinds: [32]TokenKind = undefined;
    for (toks1[0..n1], 0..) |t, k| kinds[k] = t.kind;
    // *** opens bold+italic, closes bold+italic
    try std.testing.expectEqual(TokenKind.start_bold, kinds[0]);
    try std.testing.expectEqual(TokenKind.start_italic, kinds[1]);
    try std.testing.expectEqual(TokenKind.text, kinds[2]);
    try std.testing.expectEqualStrings("both", tokenSlice(&backing, toks1[2]));
    try std.testing.expectEqual(TokenKind.end_bold, kinds[3]);
    try std.testing.expectEqual(TokenKind.end_italic, kinds[4]);

    const line2 = "see <https://ziglang.org> now";
    @memcpy(backing[256..][0..line2.len], line2);
    var toks2: [16]Token = undefined;
    const n2 = parseInlinesStream(256, line2, &toks2);
    var found_auto = false;
    for (toks2[0..n2]) |t| {
        if (t.kind == .start_link and std.mem.eql(u8, tokenSlice(&backing, t), "https://ziglang.org")) {
            found_auto = true;
        }
    }
    try std.testing.expect(found_auto);
}

test "pass2: parseLineStream slices one mmap line with zero copies" {
    const doc = "# Title\nBody with **bold** here\n";
    var toks: [16]Token = undefined;
    // Second line at offset 8, length 22.
    const n = parseLineStream(doc, 8, 22, &toks);
    try std.testing.expect(n > 0);
    var saw_bold_text = false;
    for (toks[0..n]) |t| {
        if (t.kind == .text and std.mem.eql(u8, tokenSlice(doc, t), "bold")) {
            saw_bold_text = true;
        }
    }
    try std.testing.expect(saw_bold_text);
    // Out-of-range tokens can never trap tokenSlice.
    try std.testing.expectEqual(@as(usize, 0), tokenSlice(doc, .{ .kind = .text, .start = 5000, .len = 10 }).len);
}

/// Decodes one HTML entity starting right after the `&` (`rest[0]` is the
/// first entity character; the trailing `;` must be inside `rest`).
/// Writes UTF-8 into `out`, returns bytes written, or 0 when not an entity
/// (caller keeps the literal text). Named table covers the entities the
/// CommonMark spec exercises (`amp lt gt quot apos nbsp copy AElig Dcaron
/// DifferentialD HilbertSpace ClockwiseContourIntegral frac34 ngE ouml
/// auml`); numeric references are complete per spec (1-7 decimal or 1-6 hex
/// digits, NUL/surrogate/overflow mapping to U+FFFD).
pub fn decodeEntityAfterAmp(rest: []const u8, out: []u8) usize {
    const semi = simd.findByte(rest, 0, ';') orelse return 0;
    if (semi == 0 or semi > 32) return 0;
    const body = rest[0..semi];
    const named: ?[]const u8 = if (std.mem.eql(u8, body, "amp"))
        "&"
    else if (std.mem.eql(u8, body, "lt"))
        "<"
    else if (std.mem.eql(u8, body, "gt"))
        ">"
    else if (std.mem.eql(u8, body, "quot"))
        "\""
    else if (std.mem.eql(u8, body, "apos"))
        "'"
    else if (std.mem.eql(u8, body, "nbsp"))
        " "
    else if (std.mem.eql(u8, body, "copy"))
        "©"
    else if (std.mem.eql(u8, body, "AElig"))
        "Æ"
    else if (std.mem.eql(u8, body, "Dcaron"))
        "Ď"
    else if (std.mem.eql(u8, body, "DifferentialD"))
        "ⅆ"
    else if (std.mem.eql(u8, body, "HilbertSpace"))
        "ℋ"
    else if (std.mem.eql(u8, body, "ClockwiseContourIntegral"))
        "∲"
    else if (std.mem.eql(u8, body, "frac34"))
        "¾"
    else if (std.mem.eql(u8, body, "ngE"))
        "≧̸"
    else if (std.mem.eql(u8, body, "ouml"))
        "ö"
    else if (std.mem.eql(u8, body, "auml"))
        "ä"
    else
        null;
    if (named) |s| {
        if (out.len < s.len) return 0;
        @memcpy(out[0..s.len], s);
        return s.len;
    }
    // Numeric reference: &#123; (1-7 digits) or &#x1A; (1-6 hex digits,
    // case-insensitive x). NUL, surrogates, and overflow become U+FFFD.
    if (body.len < 2 or body[0] != '#') return 0;
    var digits = body[1..];
    var base: u32 = 10;
    var max_digits: usize = 7;
    if (digits.len > 1 and (digits[0] == 'x' or digits[0] == 'X')) {
        base = 16;
        max_digits = 6;
        digits = digits[1..];
    }
    if (digits.len == 0 or digits.len > max_digits) return 0;
    var value: u32 = 0;
    for (digits) |d| {
        const v: u32 = if (d >= '0' and d <= '9')
            @as(u32, d - '0')
        else if (base == 16 and d >= 'a' and d <= 'f')
            @as(u32, d - 'a' + 10)
        else if (base == 16 and d >= 'A' and d <= 'F')
            @as(u32, d - 'A' + 10)
        else
            return 0;
        value = value * base + v;
        if (value >= 0x110000) value = 0x110000;
    }
    const scalar: u21 = if (value == 0 or
        (value >= 0xD800 and value <= 0xDFFF) or value >= 0x110000)
        0xFFFD
    else
        @intCast(value);
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(scalar, &buf) catch return 0;
    if (out.len < n) return 0;
    @memcpy(out[0..n], buf[0..n]);
    return n;
}

/// Consumed length of the entity starting at `line[i]` (`line[i] == '&'`),
/// or 0 when there is no valid `&...;` entity here. The decoded bytes are
/// available via `decodeEntityAfterAmp`; this helper answers the cheaper
/// "is there an entity" question for measurement pre-scans.
pub fn entityLengthAt(line: []const u8, i: usize) usize {
    if (i >= line.len or line[i] != '&') return 0;
    const semi = simd.findByte(line, i + 1, ';') orelse return 0;
    if (semi - (i + 1) == 0 or semi - (i + 1) > 32) return 0;
    var tmp: [4]u8 = undefined;
    const n = decodeEntityAfterAmp(line[i + 1 ..], tmp[0..]);
    if (n == 0) return 0;
    return semi - i + 1;
}

/// Reference-definition machinery lives in simd.zig next to the block
/// classifier (scan-time detection needs it without a parser import
/// cycle); re-exported here for inline resolution and tests.
pub const RefDef = simd.RefDef;
pub const MAX_REF_DEFS = simd.MAX_REF_DEFS;
pub const parseRefDefLine = simd.parseRefDefLine;
pub const scanRefDefs = simd.scanRefDefs;
pub const findRefDef = simd.findRefDef;

fn linkTargetOf(line: []const u8) ?[]const u8 {
    var spans: [8]InlineSpan = undefined;
    const n = parseInlines(line, &spans);
    for (spans[0..n]) |s| {
        if (s.style.link) return s.link_target;
    }
    return null;
}

test "inline links: titles validate, destinations exclude brackets" {
    // Plain destination with double-quoted title.
    const t1 = linkTargetOf("[URL and title](/url/ \"title\")");
    try std.testing.expect(t1 != null);
    try std.testing.expectEqualStrings("/url/", t1.?);

    // Title may be separated by two spaces or a tab.
    try std.testing.expectEqualStrings("/url/", linkTargetOf("[t](/url/  \"spaced\")").?);
    try std.testing.expectEqualStrings("/url/", linkTargetOf("[t](/url/\t\"tabbed\")").?);

    // Empty destination is a link with an empty target.
    const t_empty = linkTargetOf("[Empty]()");
    try std.testing.expect(t_empty != null);
    try std.testing.expectEqualStrings("", t_empty.?);

    // Angle destination keeps raw characters (unbalanced query "&").
    try std.testing.expectEqualStrings(
        "/script?foo=1&bar=2",
        linkTargetOf("Here's an inline [link](</script?foo=1&bar=2>).").?,
    );

    // Balanced parens inside a bare destination are kept.
    try std.testing.expectEqualStrings("u(v)w", linkTargetOf("[a](u(v)w)").?);

    // A title holding its own quote character is not a title at all
    // (CommonMark first-close rule), so the whole construct stays literal.
    try std.testing.expect(linkTargetOf("Foo [bar](/url/ \"Title with \"quotes\" inside\").") == null);

    // Unterminated title also stays literal.
    try std.testing.expect(linkTargetOf("[a](/u \"no end") == null);

    // Image destinations follow the same rule (title dropped).
    var spans: [8]InlineSpan = undefined;
    const n = parseInlines("![alt](/img.png \"Title\")", &spans);
    var found_img = false;
    for (spans[0..n]) |s| {
        if (s.style.link and s.link_target != null and std.mem.eql(u8, s.link_target.?, "/img.png")) {
            found_img = true;
        }
    }
    try std.testing.expect(found_img);
}

test "code spans: matched closers and padding strip" {
    // Double-backtick span holding an escaped backtick (backslash doc).
    var spans: [8]InlineSpan = undefined;
    const n = parseInlines("Backtick: `` \\` ``", &spans);
    var found = false;
    for (spans[0..n]) |s| {
        if (s.style.code and std.mem.eql(u8, s.text, "\\`")) found = true;
    }
    try std.testing.expect(found);

    // Single spans are unchanged; padded singles strip one space.
    var s2: [8]InlineSpan = undefined;
    const n2 = parseInlines("`<http://example.com/>`", &s2);
    try std.testing.expect(n2 == 1 and s2[0].style.code);
    try std.testing.expectEqualStrings("<http://example.com/>", s2[0].text);
    var s3: [8]InlineSpan = undefined;
    const n3 = parseInlines("` pad `", &s3);
    try std.testing.expect(n3 == 1 and s3[0].style.code);
    try std.testing.expectEqualStrings("pad", s3[0].text);

    // Unterminated backticks stay literal text (no code spans at all).
    var s4: [8]InlineSpan = undefined;
    const n4 = parseInlines("a ` b", &s4);
    for (s4[0..n4]) |s| {
        try std.testing.expect(!s.style.code);
    }
}

test "entities: named and numeric references decode" {
    var out: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), decodeEntityAfterAmp("amp;T", out[0..]));
    try std.testing.expectEqualStrings("&", out[0..1]);
    try std.testing.expectEqual(@as(usize, 1), decodeEntityAfterAmp("lt;", out[0..]));
    try std.testing.expectEqualStrings("<", out[0..1]);
    try std.testing.expectEqual(@as(usize, 1), decodeEntityAfterAmp("gt;", out[0..]));
    try std.testing.expectEqual(@as(usize, 2), decodeEntityAfterAmp("nbsp;", out[0..]));
    try std.testing.expectEqual(@as(usize, 1), decodeEntityAfterAmp("#39;", out[0..]));
    try std.testing.expectEqualStrings("'", out[0..1]);
    try std.testing.expectEqual(@as(usize, 1), decodeEntityAfterAmp("#x2F;", out[0..]));
    try std.testing.expectEqualStrings("/", out[0..1]);
    try std.testing.expectEqual(@as(usize, 3), decodeEntityAfterAmp("#0;", out[0..]));
    // Unknown names, missing semicolons, and bare ampersands stay literal.
    try std.testing.expectEqual(@as(usize, 0), decodeEntityAfterAmp("bogus;", out[0..]));
    try std.testing.expectEqual(@as(usize, 0), decodeEntityAfterAmp("amp", out[0..]));
    try std.testing.expectEqual(@as(usize, 0), decodeEntityAfterAmp(";", out[0..]));
    try std.testing.expectEqual(@as(usize, 5), entityLengthAt("AT&amp;T", 2));
    try std.testing.expectEqual(@as(usize, 0), entityLengthAt("AT&T", 2));
    try std.testing.expectEqual(@as(usize, 0), entityLengthAt("fish & chips", 5));
}

test "refdefs: single-line definitions scan, indent and titles gate" {
    // Valid definitions with titles, extra spaces, and 1-3 space indent.
    const d1 = parseRefDefLine("[1]: http://example.com/?foo=1&bar=2");
    try std.testing.expect(d1 != null);
    try std.testing.expectEqualStrings("1", d1.?.label);
    try std.testing.expectEqualStrings("http://example.com/?foo=1&bar=2", d1.?.url);

    const d2 = parseRefDefLine("[2]: http://att.com/  \"AT&T\"");
    try std.testing.expect(d2 != null);
    try std.testing.expectEqualStrings("http://att.com/", d2.?.url);

    try std.testing.expect(parseRefDefLine(" [once]: /url") != null);
    try std.testing.expect(parseRefDefLine("  [twice]: /url") != null);
    try std.testing.expect(parseRefDefLine("   [thrice]: /url") != null);

    // Four spaces or a tab: indented code, never a definition.
    try std.testing.expect(parseRefDefLine("    [four]: /url") == null);
    try std.testing.expect(parseRefDefLine("\t[tab]: /url") == null);

    // First-close titles: a title holding its own quote invalidates the
    // whole definition (CommonMark); only trailing garbage otherwise does.
    try std.testing.expect(parseRefDefLine("[bar]: /url/ \"Title with \"quotes\" inside\"") == null);
    try std.testing.expect(parseRefDefLine("[a]: /url garbage") == null);

    // Use sites are not definitions.
    try std.testing.expect(parseRefDefLine("Here's a [link] [1] with text.") == null);
    try std.testing.expect(parseRefDefLine("[1].") == null);
    try std.testing.expect(parseRefDefLine("[foo] bar") == null);

    // Matching is case-insensitive with collapsed whitespace.
    const defs = [_]RefDef{
        .{ .label = "Once", .url = "/url", .line_idx = 3 },
        .{ .label = "a  b", .url = "/u2", .line_idx = 5 },
    };
    try std.testing.expectEqualStrings("/url", findRefDef(&defs, "once").?.url);
    try std.testing.expectEqualStrings("/url", findRefDef(&defs, "ONCE").?.url);
    try std.testing.expectEqualStrings("/u2", findRefDef(&defs, "a b").?.url);
    try std.testing.expect(findRefDef(&defs, "missing") == null);
}

fn linkTargetOfDefs(line: []const u8, defs: []const simd.RefDef) ?[]const u8 {
    var spans: [8]InlineSpan = undefined;
    const n = parseInlinesWithDefs(line, &spans, defs);
    for (spans[0..n]) |s| {
        if (s.style.link) return s.link_target;
    }
    return null;
}

fn linkTextOfDefs(line: []const u8, defs: []const simd.RefDef) ?[]const u8 {
    var spans: [8]InlineSpan = undefined;
    const n = parseInlinesWithDefs(line, &spans, defs);
    for (spans[0..n]) |s| {
        if (s.style.link) return s.text;
    }
    return null;
}

test "ref links: full, collapsed, and shortcut forms resolve" {
    const doc =
        "Foo [bar] [1].\n" ++
        "With [embedded [brackets]] [b].\n" ++
        "Indented [once][].\n" ++
        "Indented [twice].\n" ++
        "Indented [four][] times.\n" ++
        "\n" ++
        " [once]: /url\n" ++
        "[twice]: /url\n" ++
        "    [four]: /url\n" ++
        "[1]: /url/  \"Title\"\n" ++
        "[b]: /url/\n";
    var lines: [16]simd.Line = undefined;
    var fence: simd.FenceState = .{};
    const n = simd.scanLines(doc, &lines, &fence);
    var defs: [8]simd.RefDef = undefined;
    const m = simd.scanRefDefs(doc, lines[0..n], &defs);
    try std.testing.expectEqual(@as(usize, 4), m);

    // No space-separated full form (CommonMark): `[bar]` has no definition
    // so it stays literal, and the trailing `[1]` resolves as its own
    // shortcut link.
    try std.testing.expectEqualStrings("/url/", linkTargetOfDefs("Foo [bar] [1].", defs[0..m]).?);
    try std.testing.expectEqualStrings("1", linkTextOfDefs("Foo [bar] [1].", defs[0..m]).?);
    // Nested brackets with a space before the label stay literal except the
    // trailing shortcut: only `[b]` links (CommonMark).
    try std.testing.expectEqualStrings("/url/", linkTargetOfDefs("With [embedded [brackets]] [b].", defs[0..m]).?);
    try std.testing.expectEqualStrings("b", linkTextOfDefs("With [embedded [brackets]] [b].", defs[0..m]).?);
    // Collapsed and shortcut forms.
    try std.testing.expectEqualStrings("/url", linkTargetOfDefs("Indented [once][].", defs[0..m]).?);
    try std.testing.expectEqualStrings("/url", linkTargetOfDefs("Indented [twice].", defs[0..m]).?);
    // Four-space definition is code: use stays literal.
    try std.testing.expect(linkTargetOfDefs("Indented [four][] times.", defs[0..m]) == null);
    // Unknown labels stay literal.
    try std.testing.expect(linkTargetOfDefs("[missing] here.", defs[0..m]) == null);
    // Without a table nothing resolves (plain parseInlines path).
    try std.testing.expect(linkTargetOf("Foo [bar] [1].") == null);
}

test "refdefs: amps document yields two definitions" {
    const doc =
        "Here's a [link] [1] with an ampersand in the URL.\n" ++
        "\n" ++
        "[1]: http://example.com/?foo=1&bar=2\n" ++
        "[2]: http://att.com/  \"AT&T\"\n";
    var lines: [8]simd.Line = undefined;
    var fence: simd.FenceState = .{};
    const n = simd.scanLines(doc, &lines, &fence);
    var defs: [8]RefDef = undefined;
    const m = scanRefDefs(doc, lines[0..n], &defs);
    try std.testing.expectEqual(@as(usize, 2), m);
    try std.testing.expectEqualStrings("1", defs[0].label);
    try std.testing.expectEqualStrings("http://example.com/?foo=1&bar=2", defs[0].url);
    try std.testing.expectEqualStrings("2", defs[1].label);
}

