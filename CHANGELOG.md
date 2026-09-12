# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Initial project structure
- Core library implementation
- Unit and integration tests
- CI/CD pipeline
- Documentation

## [0.1.14] - 2026-09-12

### Changed

- Converge thread_pool v0.2.7, fips v0.1.1, protobuf v0.1.5, config v0.1.13 (GAP-0838 diamond sync).

## [0.1.13] - 2026-09-12

### Changed

- Converge thread_pool v0.2.7, fips v0.1.1, protobuf v0.1.5 (GAP-0838 diamond sync).

## [0.1.0] - 2026-03-22

### Added

- GQL front-end extracted from the Geode graph database
- Lexer, parser, and full AST types for GQL (ISO/IEC 39075:2024)
- Human-readable and JSON pretty printers
- ISO/IEC 39075 status codes and diagnostic helpers
- Language metadata (keywords, built-in functions, types, procedures)
- Temporal parsing and formatting helpers
- Unicode identifier support
- Field-Level Encryption AST extensions (Geode extension)

[Unreleased]: https://gitlab.com/devnw/zig/gql/-/compare/v0.1.0...HEAD
[0.1.0]: https://gitlab.com/devnw/zig/gql/-/releases/v0.1.0
