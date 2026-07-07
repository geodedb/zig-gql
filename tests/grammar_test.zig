// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");
const builtin = @import("builtin");
const ebnf = @import("ebnf");
const iso_src = @embedFile("iso_bnf");

// Zig 0.16 moved file/dir I/O behind an explicit `Io` interface
// (`std.Io.Dir`), removing `std.fs.cwd()`. `std.Io` gained a `Dir`
// declaration only in 0.16, so it doubles as a reliable comptime version
// discriminator for `runCorpusDir` below, which needs to speak both
// dialects (mirrors the pattern used in the `ebnf` dependency's
// `src/lib.zig`).
const io_has_dir = @hasDecl(std.Io, "Dir");

inline fn io() std.Io {
    return if (builtin.is_test)
        std.testing.io
    else
        std.Io.Threaded.global_single_threaded.io();
}

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

// ============================================================================
// Conformance corpus (B5)
// ============================================================================
//
// `tests/corpus/iso/*.gql` and `tests/corpus/geode/*.gql` each carry a
// `-- expect: ok|error` header recording whether the CURRENT parser accepts
// the query. This is a conformance ratchet, not an ISO-purity claim: some
// "iso" corpus files exercise Cypher-compat surface (SHOW, EXPLAIN/PROFILE,
// UNWIND) that the parser supports but that src/language_metadata.zig tags
// `.cypher_compat` rather than `.iso_gql` — they live here because they are
// core, non-Geode-specific statement forms, not because every keyword is
// ISO/IEC 39075. The geode/ directory is reserved for Field-Level-Encryption
// annotations, PRIMARY KEY, SCAN, legacy ASSERT constraints, and other
// Geode-specific extensions that require `geode_mode` (see `parseOne` below).
//
// `-- unsupported: <reason>` on line 2 documents a case that IS valid GQL
// syntax but that this parser does not yet accept — the file is kept with
// `expect: error` so the gap is tracked instead of silently deleted.

/// Parse `src` once, in a scratch arena, optionally with the Geode extension
/// flags needed by `tests/corpus/geode/*.gql`.
///
/// Flag choice: `Parser` (src/parser.zig:26-48) exposes exactly one
/// syntax-affecting extension flag, `ts_extensions` (src/parser.zig:38).
/// Every other Geode surface in grammar/geode.bnf — `@encrypted`/`@searchable`
/// annotations, `PRIMARY KEY`, `SCAN`, legacy `ASSERT` constraints, the `^`
/// power operator — is parsed unconditionally by `Parser` regardless of any
/// flag (see `parseFieldDefinitions`, src/parser.zig:5889-5985, and the
/// `.SCAN`/`CREATE CONSTRAINT` arms of `parseStatement`). `ts_extensions`
/// itself does not gate whether the time-series builtins (`LAST_VALUE`,
/// `VALUE_AT`, `SAMPLE_BY`, ...) are *recognized* — `validateBuiltinCall`
/// (src/parser.zig:4224) accepts unknown/any-arity calls either way — it
/// gates whether their argument shape is *validated strictly*
/// (src/parser.zig:4258-4264: `if (!ts_enabled) true else (n == 1 and ...)`).
/// So `geode_mode` sets `ts_extensions = true`: it is the one flag whose
/// value changes parser behavior for Geode-extension queries, and setting it
/// is the honest choice for a corpus meant to exercise Geode syntax under its
/// real (strict) validation rules rather than the permissive ISO-only
/// default.
fn parseOne(a: std.mem.Allocator, src: []const u8, geode_mode: bool) !bool {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var lx = gql.Lexer{ .src = src };
    var p = gql.Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    if (geode_mode) {
        p.ts_extensions = true;
    }
    _ = p.parseProgram() catch return false;
    return true;
}

/// Checks one already-read corpus file's contents against its `-- expect:
/// ok|error` header. Factored out of `runCorpusDir` so the dual-version
/// (0.15 `std.fs.Dir` / 0.16 `std.Io.Dir`) directory-walking loops below can
/// share identical per-file logic.
fn checkCorpusFile(a: std.mem.Allocator, dir_path: []const u8, name: []const u8, src: []const u8, geode_mode: bool) !usize {
    var failures: usize = 0;
    const nl = std.mem.indexOfScalar(u8, src, '\n') orelse src.len;
    const header = src[0..nl];
    const expect_ok = std.mem.indexOf(u8, header, "expect: ok") != null;
    const expect_err = std.mem.indexOf(u8, header, "expect: error") != null;
    if (!expect_ok and !expect_err) {
        std.debug.print("CORPUS: {s}/{s} missing '-- expect: ok|error' header\n", .{ dir_path, name });
        failures += 1;
        return failures;
    }
    const ok = try parseOne(a, src[@min(nl + 1, src.len)..], geode_mode);
    if (ok != expect_ok) {
        std.debug.print("CORPUS DRIFT: {s}/{s} expected {s} but parser said {s}\n", .{ dir_path, name, if (expect_ok) "ok" else "error", if (ok) "ok" else "error" });
        failures += 1;
    }
    return failures;
}

fn runCorpusDir(a: std.mem.Allocator, dir_path: []const u8, geode_mode: bool) !usize {
    var failures: usize = 0;
    var count: usize = 0;
    if (comptime io_has_dir) {
        var dir = try std.Io.Dir.cwd().openDir(io(), dir_path, .{ .iterate = true });
        defer dir.close(io());
        var it = dir.iterate();
        while (try it.next(io())) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".gql")) continue;
            count += 1;
            const src = try dir.readFileAlloc(io(), entry.name, a, .limited(1 << 20));
            defer a.free(src);
            failures += try checkCorpusFile(a, dir_path, entry.name, src, geode_mode);
        }
    } else {
        var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
        defer dir.close();
        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".gql")) continue;
            count += 1;
            const src = try dir.readFileAlloc(a, entry.name, 1 << 20);
            defer a.free(src);
            failures += try checkCorpusFile(a, dir_path, entry.name, src, geode_mode);
        }
    }
    if (count == 0) {
        std.debug.print("CORPUS: no .gql files found in {s}\n", .{dir_path});
        failures += 1;
    }
    return failures;
}

test "conformance corpus matches recorded expectations" {
    const a = std.testing.allocator;
    var failures = try runCorpusDir(a, "tests/corpus/iso", false);
    failures += try runCorpusDir(a, "tests/corpus/geode", true);
    try std.testing.expectEqual(@as(usize, 0), failures);
}

// ============================================================================
// Deterministic generation ratchet (B5)
// ============================================================================
//
// Generates 500 random GQL-program sentences from the merged ISO+geode
// grammar (via ebnf.bnf.gen, seeded PRNG for determinism) and counts how many
// of them the real parser accepts. The count is expected to be LOW: the
// generator draws from the full, unconstrained ISO grammar (including every
// alternative this parser does not implement), while `Parser` only accepts a
// subset. The point is not to maximize the count but to PIN it — any future
// change to the grammar, the overrides below, or the parser that moves the
// count is a signal worth looking at, not a silent drift.
const gen_ratchet_src = @embedFile("gen_ratchet");

/// Maps lexical (character-by-character or otherwise noisy) ISO productions
/// to small pools of syntactically valid tokens, so generation bottoms out in
/// real tokens instead of empty strings / raw NBSP / digit-by-digit runs.
/// Names below were verified against grammar/ISO_IEC_39075.bnf.txt (grep for
/// `<...identifier> ::=`, `<...literal> ::=`, `<...parameter reference> ::=`,
/// and `<space> ::=`) rather than assumed from the task brief's starter list.
fn putLexicalOverrides(a: std.mem.Allocator, ov: *ebnf.bnf.gen.Overrides) !void {
    const entries = [_]struct { []const u8, []const []const u8 }{
        // <regular identifier> ::= <identifier start> [ <identifier extend>... ]
        // — both sub-productions are `!! See the Syntax Rules.` (impl_defined,
        // emits nothing), so without an override this collapses to "".
        .{ "regular identifier", &.{ "n", "m", "person", "acct" } },
        // <delimited identifier> ::= <double quoted character sequence> | <accent quoted character sequence>
        // — <character representation> is impl_defined; override to a fixed
        // quoted token.
        .{ "delimited identifier", &.{"\"weird name\""} },
        // <character string literal> ::= <single quoted character sequence> | <double quoted character sequence>
        // — same impl_defined bottom-out; override directly.
        .{ "character string literal", &.{ "'abc'", "''" } },
        // <byte string literal> ::= X <quote> [ <space>... ] ... — overriding
        // avoids both the impl_defined hex-digit runs and the <space> NBSP
        // oddity (see below).
        .{ "byte string literal", &.{"X'00ff'"} },
        // <unsigned decimal integer> ::= <digit> [ { [ <underscore> ] <digit> }... ]
        // — <digit> bottoms out in real terminals (0-9) so this WOULD
        // generate valid (if noisy, e.g. "0_1_2") integers on its own, but
        // overriding keeps generated numerics short and readable.
        .{ "unsigned decimal integer", &.{ "0", "7", "42" } },
        // <unsigned numeric literal> ::= <exact numeric literal> | <approximate numeric literal>
        .{ "unsigned numeric literal", &.{ "1", "3.14" } },
        // <separator> is impl_defined (whitespace/comment run description,
        // not a concrete terminal); override to a single space so it never
        // silently emits nothing where a token boundary is required.
        .{ "separator", &.{" "} },
        // <whitespace> ::= <space> | <horizontal tab> | ... — same reasoning.
        .{ "whitespace", &.{" "} },
        // <space> ::= <U+00A0 NO-BREAK SPACE> in the vendored artifact (a
        // typographic oddity of the source PDF-derived text, not a real GQL
        // token) — override to a plain ASCII space so it never surfaces
        // literally in generated output.
        .{ "space", &.{" "} },
        // <substituted parameter reference> ::= <double dollar sign> <parameter name>
        // <general parameter reference> ::= <dollar sign> <parameter name>
        // — <parameter name> bottoms out via <identifier>, but overriding the
        // whole production keeps parameter tokens short and lexable.
        .{ "general parameter reference", &.{"$param"} },
        .{ "substituted parameter reference", &.{"$$param"} },
    };
    for (entries) |e| try ov.put(a, e[0], e[1]);
}

test "deterministic grammar generation: parse-ok ratchet" {
    const a = std.testing.allocator;
    var iso = try ebnf.bnf.parse(a, iso_src);
    defer iso.deinit();
    var geo = try ebnf.bnf.parse(a, geode_src);
    defer geo.deinit();
    try iso.mergeFrom(a, &geo);

    var overrides = ebnf.bnf.gen.Overrides{};
    defer overrides.deinit(a);
    try putLexicalOverrides(a, &overrides);

    const num_seeds: u64 = 500;
    var ok_count: usize = 0;
    var seed: u64 = 1;
    while (seed <= num_seeds) : (seed += 1) {
        var prng = std.Random.DefaultPrng.init(seed);
        var cs = ebnf.bnf.gen.ChoiceSource{ .prng = &prng };
        const sentence = ebnf.bnf.gen.generate(a, &iso, .{
            .start = "GQL-program",
            .max_depth = 48,
            .overrides = &overrides,
        }, &cs) catch |e| {
            std.debug.print("GEN ERROR seed {d}: {s}\n", .{ seed, @errorName(e) });
            continue;
        };
        defer a.free(sentence);
        if (try parseOne(a, sentence, true)) ok_count += 1;
    }
    const expected = std.fmt.parseInt(usize, std.mem.trim(u8, gen_ratchet_src, " \t\r\n"), 10) catch 0;
    if (ok_count != expected) {
        std.debug.print(
            "GENERATION RATCHET DRIFT: {d}/{d} generated programs parsed (recorded: {d}).\n" ++
                "If this change is intentional, update grammar/generation_ratchet.txt to {d}.\n",
            .{ ok_count, num_seeds, expected, ok_count },
        );
    }
    try std.testing.expectEqual(expected, ok_count);
}
