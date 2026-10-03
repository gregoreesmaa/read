// Print the .text section raw size of a PE file (for the size gate).
// Writes the number to stdout AND appends it to the file named by the
// second argv (the size_gate PE branch runs the tool with stdout
// connected in ways that lose bytes; the file is the reliable channel).
const std = @import("std");
pub fn main(init: std.process.Init.Minimal) !void {
    var args_it = try std.process.Args.Iterator.initAllocator(init.args, std.heap.page_allocator);
    defer args_it.deinit();
    _ = args_it.next();
    const path = args_it.next() orelse return error.Usage;
    const out_path = args_it.next();
    var tio = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer tio.deinit();
    const io = tio.io();
    var f = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only });
    defer f.close(io);
    var h: [64]u8 = undefined;
    _ = try f.readStreaming(io, &.{&h});
    if (h[0] != 'M' or h[1] != 'Z') return error.NotPE;
    const pe = std.mem.readInt(u32, h[60..64], .little);
    var ch: [24]u8 = undefined;
    _ = try f.readPositionalAll(io, &ch, pe);
    if (ch[0] != 'P' or ch[1] != 'E') return error.NotPE;
    const nsec = std.mem.readInt(u16, ch[6..8], .little);
    const optsz = std.mem.readInt(u16, ch[20..22], .little);
    const secbase = pe + 24 + optsz;
    var i: usize = 0;
    while (i < nsec) : (i += 1) {
        var s: [40]u8 = undefined;
        _ = try f.readPositionalAll(io, &s, secbase + i * 40);
        if (std.mem.eql(u8, s[0..5], ".text")) {
            const sz = std.mem.readInt(u32, s[16..20], .little);
            std.debug.print("{d}\n", .{sz});
            if (out_path) |op| {
                var of = try std.Io.Dir.cwd().createFile(io, op, .{});
                defer of.close(io);
                var nbuf: [32]u8 = undefined;
                const line = try std.fmt.bufPrint(&nbuf, "{d}\n", .{sz});
                try of.writeStreamingAll(io, line);
            }
            return;
        }
    }
    return error.NoText;
}
