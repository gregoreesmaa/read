const std = @import("std");

/// Cross-platform file helpers for test blocks (and only test blocks:
/// production paths keep their direct syscalls for the size/precision
/// reasons documented at each site). Zig 0.16 Windows has no
/// std.posix.openat and std.posix.AT has no FDCWD, so tests that stage
/// scratch files must go through std.Io, which works on every OS.
pub fn writeFile(io: std.Io, dir: std.Io.Dir, sub_path: []const u8, data: []const u8) !void {
    var f = try dir.createFile(io, sub_path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, data);
}

pub fn deleteFile(io: std.Io, dir: std.Io.Dir, sub_path: []const u8) void {
    dir.deleteFile(io, sub_path) catch {};
}

/// Threaded Io context for tests that need one. Heap-allocating (test
/// only, never on a hot path).
pub const TestIo = struct {
    threaded: std.Io.Threaded,

    pub fn init() TestIo {
        return .{ .threaded = std.Io.Threaded.init(std.testing.allocator, .{}) };
    }

    pub fn deinit(self: *TestIo) void {
        self.threaded.deinit();
    }

    pub fn io(self: *TestIo) std.Io {
        return self.threaded.io();
    }
};

test "port_fs: write/read/delete roundtrip" {
    var tio = TestIo.init();
    defer tio.deinit();
    const io = tio.io();
    const cwd = std.Io.Dir.cwd();
    const path = "port_fs_roundtrip_test.md";
    defer deleteFile(io, cwd, path);
    try writeFile(io, cwd, path, "# hello\n");
    {
        var f = try cwd.openFile(io, path, .{ .mode = .read_only });
        defer f.close(io);
        try std.testing.expectEqual(@as(u64, 8), try f.length(io));
    }
}
