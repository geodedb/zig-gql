// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Parallel GQL operations using spice heartbeat scheduling.
//!
//! Provides parallel processing for statement validation and analysis.
//! When compiled without `-Dspice=true`, all functions degrade to
//! sequential execution with zero overhead.
//!
//! ## Parallel Parsing Pattern
//!
//! The GQL Lexer and Parser use mutable state internally and are **not**
//! thread-safe. To parse multiple GQL sources in parallel, create a
//! separate Lexer + Parser + ArenaAllocator per thread:
//!
//! ```zig
//! // Each thread does:
//! var arena = std.heap.ArenaAllocator.init(backing_allocator);
//! defer arena.deinit();
//! var lx = gql.Lexer{ .src = source_text };
//! var parser = gql.Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
//! const prog = try parser.parseProgram();
//! ```
//!
//! Once parsed, AST nodes are immutable and safe to share across threads.
//! The functions in this module operate on already-parsed AST data.
//!
//! ## Processing Already-Parsed Statements
//!
//! Rather than parallelizing the parse itself (which requires per-thread
//! Lexer/Parser instances), this module provides fork/join APIs that
//! operate on slices of already-parsed `ast.Statement` values:
//!
//! - `parallelProcessStatements` -- map a function over each statement
//! - `parallelValidateStatements` -- count statements matching a predicate
//! - `parallelCount` -- generic counted predicate over any slice
//!
//! All three automatically fall back to sequential execution when spice
//! is disabled or the input slice is below the fork threshold.

const std = @import("std");
const ast = @import("ast.zig");
const build_options = @import("build_options");

const spice = if (build_options.enable_spice) @import("spice") else struct {
    pub const ThreadPool = void;
    pub const ThreadPoolConfig = void;
    pub const Task = struct {};
    pub fn Future(comptime I: type, comptime O: type) type {
        _ = I;
        _ = O;
        return struct {
            pub fn init() @This() {
                return .{};
            }
        };
    }
};

// ============================================================================
// Global Thread Pool (lazy-initialized, mutex-guarded)
// ============================================================================

var pool_mutex: std.Thread.Mutex = .{};
var global_pool: if (build_options.enable_spice) ?spice.ThreadPool else void =
    if (build_options.enable_spice) null else {};

/// Returns a pointer to the global spice thread pool, initializing it on
/// first access.  Returns `void` when spice is disabled.
pub fn getPool() if (build_options.enable_spice) *spice.ThreadPool else void {
    if (!build_options.enable_spice) return;

    pool_mutex.lock();
    defer pool_mutex.unlock();

    if (global_pool == null) {
        global_pool = spice.ThreadPool.init(std.heap.page_allocator);
        global_pool.?.start(.{});
    }
    return &global_pool.?;
}

/// Tears down the global thread pool, joining all background workers.
/// Safe to call when spice is disabled (no-op) or when the pool was
/// never initialized.
pub fn deinitPool() void {
    if (!build_options.enable_spice) return;

    pool_mutex.lock();
    defer pool_mutex.unlock();

    if (global_pool) |*p| {
        p.deinit();
        global_pool = null;
    }
}

// ============================================================================
// Parallel Statement Processing
// ============================================================================

/// Context for fork/join statement processing.
pub fn StatementContext(comptime R: type) type {
    return struct {
        statements: []const ast.Statement,
        results: []R,
    };
}

/// Process parsed GQL statements in parallel, writing one result per
/// statement into `results`.  Falls back to sequential execution when
/// spice is disabled or the slice is shorter than 8 elements.
///
/// `processFn` is called once per statement and must be a pure function
/// (no mutable captures).
pub fn parallelProcessStatements(
    comptime R: type,
    statements: []const ast.Statement,
    results: []R,
    comptime processFn: fn (ast.Statement) R,
) void {
    std.debug.assert(statements.len == results.len);

    if (!build_options.enable_spice or statements.len < 8) {
        for (statements, 0..) |s, i| {
            results[i] = processFn(s);
        }
        return;
    }

    const pool = getPool();
    const Ctx = StatementContext(R);
    pool.call(void, ParallelStmtTask(R, processFn).task, Ctx{
        .statements = statements,
        .results = results,
    });
}

fn ParallelStmtTask(comptime R: type, comptime processFn: fn (ast.Statement) R) type {
    const Ctx = StatementContext(R);
    return struct {
        pub fn task(t: *spice.Task, ctx: Ctx) void {
            const stmts = ctx.statements;
            const results = ctx.results;

            if (stmts.len < 4) {
                for (stmts, 0..) |s, i| {
                    results[i] = processFn(s);
                }
                return;
            }

            const mid = stmts.len / 2;
            const left_ctx = Ctx{ .statements = stmts[0..mid], .results = results[0..mid] };
            const right_ctx = Ctx{ .statements = stmts[mid..], .results = results[mid..] };

            var fut = spice.Future(Ctx, void).init();
            fut.fork(t, task, right_ctx);

            t.call(void, task, left_ctx);
            if (fut.join(t)) |_| {} else t.call(void, task, right_ctx);
        }
    };
}

// ============================================================================
// Parallel Count
// ============================================================================

/// Count items matching a predicate, using fork/join parallelism when
/// spice is enabled and the input is large enough (>= 64 items).
pub fn parallelCount(
    comptime T: type,
    items: []const T,
    comptime predicate: fn (T) bool,
) usize {
    if (!build_options.enable_spice or items.len < 64) {
        var count: usize = 0;
        for (items) |item| {
            if (predicate(item)) count += 1;
        }
        return count;
    }

    const pool = getPool();
    return pool.call(usize, ParallelCountTask(T, predicate).task, items);
}

fn ParallelCountTask(comptime T: type, comptime predicate: fn (T) bool) type {
    return struct {
        pub fn task(t: *spice.Task, items: []const T) usize {
            if (items.len < 32) {
                var count: usize = 0;
                for (items) |item| {
                    if (predicate(item)) count += 1;
                }
                return count;
            }

            const mid = items.len / 2;
            const left = items[0..mid];
            const right = items[mid..];

            var fut = spice.Future([]const T, usize).init();
            fut.fork(t, task, right);

            const left_count = t.call(usize, task, left);
            const right_count = if (fut.join(t)) |val| val else t.call(usize, task, right);

            return left_count + right_count;
        }
    };
}

// ============================================================================
// Parallel Statement Validation
// ============================================================================

/// Apply a validation function to each statement in parallel, returning
/// the count of statements for which `validateFn` returns `true`.
/// Falls back to sequential processing when spice is disabled or input
/// is shorter than 8 items.
pub fn parallelValidateStatements(
    statements: []const ast.Statement,
    comptime validateFn: fn (ast.Statement) bool,
) usize {
    if (!build_options.enable_spice or statements.len < 8) {
        var count: usize = 0;
        for (statements) |s| {
            if (validateFn(s)) count += 1;
        }
        return count;
    }

    const pool = getPool();
    return pool.call(usize, ParallelValidateTask(validateFn).task, statements);
}

fn ParallelValidateTask(comptime validateFn: fn (ast.Statement) bool) type {
    return struct {
        pub fn task(t: *spice.Task, stmts: []const ast.Statement) usize {
            if (stmts.len < 4) {
                var count: usize = 0;
                for (stmts) |s| {
                    if (validateFn(s)) count += 1;
                }
                return count;
            }

            const mid = stmts.len / 2;
            const left = stmts[0..mid];
            const right = stmts[mid..];

            var fut = spice.Future([]const ast.Statement, usize).init();
            fut.fork(t, task, right);

            const left_count = t.call(usize, task, left);
            const right_count = if (fut.join(t)) |val| val else t.call(usize, task, right);

            return left_count + right_count;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "getPool returns void when spice disabled" {
    if (build_options.enable_spice) return error.SkipZigTest;
    const result = getPool();
    try std.testing.expectEqual({}, result);
}

test "deinitPool is safe when spice disabled" {
    if (build_options.enable_spice) return error.SkipZigTest;
    // Should be a no-op without crashing.
    deinitPool();
    deinitPool(); // idempotent
}

test "parallelProcessStatements sequential fallback" {
    if (build_options.enable_spice) return error.SkipZigTest;

    // Build a small set of statements — the sequential path runs for < 8
    const stmts = [_]ast.Statement{
        .Commit,
        .Rollback,
        .Commit,
    };

    var results: [3]bool = undefined;
    parallelProcessStatements(
        bool,
        &stmts,
        &results,
        struct {
            fn isCommit(s: ast.Statement) bool {
                return s == .Commit;
            }
        }.isCommit,
    );

    try std.testing.expect(results[0] == true);
    try std.testing.expect(results[1] == false);
    try std.testing.expect(results[2] == true);
}

test "parallelValidateStatements sequential fallback" {
    if (build_options.enable_spice) return error.SkipZigTest;

    const stmts = [_]ast.Statement{
        .Commit,
        .Rollback,
        .SessionClose,
        .Commit,
    };

    const count = parallelValidateStatements(
        &stmts,
        struct {
            fn isCommit(s: ast.Statement) bool {
                return s == .Commit;
            }
        }.isCommit,
    );

    try std.testing.expectEqual(@as(usize, 2), count);
}

test "parallelValidateStatements always-true returns full count" {
    if (build_options.enable_spice) return error.SkipZigTest;

    const stmts = [_]ast.Statement{
        .Commit,
        .Rollback,
        .SessionClose,
    };

    const count = parallelValidateStatements(
        &stmts,
        struct {
            fn alwaysTrue(_: ast.Statement) bool {
                return true;
            }
        }.alwaysTrue,
    );

    try std.testing.expectEqual(@as(usize, 3), count);
}

test "parallelValidateStatements always-false returns zero" {
    if (build_options.enable_spice) return error.SkipZigTest;

    const stmts = [_]ast.Statement{
        .Commit,
        .Rollback,
    };

    const count = parallelValidateStatements(
        &stmts,
        struct {
            fn alwaysFalse(_: ast.Statement) bool {
                return false;
            }
        }.alwaysFalse,
    );

    try std.testing.expectEqual(@as(usize, 0), count);
}

test "parallelCount sequential fallback" {
    if (build_options.enable_spice) return error.SkipZigTest;

    const items = [_]i32{ 1, 2, 3, 4, 5, 6 };
    const count = parallelCount(i32, &items, struct {
        fn isEven(x: i32) bool {
            return @mod(x, 2) == 0;
        }
    }.isEven);
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "deinitPool is safe when pool never initialized" {
    if (!build_options.enable_spice) return error.SkipZigTest;
    // When spice is enabled but pool was never used, deinit should be safe.
    // Note: we cannot easily test this because the global pool may already
    // be initialized by other tests. Just verify no crash.
    deinitPool();
}
