const std = @import("std");

pub const BlockType = enum(u8) {
    paragraph = 0,
    heading1 = 1,
    heading2 = 2,
    heading3 = 3,
    heading4 = 4,
    heading5 = 5,
    heading6 = 6,
    quote = 7,
    bullet_list = 8,
    ordered_list = 9,
    code_fence_start = 10,
    code_line = 11,
    code_fence_end = 12,
    hr = 13,
    table_row = 14,
    blank = 15,
    task_list = 16,
};

pub const Line = struct {
    offset: u32,
    len: u32,
    block_type: BlockType,
    indent: u8,
};

pub const VecSize = 32;
pub const ByteVec = @Vector(VecSize, u8);
pub const MaskType = std.meta.Int(.unsigned, VecSize);

/// Scans raw text bytes using vector registers and returns lines.
/// Zero heap allocations during scanning if output buffer is pre-allocated.
pub fn scanLines(
    bytes: []const u8,
    lines_out: []Line,
    in_code_fence_state: *bool,
) usize {
    var line_count: usize = 0;
    var line_start: usize = 0;
    var i: usize = 0;
    const len = bytes.len;

    const nl_vec: ByteVec = @splat('\n');

    while (i + VecSize <= len) {
        const chunk: ByteVec = bytes[i..][0..VecSize].*;
        const matches: @Vector(VecSize, bool) = (chunk == nl_vec);
        const bitmask: MaskType = @as(MaskType, @bitCast(matches));

        if (bitmask != 0) {
            var mask = bitmask;
            while (mask != 0) {
                const tz = @ctz(mask);
                const nl_pos = i + tz;

                if (line_count < lines_out.len) {
                    var end_pos = nl_pos;
                    if (end_pos > line_start and bytes[end_pos - 1] == '\r') {
                        end_pos -= 1;
                    }
                    const line_bytes = bytes[line_start..end_pos];
                    lines_out[line_count] = classifyLine(
                        line_bytes,
                        @as(u32, @intCast(line_start)),
                        in_code_fence_state,
                    );
                    line_count += 1;
                }

                line_start = nl_pos + 1;
                // Clear the lowest set bit
                mask &= mask - 1;
            }
        }
        i += VecSize;
    }

    // Scalar tail for remainder
    while (i < len) : (i += 1) {
        if (bytes[i] == '\n') {
            if (line_count < lines_out.len) {
                var end_pos = i;
                if (end_pos > line_start and bytes[end_pos - 1] == '\r') {
                    end_pos -= 1;
                }
                const line_bytes = bytes[line_start..end_pos];
                lines_out[line_count] = classifyLine(
                    line_bytes,
                    @as(u32, @intCast(line_start)),
                    in_code_fence_state,
                );
                line_count += 1;
            }
            line_start = i + 1;
        }
    }

    // Final line without trailing newline
    if (line_start < len and line_count < lines_out.len) {
        const line_bytes = bytes[line_start..len];
        lines_out[line_count] = classifyLine(
            line_bytes,
            @as(u32, @intCast(line_start)),
            in_code_fence_state,
        );
        line_count += 1;
    }

    return line_count;
}

/// Fast branchless/minimal-branch classifier for a single line of markdown
pub fn classifyLine(line: []const u8, offset: u32, in_code_fence: *bool) Line {
    const raw_len: u32 = @intCast(line.len);

    // Fast check for blank lines
    var idx: usize = 0;
    while (idx < line.len and (line[idx] == ' ' or line[idx] == '\t')) : (idx += 1) {}

    const indent: u8 = @intCast(@min(idx, 255));

    if (idx >= line.len) {
        return Line{
            .offset = offset,
            .len = raw_len,
            .block_type = .blank,
            .indent = indent,
        };
    }

    const trimmed = line[idx..];

    // Check code fence toggle: ``` or ~~~
    if (trimmed.len >= 3 and
        ((trimmed[0] == '`' and trimmed[1] == '`' and trimmed[2] == '`') or
        (trimmed[0] == '~' and trimmed[1] == '~' and trimmed[2] == '~')))
    {
        if (in_code_fence.*) {
            in_code_fence.* = false;
            return Line{
                .offset = offset,
                .len = raw_len,
                .block_type = .code_fence_end,
                .indent = indent,
            };
        } else {
            in_code_fence.* = true;
            return Line{
                .offset = offset,
                .len = raw_len,
                .block_type = .code_fence_start,
                .indent = indent,
            };
        }
    }

    // If already inside a code fence, everything is code content
    if (in_code_fence.*) {
        return Line{
            .offset = offset,
            .len = raw_len,
            .block_type = .code_line,
            .indent = indent,
        };
    }

    // Task list: - [ ] or - [x] or * [ ] or * [x]
    if (trimmed.len >= 5 and
        (trimmed[0] == '-' or trimmed[0] == '*' or trimmed[0] == '+') and
        trimmed[1] == ' ' and trimmed[2] == '[' and
        (trimmed[3] == ' ' or trimmed[3] == 'x' or trimmed[3] == 'X') and
        trimmed[4] == ']')
    {
        return Line{
            .offset = offset,
            .len = raw_len,
            .block_type = .task_list,
            .indent = indent,
        };
    }

    const first = trimmed[0];
    // High-probability fast path: normal text paragraphs starting with letter/quote
    if ((first >= 'a' and first <= 'z') or (first >= 'A' and first <= 'Z') or first == '"' or first == '\'') {
        return Line{
            .offset = offset,
            .len = raw_len,
            .block_type = .paragraph,
            .indent = indent,
        };
    }

    // Headings: #, ##, ###, ####, #####, ######
    if (first == '#') {
        var h_level: u8 = 1;
        while (h_level < 6 and h_level < trimmed.len and trimmed[h_level] == '#') : (h_level += 1) {}
        if (h_level < trimmed.len and trimmed[h_level] == ' ') {
            return Line{
                .offset = offset,
                .len = raw_len,
                .block_type = @enumFromInt(h_level),
                .indent = indent,
            };
        }
    }

    // Blockquote: >
    if (trimmed[0] == '>') {
        return Line{
            .offset = offset,
            .len = raw_len,
            .block_type = .quote,
            .indent = indent,
        };
    }

    // Horizontal rule: ---, ***, ___
    if (trimmed.len >= 3 and
        ((trimmed[0] == '-' and trimmed[1] == '-' and trimmed[2] == '-') or
        (trimmed[0] == '*' and trimmed[1] == '*' and trimmed[2] == '*') or
        (trimmed[0] == '_' and trimmed[1] == '_' and trimmed[2] == '_')))
    {
        var is_hr = true;
        for (trimmed) |c| {
            if (c != trimmed[0] and c != ' ') {
                is_hr = false;
                break;
            }
        }
        if (is_hr) {
            return Line{
                .offset = offset,
                .len = raw_len,
                .block_type = .hr,
                .indent = indent,
            };
        }
    }

    // Bullet list: - , * , +
    if (trimmed.len >= 2 and
        (trimmed[0] == '-' or trimmed[0] == '*' or trimmed[0] == '+') and
        trimmed[1] == ' ')
    {
        return Line{
            .offset = offset,
            .len = raw_len,
            .block_type = .bullet_list,
            .indent = indent,
        };
    }

    // Ordered list: digit(s) followed by '.' or ')' and space
    if (trimmed[0] >= '0' and trimmed[0] <= '9') {
        var d_idx: usize = 1;
        while (d_idx < trimmed.len and trimmed[d_idx] >= '0' and trimmed[d_idx] <= '9') : (d_idx += 1) {}
        if (d_idx + 1 < trimmed.len and (trimmed[d_idx] == '.' or trimmed[d_idx] == ')') and trimmed[d_idx + 1] == ' ') {
            return Line{
                .offset = offset,
                .len = raw_len,
                .block_type = .ordered_list,
                .indent = indent,
            };
        }
    }

    // Table row: starts with |
    if (trimmed[0] == '|') {
        return Line{
            .offset = offset,
            .len = raw_len,
            .block_type = .table_row,
            .indent = indent,
        };
    }

    return Line{
        .offset = offset,
        .len = raw_len,
        .block_type = .paragraph,
        .indent = indent,
    };
}

/// Microsecond hardware-vector accelerated substring search.
/// Scans 32 bytes per cycle comparing first character, then fast-checks last character,
/// then verifies candidate slice.
pub fn simdSearch(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;

    if (needle.len == 1) {
        const target = needle[0];
        const target_vec: ByteVec = @splat(target);
        var i: usize = 0;
        while (i + VecSize <= haystack.len) : (i += VecSize) {
            const chunk: ByteVec = haystack[i..][0..VecSize].*;
            const matches: @Vector(VecSize, bool) = (chunk == target_vec);
            const mask: MaskType = @as(MaskType, @bitCast(matches));
            if (mask != 0) {
                return i + @ctz(mask);
            }
        }
        while (i < haystack.len) : (i += 1) {
            if (haystack[i] == target) return i;
        }
        return null;
    }

    const first_char = needle[0];
    const last_char = needle[needle.len - 1];
    const first_vec: ByteVec = @splat(first_char);
    const needle_len_minus_1 = needle.len - 1;

    var i: usize = 0;
    if (haystack.len < needle.len) return null;
    const end = haystack.len - needle.len;

    while (i + VecSize <= end) : (i += VecSize) {
        const chunk: ByteVec = haystack[i..][0..VecSize].*;
        const matches: @Vector(VecSize, bool) = (chunk == first_vec);
        var mask: MaskType = @as(MaskType, @bitCast(matches));

        while (mask != 0) {
            const tz = @ctz(mask);
            const cand = i + tz;
            if (cand <= end and haystack[cand + needle_len_minus_1] == last_char) {
                if (std.mem.eql(u8, haystack[cand..][0..needle.len], needle)) {
                    return cand;
                }
            }
            mask &= mask - 1;
        }
    }

    // Scalar remainder
    while (i <= end) : (i += 1) {
        if (haystack[i] == first_char and haystack[i + needle_len_minus_1] == last_char) {
            if (std.mem.eql(u8, haystack[i..][0..needle.len], needle)) {
                return i;
            }
        }
    }

    return null;
}
