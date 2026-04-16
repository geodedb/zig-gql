// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Incremental scale benchmark for the gql front-end library.
//!
//! Runs the same battery of operations at progressively larger query workloads
//! and emits structured JSON to stdout for tracking over time.
//! A human-readable summary table is printed to stderr via std.debug.print.
//!
//! Scale tiers increase query count and complexity rather than data size
//! (since this is a parser, not a storage engine).
//!
//! Run via: zig build scale-bench
//! Save:   zig build scale-bench 2>/dev/null > results.json

const std = @import("std");
const gql = @import("gql");
const builtin = @import("builtin");

const print = std.debug.print;

// Zig 0.16 compat: Timer was removed; use monotonic clock directly.
const Timer = struct {
    start_ns: i96,

    fn start() error{}!Timer {
        return .{ .start_ns = nanoTimestamp() };
    }

    fn read(self: *Timer) u64 {
        const diff = nanoTimestamp() - self.start_ns;
        return if (diff > 0) @intCast(diff) else 0;
    }

    fn nanoTimestamp() i96 {
        const io = std.Io.Threaded.global_single_threaded.io();
        return std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds;
    }
};

// ---------------------------------------------------------------------------
// Query generators
// ---------------------------------------------------------------------------

/// Generate N simple MATCH-RETURN queries with varying labels.
fn generateSimpleQueries(allocator: std.mem.Allocator, count: usize) ![][]const u8 {
    const labels = [_][]const u8{
        "Person", "Company", "City",        "Product", "Order",
        "User",   "Device",  "Application", "Group",   "Site",
    };
    var list = try allocator.alloc([]const u8, count);
    for (0..count) |i| {
        const label = labels[i % labels.len];
        list[i] = try std.fmt.allocPrint(allocator, "MATCH (n:{s}) WHERE n.id = {d} RETURN n.name", .{ label, i });
    }
    return list;
}

/// Generate N relationship queries with varying patterns.
fn generateRelQueries(allocator: std.mem.Allocator, count: usize) ![][]const u8 {
    const templates = [_]struct { prefix: []const u8, suffix: []const u8 }{
        .{ .prefix = "MATCH (a:Person)-[r:KNOWS]->(b:Person) WHERE a.age > ", .suffix = " RETURN a.name, b.name" },
        .{ .prefix = "MATCH (a:User)-[r:LOGGED_INTO]->(b:Device) WHERE b.trust > ", .suffix = " RETURN a.name, b.id" },
        .{ .prefix = "MATCH (a:Person)-[r1:WORKS_AT]->(b:Company)-[r2:LOCATED_IN]->(c:City) WHERE a.age > ", .suffix = " RETURN a.name, c.name" },
        .{ .prefix = "MATCH (a:User)-[r:MEMBER_OF]->(g:Group) WHERE g.size > ", .suffix = " RETURN a.name, g.name ORDER BY a.name LIMIT 10" },
        .{ .prefix = "MATCH (d:Device)-[r:SIGNED_IN_FROM]->(ip:IPAddress) WHERE ip.risk > ", .suffix = " RETURN d.id, ip.address" },
    };
    var list = try allocator.alloc([]const u8, count);
    for (0..count) |i| {
        const t = templates[i % templates.len];
        list[i] = try std.fmt.allocPrint(allocator, "{s}{d}{s}", .{ t.prefix, i % 100, t.suffix });
    }
    return list;
}

/// Generate N complex multi-statement queries.
fn generateComplexQueries(allocator: std.mem.Allocator, count: usize) ![][]const u8 {
    const templates = [_]struct { prefix: []const u8, suffix: []const u8 }{
        .{ .prefix = "MATCH (a:Person)-[r:KNOWS]->(b:Person)-[r2:LIVES_IN]->(c:City) WHERE a.age > ", .suffix = " AND b.name STARTS WITH 'A' AND c.population > 1000000 RETURN a.name, b.name, c.name ORDER BY a.name LIMIT 100" },
        .{ .prefix = "MATCH (u:User)-[r1:LOGGED_INTO]->(d:Device)-[r2:SIGNED_IN_FROM]->(ip:IPAddress) WHERE u.risk > ", .suffix = " AND d.compliant = TRUE RETURN u.name, d.id, ip.address ORDER BY u.risk DESC LIMIT 50" },
        .{ .prefix = "MATCH (p:Person) WHERE p.age > ", .suffix = " AND p.city <> 'Unknown' AND p.active = TRUE RETURN p.name, p.age, p.city ORDER BY p.age DESC LIMIT 25 OFFSET 10" },
    };
    var list = try allocator.alloc([]const u8, count);
    for (0..count) |i| {
        const t = templates[i % templates.len];
        list[i] = try std.fmt.allocPrint(allocator, "{s}{d}{s}", .{ t.prefix, i % 80, t.suffix });
    }
    return list;
}

fn freeQueries(allocator: std.mem.Allocator, qs: [][]const u8) void {
    for (qs) |q| allocator.free(q);
    allocator.free(qs);
}

// ---------------------------------------------------------------------------
// Scale tier definitions
// ---------------------------------------------------------------------------

const Tier = struct {
    name: []const u8,
    simple_count: usize,
    rel_count: usize,
    complex_count: usize,
    print_iterations: usize,
    temporal_iterations: usize,
    keyword_iterations: usize,
};

const tiers = [_]Tier{
    .{ .name = "100", .simple_count = 100, .rel_count = 50, .complex_count = 20, .print_iterations = 5_000, .temporal_iterations = 50_000, .keyword_iterations = 100_000 },
    .{ .name = "500", .simple_count = 500, .rel_count = 250, .complex_count = 100, .print_iterations = 2_000, .temporal_iterations = 20_000, .keyword_iterations = 50_000 },
    .{ .name = "1K", .simple_count = 1_000, .rel_count = 500, .complex_count = 200, .print_iterations = 1_000, .temporal_iterations = 10_000, .keyword_iterations = 25_000 },
    .{ .name = "5K", .simple_count = 5_000, .rel_count = 2_500, .complex_count = 1_000, .print_iterations = 500, .temporal_iterations = 5_000, .keyword_iterations = 10_000 },
    .{ .name = "10K", .simple_count = 10_000, .rel_count = 5_000, .complex_count = 2_000, .print_iterations = 200, .temporal_iterations = 2_000, .keyword_iterations = 5_000 },
    .{ .name = "25K", .simple_count = 25_000, .rel_count = 12_500, .complex_count = 5_000, .print_iterations = 100, .temporal_iterations = 1_000, .keyword_iterations = 2_000 },
};

// ---------------------------------------------------------------------------
// Per-tier results
// ---------------------------------------------------------------------------

const TierResult = struct {
    name: []const u8,
    query_count: u64,
    lex_ops_sec: f64,
    parse_simple_ns: f64,
    parse_rel_ns: f64,
    parse_complex_ns: f64,
    print_human_ns: f64,
    print_json_ns: f64,
    temporal_ns: f64,
    keyword_ns: f64,
    skipped: bool = false,
    skip_reason: ?[]const u8 = null,
};

/// Maximum wall-clock time for a single tier (5 minutes in ns).
const TIER_TIMEOUT_NS: u64 = 5 * 60 * std.time.ns_per_s;

fn skipResult(tier: Tier, reason: []const u8) TierResult {
    return TierResult{
        .name = tier.name,
        .query_count = tier.simple_count + tier.rel_count + tier.complex_count,
        .lex_ops_sec = 0,
        .parse_simple_ns = 0,
        .parse_rel_ns = 0,
        .parse_complex_ns = 0,
        .print_human_ns = 0,
        .print_json_ns = 0,
        .temporal_ns = 0,
        .keyword_ns = 0,
        .skipped = true,
        .skip_reason = reason,
    };
}

fn checkTimeout(tier_start: *Timer, tier: Tier) ?TierResult {
    const elapsed = tier_start.read();
    if (elapsed > TIER_TIMEOUT_NS) {
        return skipResult(tier, "timeout (>5min)");
    }
    return null;
}

// ---------------------------------------------------------------------------
// Benchmark functions
// ---------------------------------------------------------------------------

fn benchLex(qs: [][]const u8) struct { ops_sec: f64 } {
    var timer = Timer.start() catch return .{ .ops_sec = 0 };
    for (qs) |q| {
        var lx = gql.Lexer{ .src = q };
        while (true) {
            const tok = lx.next();
            if (tok.kind == .eof) break;
        }
    }
    const elapsed = timer.read();
    const count_f: f64 = @floatFromInt(qs.len);
    const ns_f: f64 = @floatFromInt(elapsed);
    return .{ .ops_sec = if (ns_f > 0) count_f / (ns_f / 1_000_000_000.0) else 0 };
}

fn benchParse(qs: [][]const u8) f64 {
    var total_ns: u64 = 0;
    for (qs) |q| {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var lx = gql.Lexer{ .src = q };
        var parser = gql.Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
        var timer = Timer.start() catch continue;
        _ = parser.parseProgram() catch {};
        total_ns += timer.read();
    }
    if (qs.len == 0) return 0;
    const ns_f: f64 = @floatFromInt(total_ns);
    const count_f: f64 = @floatFromInt(qs.len);
    return ns_f / count_f;
}

fn benchPrintHuman(iterations: usize, program: gql.ast.Program) f64 {
    var timer = Timer.start() catch return 0;
    for (0..iterations) |_| {
        var buf: [4096]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        gql.print.printProgramHuman(&w, program) catch {};
    }
    const elapsed = timer.read();
    const ns_f: f64 = @floatFromInt(elapsed);
    const count_f: f64 = @floatFromInt(iterations);
    return ns_f / count_f;
}

fn benchPrintJson(allocator: std.mem.Allocator, iterations: usize, program: gql.ast.Program) f64 {
    var timer = Timer.start() catch return 0;
    for (0..iterations) |_| {
        var buf: [16384]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        gql.print.printProgramJsonWith(allocator, &w, program, .{}) catch {};
    }
    const elapsed = timer.read();
    const ns_f: f64 = @floatFromInt(elapsed);
    const count_f: f64 = @floatFromInt(iterations);
    return ns_f / count_f;
}

fn benchTemporal(iterations: usize) f64 {
    const dates = [_][]const u8{ "2024-01-15", "2025-12-31", "2000-06-15" };
    const times = [_][]const u8{ "14:30:00", "23:59:59", "00:00:00.123456" };
    const datetimes = [_][]const u8{ "2024-01-15T14:30:00Z", "2025-12-31T23:59:59" };

    var timer = Timer.start() catch return 0;
    const per_iter = dates.len + times.len + datetimes.len;
    for (0..iterations) |_| {
        for (dates) |d| _ = gql.temporal.parseDate(d) catch {};
        for (times) |t| _ = gql.temporal.parseTime(t, true) catch {};
        for (datetimes) |dt| _ = gql.temporal.parseDateTime(dt, true) catch {};
    }
    const elapsed = timer.read();
    const total: f64 = @floatFromInt(iterations * per_iter);
    const ns_f: f64 = @floatFromInt(elapsed);
    return ns_f / total;
}

fn benchKeyword(iterations: usize) f64 {
    const keywords = [_][]const u8{
        "MATCH",       "RETURN",  "WHERE",  "CREATE", "DELETE", "SET",
        "MERGE",       "ORDER",   "LIMIT",  "AND",    "OR",     "NOT",
        "notAKeyword", "alsoNot", "SELECT", "FROM",
    };
    var timer = Timer.start() catch return 0;
    for (0..iterations) |_| {
        for (keywords) |kw| _ = gql.token.keywordKind(kw);
    }
    const elapsed = timer.read();
    const total: f64 = @floatFromInt(iterations * keywords.len);
    const ns_f: f64 = @floatFromInt(elapsed);
    return ns_f / total;
}

// ---------------------------------------------------------------------------
// Run a single tier
// ---------------------------------------------------------------------------

fn runTier(allocator: std.mem.Allocator, tier: Tier) TierResult {
    var tier_start = Timer.start() catch return skipResult(tier, "timer init failed");

    // Generate queries for this tier
    const simple_qs = generateSimpleQueries(allocator, tier.simple_count) catch return skipResult(tier, "query gen failed");
    defer freeQueries(allocator, simple_qs);

    const rel_qs = generateRelQueries(allocator, tier.rel_count) catch return skipResult(tier, "query gen failed");
    defer freeQueries(allocator, rel_qs);

    const complex_qs = generateComplexQueries(allocator, tier.complex_count) catch return skipResult(tier, "query gen failed");
    defer freeQueries(allocator, complex_qs);

    // Combine all queries for lex benchmark
    const all_count = simple_qs.len + rel_qs.len + complex_qs.len;
    var all_qs = allocator.alloc([]const u8, all_count) catch return skipResult(tier, "alloc failed");
    defer allocator.free(all_qs);
    @memcpy(all_qs[0..simple_qs.len], simple_qs);
    @memcpy(all_qs[simple_qs.len..][0..rel_qs.len], rel_qs);
    @memcpy(all_qs[simple_qs.len + rel_qs.len ..][0..complex_qs.len], complex_qs);

    // --- Lex all ---
    const lex_result = benchLex(all_qs);
    if (checkTimeout(&tier_start, tier)) |r| return r;

    // --- Parse simple ---
    const parse_simple_ns = benchParse(simple_qs);
    if (checkTimeout(&tier_start, tier)) |r| return r;

    // --- Parse relationship ---
    const parse_rel_ns = benchParse(rel_qs);
    if (checkTimeout(&tier_start, tier)) |r| return r;

    // --- Parse complex ---
    const parse_complex_ns = benchParse(complex_qs);
    if (checkTimeout(&tier_start, tier)) |r| return r;

    // --- Print (use first complex query as representative AST) ---
    var print_human_ns: f64 = 0;
    var print_json_ns: f64 = 0;
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        var lx = gql.Lexer{ .src = complex_qs[0] };
        var parser = gql.Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
        if (parser.parseProgram()) |prog| {
            print_human_ns = benchPrintHuman(tier.print_iterations, prog);
            if (checkTimeout(&tier_start, tier)) |r| return r;
            print_json_ns = benchPrintJson(allocator, tier.print_iterations, prog);
        } else |_| {}
    }
    if (checkTimeout(&tier_start, tier)) |r| return r;

    // --- Temporal ---
    const temporal_ns = benchTemporal(tier.temporal_iterations);
    if (checkTimeout(&tier_start, tier)) |r| return r;

    // --- Keyword lookup ---
    const keyword_ns = benchKeyword(tier.keyword_iterations);

    return TierResult{
        .name = tier.name,
        .query_count = all_count,
        .lex_ops_sec = lex_result.ops_sec,
        .parse_simple_ns = parse_simple_ns,
        .parse_rel_ns = parse_rel_ns,
        .parse_complex_ns = parse_complex_ns,
        .print_human_ns = print_human_ns,
        .print_json_ns = print_json_ns,
        .temporal_ns = temporal_ns,
        .keyword_ns = keyword_ns,
    };
}

// ---------------------------------------------------------------------------
// JSON output to stdout
// ---------------------------------------------------------------------------

const StdoutWriter = struct {
    file: std.Io.File,
    buf: [8192]u8 = undefined,
    writer: ?std.Io.File.Writer = null,

    fn open(self: *StdoutWriter) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.writer = self.file.writer(io, &self.buf);
    }

    fn writeAll(self: *StdoutWriter, data: []const u8) !void {
        try self.writer.?.interface.writeAll(data);
    }

    fn writeFmt(self: *StdoutWriter, comptime fmt: []const u8, args: anytype) !void {
        try self.writer.?.interface.print(fmt, args);
    }

    fn flush(self: *StdoutWriter) !void {
        try self.writer.?.interface.flush();
    }
};

fn writeJsonOutput(out: *StdoutWriter, results: []const TierResult) !void {
    try out.writeAll("{\n");
    try out.writeAll("  \"version\": 1,\n");

    // Timestamp
    const ts = @divTrunc(Timer.nanoTimestamp(), std.time.ns_per_s);
    const epoch_secs: u64 = @intCast(ts);
    const es = std.time.epoch.EpochSeconds{ .secs = epoch_secs };
    const day_secs = es.getDaySeconds();
    const year_day = es.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    try out.writeFmt("  \"timestamp\": \"{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z\",\n", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    });

    try out.writeAll("  \"git_commit\": \"unknown\",\n");
    try out.writeFmt("  \"system\": {{ \"os\": \"{s}\", \"arch\": \"{s}\" }},\n", .{
        @tagName(builtin.os.tag),
        @tagName(builtin.cpu.arch),
    });

    // Tiers
    try out.writeAll("  \"tiers\": [\n");
    for (results, 0..) |r, i| {
        try out.writeAll("    {\n");
        try out.writeFmt("      \"name\": \"{s}\",\n", .{r.name});
        try out.writeFmt("      \"query_count\": {d},\n", .{r.query_count});
        if (r.skipped) {
            try out.writeAll("      \"skipped\": true,\n");
            if (r.skip_reason) |reason| {
                try out.writeFmt("      \"skip_reason\": \"{s}\",\n", .{reason});
            }
        }
        try out.writeFmt("      \"lex_ops_sec\": {d:.0},\n", .{r.lex_ops_sec});
        try out.writeFmt("      \"parse_simple_ns\": {d:.0},\n", .{r.parse_simple_ns});
        try out.writeFmt("      \"parse_rel_ns\": {d:.0},\n", .{r.parse_rel_ns});
        try out.writeFmt("      \"parse_complex_ns\": {d:.0},\n", .{r.parse_complex_ns});
        try out.writeFmt("      \"print_human_ns\": {d:.0},\n", .{r.print_human_ns});
        try out.writeFmt("      \"print_json_ns\": {d:.0},\n", .{r.print_json_ns});
        try out.writeFmt("      \"temporal_ns\": {d:.0},\n", .{r.temporal_ns});
        try out.writeFmt("      \"keyword_ns\": {d:.0}\n", .{r.keyword_ns});
        if (i < results.len - 1) {
            try out.writeAll("    },\n");
        } else {
            try out.writeAll("    }\n");
        }
    }
    try out.writeAll("  ]\n");
    try out.writeAll("}\n");
    try out.flush();
}

// ---------------------------------------------------------------------------
// Human-readable summary to stderr
// ---------------------------------------------------------------------------

fn writeSummary(results: []const TierResult) void {
    print("\n", .{});
    print("{s}\n", .{"=" ** 120});
    print("  gql incremental scale benchmark\n", .{});
    print("{s}\n\n", .{"=" ** 120});

    print("  {s:<6} {s:>8} {s:>12} {s:>12} {s:>12} {s:>14} {s:>12} {s:>12} {s:>12} {s:>12}\n", .{
        "Tier", "Queries", "Lex ops/s", "Simple(ns)", "Rel(ns)", "Complex(ns)", "HumPrt(ns)", "JsonPrt(ns)", "Temporal(ns)", "Keyword(ns)",
    });
    print("  {s:<6} {s:>8} {s:>12} {s:>12} {s:>12} {s:>14} {s:>12} {s:>12} {s:>12} {s:>12}\n", .{
        "-" ** 6, "-" ** 8, "-" ** 12, "-" ** 12, "-" ** 12, "-" ** 14, "-" ** 12, "-" ** 12, "-" ** 12, "-" ** 12,
    });

    for (results) |r| {
        if (r.skipped) {
            print("  {s:<6} {d:>8} SKIPPED ({s})\n", .{
                r.name, r.query_count, r.skip_reason orelse "unknown",
            });
        } else {
            print("  {s:<6} {d:>8} {d:>12.0} {d:>12.0} {d:>12.0} {d:>14.0} {d:>12.0} {d:>12.0} {d:>12.0} {d:>12.0}\n", .{
                r.name,
                r.query_count,
                r.lex_ops_sec,
                r.parse_simple_ns,
                r.parse_rel_ns,
                r.parse_complex_ns,
                r.print_human_ns,
                r.print_json_ns,
                r.temporal_ns,
                r.keyword_ns,
            });
        }
    }

    print("\n{s}\n\n", .{"=" ** 120});
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init.Minimal) !void {
    const allocator = std.heap.page_allocator;

    // Parse optional max-tier argument
    const argv = try init.args.toSlice(allocator);

    var max_tier_count: usize = tiers.len;
    if (argv.len > 1) {
        const arg = argv[1];
        for (tiers, 0..) |t, i| {
            if (std.mem.eql(u8, arg, t.name)) {
                max_tier_count = i + 1;
                break;
            }
        }
    }

    var results: [tiers.len]TierResult = undefined;
    var completed: usize = 0;

    for (tiers[0..max_tier_count], 0..) |tier, i| {
        print("  Running tier {s} ({d} queries)...\n", .{
            tier.name, tier.simple_count + tier.rel_count + tier.complex_count,
        });

        results[i] = runTier(allocator, tier);
        completed = i + 1;

        if (results[i].skipped) {
            print("  Tier {s} skipped: {s}\n", .{
                tier.name, results[i].skip_reason orelse "unknown",
            });
        } else {
            print("  Tier {s} complete.\n", .{tier.name});
        }
    }

    writeSummary(results[0..completed]);

    var out = StdoutWriter{ .file = std.Io.File.stdout() };
    out.open();
    try writeJsonOutput(&out, results[0..completed]);
}
