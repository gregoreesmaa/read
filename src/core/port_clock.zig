const std = @import("std");
const builtin = @import("builtin");

/// Cross-platform monotonic clock + sleep for benchmarks and backoff naps.
/// POSIX uses clock_gettime(CLOCK_MONOTONIC)/nanosleep directly; Windows
/// uses QueryPerformanceCounter/Sleep (std.c.nanosleep's second parameter
/// is void there, and std.posix.system.clock_gettime does not exist).
/// Same units everywhere (nanoseconds); zero heap allocations.
pub fn nowNs() u64 {
    if (builtin.os.tag == .windows) {
        var freq: i64 = 0;
        _ = QueryPerformanceFrequency(&freq);
        var ctr: i64 = 0;
        _ = QueryPerformanceCounter(&ctr);
        if (freq <= 0) return 0;
        return @intCast(@divTrunc(@as(i128, ctr) * 1_000_000_000, @as(i128, freq)));
    } else {
        var ts: std.posix.timespec = undefined;
        _ = std.posix.system.clock_gettime(.MONOTONIC, &ts);
        return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
    }
}

pub fn nowNsI128() i128 {
    return @intCast(nowNs());
}

/// Backoff nap (test-only measurement hygiene; never on a hot path).
/// Delegates to simd.timingGateBackoff's primitive: simd.zig (the `hot`
/// module) owns the only Sleep/nanosleep spelling so no file lives in two
/// modules (Zig 0.16 module-ownership rule).
pub fn sleepNs(ns: u64) void {
    _ = ns;
    @import("hot").timingGateBackoff();
}

pub fn nowMs() i64 {
    return @intCast(nowNs() / 1_000_000);
}

test "port_clock: nowNs advances, sleepNs waits" {
    const t0 = nowNs();
    sleepNs(2_000_000);
    const t1 = nowNs();
    try std.testing.expect(t1 >= t0);
    // 2 ms sleep must advance the clock by at least 1 ms (scheduler slop
    // absorbs the rest; the bound is one-sided on purpose).
    try std.testing.expect(t1 - t0 >= 1_000_000);
    try std.testing.expect(nowMs() * 1_000_000 <= nowNs());
}

const is_windows = builtin.os.tag == .windows;

extern "kernel32" fn QueryPerformanceFrequency(lpFrequency: *i64) callconv(.winapi) c_int;
extern "kernel32" fn QueryPerformanceCounter(lpPerformanceCount: *i64) callconv(.winapi) c_int;
extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;
