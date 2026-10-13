const std = @import("std");
const cli = @import("cli.zig");
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    const count = if (args.len > 1) try std.fmt.parseInt(usize, args[1], 10) else 100000;
    const rounds = if (args.len > 2) try std.fmt.parseInt(usize, args[2], 10) else 20;
    const base = try a.alloc([]const u8, count);
    const values = try a.alloc([]const u8, count);
    for (base, 0..) |*item, i| {
        const n = (i *% 7919 +% 17) % 1000003;
        item.* = if (i % 4 == 0) try std.fmt.allocPrint(a, "sm{d:0>12}", .{n}) else try std.fmt.allocPrint(a, "sm{d}", .{n});
    }
    const start = std.Io.Timestamp.now(init.io, .awake).toNanoseconds();
    for (0..rounds) |_| {
        @memcpy(values, base);
        try cli.sortVideoIDs(init.gpa, values);
    }
    const elapsed = std.Io.Timestamp.now(init.io, .awake).toNanoseconds() - start;
    var hash: u64 = 14695981039346656037;
    for (values) |item| {
        for (item) |byte| hash = (hash ^ byte) *% 1099511628211;
        hash = (hash ^ 10) *% 1099511628211;
    }
    var buffer: [1024]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &buffer);
    try out.interface.print("{{\"count\":{d},\"rounds\":{d},\"checksum\":\"{x:0>16}\",\"elapsed_ns\":{d}}}\n", .{ count, rounds, hash, elapsed });
    try out.interface.flush();
}
