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

        // Bold ** or Italic *
        if (c == '*' or c == '_') {
            const is_double = (i + 1 < line.len and line[i + 1] == c);
            const delim_len: usize = if (is_double) 2 else 1;

            if (i > span_start) {
                spans_out[span_count] = .{
                    .text = line[span_start..i],
                    .style = cur_style,
                };
                span_count += 1;
                if (span_count >= spans_out.len) break;
            }

            if (is_double) {
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
