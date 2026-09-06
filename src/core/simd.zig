const std = @import("std");
const builtin = @import("builtin");

/// Wall-clock microsecond budgets are enforced where wall-clock is a stable
/// oracle: consistent-hardware macOS runners (also the product platform).
/// Shared Linux CI VMs measure identical code anywhere from 333 to 483 µs
/// run to run, so there every benchmark still runs and prints its numbers
/// for log review, but only the functional asserts gate. Thresholds
/// (TARGET_* in strict_benchmarks.zig) are identical on all platforms.
pub const enforce_timing_budgets: bool = builtin.os.tag == .macos;

pub const BlockType = enum(u5) {
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
    image = 17,
    link_def = 18,
    html_comment = 19,
};

pub const Line = packed struct(u64) {
    offset: u32,
    len: u20,
    block_type: BlockType,
    indent: u7,
};

pub const VecSize = 32;
pub const ByteVec = @Vector(VecSize, u8);
pub const MaskType = std.meta.Int(.unsigned, VecSize);

/// Emits one Line per set bit in a newline mask. Returns the next line_start.
/// Inlined into the vector loops below; never allocates, never copies text.
inline fn emitNewlines(
    bytes: []const u8,
    base: usize,
    bitmask: MaskType,
    line_start: usize,
    lines_out: []Line,
    line_count: *usize,
    in_code_fence_state: *bool,
    in_comment_state: *bool,
) usize {
    var ls = line_start;
    var mask = bitmask;
    while (mask != 0) {
        const tz = @ctz(mask);
        const nl_pos = base + tz;

        if (line_count.* < lines_out.len) {
            var end_pos = nl_pos;
            if (end_pos > ls and bytes[end_pos - 1] == '\r') {
                end_pos -= 1;
            }
            lines_out[line_count.*] = classifyLine(
                bytes[ls..end_pos],
                @as(u32, @intCast(ls)),
                in_code_fence_state,
                in_comment_state,
            );
            line_count.* += 1;
        }

        ls = nl_pos + 1;
        mask &= mask - 1;
    }
    return ls;
}

/// Scans raw text bytes using vector registers and returns lines.
/// Zero heap allocations during scanning if output buffer is pre-allocated.
///
/// Pass 1 of the lazy two-pass pipeline: coarse block discovery. The SIMD
/// front-end finds every `\n` near memory bandwidth with wide vector
/// compares (lowered to AVX2 on x86-64 / paired 128-bit NEON on ARM —
/// never AVX-512), then classifies each line with a branch-light scalar
/// check. Zero string copies: each Line packs (offset, len, type, indent)
/// into 8 bytes referencing the mmap buffer in place.
pub fn scanLines(
    bytes: []const u8,
    lines_out: []Line,
    in_code_fence_state: *bool,
) usize {
    var line_count: usize = 0;
    var line_start: usize = 0;
    var in_comment: bool = false;
    const in_comment_state: *bool = &in_comment;
    var i: usize = 0;
    const len = bytes.len;

    const nl_vec: ByteVec = @splat('\n');

    // 128-byte quad-vector loop: four compares per iteration keep multiple
    // vector units busy (ILP) while staying on low-power SIMD, and a single
    // combined branch skips bit-twiddling entirely for text without newlines.
    while (i + 4 * VecSize <= len) {
        const chunk0: ByteVec = bytes[i..][0..VecSize].*;
        const chunk1: ByteVec = bytes[i + VecSize ..][0..VecSize].*;
        const chunk2: ByteVec = bytes[i + 2 * VecSize ..][0..VecSize].*;
        const chunk3: ByteVec = bytes[i + 3 * VecSize ..][0..VecSize].*;
        const matches0: @Vector(VecSize, bool) = (chunk0 == nl_vec);
        const matches1: @Vector(VecSize, bool) = (chunk1 == nl_vec);
        const matches2: @Vector(VecSize, bool) = (chunk2 == nl_vec);
        const matches3: @Vector(VecSize, bool) = (chunk3 == nl_vec);
        const bitmask0: MaskType = @as(MaskType, @bitCast(matches0));
        const bitmask1: MaskType = @as(MaskType, @bitCast(matches1));
        const bitmask2: MaskType = @as(MaskType, @bitCast(matches2));
        const bitmask3: MaskType = @as(MaskType, @bitCast(matches3));

        if ((bitmask0 | bitmask1 | bitmask2 | bitmask3) != 0) {
            if (bitmask0 != 0) {
                line_start = emitNewlines(bytes, i, bitmask0, line_start, lines_out, &line_count, in_code_fence_state, in_comment_state);
            }
            if (bitmask1 != 0) {
                line_start = emitNewlines(bytes, i + VecSize, bitmask1, line_start, lines_out, &line_count, in_code_fence_state, in_comment_state);
            }
            if (bitmask2 != 0) {
                line_start = emitNewlines(bytes, i + 2 * VecSize, bitmask2, line_start, lines_out, &line_count, in_code_fence_state, in_comment_state);
            }
            if (bitmask3 != 0) {
                line_start = emitNewlines(bytes, i + 3 * VecSize, bitmask3, line_start, lines_out, &line_count, in_code_fence_state, in_comment_state);
            }
        }
        i += 4 * VecSize;
    }

    // 32-byte single-vector remainder
    while (i + VecSize <= len) {
        const chunk: ByteVec = bytes[i..][0..VecSize].*;
        const matches: @Vector(VecSize, bool) = (chunk == nl_vec);
        const bitmask: MaskType = @as(MaskType, @bitCast(matches));

        if (bitmask != 0) {
            line_start = emitNewlines(bytes, i, bitmask, line_start, lines_out, &line_count, in_code_fence_state, in_comment_state);
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
                lines_out[line_count] = classifyLine(
                    bytes[line_start..end_pos],
                    @as(u32, @intCast(line_start)),
                    in_code_fence_state,
                    in_comment_state,
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
            in_comment_state,
        );
        line_count += 1;
    }

    return line_count;
}

/// True for a thematic break of `marker` (`-`, `*`, `_`): at least three
/// markers with only spaces between/around (`---`, `- - -`, `***`, ...).
/// Contiguous runs fold through the same check, so one helper covers both.
fn isSpacedHr(trimmed: []const u8, marker: u8) bool {
    var count: usize = 0;
    for (trimmed) |c| {
        if (c == marker) {
            count += 1;
        } else if (c != ' ') {
            return false;
        }
    }
    return count >= 3;
}

/// One link reference definition (`[label]: /url "title"`). Slices borrow
/// the document buffer (zero-copy); titles validate the definition but are
/// dropped (no tooltip surface). Only single-line definitions are collected;
/// a title continued on the next line stays literal text.
pub const RefDef = struct {
    label: []const u8,
    url: []const u8,
    line_idx: u32,
};

/// Cold-path upper bound for definitions per document.
pub const MAX_REF_DEFS: usize = 128;

/// End index (at the closing quote/paren) of a `"..."`, `'...'`, or `(...)`
/// title starting at `pos`. Quote titles run greedily to the LAST same-quote
/// whose remainder satisfies the terminator: Markdown 1.0 links
/// `("Title with "quotes" inside")` with the full inner text preserved.
/// Backslash escapes never terminate. `want_paren` selects the terminator:
/// spaces-then-`)` for inline links, spaces-then-EOL for definitions.
pub fn parseTitleEnd(line: []const u8, pos: usize, want_paren: bool) ?usize {
    if (pos >= line.len) return null;
    const q = line[pos];
    if (q == '"' or q == '\'') {
        var j = pos + 1;
        var best: ?usize = null;
        while (j < line.len) {
            if (line[j] == '\\' and j + 1 < line.len) {
                j += 2;
                continue;
            }
            if (line[j] == q) {
                var k = j + 1;
                while (k < line.len and (line[k] == ' ' or line[k] == '\t')) : (k += 1) {}
                const ok = if (want_paren)
                    (k < line.len and line[k] == ')')
                else
                    (k >= line.len);
                if (ok) best = j;
            }
            j += 1;
        }
        return best;
    } else if (q == '(') {
        var depth: usize = 1;
        var k = pos + 1;
        while (k < line.len) {
            if (line[k] == '\\' and k + 1 < line.len) {
                k += 2;
                continue;
            } else if (line[k] == '(') {
                depth += 1;
            } else if (line[k] == ')') {
                depth -= 1;
                if (depth == 0) return k;
            }
            k += 1;
        }
        return null;
    }
    return null;
}

/// Parses a single-line reference definition. Up to 3 leading spaces (a tab
/// or 4th space makes it indented code, never a definition). Returns the
/// label and URL slices, or null when the line is not a valid definition
/// (including a malformed trailing title, which invalidates the whole def).
pub fn parseRefDefLine(line: []const u8) ?struct { label: []const u8, url: []const u8 } {
    var pos: usize = 0;
    var indent: usize = 0;
    while (pos < line.len and line[pos] == ' ') : (pos += 1) {
        indent += 1;
    }
    if (indent >= 4) return null;
    if (pos < line.len and line[pos] == '\t') return null;
    if (pos >= line.len or line[pos] != '[') return null;

    // Label: first raw `]` ends it; raw `[` inside invalidates.
    var j = pos + 1;
    var label_end: ?usize = null;
    while (j < line.len) {
        if (line[j] == '\\' and j + 1 < line.len) {
            j += 2;
            continue;
        }
        if (line[j] == ']') {
            label_end = j;
            break;
        }
        if (line[j] == '[') return null;
        j += 1;
    }
    const le = label_end orelse return null;
    var label = line[pos + 1 .. le];
    while (label.len > 0 and (label[0] == ' ' or label[0] == '\t')) : (label = label[1..]) {}
    while (label.len > 0 and (label[label.len - 1] == ' ' or label[label.len - 1] == '\t')) : (label = label[0 .. label.len - 1]) {}
    if (label.len == 0 or label.len > 999) return null;

    pos = le + 1;
    if (pos >= line.len or line[pos] != ':') return null;
    pos += 1;
    while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) : (pos += 1) {}
    if (pos >= line.len) return null;

    var url_start: usize = pos;
    var url_end: usize = pos;
    if (line[pos] == '<') {
        const gt = std.mem.indexOfScalarPos(u8, line, pos + 1, '>') orelse return null;
        url_start = pos + 1;
        url_end = gt;
        pos = gt + 1;
    } else {
        var end = pos;
        var depth: usize = 0;
        while (end < line.len) {
            const c = line[end];
            if (c == '(') {
                depth += 1;
            } else if (c == ')') {
                if (depth == 0) break;
                depth -= 1;
            } else if (c == ' ' or c == '\t' or c < 0x20) {
                break;
            }
            end += 1;
        }
        if (end == pos) return null;
        url_end = end;
        pos = end;
    }

    while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) : (pos += 1) {}
    if (pos >= line.len) return .{ .label = label, .url = line[url_start..url_end] };

    // Optional same-line title (greedy quotes, Markdown 1.0); anything else
    // invalidates the whole definition.
    const title_end = parseTitleEnd(line, pos, false) orelse return null;
    pos = title_end + 1;
    while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) : (pos += 1) {}
    if (pos != line.len) return null;
    return .{ .label = label, .url = line[url_start..url_end] };
}

/// Cold-path scan of all single-line reference definitions in a document.
/// Zero heap allocations; writes at most `out.len` entries, returns the
/// stored count. First definition wins on duplicate labels (CommonMark).
/// Only lines already classified `.link_def` are collected, so the scan
/// never disagrees with the block classifier.
pub fn scanRefDefs(bytes: []const u8, lines: []const Line, out: []RefDef) usize {
    var count: usize = 0;
    for (lines, 0..) |ln, idx| {
        if (ln.block_type != .link_def) continue;
        const text = bytes[ln.offset..][0..ln.len];
        if (parseRefDefLine(text)) |d| {
            if (count >= out.len) break;
            out[count] = .{ .label = d.label, .url = d.url, .line_idx = @intCast(idx) };
            count += 1;
        }
    }
    return count;
}

/// ASCII case-insensitive label match with inner whitespace collapsed
/// (CommonMark reference matching, line-local edition).
fn matchLabel(a: []const u8, b: []const u8) bool {
    var x = a;
    var y = b;
    while (x.len > 0 and (x[0] == ' ' or x[0] == '\t')) : (x = x[1..]) {}
    while (y.len > 0 and (y[0] == ' ' or y[0] == '\t')) : (y = y[1..]) {}
    // Empty labels never match (an empty `[]` stays literal text).
    if (x.len == 0 or y.len == 0) return false;
    while (x.len > 0 and (x[x.len - 1] == ' ' or x[x.len - 1] == '\t')) : (x = x[0 .. x.len - 1]) {}
    while (y.len > 0 and (y[y.len - 1] == ' ' or y[y.len - 1] == '\t')) : (y = y[0 .. y.len - 1]) {}
    var i: usize = 0;
    var j: usize = 0;
    while (i < x.len and j < y.len) {
        const sx = x[i] == ' ' or x[i] == '\t';
        const sy = y[j] == ' ' or y[j] == '\t';
        if (sx or sy) {
            if (!(sx and sy)) return false;
            while (i < x.len and (x[i] == ' ' or x[i] == '\t')) : (i += 1) {}
            while (j < y.len and (y[j] == ' ' or y[j] == '\t')) : (j += 1) {}
            continue;
        }
        var cx = x[i];
        var cy = y[j];
        if (cx >= 'A' and cx <= 'Z') cx += 32;
        if (cy >= 'A' and cy <= 'Z') cy += 32;
        if (cx != cy) return false;
        i += 1;
        j += 1;
    }
    return i >= x.len and j >= y.len;
}

/// First definition whose label matches (case-insensitive, collapsed).
pub fn findRefDef(defs: []const RefDef, label: []const u8) ?RefDef {
    for (defs) |d| {
        if (matchLabel(d.label, label)) return d;
    }
    return null;
}

/// Fast single-dispatch classifier for a single line of markdown.
/// Inlined into the scan loop; the switch on the first content byte compiles
/// to a jump table, so the common paragraph case costs one indirect jump.
/// `in_comment` tracks CommonMark HTML block type 2 (`<!--` … `-->`)
/// across lines; callers thread one state per scanned document.
pub inline fn classifyLine(line: []const u8, offset: u32, in_code_fence: *bool, in_comment: *bool) Line {
    const raw_len: u20 = @intCast(@min(line.len, (1 << 20) - 1));

    // Fast check for blank lines
    var idx: usize = 0;
    while (idx < line.len and (line[idx] == ' ' or line[idx] == '\t')) : (idx += 1) {}

    const indent: u7 = @intCast(@min(idx, 127));

    if (idx >= line.len) {
        // Blank lines inside an HTML comment belong to the comment block.
        if (in_comment.*) {
            return Line{
                .offset = offset,
                .len = raw_len,
                .block_type = .html_comment,
                .indent = indent,
            };
        }
        return Line{
            .offset = offset,
            .len = raw_len,
            .block_type = .blank,
            .indent = indent,
        };
    }

    const trimmed = line[idx..];
    const first = trimmed[0];

    // HTML comment blocks (CommonMark type 2): opened by `<!--`, closed by
    // the first `-->`, unclosed runs to end of document. Content lines are
    // never rendered; single-line comments never touch the state.
    if (in_comment.*) {
        if (std.mem.indexOf(u8, line, "-->") != null) in_comment.* = false;
        return Line{
            .offset = offset,
            .len = raw_len,
            .block_type = .html_comment,
            .indent = indent,
        };
    }
    if (first == '<' and std.mem.startsWith(u8, trimmed, "<!--")) {
        var iw: usize = 0;
        for (line[0..idx]) |c| {
            iw += if (c == '\t') 4 else 1;
        }
        if (iw < 4) {
            if (std.mem.indexOf(u8, trimmed[4..], "-->") == null) {
                in_comment.* = true;
            }
            return Line{
                .offset = offset,
                .len = raw_len,
                .block_type = .html_comment,
                .indent = indent,
            };
        }
    }

    // Code fence toggle: ``` or ~~~ (only these starters can toggle).
    if ((first == '`' or first == '~') and trimmed.len >= 3 and trimmed[1] == first and trimmed[2] == first) {
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

    // If already inside a code fence, everything is code content.
    // (Resolved before dispatch so fenced code starting with a letter
    // can never be mistaken for a paragraph.)
    if (in_code_fence.*) {
        return Line{
            .offset = offset,
            .len = raw_len,
            .block_type = .code_line,
            .indent = indent,
        };
    }

    // Single dispatch on the first content byte. Each starter character can
    // only open a small subset of block types, so every arm runs the minimal
    // check sequence in the original precedence order.
    switch (first) {
        // Plain-text fast path: the most common line kind, one jump.
        'a'...'z', 'A'...'Z', '"', '\'' => {
            return Line{
                .offset = offset,
                .len = raw_len,
                .block_type = .paragraph,
                .indent = indent,
            };
        },
        // Headings: #, ##, ###, ####, #####, ######
        '#' => {
            var h_level: u8 = 1;
            while (h_level < 6 and h_level < trimmed.len and trimmed[h_level] == '#') : (h_level += 1) {}
            const block_type: BlockType = if (h_level < trimmed.len and trimmed[h_level] == ' ')
                @enumFromInt(h_level)
            else
                .paragraph;
            return Line{
                .offset = offset,
                .len = raw_len,
                .block_type = block_type,
                .indent = indent,
            };
        },
        // Blockquote: >
        '>' => {
            return Line{
                .offset = offset,
                .len = raw_len,
                .block_type = .quote,
                .indent = indent,
            };
        },
        // Task list, hr, or bullet: original precedence task -> hr -> bullet.
        '-', '*', '+' => {
            // Task list: - [ ] or - [x] (tab counts as the space after the
            // marker, matching `-`, `*`, `+` bullet handling below).
            if (trimmed.len >= 5 and
                (trimmed[1] == ' ' or trimmed[1] == '\t') and trimmed[2] == '[' and
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
            // Horizontal rule: ---, ***, and spaced forms (- - -, * * *).
            // (___ and _ _ _ are handled under '_'.)
            if ((first == '-' or first == '*') and isSpacedHr(trimmed, first)) {
                return Line{
                    .offset = offset,
                    .len = raw_len,
                    .block_type = .hr,
                    .indent = indent,
                };
            }
            // Bullet list: - , * , + (tab counts as the following space)
            if (trimmed.len >= 2 and (trimmed[1] == ' ' or trimmed[1] == '\t')) {
                return Line{
                    .offset = offset,
                    .len = raw_len,
                    .block_type = .bullet_list,
                    .indent = indent,
                };
            }
            return Line{
                .offset = offset,
                .len = raw_len,
                .block_type = .paragraph,
                .indent = indent,
            };
        },
        // '_': ___, _ _ _, and spaced variants are hr, else paragraph.
        '_' => {
            if (isSpacedHr(trimmed, '_')) {
                return Line{
                    .offset = offset,
                    .len = raw_len,
                    .block_type = .hr,
                    .indent = indent,
                };
            }
            return Line{
                .offset = offset,
                .len = raw_len,
                .block_type = .paragraph,
                .indent = indent,
            };
        },
        // Standalone image: ![alt](url), else paragraph.
        '!' => {
            if (trimmed.len >= 5 and trimmed[1] == '[') {
                var cb: usize = 2;
                while (cb < trimmed.len and trimmed[cb] != ']') : (cb += 1) {}
                if (cb + 1 < trimmed.len and trimmed[cb + 1] == '(') {
                    var cp: usize = cb + 2;
                    while (cp < trimmed.len and trimmed[cp] != ')') : (cp += 1) {}
                    if (cp < trimmed.len and cp + 1 == trimmed.len) {
                        return Line{
                            .offset = offset,
                            .len = raw_len,
                            .block_type = .image,
                            .indent = indent,
                        };
                    }
                }
            }
            return Line{
                .offset = offset,
                .len = raw_len,
                .block_type = .paragraph,
                .indent = indent,
            };
        },
        // Link reference definition: `[label]: /url "title"` (validated
        // single-line only); use sites stay paragraphs for the inline pass.
        '[' => {
            const block_type: BlockType = if (parseRefDefLine(line) != null)
                .link_def
            else
                .paragraph;
            return Line{
                .offset = offset,
                .len = raw_len,
                .block_type = block_type,
                .indent = indent,
            };
        },
        // Ordered list: digit(s) followed by '.' or ')' and space or tab.
        '0'...'9' => {
            var d_idx: usize = 1;
            while (d_idx < trimmed.len and trimmed[d_idx] >= '0' and trimmed[d_idx] <= '9') : (d_idx += 1) {}
            const block_type: BlockType = if (d_idx + 1 < trimmed.len and (trimmed[d_idx] == '.' or trimmed[d_idx] == ')') and (trimmed[d_idx + 1] == ' ' or trimmed[d_idx + 1] == '\t'))
                .ordered_list
            else
                .paragraph;
            return Line{
                .offset = offset,
                .len = raw_len,
                .block_type = block_type,
                .indent = indent,
            };
        },
        // Table row: starts with |
        '|' => {
            return Line{
                .offset = offset,
                .len = raw_len,
                .block_type = .table_row,
                .indent = indent,
            };
        },
        else => {
            return Line{
                .offset = offset,
                .len = raw_len,
                .block_type = .paragraph,
                .indent = indent,
            };
        },
    }
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
        // Quad-vector stride: 128 bytes per iteration, first match wins.
        // Matches the scanLines widening: halves loop-control overhead on
        // pure-throughput scans. Masks are checked in address order.
        while (i + 4 * VecSize <= haystack.len) : (i += 4 * VecSize) {
            const c0: ByteVec = haystack[i..][0..VecSize].*;
            const c1: ByteVec = haystack[i + VecSize ..][0..VecSize].*;
            const c2: ByteVec = haystack[i + 2 * VecSize ..][0..VecSize].*;
            const c3: ByteVec = haystack[i + 3 * VecSize ..][0..VecSize].*;
            const m0: MaskType = @as(MaskType, @bitCast(@as(@Vector(VecSize, bool), c0 == target_vec)));
            const m1: MaskType = @as(MaskType, @bitCast(@as(@Vector(VecSize, bool), c1 == target_vec)));
            const m2: MaskType = @as(MaskType, @bitCast(@as(@Vector(VecSize, bool), c2 == target_vec)));
            const m3: MaskType = @as(MaskType, @bitCast(@as(@Vector(VecSize, bool), c3 == target_vec)));
            if (m0 != 0) return i + @ctz(m0);
            if (m1 != 0) return i + VecSize + @ctz(m1);
            if (m2 != 0) return i + 2 * VecSize + @ctz(m2);
            if (m3 != 0) return i + 3 * VecSize + @ctz(m3);
        }
        // Dual-vector stride: 64 bytes per iteration, first match wins.
        while (i + 2 * VecSize <= haystack.len) : (i += 2 * VecSize) {
            const chunk0: ByteVec = haystack[i..][0..VecSize].*;
            const chunk1: ByteVec = haystack[i + VecSize ..][0..VecSize].*;
            const mask0: MaskType = @as(MaskType, @bitCast(@as(@Vector(VecSize, bool), chunk0 == target_vec)));
            if (mask0 != 0) {
                return i + @ctz(mask0);
            }
            const mask1: MaskType = @as(MaskType, @bitCast(@as(@Vector(VecSize, bool), chunk1 == target_vec)));
            if (mask1 != 0) {
                return i + VecSize + @ctz(mask1);
            }
        }
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

    // Quad-vector stride: filter 128 bytes per iteration on the first
    // character, verify survivors on last character + full compare.
    // Loads are bounded by haystack.len; candidates by `end`. The chained
    // loops below cover every candidate in [0, end] exactly once. Masks drain
    // in address order so the first document match always wins.
    while (i + 4 * VecSize <= haystack.len) : (i += 4 * VecSize) {
        const chunk0: ByteVec = haystack[i..][0..VecSize].*;
        const chunk1: ByteVec = haystack[i + VecSize ..][0..VecSize].*;
        const chunk2: ByteVec = haystack[i + 2 * VecSize ..][0..VecSize].*;
        const chunk3: ByteVec = haystack[i + 3 * VecSize ..][0..VecSize].*;
        const mask0: MaskType = @as(MaskType, @bitCast(@as(@Vector(VecSize, bool), chunk0 == first_vec)));
        const mask1: MaskType = @as(MaskType, @bitCast(@as(@Vector(VecSize, bool), chunk1 == first_vec)));
        const mask2: MaskType = @as(MaskType, @bitCast(@as(@Vector(VecSize, bool), chunk2 == first_vec)));
        const mask3: MaskType = @as(MaskType, @bitCast(@as(@Vector(VecSize, bool), chunk3 == first_vec)));

        if ((mask0 | mask1 | mask2 | mask3) != 0) {
            var m0 = mask0;
            while (m0 != 0) {
                const tz = @ctz(m0);
                const cand = i + tz;
                if (cand <= end and haystack[cand + needle_len_minus_1] == last_char) {
                    if (std.mem.eql(u8, haystack[cand..][0..needle.len], needle)) {
                        return cand;
                    }
                }
                m0 &= m0 - 1;
            }

            var m1 = mask1;
            while (m1 != 0) {
                const tz = @ctz(m1);
                const cand = i + VecSize + tz;
                if (cand <= end and haystack[cand + needle_len_minus_1] == last_char) {
                    if (std.mem.eql(u8, haystack[cand..][0..needle.len], needle)) {
                        return cand;
                    }
                }
                m1 &= m1 - 1;
            }

            var m2 = mask2;
            while (m2 != 0) {
                const tz = @ctz(m2);
                const cand = i + 2 * VecSize + tz;
                if (cand <= end and haystack[cand + needle_len_minus_1] == last_char) {
                    if (std.mem.eql(u8, haystack[cand..][0..needle.len], needle)) {
                        return cand;
                    }
                }
                m2 &= m2 - 1;
            }

            var m3 = mask3;
            while (m3 != 0) {
                const tz = @ctz(m3);
                const cand = i + 3 * VecSize + tz;
                if (cand <= end and haystack[cand + needle_len_minus_1] == last_char) {
                    if (std.mem.eql(u8, haystack[cand..][0..needle.len], needle)) {
                        return cand;
                    }
                }
                m3 &= m3 - 1;
            }
        }
    }

    // Dual-vector stride: same filter/verify for the 64-byte remainder window.
    while (i + 2 * VecSize <= haystack.len) : (i += 2 * VecSize) {
        const chunk0: ByteVec = haystack[i..][0..VecSize].*;
        const matches0: @Vector(VecSize, bool) = (chunk0 == first_vec);
        var mask0: MaskType = @as(MaskType, @bitCast(matches0));

        while (mask0 != 0) {
            const tz = @ctz(mask0);
            const cand = i + tz;
            if (cand <= end and haystack[cand + needle_len_minus_1] == last_char) {
                if (std.mem.eql(u8, haystack[cand..][0..needle.len], needle)) {
                    return cand;
                }
            }
            mask0 &= mask0 - 1;
        }

        const chunk1: ByteVec = haystack[i + VecSize ..][0..VecSize].*;
        const matches1: @Vector(VecSize, bool) = (chunk1 == first_vec);
        var mask1: MaskType = @as(MaskType, @bitCast(matches1));

        while (mask1 != 0) {
            const tz = @ctz(mask1);
            const cand = i + VecSize + tz;
            if (cand <= end and haystack[cand + needle_len_minus_1] == last_char) {
                if (std.mem.eql(u8, haystack[cand..][0..needle.len], needle)) {
                    return cand;
                }
            }
            mask1 &= mask1 - 1;
        }
    }

    while (i + VecSize <= haystack.len) : (i += VecSize) {
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

// ============================================================================
// Pass 1 (coarse): lightweight SIMD helpers for lazy two-pass parsing.
// These run once over the mmap buffer up front; Pass 2 (inline refinement
// in parser.zig) runs only for lines inside the viewport. Everything here
// is zero-allocation and copies no string data — only u32 offsets/counts.
// ============================================================================

/// Counts `\n` bytes with quad-vector SIMD. Used for heuristic scrollbar
/// estimation: estimated_doc_height = countNewlines(buf) * line_height.
/// Zero allocations; touches each byte once.
pub fn countNewlines(bytes: []const u8) usize {
    var total: usize = 0;
    var i: usize = 0;
    const len = bytes.len;
    const nl_vec: ByteVec = @splat('\n');

    while (i + 4 * VecSize <= len) : (i += 4 * VecSize) {
        const chunk0: ByteVec = bytes[i..][0..VecSize].*;
        const chunk1: ByteVec = bytes[i + VecSize ..][0..VecSize].*;
        const chunk2: ByteVec = bytes[i + 2 * VecSize ..][0..VecSize].*;
        const chunk3: ByteVec = bytes[i + 3 * VecSize ..][0..VecSize].*;
        const m0: MaskType = @as(MaskType, @bitCast(@as(@Vector(VecSize, bool), chunk0 == nl_vec)));
        const m1: MaskType = @as(MaskType, @bitCast(@as(@Vector(VecSize, bool), chunk1 == nl_vec)));
        const m2: MaskType = @as(MaskType, @bitCast(@as(@Vector(VecSize, bool), chunk2 == nl_vec)));
        const m3: MaskType = @as(MaskType, @bitCast(@as(@Vector(VecSize, bool), chunk3 == nl_vec)));
        total += @popCount(m0) + @popCount(m1) + @popCount(m2) + @popCount(m3);
    }
    while (i + VecSize <= len) : (i += VecSize) {
        const chunk: ByteVec = bytes[i..][0..VecSize].*;
        const m: MaskType = @as(MaskType, @bitCast(@as(@Vector(VecSize, bool), chunk == nl_vec)));
        total += @popCount(m);
    }
    while (i < len) : (i += 1) {
        if (bytes[i] == '\n') total += 1;
    }
    return total;
}

/// Indexed block map for O(1)-ish random access on deep scrollbar jumps.
/// Records the u32 file offset of every block start: byte 0 plus the first
/// byte of each line that follows a blank line (`\n\n`, tolerating `\r\n`).
/// A 50,000-line book yields ~10k offsets (~40 KB); callers keep a smaller
/// prefix when RAM is tight. Zero string copies — pure offset arithmetic.
/// Returns the number of offsets written (never exceeds offsets_out.len).
pub fn scanBlockOffsets(bytes: []const u8, offsets_out: []u32) usize {
    if (offsets_out.len == 0 or bytes.len == 0) return 0;
    const max_u32: usize = std.math.maxInt(u32);

    var count: usize = 0;
    offsets_out[0] = 0;
    count = 1;

    var i: usize = 0;
    const len = bytes.len;
    const nl_vec: ByteVec = @splat('\n');

    // check_nl(p): p is known to hold '\n'; emit p+1 when the line it opens
    // follows a blank line, i.e. the previous byte is '\n' (LF) or the
    // previous two bytes are "\n\r" (CRLF blank line "…\n\r\n").
    // Inlined as a helper to share across vector/scalar loops.
    const consider = struct {
        inline fn run(p: usize, buf: []const u8, out: []u32, n: *usize, total_len: usize) void {
            const line_start = p + 1;
            if (line_start >= total_len) return; // trailing newline opens no block
            if (line_start > max_u32) return; // map covers the first 4 GiB
            var prev_blank = false;
            if (p >= 1 and buf[p - 1] == '\n') {
                prev_blank = true;
            } else if (p >= 2 and buf[p - 1] == '\r' and buf[p - 2] == '\n') {
                prev_blank = true;
            }
            if (prev_blank and n.* < out.len) {
                out[n.*] = @intCast(line_start);
                n.* += 1;
            }
        }
    }.run;

    while (i + 4 * VecSize <= len) {
        const chunk0: ByteVec = bytes[i..][0..VecSize].*;
        const chunk1: ByteVec = bytes[i + VecSize ..][0..VecSize].*;
        const chunk2: ByteVec = bytes[i + 2 * VecSize ..][0..VecSize].*;
        const chunk3: ByteVec = bytes[i + 3 * VecSize ..][0..VecSize].*;
        const m0: MaskType = @as(MaskType, @bitCast(@as(@Vector(VecSize, bool), chunk0 == nl_vec)));
        const m1: MaskType = @as(MaskType, @bitCast(@as(@Vector(VecSize, bool), chunk1 == nl_vec)));
        const m2: MaskType = @as(MaskType, @bitCast(@as(@Vector(VecSize, bool), chunk2 == nl_vec)));
        const m3: MaskType = @as(MaskType, @bitCast(@as(@Vector(VecSize, bool), chunk3 == nl_vec)));
        if ((m0 | m1 | m2 | m3) != 0) {
            var m = m0;
            while (m != 0) {
                const p = i + @ctz(m);
                consider(p, bytes, offsets_out, &count, len);
                m &= m - 1;
            }
            m = m1;
            while (m != 0) {
                const p = i + VecSize + @ctz(m);
                consider(p, bytes, offsets_out, &count, len);
                m &= m - 1;
            }
            m = m2;
            while (m != 0) {
                const p = i + 2 * VecSize + @ctz(m);
                consider(p, bytes, offsets_out, &count, len);
                m &= m - 1;
            }
            m = m3;
            while (m != 0) {
                const p = i + 3 * VecSize + @ctz(m);
                consider(p, bytes, offsets_out, &count, len);
                m &= m - 1;
            }
        }
        i += 4 * VecSize;
    }
    while (i + VecSize <= len) {
        const chunk: ByteVec = bytes[i..][0..VecSize].*;
        const m_init: MaskType = @as(MaskType, @bitCast(@as(@Vector(VecSize, bool), chunk == nl_vec)));
        var m = m_init;
        while (m != 0) {
            const p = i + @ctz(m);
            consider(p, bytes, offsets_out, &count, len);
            m &= m - 1;
        }
        i += VecSize;
    }
    while (i < len) : (i += 1) {
        if (bytes[i] == '\n') consider(i, bytes, offsets_out, &count, len);
    }

    return count;
}

/// Binary-searches a block map from scanBlockOffsets: returns the index of
/// the greatest offset <= target (0 when the map is empty). A scrollbar
/// jump to `fraction` of the file seeks to `map[findBlockForOffset(map,
/// fraction * total_len)]` and resumes parsing there — no rescan.
pub fn findBlockForOffset(offsets: []const u32, target: u32) usize {
    if (offsets.len == 0) return 0;
    var lo: usize = 0;
    var hi: usize = offsets.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (offsets[mid] <= target) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return if (lo == 0) 0 else lo - 1;
}

test "pass1: countNewlines matches scalar count" {
    const doc = "# H1\n\npara one\npara two\n\n> quote\n";
    var expect: usize = 0;
    for (doc) |c| {
        if (c == '\n') expect += 1;
    }
    try std.testing.expectEqual(expect, countNewlines(doc));
    try std.testing.expectEqual(@as(usize, 0), countNewlines(""));
    try std.testing.expectEqual(@as(usize, 0), countNewlines("no newlines here"));
}

test "pass1: scanBlockOffsets finds blank-line-separated blocks" {
    // Offsets: 0:"# H1" 5:"" 6:"para one" — "para two" directly follows a
    // non-blank line so it is NOT a block start; "" then "> quote" is.
    const doc = "# H1\n\npara one\npara two\n\n> quote\n";
    var offsets: [8]u32 = undefined;
    const n = scanBlockOffsets(doc, &offsets);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(@as(u32, 0), offsets[0]);
    try std.testing.expectEqual(@as(u32, 6), offsets[1]);
    try std.testing.expectEqual(@as(u32, 25), offsets[2]);

    // CRLF blank lines count too.
    const crlf = "a\r\n\r\nb\r\n";
    var offsets2: [8]u32 = undefined;
    const n2 = scanBlockOffsets(crlf, &offsets2);
    try std.testing.expectEqual(@as(usize, 2), n2);
    try std.testing.expectEqual(@as(u32, 0), offsets2[0]);
    try std.testing.expectEqual(@as(u32, 5), offsets2[1]);

    // Empty input and zero-capacity output.
    var dummy: [1]u32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), scanBlockOffsets("", &dummy));
    try std.testing.expectEqual(@as(usize, 0), scanBlockOffsets(doc, &.{}));
}

test "pass1: findBlockForOffset binary search" {
    const map = [_]u32{ 0, 6, 25, 100 };
    try std.testing.expectEqual(@as(usize, 0), findBlockForOffset(&map, 0));
    try std.testing.expectEqual(@as(usize, 0), findBlockForOffset(&map, 5));
    try std.testing.expectEqual(@as(usize, 1), findBlockForOffset(&map, 6));
    try std.testing.expectEqual(@as(usize, 1), findBlockForOffset(&map, 24));
    try std.testing.expectEqual(@as(usize, 2), findBlockForOffset(&map, 25));
    try std.testing.expectEqual(@as(usize, 3), findBlockForOffset(&map, 1000));
    try std.testing.expectEqual(@as(usize, 0), findBlockForOffset(&.{}, 50));
}

fn classifyOne(line: []const u8) BlockType {
    var lines: [1]Line = undefined;
    var fence = false;
    const n = scanLines(line, &lines, &fence);
    std.debug.assert(n == 1);
    return lines[0].block_type;
}

test "classify: tab after bullet/task markers, spaced thematic breaks" {
    // Tab counts as the space after -, *, + bullets and task markers.
    try std.testing.expectEqual(BlockType.bullet_list, classifyOne("*\tasterisk 1"));
    try std.testing.expectEqual(BlockType.bullet_list, classifyOne("+\tPlus 1"));
    try std.testing.expectEqual(BlockType.bullet_list, classifyOne("-\tMinus 1"));
    try std.testing.expectEqual(BlockType.task_list, classifyOne("-\t[ ] spaced task"));
    try std.testing.expectEqual(BlockType.bullet_list, classifyOne("* space bullet"));
    // Spaced thematic breaks for -, *, _ (up to 3 leading spaces).
    try std.testing.expectEqual(BlockType.hr, classifyOne("- - -"));
    try std.testing.expectEqual(BlockType.hr, classifyOne(" * * *"));
    try std.testing.expectEqual(BlockType.hr, classifyOne("  - - -"));
    try std.testing.expectEqual(BlockType.hr, classifyOne("_ _ _"));
    try std.testing.expectEqual(BlockType.hr, classifyOne("___"));
    try std.testing.expectEqual(BlockType.hr, classifyOne("---"));
    // Near-misses stay lists and paragraphs.
    try std.testing.expectEqual(BlockType.bullet_list, classifyOne("- - foo"));
    try std.testing.expectEqual(BlockType.paragraph, classifyOne("*foo"));
    try std.testing.expectEqual(BlockType.paragraph, classifyOne("--"));
    // Ordered markers accept tabs; paren delimiters work with spaces.
    // (A non-1 start still classifies ordered; the no-interrupt rule that
    // keeps `Version\n8. x` flowing as one paragraph lives at layout.)
    try std.testing.expectEqual(BlockType.ordered_list, classifyOne("1.\tFirst"));
    try std.testing.expectEqual(BlockType.ordered_list, classifyOne("2) Paren"));
    try std.testing.expectEqual(BlockType.ordered_list, classifyOne("8. Laplace"));
}

test "classify: link definitions and HTML comments" {
    // Valid single-line definitions (0-3 spaces of indent).
    try std.testing.expectEqual(BlockType.link_def, classifyOne("[1]: /url/"));
    try std.testing.expectEqual(BlockType.link_def, classifyOne(" [once]: /url"));
    try std.testing.expectEqual(BlockType.link_def, classifyOne("[2]: http://att.com/  \"AT&T\""));
    // Use sites, indented code, and garbage tails are not definitions
    // (greedy quote titles stay valid, Markdown 1.0).
    try std.testing.expectEqual(BlockType.paragraph, classifyOne("Foo [bar] [1]."));
    try std.testing.expectEqual(BlockType.paragraph, classifyOne("    [four]: /url"));
    try std.testing.expectEqual(BlockType.link_def, classifyOne("[b]: /url/ \"bad \"q\" t\""));
    try std.testing.expectEqual(BlockType.paragraph, classifyOne("[1]."));

    // Comment blocks hide from the single line to the multiline span.
    const doc = "one\n<!-- x -->\n<!--\nbody\n-->\nafter\n<div>\n";
    var lines: [8]Line = undefined;
    var fence = false;
    const n = scanLines(doc, &lines, &fence);
    try std.testing.expectEqual(@as(usize, 7), n);
    try std.testing.expectEqual(BlockType.paragraph, lines[0].block_type);
    try std.testing.expectEqual(BlockType.html_comment, lines[1].block_type);
    try std.testing.expectEqual(BlockType.html_comment, lines[2].block_type);
    try std.testing.expectEqual(BlockType.html_comment, lines[3].block_type);
    try std.testing.expectEqual(BlockType.html_comment, lines[4].block_type);
    try std.testing.expectEqual(BlockType.paragraph, lines[5].block_type);
    // Other inline HTML is literal text, never a comment.
    try std.testing.expectEqual(BlockType.paragraph, lines[6].block_type);
    try std.testing.expect(!fence);
}

fn recordBlockRun(bytes_inner: []const u8, nl_pos: usize, out: []u32, n: *usize) void {
    // Only record the start of a blank run: previous byte must not be '\n'
    // so `\n\n\n` yields a single boundary, not two.
    if (nl_pos > 0 and bytes_inner[nl_pos - 1] == '\n') return;
    var next: usize = nl_pos + 1;
    // Tolerate CRLF blank lines: `\n\r\n`.
    if (next < bytes_inner.len and bytes_inner[next] == '\r') next += 1;
    if (next >= bytes_inner.len or bytes_inner[next] != '\n') return;
    var block_start = next + 1;
    // Collapse runs (`\n\n\n`, `\n\r\n`) so each blank separator yields one entry.
    while (block_start < bytes_inner.len and (bytes_inner[block_start] == '\n' or bytes_inner[block_start] == '\r')) {
        block_start += 1;
    }
    if (block_start >= bytes_inner.len) return;
    if (block_start > std.math.maxInt(u32)) return;
    if (n.* >= out.len) return;
    out[n.*] = @intCast(block_start);
    n.* += 1;
}

/// Indexed block map for O(1) random-access jumps (todo/ideas.txt).
/// Records one u32 file offset per blank-line separator run (`\n\n`),
/// pointing at the first byte of the next block. A 1MB book with ~5k
/// paragraphs costs ~20KB. Zero heap allocations: caller provides `offsets_out`.
/// Returns the number of entries stored (truncated if the buffer is full).
/// Detection reuses the same 32-byte SIMD newline census as countNewlines;
/// only the `\n\n` adjacency check is scalar over newline positions.
pub fn buildBlockMap(bytes: []const u8, offsets_out: []u32) usize {
    if (bytes.len < 2 or offsets_out.len == 0) return 0;
    var count: usize = 0;
    var i: usize = 0;
    const len = bytes.len;
    const nl_vec: ByteVec = @splat('\n');

    while (i + 2 * VecSize <= len) {
        const chunk0: ByteVec = bytes[i..][0..VecSize].*;
        const chunk1: ByteVec = bytes[i + VecSize ..][0..VecSize].*;
        var m0: MaskType = @as(MaskType, @bitCast(chunk0 == nl_vec));
        var m1: MaskType = @as(MaskType, @bitCast(chunk1 == nl_vec));
        while (m0 != 0) {
            const tz = @ctz(m0);
            recordBlockRun(bytes, i + tz, offsets_out, &count);
            if (count >= offsets_out.len) return count;
            m0 &= m0 - 1;
        }
        while (m1 != 0) {
            const tz = @ctz(m1);
            recordBlockRun(bytes, i + VecSize + tz, offsets_out, &count);
            if (count >= offsets_out.len) return count;
            m1 &= m1 - 1;
        }
        i += 2 * VecSize;
    }
    while (i + VecSize <= len) {
        const chunk: ByteVec = bytes[i..][0..VecSize].*;
        var m: MaskType = @as(MaskType, @bitCast(chunk == nl_vec));
        while (m != 0) {
            const tz = @ctz(m);
            recordBlockRun(bytes, i + tz, offsets_out, &count);
            if (count >= offsets_out.len) return count;
            m &= m - 1;
        }
        i += VecSize;
    }
    while (i < len) : (i += 1) {
        if (bytes[i] == '\n') {
            recordBlockRun(bytes, i, offsets_out, &count);
            if (count >= offsets_out.len) return count;
        }
    }
    return count;
}

/// O(1) jump: byte offset of the block boundary nearest `fraction` (0..1)
/// down the block map. Index arithmetic only; no scanning.
pub fn blockOffsetForFraction(block_map: []const u32, fraction: f32) u32 {
    if (block_map.len == 0) return 0;
    const f = std.math.clamp(fraction, 0.0, 1.0);
    const scaled = f * @as(f32, @floatFromInt(block_map.len));
    var idx: usize = @intFromFloat(scaled);
    if (idx >= block_map.len) idx = block_map.len - 1;
    return block_map[idx];
}

/// Binary search over `lines` (sorted by offset) for the last line with
/// `offset <= target_byte`. O(log N); under a microsecond for book-scale
/// line counts. Returns 0 when no line starts at or before the target.
pub fn byteOffsetToLineIndex(lines: []const Line, target_byte: u32) usize {
    if (lines.len == 0) return 0;
    var left: usize = 0;
    var right: usize = lines.len;
    var best: usize = 0;
    var found = false;
    while (left < right) {
        const mid = left + (right - left) / 2;
        if (lines[mid].offset <= target_byte) {
            best = mid;
            found = true;
            left = mid + 1;
        } else {
            right = mid;
        }
    }
    return if (found) best else 0;
}

test "scroll illusion: SIMD newline census matches scalar count" {
    const samples = [_][]const u8{
        "",
        "no newlines here",
        "\n",
        "a\nb\nc\n",
        "para one\n\npara two\n\npara three\n",
        "l1\r\nl2\r\n\r\nl3\r\n",
    };
    for (samples) |s| {
        var expected: usize = 0;
        for (s) |c| if (c == '\n') {
            expected += 1;
        };
        try std.testing.expectEqual(expected, countNewlines(s));
    }

    // Long buffer crossing all vector paths (dual-loop, single-loop, tail).
    var long: [1000]u8 = undefined;
    @memset(&long, 'x');
    var want: usize = 0;
    var k: usize = 0;
    while (k < long.len) : (k += 7) {
        long[k] = '\n';
        want += 1;
    }
    try std.testing.expectEqual(want, countNewlines(&long));
}

test "scroll illusion: block map records one u32 per blank separator" {
    const doc = "para one\n\npara two\n\n\npara three\nlast line no blank\n";
    var map: [16]u32 = undefined;
    const n = buildBlockMap(doc, &map);
    // Runs: after "para one", after "para two" (triple \n collapses to one).
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("para two", doc[map[0]..][0.."para two".len]);
    try std.testing.expectEqualStrings("para three", doc[map[1]..][0.."para three".len]);
    // Sorted ascending, each inside the buffer.
    try std.testing.expect(map[0] < map[1]);
    for (map[0..n]) |off| try std.testing.expect(off < doc.len);

    // O(1) fraction jump: 0 -> first block, ~1 -> last block.
    try std.testing.expectEqual(map[0], blockOffsetForFraction(map[0..n], 0.0));
    try std.testing.expectEqual(map[n - 1], blockOffsetForFraction(map[0..n], 1.0));
    // Empty map is a safe zero.
    try std.testing.expectEqual(@as(u32, 0), blockOffsetForFraction(&.{}, 0.75));

    // Binary search from byte offset back to line index.
    var lines: [16]Line = undefined;
    var fence = false;
    const lc = scanLines(doc, &lines, &fence);
    const idx = byteOffsetToLineIndex(lines[0..lc], map[0]);
    try std.testing.expectEqual(map[0], lines[idx].offset);
}
