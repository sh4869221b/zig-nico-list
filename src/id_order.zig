//! Decorate once, compare borrowed normalized suffixes, then undecorate.
//! Numeric-looking IDs retain the original Go ordering (including overflow and
//! malformed suffixes). There is no integer parsing or allocation in comparison.
const std = @import("std");
const Allocator = std.mem.Allocator;

fn normalized(id: []const u8) []const u8 {
    var text = if (id.len >= 2) id[2..] else id;
    for (text) |c| if (!std.ascii.isDigit(c)) return text;
    const original = text;
    while (text.len > 1 and text[0] == '0') text = text[1..];
    const max = "18446744073709551615";
    if (text.len > max.len or (text.len == max.len and std.mem.lessThan(u8, max, text))) return original;
    return text;
}
const Key = struct {
    id: []const u8,
    start: usize,
    fn init(id: []const u8) Key {
        return .{ .id = id, .start = id.len - normalized(id).len };
    }
    fn less(_: void, left: Key, right: Key) bool {
        const l = left.id[left.start..];
        const r = right.id[right.start..];
        if (l.len != r.len) return l.len < r.len;
        const order = std.mem.order(u8, l, r);
        return if (order == .eq) std.mem.lessThan(u8, left.id, right.id) else order == .lt;
    }
};
pub fn less(_: void, left: []const u8, right: []const u8) bool {
    return Key.less({}, Key.init(left), Key.init(right));
}
pub fn sort(allocator: Allocator, ids: [][]const u8) !void {
    if (ids.len < 2) return;
    const keys = try allocator.alloc(Key, ids.len);
    defer allocator.free(keys);
    for (ids, keys) |id, *key| key.* = .init(id);
    std.mem.sort(Key, keys, {}, Key.less);
    for (keys, ids) |key, *id| id.* = key.id;
}

test "cached keys preserve full comparator ordering" {
    const sample = [_][]const u8{ "sm001", "sm1", "so01", "sm0", "sm000", "x", "", "sm", "sm18446744073709551615", "sm018446744073709551615", "sm18446744073709551616", "sm00018446744073709551616", "sm12x", "sm001x", "sm-1", "SM1", "sm9", "sm10", "sm1" };
    var expected = sample;
    var actual = sample;
    std.mem.sort([]const u8, &expected, {}, less);
    try sort(std.testing.allocator, &actual);
    for (expected, actual) |e, a| try std.testing.expectEqualStrings(e, a);
}
fn allocationFailure(allocator: Allocator) !void {
    var items = [_][]const u8{ "sm2", "sm001", "sm1" };
    try sort(allocator, &items);
    try std.testing.expectEqualStrings("sm001", items[0]);
}
test "sort allocation failure leaves input unchanged and releases scratch" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailure, .{});
}
