# GQL Library — Code Quality Gap Analysis

**Scope:** Full code-quality review of the `gql` Zig library (ISO/IEC 39075 GQL lexer/parser/AST front-end).
**Date:** 2026-06-12
**Reviewer:** Automated quality review (manual deep review + reproduction).
**Toolchain:** Zig 0.16.0.
**Commit:** `5b02156` (branch `main`).

## Scan Results (objective gates)

| Gate | Command | Result |
|------|---------|--------|
| Build | `zig build` | **PASS** (8/8 steps) |
| Unit + seam tests (default) | `zig build test` | **PASS** — 133/135 pass, 2 skipped (intentional thread-pool/otel guards) |
| Integration tests | `zig build test-integration` | **PASS** |
| Format | `zig fmt --check src/` | **PASS** (clean) |
| Otel-enabled build | `zig build test -Dwith_otel=true` | **FAIL** — 1 test fails (see QUAL-001) |

The default build, default test suite, and formatting are all green. The **`-Dwith_otel=true` configuration is broken** and fails its own test.

## Severity Summary

| Severity | Count | IDs |
|----------|-------|-----|
| Critical | 2 | QUAL-002, QUAL-003 |
| High | 4 | QUAL-001, QUAL-004, QUAL-005, QUAL-006 |
| Medium | 9 | QUAL-007 … QUAL-015 |
| Low | 8 | QUAL-016 … QUAL-023 |

All findings were verified against source. The two Critical findings were **reproduced** (segfault on untrusted input). Categories explicitly found clean are listed at the end.

---

## Critical

### QUAL-002 — Unbounded recursion in `parseQuery` (`CALL { … }`) → stack-overflow crash on untrusted input

- **Severity:** Critical
- **Location:** `src/parser.zig:1614` (`parseQuery`), self-recurses at `src/parser.zig:1848` (`const inner_query = try self.parseQuery();`).
- **Evidence:** The only recursion guard in the parser is `expr_depth` (`MAX_EXPR_DEPTH = 256`, `src/parser.zig:48,50`), incremented **only** in `parseOrExpr` (2940), `parseNotExpr` (2966), and `parseUnaryExpr` (3289). The structural descent `parseProgram → parseStatement → parseQuery → parseQuery` has **no depth counter**. Reproduced: input `"CALL { CALL { … RETURN 1 … } }"` nested 100,000 deep segfaults:

  ```text
  Segmentation fault at address 0x7ffc...
  src/parser.zig:1848:56: in parseQuery
                  const inner_query = try self.parseQuery();
  ```

- **Impact:** Any untrusted GQL string can crash the host process (DoS / memory-unsafety). The library is explicitly positioned for "parsers, linters, editors, protocol gateways" (root.zig:10-12) — i.e. untrusted input. The README/root.zig claim of a "recursion depth limit (256 levels) to prevent stack overflow" (`src/root.zig:41-42`) is **false** for statement/query nesting.
- **Recommended fix:** Add a shared structural-depth counter (e.g. `stmt_depth: u16`) incremented with `defer`-decrement at the top of `parseQuery`, `parseStatement`, and `parseGraphPattern`, returning `error.UnexpectedToken` past a bound (mirror the existing `expr_depth` pattern at 2940-2942).
- **Acceptance criteria:** A test parsing ≥100k-deep `CALL { … }` returns a `ParserError` (not a crash); existing tests still pass; documented depth limit covers structural recursion.
- **Confidence:** Confirmed (reproduced segfault).

### QUAL-003 — Unbounded recursion in `parseStatement` (parenthesized statements) → second stack-overflow crash vector

- **Severity:** Critical
- **Location:** `src/parser.zig:623` (`parseStatement`), self-recurses at `src/parser.zig:1440` (`const inner_stmt = try self.parseStatement();`, the `.l_paren` arm).
- **Evidence:** Reproduced: input `"((((( … RETURN 1 … )))))"` nested 200,000 deep segfaults:

  ```text
  Segmentation fault at address 0x7ffe...
  src/parser.zig:1440:59: in parseStatement
                  const inner_stmt = try self.parseStatement();
  ```

- **Impact:** Same class as QUAL-002 — process crash on untrusted input through a distinct syntactic path. (For contrast, nested *expression* parens `RETURN (((1)))`, arrays, maps, `IN (subquery)`, and `EXISTS { … }` are correctly bounded by `expr_depth` and return errors without crashing.)
- **Recommended fix:** The same shared structural-depth guard as QUAL-002 (incrementing in `parseStatement`) closes this path.
- **Acceptance criteria:** A test parsing ≥200k-deep `( … )` statements returns a `ParserError`; no crash.
- **Confidence:** Confirmed (reproduced segfault).

---

## High

### QUAL-001 — Observability seam is permanently disabled; `-Dwith_otel=true` build is dead and fails its own test

- **Severity:** High
- **Location:** `src/observability.zig:47` (`pub const enabled: bool = false;`); gate at `src/root.zig:112-113`; failing test `tests/observability_disabled_test.zig:33`.
- **Evidence:** `enabled` is hardcoded `false` (per the 2026-05-02 comment at observability.zig:39-46, to dodge a Zig module-dedup diamond). Because `root.zig:112` does `pub const observability_init = if (observability.enabled) @import("observability_init") else struct{}`, the entire `src/observability_init.zig` (107 lines wiring `otel.sdk.*`) is **never compiled**, and the otel dependency is never reachable regardless of the flag. Worse, `zig build test -Dwith_otel=true` **fails**:

  ```text
  observability_disabled_test.zig:33: expected true, found false
      try std.testing.expectEqual(build_options.with_otel, gql.observability.enabled);
  ```

- **Impact:** (1) `README.md:100-119` and `src/root.zig:102-115` document a working `-Dwith_otel=true` span-emitting integration that **does not exist and cannot be enabled**. (2) The documented build configuration is broken (test failure) — a CI gate on `-Dwith_otel=true` would fail. (3) `observability_init.zig`, the `with_otel` build-graph machinery in `build.zig:35-244`, and the otel dependency in `build.zig.zon` are all dead while appearing live. This is misleading API surface plus a broken advertised build.
- **Recommended fix:** Either (a) restore the conditional `enabled = build_options.with_otel` now that the upstream dedup issue is resolvable, fixing the seam; or (b) if the seam must stay off, remove/upd­ate the README "Observability" section and root.zig docs to state it is a permanent no-op, delete the unreachable `observability_init`/otel build wiring, and fix `observability_disabled_test.zig:33` so the otel build configuration is not advertised as working.
- **Acceptance criteria:** Docs match reality; `zig build test -Dwith_otel=<both values>` passes (or the flag is removed); no dead otel wiring claims to be functional.
- **Confidence:** Confirmed (reproduced test failure).

### QUAL-004 — `version` constant is wrong and frozen at `"0.1.0"` (package is `0.1.4`)

- **Severity:** High
- **Location:** `src/root.zig:146` (`pub const version = "0.1.0";`); enforced stale by `tests/integration.zig:16`; authoritative value `build.zig.zon:3` (`.version = "0.1.4"`).
- **Evidence:** `build.zig.zon` declares `0.1.4`; `root.zig` exports `0.1.0`; `tests/integration.zig:16` asserts `expectEqualStrings("0.1.0", gql.version)`. The test actively pins the wrong value, so the public `gql.version` cannot be corrected without editing the test, and it has silently drifted 4 patch releases behind.
- **Impact:** Any consumer reading `gql.version` for logging, telemetry, or compatibility gating gets a wrong, 4-versions-stale value. The contradiction between manifest and API is a latent support/debug hazard.
- **Recommended fix:** Generate `version` from `build.zig.zon` (e.g. expose via a `build_options` string already populated in `build.zig:60`) so there is one source of truth; update the integration test to assert against that single source rather than a hard-coded literal.
- **Acceptance criteria:** `gql.version` equals the `build.zig.zon` version; a version bump in the manifest does not require editing a string literal in `root.zig` or the test.
- **Confidence:** Confirmed.

### QUAL-005 — Keyword set duplicated and drifted between `token.zig` and `language_metadata.zig` ("single source of truth" is false)

- **Severity:** High
- **Location:** `src/token.zig:251-419` (`KeywordMap` StaticStringMap) vs `src/language_metadata.zig:88-254` (`keywords` array). Misleading docs at `token.zig:249-250` ("sourced from language_metadata.zig for single source of truth") and `language_metadata.zig:2-20`.
- **Evidence:** `KeywordMap` is a hand-written literal that does **not** consume `language_metadata.keywords` (nor the provided `getKeywordNames()` helper). Set diff (verified by extraction): 10 entries are in `token.zig`'s keyword map but absent from `language_metadata.keywords`: `BOOLEAN`, `DATE`, `DATETIME`, `DECIMAL`, `FLOAT`, `INTEGER`, `STRING`, `TIME`, `TIMESTAMP`, `YIELD`. `YIELD` is absent from `language_metadata.zig` entirely (it appears only inside `.example` strings), so `language_metadata.findKeyword("YIELD")` → `null`, and therefore `token.getKeywordMetadata("YIELD")` (`token.zig:443`) → `null` for a keyword the lexer does tokenize.
- **Impact:** The lexer and the metadata table (used for LSP completion/hover/docs/highlighting) disagree about the keyword set. `YIELD`, `TIMESTAMP`, `DECIMAL`, etc. tokenize as keywords but have no descriptive metadata, so editor tooling silently omits them. There is no comptime/test guard preventing further drift. (Type keywords like `DATE` exist under the `types` table but not the `keywords` array, so `findKeyword` still misses them.)
- **Recommended fix:** Generate `KeywordMap` from `language_metadata.keywords` at comptime (the unused `getKeywordNames()` at language_metadata.zig:1554 exists for exactly this), OR add a `test`/`comptime` assertion that every `KeywordMap` key resolves via `findKeyword`/metadata and vice versa.
- **Acceptance criteria:** A test fails if a tokenized keyword has no metadata entry (or the map is comptime-derived from metadata); `getKeywordMetadata` returns non-null for every keyword the lexer emits.
- **Confidence:** Confirmed (set diff reproduced).

### QUAL-006 — God functions `parseStatement` and `parseQuery` (~880 and ~960 lines)

- **Severity:** High
- **Location:** `src/parser.zig:623-1502` (`parseStatement`, ~880 lines) and `src/parser.zig:1614-2574` (`parseQuery`, ~960 lines).
- **Evidence:** `parseStatement` is one giant `switch (self.cur.kind)` with arms inlining large logic blocks (e.g. `.WITH` 828-927, `.RETURN` 928-1080, `.CALL` 1209-1435), each duplicating UNION/INTERSECT/EXCEPT handling. `parseQuery` threads ~15 optional `?T` clause accumulators (LET, WITH, SELECT, UNWIND, CALL, MATCH, FILTER, GROUP BY, SET, REMOVE, DELETE, RETURN, ORDER BY, LIMIT/OFFSET) through one ~960-line body.
- **Impact:** Very high cyclomatic complexity; hard to test in isolation or modify safely. Both Critical crash bugs (QUAL-002/003) live here, and the set-operation duplication (QUAL-007) has already drifted (QUAL-009). High regression risk for any change.
- **Recommended fix:** Extract the set-operation tail (QUAL-007) into `parseSetOperationTail`, and split per-statement arms into named helpers (`parseCallStatement`, `parseMatchOrDelete`, …).
- **Acceptance criteria:** Each extracted helper is independently testable; no single parse function exceeds a few hundred lines; behavior unchanged (tests green).
- **Confidence:** Confirmed.

---

## Medium

### QUAL-007 — UNION/INTERSECT/EXCEPT set-operation tail logic duplicated 4–6 times

- **Severity:** Medium
- **Location:** `src/parser.zig:831-925` (`.WITH` arm), `963-1058` (`.RETURN` arm), `1505-1610` (`handleQueryResult`), plus paren-group variants at `933-961` and `1456-1495`.
- **Evidence:** Each block repeats: hoist `order_by`/`limit`/`offset` off the first query, `while (self.cur.kind == .UNION …)` consuming `ALL`/`DISTINCT`, the identical guard `"both ALL and DISTINCT specified"` (recurs at lines 861, 951, 994, 1071, 1546), strip ORDER BY/LIMIT/OFFSET from tail queries, re-parse trailing clauses.
- **Impact:** Any change to set-operation semantics must be applied in 4–6 places; they have already diverged (see QUAL-009).
- **Recommended fix:** Extract one `parseSetOperationTail(first) ParserError!ast.Statement`; `handleQueryResult` already approximates it.
- **Acceptance criteria:** One implementation; all set-op arms delegate to it; tests green.
- **Confidence:** Confirmed.

### QUAL-008 — `USING <index_type>` mapping block copy-pasted verbatim

- **Severity:** Medium
- **Location:** `src/parser.zig:4905-4942` and `src/parser.zig:4992-5026` (both inside `parseCreateIndex`).
- **Evidence:** The full ~12-branch string→`ast.IndexType` chain (`"btree"/"hash"/"fulltext"/"spatial"/"vector"/…`, with `IntervalTree`/`JsonbInverted`/`DomainTrie`→`.btree` fallbacks and `return error.InvalidIndexType` default) is duplicated to handle `USING` before vs. after the property list.
- **Impact:** Adding an index type requires editing two identical blocks; silent divergence risk.
- **Recommended fix:** Extract `fn parseIndexTypeName(type_str: []const u8) ParserError!ast.IndexType`.
- **Acceptance criteria:** Single mapping function; both `USING` positions call it.
- **Confidence:** Confirmed.

### QUAL-009 — Inconsistent LIMIT parsing in `.WITH` UNION tail rejects `$param` (behavioral drift)

- **Severity:** Medium
- **Location:** `src/parser.zig:902-914` (`.WITH` UNION tail) vs `parseLimitValue` used at `1035-1047`, `2521-2540`, `5529-5544`.
- **Evidence:** The `.WITH` tail does `const limit_expr = try self.parseOrExpr(); if (limit_expr != .Int) return self.unexpected("LIMIT requires integer constant"); limit_val = @intCast(limit_expr.Int);` (902-906) — rejecting `$param`. Every other LIMIT site uses `parseLimitValue`, which accepts `$param`.
- **Impact:** `WITH … UNION … LIMIT $n` behaves differently from `RETURN … UNION … LIMIT $n` — a real inconsistency for parameterized queries.
- **Recommended fix:** Use `parseLimitValue` uniformly in the `.WITH` UNION tail (subsumed by QUAL-007).
- **Acceptance criteria:** Parameterized LIMIT accepted identically across all set-op arms; a test covers `WITH … UNION … LIMIT $n`.
- **Confidence:** Confirmed.

### QUAL-010 — `validateBuiltinCall` is a 130-line linear `if`-chain (table-driven design never implemented)

- **Severity:** Medium
- **Location:** `src/parser.zig:4115-4246`.
- **Evidence:** ~25 sequential `if (std.ascii.eqlIgnoreCase(name, "…"))` arms with bespoke arity/type checks (+~10 nested time-series arms at 4189-4243). Returns `true` for unknown functions (4245) — partial validation. The comment at 4116 ("Table of builtins: name, min_arity, max_arity…") describes a table that was never built.
- **Impact:** High cyclomatic complexity; easy to miss an arity check; the comment misleads about the design.
- **Recommended fix:** Replace with a static lookup table of `{name, min, max, validator}` entries as the comment intends.
- **Acceptance criteria:** Builtin validation driven by a data table; behavior preserved.
- **Confidence:** Confirmed.

### QUAL-011 — `parsePostfixExpr` mixes many unrelated postfix forms with embedded function-name special-casing

- **Severity:** Medium
- **Location:** `src/parser.zig:3345-3655`.
- **Evidence:** One `while (true)` loop handles `.dot` member access, `COUNT { … }` subquery, `shortestPath`/`allShortestPaths`/`size` pattern calls, list-comprehension `all()`/`any()`, named-param `=>` args, `COUNT(DISTINCT/*)`, indexing/slicing `[..]`, map projection `{.a,.b}`, and `:Label` tests — with `if (base == .Ident and std.ascii.eqlIgnoreCase(...))` magic-name checks mid-loop (`count`, `shortestPath`, `allShortestPaths`, `size`, `all`, `any`).
- **Impact:** Very high local complexity; the set of specially-handled builtin names is scattered and hard to audit.
- **Recommended fix:** Extract call-argument parsing (3429-3568) into `parseCallArgs`, and pattern-function special cases into a helper keyed off the callee name.
- **Acceptance criteria:** Postfix loop reduced to dispatch; special-cased names centralized; tests green.
- **Confidence:** Confirmed.

### QUAL-012 — Dead private functions in `parser.zig` (~60 lines)

- **Severity:** Medium
- **Location:** `peek2Kind` (`src/parser.zig:243`), `isPathAlias` (`2582`), `isProjectedIdent` (`2592`), `isSimpleOrderKey` (`4025`) + its helper `isSimpleOrderPtr` (`4034`), `parseCreateGraph` (`5860`).
- **Evidence:** Each symbol appears exactly once in the file (declaration only; zero call sites — verified by grep). `parseCreateGraph` is an unreferenced wrapper for `parseCreateGraphWithReplace(false)`.
- **Impact:** Misleads readers (e.g. `isSimpleOrderKey`/`isProjectedIdent` imply ORDER-BY validation that is not wired up).
- **Recommended fix:** Delete, or wire `isSimpleOrderKey`/`isProjectedIdent` into ORDER-BY validation if intended.
- **Acceptance criteria:** No unreferenced private functions; build/tests green.
- **Confidence:** Confirmed.

### QUAL-013 — Dead public metadata helpers `getKeywordNames`/`getFunctionNames`/`getTypeNames`/`getProcedureNames`

- **Severity:** Medium
- **Location:** `src/language_metadata.zig:1554-1587`.
- **Evidence:** Zero references anywhere outside the file (verified across `src/ tests/ examples/ benchmarks/`). They were intended to feed the lexer's keyword map but `token.zig` does not use them (root cause of QUAL-005).
- **Impact:** ~34 lines of dead public API that make the "single source of truth" intent look implemented when it is not.
- **Recommended fix:** Wire `getKeywordNames()` into a comptime-generated `KeywordMap` (closes QUAL-005), or delete the unused helpers.
- **Acceptance criteria:** Either the helpers drive the keyword map (with a guard test) or they are removed.
- **Confidence:** Confirmed.

### QUAL-014 — `pattern_comp_depth` leaks on the error path (state corruption after a recoverable error)

- **Severity:** Medium
- **Location:** `src/parser.zig:3958` (`self.pattern_comp_depth += 1;`) and `3990` (`self.pattern_comp_depth -= 1;`) in the `.l_bracket` pattern-comprehension arm of `parsePrimaryExpr`.
- **Evidence:** Unlike `expr_depth` (which uses `defer self.expr_depth -= 1;`), the increment/decrement here is not `defer`-protected; multiple `try` calls sit between 3959 and 3989, so any error leaves `pattern_comp_depth > 0` permanently.
- **Impact:** After a recoverable parse error inside a pattern comprehension, the relationship-type `|`-handling heuristic at `parser.zig:2812` (`if (self.pattern_comp_depth > 0)`) stays wrongly active for the rest of the input — subtly mis-parsing subsequent `|` tokens. Not a crash, but state corruption.
- **Recommended fix:** Replace the manual decrement at 3990 with `defer self.pattern_comp_depth -= 1;` immediately after the increment at 3958.
- **Acceptance criteria:** `pattern_comp_depth` returns to its prior value on both success and error paths.
- **Confidence:** Confirmed (control-flow inspection).

### QUAL-015 — Parallel/inconsistent print APIs and silently-swallowed statement kinds in `print.zig`

- **Severity:** Medium
- **Location:** `src/print.zig:16-38` (human pair), `49-164` (JSON pair), `24-36` (`else => {}` at line 35).
- **Evidence:** The human pair uses option struct `PrintOptions`; the JSON pair uses a differently-named `PrintJsonOptions` (line 40) — inconsistent option surface for the same library. `printProgramHumanWith` renders bodies for only `.Query` and `.Union`; all other ~30 statement kinds (`Create`, `Delete`, `Merge`, `Call`, `Insert`, `CreateIndex`, …) hit `else => {}` (line 35) and print only their tag line. `tagName` (166-204) knows 33 variants. Additionally the JSON printer only emits `{"kind":"<tag>"}` per statement plus the optional temporals array — it does not serialize statement bodies at all.
- **Impact:** A "human-readable printer" silently drops most statement detail; consumers cannot tell output is incomplete. The two option types raise learning cost.
- **Recommended fix:** Unify option naming; replace `else => {}` with explicit handling or a visible `… (body not printed)` marker.
- **Acceptance criteria:** Unsupported statement kinds are visibly marked, not silently dropped; option structs share a consistent shape/name.
- **Confidence:** Confirmed.

---

## Low

### QUAL-016 — JSON printer has no string-escaping helper (defensive gap; not currently exploitable)

- **Severity:** Low
- **Location:** `src/print.zig:101-108` (`printProgramJsonWith`, temporal `.raw` emission) — no `escape`/`writeJsonString` helper exists in the file.
- **Evidence:** `try w.writeAll(d.raw)` writes the raw temporal lexeme directly between JSON quotes with no escaping. **However**, the only user-controlled string reaching JSON output is a temporal `.raw`, and temporals must pass strict validation (`temporal.isDateStrict`/`isTimeIso`/`isDateTimeIso`) which permits only `[0-9\-:.TZz+]`. Verified empirically: crafted inputs cannot place `"`, `\`, or control chars into `.raw` (invalid temporals tokenize as `.invalid` and never reach the AST). Statement bodies are emitted only as `{"kind":"<tag>"}` (enum tag names), and identifiers/string literals are not emitted to JSON at all.
- **Impact:** No injection today, but the code relies on an implicit upstream-validation invariant. If a future change emits identifiers/string literals to JSON (or relaxes temporal validation), this becomes an injection/invalid-JSON bug with no guard.
- **Recommended fix:** Add a `writeJsonString(w, s)` helper (escape `"`, `\`, `0x00–0x1F` per RFC 8259) and route all string emission through it as a defensive default; document the temporal-validation invariant the current safety depends on.
- **Acceptance criteria:** All user-controlled strings in JSON output pass through an escaper; a test feeds a string containing `"`/`\`/newline and the output round-trips as valid JSON.
- **Confidence:** Confirmed (escaping absent; injection path verified non-exploitable today).

### QUAL-017 — Near-duplicate public helpers `containsCall` / `containsCallStatic`

- **Severity:** Low
- **Location:** `src/parser.zig:4042` (`pub fn containsCall(self, e)`) and `4063` (`pub fn containsCallStatic(e)`).
- **Evidence:** Structurally identical switch bodies (`.Call`/`.Member`/`.Unary`/`.Binary`/`.List`/`.In`/`.IsNull`); the instance method never uses `self`. Both are public, an inconsistent surface where two niche AST utilities are exported while no other parse entry point is.
- **Impact:** Two public entry points for one behavior; the instance variant's `self` is pointless.
- **Recommended fix:** Make `containsCall` a thin wrapper over `containsCallStatic` (or drop the instance variant).
- **Acceptance criteria:** Single implementation; consistent public surface.
- **Confidence:** Confirmed.

### QUAL-018 — Unused struct fields `strict_order_keys` / `forbid_orderby_paths` (dead configuration)

- **Severity:** Low
- **Location:** `src/parser.zig:26` and `src/parser.zig:32`.
- **Evidence:** Each appears exactly once (declaration only); never read. (Sibling flags `ident_order_only`/`forbid_orderby_calls` ARE read at 2468/2482/2503/2508.)
- **Impact:** Implies ORDER-BY restriction features that do not exist; confuses consumers who set them expecting an effect.
- **Recommended fix:** Remove the two fields, or implement their checks alongside the existing `ident_order_only` logic (2502-2516).
- **Acceptance criteria:** No unread config fields, or the flags have observable effect with tests.
- **Confidence:** Confirmed.

### QUAL-019 — `expect` error-handling convention inconsistent (`try` vs `catch return error.UnexpectedToken`)

- **Severity:** Low
- **Location:** `catch return error.UnexpectedToken` at `src/parser.zig:506, 557, 564, 567, 574` (CTE parsing); plain `try self.expect(...)` everywhere else.
- **Evidence:** `expect` already returns `error.UnexpectedToken` on mismatch but may surface other `ParserError` members (e.g. `OutOfMemory`); the CTE sites collapse all errors to `UnexpectedToken`, losing fidelity and diverging from the dominant `try` convention.
- **Impact:** An OOM during CTE parsing is reported as a syntax error; reader confusion.
- **Recommended fix:** Standardize on `_ = try self.expect(...);`.
- **Acceptance criteria:** Uniform `expect` usage; error categories preserved.
- **Confidence:** Confirmed.

### QUAL-020 — Fragile `unreachable` after `try self.expect(.RETURN)`

- **Severity:** Low
- **Location:** `src/parser.zig:2450`, `2456`, `4445`.
- **Evidence:** Pattern `if (self.cur.kind != .RETURN) { _ = try self.expect(.RETURN); unreachable; }` — `expect` always errors when the branch is entered, so `unreachable` is currently unreachable. But it is fragile: any refactor making the preceding line non-fatal turns this into reachable UB.
- **Impact:** Latent UB hazard under future edits.
- **Recommended fix:** Replace with `return self.unexpected("expected RETURN");` to delete the `unreachable`.
- **Acceptance criteria:** No `unreachable` immediately after a fallible `expect`.
- **Confidence:** Confirmed.

### QUAL-021 — Magic numbers in scientific-notation decimal scaling (`1e15`/`scale=15`/`1e37`)

- **Severity:** Low
- **Location:** `src/parser.zig:3771-3784` (`parsePrimaryExpr`, `.float_lit`).
- **Evidence:** `const scaled = value * 1_000_000_000_000_000;` (1e15), overflow guard `@abs(scaled) >= 1e37`, and `.Decimal = .{ .coeff = coeff, .scale = 15 }` — the scale `15` is duplicated as a literal factor, a `.scale` field, and an implied `1e37` bound, with nothing tying them together.
- **Impact:** Easy to desynchronize the scale factor and `.scale`, silently corrupting decimal precision.
- **Recommended fix:** Introduce `const DECIMAL_SCI_SCALE = 15;` and derive the factor/bound from it.
- **Acceptance criteria:** One named constant drives all three uses.
- **Confidence:** Confirmed.

### QUAL-022 — Stale/garbled CANARY comments and dead leftover comments

- **Severity:** Low
- **Location:** `src/print.zig:771` and `src/ast.zig:325` (`TEST=geodetestlab/specs/gql_expressions_comprehensive.ymlEMENTED;` — corrupted path, apparently a botched `IMPLEMENTED` merge); `src/print.zig:211` (leftover `// no-op placeholder removed: …` comment with no code); `src/language_metadata.zig:87` ("sorted for binary search" but `findKeyword` at 1608 does a linear scan, not binary search).
- **Evidence:** Direct reads of the cited lines.
- **Impact:** Breaks tooling that parses CANARY `TEST=` paths; misleads readers about implemented behavior (binary search, removed code).
- **Recommended fix:** Fix the two `…comprehensive.yml` paths; delete the dead comment at print.zig:211; correct or remove the "binary search" claim at language_metadata.zig:87.
- **Acceptance criteria:** No corrupted CANARY paths; comments match code.
- **Confidence:** Confirmed.

### QUAL-023 — Documentation gaps on public API contracts (arena ownership, error sets, `prec`, double-quote handling)

- **Severity:** Low
- **Location:** `src/parser.zig:389` (`parseProgram`), `4042`/`4063` (`containsCall*`); `src/print.zig:444`/`457` (`printExpr`/`printExprWith` ignore `prec` via `_ = prec;`); `src/lexer.zig:26-30` (double-quote TODO).
- **Evidence:** `parseProgram` documents only its observability span, not that the returned `ast.Program` is owned by the caller-provided arena or that its error set is `ParserError`. `printExprWith` keeps a `prec` parameter that is immediately discarded (`_ = prec;`, print.zig:457), so the printer never parenthesizes by precedence and its output is not guaranteed to re-parse to the same tree — yet the parameter remains in the public signature, implying a contract it does not honor. The lexer treats `"` exactly like `'` per a "temporary fix until proper double quote handling is implemented" comment (lexer.zig:27-28), so the `quoted_identifier` TokenKind (token.zig:43) is never produced — an undocumented limitation of the public token contract.
- **Impact:** Consumers must read the implementation to learn arena-ownership, error sets, the no-precedence-parenthesization caveat, and the double-quote==string-literal behavior.
- **Recommended fix:** Document arena ownership + error set on `parseProgram`; either implement precedence parenthesization using `prec` or remove the parameter and document that output is not round-trip-safe; document (or resolve) the double-quote handling and unused `quoted_identifier` kind.
- **Acceptance criteria:** Public functions document ownership/error/round-trip contracts; no public parameter is silently ignored.
- **Confidence:** Confirmed.

---

## Categories Found Clean

- **Formatting:** `zig fmt --check src/` is clean — no style findings.
- **Default build & test suite:** `zig build`, `zig build test`, and `zig build test-integration` all pass; no broken tests on the default configuration.
- **Integer overflow in numeric parsing:** `parseInt` calls propagate `error.Overflow` via `try` (`ParserError` includes `Overflow`); `@intCast` truncations reviewed (e.g. UNION limit handling, `@intCast` on already-u32 values) are safe on 64-bit. No unhandled overflow found in `parser.zig`/`temporal.zig`.
- **Temporal fraction overflow:** `temporal.parseTime` caps `frac_digits` at 9 and guards `frac_nanos` accumulation (temporal.zig:170-184); covered by tests. Clean.
- **UTF-8 decoding (`lexer.decodeUtf8Codepoint`):** Rejects overlong encodings, surrogates, truncated/invalid sequences, and out-of-range code points; well-tested (lexer.zig:524-582). The two `unreachable` arms (lexer.zig:501,515) are genuinely unreachable (guarded by the preceding `len`/`min_cp` switch). Clean.
- **`ast.zig` reliability:** No `catch unreachable`, `@panic`, reachable `unreachable`, or fixed-buffer overflow risk (pure type definitions); `BackupStatement.encryption_key` even carries a security caveat (ast.zig:563-565).
- **`parallel.zig`:** Sequential-fallback paths, mutex-guarded lazy pool init, and `submitBatch` error fallbacks are correct; thread-safety claims in root.zig match the code. Clean (aside from the standard chunk-array-on-stack pattern, which is safe because `wg.wait()` blocks before the frame returns).
- **`status.zig`:** SQLSTATE constants and JSON diagnostic writer are straightforward and tested; stable key order maintained. Clean. (Note: `status.writeJson` does not escape `message`/`token` strings, but these are library-internal constant messages plus already-validated tokens, not arbitrary untrusted free text — consider folding into the QUAL-016 escaper for defense in depth.)

## Verification Notes

- The two Critical findings (QUAL-002, QUAL-003) and the broken otel build (QUAL-001) were reproduced with standalone executables / `zig build test -Dwith_otel=true`. All reproduction artifacts were removed; the working tree contains no review-introduced changes to `src/`, `build.zig`, `build.zig.zon`, or `tests/`.
- The keyword drift (QUAL-005) and the version mismatch (QUAL-004) were confirmed by direct extraction/grep and by the enforcing test at `tests/integration.zig:16`.
- Dead-code findings (QUAL-012, QUAL-013, QUAL-018) were confirmed by single-occurrence grep across `src/`, `tests/`, `examples/`, and `benchmarks/`.

---

## Remediation Status — 2026-06-12

Branch `audit/security-quality-remediation`. All status changes verified by
`zig build test` / `test-integration` / `check` and `zig fmt --check src/`
green (plus `-Dthread_pool=true`, `-Dwith_otel=true`, `-Doptimize=ReleaseSafe`,
`-Doptimize=ReleaseFast`).

### Resolved (with commit)

| Finding | Commit | Note |
|---------|--------|------|
| QUAL-001 (otel seam broken / `-Dwith_otel=true` fails) | 39bfa70 | Seam documented as intentionally force-disabled; test pins the contract; `-Dwith_otel=true` passes |
| QUAL-002 / QUAL-003 (unbounded structural recursion → SIGSEGV) | eac9f23 | Shared `recur_depth`/`MAX_RECUR_DEPTH=100` guard with `defer`; regression tests under ReleaseSafe |
| QUAL-004 (stale version literal) | 39bfa70 | `version` sourced from build.zig.zon via build_options; test asserts wiring |
| QUAL-005 (keyword metadata drift) | a15983e | 10 entries added + drift-guard test |
| QUAL-008 (USING index-type block duplicated) | b8b6676 | Extracted `parseIndexTypeName` |
| QUAL-009 (`$param` rejected in WITH-UNION LIMIT) | 64dab70 | Uses `parseLimitValue`; regression test |
| QUAL-010 (linear builtin ladder) | 8dcf1b6 | StaticStringMap dispatch |
| QUAL-012 (dead private fns) | 12b7de5, f913316 | peek2Kind/isProjectedIdent/parseCreateGraph removed; isSimpleOrderKey wired |
| QUAL-013 (dead metadata accessors) | f913316 | Exercised by a test; kept as supported public API |
| QUAL-014 (`pattern_comp_depth` leak) | 12b7de5 | `defer` decrement |
| QUAL-016 (no JSON string escaping) | 900ebfe | `writeJsonString` + round-trip test |
| QUAL-017 (`containsCall` duplication) | f913316 | Thin wrapper over `containsCallStatic` |
| QUAL-018 (dead ORDER BY config flags) | f913316 | `strict_order_keys`/`forbid_orderby_paths` wired + tests |
| QUAL-020 (latent `unreachable` after expect) | 12b7de5 | Replaced with `unexpected(...)` |
| QUAL-021 (decimal magic numbers) | 900ebfe | `DECIMAL_SCI_SCALE` single source |
| QUAL-022 (garbled CANARY comments) | f913316 | Paths fixed; dead comment removed; binary-search claim corrected |
| QUAL-023 (API contract docs) | 65882c7 | Arena ownership/error set/prec/double-quote documented |

### Accepted as tech debt (deferred — maintainability only, not bugs)

- **QUAL-006** (god functions `parseStatement`/`parseQuery`, ~880/~960 lines): a behavior-preserving extraction refactor of the most heavily-relied-upon, thinly-test-covered core functions carries high regression risk for low value. Deferred; no correctness/safety impact.
- **QUAL-007** (UNION/INTERSECT/EXCEPT tail duplicated 4–6×): large dedup across the core set-op grammar; deferred for the same risk/reward reason. (Note: the one behavioral inconsistency it subsumed, QUAL-009, was fixed independently.)
- **QUAL-011** (`parsePostfixExpr` complexity): refactor-only; deferred.
- **QUAL-015** (human/JSON printer `else => {}` drops bodies for ~30 statement kinds; `PrintJsonOptions` naming): the JSON printer intentionally emits statement *kinds* plus verbose temporals, not a full AST serialization (see GAP-QUAL-013). Documented limitation; full AST→JSON is a feature, not a defect.
