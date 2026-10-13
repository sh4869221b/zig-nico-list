//! API wire schema and response filtering. Keep the complete NicoData schema
//! even when only a subset of its fields is used by the collector.
const std = @import("std");
const cli = @import("cli.zig");
const Allocator = std.mem.Allocator;

pub const Page = struct {
    ids: []const []const u8,
    item_count: usize,
    status: i64,
    total_count: ?i64,

    pub fn deinit(self: Page, allocator: Allocator) void {
        for (self.ids) |id| allocator.free(id);
        allocator.free(self.ids);
    }
};

/// Go's zero time is 0001-01-01T00:00:00Z, not the Unix epoch.
const Timestamp = struct { unix: i64 = -62135596800 };
const Meta = struct { status: i64 = 0 };
const Series = struct { id: i64 = 0, title: []const u8 = "", order: i64 = 0 };
const Count = struct { view: i64 = 0, comment: i64 = 0, mylist: i64 = 0, like: i64 = 0 };
const Thumbnail = struct {
    url: []const u8 = "",
    middleUrl: []const u8 = "",
    largeUrl: []const u8 = "",
    listingUrl: []const u8 = "",
    nHdUrl: []const u8 = "",
};
const Owner = struct { ownerType: []const u8 = "", id: []const u8 = "", name: []const u8 = "", iconUrl: []const u8 = "" };
const Essential = struct {
    type: []const u8 = "",
    id: []const u8 = "",
    title: []const u8 = "",
    registeredAt: Timestamp = .{},
    count: Count = .{},
    thumbnail: Thumbnail = .{},
    duration: i64 = 0,
    shortDescription: []const u8 = "",
    latestCommentSummary: []const u8 = "",
    isChannelVideo: bool = false,
    isPaymentRequired: bool = false,
    playbackPosition: std.json.Value = .null,
    owner: Owner = .{},
    requireSensitiveMasking: bool = false,
    videoLive: std.json.Value = .null,
    @"9d091f87": bool = false,
    acf68865: bool = false,
};
const UserItem = struct { series: Series = .{}, essential: Essential = .{} };
pub const NicoData = struct {
    meta: Meta = .{},
    data: struct { totalCount: ?i64 = null, items: []const UserItem = &.{} } = .{},
};
// The Go mylist decoder intentionally has a smaller schema than NicoData.
// Unknown fields must remain ignored, even if they would be invalid in NicoData.
const MylistVideo = struct {
    id: []const u8 = "",
    registeredAt: Timestamp = .{},
    count: struct { comment: i64 = 0 } = .{},
};
const MylistItem = struct { video: MylistVideo = .{} };
const MylistData = struct {
    meta: Meta = .{},
    data: struct {
        totalCount: ?i64 = null,
        mylist: struct {
            totalCount: ?i64 = null,
            totalItemCount: ?i64 = null,
            items: []const MylistItem = &.{},
        } = .{},
    } = .{},
};

// The complete wire types above are the validation schema, not an allocation
// plan. A projected item retains only a borrowed JSON string span and the two
// values used by filtering. Discarded strings and interface{} values are
// validated directly from scanner tokens; no strings or JSON trees are built.
const StringSpan = struct { json: []const u8 = "\"\"" };
const VideoProjection = struct {
    id: StringSpan = .{},
    registeredAt: Timestamp = .{},
    count: struct { comment: i64 = 0 } = .{},

    fn selected(self: VideoProjection, threshold: i64, after: i64, before: i64) bool {
        return self.count.comment > threshold and self.registeredAt.unix >= after and self.registeredAt.unix < before;
    }
};
const UserProjection = struct { essential: VideoProjection = .{} };
const MylistProjection = struct { video: VideoProjection = .{} };

fn ItemProjection(comptime Item: type) type {
    return struct {
        // Go reuses a slice's backing elements across duplicate array fields,
        // including truncated elements when a later duplicate grows again.
        // Keep initialized slots separately from the visible length. A null or
        // empty array resets these slots, just as encoding/json does.
        slots: std.ArrayList(Item) = .empty,
        count: usize = 0,

        fn reset(self: *@This()) void {
            self.slots.clearRetainingCapacity();
            self.count = 0;
        }
    };
}
const ProjectedUserData = struct {
    meta: Meta = .{},
    data: struct {
        totalCount: ?i64 = null,
        items: ItemProjection(UserProjection) = .{},
    } = .{},
};
const ProjectedMylistData = struct {
    meta: Meta = .{},
    data: struct {
        totalCount: ?i64 = null,
        mylist: struct {
            totalCount: ?i64 = null,
            totalItemCount: ?i64 = null,
            items: ItemProjection(MylistProjection) = .{},
        } = .{},
    } = .{},
};

const Decoder = struct {
    scanner: std.json.Scanner,
    allocator: Allocator,

    const Error = std.json.Scanner.NextError || std.json.Scanner.AllocError || error{ UnexpectedToken, InvalidCharacter, Overflow };

    /// Schema drives validation; Projection contains only fields worth keeping.
    /// A *void projection is a checked discard, not an unchecked skip.
    fn decode(self: *Decoder, comptime Schema: type, projection: anytype) Error!void {
        const Projected = @TypeOf(projection.*);
        if (Schema == std.json.Value) return self.discardAny();
        const kind = try self.scanner.peekNextTokenType();
        if (kind == .null) {
            _ = try self.scanner.next();
            if (Projected != void) switch (@typeInfo(Schema)) {
                .optional => projection.* = null,
                .pointer => |ptr| if (ptr.size == .slice and ptr.child != u8) {
                    projection.reset();
                },
                else => {}, // null does not overwrite Go scalar/struct values.
            };
            return;
        }
        if (Schema == Timestamp) {
            if (kind != .string) return error.UnexpectedToken;
            const token = try self.scanner.nextAllocMax(self.allocator, .alloc_if_needed, self.scanner.input.len);
            const text = switch (token) {
                .string, .allocated_string => |value| value,
                else => unreachable,
            };
            defer if (token == .allocated_string) self.allocator.free(text);
            const unix = cli.parseTimestamp(text) catch return error.UnexpectedToken;
            if (Projected != void) projection.unix = unix;
            return;
        }
        switch (@typeInfo(Schema)) {
            .@"struct" => |info| {
                if (try self.scanner.next() != .object_begin) return error.UnexpectedToken;
                while (try self.scanner.peekNextTokenType() != .object_end) {
                    // Known schema names are ASCII. Unicode simple folding can
                    // expand one name byte to at most three UTF-8 bytes (K).
                    const capacity = comptime blk: {
                        var longest: usize = 0;
                        for (info.field_names) |name| longest = @max(longest, name.len);
                        break :blk longest * 3;
                    };
                    var name_buffer: [capacity]u8 = undefined;
                    const name = try self.readName(&name_buffer);
                    if (name) |text| {
                        inline for (info.field_names, info.field_types) |field_name, Field| {
                            if (foldedNameEqual(text, field_name)) {
                                if (Projected != void and @hasField(Projected, field_name)) {
                                    try self.decode(Field, &@field(projection.*, field_name));
                                } else {
                                    var discarded: void = {};
                                    try self.decode(Field, &discarded);
                                }
                                break;
                            }
                        } else {
                            try self.scanner.skipValue();
                        }
                    } else {
                        try self.scanner.skipValue();
                    }
                }
                _ = try self.scanner.next();
            },
            .optional => |info| {
                var value: info.child = if (Projected != void) projection.* orelse std.mem.zeroes(info.child) else std.mem.zeroes(info.child);
                try self.decode(info.child, &value);
                if (Projected != void) projection.* = value;
            },
            .int => {
                const number = switch (try self.scanner.next()) {
                    .number => |value| value,
                    else => return error.UnexpectedToken,
                };
                const value = try std.fmt.parseInt(Schema, number, 10);
                if (Projected != void) projection.* = value;
            },
            .bool => {
                const value = switch (try self.scanner.next()) {
                    .true => true,
                    .false => false,
                    else => return error.UnexpectedToken,
                };
                if (Projected != void) projection.* = value;
            },
            .pointer => |ptr| {
                if (ptr.size != .slice) @compileError("unsupported API schema pointer");
                if (ptr.child == u8) {
                    if (kind != .string) return error.UnexpectedToken;
                    const start = self.scanner.cursor;
                    try self.scanner.skipValue();
                    if (Projected != void) projection.json = self.scanner.input[start..self.scanner.cursor];
                } else {
                    if (try self.scanner.next() != .array_begin) return error.UnexpectedToken;
                    var index: usize = 0;
                    while (try self.scanner.peekNextTokenType() != .array_end) : (index += 1) {
                        if (Projected != void) {
                            if (index == projection.slots.items.len) try projection.slots.append(self.allocator, .{});
                            try self.decode(ptr.child, &projection.slots.items[index]);
                        } else {
                            var discarded: void = {};
                            try self.decode(ptr.child, &discarded);
                        }
                    }
                    _ = try self.scanner.next();
                    if (Projected != void) {
                        projection.count = index;
                        if (index == 0) projection.reset();
                    }
                }
            },
            else => @compileError("unsupported API schema type"),
        }
    }

    /// Decode a name into bounded stack memory, consuming oversized/escaped
    /// unknown names without allocating. Value strings use skipValue instead.
    fn readName(self: *Decoder, buffer: []u8) Error!?[]const u8 {
        var len: usize = 0;
        var oversized = false;
        while (true) {
            const token = try self.scanner.next();
            const part: []const u8 = switch (token) {
                .string, .partial_string => |value| value,
                .partial_string_escaped_1 => |*value| value,
                .partial_string_escaped_2 => |*value| value,
                .partial_string_escaped_3 => |*value| value,
                .partial_string_escaped_4 => |*value| value,
                else => return error.UnexpectedToken,
            };
            if (!oversized and part.len <= buffer.len - len) {
                @memcpy(buffer[len..][0..part.len], part);
                len += part.len;
            } else oversized = true;
            if (token == .string) return if (oversized) null else buffer[0..len];
        }
    }

    /// Go decodes interface{} numbers as float64. Check every encountered
    /// number, including ones later overwritten by duplicate object keys.
    /// Unknown schema fields intentionally use skipValue instead, since Go
    /// does not impose the float64 range restriction on ignored values.
    fn discardAny(self: *Decoder) Error!void {
        const depth = self.scanner.stackHeight();
        while (true) {
            switch (try self.scanner.next()) {
                .number => |text| {
                    const value = try std.fmt.parseFloat(f64, text);
                    if (!std.math.isFinite(value)) return error.Overflow;
                },
                .end_of_document => return error.UnexpectedToken,
                .partial_string, .partial_string_escaped_1, .partial_string_escaped_2, .partial_string_escaped_3, .partial_string_escaped_4 => continue,
                else => {},
            }
            if (self.scanner.stackHeight() == depth) return;
        }
    }
};

// Go's Unicode simple folding has two non-ASCII equivalents of ASCII letters.
// All schema field names are ASCII, so this is the complete relevant fold set.
fn foldedNameEqual(name: []const u8, field: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(name, field)) return true;
    var i: usize = 0;
    for (field) |expected| {
        if (i >= name.len) return false;
        var actual = name[i];
        i += 1;
        if (actual >= 128) {
            if (std.mem.startsWith(u8, name[i - 1 ..], "ſ")) {
                actual = 's';
                i += 1;
            } else if (std.mem.startsWith(u8, name[i - 1 ..], "K")) {
                actual = 'k';
                i += 2;
            } else return false;
        }
        if (std.ascii.toLower(actual) != std.ascii.toLower(expected)) return false;
    }
    return i == name.len;
}

// encoding/json replaces invalid UTF-8 and unpaired UTF-16 surrogate escapes.
// std.json correctly rejects these by default. Repair only after a syntax error
// so normal API bodies take no extra scan or allocation.
fn repairJsonUnicode(allocator: Allocator, input: []const u8) !?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var changed = false;
    var in_string = false;
    var i: usize = 0;
    while (i < input.len) {
        const c = input[i];
        if (c == '"') {
            in_string = !in_string;
        } else if (in_string and c == '\\' and i + 1 < input.len) {
            if (unicodeEscape(input[i..])) |code| {
                if (code >= 0xd800 and code <= 0xdfff) {
                    if (code <= 0xdbff and i + 12 <= input.len) {
                        if (unicodeEscape(input[i + 6 ..])) |low| {
                            if (low >= 0xdc00 and low <= 0xdfff) {
                                try out.appendSlice(allocator, input[i .. i + 12]);
                                i += 12;
                                continue;
                            }
                        }
                    }
                    try out.appendSlice(allocator, "\\ufffd");
                    i += 6;
                    changed = true;
                    continue;
                }
            }
            try out.appendSlice(allocator, input[i .. i + 2]);
            i += 2;
            continue;
        } else if (in_string and c >= 128) {
            const size = std.unicode.utf8ByteSequenceLength(c) catch 0;
            if (size > 0 and i + size <= input.len) {
                if (std.unicode.utf8Decode(input[i .. i + size])) |_| {
                    try out.appendSlice(allocator, input[i .. i + size]);
                    i += size;
                    continue;
                } else |_| {}
            }
            try out.appendSlice(allocator, "�");
            i += 1;
            changed = true;
            continue;
        }
        try out.append(allocator, c);
        i += 1;
    }
    return if (changed) try out.toOwnedSlice(allocator) else null;
}

fn unicodeEscape(input: []const u8) ?u16 {
    if (input.len < 6 or input[0] != '\\' or input[1] != 'u') return null;
    return std.fmt.parseInt(u16, input[2..6], 16) catch null;
}

pub fn parse(
    allocator: Allocator,
    body: []const u8,
    is_mylist: bool,
    comment: i64,
    after_unix: i64,
    before_exclusive: i64,
) !Page {
    return parseWithTemporary(allocator, allocator, body, is_mylist, comment, after_unix, before_exclusive);
}

/// Output owns exactly the final selected IDs and their slice. Temporary
/// allocations are explicitly freed before returning; no response-wide JSON
/// arena, unused string copies, or dynamically typed JSON trees are retained.
pub fn parseWithTemporary(
    output_allocator: Allocator,
    temporary_allocator: Allocator,
    body: []const u8,
    is_mylist: bool,
    comment: i64,
    after_unix: i64,
    before_exclusive: i64,
) !Page {
    return parseProjected(output_allocator, temporary_allocator, body, is_mylist, comment, after_unix, before_exclusive) catch |err| switch (err) {
        error.SyntaxError => blk: {
            const repaired = try repairJsonUnicode(temporary_allocator, body) orelse return err;
            defer temporary_allocator.free(repaired);
            break :blk try parseProjected(output_allocator, temporary_allocator, repaired, is_mylist, comment, after_unix, before_exclusive);
        },
        else => return err,
    };
}

fn parseProjected(
    output_allocator: Allocator,
    temporary_allocator: Allocator,
    body: []const u8,
    is_mylist: bool,
    comment: i64,
    after_unix: i64,
    before_exclusive: i64,
) !Page {
    return if (is_mylist)
        projectTyped(MylistData, ProjectedMylistData, output_allocator, temporary_allocator, body, comment, after_unix, before_exclusive)
    else
        projectTyped(NicoData, ProjectedUserData, output_allocator, temporary_allocator, body, comment, after_unix, before_exclusive);
}

fn projectTyped(
    comptime Schema: type,
    comptime Projection: type,
    output_allocator: Allocator,
    temporary_allocator: Allocator,
    body: []const u8,
    comment: i64,
    after_unix: i64,
    before_exclusive: i64,
) !Page {
    var decoder: Decoder = .{ .scanner = .initCompleteInput(temporary_allocator, body), .allocator = temporary_allocator };
    defer decoder.scanner.deinit();
    var projected: Projection = .{};
    const items = if (Schema == MylistData) &projected.data.mylist.items else &projected.data.items;
    defer items.slots.deinit(temporary_allocator);
    try decoder.decode(Schema, &projected);
    if (try decoder.scanner.next() != .end_of_document) return error.UnexpectedToken;

    var selected_count: usize = 0;
    for (items.slots.items[0..items.count]) |item| {
        const video = if (Schema == MylistData) item.video else item.essential;
        if (video.selected(comment, after_unix, before_exclusive)) selected_count += 1;
    }
    // Exact output sizing avoids abandoned growth buffers when the caller uses
    // an arena for the invocation's retained results.
    const ids = try output_allocator.alloc([]const u8, selected_count);
    errdefer output_allocator.free(ids);
    var initialized: usize = 0;
    errdefer for (ids[0..initialized]) |id| output_allocator.free(id);
    for (items.slots.items[0..items.count]) |item| {
        const video = if (Schema == MylistData) item.video else item.essential;
        if (!video.selected(comment, after_unix, before_exclusive)) continue;
        // Decode/copy only selected IDs, after the whole page has validated.
        // This scanner needs no nesting storage: its input is one string.
        var string_scanner = std.json.Scanner.initCompleteInput(temporary_allocator, video.id.json);
        defer string_scanner.deinit();
        ids[initialized] = switch (try string_scanner.nextAllocMax(output_allocator, .alloc_always, video.id.json.len)) {
            .allocated_string => |value| value,
            else => unreachable,
        };
        initialized += 1;
    }
    const total = if (Schema == MylistData)
        projected.data.mylist.totalCount orelse projected.data.mylist.totalItemCount orelse projected.data.totalCount
    else
        projected.data.totalCount;
    return .{ .ids = ids, .item_count = items.count, .status = projected.meta.status, .total_count = total };
}

const testing = std.testing;

fn parseTest(body: []const u8, is_mylist: bool) !Page {
    return parse(testing.allocator, body, is_mylist, 0, 0, 4102444800);
}

test "user page preserves complete NicoData schema" {
    const fixture =
        \\{"meta":{"status":200},"data":{"totalCount":2,"items":[{"series":{"id":7,"title":"series","order":1},"essential":{"type":"video","id":"sm9","title":"sample title 1","registeredAt":"2025-01-02T03:04:05Z","count":{"view":100,"comment":12,"mylist":3,"like":8},"thumbnail":{"url":"u","middleUrl":"m","largeUrl":"l","listingUrl":"s","nHdUrl":"hd"},"duration":120,"shortDescription":"desc","latestCommentSummary":"summary","isChannelVideo":false,"isPaymentRequired":true,"playbackPosition":{"position":5},"owner":{"ownerType":"user","id":"1","name":"owner-1","iconUrl":"icon"},"requireSensitiveMasking":false,"videoLive":[1,"x"],"9d091f87":false,"acf68865":true}},{"essential":{"id":"sm10","registeredAt":"2025-01-03T04:05:06Z","count":{"comment":34}}}]}}
    ;
    const page = try parseTest(fixture, false);
    defer page.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), page.item_count);
    try testing.expectEqual(@as(i64, 200), page.status);
    try testing.expectEqual(@as(?i64, 2), page.total_count);
    try testing.expectEqualStrings("sm9", page.ids[0]);
    try testing.expectEqualStrings("sm10", page.ids[1]);
}

test "comment threshold and offset fractional timestamp date boundaries" {
    const body =
        \\{"data":{"items":[{"essential":{"id":"before","registeredAt":"2024-01-01T08:59:59.999999999+09:00","count":{"comment":11}}},{"essential":{"id":"start","registeredAt":"2024-01-01T09:00:00+09:00","count":{"comment":11}}},{"essential":{"id":"equal","registeredAt":"2024-01-01T00:00:00Z","count":{"comment":10}}},{"essential":{"id":"last","registeredAt":"2024-01-01T23:59:59.999999999Z","count":{"comment":11}}},{"essential":{"id":"end","registeredAt":"2024-01-01T19:00:00-05:00","count":{"comment":11}}}]}}
    ;
    const page = try parse(testing.allocator, body, false, 10, 1704067200, 1704153600);
    defer page.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 5), page.item_count);
    try testing.expectEqual(@as(usize, 2), page.ids.len);
    try testing.expectEqualStrings("start", page.ids[0]);
    try testing.expectEqualStrings("last", page.ids[1]);
}

test "mylist totals use nested total then item total then outer total" {
    for ([_]struct { body: []const u8, total: ?i64 }{
        .{ .body = "{\"data\":{\"totalCount\":3,\"mylist\":{\"totalCount\":1,\"totalItemCount\":2}}}", .total = 1 },
        .{ .body = "{\"data\":{\"totalCount\":3,\"mylist\":{\"totalCount\":null,\"totalItemCount\":2}}}", .total = 2 },
        .{ .body = "{\"data\":{\"totalCount\":3,\"mylist\":{\"totalItemCount\":null}}}", .total = 3 },
        .{ .body = "{\"data\":{\"totalCount\":3,\"mylist\":{\"totalCount\":0,\"totalItemCount\":2}}}", .total = 0 },
        .{ .body = "{}", .total = null },
    }) |case| {
        const page = try parseTest(case.body, true);
        defer page.deinit(testing.allocator);
        try testing.expectEqual(case.total, page.total_count);
    }
}

test "mylist filters videos and ignores fields outside its smaller schema" {
    const page = try parseTest("{\"meta\":{\"status\":503},\"data\":{\"mylist\":{\"items\":[{\"video\":{\"id\":\"sm9\",\"registeredAt\":\"2025-01-02T03:04:05Z\",\"title\":42,\"count\":{\"comment\":12,\"view\":\"ignored\"}}}]}}}", true);
    defer page.deinit(testing.allocator);
    try testing.expectEqual(@as(i64, 503), page.status);
    try testing.expectEqualStrings("sm9", page.ids[0]);
}

test "missing null and empty objects use Go zero defaults" {
    for ([_][]const u8{ "null", "{}", "{\"meta\":null,\"data\":null}", "{\"data\":{\"items\":null}}" }) |body| {
        const page = try parseTest(body, false);
        defer page.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 0), page.item_count);
        try testing.expectEqual(@as(i64, 0), page.status);
        try testing.expectEqual(@as(?i64, null), page.total_count);
    }
    const page = try parse(testing.allocator, "{\"data\":{\"items\":[null,{}, {\"essential\":{\"id\":null,\"registeredAt\":null,\"count\":null}}]}}", false, -1, -62135596800, -62135596799);
    defer page.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), page.item_count);
    try testing.expectEqual(@as(usize, 3), page.ids.len);
    for (page.ids) |id| try testing.expectEqualStrings("", id);
}

test "case insensitive names duplicate struct merge and scalar null retention" {
    const page = try parseTest("{\"META\":{\"STATUS\":200},\"meta\":null,\"data\":{\"totalCount\":4,\"items\":[{\"essential\":{\"ID\":\"sm9\",\"id\":null,\"registeredAt\":\"2025-01-02T03:04:05Z\"},\"essential\":{\"COUNT\":{\"Comment\":12}}}]},\"DATA\":{\"totalCount\":null}}", false);
    defer page.deinit(testing.allocator);
    try testing.expectEqual(@as(i64, 200), page.status);
    try testing.expectEqual(@as(?i64, null), page.total_count);
    try testing.expectEqualStrings("sm9", page.ids[0]);
}

test "retained IDs own memory including escaped strings" {
    const body = try testing.allocator.dupe(u8, "{\"data\":{\"items\":[{\"essential\":{\"id\":\"sm\\u0039\",\"registeredAt\":\"2025-01-02T03:04:05Z\",\"count\":{\"comment\":12}}}]}}");
    defer testing.allocator.free(body);
    const page = try parseTest(body, false);
    defer page.deinit(testing.allocator);
    @memset(body, 'x');
    try testing.expectEqualStrings("sm9", page.ids[0]);
}

test "invalid timestamps fail before filtering or duplicate overwrite" {
    for ([_][]const u8{
        "{\"data\":{\"items\":[{\"essential\":{\"registeredAt\":\"invalid\",\"count\":{\"comment\":0}}}]}}",
        "{\"data\":{\"items\":[{\"essential\":{\"registeredAt\":\"invalid\",\"registeredAt\":\"2025-01-02T03:04:05Z\"}}]}}",
        "{\"data\":{\"items\":[{\"essential\":{\"registeredAt\":\"\"}}]}}",
    }) |body| try testing.expectError(error.UnexpectedToken, parseTest(body, false));
}

test "known schema field type errors are rejected even if unused" {
    for ([_][]const u8{
        "{\"meta\":{\"status\":\"200\"}}",
        "{\"data\":{\"items\":[{\"series\":{\"title\":3}}]}}",
        "{\"data\":{\"items\":[{\"essential\":{\"title\":[65]}}]}}",
        "{\"data\":{\"items\":[{\"essential\":{\"isChannelVideo\":1}}]}}",
        "{\"data\":{\"items\":[{\"essential\":{\"owner\":{\"id\":5}}}]}}",
        "{\"data\":{\"items\":{}}}",
        "[]",
    }) |body| try testing.expectError(error.UnexpectedToken, parseTest(body, false));
    for ([_][]const u8{ "{\"data\":{\"totalCount\":1.0}}", "{\"data\":{\"totalCount\":1e2}}" }) |body|
        try testing.expectError(error.InvalidCharacter, parseTest(body, false));
    try testing.expectError(error.Overflow, parseTest("{\"data\":{\"totalCount\":9223372036854775808}}", false));
}

fn allocationFailureTest(allocator: Allocator) !void {
    const page = try parse(allocator, "{\"data\":{\"items\":[{\"essential\":{\"id\":\"sm\\u0039\",\"registeredAt\":\"2025-01-02T03:04:05Z\",\"count\":{\"comment\":12}}},{\"essential\":{\"id\":\"sm10\",\"registeredAt\":\"2025-01-02T03:04:05Z\",\"count\":{\"comment\":12}}}]}}", false, 0, 0, 4102444800);
    defer page.deinit(allocator);
}

test "allocation failures release partial results" {
    try testing.checkAllAllocationFailures(testing.allocator, allocationFailureTest, .{});
}

test "any typed fields reject float64 overflow like Go" {
    try testing.expectError(error.Overflow, parseTest("{\"data\":{\"items\":[{\"essential\":{\"videoLive\":{\"large\":1e999}}}]}}", false));
    const page = try parseTest("{\"unknown\":1e999,\"data\":{\"items\":[{\"essential\":{\"playbackPosition\":1e100}}]}}", false);
    defer page.deinit(testing.allocator);
}

test "Go Unicode replacement and Unicode field folding" {
    const body = "{\"meta\":{\"ſtatus\":201},\"data\":{\"items\":[{\"essential\":{\"id\":\"sm\\ud800x\\udc00\xff\",\"registeredAt\":\"2025-01-02T03:04:05Z\",\"count\":{\"comment\":12,\"liKe\":7}}}]}}";
    const page = try parseTest(body, false);
    defer page.deinit(testing.allocator);
    try testing.expectEqual(@as(i64, 201), page.status);
    try testing.expectEqualStrings("sm�x��", page.ids[0]);
    try testing.expect(foldedNameEqual("liKe", "like"));
    try testing.expect(!foldedNameEqual("ſtatuſx", "status"));
    try testing.expect(!foldedNameEqual("ſtatu", "status"));
    try testing.expect(!foldedNameEqual("ѕtatus", "status"));
}

test "duplicate arrays merge reused item slots including truncated tails" {
    const body =
        \\{"data":{"items":[{"essential":{"id":"first","registeredAt":"2025-01-02T03:04:05Z","count":{"comment":0}}},{"essential":{"id":"tail","registeredAt":"2025-01-02T03:04:05Z","count":{"comment":2}}}],"items":[{"essential":{"count":{"comment":1}}}],"items":[null,{}]}}
    ;
    const page = try parseTest(body, false);
    defer page.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), page.item_count);
    try testing.expectEqual(@as(usize, 2), page.ids.len);
    try testing.expectEqualStrings("first", page.ids[0]);
    try testing.expectEqualStrings("tail", page.ids[1]);
    for ([_][]const u8{ "[]", "null" }) |reset| {
        const cleared = try std.fmt.allocPrint(testing.allocator, "{{\"data\":{{\"items\":[{{\"essential\":{{\"id\":\"old\",\"registeredAt\":\"2025-01-02T03:04:05Z\",\"count\":{{\"comment\":2}}}}}}],\"items\":{s},\"items\":[{{}}]}}}}", .{reset});
        defer testing.allocator.free(cleared);
        const empty = try parse(testing.allocator, cleared, false, -1, -62135596800, -62135596799);
        defer empty.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 1), empty.item_count);
        try testing.expectEqualStrings("", empty.ids[0]);
    }
}

test "mylist duplicate arrays preserve projected fields" {
    const body =
        \\{"data":{"mylist":{"items":[{"video":{"id":"sm9","registeredAt":"2025-01-02T03:04:05Z","count":{"comment":2}}}]}},"DATA":{"mylist":{"items":[{"video":{"id":"sm10"}}]}}}
    ;
    const page = try parseTest(body, true);
    defer page.deinit(testing.allocator);
    try testing.expectEqualStrings("sm10", page.ids[0]);
}

test "discarded schema objects preserve strict field validation" {
    const bad_fields = [_][]const u8{
        "\"series\":{\"id\":\"7\"}",
        "\"series\":{\"order\":true}",
        "\"essential\":{\"type\":{}}",
        "\"essential\":{\"count\":{\"view\":1.0}}",
        "\"essential\":{\"count\":{\"mylist\":\"1\"}}",
        "\"essential\":{\"count\":{\"like\":[]}}",
        "\"essential\":{\"thumbnail\":{\"url\":1}}",
        "\"essential\":{\"thumbnail\":{\"middleUrl\":true}}",
        "\"essential\":{\"thumbnail\":{\"largeUrl\":[]}}",
        "\"essential\":{\"thumbnail\":{\"listingUrl\":{}}}",
        "\"essential\":{\"thumbnail\":{\"nHdUrl\":1}}",
        "\"essential\":{\"duration\":\"12\"}",
        "\"essential\":{\"shortDescription\":1}",
        "\"essential\":{\"latestCommentSummary\":true}",
        "\"essential\":{\"isPaymentRequired\":0}",
        "\"essential\":{\"owner\":{\"ownerType\":0}}",
        "\"essential\":{\"owner\":{\"name\":[]}}",
        "\"essential\":{\"owner\":{\"iconUrl\":{}}}",
        "\"essential\":{\"requireSensitiveMasking\":0}",
        "\"essential\":{\"9d091f87\":0}",
        "\"essential\":{\"acf68865\":0}",
    };
    for (bad_fields) |field| {
        const body = try std.fmt.allocPrint(testing.allocator, "{{\"data\":{{\"items\":[{{{s}}}]}}}}", .{field});
        defer testing.allocator.free(body);
        if (parseTest(body, false)) |page| {
            page.deinit(testing.allocator);
            return error.TestUnexpectedResult;
        } else |err| try testing.expect(err == error.UnexpectedToken or err == error.InvalidCharacter);
    }
}

test "interface numbers validate before duplicate overwrite and discarded array replacement" {
    for ([_][]const u8{
        "{\"data\":{\"items\":[{\"essential\":{\"videoLive\":{\"x\":1e999,\"x\":0}}}]}}",
        "{\"data\":{\"items\":[{\"essential\":{\"playbackPosition\":1e999,\"playbackPosition\":null}}]}}",
        "{\"data\":{\"items\":[{\"essential\":{\"title\":3}}],\"items\":[]}}",
    }) |body| {
        if (parseTest(body, false)) |page| {
            page.deinit(testing.allocator);
            return error.TestUnexpectedResult;
        } else |err| try testing.expect(err == error.UnexpectedToken or err == error.Overflow);
    }
    const page = try parseTest("{\"data\":{\"items\":[{\"essential\":{\"videoLive\":{\"a\":[null,true,false,\"escaped\\nstring\",{\"nested\":1e100}]}}}]}}", false);
    defer page.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), page.item_count);
}

test "large unused escaped strings and JSON trees need bounded scratch space" {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(testing.allocator);
    try body.appendSlice(testing.allocator, "{\"data\":{\"items\":[{\"essential\":{\"id\":\"");
    for (0..20000) |_| try body.appendSlice(testing.allocator, "unused\\u0039");
    try body.appendSlice(testing.allocator, "\",\"title\":\"");
    for (0..20000) |_| try body.appendSlice(testing.allocator, "title\\n");
    try body.appendSlice(testing.allocator, "\",\"videoLive\":[");
    for (0..10000) |_| try body.appendSlice(testing.allocator, "{\"unused\":\"value\\t\"},");
    try body.appendSlice(testing.allocator, "null],\"");
    // A huge escaped unknown name must not allocate either.
    for (0..20000) |_| try body.appendSlice(testing.allocator, "\\u0061");
    try body.appendSlice(testing.allocator, "\":1e999}}]}}");
    var scratch_buffer: [1024]u8 = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&scratch_buffer);
    var no_output_buffer: [0]u8 = .{};
    var no_output = std.heap.FixedBufferAllocator.init(&no_output_buffer);
    const page = try parseWithTemporary(no_output.allocator(), scratch.allocator(), body.items, false, 0, 0, 4102444800);
    defer page.deinit(no_output.allocator());
    try testing.expectEqual(@as(usize, 1), page.item_count);
    try testing.expectEqual(@as(usize, 0), page.ids.len);
}

fn duplicateAndUnicodeFailureTest(allocator: Allocator) !void {
    const body =
        \\{"data":{"items":[{"essential":{"id":"discarded","registeredAt":"2025-01-02T03:04:05Z","count":{"comment":2}}},{"essential":{"id":"tail"}}],"items":[],"items":[{"essential":{"id":"sm\ud800\u0039","registeredAt":"2025-01-02T03:04:05Z","count":{"comment":2}}}],"items":[{}]}}
    ;
    const page = try parse(allocator, body, false, 0, 0, 4102444800);
    defer page.deinit(allocator);
    try testing.expectEqualStrings("sm�9", page.ids[0]);
}

test "allocation failures release duplicate projections and Unicode repair" {
    try testing.checkAllAllocationFailures(testing.allocator, duplicateAndUnicodeFailureTest, .{});
}

test "escaped field names use Unicode folding and bounded name storage" {
    const page = try parseTest("{\"meta\":{\"\\u017Ftatus\":202},\"da\\u0074a\":{\"items\":[{\"essential\":{\"i\\u0064\":\"sm9\",\"registeredAt\":\"2025-01-02T03:04:05Z\",\"count\":{\"com\\u006Dent\":1}}}]}}", false);
    defer page.deinit(testing.allocator);
    try testing.expectEqual(@as(i64, 202), page.status);
    try testing.expectEqualStrings("sm9", page.ids[0]);
}

test "trailing JSON and malformed discarded data fail the entire page" {
    for ([_][]const u8{
        "{} {}",
        "{\"data\":{\"items\":[{\"essential\":{\"count\":{\"comment\":1},\"registeredAt\":\"2025-01-02T03:04:05Z\",\"id\":\"sm9\"}}]},\"unused\":[1,]}",
    }) |body| {
        if (parseTest(body, false)) |page| {
            page.deinit(testing.allocator);
            return error.TestUnexpectedResult;
        } else |err| try testing.expect(err == error.UnexpectedToken or err == error.SyntaxError);
    }
}
