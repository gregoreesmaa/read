const std = @import("std");
const simd = @import("simd.zig");

/// Flat SoA block-index store (see todo/ideas2.txt:3-7).
///
/// Zero-copy: a Block holds only integer anchors (`start`/`len`) into the
/// mmap buffer plus u32 relationship indices. No heap strings, no pointers.
/// Backed by `std.MultiArrayList` so each field lives in its own dense array
/// (Struct of Arrays), keeping the CPU prefetcher saturated on traversal.
///
/// Hierarchy is index-based: `parent`, `first_child`, `next_sibling` are
/// block indices, with `NULL_IDX` for "none". The reader's block model is
/// flat (viewport renders a linear block stream), so every block is a root
/// linked through `next_sibling`; `parent`/`first_child` are reserved as
/// u32 indices for future nesting without changing the layout.

pub const NULL_IDX: u32 = std.math.maxInt(u32);

pub const Block = struct {
    start: u32,
    len: u32,
    line_start: u32,
    line_count: u32,
    parent: u32 = NULL_IDX,
    first_child: u32 = NULL_IDX,
    next_sibling: u32 = NULL_IDX,
    tag: simd.BlockType = .paragraph,
};

/// A fenced code region folds into a single block; headings, rules, images,
/// and fence markers are always standalone. All other consecutive lines of
/// the same block type fold into one block. Blank lines are separators and
/// never produce blocks.
fn isStandalone(tag: simd.BlockType) bool {
    return switch (tag) {
        .heading1, .heading2, .heading3, .heading4, .heading5, .heading6, .hr, .image, .code_fence_start, .code_fence_end, .link_def, .html_comment, .html_block, .html_hidden => true,
        else => false,
    };
}

/// Fold a scanned `Line` slice into caller-provided block storage.
/// Zero heap allocations; writes at most `blocks_out.len` entries and
/// returns the count. Wires the `next_sibling` chain; `parent`/`first_child`
/// stay `NULL_IDX` (flat root list).
pub fn buildInto(lines: []const simd.Line, blocks_out: []Block) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < lines.len) {
        if (lines[i].block_type == .blank) {
            i += 1;
            continue;
        }
        if (count >= blocks_out.len) break;

        const tag = lines[i].block_type;
        const start_line = i;
        var end_line = i;

        if (tag == .code_fence_start) {
            // Fold fence start .. matching fence end (or EOF) into one block.
            end_line = i;
            var j = i + 1;
            while (j < lines.len) : (j += 1) {
                end_line = j;
                if (lines[j].block_type == .code_fence_end) break;
            }
            i = end_line + 1;
        } else if (isStandalone(tag)) {
            i += 1;
        } else {
            var j = i + 1;
            while (j < lines.len and lines[j].block_type == tag and !isStandalone(lines[j].block_type)) : (j += 1) {
                end_line = j;
            }
            i = end_line + 1;
        }

        const first = lines[start_line];
        const last = lines[end_line];
        const start: usize = first.offset;
        const end: usize = @as(usize, last.offset) + last.len;
        blocks_out[count] = .{
            .start = @intCast(start),
            .len = @intCast(end - start),
            .line_start = @intCast(start_line),
            .line_count = @intCast(end_line - start_line + 1),
            .tag = if (tag == .code_fence_start) .code_fence_start else tag,
            .next_sibling = NULL_IDX,
        };
        if (count > 0) blocks_out[count - 1].next_sibling = @intCast(count);
        count += 1;
    }
    return count;
}

test "block store: 8-byte Line invariance" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(simd.Line));
    comptime {
        if (@sizeOf(simd.Line) != 8) @compileError("Line must stay 8 bytes");
    }
}

test "block store: fold lines into flat SoA blocks with u32 links" {
    const md =
        \\# Title
        \\Para one.
        \\Para two.
        \\
        \\- item a
        \\- item b
        \\
        \\```zig
        \\const x = 1;
        \\const y = 2;
        \\```
        \\Trailing.
    ;
    var lines: [16]simd.Line = undefined;
    var in_fence: simd.FenceState = .{};
    const n_lines = simd.scanLines(md, &lines, &in_fence);

    var buf: [16]Block = undefined;
    const n = buildInto(lines[0..n_lines], &buf);

    // h1, para-run(2 lines), list-run(2), fence region(1), trailing = 5
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expectEqual(simd.BlockType.heading1, buf[0].tag);
    try std.testing.expectEqual(@as(u32, 2), buf[1].line_count);
    try std.testing.expectEqual(@as(u32, 2), buf[2].line_count);
    try std.testing.expectEqual(simd.BlockType.code_fence_start, buf[3].tag);
    try std.testing.expectEqual(@as(u32, 4), buf[3].line_count);

    // Flat root list: sibling chain wired, parent/child reserved as NULL_IDX.
    var k: usize = 0;
    while (k < n) : (k += 1) {
        try std.testing.expectEqual(NULL_IDX, buf[k].parent);
        try std.testing.expectEqual(NULL_IDX, buf[k].first_child);
        const want_next = if (k + 1 < n) @as(u32, @intCast(k + 1)) else NULL_IDX;
        try std.testing.expectEqual(want_next, buf[k].next_sibling);
    }

    // Zero-copy: block text slices alias the source buffer, no heap strings.
    try std.testing.expectEqualStrings("# Title", md[buf[0].start..][0..buf[0].len]);
    const fence_text = md[buf[3].start..][0..buf[3].len];
    try std.testing.expect(std.mem.indexOf(u8, fence_text, "const y = 2;") != null);
}

test "block store: fold output is ordered with chained siblings" {
    const md = "# A\nBody line here.\nBody line two.\n> Quote.\n";
    var lines: [8]simd.Line = undefined;
    var in_fence: simd.FenceState = .{};
    const n_lines = simd.scanLines(md, &lines, &in_fence);

    var buf: [8]Block = undefined;
    const n = buildInto(lines[0..n_lines], &buf);

    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("# A", md[buf[0].start..][0..buf[0].len]);
    // Blocks are ordered, non-overlapping, sibling-chained.
    var k: usize = 0;
    while (k < n) : (k += 1) {
        if (k > 0) try std.testing.expect(buf[k].start >= buf[k - 1].start + buf[k - 1].len);
        const want_next = if (k + 1 < n) @as(u32, @intCast(k + 1)) else NULL_IDX;
        try std.testing.expectEqual(want_next, buf[k].next_sibling);
    }
    try std.testing.expect(buf[n - 1].start + buf[n - 1].len <= md.len);
}

test "mmap: Goldilocks window math clamps to file bounds" {
    const mmap = @import("mmap.zig");
    const w = mmap.goldilocksWindow(1000, 2000, 100_000, 4096);
    try std.testing.expectEqual(@as(usize, 0), w.start); // 1000 - 4096 saturates
    try std.testing.expectEqual(@as(usize, 2000 + 4096), w.end);
    const tail = mmap.goldilocksWindow(99_000, 99_500, 100_000, 4096);
    try std.testing.expectEqual(@as(usize, 100_000), tail.end); // clamped
    const zero = mmap.goldilocksWindow(0, 0, 0, 4096);
    try std.testing.expectEqual(@as(usize, 0), zero.start);
    try std.testing.expectEqual(@as(usize, 0), zero.end);
}

test "mmap: MADV_DONTNEED release keeps mapping readable (volatile, not free)" {
    const mmap = @import("mmap.zig");
    const fname = "block_index_release_test.md";
    const row = "# Heading row for release test with padding text 0123456789\nBody text row for the memory pressure discipline check.\n";
    const rows = 4096; // ~440KB, well above the 64KB advise threshold

    const fd = try std.posix.openat(
        std.posix.AT.FDCWD,
        fname,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
        0o644,
    );
    var w: usize = 0;
    while (w < rows) : (w += 1) {
        _ = std.c.write(fd, row.ptr, row.len);
    }
    _ = std.c.close(fd);
    defer _ = std.c.unlink(fname);

    var mapped = try mmap.MappedFile.open(fname);
    defer mapped.close();
    try std.testing.expect(mapped.bytes.len > mmap.min_advise_bytes);

    // Touch every page so RSS is real, then hash.
    var sum_before: u64 = 0;
    for (mapped.bytes) |b| sum_before = sum_before *% 31 +% b;

    // Keep only the middle screen resident; release head and tail.
    const mid = mapped.bytes.len / 2;
    const hint = mapped.bytes.len / 8;
    const win = mmap.goldilocksWindow(mid - hint / 2, mid + hint / 2, mapped.bytes.len, hint);
    mapped.releaseOutside(win.start, win.end);

    // Mapping must still read back identical bytes (kernel faults them in).
    var sum_after: u64 = 0;
    for (mapped.bytes) |b| sum_after = sum_after *% 31 +% b;
    try std.testing.expectEqual(sum_before, sum_after);
    try std.testing.expect(std.mem.startsWith(u8, mapped.bytes, "# Heading"));

    // Small buffers are a no-op and never crash.
    var tiny: [16]u8 = .{0} ** 16;
    mmap.releaseOutsideWindow(&tiny, 0, 0);
}
