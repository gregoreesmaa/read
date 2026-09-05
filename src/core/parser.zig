const std = @import("std");
const simd = @import("simd.zig");

pub const SpanStyle = packed struct {
    bold: bool = false,
    italic: bool = false,
    code: bool = false,
    strikethrough: bool = false,
    link: bool = false,
    heading: bool = false,
    _pad: u2 = 0,
};

pub const InlineSpan = struct {
    text: []const u8,
    style: SpanStyle,
    link_target: ?[]const u8 = null,
};

fn isAsciiPunct(ch: u8) bool {
    return switch (ch) {
        '!', '"', '#', '$', '%', '&', '\'', '(', ')', '*', '+', ',', '-', '.', '/', ':', ';', '<', '=', '>', '?', '@', '[', '\\', ']', '^', '_', '`', '{', '|', '}', '~' => true,
        else => false,
    };
}

/// High-speed inline parser for viewport lines.
/// Zero heap allocations: tokens are stored directly into caller's slice.
pub fn parseInlines(
    line: []const u8,
    spans_out: []InlineSpan,
) usize {
    if (line.len == 0 or spans_out.len == 0) return 0;

    var span_count: usize = 0;
    var i: usize = 0;
    var span_start: usize = 0;

    var cur_style = SpanStyle{};

    while (i < line.len and span_count < spans_out.len) {
        const c = line[i];

        // Backslash escape for Markdown punctuation: \* \_ \[ \] \` etc.
        if (c == '\\' and i + 1 < line.len) {
            const next_c = line[i + 1];
            if (isAsciiPunct(next_c)) {
                if (i > span_start) {
                    spans_out[span_count] = .{
                        .text = line[span_start..i],
                        .style = cur_style,
                    };
                    span_count += 1;
                    if (span_count >= spans_out.len) break;
                }
                spans_out[span_count] = .{
                    .text = line[i + 1 .. i + 2],
                    .style = cur_style,
                };
                span_count += 1;
                i += 2;
                span_start = i;
                continue;
            }
        }

        // Inline code `...`
        if (c == '`') {
            if (i > span_start) {
                spans_out[span_count] = .{
                    .text = line[span_start..i],
                    .style = cur_style,
                };
                span_count += 1;
                if (span_count >= spans_out.len) break;
            }

            const code_start = i + 1;
            var code_end = code_start;
            while (code_end < line.len and line[code_end] != '`') : (code_end += 1) {}

            if (code_end < line.len) {
                spans_out[span_count] = .{
                    .text = line[code_start..code_end],
                    .style = .{ .code = true },
                };
                span_count += 1;
                i = code_end + 1;
                span_start = i;
                continue;
            } else {
                // Unterminated backtick, treat as regular text
                i += 1;
                continue;
            }
        }

        // Bold ***, **, or Italic *
        if (c == '*' or c == '_') {
            const is_triple = (i + 2 < line.len and line[i + 1] == c and line[i + 2] == c);
            const is_double = !is_triple and (i + 1 < line.len and line[i + 1] == c);
            const delim_len: usize = if (is_triple) 3 else if (is_double) 2 else 1;

            if (i > span_start) {
                spans_out[span_count] = .{
                    .text = line[span_start..i],
                    .style = cur_style,
                };
                span_count += 1;
                if (span_count >= spans_out.len) break;
            }

            if (is_triple) {
                cur_style.bold = !cur_style.bold;
                cur_style.italic = !cur_style.italic;
            } else if (is_double) {
                cur_style.bold = !cur_style.bold;
            } else {
                cur_style.italic = !cur_style.italic;
            }

            i += delim_len;
            span_start = i;
            continue;
        }

        // Strikethrough ~~
        if (c == '~' and i + 1 < line.len and line[i + 1] == '~') {
            if (i > span_start) {
                spans_out[span_count] = .{
                    .text = line[span_start..i],
                    .style = cur_style,
                };
                span_count += 1;
                if (span_count >= spans_out.len) break;
            }

            cur_style.strikethrough = !cur_style.strikethrough;
            i += 2;
            span_start = i;
            continue;
        }

        // Image ![alt](url)
        if (c == '!' and i + 1 < line.len and line[i + 1] == '[') {
            var close_bracket = i + 2;
            while (close_bracket < line.len and line[close_bracket] != ']') : (close_bracket += 1) {}

            if (close_bracket + 1 < line.len and line[close_bracket + 1] == '(') {
                var close_paren = close_bracket + 2;
                while (close_paren < line.len and line[close_paren] != ')') : (close_paren += 1) {}

                if (close_paren < line.len) {
                    if (i > span_start) {
                        spans_out[span_count] = .{
                            .text = line[span_start..i],
                            .style = cur_style,
                        };
                        span_count += 1;
                        if (span_count >= spans_out.len) break;
                    }

                    const alt_text = line[i + 2 .. close_bracket];
                    const img_url = line[close_bracket + 2 .. close_paren];

                    var img_style = cur_style;
                    img_style.link = true;

                    spans_out[span_count] = .{
                        .text = if (alt_text.len > 0) alt_text else "🖼 Image",
                        .style = img_style,
                        .link_target = img_url,
                    };
                    span_count += 1;

                    i = close_paren + 1;
                    span_start = i;
                    continue;
                }
            }
        }

        // Link [text](url)
        if (c == '[') {
            var close_bracket = i + 1;
            while (close_bracket < line.len and line[close_bracket] != ']') : (close_bracket += 1) {}

            if (close_bracket + 1 < line.len and line[close_bracket + 1] == '(') {
                var close_paren = close_bracket + 2;
                while (close_paren < line.len and line[close_paren] != ')') : (close_paren += 1) {}

                if (close_paren < line.len) {
                    // Flush preceding plain text
                    if (i > span_start) {
                        spans_out[span_count] = .{
                            .text = line[span_start..i],
                            .style = cur_style,
                        };
                        span_count += 1;
                        if (span_count >= spans_out.len) break;
                    }

                    const link_text = line[i + 1 .. close_bracket];
                    const link_url = line[close_bracket + 2 .. close_paren];

                    var link_style = cur_style;
                    link_style.link = true;

                    spans_out[span_count] = .{
                        .text = link_text,
                        .style = link_style,
                        .link_target = link_url,
                    };
                    span_count += 1;

                    i = close_paren + 1;
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
                    (std.mem.indexOfScalar(u8, inner, '@') != null and std.mem.indexOfScalar(u8, inner, ' ') == null);

                if (is_url) {
                    if (i > span_start) {
                        spans_out[span_count] = .{
                            .text = line[span_start..i],
                            .style = cur_style,
                        };
                        span_count += 1;
                        if (span_count >= spans_out.len) break;
                    }

                    var link_style = cur_style;
                    link_style.link = true;

                    spans_out[span_count] = .{
                        .text = inner,
                        .style = link_style,
                        .link_target = inner,
                    };
                    span_count += 1;

                    i = close_angle + 1;
                    span_start = i;
                    continue;
                }
            }
        }

        i += 1;
    }

    // Flush remaining text
    if (span_start < line.len and span_count < spans_out.len) {
        spans_out[span_count] = .{
            .text = line[span_start..line.len],
            .style = cur_style,
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
/// (escapes, code spans, */_ bold+italic incl. triple, ~~strike~~, images,
/// links, autolinks), but emits tokens with absolute mmap offsets instead of
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

    var bold_on = false;
    var italic_on = false;
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

        // Inline code `...` (atomic content token, like parseInlines)
        if (c == '`') {
            em.flushText(span_start, i);

            const code_start = i + 1;
            var code_end = code_start;
            while (code_end < line.len and line[code_end] != '`') : (code_end += 1) {}

            if (code_end < line.len) {
                em.emitSlice(.code_span, code_start, code_end);
                i = code_end + 1;
                span_start = i;
                continue;
            } else {
                // Unterminated backtick, treat as regular text
                i += 1;
                continue;
            }
        }

        // Bold ***, **, or Italic *
        if (c == '*' or c == '_') {
            const is_triple = (i + 2 < line.len and line[i + 1] == c and line[i + 2] == c);
            const is_double = !is_triple and (i + 1 < line.len and line[i + 1] == c);
            const delim_len: usize = if (is_triple) 3 else if (is_double) 2 else 1;

            em.flushText(span_start, i);

            if (is_triple) {
                bold_on = !bold_on;
                em.emitEvent(if (bold_on) .start_bold else .end_bold);
                italic_on = !italic_on;
                em.emitEvent(if (italic_on) .start_italic else .end_italic);
            } else if (is_double) {
                bold_on = !bold_on;
                em.emitEvent(if (bold_on) .start_bold else .end_bold);
            } else {
                italic_on = !italic_on;
                em.emitEvent(if (italic_on) .start_italic else .end_italic);
            }

            i += delim_len;
            span_start = i;
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

        // Image ![alt](url)
        if (c == '!' and i + 1 < line.len and line[i + 1] == '[') {
            var close_bracket = i + 2;
            while (close_bracket < line.len and line[close_bracket] != ']') : (close_bracket += 1) {}

            if (close_bracket + 1 < line.len and line[close_bracket + 1] == '(') {
                var close_paren = close_bracket + 2;
                while (close_paren < line.len and line[close_paren] != ')') : (close_paren += 1) {}

                if (close_paren < line.len) {
                    em.flushText(span_start, i);
                    // Empty alt text yields an image token with len 0; the
                    // renderer substitutes the fallback label (parseInlines
                    // uses "🖼 Image") without any string copy here.
                    em.emitSlice(.image, i + 2, close_bracket);
                    em.emitSlice(.image_src, close_bracket + 2, close_paren);
                    i = close_paren + 1;
                    span_start = i;
                    continue;
                }
            }
        }

        // Link [text](url)
        if (c == '[') {
            var close_bracket = i + 1;
            while (close_bracket < line.len and line[close_bracket] != ']') : (close_bracket += 1) {}

            if (close_bracket + 1 < line.len and line[close_bracket + 1] == '(') {
                var close_paren = close_bracket + 2;
                while (close_paren < line.len and line[close_paren] != ')') : (close_paren += 1) {}

                if (close_paren < line.len) {
                    em.flushText(span_start, i);
                    em.emitSlice(.start_link, close_bracket + 2, close_paren);
                    em.emitText(i + 1, close_bracket);
                    em.emitEvent(.end_link);
                    i = close_paren + 1;
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
                    (std.mem.indexOfScalar(u8, inner, '@') != null and std.mem.indexOfScalar(u8, inner, ' ') == null);

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
