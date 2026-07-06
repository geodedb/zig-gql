# gql - Zig Library Makefile
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2024-2025 CodePros

.PHONY: all build test test-unit test-integration clean check grammar-fetch grammar-check-upstream test-grammar grammar-fuzz fmt help dev ci
.PHONY: test-release-safe test-release-fast test-release-small test-all-optimizations
.PHONY: pre-commit-install pre-commit pre-commit-run
.PHONY: bench scale-bench bench-save bench-compare bench-baseline

# Grammar artifact URLs and paths
GRAMMAR_URL := https://standards.iso.org/iso-iec/39075/ed-1/en/ISO_IEC_39075(en).bnf.txt
GRAMMAR_FILE := grammar/ISO_IEC_39075.bnf.txt

# Default target: build and run tests
all: build test-unit
	@echo "✅ All builds and tests completed successfully!"

# Build the library
build:
	@echo "🔨 Building gql..."
	@zig build

# Run all tests
test: test-unit test-integration
	@echo "✅ All tests completed"

# Run unit tests only
test-unit:
	@echo "🧪 Running unit tests..."
	@zig build test --summary all

# Run integration tests only
test-integration:
	@echo "🔗 Running integration tests..."
	@zig build test-integration --summary all

# Run performance benchmarks
bench:
	@echo "Running benchmarks..."
	@zig build bench

# Incremental scale benchmark
scale-bench:
	@echo "Running incremental scale benchmark..."
	@zig build scale-bench 2>/dev/null

# Run scale bench and save results
bench-save:
	@echo "Running scale benchmark and saving results..."
	@zig build scale-bench 2>/dev/null > benchmarks/results/$$(git rev-parse --short HEAD).json
	@echo "Saved to benchmarks/results/$$(git rev-parse --short HEAD).json"

# Compare current results against baseline
bench-compare:
	@echo "Running scale benchmark and comparing against baseline..."
	@zig build scale-bench 2>/dev/null > /tmp/current-gql-bench.json
	@zig build compare-bench -- benchmarks/results/baseline.json /tmp/current-gql-bench.json

# Save current results as the baseline
bench-baseline:
	@echo "Running scale benchmark and saving as baseline..."
	@zig build scale-bench 2>/dev/null > benchmarks/results/baseline.json
	@echo "Saved to benchmarks/results/baseline.json"

# Clean build artifacts
clean:
	@echo "🧹 Cleaning build artifacts..."
	@rm -rf zig-cache zig-out .zig-cache

# Check for compilation errors (fast, no codegen)
check:
	@echo "🔍 Checking for compilation errors..."
	@zig build check

# Download the ISO/IEC 39075 BNF grammar artifact into grammar/
grammar-fetch:
	curl -fsSL '$(GRAMMAR_URL)' -o $(GRAMMAR_FILE)
	@echo "fetched $$(wc -l < $(GRAMMAR_FILE)) lines into $(GRAMMAR_FILE)"

# Verify the vendored ISO grammar matches the upstream artifact
grammar-check-upstream:
	@tmp=$$(mktemp); curl -fsSL '$(GRAMMAR_URL)' -o $$tmp && \
	  diff -u $(GRAMMAR_FILE) $$tmp && echo "vendored grammar matches upstream" ; \
	  rc=$$?; rm -f $$tmp; exit $$rc

# Run grammar verification tests
test-grammar:
	@echo "📜 Running grammar verification tests..."
	@zig build test-grammar --summary all

# Run grammar-guided fuzzing (time-boxed 60s, rc 124 = clean timeout).
#
# CI's `fuzz:` job (.gitlab-ci.yml) runs `zig build test --fuzz` on zig
# 0.16.0, which fuzzes every `std.testing.fuzz` target reachable from the
# `test` step -- including tests/grammar_fuzz.zig (this target) AND
# src/parser.zig's pre-existing Smith-based `fuzzParseOne`.
#
# Locally, zig is pinned to 0.15.2, which does not have `std.testing.Smith`
# at all: `zig build test --fuzz` fails to compile fuzzParseOne (a
# pre-existing, unrelated gap -- see src/parser.zig:6947) and then the
# 0.15.2 fuzz-runner itself crashes when zero fuzz entry points survive
# compilation. That means `zig build test --fuzz` cannot be run locally
# today regardless of this target.
#
# So this target scopes fuzzing to the `test-grammar` step instead, which
# compiles under both 0.15.2 and 0.16.0 (tests/grammar_fuzz.zig's fuzz body
# is written to work under either std.testing.fuzz API -- see the
# `has_smith` comptime branch there) and exercises the exact same
# grammar-guided property CI fuzzes via the `test` step.
#
# CAVEAT (observed, not theoretical): zig 0.15.2's coverage-guided `--fuzz`
# runner is itself flaky here independent of any of the above -- across a
# handful of local runs it sometimes completes the full time-box cleanly
# (rc=124) and sometimes crashes a few seconds in with
# `panic: start index 1 is larger than end index 0` inside
# `std/Build/Fuzz.zig:429 (addEntryPoint)`, a zig-internal coverage
# bookkeeping bug with a single valid fuzz entry point, not a grammar_fuzz.zig
# defect. Because that failure mode is non-deterministic on 0.15.2 and not
# reproducible on CI's 0.16.0, the AUTHORITATIVE local check for this
# property is the deterministic 200-seed loop in `zig build test-grammar`
# (no --fuzz, see tests/grammar_fuzz.zig); this target is a best-effort local
# approximation of CI's coverage-guided run, not a required-green gate.
grammar-fuzz:
	@echo "🧬 Running grammar-guided fuzzing (60s, local: test-grammar step)..."
	timeout 60 zig build test-grammar --fuzz; rc=$$?; [ $$rc -eq 124 ] && exit 0 || exit $$rc

# Format source code
fmt:
	@echo "📝 Formatting code..."
	@zig fmt src/ tests/ benchmarks/ build.zig

# Quick development iteration loop
dev: fmt check test-unit
	@echo "✅ Development checks passed"

# Full CI pipeline (clean slate)
# `grammar-check-upstream` is deliberately NOT included: it requires network
# access to the ISO standards site and depends on upstream artifact
# availability, neither of which should gate a merge. It stays a
# manual/scheduled check (see `make grammar-check-upstream`).
ci: clean build test test-grammar
	@echo "✅ CI pipeline passed"

# Release optimization level tests
test-release-safe:
	@echo "🧪 Testing with ReleaseSafe..."
	@zig build test -Doptimize=ReleaseSafe --summary all

test-release-fast:
	@echo "🧪 Testing with ReleaseFast..."
	@zig build test -Doptimize=ReleaseFast --summary all

test-release-small:
	@echo "🧪 Testing with ReleaseSmall..."
	@zig build test -Doptimize=ReleaseSmall --summary all

test-all-optimizations: test-unit test-release-safe test-release-fast test-release-small
	@echo "✅ All optimization levels passed"

# Pre-commit hook management
pre-commit-install:
	@echo "📦 Installing pre-commit hooks..."
	@pre-commit install
	@pre-commit install --hook-type commit-msg
	@pre-commit install --hook-type pre-push

pre-commit:
	@echo "🔍 Running pre-commit checks..."
	@pre-commit run --all-files

pre-commit-run: pre-commit

# Display help
help:
	@echo "gql - Zig Library"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "Development:"
	@echo "  all                  Build and run tests (default)"
	@echo "  build                Build the library"
	@echo "  dev                  Quick iteration: fmt + check + test"
	@echo "  ci                   Full CI: clean + build + test + grammar"
	@echo ""
	@echo "Testing:"
	@echo "  test                 Run all tests"
	@echo "  test-unit            Run unit tests only"
	@echo "  test-integration     Run integration tests only"
	@echo "  test-release-safe    Test with ReleaseSafe"
	@echo "  test-release-fast    Test with ReleaseFast"
	@echo "  test-release-small   Test with ReleaseSmall"
	@echo "  test-all-optimizations  Test all optimization levels"
	@echo ""
	@echo "Benchmarks:"
	@echo "  bench                Run performance benchmarks"
	@echo "  scale-bench          Run incremental scale benchmark"
	@echo "  bench-save           Run scale bench and save results"
	@echo "  bench-baseline       Save current results as baseline"
	@echo "  bench-compare        Compare current against baseline"
	@echo ""
	@echo "Code Quality:"
	@echo "  fmt                  Format source code"
	@echo "  check                Check for compilation errors"
	@echo "  pre-commit           Run pre-commit hooks"
	@echo "  pre-commit-install   Install pre-commit hooks"
	@echo ""
	@echo "Grammar:"
	@echo "  grammar-fetch        Download the ISO/IEC 39075 BNF grammar artifact"
	@echo "  grammar-check-upstream  Verify vendored grammar matches upstream"
	@echo "  test-grammar         Run grammar verification tests"
	@echo "  grammar-fuzz         Run grammar-guided fuzzing (60s time-boxed)"
	@echo ""
	@echo "Maintenance:"
	@echo "  clean                Remove build artifacts"
	@echo "  help                 Show this help message"
