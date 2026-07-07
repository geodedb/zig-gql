# gql

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/Zig-0.15.1+-orange.svg)](https://ziglang.org/)

A Zig library for gql

## Features

- **GQL Lexer**: Tokenizes GQL (ISO/IEC 39075:2024) source text
- **GQL Parser**: Produces a typed AST from the token stream
- **AST Types**: Full node definitions for statements, expressions, patterns, and graph DDL
- **Pretty Printers**: Human-readable and JSON output for AST programs
- **Status Codes**: ISO/IEC 39075 diagnostic status codes and helpers
- **Language Metadata**: Keyword tables, built-in functions, types, and procedures
- **Minimal Dependencies**: Pure Zig standard library by default; optional [thread-pool](https://gitlab.com/devnw/zig/thread-pool) integration for parallelism (`-Dthread_pool=true`)
- **Memory Safe**: Arena-based allocation with no leaks
- **Cross-Platform**: Linux, macOS, Windows support

## Installation

### Using Zig Package Manager

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .gql = .{
        .url = "https://gitlab.com/devnw/zig/gql/-/archive/v0.1.0/gql-v0.1.0.tar.gz",
        .hash = "...",
    },
},
```

Then in your `build.zig`:

```zig
const gql = b.dependency("gql", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("gql", gql.module("gql"));
```

## Quick Start

```zig
const std = @import("std");
const gql = @import("gql");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var lx = gql.Lexer{ .src = "MATCH (n:Person) RETURN n.name" };
    var parser = gql.Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    const program = try parser.parseProgram();
    _ = program; // Use the parsed AST
}
```

## Parallelism

The library includes optional parallel processing support via the [thread-pool](https://gitlab.com/devnw/zig/thread-pool) library. Enable it at build time:

```bash
zig build -Dthread_pool=true
zig build test -Dthread_pool=true
```

When thread-pool is enabled, the `parallel` module provides fork/join APIs for processing parsed AST statements across multiple cores:

- `parallelProcessStatements` -- map a function over each statement in parallel
- `parallelValidateStatements` -- count statements matching a predicate in parallel
- `parallelCount` -- generic parallel counted predicate over any slice

When thread-pool is **not** enabled (the default), all functions degrade to sequential execution with zero overhead. No code changes are required.

**Thread Safety:** The Lexer and Parser are not thread-safe -- create separate instances per thread. Parsed AST nodes are immutable and safe to share. See the module doc comment in `src/root.zig` for full details.

## Requirements

- Zig 0.15.1 or later

## Building

```bash
# Build the library
make build

# Run tests
make test

# Quick development iteration
make dev

# Full CI pipeline
make ci
```

## Grammar Verification

`make test-grammar` (part of `make ci`) checks this parser against the
vendored ISO/IEC 39075 BNF grammar and the Geode extension grammar: keyword
drift, a conformance corpus, a deterministic generation ratchet, and a
grammar-guided fuzz smoke loop. See
[docs/GRAMMAR_VERIFICATION.md](docs/GRAMMAR_VERIFICATION.md) for the
architecture, how to update the ratchet files, and how to add corpus
entries.

## Observability

This library ships an optional OpenTelemetry seam, gated behind
`-Dwith_otel=<bool>` (default `false`).

> **Current status (temporary):** the seam is compiled as a permanent
> no-op regardless of `-Dwith_otel`. `gql.observability.enabled` is
> hardcoded `false` to avoid a Zig 0.16 module-dedup diamond
> (`build_options` vs `build_options0`) that surfaced when this library is
> reached through multiple paths in a downstream build graph. Until the
> upstream dedup behavior is resolved, building with `-Dwith_otel=true`
> compiles the enabled-mode test scaffolding but **emits no telemetry** —
> every helper still returns a zero-sized `Span{}`. The span shape and
> bootstrap API documented below describe the intended behavior once the
> conditional is restored. Track this in `src/observability.zig`.

When `-Dwith_otel=false` (the default) the seam collapses to a
comptime-known no-op: every public helper in `gql.observability`
returns a zero-sized `Span{}`, the otel dependency is never resolved,
and the produced artifact contains zero otel symbols (verified by
`otel/scripts/verify-consumer-noop.sh`).

When `-Dwith_otel=true`, `gql.Parser.parseProgram` emits **one
client-kind span per top-level parse call**. Each span is named
`"gql.{operation_type}"` (e.g. `"gql.query"`) and carries the standard
GraphQL semantic-convention attributes:

- `db.system = "graphql"`
- `graphql.operation.type` (e.g. `"query"`, `"mutation"`, `"subscription"`)
- `graphql.operation.name` (when the caller supplies one)
- `graphql.errors.count` (recoverable diagnostics observed during the parse)

By default we do NOT set `db.statement` to the full query body — GQL
queries can be long and may contain PII embedded in literals. Consumers
that have explicitly sanitised their query text can opt in via
`gql.observability.setQueryStatement(span, body)`, which truncates to
1024 bytes (`gql.observability.max_statement_bytes`) to keep span
attribute sizes bounded.

Bootstrap from your application entry point:

```zig
const std = @import("std");
const gql = @import("gql");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();

    var otel = try gql.observability_init.Otel.init(gpa.allocator(), "my-app");
    otel.installGlobals();
    defer otel.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    var lx = gql.Lexer{ .src = "MATCH (n) RETURN n" };
    var parser = gql.Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    _ = try parser.parseProgram(); // emits a span
}
```

Configuration follows the OpenTelemetry environment-variable contract
(`OTEL_SERVICE_NAME`, `OTEL_TRACES_SAMPLER`, `OTEL_EXPORTER_OTLP_ENDPOINT`,
etc). Defaults: `parentbased_traceidratio` @ 5%, OTLP/HTTP to
`http://localhost:4318`.

Verification gates (all three must pass):

```bash
zig build test                      # default flag = false
zig build test -Dwith_otel=true     # flag on
otel/scripts/verify-consumer-noop.sh --worktree <name> gql  # symbol-leak check
```

See [otel/docs/integration/RECIPE.md](https://gitlab.com/devnw/zig/otel/-/blob/main/docs/integration/RECIPE.md)
for the full recipe.

## Documentation

See the [docs](docs/) directory for detailed documentation.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## Security

See [SECURITY.md](SECURITY.md) for security policy and vulnerability reporting.

## License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE) file for details.
