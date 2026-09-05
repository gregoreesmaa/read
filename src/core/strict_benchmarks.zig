const std = @import("std");
const mmap = @import("../core/mmap.zig");
const simd = @import("../core/simd.zig");
const parser = @import("../core/parser.zig");
const layout = @import("../layout/viewport.zig");

// ============================================================================
// STRICT ARCHITECTURAL & PERFORMANCE TARGET SPECIFICATION
// DO NOT RELAX OR CHANGE THESE TARGETS UNDER ANY CIRCUMSTANCE.
// ONLY OPTIMIZE IMPLEMENTATION TO SATISFY THEM.
// ============================================================================

pub const TARGET_MIN_SCAN_THROUGHPUT_MB_S: f64 = 2500.0;  // Minimum 2.5 GB/s scanning speed
pub const TARGET_MAX_50K_SCAN_TIME_US: i128 = 1000;      // Max 1.0 ms to scan 50,000 lines
pub const TARGET_MAX_MMAP_OPEN_TIME_US: i128 = 45;        // Max 45 µs to open & map file
pub const TARGET_MAX_VIEWPORT_LAYOUT_TIME_US: i128 = 50;  // Max 50 µs for virtualized viewport layout
pub const TARGET_MAX_SUBSTRING_SEARCH_TIME_US: i128 = 150;// Max 150 µs to search 50k lines
pub const TARGET_MAX_HOT_PATH_ALLOCATIONS: usize = 0;     // Zero allocations on hot render path

test "STRICT: SIMD Line Scanner Throughput and Latency" {
    const allocator = std.testing.allocator;
    const lines_target = 50_000;

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);

    const chunk =
        \\# Architecture of Pure Speed
        \\Computers are fast, software is slow.
        \\> Simplicity is prerequisite for reliability.
        \\- Point alpha with **bold** and *italic* text.
        \\- Point beta with `inline code` and a [link](https://ziglang.org).
        \\
    ;

    var i: usize = 0;
    while (i < 10_000) : (i += 1) {
        try buffer.appendSlice(allocator, chunk);
    }

    const mem = buffer.items;
    const line_entries = try allocator.alloc(simd.Line, lines_target + 100);
    defer allocator.free(line_entries);

    var in_fence: bool = false;

    var ts_start: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.MONOTONIC, &ts_start);

    const count = simd.scanLines(mem, line_entries, &in_fence);

    var ts_end: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.MONOTONIC, &ts_end);

    const start_ns = @as(i128, ts_start.sec) * 1_000_000_000 + ts_start.nsec;
    const end_ns = @as(i128, ts_end.sec) * 1_000_000_000 + ts_end.nsec;
    const elapsed_ns = end_ns - start_ns;
    const elapsed_us = @divTrunc(elapsed_ns, 1_000);

    const mb = @as(f64, @floatFromInt(mem.len)) / (1024.0 * 1024.0);
    const secs = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
    const throughput_mb_s = mb / secs;

    std.debug.print("\n[STRICT BENCHMARK] Scanned {d} lines ({d:.2} MB) in {d} µs ({d:.2} MB/s)\n", .{
        count,
        mb,
        elapsed_us,
        throughput_mb_s,
    });

    try std.testing.expect(count >= lines_target);
    // Non-negotiable throughput constraint
    try std.testing.expect(throughput_mb_s >= TARGET_MIN_SCAN_THROUGHPUT_MB_S);
    // Non-negotiable scan time constraint
    try std.testing.expect(elapsed_us <= TARGET_MAX_50K_SCAN_TIME_US);
}

test "STRICT: Zero-Copy mmap Open Latency" {
    const test_filename = "strict_mmap_test.md";
    const test_content = "# Test Document for Latency Verification\nContent row.\n";

    const fd = try std.posix.openat(
        std.posix.AT.FDCWD,
        test_filename,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
        0o644,
    );
    _ = std.c.write(fd, test_content.ptr, test_content.len);
    _ = std.c.close(fd);
    defer _ = std.c.unlink(test_filename);

    var ts_start: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.MONOTONIC, &ts_start);

    var mapped = try mmap.MappedFile.open(test_filename);
    defer mapped.close();

    var ts_end: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.MONOTONIC, &ts_end);

    const start_ns = @as(i128, ts_start.sec) * 1_000_000_000 + ts_start.nsec;
    const end_ns = @as(i128, ts_end.sec) * 1_000_000_000 + ts_end.nsec;
    const elapsed_us = @divTrunc(end_ns - start_ns, 1_000);

    std.debug.print("[STRICT BENCHMARK] mmap Open Latency: {d} µs\n", .{elapsed_us});

    try std.testing.expectEqualStrings(test_content, mapped.bytes);
    try std.testing.expect(elapsed_us <= TARGET_MAX_MMAP_OPEN_TIME_US);
}

test "STRICT: Viewport Layout Under 500 µs on 50,000 Lines" {
    const allocator = std.testing.allocator;
    const lines_target = 50_000;

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);

    const chunk =
        \\# Fast Layout Target
        \\This is regular paragraph text with **bold** and *italic* words.
        \\> Dijkstra: Simplicity is prerequisite for reliability.
        \\- Bullet point alpha
        \\- Bullet point beta
        \\
    ;

    var i: usize = 0;
    while (i < 10_000) : (i += 1) {
        try buffer.appendSlice(allocator, chunk);
    }

    const mem = buffer.items;
    const line_entries = try allocator.alloc(simd.Line, lines_target + 100);
    defer allocator.free(line_entries);

    var in_fence: bool = false;
    const line_count = simd.scanLines(mem, line_entries, &in_fence);

    var commands: [1024]layout.DrawCommand = undefined;
    const vp_config = layout.ViewportConfig{
        .window_width = 1200.0,
        .window_height = 800.0,
        .scroll_y = 1200.0,
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
    const elapsed_us = @divTrunc(end_ns - start_ns, 1_000);

    std.debug.print("[STRICT BENCHMARK] Viewport Layout Latency: {d} µs ({d} draw commands)\n", .{
        elapsed_us,
        cmd_count,
    });

    try std.testing.expect(cmd_count > 0);
    try std.testing.expect(elapsed_us <= TARGET_MAX_VIEWPORT_LAYOUT_TIME_US);
}

test "STRICT: SIMD Substring Search Under 500 µs on 50,000 Lines" {
    const allocator = std.testing.allocator;
    const lines_target = 50_000;

    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);

    const chunk = "A sentence of text in a markdown document line.\n";
    var i: usize = 0;
    while (i < lines_target) : (i += 1) {
        try buffer.appendSlice(allocator, chunk);
    }
    // Inject target search needle near end
    try buffer.appendSlice(allocator, "Special needle token here.\n");

    const mem = buffer.items;
    const needle = "Special needle";

    var ts_start: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.MONOTONIC, &ts_start);

    const match_pos = simd.simdSearch(mem, needle);

    var ts_end: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.MONOTONIC, &ts_end);

    const start_ns = @as(i128, ts_start.sec) * 1_000_000_000 + ts_start.nsec;
    const end_ns = @as(i128, ts_end.sec) * 1_000_000_000 + ts_end.nsec;
    const elapsed_us = @divTrunc(end_ns - start_ns, 1_000);

    std.debug.print("[STRICT BENCHMARK] Substring Search Latency: {d} µs\n", .{elapsed_us});

    try std.testing.expect(match_pos != null);
    try std.testing.expect(elapsed_us <= TARGET_MAX_SUBSTRING_SEARCH_TIME_US);
}
