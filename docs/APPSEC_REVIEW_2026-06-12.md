# Application Security Review — gql (GQL lexer/parser library)

- **Target:** `gitlab.com/devnw/zig/gql` @ `main` (HEAD `5b02156`, working tree clean)
- **Date:** 2026-06-12
- **Reviewer role:** Defensive, evidence-first AppSec code review
- **Frameworks:** OWASP Top 10:2025, CIS Controls v8.1.2
- **Language/runtime:** Zig 0.15.1+ library (no standalone server); Python 3 dependency-sync scripts
- **Core question:** *Is this library safe to embed in a server that parses attacker-controlled GQL text?*

---

## 1. Scope & Assumptions

### Reviewed

- **Untrusted-input core (source-to-sink):** `src/lexer.zig`, `src/parser.zig` (6686 lines, scanned in full), `src/token.zig`, `src/temporal.zig`, `src/unicode/unicode_tables.zig`, `src/ast.zig` (security-relevant types).
- **Concurrency / allocator / printing:** `src/parallel.zig`, `src/print.zig`, `src/root.zig`, `src/observability.zig`, `src/observability_init.zig`, `src/build_options` wiring.
- **Supply chain / build / CI:** `build.zig`, `build.zig.zon`, `.gitlab-ci.yml`, `.pre-commit-config.yaml`, `.gitleaks.toml`, `Makefile`.
- **Scripts:** `scripts/detect_diamond_deps.py`, `scripts/sync_diamond_deps.py`, `scripts/sync_diamond_deps.sh`.
- **Tracking docs:** `docs/GAP_ANALYSIS.md`, `docs/REQUIREMENTS.md` (to avoid re-reporting tracked items without noting their status).

### Assumptions

1. The threat model in the input contract holds: the library is intended to be embedded in a server/database that feeds it **attacker-controlled GQL query text**. The library itself has no auth/authz surface (by design), so OWASP A01/A04/A07 are largely N/A; the dominant risk classes are **A06 (Insecure Design — DoS robustness)**, **A10 (Mishandling of Exceptional Conditions)**, **A03 (Supply Chain)**, and **A09 (Logging/Alerting)**.
2. **The library is compiled and shipped in `ReleaseFast` in production** (CI explicitly builds and tests `-Doptimize=ReleaseFast`, and `root.zig` markets embedding in servers). In `ReleaseFast`/`ReleaseSmall`, Zig **disables** safety checks: integer overflow, out-of-bounds indexing, invalid `@intCast`, and `unreachable` become **undefined behavior**, not panics. Severity is calibrated against this reality. Where a finding only manifests as a clean panic in `ReleaseSafe`/`Debug`, that is noted.
3. Native call-stack exhaustion in Zig is **not** a catchable error — it is a hardware fault (SIGSEGV) in `ReleaseFast` or a process-terminating panic in safe modes. `parseProgram` returning a recoverable `ParserError` does **not** protect against it.
4. The Python `--cascade --apply` workflow in `sync_diamond_deps.py` is **maintainer-operated** with maintainer-supplied CLI arguments; it is not reachable from attacker-controlled GQL input. It is reviewed for command-injection/operational hygiene only.

### Not covered / out of scope

- First-party transitive dependencies (`thread-pool`, `otel`) were **not** source-audited; only their pinning was checked.
- Runtime behavior was **not** executed (no build/run/fuzz performed); findings are by static analysis and code reading.
- The Geode host integration (how a server calls into this library, its allocator budget, sandboxing) is external and unavailable.

---

## 2. Executive Summary

- **The headline answer to the embedding question is: not yet, without compensating controls.** The library is robust against the *expression* nesting it was hardened against (GAP-SEC-001), but the recursion-depth guard (`expr_depth`/`MAX_EXPR_DEPTH=256`) **does not cover the statement/query grammar or the graph-pattern grammar**, both of which contain unbounded mutually-recursive cycles reachable from a few KB of input. This is a **trivially triggerable remote denial-of-service (stack exhaustion → SIGSEGV in ReleaseFast)** and is the dominant risk (FINDING 1, Critical; FINDING 2, High).
- The expression-depth guard itself was verified correct and complete for `(...)`, `[...]`, `{...}`, function args, indexing, CASE/CAST — an attacker simply nests `CALL{...}` or `shortestPath(...)` instead, completely bypassing the 256 budget. The existing guard creates a **false sense of safety**.
- **Memory-corruption surface is clean in the audited scope.** Integer-overflow/`@intCast` paths in `temporal.zig` and the numeric/decimal/scientific-notation literal handling in `parser.zig` are correctly validated-before-cast or range-guarded (the GAP-SEC-005/006/007 fixes hold). No reachable out-of-bounds slice, use-after-free, or attacker-reachable `unreachable`/`@panic`/`catch unreachable` was found on the parse path. UTF-8 decoding (`decodeUtf8Codepoint`) is hand-rolled and safe against invalid/overlong/surrogate input.
- **Allocation is unbounded by default but documented.** The arena allocator has no built-in memory budget; `root.zig` documents a `FixedBufferAllocator` mitigation for callers (GAP-SEC-002, closed-by-doc). This remains a real OOM-DoS vector if callers ignore the guidance (FINDING 4, Medium).
- **Supply chain is mostly sound:** dependencies are content-hash-pinned; the CI Zig toolchain is SHA-256-verified against the ziglang.org index. Gaps: CI catalog components and base images are pinned by mutable tag, not immutable digest (FINDING 6, Low; partially tracked as GAP-SEC-011).
- **The CI fuzz job runs against zero fuzz targets** — no `std.testing.fuzz` harness exists anywhere in the tree, so the `zig build test --fuzz` job provides false assurance for a library whose entire security posture rests on input-handling robustness (FINDING 5, Medium — A09).
- **Overall confidence:** High for the recursion findings (traced call chains, line-cited) and for the negative results on memory corruption. Medium for the allocation-DoS reachability (depends on caller configuration).

---

## 3. Findings Table

| ID | Severity | Confidence | Title | Location | OWASP 2025 | Status |
|----|----------|------------|-------|----------|------------|--------|
| GQL-APPSEC-01 | **Critical** | High | Unbounded statement/query recursion (subqueries) bypasses depth guard → stack-exhaustion DoS | `src/parser.zig:1848`, `:1263`, `:1484`, `:1747`, `:2311`, `:5439` | A06 / A10 | New (extends GAP-SEC-001 scope) |
| GQL-APPSEC-02 | **High** | High | Unbounded graph-pattern recursion via `shortestPath(...)` bypasses depth guard → stack-exhaustion DoS | `src/parser.zig:2645`; `pattern_comp_depth` never bounded `:46`,`:2812`,`:3958` | A06 / A10 | New |
| GQL-APPSEC-03 | **Medium** | High | `expr_depth` guard documented as "the" recursion limit but only covers expression grammar (defense-in-depth / insecure design) | `src/parser.zig:50`,`:2940`,`:2966`,`:3289`; `src/root.zig:41` | A06 | New |
| GQL-APPSEC-04 | **Medium** | Medium | Unbounded arena allocation on adversarial input → memory-exhaustion DoS (budget is caller's responsibility) | `src/root.zig:29-43`; arena usage throughout `parser.zig` | A06 | Tracked (GAP-SEC-002, closed-by-doc) |
| GQL-APPSEC-05 | **Medium** | High | CI `--fuzz` job has no fuzz targets → false security assurance for a parser | `.gitlab-ci.yml:176-195`; no `testing.fuzz` in tree | A09 | New |
| GQL-APPSEC-06 | **Low** | High | Supply chain: CI catalog components and base images pinned by mutable tag, not digest | `.gitlab-ci.yml:11-24`,`:88` | A03 / A08 | Partially tracked (GAP-SEC-011) |
| GQL-APPSEC-07 | **Low** | High | Lexer passes raw UTF-8 byte to `isIdentifierStart`/`Continue` (u21 param) in LOCAL DATETIME / numeric-restore paths → mis-tokenization, mid-codepoint advance | `src/lexer.zig:302`,`:306` | A10 | New (correctness; not memory-unsafe) |
| GQL-APPSEC-08 | **Info** | High | Latent `unreachable` after `try self.expect(...)` — dead today, UB if a future edit changes the guard | `src/parser.zig:2450`,`:2456`,`:4445` | A10 | New |
| GQL-APPSEC-09 | **Info** | High | Version string mismatch (`build.zig.zon` 0.1.4 vs `root.zig` 0.1.0) — SBOM/traceability hygiene | `build.zig.zon:3` vs `src/root.zig:146` | A08 | New |

---

## 4. Finding Details

### GQL-APPSEC-01 — Critical — Unbounded statement/query recursion (subqueries) → stack-exhaustion DoS

**OWASP:** A06 Insecure Design / A10 Mishandling of Exceptional Conditions · **CWE-674** (Uncontrolled Recursion), CWE-789 (Memory Allocation with Excessive Size Value — stack) · **CIS:** 16.1 (secure development process), 16.11 (vetted modules), 18 (penetration testing)

**Evidence.** The recursion-depth counter is the field `expr_depth: u16` (`parser.zig:48`) with `const MAX_EXPR_DEPTH = 256` (`:50`). Grep confirms it is incremented/checked in **only three functions** — `parseOrExpr` (`:2940-2942`), `parseNotExpr` (`:2966-2968`), `parseUnaryExpr` (`:3289-3291`). It is **never** touched in `parseQuery` (`:1614`), `parseStatement` (`:623`), or `parseQueryForCTE` (`:617`).

`parseQuery` recurses into itself with no depth budget on multiple input-driven paths. The clearest is the `CALL { subquery }` branch:

```zig
// src/parser.zig:1840-1848
if (self.cur.kind == .CALL) {
    const peek_ahead = self.peekToken();
    if (peek_ahead == .l_brace) {
        self.advance(); // consume CALL
        self.advance(); // consume {
        const inner_query = try self.parseQuery();   // :1848  ← unbounded self-recursion
```

Additional unguarded `parseQuery`/`parseStatement` recursion sites confirmed by grep: `:1263` (`parseStatement` → `parseQuery`), `:1484` (parenthesized statement set-ops), `:1747` and `:2311` (`WITH`-chaining `parseQuery` → `parseQuery`), `:5439` (`FOR ... RETURN` wrapping `parseStatement`). None increments `expr_depth`.

**Attack scenario (non-destructive).** Submit a query consisting of a deeply repeated subquery prefix, e.g.:

```text
CALL{CALL{CALL{ ... CALL{RETURN 1} ... }}}
```

Each `CALL{` adds one native `parseQuery` frame. A few thousand repetitions (a few KB of text) drives the call stack past the default thread stack size. There is no 256-level cap on this path because `expr_depth` is never incremented during query descent.

**Impact.** Remote, unauthenticated denial of service. In a server that hands attacker GQL to `parseProgram`, a single small request crashes the worker:

- `ReleaseFast`/`ReleaseSmall` (the CI-tested production modes): SIGSEGV on stack overflow — **uncatchable**, terminates the process/worker.
- `ReleaseSafe`/`Debug`: process-terminating panic.
Either way `parseProgram`'s `ParserError` return cannot intercept it (stack exhaustion is not a Zig error value).

**Root cause.** The depth guard was added to the expression grammar only (GAP-SEC-001 / GAP-PERF-001) under the assumption that expression nesting was the sole unbounded recursion. The statement and query grammars contain independent unbounded recursive cycles that share none of the expression guard's accounting.

**Remediation.** Add a unified recursion budget that covers **all** mutually-recursive descent. Minimal, low-risk fix:

```zig
// Add alongside expr_depth:
recur_depth: u16 = 0,
const MAX_RECUR_DEPTH = 256; // tune to stack budget

// At the top of parseQuery(), parseStatement(), parseGraphPattern():
self.recur_depth += 1;
defer self.recur_depth -= 1;
if (self.recur_depth > MAX_RECUR_DEPTH) return error.UnexpectedToken; // or a dedicated error.TooDeep
```

Prefer a single shared counter spanning statements + patterns + expressions so the total native stack depth is bounded by one budget regardless of how the attacker interleaves `CALL{`, `shortestPath(`, `(`, `[`, `{`.

**Regression tests.**

- A test that builds `"CALL{" * N ++ "RETURN 1" ++ "}" * N` for `N` well past the limit (e.g. 5_000) and asserts `parseProgram` returns an error (not a crash). Run it under `-Doptimize=ReleaseSafe` so overflow is observable as a panic if the guard regresses.
- Equivalent tests for `WITH`-chaining and parenthesized-statement set-ops nesting.

---

### GQL-APPSEC-02 — High — Unbounded graph-pattern recursion via `shortestPath(...)` → stack-exhaustion DoS

**OWASP:** A06 / A10 · **CWE-674** · **CIS:** 16.1, 16.11

**Evidence.** `parseGraphPattern` (`parser.zig:2607`) recurses directly into itself inside the path-function branch, with no depth guard:

```zig
// src/parser.zig:2641-2645
if (std.ascii.eqlIgnoreCase(func_name, "shortestPath") or
    std.ascii.eqlIgnoreCase(func_name, "allShortestPaths")) {
    self.advance(); // consume function name
    _ = try self.expect(.l_paren);
    const inner_pattern = try self.parseGraphPattern();   // :2645  ← unbounded self-recursion
```

The inner `parseGraphPattern` again accepts the `ident '=' shortestPath(` prefix (chain-alias branch `:2633-2645`), so the cycle is unbounded. The `pattern_comp_depth: u32` field (`:46`) is incremented only on the pattern-comprehension `[` path (`:3958`) and is **never compared against a maximum** — `:2812` only tests `> 0` — so it offers no protection. Other unguarded `parseGraphPattern` entry points: `EXISTS { pattern }` (`:3307`), `COUNT { pattern }` (`:3369`), postfix `shortestPath`/`size` (`:3404`, `:3417`), pattern-comprehension `[ pattern ]` (`:3959`).

**Attack scenario.** `MATCH p=shortestPath((q=shortestPath((r=shortestPath(( ... ))))))` — recursion depth equals nesting count.

**Impact.** Same class as GQL-APPSEC-01: remote stack-exhaustion DoS from a small query. Slightly more syntax per level, but still trivial.

**Root cause.** Same as GQL-APPSEC-01 — the pattern grammar has no recursion budget; `pattern_comp_depth` was added without an enforced cap.

**Remediation.** Cover `parseGraphPattern` with the shared recursion budget from GQL-APPSEC-01 (recommended), or give `pattern_comp_depth` an enforced maximum and check it at every `parseGraphPattern` entry (`:2645`, `:3307`, `:3369`, `:3404`, `:3417`, `:3959`).

**Regression tests.** Nested `shortestPath((...))` and nested `EXISTS{ ( ... ) }` depth tests asserting a returned error rather than a crash, run under `ReleaseSafe`.

---

### GQL-APPSEC-03 — Medium — Recursion guard scope is narrower than documented (insecure design)

**OWASP:** A06 Insecure Design · **CWE-1059** (Insufficient Documentation of Error Handling) · **CIS:** 16.1

**Evidence.** `root.zig:41-42` states: *"The parser also has a recursion depth limit (256 levels) to prevent stack overflow on deeply nested expressions."* The word *expressions* is accurate but the public-facing implication — that nesting is bounded — is false for statements and patterns (GQL-APPSEC-01/02). A consumer reading the Security Notes would reasonably conclude the parser is stack-safe on arbitrary input.

**Impact.** Operators relying on the documented 256-limit will under-provision compensating controls (stack guard pages, per-request isolation, watchdogs), increasing exposure to GQL-APPSEC-01/02.

**Remediation.** Once GQL-APPSEC-01/02 are fixed with a unified budget, update `root.zig` to state the limit applies to total parse recursion (statements, patterns, expressions). Until fixed, the doc should explicitly warn that statement/pattern nesting is **not** bounded.

**Verification.** Doc/code consistency check in review; the regression tests for 01/02 double as proof the documented guarantee holds.

---

### GQL-APPSEC-04 — Medium — Unbounded arena allocation → memory-exhaustion DoS

**OWASP:** A06 Insecure Design · **CWE-770** (Allocation Without Limits / Throttling) · **CIS:** 16.1 · **Tracked:** GAP-SEC-002 (status "Closed — documented")

**Evidence.** The parser allocates all AST nodes from a caller-provided `ArenaAllocator` (`root.zig:23`, arena usage throughout `parser.zig`). There is no internal node-count or byte budget. `root.zig:29-43` documents a `FixedBufferAllocator` mitigation for callers. Even short inputs can expand the AST super-linearly (e.g. wide `VALUES`/list literals, long property maps, repeated chains), and absent the documented FBA wrapper the arena grows until the host OOMs.

**Impact.** Memory-exhaustion DoS when an embedding server passes an unbounded backing allocator (the default if the caller does not follow the Security Notes). Distinct from the stack-exhaustion findings; both should be mitigated.

**Why "closed-by-doc" is not sufficient.** The library cannot assume callers read the note; a safer default would self-enforce a budget. This is correctly tracked but remains a live risk for the embedding use case the threat model targets.

**Remediation (defense-in-depth, optional but recommended).** Offer an opt-in hard cap inside the parser (e.g. a `max_nodes` / `max_bytes` field checked at allocation sites or via a counting allocator wrapper) so robustness does not depend solely on caller discipline. At minimum, keep the `FixedBufferAllocator` example prominent and add it to any server-embedding example.

**Verification.** Test that parsing a large generated input under a small `FixedBufferAllocator` returns `error.OutOfMemory` cleanly (no crash, no leak), confirming the documented mitigation works end-to-end.

---

### GQL-APPSEC-05 — Medium — CI fuzz job runs zero fuzz targets (false assurance)

**OWASP:** A09 Security Logging and Alerting Failures · **CWE-1127** (ineffective detection) / CWE-778 (insufficient logging of security-relevant gaps) · **CIS:** 16.13 (application testing), 18 (penetration testing)

**Evidence.** `.gitlab-ci.yml:176-195` defines a `fuzz` job running `timeout 60 zig build test --fuzz` and treats rc 0 or 124 as pass. A repo-wide search for `std.testing.fuzz` / fuzz input harnesses returns **no matches** in `src/`, `tests/`, `benchmarks/`, or `examples/` (the only hit is a doc comment in `language_metadata.zig:20`). `zig build test --fuzz` with no `fuzzInput`/`testing.fuzz` targets exercises nothing; the job reliably "passes" while providing zero coverage.

**Impact.** For a library whose entire security posture is input-handling robustness, the green fuzz badge is misleading. The recursion DoS (GQL-APPSEC-01/02) is exactly the class a real coverage-guided fuzz target would have surfaced quickly. This is an alerting/assurance failure: a control that appears present but is inert.

**Remediation.** Add at least one real fuzz target that drives `Lexer` + `Parser.parseProgram` over `std.testing.fuzzInput`-derived bytes (bounded allocator + bounded recursion so the fuzzer reports the bug rather than OOM/segfault-by-design), and wire it into `zig build test --fuzz`. Fail CI if no fuzz target is discovered (guard against silent regression to zero targets).

**Verification.** Confirm the fuzz job exercises the new target (non-trivial coverage in the run summary) and that, before the GQL-APPSEC-01 fix, the fuzzer reproduces the deep-`CALL{` crash.

---

### GQL-APPSEC-06 — Low — Supply chain: CI components and base images pinned by mutable tag

**OWASP:** A03 Software Supply Chain Failures / A08 Software and Data Integrity Failures · **CWE-1357** (reliance on insufficiently trustworthy component) · **CIS:** 16.4/16.5 (third-party component trust), 7 (continuous vulnerability management) · **Partially tracked:** GAP-SEC-011 (Won't Do)

**Evidence.**

- CI catalog components are pinned by **tag**, not digest: `gitlab.com/devnw/ci-catalog/security-sast@v1.7.1` and siblings (`.gitlab-ci.yml:11-24`). A tag is mutable; whoever can move `v1.7.1` can alter what runs in CI.
- The build/test base image `debian:bookworm-slim` is pinned by **tag**, not by `@sha256:` digest (`.gitlab-ci.yml:88` and every job's `image:`).

**Positive offsets.** The Zig toolchain itself **is** verified: the install template downloads `index.json`, extracts the per-version/arch `shasum`, and runs `sha256sum --check --strict` on the tarball (`.gitlab-ci.yml:38-77`). Application dependencies in `build.zig.zon` are content-hash-pinned (`thread_pool` and `otel` both carry `.hash`), and a diamond-dependency detector guards against silently linking two versions of the same package.

**Impact.** Low for this library (first-party catalog, devnw-controlled), but tag-based pins are a standard supply-chain weakness: a compromised or re-pointed tag injects code into the build/release pipeline. GAP-SEC-011 documents this as a deliberate, catalog-team-coordinated deferral.

**Remediation.** Pin CI components and base images by immutable digest (`@<sha>` / `image: debian:bookworm-slim@sha256:...`) once the catalog supports it; until then, the existing tracked deferral is acceptable given the first-party trust boundary.

---

### GQL-APPSEC-07 — Low — Raw byte passed to Unicode `isIdentifierStart`/`Continue` in lexer fast paths (mis-tokenization)

**OWASP:** A10 Mishandling of Exceptional Conditions · **CWE-170/CWE-704** (improper conversion/handling) · **CIS:** 16.1

**Evidence.** In the LOCAL DATETIME literal path the lexer tests a **raw `u8`** against the Unicode predicates (which take `u21` and treat e.g. `0xC3` as a Latin-1 letter), then advances exactly one byte:

```zig
// src/lexer.zig:302-306
if (self.idx < self.src.len and t.isIdentifierStart(self.src[self.idx])) {
    const ident_start = self.idx;
    self.idx += 1;                       // advances 1 byte even for a multi-byte UTF-8 lead
    self.col += 1;
    while (self.idx < self.src.len and t.isIdentifierContinue(self.src[self.idx])) : (self.col += 1) self.idx += 1;
```

For input where `LOCAL` is followed by a non-ASCII identifier, a multi-byte codepoint is split mid-sequence and the word comparison (`eqlIgnoreCase(w, "DATETIME")`) operates on partial bytes.

**Impact.** Correctness/robustness only — **not** memory-unsafe. Every `self.idx` access stays guarded by `self.idx < self.src.len`, so no out-of-bounds read occurs even in `ReleaseFast`. Worst case is mis-tokenization of an unusual `LOCAL <non-ASCII>` sequence (the path falls back to treating `LOCAL` as a keyword). No crash, no UB.

**Root cause.** ASCII fast-path written with raw-byte predicates instead of the `decodeUtf8Codepoint` path used elsewhere in the same file (`:40`).

**Remediation.** Gate these byte tests on `self.src[self.idx] < 128` (the rest of the lexer already routes non-ASCII through `decodeUtf8Codepoint`), or decode the codepoint before the predicate. Add a unit test with `LOCAL` followed by a non-ASCII identifier and a `LOCAL DATETIME"..."` literal to lock the behavior.

---

### GQL-APPSEC-08 — Info — Latent `unreachable` after `try self.expect(...)`

**OWASP:** A10 · **CWE-617** (Reachable Assertion) — *latent, not currently reachable* · **CIS:** 16.1

**Evidence.** Three sites follow the pattern `_ = try self.expect(.RETURN); unreachable;` inside a branch entered only when the current token is **not** `.RETURN` (`parser.zig:2450`, `:2456`, `:4445`). Today `expect` returns `error.UnexpectedToken` before `unreachable` executes, so the `unreachable` is dead. The other `unreachable` sites (`:1472`, `:1533`, `:3250`; `lexer.zig:501`, `:515`) are guarded by exhaustive `switch`/`while` conditions and are also unreachable.

**Impact.** None today. The risk is purely maintenance: if a future edit makes `expect` conditional or changes the enclosing branch condition, these become reachable UB in `ReleaseFast`. Defense-in-depth issue.

**Remediation.** Replace the post-`expect` `unreachable`s with `return self.unexpected("RETURN")`, and the operator-switch `else => unreachable` sites with `else => return error.UnexpectedToken`, to remove the latent UB.

---

### GQL-APPSEC-09 — Info — Version string mismatch (SBOM/traceability hygiene)

**OWASP:** A08 · **CWE-1059** · **CIS:** 16.4 (SBOM accuracy)

**Evidence.** `build.zig.zon:3` declares `.version = "0.1.4"` while `src/root.zig:146` exports `pub const version = "0.1.0"`. Consumers reading the runtime constant get a stale version.

**Impact.** None to memory safety; it degrades SBOM/version traceability, which matters for vulnerability-intake and incident response (CIS 16.4, 7).

**Remediation.** Source the runtime `version` from `build_options`/`build.zig.zon` (single source of truth) or update the constant on each release.

---

## 5. Secure Design Notes (positive controls observed)

- **Hardened UTF-8 decoding.** `lexer.zig:decodeUtf8Codepoint` (`:479-522`) is a from-scratch decoder that explicitly rejects invalid lead bytes, truncated sequences, **overlong encodings**, surrogate-range codepoints, and out-of-range values — and the lexer routes non-ASCII through it specifically *"to avoid std lib assertions."* Backed by 12 unit tests covering each malformed case. This is the right instinct for untrusted input.
- **Validated-before-cast temporal parsing.** Every `@intCast` in `temporal.zig` (`:135-137`, `:151-208`, `:249-253`) operates on digits already validated by `isDateStrict`/`isTimeIso`/`isDateTimeIso`; `parseDate`/`parseTime` re-validate at entry. The `u8`/`i16` digit arithmetic cannot overflow (max value 99) and the i128 datetime math uses explicit widening. The GAP-SEC-005/006/007 hardening (decimal-scale clamp, scientific-notation `isFinite` + `<1e37` guard, `frac_digits` cap at 9) was verified present and effective.
- **Expression recursion guard is correct *within its scope*.** Traced every `parsePrimaryExpr` sub-case (`(...)`, `[...]`, `{...}`, function args, index/slice, CASE/CAST) back through `parseOrExpr`; all are correctly bounded at 256 with `defer`-decrement. The fix is sound — it just needs to extend to statements and patterns.
- **No reachable `catch unreachable`/`@panic` on the parse path.** `parseInt`/`parseFloat` errors (`Overflow`, etc.) are members of `ParserError` and propagated with `try`; no `catch unreachable`/`catch @panic` exists in `parser.zig`. The one `catch unreachable` in `print.zig:478` formats an i128 into a 64-byte buffer that cannot overflow, and the `@panic` in `parallel.zig:73` is on thread-pool init failure (startup, not input-driven).
- **Privacy-aware observability.** `observability.zig` deliberately does **not** attach query bodies (`db.statement`) to spans, with an explicit comment that bodies "may be long and contain PII in literals," and exposes an opt-in, length-truncated `setQueryStatement` for callers who have sanitized. Good A09/data-protection posture.
- **Sensitive-field annotation.** `ast.zig:563-565` carries a `SECURITY:` doc warning on `BackupStatement.encryption_key` instructing callers not to log/serialize/transmit it unredacted (GAP-SEC-004).
- **Supply-chain hygiene baseline.** Application deps content-hash-pinned in `build.zig.zon`; Zig toolchain SHA-256-verified in CI; gitleaks + `detect-private-key` pre-commit hook + secret-scanning CI components; a custom diamond-dependency detector that prevents silently linking two versions of one package (a real UAF root cause referenced in the script).
- **No injection surface.** No SQL/OS/template construction, no shell-out from library code, no deserialization of untrusted bytes into native objects, no SSRF/file-path sinks. The Python scripts use `subprocess` with list-args (`shell=False`) throughout — the maintainer `--cascade --apply` flow runs `git`/`zig` with arguments built from maintainer-supplied CLI specs, not attacker input; no command-injection path was found.
- **Multiple optimization modes exercised in CI.** Tests run under Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall, so safety-check-disabled builds get test coverage.

---

## 6. Coverage Gaps & Questions

1. **Transitive dependency source.** `thread-pool` and `otel` were not source-audited (only pinning). If they are in the trusted boundary of an embedding server, audit them separately — especially `otel`, which when enabled does network I/O.
2. **Actual production optimization mode.** Severity for the recursion findings assumes `ReleaseFast` (uncatchable SIGSEGV). Confirm the deployed mode. In `ReleaseSafe` the same bugs are a process-killing panic — still a DoS, but observable.
3. **Embedding allocator policy.** GQL-APPSEC-04's reachability depends on whether the host wraps the arena in a `FixedBufferAllocator` per the Security Notes. What is the actual server integration's allocator budget and per-request isolation?
4. **Stack budget and watchdog.** What thread stack size and request-timeout/watchdog does the embedding server use? These are the only compensating controls for GQL-APPSEC-01/02 until the guard is extended.
5. **No dynamic verification performed.** I did not build, run, or fuzz the code. The recursion crash is asserted from static call-chain tracing (high confidence) but not executed. Reproduce with the regression tests in §4 before/after the fix.
6. **`peekToken`/lookahead state restoration.** GAP-PERF-005/006 note `peekToken` "restores incomplete state" and CTE detection does "unbounded speculative lexing." These were not deeply traced for a re-lex amplification DoS; worth a focused look (could compound GQL-APPSEC-04).

---

## 7. Prioritized Next Actions

1. **(Critical, do first) Fix GQL-APPSEC-01 + GQL-APPSEC-02 together** by adding a single unified recursion budget covering `parseQuery`, `parseStatement`, and `parseGraphPattern` (pattern: `+= 1` / `defer -= 1` / `if (depth > MAX) return error`). This closes the dominant remote-DoS vector and is a small, localized change. Add the deep-`CALL{` and deep-`shortestPath((` regression tests under `ReleaseSafe`.
2. **(Medium) Stand up a real fuzz target (GQL-APPSEC-05)** over `Parser.parseProgram` with a bounded allocator + the new recursion cap, and make CI fail if zero fuzz targets are discovered. Verify it reproduces the recursion crash pre-fix.
3. **(Medium) Add an opt-in in-parser allocation cap (GQL-APPSEC-04)** so memory-DoS resistance does not depend solely on caller discipline; keep the `FixedBufferAllocator` example prominent in any server-embedding docs. Update `root.zig` Security Notes (GQL-APPSEC-03) to state the recursion limit now covers statements/patterns/expressions.
4. **(Low) Supply chain (GQL-APPSEC-06):** move CI components and base images to digest pins when the catalog supports it; the existing GAP-SEC-011 deferral is acceptable in the interim given first-party trust.
5. **(Low/Info) Cleanups:** gate the lexer byte predicates on `< 128` (GQL-APPSEC-07); replace latent `unreachable`s with error returns (GQL-APPSEC-08); reconcile the version string (GQL-APPSEC-09).
6. **(Process) Operational compensating controls** for the embedding server until #1 ships: per-request worker isolation, a request timeout/watchdog, and a generous stack guard page so a recursion crash is contained to one request rather than the process.

---

### Verdict on the embedding question

**With the current code, embedding in a server that parses attacker-controlled GQL is not safe against denial-of-service.** Memory-corruption resistance in the audited scope is good and the hardening already done is real and correct — but the recursion-depth guard does not cover the statement/query and graph-pattern grammars, giving a trivially triggerable remote stack-exhaustion crash (GQL-APPSEC-01/02), and allocation is unbounded by default (GQL-APPSEC-04). After the unified recursion budget (Action 1), an enforced allocation budget (Action 3), and a real fuzz target (Action 2), the library would be in a defensible position for that use case. No confirmed memory-safety (OOB/UAF/overflow) vulnerabilities were found in the reviewed scope.

---

## Remediation Status — 2026-06-12 (rounds 1–3)

| Finding | Status | Commit / Note |
|---------|--------|---------------|
| GQL-APPSEC-01 (unbounded statement/query recursion DoS) | **Fixed (verified round 2)** | eac9f23 — shared structural recursion guard |
| GQL-APPSEC-02 (unbounded graph-pattern recursion DoS) | **Fixed (verified round 2)** | eac9f23 |
| GQL-APPSEC-03 (recursion guard narrower than documented) | **Fixed** | eac9f23 — root.zig documents both 256 expr + 100 structural |
| GQL-APPSEC-04 (unbounded arena allocation → memory DoS) | **Addressed by design + doc** | Memory bounding is delegated to the caller-injected allocator (idiomatic Zig); root.zig Security Notes show the FixedBufferAllocator pattern; the fuzz target uses a bounded allocator. Tracked GAP-SEC-002 (closed-by-doc) |
| GQL-APPSEC-05 (CI fuzz job had zero targets) | **Fixed** | e8df65c — real `std.testing.fuzz` parser target |
| GQL-APPSEC-06 (CI components/images pinned by tag) | **Accepted / Won't-Do** | First-party catalog; tracks GAP-SEC-011 (Won't-Do); move to digests when catalog supports it |
| GQL-APPSEC-07 (raw byte to Unicode predicate in LOCAL DATETIME) | **Fixed** | eb355b7 — ASCII `< 128` gate + regression tests |
| GQL-APPSEC-08 (latent unreachable after expect) | **Fixed** | 12b7de5 — replaced with `unexpected(...)` |
| GQL-APPSEC-09 (version string mismatch) | **Fixed** | 39bfa70 — single-sourced from build.zig.zon |
| **GQL-APPSEC-10** (UTF-8 continuation bytes → Utf8Iterator unreachable/OOB; + invalid-byte double-advance OOB) | **Fixed** | 6013cdd — scan routed through hardened decodeUtf8Codepoint; invalid-byte emission no longer double-advances. Reproduced and verified fixed under Debug/ReleaseSafe/ReleaseFast |
