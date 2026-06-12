# Performance Gap Analysis

Last updated: 2026-06-12
Reviewer: performance review (manual, evidence-based)
Scope: GQL (ISO/IEC 39075) lexer/parser/AST library. Hot path = parse query text → AST.

## Method & Context

- **Entrypoints:** `Lexer` (`src/lexer.zig:5`), `Parser.parseProgram` (`src/parser.zig:389`) → `parseProgramImpl` (`src/parser.zig:414`).
- **Allocator model:** caller-provided arena. `Parser.arena: *std.heap.ArenaAllocator` (`src/parser.zig:23`); construction pattern `Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() }` (e.g. `src/parser.zig:6654`). An arena **never frees individual allocations** — it is reset/destroyed as a whole. This makes redundant intermediate allocations a *cumulative footprint* problem, not just a transient cost.
- **Parser shape:** single-token-lookahead recursive descent. State is `cur: tok.Token` (one-token buffer) plus a `*Lexer` re-lexed on demand. No token vector is materialized.
- **Observability seam:** `src/observability.zig:47` hardcodes `enabled = false`; `startQueryExecutionSpan`/`endQueryExecutionSpan` collapse to comptime no-ops. **Zero hot-path overhead in default build — not a finding.**
- **Baseline evidence:** `benchmarks/results/baseline.json`. Per-query parse times are flat across 100→25K-query tiers (`parse_simple_ns` ~6.1-7.2k, `parse_rel_ns` ~10.3-11.9k, `parse_complex_ns` ~15.8-19.0k), i.e. **no O(n²) over query count**. Note `parse_rel_ns` is ~1.5× `parse_simple_ns` and `parse_complex_ns` is ~2.4× — relationship/MATCH parsing is the dominant per-query cost, which aligns with PERF-101 below.

## Severity legend

| PerfSeverity | Meaning |
|---|---|
| P0 | Super-linear blowup or unbounded resource use reachable from normal input; fix urgently |
| P1 | Constant-factor waste on the dominant hot path (every MATCH / every identifier) |
| P2 | Repeated waste on a common-but-not-dominant path (every function call, every lookahead) |
| P3 | Minor / cleanup / micro-opt with small measurable effect |

## Relationship to existing GAP_ANALYSIS.md

`docs/GAP_ANALYSIS.md` tracks GAP-PERF-001..010. Status snapshot relevant here:

- GAP-PERF-004 (peekKind/peek2Kind copy Lexer + re-lex) — **Won't Do** (deferred to parser split). Re-confirmed below as **PERF-105**, with the new note that `peek2Kind` is now fully dead code.
- GAP-PERF-005/006 (peekToken state restore; CTE speculative lexing) — **Won't Do**. Re-confirmed; CTE detection is bounded (PERF-104). The previously *untracked* and more expensive sibling is the **MATCH…DELETE speculative full re-parse (PERF-101, NEW)** — this is not GAP-PERF-006 and is materially worse.
- GAP-PERF-007 (zero-capacity ArrayList at 83 sites) — **Won't Do**. Re-confirmed (now 75 `.empty`/`initCapacity(...,0)` sites); see **PERF-103** which narrows it to the append-in-loop subset that actually matters under an arena.

New findings not previously tracked: **PERF-101, PERF-102, PERF-106, PERF-107**.

---

## Findings

### PERF-101 — MATCH statements are speculatively parsed twice (parse-discard-reparse)

- **PerfSeverity:** P1
- **Location:** `src/parser.zig:732-759` (detection block), re-parse at `:761-764`
- **Evidence:**

  ```zig
  .MATCH => blk_match: {
      const saved_pos = self.lx.*;
      const saved_cur = self.cur;
      self.advance(); // Skip MATCH
      _ = self.parseGraphPattern() catch { ... };   // FULL parse, AST built into arena
      if (self.cur.kind == .WHERE) {
          self.advance();
          _ = self.parseOrExpr() catch {};            // FULL WHERE expr parse, discarded
      }
      const is_delete = self.cur.kind == .DELETE or self.cur.kind == .DETACH;
      self.lx.* = saved_pos;                           // rewind lexer
      self.cur = saved_cur;
      if (is_delete) { ... self.parseGraphPattern() ... }  // parse AGAIN
      else: parseQuery() ... parseGraphPattern() AGAIN
  }
  ```

  To decide whether a `MATCH` leads to a `DELETE`, the parser fully parses the graph pattern **and** the optional `WHERE` expression (allocating AST nodes into the arena via `self.arena.allocator()`), throws the result away, rewinds the lexer, and parses the same tokens a second time. This is not a bounded lookahead (contrast PERF-104) — it is a complete speculative parse.
- **Estimated cost/impact:** ~2× lexing + ~2× AST construction for the graph-pattern + WHERE portion of **every MATCH statement** — the single most common GQL statement. The discarded first-pass AST nodes are arena-allocated and **never reclaimed** (arena model), so peak arena footprint for MATCH-heavy programs is inflated by the size of the discarded pattern/where AST. Directly consistent with `parse_rel_ns` being ~1.5× `parse_simple_ns` in the baseline.
- **Recommended fix:** Replace the speculative parse with bounded token lookahead. The decision only needs the token *kind* that follows the graph pattern + optional WHERE. Either (a) parse the pattern + WHERE **once** into locals and branch on the next token (`DELETE`/`DETACH` vs not) without rewinding, or (b) if the grammar truly needs to disambiguate before committing, scan ahead over balanced brackets at the *token* level (like the CTE block) to find whether a top-level `DELETE`/`DETACH` token appears before the clause terminator, without building AST. Option (a) is cleanest: parse pattern+WHERE, keep them, then dispatch.
- **Acceptance criteria:** `MATCH (n)-[r]->(m) WHERE ... RETURN ...` and `MATCH (n) DETACH DELETE n` parse with `parseGraphPattern` invoked at most once and `parseOrExpr` for WHERE invoked at most once (verify by counting calls or via a parse-allocation counter). `parse_rel_ns` in `scale_bench` drops measurably (target: within ~10-20% of `parse_simple_ns` for single-hop patterns). No change to produced AST or to existing MATCH/DELETE tests.

---

### PERF-102 — `validateBuiltinCall` is a ~40-deep linear `eqlIgnoreCase` chain per function call

- **PerfSeverity:** P2
- **Location:** `src/parser.zig:4115-4260` (validator); invoked per call at `src/parser.zig:3563-3566`
- **Evidence:** The validator is a flat `if … else if …` ladder of ~40 sequential `std.ascii.eqlIgnoreCase(name, "…")` comparisons (lines 4118, 4122, 4125, 4128, 4131, 4135, 4138, 4142, 4147, 4151, 4155, 4158, 4162, 4165, 4172, 4176, 4179, 4183, 4186, 4191, 4195, 4199, 4209, 4216, 4223, 4229, 4235, …). A function name that matches nothing walks the entire chain, doing a case-insensitive string compare at each step. It is fed by a throwaway flatten at the call site:

  ```zig
  // src/parser.zig:3563-3566
  var flat = std.ArrayList(ast.Expr).empty;
  for (args_slice) |p| try flat.append(self.arena.allocator(), p.*);  // copy each arg BY VALUE
  if (!validateBuiltinCall(name.orig, try flat.toOwnedSlice(self.arena.allocator()), ...))
  ```

- **Estimated cost/impact:** Per function call: O(#builtins × name_len) byte comparisons for unrecognized names, plus an O(args) by-value copy of every argument `Expr` into a fresh arena-backed ArrayList that is consumed and discarded immediately. Both scale with call density (aggregations, `date()`, `count()`, etc. are common in `parse_complex` queries).
- **Recommended fix:** (1) Replace the `eqlIgnoreCase` ladder with a `std.StaticStringMap` (comptime, like `token.zig:251` `KeywordMap`) keyed on the upper-cased name, or a comptime `switch` on a small enum, giving O(1) dispatch. (2) Pass `args_slice` (the existing `[]*Expr`) directly to `validateBuiltinCall` and have the validator index `args[i].*` only when it needs an argument, eliminating the per-call flatten/copy/`toOwnedSlice`.
- **Acceptance criteria:** `validateBuiltinCall` performs at most one hashed/`switch` lookup per call (no linear scan); the per-call `ArrayList(ast.Expr)` flatten at `:3563-3566` is removed. A microbench over a call-dense query (e.g. `RETURN count(*), avg(x), max(y), date('2024-01-01')` repeated) shows reduced parse time; all builtin-validation tests still pass.

---

### PERF-103 — ArrayLists grown by reallocation under a non-freeing arena (no capacity hints in hot loops)

- **PerfSeverity:** P2
- **Location:** Parser-wide. 0 occurrences of `ensureTotalCapacity`/`ensureUnusedCapacity` in `src/parser.zig`; append-in-loop hot sites include `src/parser.zig:497` (statements), `:786`/`:792` (delete items), `:2660`/`:2688` (chains/hops), `:3541` (call args). `self.arena.allocator()` is invoked 278× and reconstructed at each call.
- **Evidence:** Lists are created empty (`std.ArrayList(...).empty` / `initCapacity(...,0)`, 75 sites) and grown by repeated `append`, which reallocates with geometric growth. Under the arena allocator each regrow **leaves the previous, smaller backing buffer stranded** (arenas don't free), so a list that grows 0→1→2→4→8 leaves 1+2+4 elements' worth of dead buffers behind in addition to the live 8. This is the narrowed, impactful subset of GAP-PERF-007 (which was closed as "Won't Do" on the grounds that "the arena amortizes small allocations" — that rationale is partially inverted: the arena *hides* the cost as permanent footprint rather than eliminating it).
- **Estimated cost/impact:** Extra memcpy on each regrow plus permanent arena footprint of all intermediate buffers. Negligible for 1-2 element lists (most patterns) but grows with statement count, projection-item count, and call-arg count. Worst for large multi-statement programs and wide RETURN/GROUP lists.
- **Recommended fix:** For the loops whose element count is cheaply known or boundable, preallocate with `ensureTotalCapacity`/`initCapacity`. Where the count is unknown, a small initial capacity (e.g. 4) avoids the 0→1→2 regrow chain. Also cache `const a = self.arena.allocator();` once per function instead of calling `self.arena.allocator()` inside loops. Do **not** blanket-apply across all 75 sites (per the existing Won't-Do rationale); target the append-in-loop hot sites listed above.
- **Acceptance criteria:** The statement loop (`:497`), projection/return-item loops, and call-arg loop (`:3541`) preallocate a small capacity; arena bytes consumed for a 1000-statement program drop measurably (instrument `arena.queryCapacity()` before/after). All parser tests pass.

---

### PERF-104 — CTE detection does bounded balanced-paren speculative lexing (confirm; low risk)

- **PerfSeverity:** P3
- **Location:** `src/parser.zig:426-460`
- **Evidence:** At program start, when `cur.kind == .WITH`, the parser copies the lexer (`var tmp = self.lx.*`, `:426`) and re-lexes ahead to distinguish a CTE (`WITH name AS (…)`) from a projection. The column-list case runs a `while (depth > 0)` balanced-paren scan (`:445-450`) calling `tmp.next()` until matching `r_paren` or `.eof`.
- **Estimated cost/impact:** One-time, **once per program**, and only when input begins with `WITH`. Worst case re-lexes to EOF for a malformed/huge column list, but it is bounded by input length and not repeated. This is GAP-PERF-006, already triaged "Won't Do" (tied to the lookahead-buffer initiative). Re-confirmed as genuinely low impact — listed for completeness so it is not mistaken for the worse PERF-101.
- **Recommended fix:** No standalone action recommended; will be subsumed if a lookahead/token-buffer is introduced (GAP-PERF-004). If touched, cap the column-list scan to a sane token budget to avoid worst-case re-lex on pathological input.
- **Acceptance criteria:** N/A (accept as-is) or, if addressed, scan terminates within a fixed token budget. No behavior change to CTE vs projection disambiguation.

---

### PERF-105 — `peekKind` re-lexes for lookahead; `peek2Kind` is dead code (re-confirm GAP-PERF-004)

- **PerfSeverity:** P3
- **Location:** `src/parser.zig:237-241` (`peekKind`), `:243-248` (`peek2Kind`), `:56-71` (`peekToken`). Call sites: `peekKind` at `:2633, :2676, :3886, :3892`; `peekToken` at `:1841, :2813, :2972, :2979, :2994, :3294, :3415`; `peek2Kind` has **zero call sites**.
- **Evidence:**

  ```zig
  fn peekKind(self: *Parser) tok.TokenKind { var tmp = self.lx.*; const tkn = tmp.next(); return tkn.kind; }
  fn peek2Kind(self: *Parser) tok.TokenKind { var tmp = self.lx.*; _ = tmp.next(); const t2 = tmp.next(); return t2.kind; }  // UNUSED
  ```

  Each `peekKind`/`peekToken` runs the lexer's full `next()` scan (skipSeparators, multi-char match, identifier/keyword classification) for one token, which `advance` then re-runs when the token is actually consumed. The `Lexer` struct is small (~40 bytes), so the *copy* is cheap; the cost is the redundant *scan*. `peek2Kind` is defined but never called.
- **Estimated cost/impact:** Modest constant overhead at 11 call sites (notably `:2676` `peekKind()==.minus` inside the per-hop relationship loop, so it runs once per hop). One token re-lexed per peek; the keyword path additionally re-runs `keywordKind` (see PERF-106). This is GAP-PERF-004 ("Won't Do", deferred to parser split) — re-listed because the dead `peek2Kind` can be removed now at zero risk.
- **Recommended fix:** (1) Delete the unused `peek2Kind` (`:243-248`) — immediate, zero-risk, reduces compile surface. (2) The broader fix (a one-slot lookahead buffer so peek caches the next token and `advance` consumes it without re-lexing) remains the GAP-PERF-004 architectural change; defer per existing decision.
- **Acceptance criteria:** `peek2Kind` removed; build and tests still pass. (Lookahead buffer left to GAP-PERF-004.)

---

### PERF-106 — `keywordKind` upper-cases into a stack buffer on every identifier, then map-looks-up

- **PerfSeverity:** P3
- **Location:** `src/token.zig:423-435`, called from `src/lexer.zig:273` (`scanIdentifierOrKeyword`)
- **Evidence:**

  ```zig
  pub fn keywordKind(word: []const u8) TokenKind {
      var upper_buf: [64]u8 = undefined;
      if (word.len > upper_buf.len) return .identifier;
      for (word, 0..) |c, i| upper_buf[i] = std.ascii.toUpper(c);  // copy+upper every ident
      const upper = upper_buf[0..word.len];
      return KeywordMap.get(upper) orelse .identifier;             // hash again over the bytes
  }
  ```

  Every identifier token (keyword or not) is copied byte-by-byte into a 64-byte stack buffer with `toUpper`, then the `StaticStringMap` re-hashes those bytes. So each identifier is walked twice (upper-case pass + hash pass).
- **Estimated cost/impact:** One extra O(len) pass + a 64-byte stack buffer per identifier token. Small (lexemes are short), but it is on the hottest tokenizing path — every identifier and keyword in the query. The 64-byte stack frame is trivial.
- **Recommended fix:** Use a case-insensitive lookup so the upper-case copy is avoided: either (a) build the `StaticStringMap` with an ASCII-case-insensitive context/hash so `get` can take the raw lexeme, or (b) since GQL keywords are ASCII, fold the case during the hash walk rather than into a separate buffer. Caller `scanIdentifierOrKeyword` already has the slice; passing it straight to a case-insensitive map removes the buffer entirely.
- **Acceptance criteria:** `keywordKind` does not materialize an upper-cased copy; `keyword_ns` in the baseline (currently ~17ns) does not regress and ideally improves; all `keywordKind` case tests (`token.zig:453-543`) pass including mixed-case and >64-char inputs.

---

### PERF-107 — `scanIdentifierOrKeyword` double-decodes UTF-8 (iterator + per-codepoint length recompute)

- **PerfSeverity:** P3
- **Location:** `src/lexer.zig:257-270`
- **Evidence:**

  ```zig
  var iter = std.unicode.Utf8Iterator{ .bytes = self.src[self.idx..], .i = 0 };
  while (iter.nextCodepoint()) |cp| {                      // decode #1 (advances iter.i)
      ...
      const cp_len = std.unicode.utf8CodepointSequenceLength(self.src[self.idx]) catch 1;  // decode #2
      self.idx += cp_len;
      self.col += 1;
  }
  ```

  `nextCodepoint()` already decodes the codepoint and internally advances `iter.i` by the sequence length, but that length is discarded; the loop then recomputes the sequence length from the lead byte via `utf8CodepointSequenceLength` to advance `self.idx`. Two length determinations per codepoint. (For pure-ASCII identifiers both are trivial, but the iterator is still heavier than a byte loop.)
- **Estimated cost/impact:** Redundant per-codepoint length computation for every identifier. Most identifiers are ASCII, where a plain byte loop (as already used in the `LOCAL DATETIME` fast path at `:302-306`) would be cheaper than spinning up a `Utf8Iterator`. Effect is small but on the per-identifier path.
- **Recommended fix:** Either (a) advance `self.idx` by the iterator's own consumed length (track `iter.i` delta) instead of recomputing, or (b) add an ASCII fast path: scan `isIdentifierContinue` over bytes while `b < 0x80`, only dropping into the Utf8Iterator when a non-ASCII byte is seen. Option (b) matches the existing fast-path style elsewhere in the file and `caseFoldToUpper`'s ASCII fast path.
- **Acceptance criteria:** Identifier scanning advances `self.idx` using the already-decoded length (no second `utf8CodepointSequenceLength` per cp), or an ASCII fast path is added. `lex_ops_sec` in the baseline does not regress and ideally improves; Unicode-identifier tests still pass.

---

## Already-tracked items re-confirmed (no new action)

| ID | Item | Status in GAP_ANALYSIS.md | Re-confirmation |
|---|---|---|---|
| GAP-PERF-003 | `caseFoldToUpper` heap-allocates per identifier | Closed (ASCII fast path added) | Confirmed: `unicode_tables.zig:156-161` ASCII fast path present. **However** it still `allocator.alloc`s a fresh duplicate of every identifier lexeme for the `.cnf` field (4 call sites: `parser.zig:3500, 3736, 3984, 4007`). The allocation was not eliminated, only made cheaper. If `.cnf` is only consumed for case-insensitive comparison, consider computing it lazily or comparing case-insensitively against `.orig` to drop the per-identifier allocation entirely. Logged here as an observation, not a new P-level (the closed gap's fix is real). |
| GAP-PERF-004 | peekKind/peek2Kind copy Lexer + re-lex | Won't Do | See PERF-105. `peek2Kind` now fully dead. |
| GAP-PERF-006 | CTE unbounded speculative lexing | Won't Do | See PERF-104. Bounded per-program; low impact. |
| GAP-PERF-007 | Zero-capacity ArrayList at 83 sites | Won't Do | See PERF-103 (now 75 sites). Narrowed to append-in-loop hot subset under arena semantics. |
| GAP-SEC-001 / GAP-PERF-001 | Expression recursion depth guard | Closed | Confirmed `MAX_EXPR_DEPTH = 256` (`parser.zig:50`); bounds recursion, no oversized frames. |

## Not findings (verified clean)

- **Observability seam** (`observability.zig:47` `enabled=false`) — comptime no-op, zero default-build overhead.
- **Print path** (`print.zig:63` `printProgramJsonWith`) — streams directly to a writer; `print_json_ns` ~39ns. No materialization. The `printProgramJson` convenience wrapper takes a per-call mutex (`print.zig:53`) but is not the parse hot path and is the documented non-recommended entrypoint.
- **`parallel.zig`** — flat-chunk fork/join over already-parsed statements with a sequential fallback below threshold (8/64) and bounded `MAX_CHUNKS=64` stack arrays of small contexts. The thread pool is **not** on the parse hot path (parsing is single-threaded by design; `parallel.zig:10-26`). No contention or oversubscription issue in the parser itself.
- **No O(n²) over input size** in the benchmarked range — `baseline.json` per-query times are flat from 100→25K queries.

## Suggested priority order

1. **PERF-101 (P1)** — eliminate MATCH double-parse. Highest single-statement win; touches the dominant statement class.
2. **PERF-102 (P2)** — `StaticStringMap` for builtin validation + drop per-call arg flatten.
3. **PERF-103 (P2)** — capacity hints on append-in-loop hot sites; cache `arena.allocator()`.
4. **PERF-105 (P3, partial now)** — delete dead `peek2Kind` immediately; defer lookahead buffer to GAP-PERF-004.
5. **PERF-106 / PERF-107 (P3)** — case-insensitive keyword lookup; identifier-scan ASCII fast path / single-decode.

## Validation harness

Existing suite covers regression detection:

- `zig build scale-bench` → JSON tiers (compare `parse_rel_ns`, `parse_simple_ns`, `lex_ops_sec`, `keyword_ns`).
- `zig build bench` → `benchmarks/bench.zig` (14 microbenchmarks).
- `zig build compare-bench` against `benchmarks/results/baseline.json` (regression threshold).
- After PERF-101: add a MATCH-heavy and a MATCH…DELETE query to `scale_bench` so the double-parse removal is directly measured.

---

## Remediation Status — 2026-06-12

| Finding | Status | Commit / Note |
|---------|--------|---------------|
| PERF-101 (MATCH parsed twice) | **Resolved** | 12b7de5 — replaced speculative pattern parse with token-only `matchIsDelete` lookahead (no AST built/discarded); routing tests added |
| PERF-102 (validateBuiltinCall linear ladder + per-call arg flatten) | **Resolved** | 8dcf1b6 — StaticStringMap O(1) dispatch; takes `[]const *ast.Expr` directly (no flatten allocation) |
| PERF-105 (dead peek2Kind) | **Resolved** | 12b7de5 — removed |
| PERF-107 (redundant UTF-8 length recompute) | **Resolved** | 6081156 — consumed bytes derived from decoder; superseded by 6013cdd which routes the scan through the hardened decoder |
| PERF-103 (no ensureTotalCapacity hints) | **Accepted / Won't-Do** | Tracks GAP-PERF-007 (Won't-Do); arena append-regrow footprint, low impact |
| PERF-104 (CTE detection lookahead) | **Accepted** | Confirmed bounded/per-program, low impact |
| PERF-106 (keywordKind uppercase + hash two-pass) | **Accepted (P3)** | Uppercase-then-StaticStringMap is the correct standard approach for case-insensitive matching; a truly case-insensitive static map needs a custom hash std does not provide. Left as-is; negligible cost on short keywords |

Also fixed in this pass (not originally in this doc): the benchmark targets
(`bench`, `compare-bench`) did not compile under Zig 0.16 — migrated to the
0.16 writer/Io/args APIs (commit 922a78a) so `zig build bench` works again.
