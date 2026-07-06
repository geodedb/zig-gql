// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const ebnf = @import("ebnf");
const iso_src = @embedFile("iso_bnf");

test "iso grammar parses, validates, and exposes expected productions" {
    const a = std.testing.allocator;
    var g = try ebnf.bnf.parse(a, iso_src);
    defer g.deinit();
    try std.testing.expect(g.ruleCount() >= 800);
    try g.validate(a);
    inline for (.{ "GQL-program", "match statement", "reserved word", "insert statement" }) |name| {
        try std.testing.expect(g.find(name) != null);
    }
}
