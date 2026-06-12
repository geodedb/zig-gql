// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Performance benchmark harness for the gql front-end library.
//!
//! Benchmarks: lexing, parsing (simple through complex), AST printing,
//! temporal parsing, keyword lookup, and unicode classification.
//!
//! Run via: zig build bench
//!      or: make bench

const std = @import("std");
const gql = @import("gql");

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
// Helpers
// ---------------------------------------------------------------------------

const BenchResult = struct {
    name: []const u8,
    count: usize,
    total_ns: u64,

    fn ops_per_sec(self: BenchResult) f64 {
        if (self.total_ns == 0) return 0;
        const count_f: f64 = @floatFromInt(self.count);
        const ns_f: f64 = @floatFromInt(self.total_ns);
        return count_f / (ns_f / 1_000_000_000.0);
    }

    fn avg_ns(self: BenchResult) f64 {
        if (self.count == 0) return 0;
        const ns_f: f64 = @floatFromInt(self.total_ns);
        const count_f: f64 = @floatFromInt(self.count);
        return ns_f / count_f;
    }
};

const print = std.debug.print;

fn printHeader() void {
    print("\n{s}\n", .{"=" ** 78});
    print("  gql benchmark suite\n", .{});
    print("{s}\n\n", .{"=" ** 78});
    print("  {s:<34} {s:>10} {s:>14} {s:>12} {s:>10}\n", .{
        "Benchmark", "Count", "Total (ms)", "Avg (ns)", "ops/sec",
    });
    print("  {s:<34} {s:>10} {s:>14} {s:>12} {s:>10}\n", .{
        "-" ** 34, "-" ** 10, "-" ** 14, "-" ** 12, "-" ** 10,
    });
}

fn printResult(r: BenchResult) void {
    const total_ms = @as(f64, @floatFromInt(r.total_ns)) / 1_000_000.0;
    print("  {s:<34} {d:>10} {d:>14.2} {d:>12.1} {d:>10.0}\n", .{
        r.name,
        r.count,
        total_ms,
        r.avg_ns(),
        r.ops_per_sec(),
    });
}

fn printFooter() void {
    print("\n{s}\n\n", .{"=" ** 78});
}

// ---------------------------------------------------------------------------
// Query corpus
// ---------------------------------------------------------------------------

const queries = struct {
    const simple = "MATCH (n) RETURN n";
    const labeled = "MATCH (n:Person) RETURN n.name, n.age";
    const where = "MATCH (n:Person) WHERE n.age > 21 AND n.name <> 'Bob' RETURN n.name";
    const relationship = "MATCH (a:Person)-[r:KNOWS]->(b:Person) RETURN a.name, b.name, r.since";
    const multi_hop = "MATCH (a:Person)-[r1:KNOWS]->(b:Person)-[r2:WORKS_AT]->(c:Company) WHERE b.age > 30 RETURN a.name, c.name";
    const create = "CREATE (n:Person {name: 'Alice', age: 30, city: 'NYC'})";
    const set_clause = "MATCH (n:Person) WHERE n.name = 'Alice' SET n.age = 31, n.city = 'LA' RETURN n";
    const delete = "MATCH (n:Temp)-[r]->(m) DELETE r, n";
    const union_q = "MATCH (a:Person) RETURN a.name UNION MATCH (b:Company) RETURN b.name";
    const order_limit = "MATCH (n:Person) RETURN n.name, n.age ORDER BY n.age DESC LIMIT 10 OFFSET 5";
    const complex = "MATCH (a:Person)-[r:KNOWS]->(b:Person)-[r2:LIVES_IN]->(c:City) WHERE a.age > 25 AND b.name STARTS WITH 'A' AND c.population > 1000000 RETURN a.name, b.name, c.name, r.since ORDER BY a.name LIMIT 100";

    const all = [_][]const u8{
        simple,
        labeled,
        where,
        relationship,
        multi_hop,
        create,
        set_clause,
        delete,
        union_q,
        order_limit,
        complex,
    };
};

// ---------------------------------------------------------------------------
// Individual benchmarks
// ---------------------------------------------------------------------------

fn benchLexSimple() BenchResult {
    const iterations: usize = 50_000;
    var timer = Timer.start() catch return .{ .name = "lex simple", .count = 0, .total_ns = 0 };

    for (0..iterations) |_| {
        var lx = gql.Lexer{ .src = queries.simple };
        while (true) {
            const tok = lx.next();
            if (tok.kind == .eof) break;
        }
    }

    return .{ .name = "lex simple", .count = iterations, .total_ns = timer.read() };
}

fn benchLexComplex() BenchResult {
    const iterations: usize = 20_000;
    var timer = Timer.start() catch return .{ .name = "lex complex", .count = 0, .total_ns = 0 };

    for (0..iterations) |_| {
        var lx = gql.Lexer{ .src = queries.complex };
        while (true) {
            const tok = lx.next();
            if (tok.kind == .eof) break;
        }
    }

    return .{ .name = "lex complex", .count = iterations, .total_ns = timer.read() };
}

fn benchLexCorpus() BenchResult {
    const iterations: usize = 10_000;
    var timer = Timer.start() catch return .{ .name = "lex corpus (11 queries)", .count = 0, .total_ns = 0 };

    for (0..iterations) |_| {
        for (queries.all) |q| {
            var lx = gql.Lexer{ .src = q };
            while (true) {
                const tok = lx.next();
                if (tok.kind == .eof) break;
            }
        }
    }

    return .{ .name = "lex corpus (11 queries)", .count = iterations * queries.all.len, .total_ns = timer.read() };
}

fn benchParseSimple() BenchResult {
    const iterations: usize = 50_000;
    var timer = Timer.start() catch return .{ .name = "parse simple", .count = 0, .total_ns = 0 };

    for (0..iterations) |_| {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var lx = gql.Lexer{ .src = queries.simple };
        var parser = gql.Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
        _ = parser.parseProgram() catch {};
    }

    return .{ .name = "parse simple", .count = iterations, .total_ns = timer.read() };
}

fn benchParseWhere() BenchResult {
    const iterations: usize = 30_000;
    var timer = Timer.start() catch return .{ .name = "parse WHERE", .count = 0, .total_ns = 0 };

    for (0..iterations) |_| {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var lx = gql.Lexer{ .src = queries.where };
        var parser = gql.Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
        _ = parser.parseProgram() catch {};
    }

    return .{ .name = "parse WHERE", .count = iterations, .total_ns = timer.read() };
}

fn benchParseRelationship() BenchResult {
    const iterations: usize = 30_000;
    var timer = Timer.start() catch return .{ .name = "parse relationship", .count = 0, .total_ns = 0 };

    for (0..iterations) |_| {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var lx = gql.Lexer{ .src = queries.relationship };
        var parser = gql.Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
        _ = parser.parseProgram() catch {};
    }

    return .{ .name = "parse relationship", .count = iterations, .total_ns = timer.read() };
}

fn benchParseMultiHop() BenchResult {
    const iterations: usize = 20_000;
    var timer = Timer.start() catch return .{ .name = "parse multi-hop", .count = 0, .total_ns = 0 };

    for (0..iterations) |_| {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var lx = gql.Lexer{ .src = queries.multi_hop };
        var parser = gql.Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
        _ = parser.parseProgram() catch {};
    }

    return .{ .name = "parse multi-hop", .count = iterations, .total_ns = timer.read() };
}

fn benchParseComplex() BenchResult {
    const iterations: usize = 10_000;
    var timer = Timer.start() catch return .{ .name = "parse complex", .count = 0, .total_ns = 0 };

    for (0..iterations) |_| {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var lx = gql.Lexer{ .src = queries.complex };
        var parser = gql.Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
        _ = parser.parseProgram() catch {};
    }

    return .{ .name = "parse complex", .count = iterations, .total_ns = timer.read() };
}

fn benchParseCorpus() BenchResult {
    const iterations: usize = 5_000;
    var timer = Timer.start() catch return .{ .name = "parse corpus (11 queries)", .count = 0, .total_ns = 0 };

    for (0..iterations) |_| {
        for (queries.all) |q| {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            var lx = gql.Lexer{ .src = q };
            var parser = gql.Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
            _ = parser.parseProgram() catch {};
        }
    }

    return .{ .name = "parse corpus (11 queries)", .count = iterations * queries.all.len, .total_ns = timer.read() };
}

fn benchPrintHuman() BenchResult {
    const iterations: usize = 20_000;

    // Pre-parse the AST
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var lx = gql.Lexer{ .src = queries.complex };
    var parser = gql.Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    const program = parser.parseProgram() catch return .{ .name = "print human", .count = 0, .total_ns = 0 };

    var timer = Timer.start() catch return .{ .name = "print human", .count = 0, .total_ns = 0 };

    for (0..iterations) |_| {
        var buf: [4096]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        gql.print.printProgramHuman(&w, program) catch {};
    }

    return .{ .name = "print human", .count = iterations, .total_ns = timer.read() };
}

fn benchPrintJson() BenchResult {
    const iterations: usize = 20_000;
    const allocator = std.heap.page_allocator;

    // Pre-parse the AST
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var lx = gql.Lexer{ .src = queries.complex };
    var parser = gql.Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    const program = parser.parseProgram() catch return .{ .name = "print JSON", .count = 0, .total_ns = 0 };

    var timer = Timer.start() catch return .{ .name = "print JSON", .count = 0, .total_ns = 0 };

    for (0..iterations) |_| {
        var buf: [16384]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        gql.print.printProgramJsonWith(allocator, &w, program, .{}) catch {};
    }

    return .{ .name = "print JSON", .count = iterations, .total_ns = timer.read() };
}

fn benchTemporalParse() BenchResult {
    const iterations: usize = 100_000;
    const dates = [_][]const u8{
        "2024-01-15", "2025-12-31", "2000-06-15", "1999-01-01", "2030-03-28",
    };
    const times = [_][]const u8{
        "14:30:00", "23:59:59", "00:00:00", "12:00:00.123456", "08:15:30+05:30",
    };
    const datetimes = [_][]const u8{
        "2024-01-15T14:30:00Z", "2025-12-31T23:59:59", "2000-06-15T12:00:00.123",
    };

    var timer = Timer.start() catch return .{ .name = "temporal parse", .count = 0, .total_ns = 0 };

    var count: usize = 0;
    for (0..iterations) |_| {
        for (dates) |d| {
            _ = gql.temporal.parseDate(d) catch {};
            count += 1;
        }
        for (times) |t| {
            _ = gql.temporal.parseTime(t, true) catch {};
            count += 1;
        }
        for (datetimes) |dt| {
            _ = gql.temporal.parseDateTime(dt, true) catch {};
            count += 1;
        }
    }

    return .{ .name = "temporal parse", .count = count, .total_ns = timer.read() };
}

fn benchKeywordLookup() BenchResult {
    const iterations: usize = 200_000;
    const keywords = [_][]const u8{
        "MATCH", "RETURN",      "WHERE",           "CREATE", "DELETE",   "SET",  "MERGE",
        "ORDER", "LIMIT",       "OFFSET",          "UNION",  "OPTIONAL", "WITH", "AS",
        "AND",   "OR",          "NOT",             "IN",     "IS",       "NULL", "TRUE",
        "FALSE", "notAKeyword", "alsoNotAKeyword", "SELECT", "FROM",
    };

    var sink: usize = 0;
    var timer = Timer.start() catch return .{ .name = "keyword lookup", .count = 0, .total_ns = 0 };

    for (0..iterations) |_| {
        for (keywords) |kw| {
            sink +%= @intFromEnum(gql.token.keywordKind(kw));
        }
    }

    const elapsed = timer.read();
    std.mem.doNotOptimizeAway(sink);
    return .{ .name = "keyword lookup", .count = iterations * keywords.len, .total_ns = elapsed };
}

fn benchUnicodeClassify() BenchResult {
    const iterations: usize = 500_000;
    // Mix of ASCII, Latin-1, Greek, CJK, emoji
    const codepoints = [_]u21{
        'a', 'Z', '_', '0', '9',
        0x00E9, // e-acute
        0x0391, // Greek Alpha
        0x0410, // Cyrillic A
        0x4E16, // CJK character
        0x1F600, // emoji (not an identifier)
        '$',
        '@',
        ' ',
        '\n',
    };

    // Accumulate results to prevent optimizer from eliminating the calls
    var sink: usize = 0;
    var timer = Timer.start() catch return .{ .name = "unicode classify", .count = 0, .total_ns = 0 };

    for (0..iterations) |_| {
        for (codepoints) |cp| {
            sink +%= @intFromBool(gql.unicode.isIdentifierStart(cp));
            sink +%= @intFromBool(gql.unicode.isIdentifierContinue(cp));
        }
    }

    const elapsed = timer.read();
    std.mem.doNotOptimizeAway(sink);
    return .{ .name = "unicode classify", .count = iterations * codepoints.len * 2, .total_ns = elapsed };
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

pub fn main() void {
    printHeader();

    // Lexer benchmarks
    printResult(benchLexSimple());
    printResult(benchLexComplex());
    printResult(benchLexCorpus());

    // Parser benchmarks
    printResult(benchParseSimple());
    printResult(benchParseWhere());
    printResult(benchParseRelationship());
    printResult(benchParseMultiHop());
    printResult(benchParseComplex());
    printResult(benchParseCorpus());

    // Printer benchmarks
    printResult(benchPrintHuman());
    printResult(benchPrintJson());

    // Subsystem benchmarks
    printResult(benchTemporalParse());
    printResult(benchKeywordLookup());
    printResult(benchUnicodeClassify());

    printFooter();
}
