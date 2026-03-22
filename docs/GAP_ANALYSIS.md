# GAP Analysis

Last updated: 2026-03-21

Repository status: bootstrapped from `../zig-template`; no Geode code has been moved yet.

## Goal

Extract the reusable GQL front-end from Geode into a standalone library for parsers, linters, editors, protocol gateways, and tooling.

## Intended Boundary

Move into this library:

| Geode source | Why it belongs here |
|---|---|
| `src/gql/ast.zig:5`, `:7`, `:252` | Canonical AST types |
| `src/gql/token.zig:6`, `:216`, `:423` | Token model, keyword resolution, identifier helpers |
| `src/gql/lexer.zig:5`, `:13`, `:620` | Lexer implementation |
| `src/gql/parser.zig:13`, `:371` | Parser and `parseProgram` entry point |
| `src/gql/print.zig:12`, `:42`, `:51`, `:432` | Human and JSON printers plus expression formatting |
| `src/gql/status.zig:10`, `:49`, `:109`, `:157`, `:168`, `:177`, `:185` | Status and diagnostic model |
| `src/gql/language_metadata.zig:73`, `:1554`, `:1590` | Keyword/function/type/procedure metadata |
| `src/temporal.zig:7`, `:34`, `:133`, `:258`, `:308` | Date/time parsing and formatting helpers used by front-end serialization |
| `src/unicode/unicode_tables.zig:9`, `:84`, `:89`, `:145`, `:179` | Unicode identifier and encoding helpers used by the lexer/token layer |

Keep in Geode:

| Geode source | Why it stays |
|---|---|
| `src/gql/match.zig:176` | This is the bridge into planner/execution/store behavior |
| `src/gql/recommendations.zig:30`, `:46` | Recommendation and product-specific analysis logic is Geode-facing, not parser-core behavior |

## Concrete Gaps

| Gap | Evidence | Impact | Required fix |
|---|---|---|---|
| Parser/token packaging still assumes the Geode module tree | direct standalone review of `src/gql/parser.zig` and `src/gql/token.zig` failed on module-path assumptions | Blocks extraction | Normalize imports and define a proper package root here |
| Unicode support is bundled as local tables today | `src/unicode/unicode_tables.zig:9`, `:145`, `:179` | Affects public dependency story | Decide whether this repo owns the tables or depends on a dedicated Unicode package |
| Library metadata mixes ISO content and Geode extensions | `src/gql/language_metadata.zig:1801`, `:1848` | API documentation needs clearer compatibility labeling | Separate ISO core metadata from extensions in docs and maybe in data tables |

## Tests And Verification To Carry Over

| Geode test / verification | Coverage provided |
|---|---|
| `src/gql/token.zig:453` through `:538` | Token and keyword correctness |
| `src/gql/lexer.zig:698` through `:811` | UTF-8 decoding, invalid input, and operator tokenization |
| `src/gql/parser.zig:6591`, `:6604`, `:6617` | Parser behavior for `!=` and `<>` operators |
| `src/gql/status.zig:197` through `:234` | Status helpers and SQLSTATE coverage |
| `src/gql/language_metadata.zig:1638` through `:1881` | Metadata consistency and extension labeling |
| `src/temporal.zig:403`, `:413`, `:430`, `:438`, `:446` | Temporal parsing/formatting correctness |
| `build.zig:759`, `:767`, `:772` | Generated conformance test harness entries |
| `build.zig:1086` | Parser fuzz-test wiring |

Benchmarks identified:

- No dedicated parser benchmark was identified in Geode. Current validation is based on conformance, unit coverage, and fuzzing.

## Proposed Public API

Initial public surface should include:

- AST types
- token kinds and token helpers
- `Lexer`
- `Parser`
- printers
- status/diagnostic helpers
- language metadata
- temporal/unicode helpers required by the front-end

## Extraction Plan

1. Move the pure front-end modules into this repo.
2. Normalize imports so the package builds outside Geode.
3. Port the unit tests, conformance harness, and parser fuzz wiring.
4. Keep execution/planner-facing match/recommendation logic in Geode.
5. Document extension metadata separately from ISO core behavior.

## Acceptance Criteria

- This repo parses and prints GQL without the Geode runtime.
- Geode imports the parser/AST/status packages externally.
- `match.zig` and recommendation logic remain Geode-owned adapters.
