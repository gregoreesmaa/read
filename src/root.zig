const std = @import("std");

pub const mmap = @import("core/mmap.zig");
pub const simd = @import("core/simd.zig");
pub const parser = @import("core/parser.zig");
pub const layout = @import("layout/viewport.zig");
pub const block_index = @import("core/block_index.zig");
pub const highlight = @import("core/highlight.zig");
pub const idle = @import("platform/idle.zig");
pub const damage = @import("layout/damage.zig");
pub const glyph_cache = @import("platform/glyph_cache.zig");
pub const strict_benchmarks = @import("core/strict_benchmarks.zig");
pub const controls_test = @import("tests/controls_test.zig");
pub const spec_compliance_test = @import("tests/spec_compliance_test.zig");
pub const commonmark_harness = @import("tests/commonmark_harness.zig");

test {
    _ = strict_benchmarks;
    _ = controls_test;
    _ = spec_compliance_test;
    _ = commonmark_harness;
    _ = block_index;
    _ = highlight;
    _ = idle;
    _ = damage;
    _ = glyph_cache;
}

test "simd line scanner and block classification" {
    const md_sample =
        \\# Heading 1
        \\This is a paragraph with **bold** and *italic* text.
        \\
        \\## Heading 2
        \\> This is a quote
        \\- Bullet item 1
        \\- Bullet item 2
        \\1. Ordered item
        \\
        \\```zig
        \\const x: i32 = 42;
        \\```
        \\---
        \\| Col 1 | Col 2 |
    ;

    var lines: [32]simd.Line = undefined;
    var in_fence: simd.FenceState = .{};
    const count = simd.scanLines(md_sample, &lines, &in_fence);

    try std.testing.expectEqual(@as(usize, 14), count);
    try std.testing.expectEqual(simd.BlockType.heading1, lines[0].block_type);
    try std.testing.expectEqual(simd.BlockType.paragraph, lines[1].block_type);
    try std.testing.expectEqual(simd.BlockType.blank, lines[2].block_type);
    try std.testing.expectEqual(simd.BlockType.heading2, lines[3].block_type);
    try std.testing.expectEqual(simd.BlockType.quote, lines[4].block_type);
    try std.testing.expectEqual(simd.BlockType.bullet_list, lines[5].block_type);
    try std.testing.expectEqual(simd.BlockType.bullet_list, lines[6].block_type);
    try std.testing.expectEqual(simd.BlockType.ordered_list, lines[7].block_type);
    try std.testing.expectEqual(simd.BlockType.blank, lines[8].block_type);
    try std.testing.expectEqual(simd.BlockType.code_fence_start, lines[9].block_type); // ```zig
    try std.testing.expectEqual(simd.BlockType.code_line, lines[10].block_type); // const x: i32 = 42;
    try std.testing.expectEqual(simd.BlockType.code_fence_end, lines[11].block_type); // ```
    try std.testing.expectEqual(simd.BlockType.hr, lines[12].block_type); // ---
    try std.testing.expectEqual(simd.BlockType.table_row, lines[13].block_type); // | Col 1 | Col 2 |
}

test "inline parser tokenization" {
    const line = "Here is **bold**, *italic*, `code`, and a [link](https://ziglang.org)!";
    var spans: [16]parser.InlineSpan = undefined;
    const span_count = parser.parseInlines(line, &spans);

    try std.testing.expect(span_count >= 5);

    // Verify code block
    var found_code = false;
    var found_link = false;
    for (spans[0..span_count]) |s| {
        if (s.style.code and std.mem.eql(u8, s.text, "code")) {
            found_code = true;
        }
        if (s.style.link and std.mem.eql(u8, s.text, "link")) {
            if (s.link_target) |target| {
                if (std.mem.eql(u8, target, "https://ziglang.org")) {
                    found_link = true;
                }
            }
        }
    }
    try std.testing.expect(found_code);
    try std.testing.expect(found_link);
}

test "microsecond benchmark on 50,000 lines" {
    const allocator = std.testing.allocator;
    const lines_target = 50_000;

    // Build synthetic markdown buffer
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);

    const chunk =
        \\# Architecture of Pure Speed
        \\Computers are fast, software is slow.
        \\> Simplicity is prerequisite for reliability.
        \\- Point alpha
        \\- Point beta
        \\
    ;

    var i: usize = 0;
    while (i < 10_000) : (i += 1) {
        try buffer.appendSlice(allocator, chunk);
    }

    const mem = buffer.items;
    const line_entries = try allocator.alloc(simd.Line, lines_target + 100);
    defer allocator.free(line_entries);

    var in_fence: simd.FenceState = .{};

    var ts_start: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.MONOTONIC, &ts_start);
    const count = simd.scanLines(mem, line_entries, &in_fence);
    var ts_end: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.MONOTONIC, &ts_end);

    const start_ns = @as(i128, ts_start.sec) * 1_000_000_000 + ts_start.nsec;
    const end_ns = @as(i128, ts_end.sec) * 1_000_000_000 + ts_end.nsec;
    const elapsed_ns = end_ns - start_ns;
    const elapsed_us = @divTrunc(elapsed_ns, 1_000);
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;

    std.debug.print("\n=== SCANNER BENCHMARK ===\n", .{});
    std.debug.print("Scanned {d} lines ({d} KB) in {d} µs ({d:.2} ms)\n", .{
        count,
        mem.len / 1024,
        elapsed_us,
        elapsed_ms,
    });
    const bytes_per_sec = (@as(f64, @floatFromInt(mem.len)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1e9)) / (1024.0 * 1024.0 * 1024.0);
    std.debug.print("Throughput: {d:.2} GB/s\n", .{bytes_per_sec});
    std.debug.print("=========================\n", .{});

    try std.testing.expect(count >= lines_target);
}

test "mmap mapped file read and parse" {
    const test_filename = "test_sample_mmap.md";
    const test_content =
        \\# Read Engine Test
        \\This file was mapped directly into virtual memory.
        \\## Performance
        \\Zero allocations on the hot path.
    ;

    // Write a temporary file using direct posix syscalls
    const fd = try std.posix.openat(
        std.posix.AT.FDCWD,
        test_filename,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
        0o644,
    );
    _ = std.c.write(fd, test_content.ptr, test_content.len);
    _ = std.c.close(fd);
    defer _ = std.c.unlink(test_filename);

    // Map the file
    var mapped = try mmap.MappedFile.open(test_filename);
    defer mapped.close();

    try std.testing.expectEqualStrings(test_content, mapped.bytes);

    var lines: [8]simd.Line = undefined;
    var in_fence: simd.FenceState = .{};
    const count = simd.scanLines(mapped.bytes, &lines, &in_fence);

    try std.testing.expectEqual(@as(usize, 4), count);
    try std.testing.expectEqual(simd.BlockType.heading1, lines[0].block_type);
    try std.testing.expectEqual(simd.BlockType.paragraph, lines[1].block_type);
    try std.testing.expectEqual(simd.BlockType.heading2, lines[2].block_type);
    try std.testing.expectEqual(simd.BlockType.paragraph, lines[3].block_type);
}

test "virtualized layout performance on 50,000 lines" {
    const allocator = std.testing.allocator;
    const lines_target = 50_000;

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);

    const chunk =
        \\# Architecture of Pure Speed
        \\Computers are fast, software is slow.
        \\> Simplicity is prerequisite for reliability.
        \\- Point alpha with **bold** and *italic* details.
        \\- Point beta with a [link](https://ziglang.org) target.
        \\
    ;

    var i: usize = 0;
    while (i < 10_000) : (i += 1) {
        try buffer.appendSlice(allocator, chunk);
    }

    const mem = buffer.items;
    const line_entries = try allocator.alloc(simd.Line, lines_target + 100);
    defer allocator.free(line_entries);

    var in_fence: simd.FenceState = .{};
    const line_count = simd.scanLines(mem, line_entries, &in_fence);

    var commands: [512]layout.DrawCommand = undefined;
    const vp_config = layout.ViewportConfig{
        .window_width = 1200.0,
        .window_height = 800.0,
        .scroll_y = 500.0, // Scrolled into the document
    };

    var ts_start: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.MONOTONIC, &ts_start);

    const cmd_count = layout.layoutViewport(
        mem,
        line_entries[0..line_count],
        vp_config,
        &commands,
    );

    var ts_end: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.MONOTONIC, &ts_end);

    const start_ns = @as(i128, ts_start.sec) * 1_000_000_000 + ts_start.nsec;
    const end_ns = @as(i128, ts_end.sec) * 1_000_000_000 + ts_end.nsec;
    const elapsed_ns = end_ns - start_ns;
    const elapsed_us = @divTrunc(elapsed_ns, 1_000);

    std.debug.print("\n=== VIEWPORT LAYOUT BENCHMARK ===\n", .{});
    std.debug.print("Generated {d} visible draw commands from {d} lines in {d} µs ({d} ns)\n", .{
        cmd_count,
        line_count,
        elapsed_us,
        elapsed_ns,
    });
    std.debug.print("=================================\n", .{});

    try std.testing.expect(cmd_count > 0);
}


