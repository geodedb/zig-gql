// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! # gql
//!
//! Standalone GQL (ISO/IEC 39075:2024) front-end library for Zig.
//!
//! Provides lexing, parsing, AST types, pretty-printing, status/diagnostics,
//! and language metadata for GQL queries. Extracted from the Geode graph
//! database so that parsers, linters, editors, protocol gateways, and other
//! tooling can depend on the GQL front-end without pulling in the full
//! Geode runtime.
//!
//! ## Quick Start
//!
//! ```zig
//! const gql = @import("gql");
//!
//! pub fn main() !void {
//!     var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
//!     defer arena.deinit();
//!     var lx = gql.Lexer{ .src = "MATCH (n) RETURN n" };
//!     var parser = gql.Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
//!     const prog = try parser.parseProgram();
//!     _ = prog;
//! }
//! ```
//!
//! ## Security Notes
//!
//! The parser allocates all AST nodes via the caller-provided arena allocator.
//! When parsing untrusted input, callers SHOULD use a memory-limited backing
//! allocator to prevent denial-of-service via memory exhaustion:
//!
//! ```zig
//! var buf: [4 * 1024 * 1024]u8 = undefined; // 4 MB budget
//! var fba = std.heap.FixedBufferAllocator.init(&buf);
//! var arena = std.heap.ArenaAllocator.init(fba.allocator());
//! ```
//!
//! The parser also has a recursion depth limit (256 levels) to prevent
//! stack overflow on deeply nested expressions.
//!
//! ## Thread Safety
//!
//! - **Lexer / Parser**: NOT thread-safe. Each thread must create its own
//!   `Lexer`, `Parser`, and `ArenaAllocator` instances. Do not share a
//!   single Lexer or Parser across threads.
//! - **AST (Program, Statement, Expr, etc.)**: Immutable after parsing.
//!   Safe to share read-only across threads without synchronization.
//! - **printProgramJson**: Guarded by an internal mutex on the global GPA.
//!   Safe to call concurrently. For maximum throughput, prefer
//!   `printProgramJsonWith` with a per-thread allocator.
//! - **parallel.zig functions**: Thread-safe. `getPool()`, `deinitPool()`,
//!   `parallelProcessStatements()`, `parallelValidateStatements()`, and
//!   `parallelCount()` use internal synchronization. Requires
//!   `-Dthread_pool=true` to enable parallel execution; otherwise all ops
//!   run sequentially.
//! - **language_metadata, status, token**: Read-only lookup tables. Safe
//!   to use from any thread without synchronization.
//!
//! ## License
//!
//! Apache-2.0

const std = @import("std");

// ============================================================================
// Public API — re-exported submodules
// ============================================================================

/// AST node types for GQL programs.
pub const ast = @import("ast.zig");

/// Token kinds, keyword resolution, and identifier helpers.
pub const token = @import("token.zig");

/// Lexer: converts GQL source text into a token stream.
pub const lexer = @import("lexer.zig");

/// Parser: converts a token stream into an AST.
pub const parser = @import("parser.zig");

/// Human-readable and JSON printers for AST nodes.
pub const print = @import("print.zig");

/// ISO/IEC 39075 status codes and diagnostic helpers.
pub const status = @import("status.zig");

/// GQL language metadata: keywords, functions, types, and procedures.
pub const language_metadata = @import("language_metadata.zig");

/// Date/time parsing and formatting helpers used by front-end serialization.
pub const temporal = @import("temporal.zig");

/// Unicode identifier and encoding helpers used by the lexer/token layer.
pub const unicode = @import("unicode/unicode_tables.zig");

/// Parallel processing helpers (optional thread-pool integration).
pub const parallel = @import("parallel.zig");

/// OpenTelemetry seam. Surfaces the no-op-when-disabled instrumentation
/// helpers (`startQueryExecutionSpan`, `endQueryExecutionSpan`, etc.).
/// When `-Dwith_otel=false` (the default) every helper compiles to a
/// comptime-known no-op and the otel dependency is never resolved.
pub const observability = @import("observability");

// ============================================================================
// Convenience re-exports
// ============================================================================

/// The GQL lexer.
pub const Lexer = lexer.Lexer;

/// The GQL parser.
pub const Parser = parser.Parser;

/// A parsed GQL program (list of statements).
pub const Program = ast.Program;

/// A single GQL statement.
pub const Statement = ast.Statement;

/// A GQL expression node.
pub const Expr = ast.Expr;

/// A single token from the lexer.
pub const Token = token.Token;

/// Token classification.
pub const TokenKind = token.TokenKind;

/// GQL status/diagnostic type.
pub const GqlStatus = status.GqlStatus;

/// Library version
pub const version = "0.1.0";

// ============================================================================
// Compile-time verification
// ============================================================================

test {
    // Ensure all public declarations are referenced for test coverage.
    // This also transitively runs tests in all imported modules.
    std.testing.refAllDecls(@This());
}
