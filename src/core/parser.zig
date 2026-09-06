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
    if (content.len >= 2 and content[0] == ' ' and content[content.len - 1] == ' ') {
        for (content) |ch| {
            if (ch != ' ') return content[1 .. content.len - 1];
        }
    }
    return content;
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

fn parseLinkTail(line: []const u8, paren_open: usize) ?LinkTail {
    if (paren_open >= line.len or line[paren_open] != '(') return null;
    var pos = paren_open + 1;
    while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) : (pos += 1) {}
    if (pos >= line.len) return null;

    var dest_start: usize = pos;
    var dest_end: usize = pos;
    if (line[pos] == '<') {
        const gt = std.mem.indexOfScalarPos(u8, line, pos + 1, '>');
        const end = gt orelse return null;
        dest_start = pos + 1;
        dest_end = end;
        pos = end + 1;
    } else {
        var depth: usize = 0;
        var end = pos;
        var ok = false;
        while (end < line.len) {
            const c = line[end];
            if (c == '(') {
                depth += 1;
            } else if (c == ')') {
                if (depth == 0) {
                    ok = true;
                    break;
                }
                depth -= 1;
            } else if (c == ' ' or c == '\t' or c < 0x20) {
                break;
            }
            end += 1;
        }
        // An empty destination `[t]()` is valid; anything else must have
        // consumed at least one character to be well-formed here.
        if (!ok and end != pos) {
            // Ran into whitespace/control: destination ends here, a title
            // or ')' must follow.
        } else if (!ok) {
            return null;
        }
        dest_start = pos;
        dest_end = end;
        pos = end;
    }

    while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) : (pos += 1) {}
    if (pos >= line.len) return null;
    if (line[pos] == ')') return .{ .dest_start = dest_start, .dest_end = dest_end, .close = pos };

    // Optional title ("...", '...', or (...)), validated but dropped.
    const title_end = parseTitleEnd(line, pos, true) orelse return null;
    pos = title_end + 1;

    while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) : (pos += 1) {}
    if (pos >= line.len or line[pos] != ')') return null;
    return .{ .dest_start = dest_start, .dest_end = dest_end, .close = pos };
}

/// High-speed inline parser for viewport lines.
/// Zero heap allocations: tokens are stored directly into caller's slice.
/// Reference links need document state; use `parseInlinesWithDefs` when a
/// definition table is available (the plain form resolves inline links,
/// code, emphasis, and autolinks only).
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

        // Inline code `...` (matched-length closer, stripped padding).
        if (c == '`') {
            var run: usize = 0;
            while (i + run < line.len and line[i + run] == '`') : (run += 1) {}
            if (codeSpanClose(line, i + run, run)) |cs| {
                if (i > span_start) {
                    spans_out[span_count] = .{
                        .text = line[span_start..i],
                        .style = cur_style,
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
                // No matching closer, treat as regular text
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

        // Image ![alt](url "optional title")
        if (c == '!' and i + 1 < line.len and line[i + 1] == '[') {
            var close_bracket = i + 2;
            while (close_bracket < line.len and line[close_bracket] != ']') : (close_bracket += 1) {}

            if (close_bracket + 1 < line.len and line[close_bracket + 1] == '(') {
                if (parseLinkTail(line, close_bracket + 1)) |tail| {
                    if (i > span_start) {
                        spans_out[span_count] = .{
                            .text = line[span_start..i],
                            .style = cur_style,
                        };
                        span_count += 1;
                        if (span_count >= spans_out.len) break;
                    }

                    const alt_text = line[i + 2 .. close_bracket];
                    const img_url = line[tail.dest_start..tail.dest_end];

                    var img_style = cur_style;
                    img_style.link = true;

                    spans_out[span_count] = .{
                        .text = if (alt_text.len > 0) alt_text else "🖼 Image",
                        .style = img_style,
                        .link_target = img_url,
                    };
                    span_count += 1;

                    i = tail.close + 1;
                    span_start = i;
                    continue;
                }
            }
        }

        // Link [text](url), [text][label], [text][], [text], [text] [label].
        // Bracket-balanced text scan so nested `[a [b]]` resolves as one.
        if (c == '[') {
            var close_bracket = i + 1;
            var depth: usize = 0;
            var balanced = false;
            while (close_bracket < line.len) {
                if (line[close_bracket] == '\\' and close_bracket + 1 < line.len) {
                    close_bracket += 2;
                    continue;
                }
                if (line[close_bracket] == '[') {
                    depth += 1;
                } else if (line[close_bracket] == ']') {
                    if (depth == 0) {
                        balanced = true;
                        break;
                    }
                    depth -= 1;
                }
                close_bracket += 1;
            }

            if (balanced) {
                if (close_bracket + 1 < line.len and line[close_bracket + 1] == '(') {
                    if (parseLinkTail(line, close_bracket + 1)) |tail| {
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
                        const link_url = line[tail.dest_start..tail.dest_end];

                        var link_style = cur_style;
                        link_style.link = true;

                        spans_out[span_count] = .{
                            .text = link_text,
                            .style = link_style,
                            .link_target = link_url,
                        };
                        span_count += 1;

                        i = tail.close + 1;
                        span_start = i;
                        continue;
                    }
                }

                // Reference forms (need a definition table).
                if (defs.len > 0) {
                    const link_text = line[i + 1 .. close_bracket];
                    var ref_label: ?[]const u8 = null;
                    var ref_end: usize = close_bracket;
                    if (close_bracket + 1 < line.len and line[close_bracket + 1] == '[') {
                        var lb = close_bracket + 2;
                        while (lb < line.len and line[lb] != ']') : (lb += 1) {}
                        if (lb < line.len) {
                            const raw = line[close_bracket + 2 .. lb];
                            ref_label = if (raw.len == 0) link_text else raw;
                            ref_end = lb;
                        }
                    } else if (close_bracket + 2 < line.len and
                        (line[close_bracket + 1] == ' ' or line[close_bracket + 1] == '\t') and
                        line[close_bracket + 2] == '[')
                    {
                        var lb = close_bracket + 3;
                        while (lb < line.len and line[lb] != ']') : (lb += 1) {}
                        if (lb < line.len) {
                            ref_label = line[close_bracket + 3 .. lb];
                            ref_end = lb;
                        }
                    } else {
                        ref_label = link_text;
                    }
                    if (ref_label) |lab| {
                        if (simd.findRefDef(defs, lab)) |def| {
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
                                .text = link_text,
                                .style = link_style,
                                .link_target = def.url,
                            };
                            span_count += 1;

                            i = ref_end + 1;
                            span_start = i;
                            continue;
                        }
                    }
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
                // No matching closer, treat as regular text
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

        // Image ![alt](url "optional title")
        if (c == '!' and i + 1 < line.len and line[i + 1] == '[') {
            var close_bracket = i + 2;
            while (close_bracket < line.len and line[close_bracket] != ']') : (close_bracket += 1) {}

            if (close_bracket + 1 < line.len and line[close_bracket + 1] == '(') {
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

/// Decodes one HTML entity starting right after the `&` (`rest[0]` is the
/// first entity character; the trailing `;` must be inside `rest`).
/// Writes UTF-8 into `out`, returns bytes written, or 0 when not an entity
/// (caller keeps the literal text). Deliberate subset, not the full HTML5
/// table: `amp lt gt quot apos nbsp` plus decimal/hex numeric references
/// (which can address every scalar, e.g. `&#39;` `&#x2F;`).
pub fn decodeEntityAfterAmp(rest: []const u8, out: []u8) usize {
    const semi = std.mem.indexOfScalar(u8, rest, ';') orelse return 0;
    if (semi == 0 or semi > 10) return 0;
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
    else
        null;
    if (named) |s| {
        if (out.len < s.len) return 0;
        @memcpy(out[0..s.len], s);
        return s.len;
    }
    // Numeric reference: &#123; or &#x1A; (case-insensitive x).
    if (body.len < 2 or body[0] != '#') return 0;
    var digits = body[1..];
    var base: u32 = 10;
    if (digits.len > 1 and (digits[0] == 'x' or digits[0] == 'X')) {
        base = 16;
        digits = digits[1..];
    }
    if (digits.len == 0 or digits.len > 6) return 0;
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
        if (value > 0x10FFFF) return 0;
    }
    // NUL becomes U+FFFD; lone surrogates are rejected (literal text).
    const scalar: u21 = if (value == 0)
        0xFFFD
    else if (value >= 0xD800 and value <= 0xDFFF)
        return 0
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
    const semi = std.mem.indexOfScalarPos(u8, line, i + 1, ';') orelse return 0;
    if (semi - (i + 1) == 0 or semi - (i + 1) > 10) return 0;
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

    // Literal quotes inside a double-quoted title still link (Markdown 1.0
    // greedy titles); the inner text is preserved, target stays clean.
    try std.testing.expectEqualStrings(
        "/url/",
        linkTargetOf("Foo [bar](/url/ \"Title with \"quotes\" inside\").").?,
    );

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

    // Greedy quote titles keep the definition valid (Markdown 1.0); only
    // trailing garbage invalidates it.
    const dq = parseRefDefLine("[bar]: /url/ \"Title with \"quotes\" inside\"");
    try std.testing.expect(dq != null);
    try std.testing.expectEqualStrings("/url/", dq.?.url);
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

test "ref links: full, collapsed, shortcut, spaced forms resolve" {
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
    var fence = false;
    const n = simd.scanLines(doc, &lines, &fence);
    var defs: [8]simd.RefDef = undefined;
    const m = simd.scanRefDefs(doc, lines[0..n], &defs);
    try std.testing.expectEqual(@as(usize, 4), m);

    // Space-separated full form (Markdown.pl compatibility).
    try std.testing.expectEqualStrings("/url/", linkTargetOfDefs("Foo [bar] [1].", defs[0..m]).?);
    // Nested brackets in the text resolve as one link.
    try std.testing.expectEqualStrings("/url/", linkTargetOfDefs("With [embedded [brackets]] [b].", defs[0..m]).?);
    try std.testing.expectEqualStrings("embedded [brackets]", linkTextOfDefs("With [embedded [brackets]] [b].", defs[0..m]).?);
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
    var fence = false;
    const n = simd.scanLines(doc, &lines, &fence);
    var defs: [8]RefDef = undefined;
    const m = scanRefDefs(doc, lines[0..n], &defs);
    try std.testing.expectEqual(@as(usize, 2), m);
    try std.testing.expectEqualStrings("1", defs[0].label);
    try std.testing.expectEqualStrings("http://example.com/?foo=1&bar=2", defs[0].url);
    try std.testing.expectEqualStrings("2", defs[1].label);
}
