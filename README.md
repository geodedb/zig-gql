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
- **Minimal Dependencies**: Pure Zig standard library by default; optional [spice](https://gitlab.com/devnw/zig/spice) integration for parallelism (`-Dspice=true`)
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

The library includes optional parallel processing support via the [spice](https://gitlab.com/devnw/zig/spice) thread pool. Enable it at build time:

```bash
zig build -Dspice=true
zig build test -Dspice=true
```

When spice is enabled, the `parallel` module provides fork/join APIs for processing parsed AST statements across multiple cores:

- `parallelProcessStatements` -- map a function over each statement in parallel
- `parallelValidateStatements` -- count statements matching a predicate in parallel
- `parallelCount` -- generic parallel counted predicate over any slice

When spice is **not** enabled (the default), all functions degrade to sequential execution with zero overhead. No code changes are required.

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

## Documentation

See the [docs](docs/) directory for detailed documentation.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## Security

See [SECURITY.md](SECURITY.md) for security policy and vulnerability reporting.

## License

This project is licensed under the Apache License 2.0 - see the [LICENSE](LICENSE) file for details.
