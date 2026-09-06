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

            // File size without a trailing dependency on libc::fstat, which
            // Zig 0.16 leaves void on Linux. The Linux arm uses the same
            // statx(AT_EMPTY_PATH) query as std.Io.Threaded.fileLength.
            const size: usize = if (builtin.os.tag == .linux) blk: {
                const linux = std.os.linux;
                var sx = std.mem.zeroes(linux.Statx);
                const err = linux.errno(linux.statx(
                    fd,
                    "",
                    linux.AT.EMPTY_PATH,
                    .{ .SIZE = true },
                    &sx,
                ));
                if (err != .SUCCESS or !sx.mask.SIZE) return error.StatFailed;
                break :blk @intCast(sx.size);
            } else blk: {
                var stat: std.c.Stat = undefined;
                if (std.c.fstat(fd, &stat) != 0) return error.StatFailed;
                break :blk @intCast(stat.size);
            };

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

    /// Volatile release: drop clean pages outside the resident window.
    /// Best-effort MADV_DONTNEED hint; the mapping stays open and zero-copy,
    /// faulted pages are re-read from the file on next access. Zero heap
    /// allocations. Never call on the open/layout hot path; invoke only when
    /// the Goldilocks window moves (e.g. after a scroll settles).
    pub fn releaseOutside(self: *const MappedFile, keep_start: usize, keep_end: usize) void {
        releaseOutsideWindow(self.bytes, keep_start, keep_end);
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

/// Goldilocks window: keep the viewport plus exactly one screen-height above
/// and below resident; pages far outside get MADV_DONTNEED (see ideas.txt:3).
pub const goldilocks_screens_above: usize = 1;
pub const goldilocks_screens_below: usize = 1;

/// Files smaller than this never trigger madvise; the hint costs more than
/// it saves and risks EINVAL noise on tiny mappings.
pub const min_advise_bytes: usize = 64 * 1024;

/// Pure arithmetic: expand a visible byte range by one screen of bytes in
/// each direction, clamped to [0, total_len). No syscalls, no allocations.
pub fn goldilocksWindow(
    visible_start: usize,
    visible_end: usize,
    total_len: usize,
    window_hint_bytes: usize,
) struct { start: usize, end: usize } {
    const above = window_hint_bytes * goldilocks_screens_above;
    const below = window_hint_bytes * goldilocks_screens_below;
    return .{
        .start = if (visible_start > above) visible_start - above else 0,
        .end = @min(if (visible_end > total_len - below) total_len else visible_end + below, total_len),
    };
}

fn runtimePageSize() usize {
    if (builtin.os.tag == .windows) return 4096;
    const sc = std.c.sysconf(@intFromEnum(std.c._SC.PAGESIZE));
    if (sc > 0) return @intCast(sc);
    return std.heap.page_size_min;
}

fn dontNeedRange(addr: usize, len: usize) void {
    if (len == 0) return;
    if (builtin.os.tag == .windows) return;
    const ptr: [*]u8 = @ptrFromInt(addr);
    const aligned: [*]align(std.heap.page_size_min) u8 = @alignCast(ptr);
    _ = std.c.madvise(
        @ptrCast(aligned),
        len,
        std.c.MADV.DONTNEED,
    );
}

/// Release pages of `bytes` outside [keep_start, keep_end).
/// Ranges are page-aligned outward (keep window never shrinks); unaligned
/// slivers are kept resident. Best-effort: failures are silently ignored
/// since dropped pages fault back from the file. Zero allocations.
/// Platform note: on Linux this actively discards clean pages; on Darwin the
/// hint succeeds but clean file-backed pages are already implicitly
/// reclaimable, so mincore residency only drops under memory pressure.
/// Either way the mapping stays correct and zero-copy.
pub fn releaseOutsideWindow(bytes: []const u8, keep_start: usize, keep_end: usize) void {
    if (bytes.len < min_advise_bytes) return;
    if (builtin.os.tag == .windows) return;

    const ks = @min(keep_start, bytes.len);
    const ke = @min(@max(keep_end, ks), bytes.len);
    const base = @intFromPtr(bytes.ptr);
    const page = runtimePageSize();

    // Head: [0, alignDown(keep_start)) -- whole pages strictly before the window.
    const head_end = std.mem.alignBackward(usize, base + ks, page);
    if (head_end > base) {
        dontNeedRange(base, head_end - base);
    }

    // Tail: [alignUp(keep_end), len) -- whole pages strictly after the window.
    const tail_start = std.mem.alignForward(usize, base + ke, page);
    const end = base + bytes.len;
    if (tail_start < end) {
        dontNeedRange(tail_start, end - tail_start);
    }
}
