# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.22] - 2026-11-16

### Changed

- **BREAKING:** `SQLSTATE.SYNTAX_ERROR` is 42000 and `syntaxError` reports
  it: a program that does not conform to the Format, or violates a Syntax
  Rule that names no explicit condition, raises "syntax error or access
  rule violation" (42000, ISO/IEC 39075:2024 4.7.3 step 4 a, e). It was
  the PostgreSQL 42601 (SONNY-6543).
- **BREAKING:** `SQLSTATE.UNDEFINED_OBJECT` and `undefinedIdentifier` are
  42002, Table 8's "syntax error or access rule violation - invalid
  reference" (23.2 GR 2 d ties the INVALID_REFERENCE diagnostic to it). It
  was the PostgreSQL 42703 (SONNY-6543).
- The `PRIVILEGE_VIOLATION` (42501) comment cited 4.2.4.2 for the code;
  4.2.4.2 and 4.7.3 give the class (42000), the subclass 501 is
  implementation-defined (23.1).

### Added

- `SQLSTATE.INVALID_REFERENCE` (42002), `SQLSTATE.INVALID_SYNTAX` (42001)
  and `SQLSTATE.INVALID_CHARACTER_VALUE_FOR_CAST` (22018, the Table 8 name
  of `INVALID_CHARACTER`, kept as an alias).

### Removed

- **BREAKING:** `invalidCharacter(message, line, column)`. 22018 is a
  data exception a cast raises on a value; it carries no source position,
  and nothing called the helper. Use `invalidCharacterValueForCast(message)`
  (SONNY-6543).

## [0.1.20] - 2026-10-12

### Changed

- Pin OTEL v0.1.27 to converge the final dependency graph after its CI header-provisioning fix. Runtime algorithms and benchmark budgets remain unchanged.

### Added

- Initial project structure
- Core library implementation
- Unit and integration tests
- CI/CD pipeline
- Documentation

## [0.1.15] - 2026-09-15

### Changed

- Converge grpc_zig v0.1.10 (GAP-0838 diamond sync).

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
