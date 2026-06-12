// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Parallel GQL operations using thread-pool flat chunking.
//!
//! Provides parallel processing for statement validation and analysis.
//! When compiled without `-Dthread_pool=true`, all functions degrade to
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
//! Lexer/Parser instances), this module provides flat-chunk APIs that
//! operate on slices of already-parsed `ast.Statement` values:
//!
//! - `parallelProcessStatements` -- map a function over each statement
//! - `parallelValidateStatements` -- count statements matching a predicate
//! - `parallelCount` -- generic counted predicate over any slice
//!
//! All three automatically fall back to sequential execution when thread-pool
//! is disabled or the input slice is below the fork threshold.

const std = @import("std");
const ast = @import("ast.zig");
const build_options = @import("build_options");

const tp = if (build_options.enable_tp) @import("thread_pool") else struct {
    pub const ThreadPool = void;
    pub const WaitGroup = void;
    pub const BatchTask = struct {};
    pub const TaskContext = struct {};
};

/// Maximum number of chunks for flat parallel work dispatch.
const MAX_CHUNKS: usize = 64;

// ============================================================================
// Global Thread Pool (lazy-initialized, mutex-guarded)
// ============================================================================

// Zig 0.16 removed `std.Thread.Mutex`; its zero-arg lock/unlock shape now
// lives behind `std.Io`. The thread_pool dependency already ships a
// drop-in `sync.Mutex` that restores the zero-arg API on top of the Io
// primitives, so reuse it when the pool is compiled in. When disabled the
// guard is never reached (getPool/deinitPool early-return), so a no-op stub
// keeps the unconditional module-scope declaration valid.
const PoolMutex = if (build_options.enable_tp) tp.sync.Mutex else struct {
    pub fn lock(_: *@This()) void {}
    pub fn unlock(_: *@This()) void {}
};
var pool_mutex: PoolMutex = .{};
var global_pool: if (build_options.enable_tp) ?tp.ThreadPool else void =
    if (build_options.enable_tp) null else {};

/// Returns a pointer to the global thread pool, initializing it on first
/// access.  Returns `void` when thread-pool is disabled.
pub fn getPool() if (build_options.enable_tp) *tp.ThreadPool else void {
    if (!build_options.enable_tp) return;

    pool_mutex.lock();
    defer pool_mutex.unlock();

    if (global_pool == null) {
        global_pool = tp.ThreadPool.init(std.heap.page_allocator, .{}) catch
            @panic("parallel: failed to initialize thread pool");
    }
    return &global_pool.?;
}

/// Tears down the global thread pool, joining all background workers.
/// Safe to call when thread-pool is disabled (no-op) or when the pool was
/// never initialized.
pub fn deinitPool() void {
    if (!build_options.enable_tp) return;

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

/// Process parsed GQL statements in parallel, writing one result per
/// statement into `results`.  Falls back to sequential execution when
/// thread-pool is disabled or the slice is shorter than 8 elements.
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

    if (!build_options.enable_tp or statements.len < 8) {
        for (statements, 0..) |s, i| {
            results[i] = processFn(s);
        }
        return;
    }

    const pool = getPool();

    const n = statements.len;
    const chunk_count = @min(n, MAX_CHUNKS);
    const chunk_size = (n + chunk_count - 1) / chunk_count;

    const ProcessChunkCtx = struct {
        statements: []const ast.Statement,
        results: []R,
    };

    var chunks: [MAX_CHUNKS]ProcessChunkCtx = undefined;
    var batch: [MAX_CHUNKS]tp.BatchTask = undefined;
    var actual_chunks: usize = 0;

    var offset: usize = 0;
    while (offset < n) : (offset += chunk_size) {
        const end = @min(offset + chunk_size, n);
        chunks[actual_chunks] = .{
            .statements = statements[offset..end],
            .results = results[offset..end],
        };
        batch[actual_chunks] = .{
            .task_fn = struct {
                fn run(ctx_ptr: *anyopaque, _: *tp.TaskContext) void {
                    const c: *ProcessChunkCtx = @ptrCast(@alignCast(ctx_ptr));
                    for (c.statements, 0..) |s, i| {
                        c.results[i] = processFn(s);
                    }
                }
            }.run,
            .ctx = @ptrCast(&chunks[actual_chunks]),
        };
        actual_chunks += 1;
    }

    var wg = pool.waitGroup();
    const submit = pool.submitBatch(batch[0..actual_chunks], .{ .wait_group = &wg }) catch {
        // Sequential fallback on submit error.
        for (statements, 0..) |s, i| {
            results[i] = processFn(s);
        }
        return;
    };
    // Backpressure (the default `.return_error` policy) can leave the tail of
    // the batch un-queued; run those chunks inline so no statement is skipped.
    var ci: usize = submit.submitted;
    while (ci < actual_chunks) : (ci += 1) {
        const c = chunks[ci];
        for (c.statements, 0..) |s, i| {
            c.results[i] = processFn(s);
        }
    }
    wg.wait();
}

// ============================================================================
// Parallel Count
// ============================================================================

/// Count items matching a predicate, using flat-chunk parallelism when
/// thread-pool is enabled and the input is large enough (>= 64 items).
pub fn parallelCount(
    comptime T: type,
    items: []const T,
    comptime predicate: fn (T) bool,
) usize {
    if (!build_options.enable_tp or items.len < 64) {
        var count: usize = 0;
        for (items) |item| {
            if (predicate(item)) count += 1;
        }
        return count;
    }

    const pool = getPool();

    const n = items.len;
    const chunk_count = @min(n, MAX_CHUNKS);
    const chunk_size = (n + chunk_count - 1) / chunk_count;

    const CountChunkCtx = struct {
        items: []const T,
        count: usize,
    };

    var chunks: [MAX_CHUNKS]CountChunkCtx = undefined;
    var batch: [MAX_CHUNKS]tp.BatchTask = undefined;
    var actual_chunks: usize = 0;

    var offset: usize = 0;
    while (offset < n) : (offset += chunk_size) {
        const end = @min(offset + chunk_size, n);
        chunks[actual_chunks] = .{
            .items = items[offset..end],
            .count = 0,
        };
        batch[actual_chunks] = .{
            .task_fn = struct {
                fn run(ctx_ptr: *anyopaque, _: *tp.TaskContext) void {
                    const c: *CountChunkCtx = @ptrCast(@alignCast(ctx_ptr));
                    var cnt: usize = 0;
                    for (c.items) |item| {
                        if (predicate(item)) cnt += 1;
                    }
                    c.count = cnt;
                }
            }.run,
            .ctx = @ptrCast(&chunks[actual_chunks]),
        };
        actual_chunks += 1;
    }

    var wg = pool.waitGroup();
    const submit = pool.submitBatch(batch[0..actual_chunks], .{ .wait_group = &wg }) catch {
        // Sequential fallback on submit error.
        var count: usize = 0;
        for (items) |item| {
            if (predicate(item)) count += 1;
        }
        return count;
    };
    // Run any un-queued tail chunks inline (see parallelProcessStatements).
    var ci: usize = submit.submitted;
    while (ci < actual_chunks) : (ci += 1) {
        var cnt: usize = 0;
        for (chunks[ci].items) |item| {
            if (predicate(item)) cnt += 1;
        }
        chunks[ci].count = cnt;
    }
    wg.wait();

    var total: usize = 0;
    for (chunks[0..actual_chunks]) |c| {
        total += c.count;
    }
    return total;
}

// ============================================================================
// Parallel Statement Validation
// ============================================================================

/// Apply a validation function to each statement in parallel, returning
/// the count of statements for which `validateFn` returns `true`.
/// Falls back to sequential processing when thread-pool is disabled or input
/// is shorter than 8 items.
pub fn parallelValidateStatements(
    statements: []const ast.Statement,
    comptime validateFn: fn (ast.Statement) bool,
) usize {
    if (!build_options.enable_tp or statements.len < 8) {
        var count: usize = 0;
        for (statements) |s| {
            if (validateFn(s)) count += 1;
        }
        return count;
    }

    const pool = getPool();

    const n = statements.len;
    const chunk_count = @min(n, MAX_CHUNKS);
    const chunk_size = (n + chunk_count - 1) / chunk_count;

    const ValidateChunkCtx = struct {
        statements: []const ast.Statement,
        count: usize,
    };

    var chunks: [MAX_CHUNKS]ValidateChunkCtx = undefined;
    var batch: [MAX_CHUNKS]tp.BatchTask = undefined;
    var actual_chunks: usize = 0;

    var offset: usize = 0;
    while (offset < n) : (offset += chunk_size) {
        const end = @min(offset + chunk_size, n);
        chunks[actual_chunks] = .{
            .statements = statements[offset..end],
            .count = 0,
        };
        batch[actual_chunks] = .{
            .task_fn = struct {
                fn run(ctx_ptr: *anyopaque, _: *tp.TaskContext) void {
                    const c: *ValidateChunkCtx = @ptrCast(@alignCast(ctx_ptr));
                    var cnt: usize = 0;
                    for (c.statements) |s| {
                        if (validateFn(s)) cnt += 1;
                    }
                    c.count = cnt;
                }
            }.run,
            .ctx = @ptrCast(&chunks[actual_chunks]),
        };
        actual_chunks += 1;
    }

    var wg = pool.waitGroup();
    const submit = pool.submitBatch(batch[0..actual_chunks], .{ .wait_group = &wg }) catch {
        // Sequential fallback on submit error.
        var count: usize = 0;
        for (statements) |s| {
            if (validateFn(s)) count += 1;
        }
        return count;
    };
    // Run any un-queued tail chunks inline (see parallelProcessStatements).
    var ci: usize = submit.submitted;
    while (ci < actual_chunks) : (ci += 1) {
        var cnt: usize = 0;
        for (chunks[ci].statements) |s| {
            if (validateFn(s)) cnt += 1;
        }
        chunks[ci].count = cnt;
    }
    wg.wait();

    var total: usize = 0;
    for (chunks[0..actual_chunks]) |c| {
        total += c.count;
    }
    return total;
}

// ============================================================================
// Tests
// ============================================================================

test "getPool returns void when thread-pool disabled" {
    if (build_options.enable_tp) return error.SkipZigTest;
    const result = getPool();
    try std.testing.expectEqual({}, result);
}

test "deinitPool is safe when thread-pool disabled" {
    if (build_options.enable_tp) return error.SkipZigTest;
    // Should be a no-op without crashing.
    deinitPool();
    deinitPool(); // idempotent
}

test "parallelProcessStatements sequential fallback" {
    if (build_options.enable_tp) return error.SkipZigTest;

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
    if (build_options.enable_tp) return error.SkipZigTest;

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
    if (build_options.enable_tp) return error.SkipZigTest;

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
    if (build_options.enable_tp) return error.SkipZigTest;

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
    if (build_options.enable_tp) return error.SkipZigTest;

    const items = [_]i32{ 1, 2, 3, 4, 5, 6 };
    const count = parallelCount(i32, &items, struct {
        fn isEven(x: i32) bool {
            return @mod(x, 2) == 0;
        }
    }.isEven);
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "parallelValidateStatements mixed predicate" {
    // Runs in both thread-pool-enabled and thread-pool-disabled modes.
    const stmts = [_]ast.Statement{
        .Commit,
        .Rollback,
        .SessionClose,
        .Commit,
        .Rollback,
    };

    const count = parallelValidateStatements(
        &stmts,
        struct {
            fn notRollback(s: ast.Statement) bool {
                return s != .Rollback;
            }
        }.notRollback,
    );

    // Commit + SessionClose + Commit = 3
    try std.testing.expectEqual(@as(usize, 3), count);
}

test "deinitPool is safe when pool never initialized" {
    if (!build_options.enable_tp) return error.SkipZigTest;
    // When thread-pool is enabled but pool was never used, deinit should be safe.
    // Note: we cannot easily test this because the global pool may already
    // be initialized by other tests. Just verify no crash.
    deinitPool();
}

// The following tests use input sizes above the fork thresholds so they
// exercise the real parallel-dispatch path (submitBatch + chunked work +
// inline tail handling) under -Dthread_pool=true, and the sequential path
// otherwise. Both must produce identical, correct results.

test "parallelValidateStatements parallel path correctness" {
    const allocator = std.testing.allocator;
    // 200 statements: Commit at even indices, Rollback at odd → 100 Commits.
    const stmts = try allocator.alloc(ast.Statement, 200);
    defer allocator.free(stmts);
    for (stmts, 0..) |*s, i| s.* = if (i % 2 == 0) .Commit else .Rollback;

    const count = parallelValidateStatements(stmts, struct {
        fn isCommit(s: ast.Statement) bool {
            return s == .Commit;
        }
    }.isCommit);
    try std.testing.expectEqual(@as(usize, 100), count);

    if (build_options.enable_tp) deinitPool();
}

test "parallelProcessStatements parallel path correctness" {
    const allocator = std.testing.allocator;
    const stmts = try allocator.alloc(ast.Statement, 256);
    defer allocator.free(stmts);
    for (stmts, 0..) |*s, i| s.* = if (i % 3 == 0) .Commit else .Rollback;

    const results = try allocator.alloc(bool, 256);
    defer allocator.free(results);

    parallelProcessStatements(bool, stmts, results, struct {
        fn isCommit(s: ast.Statement) bool {
            return s == .Commit;
        }
    }.isCommit);

    var commits: usize = 0;
    for (results, 0..) |r, i| {
        try std.testing.expectEqual(i % 3 == 0, r);
        if (r) commits += 1;
    }
    try std.testing.expectEqual(@as(usize, 86), commits); // ceil(256/3)

    if (build_options.enable_tp) deinitPool();
}

test "parallelCount parallel path correctness" {
    const allocator = std.testing.allocator;
    const items = try allocator.alloc(i32, 500);
    defer allocator.free(items);
    for (items, 0..) |*x, i| x.* = @intCast(i);

    const evens = parallelCount(i32, items, struct {
        fn isEven(x: i32) bool {
            return @mod(x, 2) == 0;
        }
    }.isEven);
    try std.testing.expectEqual(@as(usize, 250), evens);

    if (build_options.enable_tp) deinitPool();
}
