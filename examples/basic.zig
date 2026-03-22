// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Basic usage example for gql

const std = @import("std");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("gql parser example\n", .{});
    // Note: When using as a library dependency, import with:
    // const gql = @import("gql");
    // var lx = gql.Lexer{ .src = "MATCH (n) RETURN n" };
    // var parser = gql.Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    // const program = try parser.parseProgram();
}
