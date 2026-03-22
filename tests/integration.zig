// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Integration tests for gql
//!
//! These tests verify end-to-end functionality and cross-module interactions.

const std = @import("std");
const gql = @import("gql");

// ============================================================================
// Integration Tests
// ============================================================================

test "integration: version is defined" {
    try std.testing.expectEqualStrings("0.1.0", gql.version);
}

test "integration: lex a simple query" {
    var lx = gql.Lexer{ .src = "MATCH (n) RETURN n" };
    const tok1 = lx.next();
    try std.testing.expectEqual(gql.TokenKind.MATCH, tok1.kind);
    const tok2 = lx.next();
    try std.testing.expectEqual(gql.TokenKind.l_paren, tok2.kind);
    const tok3 = lx.next();
    try std.testing.expectEqual(gql.TokenKind.identifier, tok3.kind);
    try std.testing.expectEqualStrings("n", tok3.lexeme);
}

test "integration: parse a simple MATCH-RETURN query" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var lx = gql.Lexer{ .src = "MATCH (n:Person) RETURN n" };
    var parser = gql.Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    const program = try parser.parseProgram();
    try std.testing.expect(program.statements.len > 0);
}

test "integration: parse query with WHERE clause" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var lx = gql.Lexer{ .src = "MATCH (n:Person) WHERE n.age > 21 RETURN n.name" };
    var parser = gql.Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    const program = try parser.parseProgram();
    try std.testing.expect(program.statements.len > 0);
}

test "integration: parse relationship pattern" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var lx = gql.Lexer{ .src = "MATCH (a)-[r:KNOWS]->(b) RETURN a, b" };
    var parser = gql.Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    const program = try parser.parseProgram();
    try std.testing.expect(program.statements.len > 0);
}

test "integration: status helpers produce correct SQLSTATE codes" {
    const err = gql.status.syntaxError("test", 1, 1, null);
    try std.testing.expectEqualStrings("42601", &err.sqlstate);
    try std.testing.expectEqual(gql.status.StatusClass.ERROR, err.class);

    const ok = gql.status.success();
    try std.testing.expectEqualStrings("00000", &ok.sqlstate);
    try std.testing.expectEqual(gql.status.StatusClass.SUCCESS, ok.class);
}

test "integration: keyword lookup is case-insensitive" {
    try std.testing.expectEqual(gql.TokenKind.MATCH, gql.token.keywordKind("MATCH"));
    try std.testing.expectEqual(gql.TokenKind.MATCH, gql.token.keywordKind("match"));
    try std.testing.expectEqual(gql.TokenKind.MATCH, gql.token.keywordKind("Match"));
    try std.testing.expectEqual(gql.TokenKind.identifier, gql.token.keywordKind("notAKeyword"));
}

test "integration: temporal parsing works standalone" {
    const d = try gql.temporal.parseDate("2024-08-12");
    try std.testing.expectEqual(@as(u16, 2024), d.y);
    try std.testing.expectEqual(@as(u8, 8), d.m);
    try std.testing.expectEqual(@as(u8, 12), d.d);
}

test "integration: unicode identifier support" {
    try std.testing.expect(gql.unicode.isIdentifierStart('a'));
    try std.testing.expect(gql.unicode.isIdentifierStart('_'));
    try std.testing.expect(!gql.unicode.isIdentifierStart('0'));
    try std.testing.expect(gql.unicode.isIdentifierContinue('a'));
    try std.testing.expect(gql.unicode.isIdentifierContinue('0'));
}

test "integration: parse CREATE statement" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var lx = gql.Lexer{ .src = "CREATE (n:Person {name: 'Alice'})" };
    var parser = gql.Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    const program = try parser.parseProgram();
    try std.testing.expect(program.statements.len > 0);
}

test "integration: parse MATCH-DELETE statement" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var lx = gql.Lexer{ .src = "MATCH (n:Temp) DELETE n" };
    var parser = gql.Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    const program = try parser.parseProgram();
    try std.testing.expect(program.statements.len > 0);
}

test "integration: parse MATCH with SET clause" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var lx = gql.Lexer{ .src = "MATCH (n) SET n.name = 'Bob' RETURN n" };
    var parser = gql.Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    const program = try parser.parseProgram();
    try std.testing.expect(program.statements.len > 0);
}

test "integration: parse UNION query" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var lx = gql.Lexer{ .src = "MATCH (a) RETURN a UNION MATCH (b) RETURN b" };
    var parser = gql.Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    const program = try parser.parseProgram();
    try std.testing.expect(program.statements.len > 0);
}

test "integration: parse ORDER BY with LIMIT" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var lx = gql.Lexer{ .src = "MATCH (n) RETURN n ORDER BY n.name LIMIT 10" };
    var parser = gql.Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    const program = try parser.parseProgram();
    try std.testing.expect(program.statements.len > 0);
}
