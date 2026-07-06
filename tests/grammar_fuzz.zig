// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

// Grammar-guided fuzzing (B6).
//
// Property under test: ANY sentence the ISO+geode grammar can derive must
// never crash, hang, or corrupt memory in the lexer/parser. Fuzz bytes drive
// the grammar's derivation *choices* (`ebnf.bnf.gen.ChoiceSource.bytes`)
// rather than being fed to the parser directly, so the coverage-guided
// fuzzer explores grammar-shaped input space instead of unstructured noise
// (that unstructured-noise property is already covered by
// `src/parser.zig`'s `fuzzParseOne`). Parse rejection is a fine, expected
// outcome — a crash, hang, or leak is not.
//
// Deliberately does NOT apply the `Overrides` used by the deterministic
// generation ratchet (tests/grammar_test.zig): fuzzing WITHOUT lexical
// overrides exercises the lexer on raw grammar-derived character soup
// (impl_defined identifier/literal productions bottoming out however the
// grammar's own terminals resolve), which is the point of this target.

const std = @import("std");
const ebnf = @import("ebnf");
const gql = @import("gql");
const iso_src = @embedFile("iso_bnf");
const geode_src = @embedFile("geode_bnf");

var grammar: ?ebnf.bnf.Grammar = null;

/// Parses + merges the ISO/geode grammars once and caches the result in a
/// page_allocator-backed global. `std.testing.fuzz` (and the local smoke
/// loop below) invoke the property function many times per process; the
/// merged grammar has 800+ rules, so re-parsing it on every call would make
/// fuzzing prohibitively slow for no benefit (the grammar itself is not part
/// of what's being fuzzed).
fn getGrammar(a: std.mem.Allocator) !*ebnf.bnf.Grammar {
    if (grammar == null) {
        var iso = try ebnf.bnf.parse(a, iso_src);
        errdefer iso.deinit();
        var geo = try ebnf.bnf.parse(a, geode_src);
        defer geo.deinit();
        try iso.mergeFrom(a, &geo);
        grammar = iso;
    }
    return &grammar.?;
}

/// Core property, independent of whichever fuzz-input API zig's
/// `std.testing` happens to expose: derive one `GQL-program` sentence from
/// `input`'s choice stream and run it through the real lexer + parser inside
/// a bounded arena. Never returns an error for a parse rejection — only a
/// crash/panic/leak would fail this.
fn fuzzGrammarBytes(input: []const u8) anyerror!void {
    const g = try getGrammar(std.heap.page_allocator);

    var gen_buf: [1 << 20]u8 = undefined;
    var gen_fba = std.heap.FixedBufferAllocator.init(&gen_buf);
    var cs = ebnf.bnf.gen.ChoiceSource{ .bytes = .{ .data = input } };
    const sentence = ebnf.bnf.gen.generate(gen_fba.allocator(), g, .{
        .start = "GQL-program",
        .max_depth = 64,
        .max_len = 1 << 16,
    }, &cs) catch return; // generation OOM/NoFiniteDerivation is not a parser bug

    // Bounded parse arena mirrors src/parser.zig's fuzzParseOne hardening:
    // adversarial derivations must error, never OOM-crash the fuzzer.
    var parse_buf: [2 << 20]u8 = undefined;
    var parse_fba = std.heap.FixedBufferAllocator.init(&parse_buf);
    var arena = std.heap.ArenaAllocator.init(parse_fba.allocator());
    defer arena.deinit();
    var lx = gql.Lexer{ .src = sentence };
    var p = gql.Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    _ = p.parseProgram() catch {}; // rejection is fine; crashing is not
}

// --- std.testing.fuzz entry point -----------------------------------------
//
// zig 0.15.2's `std.testing.fuzz` calls `testOne(context, input: []const
// u8)`. zig 0.16.0 replaced that with a coverage-instrumented,
// `Smith`-driven `testOne(context, smith: *std.testing.Smith)` — the API
// `src/parser.zig`'s pre-existing `fuzzParseOne` (line ~6947) already
// targets, which is *why* that test does not compile on local zig 0.15.2
// (Smith does not exist there): a known, pre-existing, unrelated gap this
// task does not touch.
//
// This target has to compile under BOTH: CI pins 0.16.0 for `zig build test
// --fuzz`, while local dev here is 0.15.2 and `zig build test-grammar` must
// keep working as a local smoke gate. `has_smith` selects the parameter
// type at comptime so only the branch the running compiler's std lib
// actually supports is ever semantically analyzed — the same
// comptime-branch-elision idiom `build.zig` already uses to keep the otel
// seam a zero-cost no-op when `-Dwith_otel=false` (see the `with_otel`
// block there).
const has_smith = @hasDecl(std.testing, "Smith");

fn fuzzGrammarOne(context: void, in: if (has_smith) *std.testing.Smith else []const u8) anyerror!void {
    _ = context;
    const input: []const u8 = if (comptime has_smith) blk: {
        // 0.16.0 path (CI): ask Smith for a byte string and feed it through
        // the exact same `ChoiceSource.bytes` path the 0.15.2 path (and the
        // deterministic smoke test below) use, so the property tested is
        // identical regardless of how the byte stream was sourced.
        var smith_buf: [4096]u8 = undefined;
        const len = in.sliceWeightedBytes(&smith_buf, &.{
            .rangeAtMost(u8, 0x00, 0xff, 1),
        });
        break :blk smith_buf[0..len];
    } else in; // 0.15.2 path: `in` already IS the fuzz byte slice.
    try fuzzGrammarBytes(input);
}

test "fuzz: grammar-derived programs never crash the lexer/parser" {
    try std.testing.fuzz({}, fuzzGrammarOne, .{});
}

// --- Deterministic local robustness smoke ---------------------------------
//
// `zig build test --fuzz` is coverage-guided and, per the Makefile
// `grammar-fuzz` target, meant to run time-boxed (CI: 60s; see
// docs/notes there). That leaves plain `zig build test-grammar` exercising
// `fuzzGrammarOne` exactly once, on empty input (the minimal derivation) —
// useful as a compile+wire smoke check, but it doesn't touch the property
// beyond the trivial case. This test drives the SAME core property
// (`fuzzGrammarBytes`) directly over 200 fixed-seed pseudorandom byte
// strings, so `zig build test-grammar` also gets cheap, deterministic,
// always-on evidence that grammar-derived fuzzing survives non-trivial
// inputs — independent of which `std.testing.fuzz` API the active zig
// version exposes.
test "fuzz smoke: 200 seeded random byte strings never crash the lexer/parser" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    var buf: [256]u8 = undefined;
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const len = prng.random().intRangeAtMost(usize, 0, buf.len);
        prng.random().bytes(buf[0..len]);
        try fuzzGrammarBytes(buf[0..len]);
    }
}
