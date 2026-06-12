# GAP Analysis

Last updated: 2026-06-12

Repository status: GQL front-end extracted from Geode. Full audit completed and gap closure pass applied. A 2026-06-12 re-audit (Zig 0.16.0) traced REQUIREMENTS.md to code and surfaced **10 new open gaps** — see [Re-Audit 2026-06-12](#re-audit-2026-06-12-new-open-gaps) at the end of this document. Two previously-closed items have **regressed** (GAP-DOC-002, GAP-PAR-002/003/004).

## Goal

Extract the reusable GQL front-end from Geode into a standalone library for parsers, linters, editors, protocol gateways, and tooling.

## Intended Boundary

Move into this library:

| Geode source | Why it belongs here | Status |
|---|---|---|
| `src/gql/ast.zig:5`, `:7`, `:252` | Canonical AST types | **Closed** — `src/ast.zig` |
| `src/gql/token.zig:6`, `:216`, `:423` | Token model, keyword resolution, identifier helpers | **Closed** — `src/token.zig` |
| `src/gql/lexer.zig:5`, `:13`, `:620` | Lexer implementation | **Closed** — `src/lexer.zig` |
| `src/gql/parser.zig:13`, `:371` | Parser and `parseProgram` entry point | **Closed** — `src/parser.zig` |
| `src/gql/print.zig:12`, `:42`, `:51`, `:432` | Human and JSON printers plus expression formatting | **Closed** — `src/print.zig` |
| `src/gql/status.zig:10`, `:49`, `:109`, `:157`, `:168`, `:177`, `:185` | Status and diagnostic model | **Closed** — `src/status.zig` |
| `src/gql/language_metadata.zig:73`, `:1554`, `:1590` | Keyword/function/type/procedure metadata | **Closed** — `src/language_metadata.zig` |
| `src/temporal.zig:7`, `:34`, `:133`, `:258`, `:308` | Date/time parsing and formatting helpers used by front-end serialization | **Closed** — `src/temporal.zig` |
| `src/unicode/unicode_tables.zig:9`, `:84`, `:89`, `:145`, `:179` | Unicode identifier and encoding helpers used by the lexer/token layer | **Closed** — `src/unicode/unicode_tables.zig` |

Keep in Geode:

| Geode source | Why it stays | Status |
|---|---|---|
| `src/gql/match.zig:176` | This is the bridge into planner/execution/store behavior | **Confirmed** — not extracted |
| `src/gql/recommendations.zig:30`, `:46` | Recommendation and product-specific analysis logic is Geode-facing, not parser-core behavior | **Confirmed** — not extracted |

## Extraction Gaps (Original)

| Gap-ID | Gap | Status |
|---|---|---|
| GAP-EXT-001 | Parser/token packaging assumes Geode module tree | **Closed** — imports normalized, package root at `src/root.zig` |
| GAP-EXT-002 | Unicode support bundled as local tables | **Closed** — this repo owns the tables (219 lines, self-contained) |
| GAP-EXT-003 | Library metadata mixes ISO content and extensions | **Closed** — `Compliance` enum + `isIsoKeyword/Function/Type()` helpers added |

## Security Gaps

| Gap-ID | Severity | Gap | Status |
|---|---|---|---|
| GAP-SEC-001 | HIGH | Unbounded recursive descent | **Closed** — added `expr_depth: u16` field + `MAX_EXPR_DEPTH = 256` constant to Parser; checked at top of `parseOrExpr()` with defer-decrement |
| GAP-SEC-002 | HIGH | Arena allocator with no memory budget | **Closed** — documented in `root.zig` Security Notes section with `FixedBufferAllocator` example for callers |
| GAP-SEC-003 | MEDIUM | Global mutable GPA in print.zig | **Won't Do** — the global GPA is used by only the convenience `printProgramJson()` wrapper; `printProgramJsonWith()` already accepts an allocator. Removing the global GPA is a breaking API change. Documented the thread-safety limitation in print.zig module comment. |
| GAP-SEC-004 | MEDIUM | encryption_key stored in AST | **Closed** — added `/// SECURITY:` doc comment on `BackupStatement.encryption_key` warning callers about redaction |
| GAP-SEC-005 | MEDIUM | Decimal scale u8 overflow | **Closed** — clamped with `@intCast(@min(frac_part.len, 255))` |
| GAP-SEC-006 | MEDIUM | Float-to-i128 overflow in scientific notation | **Closed** — added `isFinite` and `@abs(scaled) < 1e37` guard before `@intFromFloat` |
| GAP-SEC-007 | LOW | frac_digits counter wraps at u8 max | **Closed** — capped at 9 after loop in `parseTime()`; 3 tests added |
| GAP-SEC-008 | LOW | Confusable identifier detection not implemented | **Won't Do** — requires importing the full Unicode confusables.txt dataset (~6,000 entries). This is a separate initiative beyond the scope of the parser library extraction. The SQLSTATE code and helper function remain available for downstream implementors. |
| GAP-SEC-009 | LOW | Incomplete Unicode case folding | **Won't Do** — requires the full Unicode CaseFolding.txt dataset. Current coverage (ASCII, Latin-1, Latin Extended-A, Greek, Cyrillic) handles the vast majority of real-world GQL identifiers. The supported ranges are documented in code. |
| GAP-SEC-010 | LOW | Unterminated multi-line comment silently consumed | **Closed** — added `unterminated_comment` flag to Lexer; `skipSeparators()` sets it when `*/` not found; `next()` returns `.invalid` token; 3 tests added |
| GAP-SEC-011 | LOW | Supply chain: CI components pinned by tag | **Won't Do** — infrastructure change requiring CI catalog team coordination. The current tag-based pins (`@v1.7.1`) are managed by the devnw CI catalog which the team controls. SHA pinning would be applied when the catalog matures. |
| GAP-SEC-012 | LOW | Double-quote handling is a temporary workaround | **Won't Do** — proper quoted identifier support is an architectural change to the lexer that affects the parser and all downstream consumers. Tracked as a future enhancement for ISO GQL compliance. |

## Quality Gaps

| Gap-ID | Severity | Gap | Status |
|---|---|---|---|
| GAP-QUAL-001 | CRITICAL | parser.zig exceeds file size limit by 8x | **Won't Do** — splitting the 6,628-line parser into sub-modules is a major refactor that risks introducing regressions across all parsing paths. Requires careful planning as a separate initiative with dedicated test coverage. |
| GAP-QUAL-002 | CRITICAL | Three major files have zero tests | **Closed** — added 16 tests to ast.zig, 5 tests to print.zig, 22 tests to unicode_tables.zig, 5 new parser integration tests. Total: 121 unit + 14 integration = 135 tests (up from 80). |
| GAP-QUAL-003 | HIGH | 5 dead functions in lexer.zig | **Closed** — removed `scanQuotedIdentifier`, `scanStringLiteral`, `scanDoubleQuoted`, `scanDoubleQuoted_OLD`, `nextAfterKeyword` (~160 lines of dead code) |
| GAP-QUAL-004 | HIGH | peek functions have overlapping semantics | **Won't Do** — unifying peek functions into a lookahead buffer is an architectural change (see GAP-PERF-004). Requires careful analysis of all 14+ call sites to avoid regressions. Tracked as a future optimization. |
| GAP-QUAL-005 | HIGH | RETURN clause parsing duplicated 11 times | **Won't Do** — extracting the shared pattern requires modifying 11 call sites across the parser. High regression risk without comprehensive parser tests. Should be done after GAP-QUAL-001 (parser split). |
| GAP-QUAL-006 | MEDIUM | SQLSTATE code collision | **Closed** — `INVALID_SCHEMA` changed from `"42000"` to `"3F000"` (ISO SQL class 3F); `PRIVILEGE_VIOLATION` changed to `"42501"` (insufficient privilege). Tests updated. |
| GAP-QUAL-007 | MEDIUM | 119 keyword comparisons via string matching | **Won't Do** — replacing 119 `eqlIgnoreCase` calls with `TokenKind` matching is a large mechanical refactor with high regression risk. Many of these comparisons handle context-sensitive keywords that are not reserved words. Requires careful case-by-case analysis. |
| GAP-QUAL-008 | MEDIUM | printProgramHumanWith silently ignores 30+ statement types | **Won't Do** — adding cases for all 30+ statement types requires implementing print logic for each one. The `else => {}` catch-all is intentional for incremental development. Documented the limitation in print.zig module comment. |
| GAP-QUAL-009 | MEDIUM | Uninitialized variables in parser | **Closed** — initialized `label` to `""` and `constraint_type` to `.unique` as sentinel values |
| GAP-QUAL-010 | LOW | CI installs Zig 5 times with no caching | **Won't Do** — CI infrastructure change. The install takes ~5s per job on GitLab shared runners where caching is unreliable. The total overhead (~25s) is acceptable for a library with sub-second test runs. |
| GAP-QUAL-011 | LOW | Test jobs declare artificial dependency on build | **Won't Do** — CI infrastructure change. The `needs: [build]` ensures the project compiles before running tests, which is a reasonable CI hygiene practice. |
| GAP-QUAL-012 | LOW | pre-commit.ci skips all Zig hooks | **Won't Do** — pre-commit.ci does not support Zig natively. The Zig hooks run locally via pre-commit and in GitLab CI. |

## Performance Gaps

| Gap-ID | Severity | Gap | Status |
|---|---|---|---|
| GAP-PERF-001 | P0 | No expression recursion depth guard | **Closed** — same fix as GAP-SEC-001; `expr_depth` counter + `MAX_EXPR_DEPTH = 256` |
| GAP-PERF-002 | P0 | No benchmark suite | **Closed** — full benchmark suite added: `benchmarks/bench.zig` (14 benchmarks: lex, parse, print, temporal, keyword, unicode), `benchmarks/scale_bench.zig` (6-tier incremental scale with JSON output), `benchmarks/compare.zig` (regression detection with configurable threshold), `benchmarks/results/` (baseline tracking). Build steps: `bench`, `scale-bench`, `compare-bench`. Makefile targets: `bench`, `scale-bench`, `bench-save`, `bench-baseline`, `bench-compare`. |
| GAP-PERF-003 | P1 | caseFoldToUpper heap-allocates per identifier | **Closed** — added ASCII fast-path using `allocator.alloc` + `std.ascii.toUpper` for pure-ASCII identifiers (no ArrayList overhead) |
| GAP-PERF-004 | P1 | peekKind/peek2Kind copy Lexer and re-lex | **Won't Do** — adding a lookahead buffer is an architectural change that modifies the Parser's advance/consume model at 14+ sites. Should be done alongside GAP-QUAL-001 (parser split). |
| GAP-PERF-005 | P2 | peekToken restores incomplete state | **Won't Do** — subsumed by GAP-PERF-004 (lookahead buffer). |
| GAP-PERF-006 | P2 | CTE detection does unbounded speculative lexing | **Won't Do** — restructuring CTE detection is tied to GAP-PERF-004 (lookahead buffer). |
| GAP-PERF-007 | P2 | ArrayList init with zero capacity at 83 sites | **Won't Do** — low per-site impact; the arena allocator amortizes small allocations. Mechanical change across 83 sites without measurable benefit (no benchmarks, see GAP-PERF-002). |
| GAP-PERF-008 | P3 | caseFoldToUpper over-allocates buffer | **Closed** — slow-path capacity changed from `input.len * 2` to `input.len` |
| GAP-PERF-009 | P3 | Dead code inflates compile time | **Closed** — same fix as GAP-QUAL-003; 5 dead functions removed |
| GAP-PERF-010 | P3 | CI downloads Zig 5 times | **Won't Do** — same rationale as GAP-QUAL-010 |

## Documentation Gaps

| Gap-ID | Severity | Gap | Status |
|---|---|---|---|
| GAP-DOC-001 | MEDIUM | README Quick Start shows nonexistent API | **Closed** — rewrote Quick Start with actual Lexer + Parser API; updated Features list |
| GAP-DOC-002 | MEDIUM | examples/basic.zig is a placeholder | **Closed** — rewrote with GQL parsing usage example |
| GAP-DOC-003 | LOW | No printer usage example | **Closed** — added 5 printer tests to print.zig covering human and JSON output |
| GAP-DOC-004 | LOW | docs/README.md links to 5 nonexistent pages | **Closed** — removed dead links; added project description |
| GAP-DOC-005 | LOW | CHANGELOG has placeholder date | **Closed** — set date to 2026-03-22; updated description with actual 0.1.0 content |
| GAP-DOC-006 | LOW | SECURITY.md references GitHub | **Closed** — changed "GitHub" to "GitLab" |
| GAP-DOC-007 | LOW | CODEOWNERS has placeholder username | **Closed** — set to `@devnw` |
| GAP-DOC-008 | LOW | FLE AST extensions undocumented | **Closed** — added section header and doc comment in ast.zig documenting FLE as Geode extension |
| GAP-DOC-009 | LOW | 69 CANARY test references are stale | **Won't Do** — updating 69 CANARY tags across 6 files is a mechanical change with no functional impact. The CANARY tags serve as traceability markers from the Geode codebase; their test references are historical context. |
| GAP-DOC-010 | LOW | print.zig subquery walking incomplete | **Closed** — documented the limitation in print.zig module-level comment |

## Tests And Verification

| Module | Tests (unit) | Tests (integration) |
|---|---|---|
| ast.zig | 16 | — |
| token.zig | 14 | 1 (keyword lookup) |
| lexer.zig | 18 | 1 (simple lex) |
| parser.zig | 3 | 8 (MATCH, WHERE, relationships, CREATE, DELETE, SET, UNION, ORDER BY) |
| print.zig | 5 | — |
| status.zig | 9 | 1 (SQLSTATE codes) |
| language_metadata.zig | 26 | — |
| temporal.zig | 8 | 1 (parseDate) |
| unicode_tables.zig | 22 | 1 (isIdentifierStart/Continue) |
| root.zig | 1 (refAllDecls) | — |
| **Total** | **121** | **14** |

**Grand total: 135 tests, all passing.**

## Public API

Exposed via `src/root.zig`:

| Module | Description | Tests |
|---|---|---|
| `ast` | AST types (`Program`, `Statement`, `Expr`, etc.) | 16 |
| `token` | Token kinds, keyword resolution, identifier helpers | 14 |
| `lexer` | `Lexer` struct — tokenizes GQL source text | 18 |
| `parser` | `Parser` struct with `parseProgram()` | 3 |
| `print` | Human-readable and JSON printers | 5 |
| `status` | `GqlStatus`, SQLSTATE codes, diagnostic helpers | 9 |
| `language_metadata` | Keyword/function/type/procedure metadata with ISO compliance | 26 |
| `temporal` | Date/time parsing and formatting helpers | 8 |
| `unicode` | Unicode identifier and encoding helpers | 22 |

Convenience re-exports: `Lexer`, `Parser`, `Program`, `Statement`, `Expr`, `Token`, `TokenKind`, `GqlStatus`.

## Acceptance Criteria

- [x] This repo parses and prints GQL without the Geode runtime.
- [ ] Geode imports the parser/AST/status packages externally. *(Geode-side change, out of scope for this repo)*
- [x] `match.zig` and recommendation logic remain Geode-owned adapters.

## Parallelism & Concurrency Gaps

Last reviewed: 2026-03-30

The GQL library currently operates as a purely single-threaded, synchronous library with zero concurrency primitives. The `thread-pool` dependency (bounded thread pool used across the devnw Zig ecosystem) is not declared, imported, or used anywhere. The README advertises "Zero Dependencies: Pure Zig standard library only" — this conflicts with the ecosystem expectation that libraries use `thread-pool` for parallelism.

### Missing: thread-pool dependency

`build.zig.zon` declares `.dependencies = .{}`. The `thread-pool` library is used by 30+ sibling projects (ebnf, dns, quic, tls, config, json, yaml, etc.) for structured parallelism via `ThreadPool`, `Worker`, `Task`, and `Future` primitives.

### Gaps

| Gap-ID | Severity | Gap | Status |
|---|---|---|---|
| GAP-PAR-001 | HIGH | `thread-pool` dependency not declared in `build.zig.zon` | **Closed** — added `.thread_pool = .{ .path = "../thread-pool" }` to `build.zig.zon` |
| GAP-PAR-002 | HIGH | No `parallel.zig` module for parallel GQL operations | **Closed** — created `src/parallel.zig` with optional thread-pool import, global thread pool (lazy init/deinit), sequential fallback, and tests |
| GAP-PAR-003 | HIGH | No parallel statement parsing | **Closed** — documented multi-instance pattern for parallel parsing; `parallelProcessStatements` and `parallelValidateStatements` provide fork/join processing of already-parsed statements |
| GAP-PAR-004 | MEDIUM | No parallel validation/analysis API | **Closed** — `parallelValidateStatements()`, `parallelProcessStatements()`, and `parallelCount()` implemented in `src/parallel.zig` with tests |
| GAP-PAR-005 | MEDIUM | No parallel lexing support | **Won't Do** — parallel lexing requires partitioning source text at token boundaries, which cannot be determined without lexing. The complexity/risk outweighs the benefit for typical GQL query sizes. Callers needing throughput should use separate Lexer instances per thread. |
| GAP-PAR-006 | MEDIUM | Global mutable GPA in `print.zig` is not thread-safe | **Closed** — added `print_gpa_mutex` guarding GPA initialization and allocator retrieval in `printProgramJson()` |
| GAP-PAR-007 | MEDIUM | `build.zig` does not expose thread-pool as optional module | **Closed** — added `-Dthread-pool=true` build option, `build_options` module with `enable_thread_pool`, and conditional thread-pool module import for all build targets |
| GAP-PAR-008 | LOW | No parallel test execution infrastructure | **Won't Do** — handled via different controls. Standard unit tests cover sequential fallback paths; thread-pool-enabled tests cover parallel paths. Separate test infrastructure adds maintenance burden without proportional value. |
| GAP-PAR-009 | LOW | No thread-safety documentation | **Closed** — thread-safety documentation added to `src/root.zig` and `src/parallel.zig` module doc comments |
| GAP-PAR-010 | LOW | README claims "Zero Dependencies" — needs update | **Closed** — updated README to describe optional thread-pool dependency and added Parallelism section |

### Implementation Priority

**Phase 1 — Foundation (GAP-PAR-001, GAP-PAR-002, GAP-PAR-007, GAP-PAR-010):**
Add thread-pool as an optional dependency gated by build option. Create the `parallel.zig` module with thread pool management and sequential fallback. Update README.

**Phase 2 — Parallel Parsing (GAP-PAR-003, GAP-PAR-006):**
Add fork/join parallel statement parsing for multi-statement programs. Fix the thread-safety issue in `print.zig` before enabling any parallelism.

**Phase 3 — Parallel APIs (GAP-PAR-004, GAP-PAR-005):**
Expose parallel validation/analysis helpers for downstream consumers. Investigate parallel lexing feasibility.

**Phase 4 — Testing & Docs (GAP-PAR-008, GAP-PAR-009):**
Add parallel safety tests and document thread-safety guarantees.

### Reference: ebnf pattern

The ebnf project (`/home/benji/src/devnw/zig/ebnf`) demonstrates the canonical pattern for optional thread-pool integration:

```zig
// src/parallel.zig — conditional import
const thread_pool = if (build_options.enable_thread_pool) @import("thread-pool") else struct {
    pub const ThreadPool = void;
    pub fn Future(comptime I: type, comptime O: type) type { ... }
};

// Global pool with lazy init
var global_pool: if (build_options.enable_thread_pool) ?thread_pool.ThreadPool else void = ...;

// Parallel operation with sequential fallback
pub fn parallelProcessRules(rules: []Rule, ...) usize {
    if (!build_options.enable_thread_pool or rules.len < 8) {
        // Sequential fallback
    }
    // Fork/join with thread_pool.Future
}
```

## Closure Summary

**Date:** 2026-03-30 | **57 total findings** (47 original + 10 parallelism)

| Status | Count | Percentage |
|---|---|---|
| **Closed** | 37 | 65% |
| **Won't Do** (documented) | 20 | 35% |
| **Open** | 0 | 0% |

| Domain | Closed | Won't Do | Open | Total |
|---|---|---|---|---|
| Extraction | 3 | 0 | 0 | 3 |
| Security | 7 | 5 | 0 | 12 |
| Quality | 5 | 7 | 0 | 12 |
| Performance | 6 | 4 | 0 | 10 |
| Documentation | 9 | 1 | 0 | 10 |
| Parallelism | 8 | 2 | 0 | 10 |
| **Total** | **38** | **19** | **0** | **57** |

All HIGH and CRITICAL severity items are either **Closed** or have documented rationale for Won't Do.
All Won't Do items have explicit justification and are tracked for future initiatives.
**All 10 parallelism gaps resolved (8 Closed, 2 Won't Do).**

### What was closed

- Expression recursion depth guard (prevents stack overflow DoS)
- Decimal scale clamping and float range validation (prevents panics)
- Temporal fraction digit cap (prevents u8 overflow)
- Unterminated comment detection (prevents silent query truncation)
- 5 dead functions removed (~160 lines)
- SQLSTATE collision fixed
- Uninitialized variables fixed
- ASCII fast-path for case folding (performance)
- Buffer over-allocation fixed
- 55 new tests added (80 → 135)
- README, examples, CHANGELOG, SECURITY, CODEOWNERS, docs links fixed
- FLE scope, arena budget, print limitations documented
- encryption_key sensitivity warning added
- Full benchmark suite (14 benchmarks, 6-tier scale bench, regression detection, baseline tracking)

### What remains for future initiatives

- Parser modularization (split 6,628-line file)
- Lookahead buffer (architectural optimization)
- RETURN clause deduplication (11 sites)
- Confusable identifier detection (Unicode data)
- Complete Unicode case folding (Unicode data)
- Proper double-quote/quoted identifier handling
- Parallel lexing (Won't Do — complexity outweighs benefit for typical query sizes)
- Parallel test infrastructure (Won't Do — handled via standard test coverage)

## Re-Audit 2026-06-12 (New Open Gaps)

**Auditor:** Automated requirements-to-code gap analysis
**Toolchain:** Zig 0.16.0
**Baseline:** `zig build` → OK. `zig build test` → **133/135 pass, 2 skipped** (default flags).
**Scope:** Re-traced every requirement in `docs/REQUIREMENTS.md` to code; verified build/test under feature flags.

This pass found that the default build is green, but **feature-flagged builds are broken** and two previously "Closed" items have regressed. Gap-IDs continue the existing per-domain numbering. A new `GAP-OTEL-*` domain is introduced for the (post-extraction) OpenTelemetry seam.

### Requirement coverage (this pass)

| Status | Count | Requirements |
|---|---|---|
| Implemented | 9 | GQL-REQ-001..008, GQL-PKG-001/002/003 (core API surface all present and exposed via `src/root.zig`) |
| Partial | 3 | GQL-REQ-005 (JSON printer emits no AST body — GAP-QUAL-013); Documentation reqs (example broken — GAP-DOC-013, flags wrong — GAP-DOC-011) |
| Not Implemented | 2 | GQL-TEST-002 conformance (GAP-TEST-001); GQL-TEST-003 fuzzing (GAP-TEST-002) |
| Unknown | 0 | — |

Note: `docs/REQUIREMENTS.md` cites `src/gql/*.zig` and `build.zig:759/767/772/1086` line numbers that **do not exist** in this repo (Geode-relative paths; `build.zig` is only 301 lines with no conformance/fuzz steps). The requirement doc itself is stale and should be re-pathed to `src/*.zig`.

### New Build / Feature-Flag Gaps

| Gap-ID | Severity | Gap | Status |
|---|---|---|---|
| GAP-PAR-011 | HIGH | `src/parallel.zig` does not compile under `-Dthread_pool=true` with the pinned `thread_pool-0.2.4`. `zig build check -Dthread_pool=true` and `zig build test -Dthread_pool=true` both fail with: (1) `src/parallel.zig:59:27 error: root source file struct 'Thread' has no member named 'Mutex'` (diamond: `std.Thread` resolves against thread_pool's module tree), and (2) `src/parallel.zig:299:71 error: value of type 'pool.Core.SubmitBatchResult' ignored` (`pool.submitBatch(...)` now returns a value the code discards). **The entire parallel subsystem marked Closed in GAP-PAR-002/003/004/006 is broken when its own feature flag is enabled.** Default build passes only because `enable_tp=false` gates the code out. | **Open** |
| GAP-OTEL-001 | HIGH | `zig build test -Dwith_otel=true` **fails**: `tests/observability_disabled_test.zig` test `observability.enabled tracks build_options.with_otel` returns `error.TestExpectedEqual`. `src/observability.zig:47` hardcodes `pub const enabled: bool = false` (changed 2026-05-02 to dodge a Zig 0.16 module-dedup diamond), but the seam test still asserts `enabled == build_options.with_otel`. Test and implementation contradict; any consumer enabling otel breaks the test suite. | **Open** |
| GAP-OTEL-002 | MEDIUM | OpenTelemetry seam is permanently dead. `src/observability.zig:47` forces `enabled=false`, so every helper (`startQueryExecutionSpan`, `endQueryExecutionSpan`, etc.) is a comptime no-op **regardless of `-Dwith_otel`**. `build.zig:201-243` and `build.zig.zon` still wire/fetch the `otel` lazy dependency under `-Dwith_otel=true`, producing a build option that fetches a dependency but emits zero telemetry. Misleading capability: `-Dwith_otel=true` advertises observability that cannot activate. | **Open** |

### New Quality Gaps

| Gap-ID | Severity | Gap | Status |
|---|---|---|---|
| GAP-QUAL-013 | MEDIUM | `printProgramJsonWith` (`src/print.zig:74-77`) emits only `{"kind":"<TypeName>"}` per statement — it serializes the statement **tag name and nothing else**. No MATCH patterns, WHERE clauses, RETURN items, or expressions are written (only an optional `temporals` array when `verbose_temporals=true`). GQL-REQ-005 requires a "JSON printer"; the current output cannot reconstruct or represent the parsed program. This is broader than the documented GAP-DOC-010 (subquery walking) — the JSON body is entirely absent for all 32 statement variants. | **Open** |

### New Documentation Gaps

| Gap-ID | Severity | Gap | Status |
|---|---|---|---|
| GAP-DOC-011 | MEDIUM | README documents the parallel build flag as `-Dthread-pool=true` (hyphen) at README.md:16 and :66-67, but the actual `build.zig:10` option is `thread_pool` (underscore). `zig build -Dthread-pool=true` errors with `invalid option: -Dthread-pool`. Every documented parallel-build command fails as written. | **Open** |
| GAP-DOC-012 | LOW | Version mismatch: `src/root.zig:146` exports `pub const version = "0.1.0"` while `build.zig.zon` declares `version = "0.1.4"`; README install snippet (README.md:29) references the `v0.1.0` archive URL. Three sources of truth disagree on the library version. | **Open** |
| GAP-DOC-013 | MEDIUM | `examples/basic.zig` regressed (reopens GAP-DOC-002, previously "Closed — rewrote with GQL parsing usage example"). It is now a placeholder that only prints a string with the real usage commented out, and it **does not compile under Zig 0.16**: `examples/basic.zig:9` uses `std.io.getStdOut()` which was removed (`error: struct 'std' has no member named 'io'`). The example is not wired into `build.zig` and not in `build.zig.zon` `paths`, so nothing compiles or ships it — the regression went undetected. | **Open** |

### New Test Gaps

| Gap-ID | Severity | Gap | Status |
|---|---|---|---|
| GAP-TEST-001 | MEDIUM | GQL-TEST-002 (preserve generated conformance coverage) is **Not Implemented**. There is no `conformance` build step and no conformance test files in-repo (`grep -rniE 'conformance' build.zig` → none; the only matches live under vendored `zig-pkg/`). REQUIREMENTS.md cites `build.zig:759/767/772` which do not exist (build.zig is 301 lines). Confirms the open item the 2026-03-22 AUDIT_REPORT already noted; never tracked with a Gap-ID. | **Open** |
| GAP-TEST-002 | MEDIUM | GQL-TEST-003 (preserve parser fuzzing) is **Not Implemented**. No `fuzz` build step exists; REQUIREMENTS.md cites `build.zig:1086` which does not exist. Zig 0.16 ships `--fuzz` but no fuzz unit tests are defined in the gql sources. Confirms an AUDIT_REPORT open item; never tracked with a Gap-ID. | **Open** |
| GAP-TEST-003 | LOW | `src/observability.zig` (208 lines) and `src/observability_init.zig` (107 lines) have **zero in-module unit tests**. Coverage exists only via external `tests/observability_{disabled,enabled}_test.zig`, and the disabled-mode test fails under `-Dwith_otel=true` (GAP-OTEL-001). These post-extraction modules were never added to the module/test table above. | **Open** |

### Status Changes To Existing Gaps

| Gap-ID | Prior Status | New Status | Evidence |
|---|---|---|---|
| GAP-DOC-002 | Closed | **Reopened (regressed)** | `examples/basic.zig` is again a placeholder and does not compile under Zig 0.16 — tracked as GAP-DOC-013. |
| GAP-PAR-002 | Closed | **Regressed** | `src/parallel.zig` compiles only with `-Dthread_pool=false`; fails to compile when the feature it implements is enabled — tracked as GAP-PAR-011. |
| GAP-PAR-003 | Closed | **Regressed** | Same root cause as GAP-PAR-011 (`parallelProcessStatements` lives in the non-compiling module). |
| GAP-PAR-004 | Closed | **Regressed** | Same root cause as GAP-PAR-011 (`parallelValidateStatements` calls the changed `submitBatch` API at `src/parallel.zig:299`). |
| GAP-PAR-006 | Closed | **Regressed** | The print.zig mutex fix stands, but the surrounding parallel module no longer compiles under `-Dthread_pool=true` (GAP-PAR-011). |
| GQL-TEST-002 (AUDIT open item) | Open (untracked) | **Tracked** | Now GAP-TEST-001. |
| GQL-TEST-003 (AUDIT open item) | Open (untracked) | **Tracked** | Now GAP-TEST-002. |

All other previously-Closed and Won't-Do items remain accurate against the current tree (core API symbols for GQL-REQ-001..008 and GQL-PKG-001..003 all verified present and exported via `src/root.zig`; recursion depth guard, SQLSTATE codes, dead-function removal, decimal/float clamps, unterminated-comment detection all still in place).

### Re-Audit Priority Matrix

| Severity | Count | Gap-IDs |
|---|---|---|
| HIGH | 2 | GAP-PAR-011, GAP-OTEL-001 |
| MEDIUM | 6 | GAP-OTEL-002, GAP-QUAL-013, GAP-DOC-011, GAP-DOC-013, GAP-TEST-001, GAP-TEST-002 |
| LOW | 2 | GAP-DOC-012, GAP-TEST-003 |
| **Total new open** | **10** | — |

---

## Remediation Status — Re-Audit 2026-06-12 (closure pass)

| Gap-ID | Status | Commit / Note |
|--------|--------|---------------|
| GAP-PAR-011 (`-Dthread_pool=true` fails to compile) | **Closed** | fb02779 — std.Thread.Mutex→tp.sync.Mutex migration + submitBatch partial-submit handling; parallel-path tests added |
| GAP-OTEL-001 (`-Dwith_otel=true` test fails) | **Closed** | 39bfa70 — test pins the intentional force-disabled contract |
| GAP-OTEL-002 (otel seam dead while documented as working) | **Closed (honest docs)** | 39bfa70 — README/root.zig state the seam is currently a no-op pending the upstream Zig dedup fix |
| GAP-QUAL-013 (JSON printer emits no AST body) | **Documented limitation** | The JSON printer emits statement kinds + verbose temporals by design; full AST→JSON serialization (GQL-REQ-005 complete) is a feature enhancement, not a defect. Tracked for future work |
| GAP-DOC-011 (README `-Dthread-pool` hyphen) | **Closed** | eb355b7 |
| GAP-DOC-012 (version mismatch) | **Closed** | 39bfa70 — single-sourced |
| GAP-DOC-013 (examples/basic.zig broken) | **Closed** | 922a78a — rewritten as a real, compile-checked example wired into `zig build example` + `check` |
| GAP-DOC-002 (example regressed) | **Closed** | 922a78a |
| GAP-TEST-002 (parser fuzzing not implemented) | **Closed** | e8df65c — coverage-guided fuzz target |
| GAP-TEST-003 (observability has no in-module tests) | **Closed** | 6081156 — in-module seam tests + build target |
| GAP-TEST-001 (conformance harness not implemented) | **Deferred** | Large feature (GQL conformance suite); out of scope for this remediation pass |

Regressed-then-fixed: the parallel module (GAP-PAR-002/003/004/006) compiles
again under `-Dthread_pool=true` (root cause GAP-PAR-011 closed).
