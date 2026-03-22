# Full Codebase Audit Summary

**Date:** 2026-03-22
**Auditor:** Automated (gap analysis + quality + performance + security)

## Repository

- **Project:** gitlab.com/devnw/zig/gql
- **Platform:** GitLab
- **Languages:** Zig (100%, 12,378 lines across 10 source files)
- **Dependencies:** Zero external
- **Scope:** Entire repo
- **Version:** 0.1.0 (pre-release, 2 commits on main + uncommitted extraction)

## Domain Results

### Gap Analysis

| Status | Count | Percentage |
|--------|-------|-----------|
| Implemented | 90 | 85% |
| Partial | 4 | 4% |
| Not Implemented | 6 | 6% |
| Out of Scope | 6 | 5% |

**106 total requirements** traced from REQUIREMENTS.md, GAP_ANALYSIS.md, build config, CI, and 61 CANARY-tagged features.

**Open gaps:**
- GQL-TEST-002: Conformance harness not ported (Geode-specific)
- GQL-TEST-003: Fuzz testing not ported (Geode-specific)
- GQL-DOC-002: No printer usage example
- GQL-RW-002: Conformance entries for standalone CI
- GQL-RW-003: Parser fuzz-test wiring
- GQL-RW-004: Parser benchmark suite

**Conflicts found:** 7 (README Quick Start wrong, CHANGELOG placeholder, SECURITY.md references GitHub, docs dead links, CODEOWNERS placeholder, FLE undocumented, CANARY test refs stale)

### Code Quality

| Severity | Count |
|----------|-------|
| Critical | 2 |
| High | 3 |
| Medium | 5 |
| Low | 5 |

**Top findings:**
- parser.zig is 6,628 lines with 881-line `parseStatement` (8x over 800-line limit)
- 5 dead functions in lexer.zig (~120 lines unreachable code)
- 3 files with zero tests: ast.zig (662 lines), print.zig (769 lines), unicode_tables.zig (219 lines)
- parser.zig has 3 tests for 6,628 lines (0.05% density)
- RETURN clause parsing duplicated 11 times inline
- Static mutable GPA in print.zig (never freed, thread-unsafe)
- SQLSTATE code collision: INVALID_SCHEMA and PRIVILEGE_VIOLATION both map to "42000"

### Performance

| PerfSeverity | Count |
|-------------|-------|
| P0 (Critical) | 2 |
| P1 (High) | 2 |
| P2 (Medium) | 3 |
| P3 (Low) | 3 |

**Top findings:**
- No expression recursion depth guard (stack overflow on malicious input)
- Global mutable GPA in print.zig (thread-unsafe, never freed)
- caseFoldToUpper() heap-allocates per identifier (even ASCII-only)
- peekKind()/peek2Kind() copy entire Lexer struct and re-lex at 14+ sites
- No benchmark suite exists
- 83 ArrayList instantiations with zero initial capacity
- CI installs Zig 5 times with no caching

### Security

| Risk Level | Count |
|-----------|-------|
| Critical | 0 |
| High | 2 |
| Medium | 4 |
| Low | 6 |

**Zero secrets detected.** Zero external dependencies. Zero SAST findings.

**High findings:**
1. Unbounded recursive descent -- stack overflow via deeply nested expressions (no depth limit)
2. Arena allocator with no memory budget -- OOM via large crafted queries

**Medium findings:**
3. Global mutable GPA in print.zig -- data race in multi-threaded use
4. encryption_key stored in AST -- potential secret leakage if AST serialized
5. Integer truncation: decimal scale u8 overflows at 256+ fractional digits
6. Float-to-i128 conversion: `1e300` panics on `@intFromFloat`

## Cross-Domain Summary

| Domain | Findings | Issues Created | Issues Updated | Issues Closed |
|--------|----------|---------------|----------------|---------------|
| Gap Analysis | 10 | 0 (skip-issues) | 0 | 0 |
| Quality | 15 | 0 (skip-issues) | 0 | 0 |
| Performance | 10 | 0 (skip-issues) | 0 | 0 |
| Security | 12 | 0 (skip-issues) | 0 | 0 |
| **Total** | **47** | **0** | **0** | **0** |

*Note: Platform issue creation skipped (GitLab access not configured).*

## Docs Updated

| File | Domain | Action |
|------|--------|--------|
| docs/GAP_ANALYSIS.md | Gap | Previously updated (3 gaps closed) |
| docs/AUDIT_REPORT.md | All | Created (this file) |

## Top 15 Findings (cross-domain, by severity)

| # | Domain | Finding | Severity | File |
|---|--------|---------|----------|------|
| 1 | Security | Unbounded recursive descent -- stack overflow | HIGH | parser.zig:2896-3956 |
| 2 | Security | Arena allocator with no memory budget | HIGH | parser.zig:15 |
| 3 | Quality | parser.zig is 6,628 lines / parseStatement is 881 lines | CRITICAL | parser.zig |
| 4 | Quality | 3 files with zero tests (ast, print, unicode) | CRITICAL | ast.zig, print.zig, unicode_tables.zig |
| 5 | Perf | caseFoldToUpper heap-allocates per identifier | HIGH | unicode_tables.zig:145 |
| 6 | Perf | peekKind/peek2Kind re-lex at 14+ sites | HIGH | parser.zig:225-236 |
| 7 | Security | Global mutable GPA -- thread-unsafe | MEDIUM | print.zig:39-40 |
| 8 | Security | Decimal scale u8 overflow at 256+ digits | MEDIUM | parser.zig:3726 |
| 9 | Security | Float-to-i128 overflow on large exponents | MEDIUM | parser.zig:3717 |
| 10 | Security | encryption_key in AST, potential leakage | MEDIUM | ast.zig:563 |
| 11 | Quality | 5 dead functions in lexer.zig | HIGH | lexer.zig:387-545 |
| 12 | Quality | RETURN clause parsing duplicated 11x | MEDIUM | parser.zig (11 sites) |
| 13 | Quality | SQLSTATE collision: INVALID_SCHEMA = PRIVILEGE_VIOLATION | MEDIUM | status.zig:41-42 |
| 14 | Gap | README Quick Start shows nonexistent API | MEDIUM | README.md:47 |
| 15 | Gap | 69 CANARY test references point to nonexistent Geode paths | LOW | parser.zig, ast.zig (69 sites) |

## Recommended Priority Actions

### Immediate (before any release)

1. **Add recursion depth guard** to expression parser (~10 lines of code change)
2. **Document arena memory budget** for callers; add example with capped allocator
3. **Fix README Quick Start** to show actual Lexer+Parser API
4. **Fix examples/basic.zig** to demonstrate real parsing
5. **Clamp decimal scale and validate float range** before @intCast/@intFromFloat

### Short-term (before v0.1.0 stable)

6. **Remove 5 dead lexer functions** (scanDoubleQuoted_OLD, scanDoubleQuoted, scanQuotedIdentifier, scanStringLiteral, nextAfterKeyword)
7. **Add ASCII fast-path to caseFoldToUpper** (stack buffer for pure-ASCII identifiers)
8. **Extract RETURN clause parsing** into a shared helper (eliminate 11x duplication)
9. **Add print.zig tests** (currently zero coverage on 769 lines)
10. **Fix or remove global GPA** in print.zig (use caller-provided allocator)

### Medium-term

11. **Add parser benchmark suite** (lexer throughput MB/s, parser queries/s)
12. **Add fuzz testing** for lexer and parser
13. **Split parser.zig** into sub-modules (expressions, patterns, DDL, session)
14. **Fix boilerplate** (CHANGELOG date, SECURITY.md GitHub ref, CODEOWNERS placeholder, docs dead links)
15. **Update or remove stale CANARY test references** (69 markers referencing Geode paths)

## Blockers

- **No Zig-specific SAST tool**: Automated SAST has limited Zig coverage. All Zig findings are from manual code review.
- **Platform issue sync skipped**: GitLab API access not configured. Findings documented in this file only.
