// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Benchmark comparison tool for gql.
//!
//! Reads two JSON result files (baseline and current), compares each metric
//! at each tier, and prints a table showing delta% and pass/fail.
//!
//! Usage: zig build compare-bench -- baseline.json current.json
//! Optional: zig build compare-bench -- baseline.json current.json 25
//!           (last arg is the regression threshold percentage, default 20)
//!
//! Exit code 0 if all pass, 1 if any regression exceeds threshold.

const std = @import("std");

const print = std.debug.print;

// ---------------------------------------------------------------------------
// JSON parsing types
// ---------------------------------------------------------------------------

const TierData = struct {
    name: []const u8 = "",
    query_count: f64 = 0,
    lex_ops_sec: f64 = 0,
    parse_simple_ns: f64 = 0,
    parse_rel_ns: f64 = 0,
    parse_complex_ns: f64 = 0,
    print_human_ns: f64 = 0,
    print_json_ns: f64 = 0,
    temporal_ns: f64 = 0,
    keyword_ns: f64 = 0,
    skipped: bool = false,
};

const BenchResult = struct {
    version: f64 = 0,
    tiers: []TierData = &[_]TierData{},
};

// ---------------------------------------------------------------------------
// Metric definitions
// ---------------------------------------------------------------------------

const MetricKind = enum {
    /// Higher is better (throughput metrics). A decrease is a regression.
    higher_is_better,
    /// Lower is better (latency metrics). An increase is a regression.
    lower_is_better,
};

const Metric = struct {
    name: []const u8,
    kind: MetricKind,
    get: *const fn (TierData) f64,
};

fn getLexOps(t: TierData) f64 {
    return t.lex_ops_sec;
}
fn getParseSimple(t: TierData) f64 {
    return t.parse_simple_ns;
}
fn getParseRel(t: TierData) f64 {
    return t.parse_rel_ns;
}
fn getParseComplex(t: TierData) f64 {
    return t.parse_complex_ns;
}
fn getPrintHuman(t: TierData) f64 {
    return t.print_human_ns;
}
fn getPrintJson(t: TierData) f64 {
    return t.print_json_ns;
}
fn getTemporal(t: TierData) f64 {
    return t.temporal_ns;
}
fn getKeyword(t: TierData) f64 {
    return t.keyword_ns;
}

const metrics = [_]Metric{
    .{ .name = "lex_ops_sec", .kind = .higher_is_better, .get = getLexOps },
    .{ .name = "parse_simple_ns", .kind = .lower_is_better, .get = getParseSimple },
    .{ .name = "parse_rel_ns", .kind = .lower_is_better, .get = getParseRel },
    .{ .name = "parse_complex_ns", .kind = .lower_is_better, .get = getParseComplex },
    .{ .name = "print_human_ns", .kind = .lower_is_better, .get = getPrintHuman },
    .{ .name = "print_json_ns", .kind = .lower_is_better, .get = getPrintJson },
    .{ .name = "temporal_ns", .kind = .lower_is_better, .get = getTemporal },
    .{ .name = "keyword_ns", .kind = .lower_is_better, .get = getKeyword },
};

// ---------------------------------------------------------------------------
// File reading and parsing
// ---------------------------------------------------------------------------

fn readJsonFile(allocator: std.mem.Allocator, path: []const u8) !BenchResult {
    // Zig 0.16: file reads go through the Io interface. Use the single-threaded
    // blocking Io (this is a short-lived CLI tool).
    const io = std.Io.Threaded.global_single_threaded.io();
    const content = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        std.Io.Limit.limited(10 * 1024 * 1024),
    ) catch |err| {
        print("Error: cannot read '{s}': {s}\n", .{ path, @errorName(err) });
        return err;
    };
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(BenchResult, allocator, content, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| {
        print("Error: failed to parse '{s}': {s}\n", .{ path, @errorName(err) });
        return err;
    };
    // Intentionally leak: program exits shortly.
    _ = &parsed;

    return parsed.value;
}

// ---------------------------------------------------------------------------
// Comparison
// ---------------------------------------------------------------------------

fn findTier(result: BenchResult, name: []const u8) ?TierData {
    for (result.tiers) |t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}

fn computeDeltaPct(baseline_val: f64, current_val: f64) f64 {
    if (baseline_val == 0) return 0;
    return ((current_val - baseline_val) / baseline_val) * 100.0;
}

fn isRegression(delta_pct: f64, kind: MetricKind, threshold: f64) bool {
    return switch (kind) {
        .higher_is_better => delta_pct < -threshold,
        .lower_is_better => delta_pct > threshold,
    };
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init.Minimal) !void {
    const allocator = std.heap.page_allocator;

    // Zig 0.16 replaced `std.process.args()` with the Init-provided argument
    // vector (argv[0] is the program name).
    const argv = try init.args.toSlice(allocator);

    if (argv.len < 3) {
        print("Usage: compare-bench <baseline.json> <current.json> [threshold%]\n", .{});
        std.process.exit(2);
    }
    const baseline_path = argv[1];
    const current_path = argv[2];

    var threshold: f64 = 20.0;
    if (argv.len > 3) {
        threshold = std.fmt.parseFloat(f64, argv[3]) catch 20.0;
    }

    const baseline = readJsonFile(allocator, baseline_path) catch {
        std.process.exit(2);
    };
    const current = readJsonFile(allocator, current_path) catch {
        std.process.exit(2);
    };

    // Print header
    print("\n{s}\n", .{"=" ** 90});
    print("  Benchmark Comparison\n", .{});
    print("  Baseline: {s}\n", .{baseline_path});
    print("  Current:  {s}\n", .{current_path});
    print("  Threshold: {d:.0}%\n", .{threshold});
    print("{s}\n\n", .{"=" ** 90});

    print("  {s:<6} {s:<18} {s:>14} {s:>14} {s:>10} {s:>6}\n", .{
        "Tier", "Metric", "Baseline", "Current", "Delta%", "Status",
    });
    print("  {s:<6} {s:<18} {s:>14} {s:>14} {s:>10} {s:>6}\n", .{
        "-" ** 6, "-" ** 18, "-" ** 14, "-" ** 14, "-" ** 10, "-" ** 6,
    });

    var any_regression = false;

    for (baseline.tiers) |base_tier| {
        if (base_tier.skipped) continue;

        const cur_tier = findTier(current, base_tier.name) orelse continue;
        if (cur_tier.skipped) continue;

        for (metrics) |m| {
            const base_val = m.get(base_tier);
            const cur_val = m.get(cur_tier);
            const delta = computeDeltaPct(base_val, cur_val);
            const regressed = isRegression(delta, m.kind, threshold);

            if (regressed) any_regression = true;

            const status: []const u8 = if (regressed) "FAIL" else "PASS";
            const sign: []const u8 = if (delta >= 0) "+" else "";
            print("  {s:<6} {s:<18} {d:>14.1} {d:>14.1} {s}{d:>8.1}% {s:>6}\n", .{
                base_tier.name,
                m.name,
                base_val,
                cur_val,
                sign,
                delta,
                status,
            });
        }

        print("\n", .{});
    }

    print("{s}\n", .{"=" ** 90});

    if (any_regression) {
        print("  RESULT: FAIL -- regression(s) detected above threshold\n\n", .{});
        std.process.exit(1);
    } else {
        print("  RESULT: PASS -- all metrics within threshold\n\n", .{});
    }
}
