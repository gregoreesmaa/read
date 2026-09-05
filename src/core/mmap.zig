const std = @import("std");
const builtin = @import("builtin");

/// Zero-copy memory mapped file handle with zero wrapper overhead
pub const MappedFile = struct {
    bytes: []const u8,
    fd: if (builtin.os.tag == .windows) std.os.windows.HANDLE else std.posix.fd_t,

    pub fn open(path: []const u8) !MappedFile {
        if (builtin.os.tag == .windows) {
            const windows = std.os.windows;
            // Convert to UTF-16 on Windows
            var path_w: [std.fs.max_path_bytes:0]u16 = undefined;
            const len = try std.unicode.utf8ToUtf16Le(&path_w, path);
            path_w[len] = 0;

            const h_file = try windows.OpenFile(&path_w, .{
                .dir = null,
                .access_mask = windows.GENERIC_READ,
                .share_access = windows.FILE_SHARE_READ,
                .creation_disposition = windows.OPEN_EXISTING,
                .filter = .{},
                .follow_symlinks = true,
            });
            errdefer windows.CloseHandle(h_file);

            const size = try windows.GetFileSizeEx(h_file);
            if (size == 0) {
                return MappedFile{
                    .bytes = &[_]u8{},
                    .fd = h_file,
                };
            }

            const h_map = try windows.CreateFileMapping(
                h_file,
                null,
                windows.PAGE_READONLY,
                0,
                0,
                null,
            );
            defer windows.CloseHandle(h_map);

            const ptr = try windows.MapViewOfFile(
                h_map,
                windows.FILE_MAP_READ,
                0,
                0,
                @intCast(size),
            );

            return MappedFile{
                .bytes = @as([*]const u8, @ptrCast(ptr))[0..@intCast(size)],
                .fd = h_file,
            };
        } else {
            // Direct POSIX syscalls
            const fd = try std.posix.openat(
                std.posix.AT.FDCWD,
                path,
                .{ .ACCMODE = .RDONLY },
                0,
            );
            errdefer _ = std.c.close(fd);

            var stat: std.c.Stat = undefined;
            if (std.c.fstat(fd, &stat) != 0) return error.StatFailed;
            const size: usize = @intCast(stat.size);

            if (size == 0) {
                return MappedFile{
                    .bytes = &[_]u8{},
                    .fd = fd,
                };
            }

            const ptr = try std.posix.mmap(
                null,
                size,
                .{ .READ = true },
                .{ .TYPE = .SHARED },
                fd,
                0,
            );

            return MappedFile{
                .bytes = ptr,
                .fd = fd,
            };
        }
    }

    pub fn close(self: *MappedFile) void {
        if (self.bytes.len > 0) {
            if (builtin.os.tag == .windows) {
                _ = std.os.windows.UnmapViewOfFile(self.bytes.ptr);
            } else {
                std.posix.munmap(@alignCast(self.bytes));
            }
        }
        if (builtin.os.tag == .windows) {
            std.os.windows.CloseHandle(self.fd);
        } else {
            _ = std.c.close(self.fd);
        }
        self.* = undefined;
    }
};
