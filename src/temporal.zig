const std = @import("std");

// Temporal parsing, comparison, and normalization helpers used by lexer/printer.

pub const TemporalError = error{Invalid};

pub const Date = struct {
    raw: []const u8,
    y: u16,
    m: u8,
    d: u8,
};

pub const Time = struct {
    raw: []const u8,
    h: u8,
    min: u8,
    s: u8 = 0,
    has_seconds: bool = false,
    has_fraction: bool = false,
    // Store fraction as nanoseconds (0..999_999_999) and original digits count for formatting.
    frac_nanos: u32 = 0,
    frac_digits: u8 = 0,
    // Timezone offset in minutes; null means local/no-zone.
    offset_minutes: ?i16 = null,
};

pub const DateTime = struct {
    raw: []const u8,
    date: Date,
    time: Time,
};

pub fn isDateStrict(s: []const u8) bool {
    if (s.len != 10) return false;
    inline for (0..10) |i| {
        switch (i) {
            4, 7 => if (s[i] != '-') return false,
            else => if (!(s[i] >= '0' and s[i] <= '9')) return false,
        }
    }
    // Validate month and day ranges
    const m = (s[5] - '0') * 10 + (s[6] - '0');
    const d = (s[8] - '0') * 10 + (s[9] - '0');
    if (m < 1 or m > 12) return false;
    if (d < 1 or d > 31) return false;
    return true;
}

fn isIsoDigits2(s: []const u8, idx: usize) bool {
    return idx + 1 < s.len and s[idx] >= '0' and s[idx] <= '9' and s[idx + 1] >= '0' and s[idx + 1] <= '9';
}

fn parseTimeCore(s: []const u8, start: usize) ?usize {
    var i = start;
    // HH:MM
    if (!(i + 4 < s.len and isIsoDigits2(s, i) and s[i + 2] == ':' and isIsoDigits2(s, i + 3))) return null;
    const hh = (s[i] - '0') * 10 + (s[i + 1] - '0');
    const mm = (s[i + 3] - '0') * 10 + (s[i + 4] - '0');
    if (hh > 23 or mm > 59) return null;
    i += 5;
    // Optional :SS
    if (i < s.len and s[i] == ':') {
        if (!(i + 3 <= s.len and isIsoDigits2(s, i + 1))) return null;
        const ss = (s[i + 1] - '0') * 10 + (s[i + 2] - '0');
        if (ss > 59) return null;
        i += 3;
        // Optional .fraction
        if (i < s.len and s[i] == '.') {
            i += 1;
            var digits: usize = 0;
            while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) digits += 1;
            if (digits == 0) return null;
        }
    }
    return i;
}

pub fn isTimeIso(s: []const u8, allow_zone: bool) bool {
    const core_end_opt = parseTimeCore(s, 0);
    if (core_end_opt == null) return false;
    var i = core_end_opt.?;
    if (i == s.len) return true;
    if (!allow_zone) return false;
    // Z or z
    if (i + 1 == s.len and (s[i] == 'Z' or s[i] == 'z')) return true;
    // [+|-]HH[:MM]
    if (s[i] == '+' or s[i] == '-') {
        i += 1;
        // Require HH
        if (!(i + 2 <= s.len and isIsoDigits2(s, i))) return false;
        i += 2;
        if (i == s.len) return true; // +HH form
        // Or +HH:MM form
        if (!(i + 3 == s.len and s[i] == ':' and isIsoDigits2(s, i + 1))) return false;
        return true;
    }
    return false;
}

pub fn isDateTimeIso(s: []const u8, allow_zone: bool) bool {
    if (s.len < 11) return false;
    var tpos: ?usize = null;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == 'T' or s[i] == 't') {
            tpos = i;
            break;
        }
    }
    if (tpos == null) return false;
    const d = s[0..tpos.?];
    if (!isDateStrict(d)) return false;
    const time = s[tpos.? + 1 ..];
    return isTimeIso(time, allow_zone);
}

// Parsing into structured types

fn isLeapYear(y: u16) bool {
    return (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0);
}

fn daysInMonth(y: u16, m: u8) u8 {
    return switch (m) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(y)) 29 else 28,
        else => 0,
    };
}

pub fn parseDate(raw: []const u8) TemporalError!Date {
    if (!isDateStrict(raw)) return TemporalError.Invalid;
    const y: u16 = @intCast((@as(u32, raw[0] - '0') * 1000) + (@as(u32, raw[1] - '0') * 100) + (@as(u32, raw[2] - '0') * 10) + (@as(u32, raw[3] - '0')));
    const m: u8 = @intCast((raw[5] - '0') * 10 + (raw[6] - '0'));
    const d: u8 = @intCast((raw[8] - '0') * 10 + (raw[9] - '0'));

    // Validate month range
    if (m < 1 or m > 12) return TemporalError.Invalid;

    // Validate day range for the given month
    if (d < 1 or d > daysInMonth(y, m)) return TemporalError.Invalid;

    return .{ .raw = raw, .y = y, .m = m, .d = d };
}

pub fn parseTime(raw: []const u8, allow_zone: bool) TemporalError!Time {
    if (!isTimeIso(raw, allow_zone)) return TemporalError.Invalid;
    var i: usize = 0;
    const h: u8 = @intCast((raw[i] - '0') * 10 + (raw[i + 1] - '0'));
    i += 2; // HH
    i += 1; // ':'
    const mi: u8 = @intCast((raw[i] - '0') * 10 + (raw[i + 1] - '0'));
    i += 2; // MM
    var s: u8 = 0;
    var has_seconds = false;
    var has_fraction = false;
    var frac_digits: u8 = 0;
    var frac_nanos: u32 = 0;
    // seconds
    if (i < raw.len and raw[i] == ':') {
        has_seconds = true;
        i += 1;
        s = @intCast((raw[i] - '0') * 10 + (raw[i + 1] - '0'));
        i += 2;
        if (i < raw.len and raw[i] == '.') {
            has_fraction = true;
            i += 1;
            var pow10: u32 = 100_000_000; // scale to nanos (max 9 digits)
            while (i < raw.len and raw[i] >= '0' and raw[i] <= '9') : (i += 1) {
                if (frac_digits < 9) {
                    frac_nanos += @as(u32, @intCast(raw[i] - '0')) * pow10;
                    if (pow10 > 1) {
                        pow10 /= 10;
                    } else {
                        pow10 = 1;
                    }
                }
                frac_digits += 1;
            }
            if (frac_digits == 0) return TemporalError.Invalid;
            // Cap at max meaningful precision to prevent u8 overflow
            if (frac_digits > 9) frac_digits = 9;
        }
    }
    var offset: ?i16 = null;
    if (i < raw.len) {
        const c = raw[i];
        if (c == 'Z' or c == 'z') {
            if (!allow_zone) return TemporalError.Invalid;
            offset = 0;
            i += 1;
        } else if (c == '+' or c == '-') {
            if (!allow_zone) return TemporalError.Invalid;
            const sign: i16 = if (c == '+') 1 else -1;
            i += 1;
            // HH
            const oh: i16 = @intCast((raw[i] - '0') * 10 + (raw[i + 1] - '0'));
            i += 2;
            var om: i16 = 0;
            if (i == raw.len) {
                // +HH
                om = 0;
            } else {
                if (!(i + 2 < raw.len and raw[i] == ':' and raw[i + 1] >= '0' and raw[i + 1] <= '9' and raw[i + 2] >= '0' and raw[i + 2] <= '9'))
                    return TemporalError.Invalid;
                om = @intCast((raw[i + 1] - '0') * 10 + (raw[i + 2] - '0'));
                i += 3;
            }
            offset = sign * (oh * 60 + om);
        }
    }
    if (i != raw.len) return TemporalError.Invalid;
    return .{
        .raw = raw,
        .h = h,
        .min = mi,
        .s = s,
        .has_seconds = has_seconds,
        .has_fraction = has_fraction,
        .frac_nanos = frac_nanos,
        .frac_digits = frac_digits,
        .offset_minutes = offset,
    };
}

pub fn parseDateTime(raw: []const u8, allow_zone: bool) TemporalError!DateTime {
    if (!isDateTimeIso(raw, allow_zone)) return TemporalError.Invalid;
    // locate T/t
    var tpos: usize = 0;
    while (tpos < raw.len and !(raw[tpos] == 'T' or raw[tpos] == 't')) : (tpos += 1) {}
    if (tpos == raw.len) return TemporalError.Invalid;
    const d = try parseDate(raw[0..tpos]);
    const tm = try parseTime(raw[tpos + 1 ..], allow_zone);
    return .{ .raw = raw, .date = d, .time = tm };
}

// Parse timezone offset strings like "Z", "+HH", "+HH:MM", "-HH:MM" into minutes.
// Returns minutes east of UTC (e.g., +05:30 => +330). Accepts upper/lowercase 'Z'.
pub fn parseOffsetMinutes(s: []const u8) TemporalError!i16 {
    if (s.len == 1 and (s[0] == 'Z' or s[0] == 'z')) return 0;
    if (s.len < 3) return TemporalError.Invalid;
    if (!(s[0] == '+' or s[0] == '-')) return TemporalError.Invalid;
    const sign: i16 = if (s[0] == '+') 1 else -1;
    // +HH or +HH:MM
    if (!(s.len >= 3 and s[1] >= '0' and s[1] <= '9' and s[2] >= '0' and s[2] <= '9'))
        return TemporalError.Invalid;
    const oh: i16 = @intCast((s[1] - '0') * 10 + (s[2] - '0'));
    if (s.len == 3) return sign * (oh * 60);
    if (!(s.len == 6 and s[3] == ':' and s[4] >= '0' and s[4] <= '9' and s[5] >= '0' and s[5] <= '9'))
        return TemporalError.Invalid;
    const om: i16 = @intCast((s[4] - '0') * 10 + (s[5] - '0'));
    return sign * (oh * 60 + om);
}

// Formatting / normalization
pub const NormalizeOptions = struct { clamp_frac_digits: ?u8 = null };

pub fn formatDate(w: anytype, d: Date) !void {
    try w.print("{d:0>4}-{d:0>2}-{d:0>2}", .{ d.y, d.m, d.d });
}

pub fn formatTime(w: anytype, t: Time, opts: NormalizeOptions) !void {
    try w.print("{d:0>2}:{d:0>2}", .{ t.h, t.min });
    if (t.has_seconds) {
        try w.print(":{d:0>2}", .{t.s});
        if (t.has_fraction and t.frac_digits > 0) {
            var out_digits: u8 = t.frac_digits;
            if (opts.clamp_frac_digits) |cl| {
                if (out_digits > cl) out_digits = cl;
            }
            // Render from frac_nanos but only up to out_digits
            const ns = t.frac_nanos;
            // Build a 9-digit zero-padded string then cut to out_digits
            var buf: [9]u8 = undefined;
            var idx: usize = 9;
            var tmp = ns;
            var j: usize = 0;
            while (j < 9) : (j += 1) {
                const dch: u8 = @intCast(tmp % 10);
                tmp /= 10;
                idx -= 1;
                buf[idx] = '0' + dch;
            }
            try w.writeByte('.');
            try w.writeAll(buf[0..out_digits]);
        }
    }
    if (t.offset_minutes) |off| {
        if (off == 0) {
            try w.writeByte('Z');
        } else {
            const sign: u8 = if (off < 0) '-' else '+';
            const aoff: i16 = if (off < 0) -off else off;
            const oh: u8 = @intCast(@divTrunc(aoff, 60));
            const om: u8 = @intCast(aoff - @as(i16, oh) * 60);
            try w.writeByte(sign);
            // two-digit hours
            try w.writeByte('0' + @as(u8, oh / 10));
            try w.writeByte('0' + @as(u8, oh % 10));
            try w.writeByte(':');
            // two-digit minutes
            try w.writeByte('0' + @as(u8, om / 10));
            try w.writeByte('0' + @as(u8, om % 10));
        }
    }
}

pub fn formatDateTime(w: anytype, dt: DateTime, opts: NormalizeOptions) !void {
    try formatDate(w, dt.date);
    try w.writeByte('T');
    try formatTime(w, dt.time, opts);
}

// Comparison utilities
fn cmp3(a: anytype, b: anytype) i8 {
    if (a < b) return -1;
    if (a > b) return 1;
    return 0;
}

pub fn compareDateParsed(a: Date, b: Date) i8 {
    const c1 = cmp3(a.y, b.y);
    if (c1 != 0) return c1;
    const c2 = cmp3(a.m, b.m);
    if (c2 != 0) return c2;
    return cmp3(a.d, b.d);
}

fn timeToNanosLocal(t: Time) u64 {
    const mins: u64 = @as(u64, t.h) * 60 + t.min;
    const secs: u64 = mins * 60 + t.s;
    return secs * 1_000_000_000 + t.frac_nanos;
}

pub fn compareTimeParsed(a: Time, b: Time) TemporalError!i8 {
    const a_has = a.offset_minutes != null;
    const b_has = b.offset_minutes != null;
    if (a_has != b_has) return TemporalError.Invalid;
    if (!a_has and !b_has) {
        return cmp3(timeToNanosLocal(a), timeToNanosLocal(b));
    }
    // Normalize to UTC by subtracting offset
    const a_ns = timeToNanosLocal(a);
    const b_ns = timeToNanosLocal(b);
    const a_off_ns: i64 = @as(i64, a.offset_minutes.?) * 60 * 1_000_000_000;
    const b_off_ns: i64 = @as(i64, b.offset_minutes.?) * 60 * 1_000_000_000;
    const a_utc: i128 = @as(i128, a_ns) - a_off_ns;
    const b_utc: i128 = @as(i128, b_ns) - b_off_ns;
    return cmp3(a_utc, b_utc);
}

fn daysSinceEpoch(y_: i64, m_: i64, d_: i64) i64 {
    // Proleptic Gregorian to days since 1970-01-01 (Hinnant’s algorithm derivation)
    var y = y_;
    const m = m_;
    const d = d_;
    if (m <= 2) {
        y -= 1;
    }
    const era = @divTrunc(y, 400);
    const yoe = y - era * 400; // [0, 399]
    const m_adj: i64 = if (m > 2) m - 3 else m + 9;
    const doy = @divTrunc(153 * (m_adj) + 2, 5) + d - 1; // [0, 365]
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy; // [0, 146096]
    return era * 146097 + doe - 719468; // 1970-01-01 offset
}

pub fn compareDateTimeParsed(a: DateTime, b: DateTime) TemporalError!i8 {
    const a_has = a.time.offset_minutes != null;
    const b_has = b.time.offset_minutes != null;
    if (a_has != b_has) return TemporalError.Invalid;
    if (!a_has and !b_has) {
        // Pure local comparison
        const cd = compareDateParsed(a.date, b.date);
        if (cd != 0) return cd;
        return cmp3(timeToNanosLocal(a.time), timeToNanosLocal(b.time));
    }
    // Compare as UTC instants
    const adays = daysSinceEpoch(a.date.y, a.date.m, a.date.d);
    const bdays = daysSinceEpoch(b.date.y, b.date.m, b.date.d);
    const ans = timeToNanosLocal(a.time);
    const bns = timeToNanosLocal(b.time);
    const a_off_ns: i64 = @as(i64, a.time.offset_minutes.?) * 60 * 1_000_000_000;
    const b_off_ns: i64 = @as(i64, b.time.offset_minutes.?) * 60 * 1_000_000_000;
    const a_utc_ns: i128 = @as(i128, adays) * 86_400_000_000_000 + @as(i128, ans) - a_off_ns;
    const b_utc_ns: i128 = @as(i128, bdays) * 86_400_000_000_000 + @as(i128, bns) - b_off_ns;
    return cmp3(a_utc_ns, b_utc_ns);
}

// Coercions
pub fn coerceDateToDateTime(d: Date, utc: bool) DateTime {
    const t = Time{ .raw = "", .h = 0, .min = 0, .s = 0, .has_seconds = false, .has_fraction = false, .frac_nanos = 0, .frac_digits = 0, .offset_minutes = if (utc) 0 else null };
    return .{ .raw = d.raw, .date = d, .time = t };
}

pub fn attachSessionOffset(ldt: DateTime, session_offset_minutes: i16) DateTime {
    var t = ldt.time;
    t.offset_minutes = session_offset_minutes;
    return .{ .raw = ldt.raw, .date = ldt.date, .time = t };
}

// Basic self-tests for helpers
test "temporal helpers validate date/time/datetime" {
    try std.testing.expect(isDateStrict("2024-08-12"));
    try std.testing.expect(!isDateStrict("2024/08/12"));
    try std.testing.expect(isTimeIso("10:15", true));
    try std.testing.expect(isTimeIso("10:15:30.123+02:00", true));
    try std.testing.expect(!isTimeIso("25:00", true));
    try std.testing.expect(isDateTimeIso("2024-08-12T10:15Z", true));
    try std.testing.expect(!isDateTimeIso("2024-08-12 10:15", true));
}

test "temporal parse + compare + normalize" {
    const d1 = try parseDate("2024-08-12");
    const d2 = try parseDate("2024-08-13");
    try std.testing.expect(compareDateParsed(d1, d2) < 0);
    const t1 = try parseTime("10:15:30.123Z", true);
    const t2 = try parseTime("12:15:30.123+02:00", true);
    try std.testing.expect((try compareTimeParsed(t1, t2)) == 0);
    const dt1 = try parseDateTime("2024-08-12T10:15Z", true);
    const dt2 = try parseDateTime("2024-08-12T11:15+01:00", true);
    try std.testing.expect((try compareDateTimeParsed(dt1, dt2)) == 0);
    // Normalization output
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try formatDateTime(&aw.writer, dt1, .{});
    try std.testing.expect(std.mem.eql(u8, aw.written(), "2024-08-12T10:15Z"));
}

test "formatDateTime normalizes +HH to +HH:00" {
    const dt = try parseDateTime("2024-01-02T03:04+05", true);
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try formatDateTime(&aw.writer, dt, .{});
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "+05:00") != null);
}

test "formatDateTime preserves -HH:MM" {
    const dt = try parseDateTime("2024-01-02T03:04-05:30", true);
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try formatDateTime(&aw.writer, dt, .{});
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "-05:30") != null);
}

test "parseOffsetMinutes handles Z, +HH, and -HH:MM" {
    try std.testing.expect((try parseOffsetMinutes("Z")) == 0);
    try std.testing.expect((try parseOffsetMinutes("+05")) == 300);
    try std.testing.expect((try parseOffsetMinutes("-05:30")) == -330);
}

test "parseTime caps frac_digits at 9 to prevent u8 overflow" {
    // 15 fractional digits -- well beyond 9 but should not overflow u8
    const t1 = try parseTime("10:15:30.123456789012345", false);
    try std.testing.expect(t1.has_fraction);
    try std.testing.expectEqual(@as(u8, 9), t1.frac_digits);
    // The nanos value should reflect the first 9 digits only
    try std.testing.expectEqual(@as(u32, 123456789), t1.frac_nanos);
}

test "parseTime with exactly 9 frac_digits works normally" {
    const t1 = try parseTime("10:15:30.123456789", false);
    try std.testing.expect(t1.has_fraction);
    try std.testing.expectEqual(@as(u8, 9), t1.frac_digits);
    try std.testing.expectEqual(@as(u32, 123456789), t1.frac_nanos);
}

test "parseTime with fewer than 9 frac_digits preserves count" {
    const t1 = try parseTime("10:15:30.123", false);
    try std.testing.expect(t1.has_fraction);
    try std.testing.expectEqual(@as(u8, 3), t1.frac_digits);
}
