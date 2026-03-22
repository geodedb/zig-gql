# gql

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/Zig-0.15.1+-orange.svg)](https://ziglang.org/)

A Zig library for gql

## Features

- **Zero Dependencies**: Pure Zig standard library only
- **Memory Safe**: Proper allocation patterns with no leaks
- **Cross-Platform**: Linux, macOS, Windows support
- **Well Tested**: Comprehensive unit and integration tests

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
    try gql.init(.{
        .debug = true,
    });
}
```

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
