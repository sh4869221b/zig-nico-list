//! Pure Gregorian date and RFC3339 timestamp parsing shared by CLI and API code.
//! Preserve the accepted syntax of Go time parsing, including its RFC3339 quirks.
const std = @import("std");

pub fn parseDate(text: []const u8) error{InvalidDate}!i64 {
    if (text.len != 8) return error.InvalidDate;
    for (text) |c| if (!std.ascii.isDigit(c)) return error.InvalidDate;
    const y = std.fmt.parseInt(i64, text[0..4], 10) catch return error.InvalidDate;
    const m = std.fmt.parseInt(i64, text[4..6], 10) catch return error.InvalidDate;
    const d = std.fmt.parseInt(i64, text[6..8], 10) catch return error.InvalidDate;
    return dateSeconds(y, m, d);
}

fn dateSeconds(year: i64, month: i64, day: i64) error{InvalidDate}!i64 {
    if (month < 1 or month > 12 or day < 1) return error.InvalidDate;
    const leap = @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
    const month_days = [_]i64{ 31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (day > month_days[@intCast(month - 1)]) return error.InvalidDate;
    // Howard Hinnant's proleptic-Gregorian civil-to-days transform.
    const y = year - @as(i64, if (month <= 2) 1 else 0);
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = month + @as(i64, if (month > 2) -3 else 9);
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return (era * 146097 + doe - 719468) * 86400;
}

/// Decode an RFC3339 time, preserving timezone offsets. Fractional seconds are
/// discarded toward the start of their second, which is exact for day filters.
pub fn parseTimestamp(text: []const u8) error{InvalidTimestamp}!i64 {
    if (text.len < 19 or text[4] != '-' or text[7] != '-' or text[10] != 'T') return error.InvalidTimestamp;
    const hour_end: usize = if (text[12] == ':') 12 else 13;
    if (text[hour_end] != ':' or text[hour_end + 3] != ':') return error.InvalidTimestamp;
    const y = decimal(text[0..4]) catch return error.InvalidTimestamp;
    const m = decimal(text[5..7]) catch return error.InvalidTimestamp;
    const d = decimal(text[8..10]) catch return error.InvalidTimestamp;
    const hour = decimal(text[11..hour_end]) catch return error.InvalidTimestamp;
    const minute = decimal(text[hour_end + 1 .. hour_end + 3]) catch return error.InvalidTimestamp;
    const second = decimal(text[hour_end + 4 .. hour_end + 6]) catch return error.InvalidTimestamp;
    if (hour > 23 or minute > 59 or second > 59) return error.InvalidTimestamp;
    const day_start = dateSeconds(y, m, d) catch return error.InvalidTimestamp;
    var i: usize = hour_end + 6;
    if (i == text.len) return error.InvalidTimestamp;
    if (text[i] == '.' or text[i] == ',') {
        i += 1;
        const start = i;
        while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {}
        if (i == start or i == text.len) return error.InvalidTimestamp;
    }
    var offset: i64 = 0;
    if (text[i] == 'Z') {
        if (i + 1 != text.len) return error.InvalidTimestamp;
    } else {
        if (text[i] != '+' and text[i] != '-') return error.InvalidTimestamp;
        if (i + 6 != text.len or text[i + 3] != ':') return error.InvalidTimestamp;
        const oh = decimal(text[i + 1 .. i + 3]) catch return error.InvalidTimestamp;
        const om = decimal(text[i + 4 .. i + 6]) catch return error.InvalidTimestamp;
        // Go's time.Parse RFC3339 implementation accepts offset 24:00 / :60.
        if (oh > 24 or om > 60) return error.InvalidTimestamp;
        offset = (oh * 60 + om) * 60;
        if (text[i] == '-') offset = -offset;
    }
    return day_start + hour * 3600 + minute * 60 + second - offset;
}

fn decimal(text: []const u8) !i64 {
    for (text) |c| if (!std.ascii.isDigit(c)) return error.InvalidCharacter;
    return std.fmt.parseInt(i64, text, 10);
}

test "UTC date and RFC3339 offset parsing" {
    try std.testing.expectEqual(@as(i64, 0), try parseDate("19700101"));
    try std.testing.expectEqual(@as(i64, -86400), try parseDate("19691231"));
    try std.testing.expectEqual(@as(i64, -30_610_224_000), try parseDate("10000101"));
    try std.testing.expectEqual(@as(i64, 253_402_214_400), try parseDate("99991231"));
    _ = try parseDate("00000229");
    _ = try parseDate("20000229");
    for ([_][]const u8{ "19000229", "20250229", "20241301", "20240100", "2024-01-01", "202401011" }) |text| try std.testing.expectError(error.InvalidDate, parseDate(text));
    try std.testing.expectEqual(@as(i64, 0), try parseTimestamp("1970-01-01T09:00:00+09:00"));
    try std.testing.expectEqual(@as(i64, 0), try parseTimestamp("1970-01-01T9:00:00+09:00"));
    try std.testing.expectEqual(@as(i64, -1), try parseTimestamp("1969-12-31T23:59:59.999Z"));
    try std.testing.expectEqual(@as(i64, 1), try parseTimestamp("1969-12-31T19:00:01-05:00"));
    try std.testing.expectError(error.InvalidTimestamp, parseTimestamp("2024-02-30T00:00:00Z"));
    try std.testing.expectError(error.InvalidTimestamp, parseTimestamp("2024-01-01T24:00:00Z"));
}

test "RFC3339 retains Go fractional and timezone offset quirks" {
    try std.testing.expectEqual(@as(i64, 0), try parseTimestamp("1970-01-01T0:00:00Z"));
    try std.testing.expectEqual(@as(i64, -1), try parseTimestamp("1969-12-31T23:59:59,1234567890123Z"));
    try std.testing.expectEqual(@as(i64, 0), try parseTimestamp("1970-01-02T00:00:00+24:00"));
    try std.testing.expectEqual(@as(i64, 0), try parseTimestamp("1970-01-01T01:00:00+00:60"));
    try std.testing.expectEqual(@as(i64, -90_000), try parseTimestamp("1970-01-01T00:00:00+24:60"));
    try std.testing.expectEqual(@as(i64, 90_000), try parseTimestamp("1970-01-01T00:00:00-24:60"));
}

test "dates and timestamps reject malformed fields without normalization" {
    for ([_][]const u8{ "", "2024010", "2024a101", "2024+101", "20240431", "20240001" }) |text| {
        try std.testing.expectError(error.InvalidDate, parseDate(text));
    }
    for ([_][]const u8{
        "",
        "1970-01-01T00:00:00",
        "1970-01-01t00:00:00Z",
        "1970-01-01T00:00:00z",
        "1970-01-01T00:60:00Z",
        "1970-01-01T00:00:60Z",
        "1970-01-01T00:00:00.Z",
        "1970-01-01T00:00:00,",
        "1970-01-01T00:00:00.1",
        "1970-01-01T00:00:00+25:00",
        "1970-01-01T00:00:00+00:61",
        "1970-01-01T00:00:00+0a:00",
        "1970-01-01T00:00:00+0000",
        "1970-01-01T00:00:00Zextra",
    }) |text| {
        try std.testing.expectError(error.InvalidTimestamp, parseTimestamp(text));
    }
}
