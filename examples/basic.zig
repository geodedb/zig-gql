// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Basic usage example for gql: lex + parse a GQL query and inspect the AST.
//!
//! Run with: `zig build example`

const std = @import("std");
const gql = @import("gql");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const source = "MATCH (n:Person)-[:KNOWS]->(m) WHERE n.age > 21 RETURN n.name, m.name";

    // The Lexer and Parser are not thread-safe; create them per parse.
    var lx = gql.Lexer{ .src = source };
    var parser = gql.Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    const program = try parser.parseProgram();

    std.debug.print(
        "Parsed {d} statement(s) from:\n  {s}\n",
        .{ program.statements.len, source },
    );
    for (program.statements, 0..) |stmt, i| {
        std.debug.print("  statement[{d}] = {s}\n", .{ i, @tagName(stmt) });
    }
}
