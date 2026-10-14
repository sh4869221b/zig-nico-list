//! Compatibility-focused CLI and serialization for go-nico-list v0.29.0.
//! All returned slices use the caller's allocator; an invocation arena is recommended.
const std = @import("std");
const date_time = @import("date_time.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
pub const watch_url = "https://www.nicovideo.jp/watch/";

pub const Config = struct {
    comment: i64 = 0,
    dateafter: []const u8 = "10000101",
    datebefore: []const u8 = "99991231",
    url: bool = false,
    concurrency_targets: i64 = 3,
    concurrency_pages: i64 = 1,
    concurrency_http: i64 = 0,
    concurrency_adaptive: bool = false,
    http_metrics: bool = false,
    retries: i64 = 10,
    timeout_ns: i64 = 10_000_000_000,
    rate_limit: f64 = 0,
    min_interval_ns: i64 = 0,
    input_file: []const u8 = "",
    logfile: []const u8 = "",
    stdin: bool = false,
    progress: bool = false,
    no_progress: bool = false,
    strict: bool = false,
    best_effort: bool = false,
    dedupe: bool = false,
    no_sort: bool = false,
    json: bool = false,
    target_explicit: bool = false,
    page_explicit: bool = false,
    http_explicit: bool = false,
    base_url: []const u8 = "https://nvapi.nicovideo.jp/v3",
    after_unix: i64 = -30_610_224_000,
    before_unix_exclusive: i64 = 253_402_300_800,
};
pub const Action = enum { run, help, version };
pub const Parsed = struct {
    config: Config = .{},
    inputs: []const []const u8 = &.{},
    action: Action = .run,
    error_message: ?[]const u8 = null,
};
pub const TargetType = enum { user, mylist };
pub const Target = struct { type: TargetType, id: []const u8 };
pub const TargetResult = struct {
    order: usize,
    target: Target,
    items: []const []const u8 = &.{},
    error_message: []const u8 = "",
};
pub const Counts = struct { total: usize = 0, valid: usize = 0, invalid: usize = 0 };
pub const InputBatch = struct { inputs: []const []const u8, error_message: ?[]const u8 = null };

const FlagKind = enum { integer, string, boolean, duration, float };
const Flag = struct { name: []const u8, alias: ?u8 = null, field: []const u8, kind: FlagKind };
const flags = [_]Flag{
    .{ .name = "comment", .alias = 'c', .field = "comment", .kind = .integer },
    .{ .name = "dateafter", .alias = 'a', .field = "dateafter", .kind = .string },
    .{ .name = "datebefore", .alias = 'b', .field = "datebefore", .kind = .string },
    .{ .name = "url", .alias = 'u', .field = "url", .kind = .boolean },
    .{ .name = "concurrency-targets", .alias = 'T', .field = "concurrency_targets", .kind = .integer },
    .{ .name = "concurrency-pages", .alias = 'P', .field = "concurrency_pages", .kind = .integer },
    .{ .name = "concurrency-http", .alias = 'H', .field = "concurrency_http", .kind = .integer },
    .{ .name = "concurrency-adaptive", .alias = 'A', .field = "concurrency_adaptive", .kind = .boolean },
    .{ .name = "http-metrics", .field = "http_metrics", .kind = .boolean },
    .{ .name = "timeout", .field = "timeout_ns", .kind = .duration },
    .{ .name = "retries", .field = "retries", .kind = .integer },
    .{ .name = "rate-limit", .field = "rate_limit", .kind = .float },
    .{ .name = "min-interval", .field = "min_interval_ns", .kind = .duration },
    .{ .name = "input-file", .field = "input_file", .kind = .string },
    .{ .name = "stdin", .field = "stdin", .kind = .boolean },
    .{ .name = "logfile", .field = "logfile", .kind = .string },
    .{ .name = "progress", .field = "progress", .kind = .boolean },
    .{ .name = "no-progress", .field = "no_progress", .kind = .boolean },
    .{ .name = "strict", .field = "strict", .kind = .boolean },
    .{ .name = "best-effort", .field = "best_effort", .kind = .boolean },
    .{ .name = "dedupe", .field = "dedupe", .kind = .boolean },
    .{ .name = "no-sort", .field = "no_sort", .kind = .boolean },
    .{ .name = "json", .field = "json", .kind = .boolean },
};

/// args excludes argv[0]. Flags may be interspersed with positional inputs.
pub fn parse(allocator: Allocator, args: []const []const u8) !Parsed {
    var result: Parsed = .{};
    var inputs: std.ArrayList([]const u8) = .empty;
    defer inputs.deinit(allocator);
    var i: usize = 0;
    var positional_only = false;
    var help = false;
    var version = false;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (positional_only or arg.len < 2 or arg[0] != '-') {
            try inputs.append(allocator, arg);
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            positional_only = true;
            continue;
        }
        const long = arg[1] == '-';
        if (long and (arg[2] == '-' or arg[2] == '=')) {
            result.error_message = try std.fmt.allocPrint(allocator, "bad flag syntax: {s}", .{arg});
            return result;
        }
        var offset: usize = if (long) 2 else 1;
        while (offset < arg.len) {
            const start = offset;
            const eq_index = if (long) std.mem.indexOfScalarPos(u8, arg, offset, '=') else null;
            const name = if (long) arg[offset .. eq_index orelse arg.len] else arg[offset .. offset + 1];
            const builtin_help = std.mem.eql(u8, name, if (long) "help" else "h");
            const builtin_version = std.mem.eql(u8, name, if (long) "version" else "v");
            const found: ?usize = blk: {
                for (flags, 0..) |flag, idx| {
                    if (if (long) std.mem.eql(u8, name, flag.name) else flag.alias != null and name[0] == flag.alias.?) break :blk idx;
                }
                break :blk null;
            };
            if (found == null and !builtin_help and !builtin_version) {
                result.error_message = if (long)
                    try std.fmt.allocPrint(allocator, "unknown flag: --{s}", .{name})
                else
                    try std.fmt.allocPrint(allocator, "unknown shorthand flag: '{s}' in -{s}", .{ name, arg[start..] });
                return result;
            }
            const kind: FlagKind = if (found) |idx| flags[idx].kind else .boolean;
            offset = if (long) arg.len else offset + 1;
            var value: []const u8 = undefined;
            if (long and eq_index != null) {
                value = arg[eq_index.? + 1 ..];
            } else if (!long and offset + 1 < arg.len and arg[offset] == '=') {
                value = arg[offset + 1 ..];
                offset = arg.len;
            } else if (kind == .boolean) {
                value = "true";
            } else if (!long and offset < arg.len) {
                value = arg[offset..];
                offset = arg.len;
            } else {
                i += 1;
                if (i == args.len) {
                    result.error_message = if (long)
                        try std.fmt.allocPrint(allocator, "flag needs an argument: --{s}", .{name})
                    else
                        try std.fmt.allocPrint(allocator, "flag needs an argument: '{s}' in -{s}", .{ name, arg[start..] });
                    return result;
                }
                value = args[i];
            }
            if (builtin_help or builtin_version) {
                const b = parseBool(value) catch {
                    const flag: Flag = .{ .name = if (builtin_help) "help" else "version", .alias = if (builtin_help) 'h' else 'v', .field = "", .kind = .boolean };
                    result.error_message = try invalidValue(allocator, flag, value, error.InvalidBoolean);
                    return result;
                };
                if (builtin_help) help = b else version = b;
            } else {
                const idx = found.?;
                applyFlag(&result.config, idx, value) catch |err| {
                    result.error_message = try invalidValue(allocator, flags[idx], value, err);
                    return result;
                };
            }
        }
    }
    result.inputs = try inputs.toOwnedSlice(allocator);
    result.action = if (help) .help else if (version) .version else .run;
    return result;
}

fn invalidValue(a: Allocator, flag: Flag, value: []const u8, err: anyerror) ![]const u8 {
    const name = if (flag.alias) |alias|
        try std.fmt.allocPrint(a, "-{c}, --{s}", .{ alias, flag.name })
    else
        try std.fmt.allocPrint(a, "--{s}", .{flag.name});
    defer a.free(name);
    const cause = switch (flag.kind) {
        .boolean => "strconv.ParseBool: parsing",
        .integer => "strconv.ParseInt: parsing",
        .float => "strconv.ParseFloat: parsing",
        .duration => return durationErrorMessage(a, name, value),
        .string => unreachable,
    };
    return std.fmt.allocPrint(a, "invalid argument \"{s}\" for \"{s}\" flag: {s} \"{s}\": {s}", .{ value, name, cause, value, if (err == error.Overflow) "value out of range" else "invalid syntax" });
}

fn durationErrorMessage(a: Allocator, name: []const u8, value: []const u8) ![]const u8 {
    var i: usize = if (value.len > 0 and (value[0] == '+' or value[0] == '-')) 1 else 0;
    while (i < value.len) {
        const start = i;
        while (i < value.len and (std.ascii.isDigit(value[i]) or value[i] == '.')) : (i += 1) {}
        if (i == start) break;
        if (i == value.len) return std.fmt.allocPrint(a, "invalid argument \"{s}\" for \"{s}\" flag: time: missing unit in duration \"{s}\"", .{ value, name, value });
        const unit_start = i;
        while (i < value.len and !std.ascii.isDigit(value[i]) and value[i] != '.') : (i += 1) {}
        const unit = value[unit_start..i];
        var known = false;
        for ([_][]const u8{ "ns", "us", "µs", "μs", "ms", "s", "m", "h" }) |u| if (std.mem.eql(u8, unit, u)) {
            known = true;
            break;
        };
        if (!known) return std.fmt.allocPrint(a, "invalid argument \"{s}\" for \"{s}\" flag: time: unknown unit \"{s}\" in duration \"{s}\"", .{ value, name, unit, value });
    }
    return std.fmt.allocPrint(a, "invalid argument \"{s}\" for \"{s}\" flag: time: invalid duration \"{s}\"", .{ value, name, value });
}

fn applyFlag(cfg: *Config, index: usize, value: []const u8) !void {
    inline for (flags, 0..) |flag, idx| {
        if (index == idx) {
            @field(cfg, flag.field) = switch (flag.kind) {
                .integer => try parseInteger(value),
                .string => value,
                .boolean => try parseBool(value),
                .duration => try parseDuration(value),
                .float => try parseFloat(value),
            };
            if (comptime std.mem.eql(u8, flag.name, "concurrency-targets")) cfg.target_explicit = true;
            if (comptime std.mem.eql(u8, flag.name, "concurrency-pages")) cfg.page_explicit = true;
            if (comptime std.mem.eql(u8, flag.name, "concurrency-http")) cfg.http_explicit = true;
            return;
        }
    }
    unreachable;
}

fn parseInteger(value: []const u8) !i64 {
    if (value.len == 0) return error.InvalidCharacter;
    const negative = value[0] == '-';
    var i: usize = if (value[0] == '+' or negative) 1 else 0;
    if (i == value.len) return error.InvalidCharacter;
    var base: u8 = 10;
    if (value.len > i + 1 and value[i] == '0') {
        base = 8;
        switch (value[i + 1]) {
            'b', 'B' => {
                base = 2;
                i += 2;
            },
            'o', 'O' => {
                base = 8;
                i += 2;
            },
            'x', 'X' => {
                base = 16;
                i += 2;
            },
            else => i += 1,
        }
        if (i < value.len and value[i] == '_') i += 1;
    }
    if (i == value.len) return error.InvalidCharacter;
    var n: u64 = 0;
    var previous_digit = false;
    const max: u64 = if (negative) @as(u64, 1) << 63 else std.math.maxInt(i64);
    while (i < value.len) : (i += 1) {
        if (value[i] == '_') {
            if (!previous_digit or i + 1 == value.len) return error.InvalidCharacter;
            previous_digit = false;
            continue;
        }
        const digit = std.fmt.charToDigit(value[i], base) catch return error.InvalidCharacter;
        if (n > (max - digit) / base) return error.Overflow;
        n = n * base + digit;
        previous_digit = true;
    }
    if (negative) {
        if (n == @as(u64, 1) << 63) return std.math.minInt(i64);
        return -@as(i64, @intCast(n));
    }
    return @intCast(n);
}

fn parseFloat(text: []const u8) !f64 {
    const value = try std.fmt.parseFloat(f64, text);
    if (std.math.isInf(value)) {
        const unsigned = if (text.len > 0 and (text[0] == '+' or text[0] == '-')) text[1..] else text;
        if (!std.ascii.eqlIgnoreCase(unsigned, "inf") and !std.ascii.eqlIgnoreCase(unsigned, "infinity")) return error.Overflow;
    }
    if (std.math.isNan(value) and !std.ascii.eqlIgnoreCase(text, "nan")) return error.InvalidCharacter;
    return value;
}

fn parseBool(value: []const u8) !bool {
    for ([_][]const u8{ "1", "t", "T", "TRUE", "true", "True" }) |v| if (std.mem.eql(u8, value, v)) return true;
    for ([_][]const u8{ "0", "f", "F", "FALSE", "false", "False" }) |v| if (std.mem.eql(u8, value, v)) return false;
    return error.InvalidBoolean;
}

/// Go time.ParseDuration-compatible units, signs, fractional units and bounds.
pub fn parseDuration(text: []const u8) error{InvalidDuration}!i64 {
    if (text.len == 0) return error.InvalidDuration;
    var i: usize = 0;
    const negative = text[0] == '-';
    if (negative or text[0] == '+') i += 1;
    if (std.mem.eql(u8, text[i..], "0")) return 0;
    if (i == text.len) return error.InvalidDuration;
    var total: u128 = 0;
    while (i < text.len) {
        var integral: u128 = 0;
        var digits: usize = 0;
        while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {
            integral = std.math.mul(u128, integral, 10) catch return error.InvalidDuration;
            integral = std.math.add(u128, integral, text[i] - '0') catch return error.InvalidDuration;
            digits += 1;
        }
        var fraction: u128 = 0;
        var divisor: u128 = 1;
        if (i < text.len and text[i] == '.') {
            i += 1;
            var frac_digits: usize = 0;
            while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {
                if (frac_digits < 18) {
                    fraction = fraction * 10 + text[i] - '0';
                    divisor *= 10;
                }
                frac_digits += 1;
                digits += 1;
            }
        }
        if (digits == 0) return error.InvalidDuration;
        const unit_start = i;
        while (i < text.len and !std.ascii.isDigit(text[i]) and text[i] != '.') : (i += 1) {}
        const unit = text[unit_start..i];
        const multiplier: u128 = blk: {
            if (std.mem.eql(u8, unit, "ns")) break :blk 1;
            if (std.mem.eql(u8, unit, "us") or std.mem.eql(u8, unit, "µs") or std.mem.eql(u8, unit, "μs")) break :blk 1_000;
            if (std.mem.eql(u8, unit, "ms")) break :blk 1_000_000;
            if (std.mem.eql(u8, unit, "s")) break :blk 1_000_000_000;
            if (std.mem.eql(u8, unit, "m")) break :blk 60_000_000_000;
            if (std.mem.eql(u8, unit, "h")) break :blk 3_600_000_000_000;
            return error.InvalidDuration;
        };
        const integer_ns = std.math.mul(u128, integral, multiplier) catch return error.InvalidDuration;
        const part = std.math.add(u128, integer_ns, fraction * multiplier / divisor) catch return error.InvalidDuration;
        total = std.math.add(u128, total, part) catch return error.InvalidDuration;
        if (total > @as(u128, 1) << 63) return error.InvalidDuration;
    }
    if (negative) {
        if (total == @as(u128, 1) << 63) return std.math.minInt(i64);
        return -@as(i64, @intCast(total));
    }
    if (total > std.math.maxInt(i64)) return error.InvalidDuration;
    return @intCast(total);
}

pub fn validate(_: Allocator, cfg: *Config) !?[]const u8 {
    if (cfg.concurrency_http < 0) return "concurrency-http must be >= 0";
    if (cfg.concurrency_targets < 1) return "concurrency-targets must be at least 1";
    if (cfg.concurrency_pages < 1) return "concurrency-pages must be at least 1";
    if (cfg.retries < 1) return "retries must be at least 1";
    if (cfg.timeout_ns <= 0) return "timeout must be greater than 0";
    if (cfg.rate_limit < 0) return "rate-limit must be at least 0";
    if (cfg.min_interval_ns < 0) return "min-interval must be at least 0";
    cfg.after_unix = date_time.parseDate(cfg.dateafter) catch return "dateafter format error";
    const before = date_time.parseDate(cfg.datebefore) catch return "datebefore format error";
    if (cfg.after_unix > before) return "dateafter must be on or before datebefore";
    cfg.before_unix_exclusive = before + 86400;
    return null;
}

/// Deliberately mirrors the two Go regex searches: any user match wins over
/// any mylist match, even if the mylist occurs earlier in the input string.
pub fn parseTarget(input: []const u8) ?Target {
    for ([_]TargetType{ .user, .mylist }) |kind| {
        const prefix = if (kind == .user) "nicovideo.jp/user/" else "nicovideo.jp/mylist/";
        const max_digits: usize = if (kind == .user) 9 else 12;
        var search: usize = 0;
        while (std.mem.indexOfPos(u8, input, search, prefix)) |pos| {
            const start = pos + prefix.len;
            var end = start;
            while (end < input.len and end < start + max_digits and std.ascii.isDigit(input[end])) : (end += 1) {}
            if (end > start) return .{ .type = kind, .id = input[start..end] };
            search = start;
        }
    }
    return null;
}

pub const InputCallback = *const fn (?*anyopaque, []const u8) anyerror!void;

/// Inputs are delivered incrementally, allowing fetches to start before the
/// next stdin/file line arrives. File strings live in the caller's allocator.
/// Cancellation is a successful early stop; an input read error is returned
/// separately so the command can cancel all already-dispatched target tasks.
pub fn streamInputs(a: Allocator, io: Io, cfg: Config, positional: []const []const u8, context: ?*anyopaque, callback: InputCallback) anyerror!?[]const u8 {
    var count: usize = 0;
    for (positional) |input| {
        callback(context, input) catch |err| {
            if (err == error.Canceled) return null;
            return err;
        };
        count += 1;
    }
    if (cfg.input_file.len > 0) {
        const file = Io.Dir.cwd().openFile(io, cfg.input_file, .{}) catch |err| {
            if (err == error.Canceled) return null;
            return try std.fmt.allocPrint(a, "open {s}: {s}", .{ cfg.input_file, fileErrorMessage(err) });
        };
        defer file.close(io);
        const outcome = try streamFileLines(a, io, file, context, callback, &count);
        if (outcome.canceled) return null;
        if (outcome.error_message) |msg| return msg;
    }
    if (cfg.stdin) {
        const outcome = try streamFileLines(a, io, Io.File.stdin(), context, callback, &count);
        if (outcome.canceled) return null;
        if (outcome.error_message) |msg| return msg;
    }
    return if (count == 0) "no inputs provided" else null;
}

pub fn readInputs(a: Allocator, io: Io, cfg: Config, positional: []const []const u8) !InputBatch {
    const Context = struct {
        allocator: Allocator,
        inputs: std.ArrayList([]const u8) = .empty,
        fn append(ptr: ?*anyopaque, input: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ptr.?));
            try self.inputs.append(self.allocator, input);
        }
    };
    var ctx: Context = .{ .allocator = a };
    defer ctx.inputs.deinit(a);
    const input_error = try streamInputs(a, io, cfg, positional, &ctx, Context.append);
    return .{ .inputs = try ctx.inputs.toOwnedSlice(a), .error_message = input_error };
}

fn fileErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "no such file or directory",
        error.AccessDenied, error.PermissionDenied => "permission denied",
        error.IsDir => "is a directory",
        else => @errorName(err),
    };
}

const StreamOutcome = struct { canceled: bool = false, error_message: ?[]const u8 = null };

fn streamFileLines(a: Allocator, io: Io, file: Io.File, context: ?*anyopaque, callback: InputCallback, count: *usize) anyerror!StreamOutcome {
    const buffer = try a.alloc(u8, 1024 * 1024);
    defer a.free(buffer);
    var reader = file.readerStreaming(io, buffer);
    while (true) {
        const raw = reader.interface.takeDelimiter('\n') catch |err| {
            if (err == error.ReadFailed) {
                if (reader.err) |underlying| if (underlying == error.Canceled) return .{ .canceled = true };
            }
            return .{ .error_message = switch (err) {
                error.StreamTooLong => "bufio.Scanner: token too long",
                error.ReadFailed => try std.fmt.allocPrint(a, "input read error: {s}", .{if (reader.err) |underlying| @errorName(underlying) else "ReadFailed"}),
            } };
        };
        const line = raw orelse break;
        const trimmed = trimSpace(line);
        if (trimmed.len == 0) continue;
        const owned = try a.dupe(u8, trimmed);
        callback(context, owned) catch |err| {
            if (err == error.Canceled) return .{ .canceled = true };
            return err;
        };
        count.* += 1;
    }
    return .{};
}

/// Unicode whitespace matches Go strings.TrimSpace (Unicode White_Space).
pub fn trimSpace(text: []const u8) []const u8 {
    var start: usize = 0;
    var last_nonspace: usize = 0;
    var leading = true;
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        var valid_len = @min(@as(usize, len), text.len - i);
        const rune = std.unicode.utf8Decode(text[i .. i + valid_len]) catch blk: {
            valid_len = 1;
            break :blk @as(u21, 0xfffd);
        };
        const ws = (rune >= 9 and rune <= 13) or rune == 32 or rune == 0x85 or rune == 0xa0 or rune == 0x1680 or (rune >= 0x2000 and rune <= 0x200a) or rune == 0x2028 or rune == 0x2029 or rune == 0x202f or rune == 0x205f or rune == 0x3000;
        i += valid_len;
        if (leading and ws) start = i else leading = false;
        if (!ws) last_nonspace = i;
    }
    return text[start..@max(start, last_nonspace)];
}

pub fn exitMessage(cfg: Config, invalid_count: usize, input_error: ?[]const u8, fetch_error: ?[]const u8) ?[]const u8 {
    if (input_error) |msg| return msg;
    if (cfg.strict and invalid_count > 0) return "invalid input detected";
    if (cfg.best_effort) return null;
    return fetch_error;
}

pub const videoIDLessThan = @import("id_order.zig").less;
pub const sortVideoIDs = @import("id_order.zig").sort;

pub fn targetLessThan(_: void, left: TargetResult, right: TargetResult) bool {
    const lt = @tagName(left.target.type);
    const rt = @tagName(right.target.type);
    if (!std.mem.eql(u8, lt, rt)) return std.mem.lessThan(u8, lt, rt);
    const l = std.mem.trimStart(u8, left.target.id, "0");
    const r = std.mem.trimStart(u8, right.target.id, "0");
    if (l.len != r.len) return l.len < r.len;
    if (!std.mem.eql(u8, l, r)) return std.mem.lessThan(u8, l, r);
    if (!std.mem.eql(u8, left.target.id, right.target.id)) return std.mem.lessThan(u8, left.target.id, right.target.id);
    return std.mem.lessThan(u8, left.error_message, right.error_message);
}

pub fn writeOutput(a: Allocator, out: *Io.Writer, cfg: Config, counts: Counts, invalid: []const []const u8, results: []const TargetResult) !usize {
    const ordered = try a.dupe(TargetResult, results);
    defer a.free(ordered);
    if (cfg.json and cfg.no_sort) std.mem.sort(TargetResult, ordered, {}, struct {
        fn less(_: void, l: TargetResult, r: TargetResult) bool {
            return l.order < r.order;
        }
    }.less);
    var items: std.ArrayList([]const u8) = .empty;
    defer items.deinit(a);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(a);
    for (ordered) |result| {
        for (result.items) |id| {
            if (cfg.dedupe) {
                const entry = try seen.getOrPut(a, id);
                if (entry.found_existing) continue;
            }
            try items.append(a, id);
        }
    }
    if (!cfg.no_sort) try sortVideoIDs(a, items.items);
    if (cfg.json) {
        std.mem.sort(TargetResult, ordered, {}, targetLessThan);
        try out.print("{{\"inputs\":{{\"total\":{d},\"valid\":{d},\"invalid\":{d}}},\"invalid\":", .{ counts.total, counts.valid, counts.invalid });
        try writeJsonStrings(out, invalid, false);
        try out.writeAll(",\"targets\":[");
        for (ordered, 0..) |r, i| {
            if (i > 0) try out.writeByte(',');
            try out.writeAll("{\"type\":");
            try writeJsonString(out, @tagName(r.target.type));
            try out.writeAll(",\"id\":");
            try writeJsonString(out, r.target.id);
            try out.writeAll(",\"items\":");
            try writeJsonStrings(out, r.items, true);
            try out.writeAll(",\"error\":");
            try writeJsonString(out, r.error_message);
            try out.writeByte('}');
        }
        try out.writeAll("],\"errors\":[");
        var first = true;
        for (results) |r| {
            if (r.error_message.len == 0) continue;
            if (!first) try out.writeByte(',');
            first = false;
            try writeJsonString(out, r.error_message);
        }
        try out.print("],\"output_count\":{d},\"items\":", .{items.items.len});
        try writeJsonStrings(out, items.items, true);
        try out.writeAll("}\n");
    } else {
        try writeLines(out, items.items, cfg.url);
    }
    return items.items.len;
}

pub fn writeLines(out: *Io.Writer, items: []const []const u8, url: bool) !void {
    for (items) |item| {
        if (url) try out.writeAll(watch_url);
        try out.writeAll(item);
        try out.writeByte('\n');
    }
}

fn writeJsonStrings(out: *Io.Writer, items: []const []const u8, normalize: bool) !void {
    try out.writeByte('[');
    for (items, 0..) |item, i| {
        if (i > 0) try out.writeByte(',');
        try writeJsonString(out, if (normalize and std.mem.startsWith(u8, item, watch_url)) item[watch_url.len..] else item);
    }
    try out.writeByte(']');
}

/// Go encoding/json string escaping, including HTML and invalid UTF-8.
pub fn writeJsonString(out: *Io.Writer, text: []const u8) !void {
    try out.writeByte('"');
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        switch (c) {
            '"', '\\' => {
                try out.writeByte('\\');
                try out.writeByte(c);
                i += 1;
            },
            '\n' => {
                try out.writeAll("\\n");
                i += 1;
            },
            '\r' => {
                try out.writeAll("\\r");
                i += 1;
            },
            '\t' => {
                try out.writeAll("\\t");
                i += 1;
            },
            '\x08' => {
                try out.writeAll("\\b");
                i += 1;
            },
            '\x0c' => {
                try out.writeAll("\\f");
                i += 1;
            },
            0...7, 11, 14...31, '<', '>', '&' => {
                try out.print("\\u00{x:0>2}", .{c});
                i += 1;
            },
            32...33, 35...37, 39...59, 61, 63...91, 93...127 => {
                try out.writeByte(c);
                i += 1;
            },
            else => {
                const len = std.unicode.utf8ByteSequenceLength(c) catch {
                    try out.writeAll("\\ufffd");
                    i += 1;
                    continue;
                };
                if (i + len > text.len) {
                    try out.writeAll("\\ufffd");
                    i += 1;
                    continue;
                }
                const rune = std.unicode.utf8Decode(text[i .. i + len]) catch {
                    try out.writeAll("\\ufffd");
                    i += 1;
                    continue;
                };
                if (rune == 0x2028 or rune == 0x2029) try out.print("\\u{x:0>4}", .{rune}) else try out.writeAll(text[i .. i + len]);
                i += len;
            },
        }
    }
    try out.writeByte('"');
}

pub const help_text =
    \\niconico {user}/video url get video list
    \\
    \\Usage:
    \\  go-nico-list [flags]
    \\
    \\Flags:
    \\      --best-effort               always exit 0 while logging fetch errors
    \\  -c, --comment number            lower comment limit number
    \\  -A, --concurrency-adaptive      automatically adjust target, page, and HTTP concurrency; explicit --concurrency-targets, --concurrency-pages, and --concurrency-http values fix their layer
    \\  -H, --concurrency-http int      maximum command-wide HTTP requests (0 means no additional maximum)
    \\  -P, --concurrency-pages int     number of concurrent page requests per target when totalCount is known (default 1)
    \\  -T, --concurrency-targets int   number of concurrent input targets (default 3)
    \\  -a, --dateafter YYYYMMDD        date YYYYMMDD after (default "10000101")
    \\  -b, --datebefore YYYYMMDD       date YYYYMMDD before (default "99991231")
    \\      --dedupe                    remove duplicate output IDs before output
    \\  -h, --help                      help for go-nico-list
    \\      --http-metrics              log aggregate HTTP performance metrics
    \\      --input-file string         read inputs from file (newline-separated)
    \\      --json                      emit JSON output to stdout
    \\      --logfile string            log output file path
    \\      --min-interval duration     minimum interval between requests (0 disables)
    \\      --no-progress               disable progress output
    \\      --no-sort                   skip sorting output IDs for faster output
    \\      --progress                  force enable progress output
    \\      --rate-limit float          maximum requests per second (0 disables)
    \\      --retries int               number of retries for requests (default 10)
    \\      --stdin                     read inputs from stdin (newline-separated)
    \\      --strict                    return non-zero if any input is invalid
    \\      --timeout duration          HTTP client timeout (default 10s)
    \\  -u, --url                       output id add url
    \\  -v, --version                   version for go-nico-list
    \\
;

test "canonical flags, aliases, explicit defaults, repeats and interspersed inputs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try parse(a, &.{ "nicovideo.jp/user/1", "-T3", "-AP4", "--concurrency-http=0", "-A=false", "--json=true", "--json=false", "-uc010", "-a20240101", "-b", "20241231", "--", "--removed" });
    try std.testing.expectEqual(@as(?[]const u8, null), p.error_message);
    try std.testing.expect(p.config.target_explicit and p.config.page_explicit and p.config.http_explicit);
    try std.testing.expectEqual(@as(i64, 3), p.config.concurrency_targets);
    try std.testing.expectEqual(@as(i64, 4), p.config.concurrency_pages);
    try std.testing.expectEqual(@as(i64, 8), p.config.comment);
    try std.testing.expect(p.config.url and !p.config.concurrency_adaptive and !p.config.json);
    try std.testing.expectEqualStrings("20240101", p.config.dateafter);
    try std.testing.expectEqual(@as(usize, 2), p.inputs.len);
    try std.testing.expectEqualStrings("--removed", p.inputs[1]);
}

test "removed aliases fail and help/version follow boolean semantics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "--concurrency", "--page-concurrency", "--http-concurrency", "--adaptive-concurrency", "--adaptive-http-concurrency", "-n" }) |flag| {
        const p = try parse(a, &.{flag});
        try std.testing.expect(p.error_message != null);
    }
    try std.testing.expectEqual(Action.help, (try parse(a, &.{"-vh"})).action);
    try std.testing.expectEqual(Action.version, (try parse(a, &.{ "--help=false", "-v" })).action);
    try std.testing.expectEqual(Action.run, (try parse(a, &.{ "--version=true", "--version=false" })).action);
    try std.testing.expectEqualStrings("flag needs an argument: --timeout", (try parse(a, &.{"--timeout"})).error_message.?);
    try std.testing.expect((try parse(a, &.{"--concurrency-adaptive=bad"})).error_message != null);
    try std.testing.expectEqualStrings("false", (try parse(a, &.{ "--json", "false" })).inputs[0]);
}

test "Go duration syntax and overflow boundaries" {
    try std.testing.expectEqual(@as(i64, 5_400_000_000_000), try parseDuration("1h30m"));
    try std.testing.expectEqual(@as(i64, 500_000_000), try parseDuration(".5s"));
    try std.testing.expectEqual(@as(i64, 1_000_000_000), try parseDuration("+1.s"));
    try std.testing.expectEqual(@as(i64, -1_501), try parseDuration("-1.5µs1ns"));
    try std.testing.expectEqual(@as(i64, 0), try parseDuration("-0"));
    try std.testing.expectEqual(std.math.maxInt(i64), try parseDuration("9223372036854775807ns"));
    try std.testing.expectEqual(std.math.minInt(i64), try parseDuration("-9223372036854775808ns"));
    for ([_][]const u8{ "", "1", "1d", "1s-2s", ".s", "9223372036854775808ns", "-9223372036854775809ns" }) |text| {
        try std.testing.expectError(error.InvalidDuration, parseDuration(text));
    }
}

test "validation and strict best-effort precedence" {
    var cfg: Config = .{};
    try std.testing.expectEqual(@as(?[]const u8, null), try validate(std.testing.allocator, &cfg));
    cfg.concurrency_http = -1;
    try std.testing.expectEqualStrings("concurrency-http must be >= 0", (try validate(std.testing.allocator, &cfg)).?);
    cfg = .{ .dateafter = "20240102", .datebefore = "20240101" };
    try std.testing.expectEqualStrings("dateafter must be on or before datebefore", (try validate(std.testing.allocator, &cfg)).?);
    cfg = .{ .strict = true, .best_effort = true };
    try std.testing.expectEqualStrings("invalid input detected", exitMessage(cfg, 1, null, "fetch failed").?);
    try std.testing.expectEqualStrings("input failed", exitMessage(cfg, 1, "input failed", "fetch failed").?);
    try std.testing.expectEqual(@as(?[]const u8, null), exitMessage(cfg, 0, null, "fetch failed"));
}

test "date validation keeps inclusive UTC bounds and CLI diagnostics" {
    var cfg: Config = .{ .dateafter = "19700101", .datebefore = "19700101" };
    try std.testing.expectEqual(@as(?[]const u8, null), try validate(std.testing.allocator, &cfg));
    try std.testing.expectEqual(@as(i64, 0), cfg.after_unix);
    try std.testing.expectEqual(@as(i64, 86400), cfg.before_unix_exclusive);
    cfg = .{ .dateafter = "20250229" };
    try std.testing.expectEqualStrings("dateafter format error", (try validate(std.testing.allocator, &cfg)).?);
    cfg = .{ .datebefore = "20250229" };
    try std.testing.expectEqualStrings("datebefore format error", (try validate(std.testing.allocator, &cfg)).?);
}

test "partial regex target matches and user precedence" {
    try std.testing.expectEqualStrings("123456789", parseTarget("xxx nicovideo.jp/user/1234567890123/video").?.id);
    try std.testing.expectEqualStrings("0001", parseTarget("http://www.nicovideo.jp/mylist/9?q=nicovideo.jp/user/0001").?.id);
    try std.testing.expectEqual(TargetType.mylist, parseTarget("nicovideo.jp/mylist/1234567890123").?.type);
    try std.testing.expectEqualStrings("123456789012", parseTarget("nicovideo.jp/mylist/1234567890123").?.id);
    try std.testing.expectEqualStrings("42", parseTarget("nicovideo.jp/user/no nicovideo.jp/user/42").?.id);
    for ([_][]const u8{ "123", "/user/123", "NICOVIDEO.jp/user/1", "nicovideo.jp/user/", "nicovideo.jp/user/-1" }) |input| try std.testing.expect(parseTarget(input) == null);
}

test "numeric sort normalization, overflow, and tie break" {
    var ids = [_][]const u8{ "sm10", "sm2", "sm0002", "sm1", "sm18446744073709551616", "sm18446744073709551615", "sm000" };
    std.mem.sort([]const u8, &ids, {}, videoIDLessThan);
    const expected = [_][]const u8{ "sm000", "sm1", "sm0002", "sm2", "sm10", "sm18446744073709551615", "sm18446744073709551616" };
    for (ids, expected) |got, want| try std.testing.expectEqualStrings(want, got);
}

test "JSON schema, target sorting and dedupe leave per-target items intact" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const targets = [_]TargetResult{
        .{ .order = 0, .target = .{ .type = .user, .id = "2" }, .items = &.{ "sm10", "sm1" } },
        .{ .order = 1, .target = .{ .type = .mylist, .id = "9" }, .items = &.{ "sm1", "sm2" }, .error_message = "oops" },
    };
    const n = try writeOutput(std.testing.allocator, &out.writer, .{ .json = true, .dedupe = true, .url = true }, .{ .total = 3, .valid = 2, .invalid = 1 }, &.{"bad<&>"}, &targets);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("{\"inputs\":{\"total\":3,\"valid\":2,\"invalid\":1},\"invalid\":[\"bad\\u003c\\u0026\\u003e\"],\"targets\":[{\"type\":\"mylist\",\"id\":\"9\",\"items\":[\"sm1\",\"sm2\"],\"error\":\"oops\"},{\"type\":\"user\",\"id\":\"2\",\"items\":[\"sm10\",\"sm1\"],\"error\":\"\"}],\"errors\":[\"oops\"],\"output_count\":3,\"items\":[\"sm1\",\"sm2\",\"sm10\"]}\n", out.written());
}

test "JSON no-sort follows input order and empty lists are arrays" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const targets = [_]TargetResult{
        .{ .order = 1, .target = .{ .type = .user, .id = "1" }, .items = &.{"sm1"} },
        .{ .order = 0, .target = .{ .type = .user, .id = "2" }, .items = &.{"sm2"} },
    };
    _ = try writeOutput(std.testing.allocator, &out.writer, .{ .json = true, .no_sort = true }, .{ .total = 2, .valid = 2 }, &.{}, &targets);
    try std.testing.expect(std.mem.endsWith(u8, out.written(), "\"items\":[\"sm2\",\"sm1\"]}\n"));
    out.clearRetainingCapacity();
    _ = try writeOutput(std.testing.allocator, &out.writer, .{ .json = true }, .{}, &.{}, &.{});
    try std.testing.expectEqualStrings("{\"inputs\":{\"total\":0,\"valid\":0,\"invalid\":0},\"invalid\":[],\"targets\":[],\"errors\":[],\"output_count\":0,\"items\":[]}\n", out.written());
}

test "JSON escaping replaces invalid UTF8 and quotes line separators" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeJsonString(&out.writer, "\"\\\n\r\t\x08\x0c\x01\xff\xe2\x80\xa8日本");
    try std.testing.expectEqualStrings("\"\\\"\\\\\\n\\r\\t\\b\\f\\u0001\\ufffd\\u2028日本\"", out.written());
}

test "line output URL formatting, sorting, dedupe and empty output" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const targets = [_]TargetResult{.{ .order = 0, .target = .{ .type = .user, .id = "1" }, .items = &.{ "sm2", "sm1", "sm2" } }};
    _ = try writeOutput(std.testing.allocator, &out.writer, .{ .url = true, .dedupe = true }, .{}, &.{}, &targets);
    try std.testing.expectEqualStrings(watch_url ++ "sm1\n" ++ watch_url ++ "sm2\n", out.written());
    out.clearRetainingCapacity();
    _ = try writeOutput(std.testing.allocator, &out.writer, .{}, .{}, &.{}, &.{});
    try std.testing.expectEqual(@as(usize, 0), out.written().len);
}

test "Unicode line trimming and empty input error" {
    try std.testing.expectEqualStrings("nicovideo.jp/user/1", trimSpace("\u{3000}\t nicovideo.jp/user/1\r\u{a0}"));
    try std.testing.expectEqualStrings("", trimSpace(" \r\n\u{2000}"));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const batch = try readInputs(arena.allocator(), std.testing.io, .{}, &.{});
    try std.testing.expectEqualStrings("no inputs provided", batch.error_message.?);
}

test "streamed input sources preserve order, unicode trim, CRLF and last line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "inputs", .data = " \r\n\u{3000}nicovideo.jp/user/2\u{a0}\r\ninvalid\nlast" });
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/inputs", .{tmp.sub_path});
    const batch = try readInputs(a, std.testing.io, .{ .input_file = path }, &.{"arg"});
    try std.testing.expect(batch.error_message == null);
    const expected = [_][]const u8{ "arg", "nicovideo.jp/user/2", "invalid", "last" };
    try std.testing.expectEqual(expected.len, batch.inputs.len);
    for (expected, batch.inputs) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "streaming callback observes partial lines before scanner limit error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const content = try a.alloc(u8, 2 + 1024 * 1024 + 1);
    @memcpy(content[0..2], "a\n");
    @memset(content[2..], 'x');
    content[content.len - 1] = '\n';
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "oversize", .data = content });
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/oversize", .{tmp.sub_path});
    const batch = try readInputs(a, std.testing.io, .{ .input_file = path }, &.{});
    try std.testing.expectEqualStrings("bufio.Scanner: token too long", batch.error_message.?);
    try std.testing.expectEqual(@as(usize, 1), batch.inputs.len);
    try std.testing.expectEqualStrings("a", batch.inputs[0]);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "fits", .data = content[3..] });
    const fits_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/fits", .{tmp.sub_path});
    const fits = try readInputs(a, std.testing.io, .{ .input_file = fits_path }, &.{});
    try std.testing.expect(fits.error_message == null);
    try std.testing.expectEqual(@as(usize, 1024 * 1024 - 1), fits.inputs[0].len);
}

test "canceled callback stops before opening later input source" {
    const Context = struct {
        count: usize = 0,
        fn callback(ptr: ?*anyopaque, _: []const u8) anyerror!void {
            const ctx: *@This() = @ptrCast(@alignCast(ptr.?));
            ctx.count += 1;
            return error.Canceled;
        }
    };
    var ctx: Context = .{};
    const msg = try streamInputs(std.testing.allocator, std.testing.io, .{ .input_file = "/does/not/exist" }, &.{ "first", "second" }, &ctx, Context.callback);
    try std.testing.expect(msg == null);
    try std.testing.expectEqual(@as(usize, 1), ctx.count);
}

test "integer syntax and precise parser diagnostics" {
    try std.testing.expectEqual(@as(i64, 8), try parseInteger("0_10"));
    try std.testing.expectEqual(@as(i64, -16), try parseInteger("-0x_10"));
    try std.testing.expectEqual(@as(i64, 1), try parseInteger("0b1"));
    for ([_][]const u8{ "1__2", "_1", "1_", "08", "0x_", "0__1" }) |value| try std.testing.expectError(error.InvalidCharacter, parseInteger(value));
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("invalid argument \"bad\" for \"-T, --concurrency-targets\" flag: strconv.ParseInt: parsing \"bad\": invalid syntax", (try parse(a, &.{"-Tbad"})).error_message.?);
    try std.testing.expectEqualStrings("invalid argument \"9223372036854775808\" for \"-c, --comment\" flag: strconv.ParseInt: parsing \"9223372036854775808\": value out of range", (try parse(a, &.{"--comment=9223372036854775808"})).error_message.?);
    try std.testing.expectEqualStrings("invalid argument \"1\" for \"--timeout\" flag: time: missing unit in duration \"1\"", (try parse(a, &.{"--timeout=1"})).error_message.?);
    try std.testing.expectEqualStrings("invalid argument \"1x\" for \"--timeout\" flag: time: unknown unit \"x\" in duration \"1x\"", (try parse(a, &.{"--timeout=1x"})).error_message.?);
    try std.testing.expectEqualStrings("bad flag syntax: ---foo", (try parse(a, &.{"---foo"})).error_message.?);
    try std.testing.expectEqualStrings("flag needs an argument: 'T' in -T", (try parse(a, &.{"-AT"})).error_message.?);
    try std.testing.expectEqualStrings("\xe0x", trimSpace("\xe0x "));
}

test "floating point parsing matches Go special values and range errors" {
    try std.testing.expect(std.math.isInf(try parseFloat("Infinity")));
    try std.testing.expect(std.math.isInf(try parseFloat("+INF")));
    try std.testing.expect(std.math.isNan(try parseFloat("nan")));
    try std.testing.expectError(error.InvalidCharacter, parseFloat("+NaN"));
    try std.testing.expectError(error.InvalidCharacter, parseFloat("1__2"));
    try std.testing.expectError(error.Overflow, parseFloat("1e9999"));
}
