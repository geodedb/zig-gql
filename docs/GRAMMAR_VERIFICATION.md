# Grammar Verification

This document describes gql's grammar-verification system: how the vendored
ISO/IEC 39075 BNF grammar is used to catch drift between the specification,
the Geode extension surface, and this parser's actual behavior.

## Architecture

```
                     ┌──────────────────────────────────┐
                     │ grammar/ISO_IEC_39075.bnf.txt     │  vendored ISO
                     │  (vendored, never hand-edited)    │  artifact
                     └────────────────┬───────────────────┘
                                      │ parse (ebnf.bnf.parse)
                                      ▼
                     ┌──────────────────────────────────┐
                     │ grammar/geode.bnf                 │  Geode extension
                     │  (hand-authored supplement)        │  grammar
                     └────────────────┬───────────────────┘
                                      │ mergeFrom (ebnf.bnf.Grammar)
                                      ▼
                     ┌──────────────────────────────────┐
                     │ merged ISO+geode Grammar           │
                     │  (in-memory, ebnf package)         │
                     └───┬─────────┬─────────┬──────────┘
                         │         │         │
          ┌──────────────┘         │         └──────────────┐
          ▼                        ▼                        ▼
 ┌──────────────────┐   ┌────────────────────────┐  ┌──────────────────────┐
 │ Keyword drift     │   │ Conformance corpus      │  │ Generation ratchet    │
 │ (grammar keyword   │   │ (tests/corpus/{iso,     │  │ (500 seeded sentences │
 │ sets vs             │   │  geode}/*.gql, parsed  │  │  generated from the   │
 │ language_metadata) │   │  by the real gql        │  │  merged grammar,      │
 │                    │   │  Lexer/Parser)          │  │  parse-ok count       │
 │                    │   │                         │  │  pinned)              │
 └──────────────────┘   └────────────────────────┘  └──────────────────────┘
                                      │
                                      ▼
                          ┌────────────────────────┐
                          │ Grammar-guided fuzzing  │
                          │ (fuzz bytes drive       │
                          │  grammar derivation     │
                          │  choices; derived        │
                          │  sentences must never    │
                          │  crash the lexer/parser) │
                          └────────────────────────┘
```

All five checks live in `tests/grammar_test.zig` (smoke, geode merge-validate,
keyword drift, corpus, generation ratchet) and `tests/grammar_fuzz.zig`
(grammar-guided fuzz), wired into the `test-grammar` Zig build step. The
grammar-fuzz test artifact is *also* wired into the plain `test` step (see
`build.zig`'s `test_step.dependOn(&run_gf.step)`) so CI's coverage-guided
`zig build test --fuzz` job exercises the same property. Both wirings live
inside build.zig's `if (with_grammar)` block (see below), so they only exist
in the build graph when `-Dgrammar=true` is passed.

Grammar parsing/validation/merging/generation itself lives in the separate,
private [`ebnf`](https://gitlab.com/devnw/zig/ebnf) package (`bnf.parse`,
`Grammar.validate`, `Grammar.mergeFrom`, `Grammar.keywords`, `bnf.gen`),
consumed here as a `lazy = true` Zig package-manager dependency. Being `lazy
= true` in `build.zig.zon` is *not* by itself enough to keep it lazy — an
unconditional `b.lazyDependency("ebnf", ...)` call is reached (and the
dependency fetched) on **every** `zig build` invocation regardless of which
step is requested, because Zig evaluates all of `build.zig` up front. To keep
`ebnf` genuinely opt-in, the call itself is gated behind a
`-Dgrammar=true` build option (`with_grammar` in `build.zig`, mirroring the
`-Dwith_otel` pattern used for the `otel` dependency): **it is only fetched
when `-Dgrammar=true` is passed**, never merely because the `test` or
`test-grammar` step was targeted.

## What each ratchet file means

| File | Meaning | Who updates it, and when |
|---|---|---|
| `grammar/ISO_IEC_39075.bnf.txt` | Vendored copy of the official ISO/IEC 39075 BNF digital artifact. **Never hand-edited.** | `make grammar-fetch` only, when intentionally re-vendoring after an upstream/edition change. |
| `grammar/geode.bnf` | Hand-authored supplementary grammar for Geode-specific extensions (SCAN/CREATE CONSTRAINT, `@` field annotations + PRIMARY KEY, VECTOR/UUID/JSON types, `^` power operator, Geode functions). Redefinitions of ISO productions restate the ISO alternatives verbatim and append the Geode addition (`Grammar.mergeFrom` replaces, not appends). | Whoever adds a new Geode-only syntax extension to the parser, in the same change that adds the parser support. |
| `grammar/unimplemented_iso_keywords.txt` | Ratchet of ISO keywords the grammar defines but the parser/`language_metadata.zig` does not yet recognize. The keyword-drift test fails if an ISO keyword is neither implemented (`known`) nor listed here (`expected_missing`) — every ISO keyword must be in exactly one of those two buckets. | Whoever implements support for one of the listed keywords **removes** it from this file in the same change. Whoever notices a keyword the test flags as missing (rare — only happens if `ISO_IEC_39075.bnf.txt` changes) **adds** it here, or implements it. |
| `grammar/generation_ratchet.txt` | A single integer: how many of the 500 deterministic, seeded, grammar-generated `GQL-program` sentences the real parser currently accepts. Not a purity target — the generator draws from the *entire* unconstrained ISO grammar, so most generated sentences exercise syntax this parser does not implement and are expected to fail. The point is to **pin** the count so any silent change (grammar edit, generator override edit, or parser behavior change) that moves it gets caught instead of drifting unnoticed. | Whoever makes an intentional change that legitimately shifts the count (parser now accepts/rejects more of the generated corpus, a new lexical override changes what gets generated, etc.) updates the number to match the new observed count — and explains why in the commit message. Do **not** update it to silence an unexplained failure. |

### Updating `unimplemented_iso_keywords.txt` (playbook)

1. Implement the keyword in the parser and tag it in `src/language_metadata.zig`
   (`.iso_gql` compliance).
2. Remove the keyword's line from `grammar/unimplemented_iso_keywords.txt`.
3. Run `zig build test-grammar -Dgrammar=true --summary all` — the keyword-drift test now
   passes because the keyword is both implemented and no longer listed as
   expected-missing.

If you instead see a *new* `DRIFT: ISO keyword '...' unimplemented but not in
grammar/unimplemented_iso_keywords.txt` failure with no code change of your
own, it means `grammar/ISO_IEC_39075.bnf.txt` was re-vendored
(`make grammar-fetch`) and the new artifact adds a keyword neither the parser
nor the ratchet file knows about yet — add it to the ratchet file (to track
it as a known gap) or implement it.

### Updating `generation_ratchet.txt` (playbook)

1. Run `zig build test-grammar -Dgrammar=true --summary all`. If the generation-ratchet test
   fails, the failure message prints the actual count and the recorded
   count:
   ```
   GENERATION RATCHET DRIFT: <actual>/500 generated programs parsed (recorded: <recorded>).
   If this change is intentional, update grammar/generation_ratchet.txt to <actual>.
   ```
2. Confirm *why* the count moved (new parser feature landed, a lexical
   override in `tests/grammar_test.zig`'s `putLexicalOverrides` changed, a
   grammar file changed). If you can't explain the delta, don't update the
   file — treat it as a real regression and investigate instead.
3. If legitimate, write the new integer (bare, no trailing content beyond
   whitespace) into `grammar/generation_ratchet.txt` and re-run the test to
   confirm it's now green.

## Adding conformance corpus entries

`tests/corpus/iso/*.gql` and `tests/corpus/geode/*.gql` are individual GQL
source files, one statement/query per file, each carrying a header comment
on the first line:

```
-- expect: ok
```
or
```
-- expect: error
```

recording whether the **current** parser accepts the query. This is a
conformance ratchet, not an ISO-purity claim — some `tests/corpus/iso/`
files exercise Cypher-compat surface (SHOW, EXPLAIN/PROFILE, UNWIND) that the
parser supports but `language_metadata.zig` tags `.cypher_compat` rather than
`.iso_gql`; they live in `iso/` because they are core, non-Geode-specific
statement forms. `tests/corpus/geode/` is reserved for Geode-specific
extensions (Field-Level-Encryption annotations, PRIMARY KEY, SCAN, legacy
ASSERT constraints, etc.) that require `geode_mode` (`Parser.ts_extensions =
true`) to parse.

To add a new corpus entry:

1. Create `tests/corpus/iso/<descriptive_name>.gql` (or
   `tests/corpus/geode/<descriptive_name>.gql` for Geode-only syntax).
2. Add the `-- expect: ok` or `-- expect: error` header as the first line.
3. Put the GQL source on the following line(s).
4. For a syntax that is valid GQL but not yet supported by this parser, use
   `-- expect: error` plus a second-line `-- unsupported: <reason>` comment,
   so the gap is tracked explicitly instead of the file being silently
   deleted or miscategorized as a real syntax error.
5. Run `zig build test-grammar -Dgrammar=true --summary all` — `tests/grammar_test.zig`'s
   `runCorpusDir` iterates every `.gql` file in both directories
   automatically; no registration step is needed beyond adding the file.

## `make grammar-fetch` / `make grammar-check-upstream`

- `make grammar-fetch` downloads the current ISO/IEC 39075 BNF digital
  artifact from `https://standards.iso.org/iso-iec/39075/ed-1/en/ISO_IEC_39075(en).bnf.txt`
  and overwrites `grammar/ISO_IEC_39075.bnf.txt`. Use this only when
  intentionally re-vendoring (e.g. a new edition/corrigendum is published).
  Always re-run the full grammar test suite afterward and expect the
  keyword-drift and generation-ratchet ratchets to need updates.
- `make grammar-check-upstream` downloads the artifact to a temp file and
  diffs it against the vendored copy without overwriting anything — a
  read-only "has upstream changed?" check.

Both targets require network access to `standards.iso.org` and depend on
that artifact remaining available at a fixed URL, so **neither is wired into
`make ci`** and there is no CI job for either — they are for manual or
scheduled use only (e.g. a periodic pipeline schedule that alerts on drift,
not a merge gate).

## Subset-parser caveat

The ISO/IEC 39075 BNF grammar describes the *complete* GQL language. This
parser (`src/parser.zig`) implements a **subset** of it, plus Geode-specific
extensions layered on top (`grammar/geode.bnf`). Concretely:

- The generation ratchet (`grammar/generation_ratchet.txt`) is expected to be
  a small fraction of 500 — most grammar-derivable sentences exercise syntax
  this parser does not (yet) implement. A low or unchanged count is normal;
  it is the *stability* of the count, not its size, that the ratchet
  protects.
- `grammar/unimplemented_iso_keywords.txt` is the authoritative, explicit
  list of ISO keywords this parser does not recognize yet (210 entries as of
  this writing). Growing that list is not itself a regression; an
  **unexplained shrink or an ISO keyword missing from both the
  implementation and the file** is what the keyword-drift test catches.
- None of these checks assert ISO conformance/completeness — they assert
  that the *current, known* gap between the ISO grammar and this
  implementation is tracked and does not silently drift. Closing gaps
  (implementing more of the grammar) is expected to shrink
  `unimplemented_iso_keywords.txt` and change `generation_ratchet.txt` over
  time; that is the intended, tracked path forward, not a test failure to
  work around.

## `make` targets

| Target | What it does |
|---|---|
| `make test-grammar` | Runs `zig build test-grammar -Dgrammar=true --summary all`: smoke, geode merge-validate, keyword drift, conformance corpus, generation ratchet, and the grammar-fuzz smoke loop. Fast, deterministic, part of `make ci`. Without `-Dgrammar=true`, `zig build test-grammar` is a documented no-op (the step exists but has no dependencies). |
| `make grammar-fuzz` | Runs a 60-second time-boxed local approximation of CI's coverage-guided grammar fuzz job (`timeout 60 zig build test-grammar -Dgrammar=true --fuzz`; rc 124 = clean timeout = pass). See the caveats in the Makefile comment above this target about zig 0.15.2 local limitations — the deterministic 200-seed loop in `test-grammar` is the authoritative local check; this target is best-effort. |
| `make grammar-fetch` | Re-vendor `grammar/ISO_IEC_39075.bnf.txt` from upstream. Manual only. |
| `make grammar-check-upstream` | Read-only diff of vendored grammar vs upstream. Manual/scheduled only, not part of `make ci`. |

## CI prerequisite

`gitlab.com/devnw/zig/ebnf` is a **private** GitLab project. An anonymous
HTTPS GET against it 302-redirects to a sign-in page, so `zig build`'s
lazy-dependency fetch (`b.lazyDependency("ebnf", ...)`, only reached when
`-Dgrammar=true` is passed — see the Architecture section above) cannot
resolve it over the network with no credentials.

Only the CI jobs whose `zig build` invocation passes `-Dgrammar=true`
actually reach `b.lazyDependency("ebnf", ...)`, and only those jobs carry the
`*fetch-ebnf` preamble:

- `test` (`zig build test -Dgrammar=true --summary all`) — reaches the
  grammar-fuzz test artifact via `test_step.dependOn(&run_gf.step)`, so it
  needs both the flag and the preamble.
- `grammar-verify` (`zig build test-grammar -Dgrammar=true --summary all`) —
  needs both.
- `fuzz` (`timeout 60 zig build test --fuzz -Dgrammar=true`) — same
  reachability as `test`, needs both.

`test-release-safe`, `test-release-fast`, `test-release-small`, and every
`test-integration*` job deliberately do **not** pass `-Dgrammar=true` and do
**not** carry the `*fetch-ebnf` preamble: without the flag, `b.lazyDependency`
is never reached, so there is nothing to fetch. Grammar coverage for those
optimization levels is intentionally out of scope — `grammar-verify` is the
single source of truth for grammar checks.

The jobs that do need it work around the private-repo fetch with a
`.fetch-ebnf` `before_script` anchor in `.gitlab-ci.yml`:

```bash
git clone --depth 1 --branch v0.2.1 "https://gitlab-ci-token:${CI_JOB_TOKEN}@gitlab.com/devnw/zig/ebnf.git" /tmp/ebnf-dep
zig fetch /tmp/ebnf-dep
```

This clones the tagged ref using the job's own `CI_JOB_TOKEN` (authenticated,
no long-lived secret needed), then runs `zig fetch` against the local clone
so the package lands in the global zig cache keyed by its content hash
(`ebnf-0.2.1-rCUW9PB7AwBS6QjNDMRWrRHUUTkP26sAMN4MK59i3jw5`, matching
`build.zig.zon`). The subsequent `zig build` step then resolves the
dependency from cache with no further network access.

**One-time setup required for this to work**: `CI_JOB_TOKEN`-based cross-project
git clone only succeeds if the `ebnf` project's CI/CD job-token **inbound**
allowlist includes this project (`devnw/zig/gql`). This was configured via:

```bash
glab api --method POST "projects/77156809/job_token_scope/allowlist" -F "target_project_id=80475020"
```

(`77156809` = `devnw/zig/ebnf` project id, `80475020` = `devnw/zig/gql`
project id.) If the `ebnf` project's job-token scope is ever reset, or if
this pipeline runs against a fork/mirror without that allowlist entry, the
`*fetch-ebnf` clone step will fail with an authentication error (redirect to
sign-in / 401). The fix is either:

- Re-run the allowlist API call above (requires Maintainer+ access on the
  `ebnf` project), or
- Make the `ebnf` project public (removing the need for job-token
  authentication entirely), or
- Check `projects/77156809/job_token_scope` (`inbound_enabled`) is still
  `true` and the allowlist (`projects/77156809/job_token_scope/allowlist`,
  paginate with `?per_page=100`) still contains this project's id.

## Known upstream issue: `--fuzz` does not compile under Zig 0.16.0

The CI `fuzz` job (`timeout 60 zig build test --fuzz -Dgrammar=true`) fails
to compile under Zig 0.16.0, on `main` as well as on every branch. The error
is in Zig's own test runner, not in gql:

```text
lib/compiler/test_runner.zig:566:55: error: expected type '*const debug.StackTrace', found '*builtin.StackTrace'
                            std.debug.writeStackTrace(trace, stderr) catch break :p;
referenced by:
    fuzz__anon_...: lib/compiler/test_runner.zig:589:41
    fuzz [inlined]: lib/std/testing.zig:1232:32
    test.fuzz: grammar-derived programs never crash the lexer/parser: tests/grammar_fuzz.zig:118:25
    test.fuzz: parser never crashes on arbitrary input: src/parser.zig:6987:25
```

`test_runner.zig` passes the `*builtin.StackTrace` it holds to
`std.debug.writeStackTrace`, which takes a `*const std.debug.StackTrace` in
0.16.0. That code is compiled only in fuzz mode (`builtin.fuzz`), so every
other test step builds and passes. Reproduce it with
`zig build test -Dgrammar=true --fuzz` on Zig 0.16.0 (SONNY-6645).

- **Not worked around here.** gql keeps the toolchain's test runner. It does
  not vendor a patched copy through `addTest(.{ .test_runner = ... })`, which
  would have to track every Zig release.
- **Coverage meanwhile.** The deterministic 200-seed grammar-fuzz loop in
  `zig build test-grammar -Dgrammar=true` (the `grammar-verify` job) and the
  plain `zig build test` still run both fuzz targets' properties without the
  coverage-guided engine.
- **To close it.** Take a Zig release whose `test_runner.zig` passes the
  matching `StackTrace` type (an upstream fix to Zig's test runner), then
  re-run the `fuzz` job and delete this section.

## Residual gaps and limitations

The grammar-verification system materially reduces (but does not eliminate)
drift between the ISO/IEC 39075 grammar, the Geode extension surface, and
this parser's actual behavior. Known, accepted gaps:

- **`.cypher_compat`-tagged keywords are exempt from all grammar drift
  checks.** Roughly 20 keywords supported for Cypher-compatibility reasons
  (including `SHOW`, `UNWIND`, `MERGE`, `EXPLAIN`) are tagged
  `.cypher_compat` rather than `.iso_gql` in `src/language_metadata.zig`, and
  the keyword-drift test only reconciles `.iso_gql`-tagged keywords against
  `grammar/unimplemented_iso_keywords.txt`. Drift in the `.cypher_compat`
  surface is not caught by this system at all.
- **Keyword drift checks keyword SETS, not production shapes.** The
  drift test verifies that every ISO keyword is either implemented or
  explicitly listed as a known gap — it says nothing about whether an
  implemented keyword's surrounding grammar production (argument order,
  optional clauses, etc.) matches the ISO shape. Production-shape drift is
  caught only statistically, via the generation ratchet and the conformance
  corpus, not exhaustively.
- **`geode.bnf`'s `!!`-note-only entries are unreachable by generation and
  fuzzing.** Some Geode extension points (Geode-specific functions, `ts_*`
  builtins) are documented in `grammar/geode.bnf` as `!!`-prefixed notes
  rather than real productions, so the grammar generator and the
  grammar-guided fuzzer can never derive sentences that exercise them. Their
  coverage depends entirely on the conformance corpus and ordinary unit
  tests, not on this system.
- **The generation ratchet is a single count.** `grammar/generation_ratchet.txt`
  pins one integer — the number of the 500 seeded sentences that currently
  parse. Two offsetting changes (one regression, one improvement) that leave
  the count unchanged would pass silently. The ratchet also runs with
  `tests/grammar_test.zig`'s lexical overrides in place, so it does not cover
  identifier/literal lexing drift; that class of drift is covered instead by
  the override-free `grammar_fuzz` target, which drives the lexer/parser
  directly off fuzz-chosen derivations without the overrides.
- **The conformance corpus pins current behavior, including two known parser
  gaps**: top-level `UNWIND` and `SCAN ... VALUES` are recorded in the corpus
  with `-- expect: error` / `-- unsupported:` headers, i.e. the corpus
  documents that these are not yet supported rather than asserting they
  should be rejected forever.
- **Upstream ISO artifact drift is checked only manually.** `make
  grammar-check-upstream` diffs the vendored `grammar/ISO_IEC_39075.bnf.txt`
  against the live standards.iso.org artifact, but it requires network
  access and is not wired into any CI job (see "`make grammar-fetch` /
  `make grammar-check-upstream`" above) — re-vendoring drift can only be
  caught by someone running it by hand or via a periodic schedule.
- **Per-MR fuzzing is a 200-seed smoke test, not full coverage-guided
  fuzzing.** The `test-grammar` step (and therefore the `grammar-verify` CI
  job that gates merges) runs `tests/grammar_fuzz.zig`'s deterministic
  200-seed loop, which is fast and always-on but bounded. Full
  coverage-guided fuzzing (`zig build test --fuzz`) runs on the scheduled
  `fuzz` job (`.gitlab-ci.yml`'s `fuzz:` job, `rules: if:
  $CI_PIPELINE_SOURCE == "schedule"`), not on every merge request.
