# Requirements

Last updated: 2026-03-21

## Functional Requirements

| ID | Requirement | Geode evidence |
|---|---|---|
| GQL-REQ-001 | The library SHALL expose the canonical AST types. | `src/gql/ast.zig:5`, `:7`, `:252` |
| GQL-REQ-002 | The library SHALL expose token kinds, keyword resolution, and identifier helpers. | `src/gql/token.zig:6`, `:216`, `:423` |
| GQL-REQ-003 | The library SHALL expose a lexer. | `src/gql/lexer.zig:5`, `:13`, `:620` |
| GQL-REQ-004 | The library SHALL expose a parser with a program-level entry point. | `src/gql/parser.zig:13`, `:371` |
| GQL-REQ-005 | The library SHALL expose human-readable and JSON printers. | `src/gql/print.zig:12`, `:42`, `:51` |
| GQL-REQ-006 | The library SHALL expose status/diagnostic helpers. | `src/gql/status.zig:10`, `:49`, `:109` |
| GQL-REQ-007 | The library SHALL expose language metadata for keywords, functions, types, and procedures. | `src/gql/language_metadata.zig:73`, `:1554`, `:1590` |
| GQL-REQ-008 | The library SHALL NOT own Geode execution/planner adapters. | `src/gql/match.zig:176`, `src/gql/recommendations.zig:30`, `:46` stay in Geode |

## Packaging Requirements

| ID | Requirement | Geode evidence |
|---|---|---|
| GQL-PKG-001 | Package imports SHALL be normalized so parser/token modules build standalone. | standalone review failures for `src/gql/parser.zig` and `src/gql/token.zig` |
| GQL-PKG-002 | Unicode helper ownership SHALL be explicit and documented. | `src/unicode/unicode_tables.zig:9`, `:145`, `:179` |
| GQL-PKG-003 | ISO metadata and Geode extensions SHALL be labeled distinctly in documentation. | `src/gql/language_metadata.zig:1801`, `:1848` |

## Test Requirements

| ID | Requirement | Geode evidence |
|---|---|---|
| GQL-TEST-001 | Port token, lexer, parser, status, metadata, and temporal unit tests. | `src/gql/token.zig:453` through `:538`, `src/gql/lexer.zig:698` through `:811`, `src/gql/parser.zig:6591`, `:6604`, `:6617`, `src/gql/status.zig:197` through `:234`, `src/gql/language_metadata.zig:1638` through `:1881`, `src/temporal.zig:403`, `:413`, `:430`, `:438`, `:446` |
| GQL-TEST-002 | Preserve generated conformance coverage. | `build.zig:759`, `:767`, `:772` |
| GQL-TEST-003 | Preserve parser fuzzing. | `build.zig:1086` |

## Documentation Requirements

- Provide one parser example.
- Provide one printer example.
- Document ISO-vs-extension metadata boundaries.
- Document the Unicode and temporal helpers this repo owns.

## Migration Requirements

1. Extract the front-end only.
2. Keep `match` and recommendation behavior in Geode.
3. Rewire Geode to consume this repo for AST, lexer, parser, printers, and status helpers.
