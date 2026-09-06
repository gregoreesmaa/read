// Parser + line-scanner crash harness (issue #34).
//
// Built via `zig build fuzz` (see build.zig): a separate binary sharing
// only the platform-independent `read` core module with the ship binary,
// never installed by default, never shipped. Exercises simd.scanLines
// over the whole input, simd.scanRefDefs, and per-line
// parser.parseInlinesStream with fixed-size buffers. Fixed buffers mean a
// hostile input can truncate output but never OOM; every loop in the core
// advances an index, so completion here proves no crash/hang/OOM.
//
// Usage: zig build fuzz -Doptimize=ReleaseFast && ./zig-out/bin/fuzz-parser <file>
// Exit: 0 ok (prints one summary line), 1 usage, 2 unreadable, 3 over cap.
const std = @import("std");
const read = @import("read");
const simd = read.simd;
const parser = read.parser;
const mmap = read.mmap;

const MAX_BYTES: usize = 16 << 20;
const MAX_LINES: usize = 220_000;
const TOKENS_PER_LINE: usize = 256;

fn nowNs() u64 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args_it = std.process.Args.Iterator.init(init.args);
    _ = args_it.next(); // skip exe name
    const path = args_it.next() orelse {
        std.debug.print("usage: fuzz-parser <file>\n", .{});
        std.process.exit(1);
    };

    // The reader's own zero-copy open: this also fuzzes the mmap cold path.
    var mf = mmap.MappedFile.open(path) catch {
        std.debug.print("unreadable: {s}\n", .{path});
        std.process.exit(2);
    };
    defer mf.close();
    const bytes = mf.bytes;
    if (bytes.len > MAX_BYTES) {
        std.debug.print("skip: {s} is {d} bytes (cap {d})\n", .{ path, bytes.len, MAX_BYTES });
        std.process.exit(3);
    }

    var lines_buf: [MAX_LINES]simd.Line = undefined;
    var fence = simd.FenceState{};

    const t0 = nowNs();
    const n_lines = simd.scanLines(bytes, &lines_buf, &fence);
    const t1 = nowNs();

    // Reference definitions over the (possibly truncated) line index.
    var refdefs: [simd.MAX_REF_DEFS]simd.RefDef = undefined;
    const n_refs = simd.scanRefDefs(bytes, lines_buf[0..n_lines], &refdefs);

    // Inline stream parse of every indexed line with a bounded token
    // buffer; token slices are resolved (bounds-clamped) and folded into
    // a checksum so the optimizer cannot delete the work.
    var tokens_buf: [TOKENS_PER_LINE]parser.Token = undefined;
    var total_tokens: usize = 0;
    var checksum: u64 = 0;
    for (lines_buf[0..n_lines]) |ln| {
        const base: usize = ln.offset;
        const end: usize = @min(base + @as(usize, ln.len), bytes.len);
        const n = parser.parseInlinesStream(ln.offset, bytes[base..end], &tokens_buf);
        total_tokens += n;
        for (tokens_buf[0..n]) |tok| {
            checksum +%= @as(u64, @intCast(@intFromEnum(tok.kind)));
            checksum +%= @as(u64, tok.start) *% 31 +% tok.len;
            const slice = parser.tokenSlice(bytes, tok);
            checksum +%= slice.len;
        }
    }
    const t2 = nowNs();

    const scan_us = (t1 - t0) / 1000;
    const total_us = (t2 - t0) / 1000;
    std.debug.print("ok: {s} bytes={d} lines={d} refs={d} tokens={d} sum={x} scan_us={d} total_us={d}\n", .{
        path, bytes.len, n_lines, n_refs, total_tokens, checksum, scan_us, total_us,
    });
}
