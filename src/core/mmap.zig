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

    /// Cold-start prefetch (issue #11): the open → scan → metrics →
    /// first-frame path walks the mapping front to back exactly once, with no
    /// `read()`/copy anywhere. `MADV_SEQUENTIAL` on the whole mapping tells
    /// the pager to readahead aggressively and reclaim behind the scan;
    /// `MADV_WILLNEED` on the leading window faults the first pages in up
    /// front so the scan never stalls on a cold fault. The WILLNEED window is
    /// capped so a giant file never pages itself fully resident: RSS grows
    /// only with touched pages. Best-effort (failures silently ignored),
    /// zero heap allocations, called once per open — never on the
    /// scroll/layout hot path.
    pub fn adviseSequential(self: *const MappedFile) void {
        adviseSequentialRange(self.bytes);
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

/// Leading window for the WILLNEED half of cold-start prefetch: the first
/// viewport + scan head start resident immediately, while the SEQUENTIAL
/// hint streams the rest. Capped so opening a huge file never faults it
/// fully resident up front.
pub const willneed_window_bytes: usize = 256 * 1024;

/// Pure arithmetic: WILLNEED length for a mapping of `total_len` bytes.
/// Zero for empty mappings (madvise on a zero-length range is EINVAL
/// noise); otherwise the leading window capped at the mapping size.
pub fn willneedLen(total_len: usize) usize {
    if (total_len == 0) return 0;
    return @min(total_len, willneed_window_bytes);
}

/// Advise a mapped byte range for a single front-to-back cold pass.
/// Ranges are page-aligned inward (sub-page slivers are already resident —
/// a single fault at most — so there is nothing to prefetch there).
/// Best-effort: failures silently ignored; empty ranges and Windows return
/// without a syscall. Zero allocations.
pub fn adviseSequentialRange(bytes: []const u8) void {
    if (bytes.len == 0) return;
    if (builtin.os.tag == .windows) return;
    const page = runtimePageSize();
    const base = @intFromPtr(bytes.ptr);
    const aligned_start = std.mem.alignForward(usize, base, page);
    const aligned_end = std.mem.alignBackward(usize, base + bytes.len, page);
    if (aligned_start >= aligned_end) return;
    const ptr: [*]u8 = @ptrFromInt(aligned_start);
    _ = std.c.madvise(
        @ptrCast(@alignCast(ptr)),
        aligned_end - aligned_start,
        std.c.MADV.SEQUENTIAL,
    );
    const want_end = @min(base + willneedLen(bytes.len), aligned_end);
    if (want_end > aligned_start) {
        _ = std.c.madvise(
            @ptrCast(@alignCast(ptr)),
            want_end - aligned_start,
            std.c.MADV.WILLNEED,
        );
    }
}

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

test "mmap: willneed window is capped, zero for empty" {
    try std.testing.expectEqual(@as(usize, 0), willneedLen(0));
    try std.testing.expectEqual(@as(usize, 1), willneedLen(1));
    try std.testing.expectEqual(@as(usize, 4096), willneedLen(4096));
    try std.testing.expectEqual(willneed_window_bytes, willneedLen(willneed_window_bytes));
    try std.testing.expectEqual(willneed_window_bytes, willneedLen(willneed_window_bytes + 1));
    try std.testing.expectEqual(willneed_window_bytes, willneedLen(1 << 40));
}

test "mmap: cold-start advise leaves bytes intact, safe on empty" {
    // Empty range: must return without a syscall (zero-length madvise is
    // EINVAL noise), never crash.
    adviseSequentialRange(&[_]u8{});
    var empty_file = MappedFile{ .bytes = &[_]u8{}, .fd = undefined };
    empty_file.adviseSequential();

    // Real mapping: hints must not alter a single byte; the scan path reads
    // the same zero-copy bytes before and after.
    const path = "mmap_advise_test.md";
    const content = "# Cold Start\nscan me twice\n";
    const fd = try std.posix.openat(
        std.posix.AT.FDCWD,
        path,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
        0o644,
    );
    _ = std.c.write(fd, content.ptr, content.len);
    _ = std.c.close(fd);
    defer _ = std.c.unlink(path);

    var mapped = try MappedFile.open(path);
    defer mapped.close();
    mapped.adviseSequential();
    try std.testing.expectEqualStrings(content, mapped.bytes);

    // Large mapping (past the WILLNEED cap): exercises the real page-aligned
    // syscall path; content must still be bit-identical afterwards.
    const big_path = "mmap_advise_big_test.md";
    const big_fd = try std.posix.openat(
        std.posix.AT.FDCWD,
        big_path,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
        0o644,
    );
    var written: usize = 0;
    while (written < willneed_window_bytes + 64 * 1024) {
        _ = std.c.write(big_fd, content.ptr, content.len);
        written += content.len;
    }
    _ = std.c.close(big_fd);
    defer _ = std.c.unlink(big_path);

    var big = try MappedFile.open(big_path);
    defer big.close();
    try std.testing.expect(big.bytes.len > willneed_window_bytes);
    big.adviseSequential();
    try std.testing.expectEqual(written, big.bytes.len);
    try std.testing.expect(std.mem.startsWith(u8, big.bytes, content));
    try std.testing.expect(std.mem.endsWith(u8, big.bytes, content));
}

test "mmap: startup path advises sequential (issue #11 wiring audit)" {
    // The cold-open gate depends on main.zig calling adviseSequential right
    // after MappedFile.open on the startup path — pin the wiring, not just
    // the helper. Same audit convention as idle.zig's run-loop test.
    var main_src = try MappedFile.open("src/main.zig");
    defer main_src.close();
    try std.testing.expect(std.mem.indexOf(u8, main_src.bytes, "adviseSequential") != null);
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
