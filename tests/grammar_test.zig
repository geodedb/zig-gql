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

const geode_src = @embedFile("geode_bnf");

test "geode extension grammar parses and merges cleanly over ISO grammar" {
    const a = std.testing.allocator;
    var iso = try ebnf.bnf.parse(a, iso_src);
    defer iso.deinit();
    var geo = try ebnf.bnf.parse(a, geode_src);
    defer geo.deinit();
    // Extension productions may reference ISO nonterminals, so geode.bnf alone
    // is NOT expected to validate — the merged grammar must.
    try iso.mergeFrom(a, &geo);
    try iso.validate(a);
    try std.testing.expect(iso.find("geode GQL-program") != null);
    try std.testing.expect(iso.find("geode field annotation") != null);
}

// ============================================================================
// Keyword drift verification (B4)
// ============================================================================
//
// Scope: `gql.language_metadata.keywords` (all CAPS lexical keywords) AND
// `gql.language_metadata.types` (type names that are themselves grammar
// keyword terminals, e.g. ISO's <predefined type> alternatives and geode's
// VECTOR/UUID/JSON extension types) both participate. Both tables already
// expose `pub` arrays of `{ name, compliance, ... }` directly (no accessor
// function was needed/added — `language_metadata.keywords` and
// `language_metadata.types` are already public).
//
// `gql.language_metadata.functions` is intentionally EXCLUDED: function names
// are call-syntax identifiers (`count(...)`, `vectorf32(...)`), not grammar
// keyword terminals, so they have no membership in either BNF grammar's
// keyword set.
const gql = @import("gql");
const unimplemented_src = @embedFile("unimplemented_kw");

/// Verify a single metadata entry's ISO-compliance tag against the ISO and
/// geode grammar keyword sets. Prints a `DRIFT:` line and returns 1 for each
/// violation found; returns 0 if the entry is consistent.
///
/// `.cypher_compat` entries are intentionally skipped: they are neither ISO
/// nor geode-extension grammar keywords (they exist solely for Cypher
/// interop, e.g. FOREACH, LOAD, RELATIONSHIPS), so neither grammar's keyword
/// set is expected to contain them.
fn checkCompliance(
    name: []const u8,
    compliance: gql.language_metadata.Compliance,
    iso_kw: *const std.StringArrayHashMapUnmanaged(void),
    geo_kw: *const std.StringArrayHashMapUnmanaged(void),
) usize {
    var failures: usize = 0;
    switch (compliance) {
        .geode_extension => {
            if (iso_kw.contains(name)) {
                std.debug.print("DRIFT: '{s}' marked geode_extension but is an ISO keyword\n", .{name});
                failures += 1;
            }
            if (!geo_kw.contains(name)) {
                std.debug.print("DRIFT: geode keyword '{s}' missing from grammar/geode.bnf\n", .{name});
                failures += 1;
            }
        },
        .iso_gql => {
            if (!iso_kw.contains(name)) {
                std.debug.print("DRIFT: '{s}' marked ISO but absent from ISO grammar\n", .{name});
                failures += 1;
            }
        },
        .cypher_compat => {},
    }
    return failures;
}

test "keyword drift: metadata vs ISO grammar vs geode grammar" {
    const a = std.testing.allocator;
    var iso = try ebnf.bnf.parse(a, iso_src);
    defer iso.deinit();
    var geo = try ebnf.bnf.parse(a, geode_src);
    defer geo.deinit();
    var iso_kw = try iso.keywords(a);
    defer iso_kw.deinit(a);
    var geo_kw = try geo.keywords(a);
    defer geo_kw.deinit(a);

    var impl_kw = std.StringArrayHashMapUnmanaged(void){};
    defer impl_kw.deinit(a);

    var failures: usize = 0;

    for (gql.language_metadata.keywords) |entry| {
        try impl_kw.put(a, entry.name, {});
        failures += checkCompliance(entry.name, entry.compliance, &iso_kw, &geo_kw);
    }
    for (gql.language_metadata.types) |entry| {
        try impl_kw.put(a, entry.name, {});
        failures += checkCompliance(entry.name, entry.compliance, &iso_kw, &geo_kw);
    }

    // Ratchet: ISO keywords the implementation does not know yet.
    var expected_missing = std.StringArrayHashMapUnmanaged(void){};
    defer expected_missing.deinit(a);
    var lines = std.mem.tokenizeScalar(u8, unimplemented_src, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len > 0) try expected_missing.put(a, t, {});
    }
    for (iso_kw.keys()) |kw| {
        const known = impl_kw.contains(kw);
        const listed = expected_missing.contains(kw);
        if (!known and !listed) {
            std.debug.print("DRIFT: ISO keyword '{s}' unimplemented but not in grammar/unimplemented_iso_keywords.txt\n", .{kw});
            failures += 1;
        }
        if (known and listed) {
            std.debug.print("DRIFT: '{s}' is implemented — remove it from grammar/unimplemented_iso_keywords.txt\n", .{kw});
            failures += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failures);
}
