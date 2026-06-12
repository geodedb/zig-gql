// CANARY: REQ=REQ-METADATA-001; FEATURE="UnifiedLanguageMetadata"; ASPECT=SingleSourceOfTruth; STATUS=TESTED; TEST=geodetestlab/specs/geode_gql_compliance.yml; OWNER=api; UPDATED=2026-01-03
//! # Unified GQL Language Metadata
//!
//! This module serves as the single source of truth for all GQL language elements.
//! All derived artifacts (lexer keywords, LSP completions, syntax highlighting,
//! documentation) should be generated from this metadata at comptime.
//!
//! ## Design Goals
//! - **Single Source**: All language elements defined once
//! - **Comptime Generation**: Derived structures computed at compile time
//! - **Self-Documenting**: Each element includes its documentation
//! - **ISO GQL Compliance**: Track which elements are ISO-standard vs extensions
//!
//! ## Generated Artifacts
//! - Lexer keyword matching (token.zig)
//! - LSP completions and hover (features.zig)
//! - VSCode syntax highlighting (gql.tmLanguage.json)
//! - Neovim syntax (gql.vim)
//! - API documentation (docs/)
//! - Fuzz dictionaries (scripts/)

const std = @import("std");

// ============================================================================
// Keyword Metadata
// ============================================================================

/// Category of a keyword for syntax highlighting and completion grouping
pub const KeywordCategory = enum {
    /// Core query clauses: MATCH, RETURN, WHERE, etc.
    clause,
    /// Modifiers: OPTIONAL, DISTINCT, ALL, etc.
    modifier,
    /// Boolean operators: AND, OR, NOT, XOR
    boolean_operator,
    /// Comparison: IS, IN, STARTS, ENDS, CONTAINS, LIKE
    comparison,
    /// Literals: TRUE, FALSE, NULL
    literal,
    /// Data definition: CREATE, DROP, GRAPH, SCHEMA, etc.
    ddl,
    /// Transaction control: BEGIN, COMMIT, ROLLBACK
    transaction,
    /// Path patterns: SHORTEST, ACYCLIC, SIMPLE, TRAIL, WALK
    path_pattern,
    /// Set operations: UNION, INTERSECT, EXCEPT
    set_operation,
    /// Ordering: ORDER, BY, ASC, DESC, NULLS, FIRST, LAST
    ordering,
    /// Aggregation-related: GROUP, HAVING, AGGREGATE
    aggregation,
    /// Type keywords: NODE, EDGE, PATH, etc.
    type_keyword,
    /// Temporal: DURATION, ZONED, LOCAL
    temporal,
    /// Session/catalog: SESSION, CATALOG, USE, HOME
    session,
    /// Other reserved words
    reserved,
};

/// ISO GQL compliance status
pub const Compliance = enum {
    /// Part of ISO/IEC 39075:2024 standard
    iso_gql,
    /// Geode-specific extension
    geode_extension,
    /// Cypher compatibility (not in ISO GQL)
    cypher_compat,
};

/// Metadata for a single keyword
pub const KeywordInfo = struct {
    /// The keyword string (uppercase)
    name: []const u8,
    /// Category for grouping
    category: KeywordCategory,
    /// ISO compliance status
    compliance: Compliance,
    /// Brief documentation
    doc: []const u8,
    /// Extended documentation/examples (optional)
    extended_doc: ?[]const u8 = null,
};

/// All GQL keywords with metadata
/// Sorted alphabetically for binary search in lexer
pub const keywords = [_]KeywordInfo{
    // A
    .{ .name = "ACYCLIC", .category = .path_pattern, .compliance = .iso_gql, .doc = "Restricts path patterns to acyclic paths (no repeated nodes)" },
    .{ .name = "AGGREGATE", .category = .aggregation, .compliance = .iso_gql, .doc = "Declares an aggregating expression" },
    .{ .name = "ALL", .category = .modifier, .compliance = .iso_gql, .doc = "Include all results (with UNION) or match all elements" },
    .{ .name = "AND", .category = .boolean_operator, .compliance = .iso_gql, .doc = "Logical AND operator" },
    .{ .name = "ANY", .category = .modifier, .compliance = .iso_gql, .doc = "Match any element in a collection" },
    .{ .name = "AS", .category = .modifier, .compliance = .iso_gql, .doc = "Alias assignment for expressions or columns" },
    .{ .name = "ASC", .category = .ordering, .compliance = .iso_gql, .doc = "Ascending sort order" },
    .{ .name = "ASSERT", .category = .ddl, .compliance = .geode_extension, .doc = "Assert a constraint condition" },
    .{ .name = "AVG", .category = .aggregation, .compliance = .iso_gql, .doc = "Average aggregate function" },
    // B
    .{ .name = "BEGIN", .category = .transaction, .compliance = .iso_gql, .doc = "Begin a transaction" },
    .{ .name = "BINDING", .category = .reserved, .compliance = .iso_gql, .doc = "Binding table reference" },
    .{ .name = "BINDINGS", .category = .reserved, .compliance = .iso_gql, .doc = "Multiple binding table references" },
    .{ .name = "BOOLEAN", .category = .type_keyword, .compliance = .iso_gql, .doc = "Boolean type keyword" },
    .{ .name = "BY", .category = .ordering, .compliance = .iso_gql, .doc = "Used with ORDER BY, GROUP BY" },
    // C
    .{ .name = "CALL", .category = .clause, .compliance = .iso_gql, .doc = "Call a procedure" },
    .{ .name = "CASE", .category = .clause, .compliance = .iso_gql, .doc = "Begin a CASE expression" },
    .{ .name = "CAST", .category = .reserved, .compliance = .iso_gql, .doc = "Type casting" },
    .{ .name = "CATALOG", .category = .session, .compliance = .iso_gql, .doc = "Reference to a catalog" },
    .{ .name = "CLOSE", .category = .session, .compliance = .iso_gql, .doc = "Close a session or cursor" },
    .{ .name = "COMMIT", .category = .transaction, .compliance = .iso_gql, .doc = "Commit the current transaction" },
    .{ .name = "CONSTRAINT", .category = .ddl, .compliance = .iso_gql, .doc = "Define a constraint" },
    .{ .name = "CONTAINS", .category = .comparison, .compliance = .iso_gql, .doc = "String containment predicate" },
    .{ .name = "COUNT", .category = .aggregation, .compliance = .iso_gql, .doc = "Count aggregate function" },
    .{ .name = "CREATE", .category = .ddl, .compliance = .iso_gql, .doc = "Create nodes, edges, graphs, or schemas" },
    .{ .name = "CSV", .category = .reserved, .compliance = .cypher_compat, .doc = "CSV file format for LOAD" },
    .{ .name = "CURRENT", .category = .temporal, .compliance = .iso_gql, .doc = "Current timestamp/date/time" },
    // D
    .{ .name = "DATE", .category = .temporal, .compliance = .iso_gql, .doc = "Date type keyword" },
    .{ .name = "DATETIME", .category = .temporal, .compliance = .iso_gql, .doc = "Datetime type keyword" },
    .{ .name = "DECIMAL", .category = .type_keyword, .compliance = .iso_gql, .doc = "Arbitrary-precision decimal type keyword" },
    .{ .name = "DELETE", .category = .clause, .compliance = .iso_gql, .doc = "Delete nodes or edges" },
    .{ .name = "DESC", .category = .ordering, .compliance = .iso_gql, .doc = "Descending sort order" },
    .{ .name = "DETACH", .category = .clause, .compliance = .iso_gql, .doc = "Detach delete (remove edges first)" },
    .{ .name = "DIFFERENT", .category = .modifier, .compliance = .iso_gql, .doc = "Elements must be different" },
    .{ .name = "DISTINCT", .category = .modifier, .compliance = .iso_gql, .doc = "Remove duplicate results" },
    .{ .name = "DROP", .category = .ddl, .compliance = .iso_gql, .doc = "Drop graphs, schemas, or constraints" },
    .{ .name = "DURATION", .category = .temporal, .compliance = .iso_gql, .doc = "Duration type keyword" },
    // E
    .{ .name = "EDGES", .category = .type_keyword, .compliance = .iso_gql, .doc = "Edge elements reference" },
    .{ .name = "ELEMENT", .category = .type_keyword, .compliance = .iso_gql, .doc = "Graph element (node or edge)" },
    .{ .name = "ELSE", .category = .clause, .compliance = .iso_gql, .doc = "ELSE branch in CASE expression" },
    .{ .name = "END", .category = .clause, .compliance = .iso_gql, .doc = "End of CASE expression" },
    .{ .name = "ENDS", .category = .comparison, .compliance = .iso_gql, .doc = "String ends-with predicate" },
    .{ .name = "END_NODE", .category = .type_keyword, .compliance = .cypher_compat, .doc = "End node of a relationship" },
    .{ .name = "EXCEPT", .category = .set_operation, .compliance = .iso_gql, .doc = "Set difference operation" },
    .{ .name = "EXISTS", .category = .comparison, .compliance = .iso_gql, .doc = "Existence predicate" },
    .{ .name = "EXPLAIN", .category = .clause, .compliance = .iso_gql, .doc = "Explain query execution plan" },
    // F
    .{ .name = "FALSE", .category = .literal, .compliance = .iso_gql, .doc = "Boolean false literal" },
    .{ .name = "FILTER", .category = .clause, .compliance = .iso_gql, .doc = "Filter clause" },
    .{ .name = "FINISH", .category = .clause, .compliance = .iso_gql, .doc = "Finish a linear graph query" },
    .{ .name = "FIRST", .category = .ordering, .compliance = .iso_gql, .doc = "NULLS FIRST ordering" },
    .{ .name = "FLOAT", .category = .type_keyword, .compliance = .iso_gql, .doc = "Floating-point type keyword" },
    .{ .name = "FOR", .category = .reserved, .compliance = .iso_gql, .doc = "For loop" },
    .{ .name = "FOREACH", .category = .clause, .compliance = .cypher_compat, .doc = "Iterate over a list" },
    .{ .name = "FROM", .category = .clause, .compliance = .iso_gql, .doc = "Source specification" },
    // G
    .{ .name = "GRAPH", .category = .ddl, .compliance = .iso_gql, .doc = "Graph reference" },
    .{ .name = "GROUP", .category = .aggregation, .compliance = .iso_gql, .doc = "GROUP BY clause" },
    // H
    .{ .name = "HAVING", .category = .aggregation, .compliance = .iso_gql, .doc = "Filter groups after aggregation" },
    .{ .name = "HOME", .category = .session, .compliance = .iso_gql, .doc = "Home graph/schema reference" },
    // I
    .{ .name = "IF", .category = .modifier, .compliance = .iso_gql, .doc = "Conditional execution" },
    .{ .name = "IN", .category = .comparison, .compliance = .iso_gql, .doc = "Membership predicate" },
    .{ .name = "INDEX", .category = .ddl, .compliance = .iso_gql, .doc = "Index definition" },
    .{ .name = "INSERT", .category = .clause, .compliance = .iso_gql, .doc = "Insert data" },
    .{ .name = "INTEGER", .category = .type_keyword, .compliance = .iso_gql, .doc = "Integer type keyword" },
    .{ .name = "INTERSECT", .category = .set_operation, .compliance = .iso_gql, .doc = "Set intersection operation" },
    .{ .name = "IS", .category = .comparison, .compliance = .iso_gql, .doc = "Type/NULL checking predicate" },
    // J
    .{ .name = "JOIN", .category = .clause, .compliance = .iso_gql, .doc = "Join operation" },
    // K
    .{ .name = "KEY", .category = .ddl, .compliance = .iso_gql, .doc = "Key constraint" },
    .{ .name = "KEYS", .category = .reserved, .compliance = .iso_gql, .doc = "Property keys" },
    // L
    .{ .name = "LABELED", .category = .modifier, .compliance = .iso_gql, .doc = "Element has label" },
    .{ .name = "LABELS", .category = .reserved, .compliance = .iso_gql, .doc = "Node/edge labels" },
    .{ .name = "LAST", .category = .ordering, .compliance = .iso_gql, .doc = "NULLS LAST ordering" },
    .{ .name = "LET", .category = .clause, .compliance = .iso_gql, .doc = "Variable binding" },
    .{ .name = "LIKE", .category = .comparison, .compliance = .iso_gql, .doc = "Pattern matching predicate" },
    .{ .name = "LIMIT", .category = .clause, .compliance = .iso_gql, .doc = "Limit number of results" },
    .{ .name = "LIST", .category = .type_keyword, .compliance = .iso_gql, .doc = "List type" },
    .{ .name = "LOAD", .category = .clause, .compliance = .cypher_compat, .doc = "Load data from file" },
    .{ .name = "LOCAL", .category = .temporal, .compliance = .iso_gql, .doc = "Local datetime (without timezone)" },
    // M
    .{ .name = "MATCH", .category = .clause, .compliance = .iso_gql, .doc = "Pattern matching clause" },
    .{ .name = "MAX", .category = .aggregation, .compliance = .iso_gql, .doc = "Maximum aggregate function" },
    .{ .name = "MERGE", .category = .clause, .compliance = .iso_gql, .doc = "Match or create pattern" },
    .{ .name = "MIN", .category = .aggregation, .compliance = .iso_gql, .doc = "Minimum aggregate function" },
    // N
    .{ .name = "NEXT", .category = .reserved, .compliance = .iso_gql, .doc = "Next value" },
    .{ .name = "NO", .category = .modifier, .compliance = .iso_gql, .doc = "Negation modifier" },
    .{ .name = "NODE", .category = .type_keyword, .compliance = .iso_gql, .doc = "Node type reference" },
    .{ .name = "NOT", .category = .boolean_operator, .compliance = .iso_gql, .doc = "Logical NOT operator" },
    .{ .name = "NULL", .category = .literal, .compliance = .iso_gql, .doc = "NULL literal" },
    .{ .name = "NULLS", .category = .ordering, .compliance = .iso_gql, .doc = "NULL ordering specification" },
    // O
    .{ .name = "OF", .category = .reserved, .compliance = .iso_gql, .doc = "Of specification" },
    .{ .name = "OFFSET", .category = .clause, .compliance = .iso_gql, .doc = "Skip results (alias for SKIP)" },
    .{ .name = "ON", .category = .modifier, .compliance = .iso_gql, .doc = "Constraint/index target" },
    .{ .name = "ONLY", .category = .modifier, .compliance = .iso_gql, .doc = "Read only modifier" },
    .{ .name = "OPTIONAL", .category = .modifier, .compliance = .iso_gql, .doc = "Optional pattern matching" },
    .{ .name = "OR", .category = .boolean_operator, .compliance = .iso_gql, .doc = "Logical OR operator" },
    .{ .name = "ORDER", .category = .ordering, .compliance = .iso_gql, .doc = "ORDER BY clause" },
    .{ .name = "ORDINALITY", .category = .reserved, .compliance = .iso_gql, .doc = "Ordinality column" },
    .{ .name = "OTHERWISE", .category = .clause, .compliance = .iso_gql, .doc = "Otherwise branch" },
    // P
    .{ .name = "PATH", .category = .type_keyword, .compliance = .iso_gql, .doc = "Path type" },
    .{ .name = "PATHS", .category = .type_keyword, .compliance = .iso_gql, .doc = "Path patterns" },
    .{ .name = "PERIODIC", .category = .reserved, .compliance = .cypher_compat, .doc = "Periodic commit" },
    .{ .name = "PROFILE", .category = .clause, .compliance = .iso_gql, .doc = "Profile query execution" },
    .{ .name = "PROPERTIES", .category = .reserved, .compliance = .iso_gql, .doc = "Element properties" },
    .{ .name = "PROPERTY", .category = .ddl, .compliance = .iso_gql, .doc = "Property definition" },
    // R
    .{ .name = "READ", .category = .transaction, .compliance = .iso_gql, .doc = "Read transaction mode" },
    .{ .name = "RECORD", .category = .type_keyword, .compliance = .iso_gql, .doc = "Record type" },
    .{ .name = "RELATIONSHIPS", .category = .reserved, .compliance = .cypher_compat, .doc = "Relationships reference" },
    .{ .name = "REMOVE", .category = .clause, .compliance = .iso_gql, .doc = "Remove properties or labels" },
    .{ .name = "REPEATABLE", .category = .transaction, .compliance = .iso_gql, .doc = "Repeatable read isolation" },
    .{ .name = "REPLACE", .category = .clause, .compliance = .iso_gql, .doc = "Replace existing data" },
    .{ .name = "REQUIRE", .category = .ddl, .compliance = .iso_gql, .doc = "Require constraint" },
    .{ .name = "RESET", .category = .session, .compliance = .iso_gql, .doc = "Reset session settings" },
    .{ .name = "RETURN", .category = .clause, .compliance = .iso_gql, .doc = "Return results from query" },
    .{ .name = "ROLLBACK", .category = .transaction, .compliance = .iso_gql, .doc = "Rollback transaction" },
    // S
    .{ .name = "SCAN", .category = .clause, .compliance = .geode_extension, .doc = "Table scan operation" },
    .{ .name = "SCHEMA", .category = .ddl, .compliance = .iso_gql, .doc = "Schema definition" },
    .{ .name = "SELECT", .category = .clause, .compliance = .iso_gql, .doc = "Select clause (table-like)" },
    .{ .name = "SESSION", .category = .session, .compliance = .iso_gql, .doc = "Session reference" },
    .{ .name = "SET", .category = .clause, .compliance = .iso_gql, .doc = "Set properties or variables" },
    .{ .name = "SHORTEST", .category = .path_pattern, .compliance = .iso_gql, .doc = "Shortest path pattern" },
    .{ .name = "SHOW", .category = .clause, .compliance = .iso_gql, .doc = "Show metadata" },
    .{ .name = "SIMPLE", .category = .path_pattern, .compliance = .iso_gql, .doc = "Simple path (no repeated edges)" },
    .{ .name = "SKIP", .category = .clause, .compliance = .iso_gql, .doc = "Skip N results" },
    .{ .name = "START", .category = .transaction, .compliance = .iso_gql, .doc = "Start transaction" },
    .{ .name = "STARTS", .category = .comparison, .compliance = .iso_gql, .doc = "String starts-with predicate" },
    .{ .name = "START_NODE", .category = .type_keyword, .compliance = .cypher_compat, .doc = "Start node of a relationship" },
    .{ .name = "STRING", .category = .type_keyword, .compliance = .iso_gql, .doc = "String type keyword" },
    .{ .name = "SUM", .category = .aggregation, .compliance = .iso_gql, .doc = "Sum aggregate function" },
    // T
    .{ .name = "TABLE", .category = .ddl, .compliance = .iso_gql, .doc = "Table reference" },
    .{ .name = "THEN", .category = .clause, .compliance = .iso_gql, .doc = "THEN branch in CASE" },
    .{ .name = "TIME", .category = .temporal, .compliance = .iso_gql, .doc = "Time type keyword" },
    .{ .name = "TIMESTAMP", .category = .temporal, .compliance = .iso_gql, .doc = "Timestamp type keyword" },
    .{ .name = "TO", .category = .reserved, .compliance = .iso_gql, .doc = "Range endpoint" },
    .{ .name = "TRAIL", .category = .path_pattern, .compliance = .iso_gql, .doc = "Trail path (no repeated edges)" },
    .{ .name = "TRANSACTION", .category = .transaction, .compliance = .iso_gql, .doc = "Transaction keyword" },
    .{ .name = "TRUE", .category = .literal, .compliance = .iso_gql, .doc = "Boolean true literal" },
    .{ .name = "TYPE", .category = .type_keyword, .compliance = .iso_gql, .doc = "Edge type" },
    .{ .name = "TYPES", .category = .type_keyword, .compliance = .iso_gql, .doc = "Edge types" },
    // U
    .{ .name = "UNION", .category = .set_operation, .compliance = .iso_gql, .doc = "Set union operation" },
    .{ .name = "UNKNOWN", .category = .literal, .compliance = .iso_gql, .doc = "Unknown truth value" },
    .{ .name = "UNWIND", .category = .clause, .compliance = .iso_gql, .doc = "Unwind a list into rows" },
    .{ .name = "USE", .category = .session, .compliance = .iso_gql, .doc = "Use graph/catalog" },
    .{ .name = "USING", .category = .modifier, .compliance = .iso_gql, .doc = "Index hint" },
    // V
    .{ .name = "VALUE", .category = .clause, .compliance = .iso_gql, .doc = "Value specification" },
    .{ .name = "VALUES", .category = .clause, .compliance = .iso_gql, .doc = "Multiple values" },
    // W
    .{ .name = "WALK", .category = .path_pattern, .compliance = .iso_gql, .doc = "Walk path (any path)" },
    .{ .name = "WHEN", .category = .clause, .compliance = .iso_gql, .doc = "WHEN branch in CASE" },
    .{ .name = "WHERE", .category = .clause, .compliance = .iso_gql, .doc = "Filter condition" },
    .{ .name = "WITH", .category = .clause, .compliance = .iso_gql, .doc = "Intermediate result binding" },
    .{ .name = "WRITE", .category = .transaction, .compliance = .iso_gql, .doc = "Write transaction mode" },
    // X
    .{ .name = "XOR", .category = .boolean_operator, .compliance = .iso_gql, .doc = "Logical XOR operator" },
    // Y
    .{ .name = "YIELD", .category = .clause, .compliance = .iso_gql, .doc = "Yields named result columns from a procedure CALL (CALL ... YIELD ...)" },
    // Z
    .{ .name = "ZONE", .category = .temporal, .compliance = .iso_gql, .doc = "Time zone" },
    .{ .name = "ZONED", .category = .temporal, .compliance = .iso_gql, .doc = "Zoned datetime" },
};

// ============================================================================
// Function Metadata
// ============================================================================

/// Function category for completion grouping
pub const FunctionCategory = enum {
    /// Aggregate functions: count, sum, avg, min, max, collect
    aggregate,
    /// Scalar functions: abs, ceil, floor, round, sqrt
    scalar_math,
    /// String functions: substring, toLower, toUpper, trim
    scalar_string,
    /// List functions: head, last, tail, reverse, range
    scalar_list,
    /// Type conversion: toInteger, toFloat, toString, toBoolean
    conversion,
    /// Temporal functions: date, time, datetime, duration
    temporal,
    /// Graph functions: nodes, relationships, type, id, labels
    graph,
    /// Path functions: shortestPath, allShortestPaths
    path,
    /// Vector functions: vectorf32, vectori32, distance functions
    vector,
    /// Predicate functions: all, any, none, single
    predicate,
    /// Null handling: coalesce, nullIf
    null_handling,
};

/// Function parameter specification
pub const FunctionParam = struct {
    /// Parameter name
    name: []const u8,
    /// Parameter type (for documentation)
    type_name: []const u8,
    /// Is this parameter optional?
    optional: bool = false,
    /// Default value if optional
    default: ?[]const u8 = null,
};

/// Metadata for a single function
pub const FunctionInfo = struct {
    /// Function name (lowercase)
    name: []const u8,
    /// Category for grouping
    category: FunctionCategory,
    /// Return type
    return_type: []const u8,
    /// Parameters
    params: []const FunctionParam,
    /// ISO compliance status
    compliance: Compliance,
    /// Brief documentation
    doc: []const u8,
    /// Example usage
    example: ?[]const u8 = null,
};

/// All GQL functions with metadata
pub const functions = [_]FunctionInfo{
    // Aggregate functions
    .{
        .name = "count",
        .category = .aggregate,
        .return_type = "INTEGER",
        .params = &[_]FunctionParam{.{ .name = "expr", .type_name = "ANY" }},
        .compliance = .iso_gql,
        .doc = "Count the number of non-null values",
        .example = "RETURN count(n)",
    },
    .{
        .name = "sum",
        .category = .aggregate,
        .return_type = "NUMERIC",
        .params = &[_]FunctionParam{.{ .name = "expr", .type_name = "NUMERIC" }},
        .compliance = .iso_gql,
        .doc = "Sum of numeric values",
        .example = "RETURN sum(n.amount)",
    },
    .{
        .name = "avg",
        .category = .aggregate,
        .return_type = "FLOAT",
        .params = &[_]FunctionParam{.{ .name = "expr", .type_name = "NUMERIC" }},
        .compliance = .iso_gql,
        .doc = "Average of numeric values",
        .example = "RETURN avg(n.score)",
    },
    .{
        .name = "min",
        .category = .aggregate,
        .return_type = "ANY",
        .params = &[_]FunctionParam{.{ .name = "expr", .type_name = "ANY" }},
        .compliance = .iso_gql,
        .doc = "Minimum value",
        .example = "RETURN min(n.created)",
    },
    .{
        .name = "max",
        .category = .aggregate,
        .return_type = "ANY",
        .params = &[_]FunctionParam{.{ .name = "expr", .type_name = "ANY" }},
        .compliance = .iso_gql,
        .doc = "Maximum value",
        .example = "RETURN max(n.price)",
    },
    .{
        .name = "collect",
        .category = .aggregate,
        .return_type = "LIST",
        .params = &[_]FunctionParam{.{ .name = "expr", .type_name = "ANY" }},
        .compliance = .iso_gql,
        .doc = "Collect values into a list",
        .example = "RETURN collect(n.name)",
    },
    // Scalar math functions
    .{
        .name = "abs",
        .category = .scalar_math,
        .return_type = "NUMERIC",
        .params = &[_]FunctionParam{.{ .name = "x", .type_name = "NUMERIC" }},
        .compliance = .iso_gql,
        .doc = "Absolute value",
        .example = "RETURN abs(-5)",
    },
    .{
        .name = "ceil",
        .category = .scalar_math,
        .return_type = "INTEGER",
        .params = &[_]FunctionParam{.{ .name = "x", .type_name = "FLOAT" }},
        .compliance = .iso_gql,
        .doc = "Ceiling (round up)",
        .example = "RETURN ceil(3.2)",
    },
    .{
        .name = "floor",
        .category = .scalar_math,
        .return_type = "INTEGER",
        .params = &[_]FunctionParam{.{ .name = "x", .type_name = "FLOAT" }},
        .compliance = .iso_gql,
        .doc = "Floor (round down)",
        .example = "RETURN floor(3.8)",
    },
    .{
        .name = "round",
        .category = .scalar_math,
        .return_type = "INTEGER",
        .params = &[_]FunctionParam{.{ .name = "x", .type_name = "FLOAT" }},
        .compliance = .iso_gql,
        .doc = "Round to nearest integer",
        .example = "RETURN round(3.5)",
    },
    .{
        .name = "sqrt",
        .category = .scalar_math,
        .return_type = "FLOAT",
        .params = &[_]FunctionParam{.{ .name = "x", .type_name = "NUMERIC" }},
        .compliance = .iso_gql,
        .doc = "Square root",
        .example = "RETURN sqrt(16)",
    },
    .{
        .name = "rand",
        .category = .scalar_math,
        .return_type = "FLOAT",
        .params = &[_]FunctionParam{},
        .compliance = .iso_gql,
        .doc = "Random number between 0 and 1",
        .example = "RETURN rand()",
    },
    .{
        .name = "sign",
        .category = .scalar_math,
        .return_type = "INTEGER",
        .params = &[_]FunctionParam{.{ .name = "x", .type_name = "NUMERIC" }},
        .compliance = .iso_gql,
        .doc = "Sign of a number (-1, 0, or 1)",
        .example = "RETURN sign(-5)",
    },
    .{
        .name = "exp",
        .category = .scalar_math,
        .return_type = "FLOAT",
        .params = &[_]FunctionParam{.{ .name = "x", .type_name = "NUMERIC" }},
        .compliance = .iso_gql,
        .doc = "Exponential (e^x)",
        .example = "RETURN exp(1)",
    },
    .{
        .name = "log",
        .category = .scalar_math,
        .return_type = "FLOAT",
        .params = &[_]FunctionParam{.{ .name = "x", .type_name = "NUMERIC" }},
        .compliance = .iso_gql,
        .doc = "Natural logarithm",
        .example = "RETURN log(10)",
    },
    .{
        .name = "log10",
        .category = .scalar_math,
        .return_type = "FLOAT",
        .params = &[_]FunctionParam{.{ .name = "x", .type_name = "NUMERIC" }},
        .compliance = .iso_gql,
        .doc = "Base-10 logarithm",
        .example = "RETURN log10(100)",
    },
    .{
        .name = "sin",
        .category = .scalar_math,
        .return_type = "FLOAT",
        .params = &[_]FunctionParam{.{ .name = "x", .type_name = "NUMERIC" }},
        .compliance = .iso_gql,
        .doc = "Sine (radians)",
        .example = "RETURN sin(pi()/2)",
    },
    .{
        .name = "cos",
        .category = .scalar_math,
        .return_type = "FLOAT",
        .params = &[_]FunctionParam{.{ .name = "x", .type_name = "NUMERIC" }},
        .compliance = .iso_gql,
        .doc = "Cosine (radians)",
        .example = "RETURN cos(0)",
    },
    .{
        .name = "tan",
        .category = .scalar_math,
        .return_type = "FLOAT",
        .params = &[_]FunctionParam{.{ .name = "x", .type_name = "NUMERIC" }},
        .compliance = .iso_gql,
        .doc = "Tangent (radians)",
        .example = "RETURN tan(pi()/4)",
    },
    .{
        .name = "asin",
        .category = .scalar_math,
        .return_type = "FLOAT",
        .params = &[_]FunctionParam{.{ .name = "x", .type_name = "NUMERIC" }},
        .compliance = .iso_gql,
        .doc = "Arc sine",
        .example = "RETURN asin(0.5)",
    },
    .{
        .name = "acos",
        .category = .scalar_math,
        .return_type = "FLOAT",
        .params = &[_]FunctionParam{.{ .name = "x", .type_name = "NUMERIC" }},
        .compliance = .iso_gql,
        .doc = "Arc cosine",
        .example = "RETURN acos(0.5)",
    },
    .{
        .name = "atan",
        .category = .scalar_math,
        .return_type = "FLOAT",
        .params = &[_]FunctionParam{.{ .name = "x", .type_name = "NUMERIC" }},
        .compliance = .iso_gql,
        .doc = "Arc tangent",
        .example = "RETURN atan(1)",
    },
    .{
        .name = "atan2",
        .category = .scalar_math,
        .return_type = "FLOAT",
        .params = &[_]FunctionParam{
            .{ .name = "y", .type_name = "NUMERIC" },
            .{ .name = "x", .type_name = "NUMERIC" },
        },
        .compliance = .iso_gql,
        .doc = "Two-argument arc tangent",
        .example = "RETURN atan2(1, 1)",
    },
    .{
        .name = "pi",
        .category = .scalar_math,
        .return_type = "FLOAT",
        .params = &[_]FunctionParam{},
        .compliance = .iso_gql,
        .doc = "Mathematical constant pi",
        .example = "RETURN pi()",
    },
    .{
        .name = "e",
        .category = .scalar_math,
        .return_type = "FLOAT",
        .params = &[_]FunctionParam{},
        .compliance = .iso_gql,
        .doc = "Mathematical constant e",
        .example = "RETURN e()",
    },
    .{
        .name = "degrees",
        .category = .scalar_math,
        .return_type = "FLOAT",
        .params = &[_]FunctionParam{.{ .name = "radians", .type_name = "NUMERIC" }},
        .compliance = .iso_gql,
        .doc = "Convert radians to degrees",
        .example = "RETURN degrees(pi())",
    },
    .{
        .name = "radians",
        .category = .scalar_math,
        .return_type = "FLOAT",
        .params = &[_]FunctionParam{.{ .name = "degrees", .type_name = "NUMERIC" }},
        .compliance = .iso_gql,
        .doc = "Convert degrees to radians",
        .example = "RETURN radians(180)",
    },
    // String functions
    .{
        .name = "size",
        .category = .scalar_string,
        .return_type = "INTEGER",
        .params = &[_]FunctionParam{.{ .name = "value", .type_name = "STRING|LIST" }},
        .compliance = .iso_gql,
        .doc = "Length of string or list",
        .example = "RETURN size('hello')",
    },
    .{
        .name = "length",
        .category = .scalar_string,
        .return_type = "INTEGER",
        .params = &[_]FunctionParam{.{ .name = "path", .type_name = "PATH" }},
        .compliance = .iso_gql,
        .doc = "Length of a path",
        .example = "RETURN length(p)",
    },
    .{
        .name = "substring",
        .category = .scalar_string,
        .return_type = "STRING",
        .params = &[_]FunctionParam{
            .{ .name = "str", .type_name = "STRING" },
            .{ .name = "start", .type_name = "INTEGER" },
            .{ .name = "length", .type_name = "INTEGER", .optional = true },
        },
        .compliance = .iso_gql,
        .doc = "Extract substring",
        .example = "RETURN substring('hello', 1, 3)",
    },
    .{
        .name = "replace",
        .category = .scalar_string,
        .return_type = "STRING",
        .params = &[_]FunctionParam{
            .{ .name = "str", .type_name = "STRING" },
            .{ .name = "search", .type_name = "STRING" },
            .{ .name = "replacement", .type_name = "STRING" },
        },
        .compliance = .iso_gql,
        .doc = "Replace occurrences in string",
        .example = "RETURN replace('hello', 'l', 'L')",
    },
    .{
        .name = "toLower",
        .category = .scalar_string,
        .return_type = "STRING",
        .params = &[_]FunctionParam{.{ .name = "str", .type_name = "STRING" }},
        .compliance = .iso_gql,
        .doc = "Convert to lowercase",
        .example = "RETURN toLower('HELLO')",
    },
    .{
        .name = "toUpper",
        .category = .scalar_string,
        .return_type = "STRING",
        .params = &[_]FunctionParam{.{ .name = "str", .type_name = "STRING" }},
        .compliance = .iso_gql,
        .doc = "Convert to uppercase",
        .example = "RETURN toUpper('hello')",
    },
    .{
        .name = "trim",
        .category = .scalar_string,
        .return_type = "STRING",
        .params = &[_]FunctionParam{.{ .name = "str", .type_name = "STRING" }},
        .compliance = .iso_gql,
        .doc = "Remove leading/trailing whitespace",
        .example = "RETURN trim('  hello  ')",
    },
    .{
        .name = "lTrim",
        .category = .scalar_string,
        .return_type = "STRING",
        .params = &[_]FunctionParam{.{ .name = "str", .type_name = "STRING" }},
        .compliance = .iso_gql,
        .doc = "Remove leading whitespace",
        .example = "RETURN lTrim('  hello')",
    },
    .{
        .name = "rTrim",
        .category = .scalar_string,
        .return_type = "STRING",
        .params = &[_]FunctionParam{.{ .name = "str", .type_name = "STRING" }},
        .compliance = .iso_gql,
        .doc = "Remove trailing whitespace",
        .example = "RETURN rTrim('hello  ')",
    },
    .{
        .name = "left",
        .category = .scalar_string,
        .return_type = "STRING",
        .params = &[_]FunctionParam{
            .{ .name = "str", .type_name = "STRING" },
            .{ .name = "n", .type_name = "INTEGER" },
        },
        .compliance = .iso_gql,
        .doc = "Get leftmost n characters",
        .example = "RETURN left('hello', 3)",
    },
    .{
        .name = "right",
        .category = .scalar_string,
        .return_type = "STRING",
        .params = &[_]FunctionParam{
            .{ .name = "str", .type_name = "STRING" },
            .{ .name = "n", .type_name = "INTEGER" },
        },
        .compliance = .iso_gql,
        .doc = "Get rightmost n characters",
        .example = "RETURN right('hello', 3)",
    },
    .{
        .name = "split",
        .category = .scalar_string,
        .return_type = "LIST",
        .params = &[_]FunctionParam{
            .{ .name = "str", .type_name = "STRING" },
            .{ .name = "delimiter", .type_name = "STRING" },
        },
        .compliance = .iso_gql,
        .doc = "Split string into list",
        .example = "RETURN split('a,b,c', ',')",
    },
    .{
        .name = "startsWith",
        .category = .scalar_string,
        .return_type = "BOOLEAN",
        .params = &[_]FunctionParam{
            .{ .name = "str", .type_name = "STRING" },
            .{ .name = "prefix", .type_name = "STRING" },
        },
        .compliance = .iso_gql,
        .doc = "Check if string starts with prefix",
        .example = "RETURN startsWith('hello', 'he')",
    },
    .{
        .name = "endsWith",
        .category = .scalar_string,
        .return_type = "BOOLEAN",
        .params = &[_]FunctionParam{
            .{ .name = "str", .type_name = "STRING" },
            .{ .name = "suffix", .type_name = "STRING" },
        },
        .compliance = .iso_gql,
        .doc = "Check if string ends with suffix",
        .example = "RETURN endsWith('hello', 'lo')",
    },
    .{
        .name = "contains",
        .category = .scalar_string,
        .return_type = "BOOLEAN",
        .params = &[_]FunctionParam{
            .{ .name = "str", .type_name = "STRING" },
            .{ .name = "search", .type_name = "STRING" },
        },
        .compliance = .iso_gql,
        .doc = "Check if string contains substring",
        .example = "RETURN contains('hello', 'ell')",
    },
    .{
        .name = "icontains",
        .category = .scalar_string,
        .return_type = "BOOLEAN",
        .params = &[_]FunctionParam{
            .{ .name = "str", .type_name = "STRING" },
            .{ .name = "search", .type_name = "STRING" },
        },
        .compliance = .geode_extension,
        .doc = "Case-insensitive string containment check",
        .example = "RETURN icontains('Hello World', 'hello')",
    },
    // List functions
    .{
        .name = "head",
        .category = .scalar_list,
        .return_type = "ANY",
        .params = &[_]FunctionParam{.{ .name = "list", .type_name = "LIST" }},
        .compliance = .iso_gql,
        .doc = "First element of list",
        .example = "RETURN head([1, 2, 3])",
    },
    .{
        .name = "last",
        .category = .scalar_list,
        .return_type = "ANY",
        .params = &[_]FunctionParam{.{ .name = "list", .type_name = "LIST" }},
        .compliance = .iso_gql,
        .doc = "Last element of list",
        .example = "RETURN last([1, 2, 3])",
    },
    .{
        .name = "tail",
        .category = .scalar_list,
        .return_type = "LIST",
        .params = &[_]FunctionParam{.{ .name = "list", .type_name = "LIST" }},
        .compliance = .iso_gql,
        .doc = "All but first element of list",
        .example = "RETURN tail([1, 2, 3])",
    },
    .{
        .name = "reverse",
        .category = .scalar_list,
        .return_type = "LIST",
        .params = &[_]FunctionParam{.{ .name = "list", .type_name = "LIST" }},
        .compliance = .iso_gql,
        .doc = "Reverse a list",
        .example = "RETURN reverse([1, 2, 3])",
    },
    .{
        .name = "range",
        .category = .scalar_list,
        .return_type = "LIST",
        .params = &[_]FunctionParam{
            .{ .name = "start", .type_name = "INTEGER" },
            .{ .name = "end", .type_name = "INTEGER" },
            .{ .name = "step", .type_name = "INTEGER", .optional = true, .default = "1" },
        },
        .compliance = .iso_gql,
        .doc = "Create a list of integers",
        .example = "RETURN range(1, 10)",
    },
    // Type conversion functions
    .{
        .name = "toInteger",
        .category = .conversion,
        .return_type = "INTEGER",
        .params = &[_]FunctionParam{.{ .name = "value", .type_name = "ANY" }},
        .compliance = .iso_gql,
        .doc = "Convert to integer",
        .example = "RETURN toInteger('42')",
    },
    .{
        .name = "toFloat",
        .category = .conversion,
        .return_type = "FLOAT",
        .params = &[_]FunctionParam{.{ .name = "value", .type_name = "ANY" }},
        .compliance = .iso_gql,
        .doc = "Convert to float",
        .example = "RETURN toFloat('3.14')",
    },
    .{
        .name = "toString",
        .category = .conversion,
        .return_type = "STRING",
        .params = &[_]FunctionParam{.{ .name = "value", .type_name = "ANY" }},
        .compliance = .iso_gql,
        .doc = "Convert to string",
        .example = "RETURN toString(42)",
    },
    .{
        .name = "toBoolean",
        .category = .conversion,
        .return_type = "BOOLEAN",
        .params = &[_]FunctionParam{.{ .name = "value", .type_name = "ANY" }},
        .compliance = .iso_gql,
        .doc = "Convert to boolean",
        .example = "RETURN toBoolean('true')",
    },
    // Temporal functions
    .{
        .name = "timestamp",
        .category = .temporal,
        .return_type = "INTEGER",
        .params = &[_]FunctionParam{},
        .compliance = .iso_gql,
        .doc = "Current Unix timestamp in milliseconds",
        .example = "RETURN timestamp()",
    },
    .{
        .name = "date",
        .category = .temporal,
        .return_type = "DATE",
        .params = &[_]FunctionParam{.{ .name = "value", .type_name = "STRING", .optional = true }},
        .compliance = .iso_gql,
        .doc = "Create or get current date",
        .example = "RETURN date('2024-01-15')",
    },
    .{
        .name = "time",
        .category = .temporal,
        .return_type = "TIME",
        .params = &[_]FunctionParam{.{ .name = "value", .type_name = "STRING", .optional = true }},
        .compliance = .iso_gql,
        .doc = "Create or get current time",
        .example = "RETURN time('14:30:00')",
    },
    .{
        .name = "datetime",
        .category = .temporal,
        .return_type = "DATETIME",
        .params = &[_]FunctionParam{.{ .name = "value", .type_name = "STRING", .optional = true }},
        .compliance = .iso_gql,
        .doc = "Create or get current datetime",
        .example = "RETURN datetime('2024-01-15T14:30:00Z')",
    },
    .{
        .name = "duration",
        .category = .temporal,
        .return_type = "DURATION",
        .params = &[_]FunctionParam{.{ .name = "value", .type_name = "STRING" }},
        .compliance = .iso_gql,
        .doc = "Create a duration",
        .example = "RETURN duration('P1DT2H')",
    },
    // Graph functions
    .{
        .name = "id",
        .category = .graph,
        .return_type = "INTEGER",
        .params = &[_]FunctionParam{.{ .name = "element", .type_name = "NODE|RELATIONSHIP" }},
        .compliance = .iso_gql,
        .doc = "Get element ID",
        .example = "RETURN id(n)",
    },
    .{
        .name = "type",
        .category = .graph,
        .return_type = "STRING",
        .params = &[_]FunctionParam{.{ .name = "rel", .type_name = "RELATIONSHIP" }},
        .compliance = .iso_gql,
        .doc = "Get relationship type",
        .example = "RETURN type(r)",
    },
    .{
        .name = "labels",
        .category = .graph,
        .return_type = "LIST",
        .params = &[_]FunctionParam{.{ .name = "node", .type_name = "NODE" }},
        .compliance = .iso_gql,
        .doc = "Get node labels",
        .example = "RETURN labels(n)",
    },
    .{
        .name = "properties",
        .category = .graph,
        .return_type = "MAP",
        .params = &[_]FunctionParam{.{ .name = "element", .type_name = "NODE|RELATIONSHIP" }},
        .compliance = .iso_gql,
        .doc = "Get all properties as map",
        .example = "RETURN properties(n)",
    },
    .{
        .name = "keys",
        .category = .graph,
        .return_type = "LIST",
        .params = &[_]FunctionParam{.{ .name = "element", .type_name = "NODE|RELATIONSHIP|MAP" }},
        .compliance = .iso_gql,
        .doc = "Get property keys",
        .example = "RETURN keys(n)",
    },
    .{
        .name = "nodes",
        .category = .graph,
        .return_type = "LIST",
        .params = &[_]FunctionParam{.{ .name = "path", .type_name = "PATH" }},
        .compliance = .iso_gql,
        .doc = "Get nodes in a path",
        .example = "RETURN nodes(p)",
    },
    .{
        .name = "relationships",
        .category = .graph,
        .return_type = "LIST",
        .params = &[_]FunctionParam{.{ .name = "path", .type_name = "PATH" }},
        .compliance = .iso_gql,
        .doc = "Get relationships in a path",
        .example = "RETURN relationships(p)",
    },
    // Path functions
    .{
        .name = "shortestPath",
        .category = .path,
        .return_type = "PATH",
        .params = &[_]FunctionParam{.{ .name = "pattern", .type_name = "PATTERN" }},
        .compliance = .iso_gql,
        .doc = "Find shortest path",
        .example = "MATCH p = shortestPath((a)-[*]-(b)) RETURN p",
    },
    .{
        .name = "allShortestPaths",
        .category = .path,
        .return_type = "LIST",
        .params = &[_]FunctionParam{.{ .name = "pattern", .type_name = "PATTERN" }},
        .compliance = .iso_gql,
        .doc = "Find all shortest paths",
        .example = "MATCH p = allShortestPaths((a)-[*]-(b)) RETURN p",
    },
    // Vector functions (Geode extension)
    .{
        .name = "vectorf32",
        .category = .vector,
        .return_type = "VECTOR",
        .params = &[_]FunctionParam{.{ .name = "list", .type_name = "LIST" }},
        .compliance = .geode_extension,
        .doc = "Create a float32 vector from list",
        .example = "RETURN vectorf32([1.0, 2.0, 3.0])",
    },
    .{
        .name = "vectori32",
        .category = .vector,
        .return_type = "VECTOR",
        .params = &[_]FunctionParam{.{ .name = "list", .type_name = "LIST" }},
        .compliance = .geode_extension,
        .doc = "Create an int32 vector from list",
        .example = "RETURN vectori32([1, 2, 3])",
    },
    .{
        .name = "vector_l2",
        .category = .vector,
        .return_type = "FLOAT",
        .params = &[_]FunctionParam{
            .{ .name = "v1", .type_name = "VECTOR" },
            .{ .name = "v2", .type_name = "VECTOR" },
        },
        .compliance = .geode_extension,
        .doc = "L2 (Euclidean) distance between vectors",
        .example = "RETURN vector_l2(n.embedding, $query)",
    },
    .{
        .name = "vector_cosine",
        .category = .vector,
        .return_type = "FLOAT",
        .params = &[_]FunctionParam{
            .{ .name = "v1", .type_name = "VECTOR" },
            .{ .name = "v2", .type_name = "VECTOR" },
        },
        .compliance = .geode_extension,
        .doc = "Cosine distance between vectors",
        .example = "RETURN vector_cosine(n.embedding, $query)",
    },
    .{
        .name = "vector_dot",
        .category = .vector,
        .return_type = "FLOAT",
        .params = &[_]FunctionParam{
            .{ .name = "v1", .type_name = "VECTOR" },
            .{ .name = "v2", .type_name = "VECTOR" },
        },
        .compliance = .geode_extension,
        .doc = "Dot product of vectors",
        .example = "RETURN vector_dot(n.embedding, $query)",
    },
    .{
        .name = "distance",
        .category = .vector,
        .return_type = "FLOAT",
        .params = &[_]FunctionParam{
            .{ .name = "v1", .type_name = "VECTOR" },
            .{ .name = "v2", .type_name = "VECTOR" },
        },
        .compliance = .geode_extension,
        .doc = "Default distance metric (L2)",
        .example = "RETURN distance(n.embedding, $query)",
    },
    .{
        .name = "similarity",
        .category = .vector,
        .return_type = "FLOAT",
        .params = &[_]FunctionParam{
            .{ .name = "v1", .type_name = "VECTOR" },
            .{ .name = "v2", .type_name = "VECTOR" },
        },
        .compliance = .geode_extension,
        .doc = "Cosine similarity between vectors",
        .example = "RETURN similarity(n.embedding, $query)",
    },
    .{
        .name = "cosine",
        .category = .vector,
        .return_type = "FLOAT",
        .params = &[_]FunctionParam{
            .{ .name = "v1", .type_name = "VECTOR" },
            .{ .name = "v2", .type_name = "VECTOR" },
        },
        .compliance = .geode_extension,
        .doc = "Cosine similarity (alias)",
        .example = "RETURN cosine(n.embedding, $query)",
    },
    .{
        .name = "euclidean",
        .category = .vector,
        .return_type = "FLOAT",
        .params = &[_]FunctionParam{
            .{ .name = "v1", .type_name = "VECTOR" },
            .{ .name = "v2", .type_name = "VECTOR" },
        },
        .compliance = .geode_extension,
        .doc = "Euclidean distance (alias for vector_l2)",
        .example = "RETURN euclidean(n.embedding, $query)",
    },
    .{
        .name = "manhattan",
        .category = .vector,
        .return_type = "FLOAT",
        .params = &[_]FunctionParam{
            .{ .name = "v1", .type_name = "VECTOR" },
            .{ .name = "v2", .type_name = "VECTOR" },
        },
        .compliance = .geode_extension,
        .doc = "Manhattan (L1) distance between vectors",
        .example = "RETURN manhattan(n.embedding, $query)",
    },
    // Predicate functions
    .{
        .name = "all",
        .category = .predicate,
        .return_type = "BOOLEAN",
        .params = &[_]FunctionParam{
            .{ .name = "variable", .type_name = "IDENTIFIER" },
            .{ .name = "list", .type_name = "LIST" },
            .{ .name = "predicate", .type_name = "BOOLEAN" },
        },
        .compliance = .iso_gql,
        .doc = "True if all elements satisfy predicate",
        .example = "RETURN all(x IN [1,2,3] WHERE x > 0)",
    },
    .{
        .name = "any",
        .category = .predicate,
        .return_type = "BOOLEAN",
        .params = &[_]FunctionParam{
            .{ .name = "variable", .type_name = "IDENTIFIER" },
            .{ .name = "list", .type_name = "LIST" },
            .{ .name = "predicate", .type_name = "BOOLEAN" },
        },
        .compliance = .iso_gql,
        .doc = "True if any element satisfies predicate",
        .example = "RETURN any(x IN [1,2,3] WHERE x > 2)",
    },
    .{
        .name = "none",
        .category = .predicate,
        .return_type = "BOOLEAN",
        .params = &[_]FunctionParam{
            .{ .name = "variable", .type_name = "IDENTIFIER" },
            .{ .name = "list", .type_name = "LIST" },
            .{ .name = "predicate", .type_name = "BOOLEAN" },
        },
        .compliance = .iso_gql,
        .doc = "True if no elements satisfy predicate",
        .example = "RETURN none(x IN [1,2,3] WHERE x > 5)",
    },
    .{
        .name = "single",
        .category = .predicate,
        .return_type = "BOOLEAN",
        .params = &[_]FunctionParam{
            .{ .name = "variable", .type_name = "IDENTIFIER" },
            .{ .name = "list", .type_name = "LIST" },
            .{ .name = "predicate", .type_name = "BOOLEAN" },
        },
        .compliance = .iso_gql,
        .doc = "True if exactly one element satisfies predicate",
        .example = "RETURN single(x IN [1,2,3] WHERE x > 2)",
    },
    // Null handling
    .{
        .name = "coalesce",
        .category = .null_handling,
        .return_type = "ANY",
        .params = &[_]FunctionParam{.{ .name = "values", .type_name = "ANY..." }},
        .compliance = .iso_gql,
        .doc = "Return first non-null value",
        .example = "RETURN coalesce(n.name, 'Unknown')",
    },
    .{
        .name = "nullIf",
        .category = .null_handling,
        .return_type = "ANY",
        .params = &[_]FunctionParam{
            .{ .name = "value", .type_name = "ANY" },
            .{ .name = "null_value", .type_name = "ANY" },
        },
        .compliance = .iso_gql,
        .doc = "Return NULL if values are equal",
        .example = "RETURN nullIf(n.status, 'inactive')",
    },
    // Graph degree functions (to be exposed)
    .{
        .name = "indegree",
        .category = .graph,
        .return_type = "INTEGER",
        .params = &[_]FunctionParam{.{ .name = "node", .type_name = "NODE" }},
        .compliance = .geode_extension,
        .doc = "Number of incoming edges to a node",
        .example = "MATCH (n) RETURN n.name, indegree(n)",
    },
    .{
        .name = "outdegree",
        .category = .graph,
        .return_type = "INTEGER",
        .params = &[_]FunctionParam{.{ .name = "node", .type_name = "NODE" }},
        .compliance = .geode_extension,
        .doc = "Number of outgoing edges from a node",
        .example = "MATCH (n) RETURN n.name, outdegree(n)",
    },
};

// ============================================================================
// Type Metadata
// ============================================================================

/// Metadata for a GQL type
pub const TypeInfo = struct {
    /// Type name (uppercase)
    name: []const u8,
    /// ISO compliance status
    compliance: Compliance,
    /// Brief documentation
    doc: []const u8,
    /// Example literal
    example: ?[]const u8 = null,
};

/// All GQL types with metadata
pub const types = [_]TypeInfo{
    .{ .name = "INTEGER", .compliance = .iso_gql, .doc = "64-bit signed integer", .example = "42" },
    .{ .name = "FLOAT", .compliance = .iso_gql, .doc = "64-bit floating point number", .example = "3.14" },
    .{ .name = "STRING", .compliance = .iso_gql, .doc = "Unicode string", .example = "'hello'" },
    .{ .name = "BOOLEAN", .compliance = .iso_gql, .doc = "Boolean (true/false)", .example = "true" },
    .{ .name = "DATE", .compliance = .iso_gql, .doc = "Calendar date", .example = "DATE'2024-01-15'" },
    .{ .name = "TIME", .compliance = .iso_gql, .doc = "Time of day", .example = "TIME'14:30:00'" },
    .{ .name = "DATETIME", .compliance = .iso_gql, .doc = "Date and time with timezone", .example = "DATETIME'2024-01-15T14:30:00Z'" },
    .{ .name = "DURATION", .compliance = .iso_gql, .doc = "Time duration", .example = "DURATION'P1DT2H'" },
    .{ .name = "POINT", .compliance = .iso_gql, .doc = "Geographic point", .example = "point({x: 1.0, y: 2.0})" },
    .{ .name = "VECTOR", .compliance = .geode_extension, .doc = "Fixed-dimension numeric vector for embedding storage. Supports HNSW indexing for efficient similarity search.", .example = "vectorf32([1.0, 2.0, 3.0])" },
    .{ .name = "UUID", .compliance = .geode_extension, .doc = "UUID identifier", .example = "'550e8400-e29b-41d4-a716-446655440000'" },
    .{ .name = "BYTES", .compliance = .iso_gql, .doc = "Binary data", .example = "X'48656C6C6F'" },
    .{ .name = "JSON", .compliance = .geode_extension, .doc = "JSON document", .example = "{\"key\": \"value\"}" },
    .{ .name = "LIST", .compliance = .iso_gql, .doc = "Ordered collection", .example = "[1, 2, 3]" },
    .{ .name = "MAP", .compliance = .iso_gql, .doc = "Key-value map", .example = "{name: 'Alice', age: 30}" },
    .{ .name = "NODE", .compliance = .iso_gql, .doc = "Graph node element", .example = "(n:Person)" },
    .{ .name = "RELATIONSHIP", .compliance = .iso_gql, .doc = "Graph relationship element", .example = "-[r:KNOWS]->" },
    .{ .name = "PATH", .compliance = .iso_gql, .doc = "Graph path", .example = "(a)-[*]->(b)" },
    .{ .name = "GRAPH", .compliance = .iso_gql, .doc = "Named graph", .example = "GRAPH myGraph" },
    .{ .name = "ANY", .compliance = .iso_gql, .doc = "Any type", .example = null },
};

// ============================================================================
// Procedure Metadata
// ============================================================================

/// Procedure category
pub const ProcedureCategory = enum {
    /// Centrality algorithms: degree, betweenness, closeness, etc.
    centrality,
    /// Community detection: louvain, label propagation, leiden
    community,
    /// Path finding: shortest path, BFS, DFS, Dijkstra
    path_finding,
    /// Connectivity: SCC, bridges, articulation points
    connectivity,
    /// Audit logging
    audit,
    /// Transparent Data Encryption
    tde,
    /// Change Data Capture
    cdc,
    /// Row-Level Security
    rls,
};

/// Procedure output column
pub const ProcedureColumn = struct {
    /// Column name
    name: []const u8,
    /// Column type
    type_name: []const u8,
    /// Description
    doc: []const u8,
};

/// Metadata for a procedure
pub const ProcedureInfo = struct {
    /// Full procedure name (e.g., "algo.pagerank.stream")
    name: []const u8,
    /// Short alias (e.g., "pagerank")
    alias: ?[]const u8 = null,
    /// Category
    category: ProcedureCategory,
    /// Output columns
    columns: []const ProcedureColumn,
    /// Brief documentation
    doc: []const u8,
    /// Example usage
    example: ?[]const u8 = null,
};

/// All procedures with metadata
pub const procedures = [_]ProcedureInfo{
    // Centrality algorithms
    .{
        .name = "algo.degree.stream",
        .alias = "degree",
        .category = .centrality,
        .columns = &[_]ProcedureColumn{
            .{ .name = "nodeId", .type_name = "INTEGER", .doc = "Node identifier" },
            .{ .name = "degree", .type_name = "INTEGER", .doc = "Degree centrality value" },
        },
        .doc = "Compute degree centrality for all nodes",
        .example = "CALL algo.degree.stream() YIELD nodeId, degree",
    },
    .{
        .name = "algo.betweenness.stream",
        .alias = "betweenness",
        .category = .centrality,
        .columns = &[_]ProcedureColumn{
            .{ .name = "nodeId", .type_name = "INTEGER", .doc = "Node identifier" },
            .{ .name = "betweenness", .type_name = "FLOAT", .doc = "Betweenness centrality value" },
        },
        .doc = "Compute betweenness centrality for all nodes",
        .example = "CALL algo.betweenness.stream() YIELD nodeId, betweenness",
    },
    .{
        .name = "algo.closeness.stream",
        .alias = "closeness",
        .category = .centrality,
        .columns = &[_]ProcedureColumn{
            .{ .name = "nodeId", .type_name = "INTEGER", .doc = "Node identifier" },
            .{ .name = "closeness", .type_name = "FLOAT", .doc = "Closeness centrality value" },
        },
        .doc = "Compute closeness centrality for all nodes",
        .example = "CALL algo.closeness.stream() YIELD nodeId, closeness",
    },
    .{
        .name = "algo.eigenvector.stream",
        .alias = "eigenvector",
        .category = .centrality,
        .columns = &[_]ProcedureColumn{
            .{ .name = "nodeId", .type_name = "INTEGER", .doc = "Node identifier" },
            .{ .name = "eigenvector", .type_name = "FLOAT", .doc = "Eigenvector centrality value" },
        },
        .doc = "Compute eigenvector centrality for all nodes",
        .example = "CALL algo.eigenvector.stream() YIELD nodeId, eigenvector",
    },
    .{
        .name = "algo.pagerank.stream",
        .alias = "pagerank",
        .category = .centrality,
        .columns = &[_]ProcedureColumn{
            .{ .name = "nodeId", .type_name = "INTEGER", .doc = "Node identifier" },
            .{ .name = "score", .type_name = "FLOAT", .doc = "PageRank score" },
        },
        .doc = "Compute PageRank for all nodes",
        .example = "CALL algo.pagerank.stream({dampingFactor: 0.85}) YIELD nodeId, score",
    },
    .{
        .name = "algo.harmonic.stream",
        .alias = "harmonic",
        .category = .centrality,
        .columns = &[_]ProcedureColumn{
            .{ .name = "nodeId", .type_name = "INTEGER", .doc = "Node identifier" },
            .{ .name = "harmonic", .type_name = "FLOAT", .doc = "Harmonic centrality value" },
        },
        .doc = "Compute harmonic centrality for all nodes",
        .example = "CALL algo.harmonic.stream() YIELD nodeId, harmonic",
    },
    .{
        .name = "algo.bridgeLeverage.stream",
        .alias = "bridgeLeverage",
        .category = .centrality,
        .columns = &[_]ProcedureColumn{
            .{ .name = "nodeId", .type_name = "INTEGER", .doc = "Node identifier" },
            .{ .name = "bridgeLeverage", .type_name = "FLOAT", .doc = "Bridge/leverage centrality value" },
        },
        .doc = "Compute bridge/leverage centrality for all nodes",
        .example = "CALL algo.bridgeLeverage.stream() YIELD nodeId, bridgeLeverage",
    },
    .{
        .name = "algo.greyCardinal.stream",
        .alias = "greyCardinal",
        .category = .centrality,
        .columns = &[_]ProcedureColumn{
            .{ .name = "nodeId", .type_name = "INTEGER", .doc = "Node identifier" },
            .{ .name = "composite", .type_name = "FLOAT", .doc = "Grey cardinal composite score" },
        },
        .doc = "Compute grey cardinal composite centrality",
        .example = "CALL algo.greyCardinal.stream() YIELD nodeId, composite",
    },
    // Community detection
    .{
        .name = "algo.louvain.stream",
        .alias = "louvain",
        .category = .community,
        .columns = &[_]ProcedureColumn{
            .{ .name = "nodeId", .type_name = "INTEGER", .doc = "Node identifier" },
            .{ .name = "community", .type_name = "INTEGER", .doc = "Community identifier" },
        },
        .doc = "Detect communities using Louvain algorithm",
        .example = "CALL algo.louvain.stream() YIELD nodeId, community",
    },
    .{
        .name = "algo.labelPropagation.stream",
        .alias = "labelPropagation",
        .category = .community,
        .columns = &[_]ProcedureColumn{
            .{ .name = "nodeId", .type_name = "INTEGER", .doc = "Node identifier" },
            .{ .name = "label", .type_name = "INTEGER", .doc = "Community label" },
        },
        .doc = "Detect communities using label propagation",
        .example = "CALL algo.labelPropagation.stream() YIELD nodeId, label",
    },
    .{
        .name = "algo.leiden.stream",
        .alias = "leiden",
        .category = .community,
        .columns = &[_]ProcedureColumn{
            .{ .name = "nodeId", .type_name = "INTEGER", .doc = "Node identifier" },
            .{ .name = "community", .type_name = "INTEGER", .doc = "Community identifier" },
        },
        .doc = "Detect communities using Leiden algorithm",
        .example = "CALL algo.leiden.stream() YIELD nodeId, community",
    },
    // Connectivity
    .{
        .name = "algo.unionFind.stream",
        .alias = "unionFind",
        .category = .connectivity,
        .columns = &[_]ProcedureColumn{
            .{ .name = "nodeId", .type_name = "INTEGER", .doc = "Node identifier" },
            .{ .name = "setId", .type_name = "INTEGER", .doc = "Connected component identifier" },
        },
        .doc = "Find connected components using union-find",
        .example = "CALL algo.unionFind.stream() YIELD nodeId, setId",
    },
    .{
        .name = "algo.scc.stream",
        .alias = "scc",
        .category = .connectivity,
        .columns = &[_]ProcedureColumn{
            .{ .name = "nodeId", .type_name = "INTEGER", .doc = "Node identifier" },
            .{ .name = "componentId", .type_name = "INTEGER", .doc = "SCC identifier" },
        },
        .doc = "Find strongly connected components",
        .example = "CALL algo.scc.stream() YIELD nodeId, componentId",
    },
    .{
        .name = "algo.articulationPoints.stream",
        .alias = "articulationPoints",
        .category = .connectivity,
        .columns = &[_]ProcedureColumn{
            .{ .name = "nodeId", .type_name = "INTEGER", .doc = "Articulation point node ID" },
        },
        .doc = "Find articulation points (cut vertices)",
        .example = "CALL algo.articulationPoints.stream() YIELD nodeId",
    },
    .{
        .name = "algo.bridges.stream",
        .alias = "bridges",
        .category = .connectivity,
        .columns = &[_]ProcedureColumn{
            .{ .name = "sourceId", .type_name = "INTEGER", .doc = "Bridge source node ID" },
            .{ .name = "targetId", .type_name = "INTEGER", .doc = "Bridge target node ID" },
        },
        .doc = "Find bridge edges (cut edges)",
        .example = "CALL algo.bridges.stream() YIELD sourceId, targetId",
    },
    .{
        .name = "algo.biconnectedComponents.stream",
        .alias = "biconnected",
        .category = .connectivity,
        .columns = &[_]ProcedureColumn{
            .{ .name = "nodeId", .type_name = "INTEGER", .doc = "Node identifier" },
            .{ .name = "componentId", .type_name = "INTEGER", .doc = "Biconnected component ID" },
        },
        .doc = "Find biconnected components",
        .example = "CALL algo.biconnectedComponents.stream() YIELD nodeId, componentId",
    },
    // Graph Statistics (#67)
    .{
        .name = "algo.graphDensity.stream",
        .alias = "graphDensity",
        .category = .connectivity,
        .columns = &[_]ProcedureColumn{
            .{ .name = "density", .type_name = "FLOAT", .doc = "Graph density value (0-1)" },
        },
        .doc = "Compute graph density (ratio of edges to max possible edges)",
        .example = "CALL algo.graphDensity.stream() YIELD density",
    },
    .{
        .name = "algo.graphDiameter.stream",
        .alias = "graphDiameter",
        .category = .connectivity,
        .columns = &[_]ProcedureColumn{
            .{ .name = "diameter", .type_name = "INTEGER", .doc = "Graph diameter (longest shortest path)" },
        },
        .doc = "Compute graph diameter (longest shortest path between any two nodes)",
        .example = "CALL algo.graphDiameter.stream() YIELD diameter",
    },
    .{
        .name = "algo.meanDistance.stream",
        .alias = "meanDistance",
        .category = .connectivity,
        .columns = &[_]ProcedureColumn{
            .{ .name = "meanDistance", .type_name = "FLOAT", .doc = "Average shortest path length" },
        },
        .doc = "Compute mean distance (average path length) between all node pairs",
        .example = "CALL algo.meanDistance.stream() YIELD meanDistance",
    },
    .{
        .name = "algo.globalClustering.stream",
        .alias = "globalClustering",
        .category = .connectivity,
        .columns = &[_]ProcedureColumn{
            .{ .name = "coefficient", .type_name = "FLOAT", .doc = "Global clustering coefficient" },
        },
        .doc = "Compute global clustering coefficient (ratio of triangles)",
        .example = "CALL algo.globalClustering.stream() YIELD coefficient",
    },
    // Katz and HITS Centrality (#69)
    .{
        .name = "algo.katz.stream",
        .alias = "katz",
        .category = .centrality,
        .columns = &[_]ProcedureColumn{
            .{ .name = "nodeId", .type_name = "INTEGER", .doc = "Node identifier" },
            .{ .name = "score", .type_name = "FLOAT", .doc = "Katz centrality score" },
        },
        .doc = "Compute Katz centrality (weighted paths with attenuation)",
        .example = "CALL algo.katz.stream({alpha: 0.1}) YIELD nodeId, score",
    },
    .{
        .name = "algo.hits.stream",
        .alias = "hits",
        .category = .centrality,
        .columns = &[_]ProcedureColumn{
            .{ .name = "nodeId", .type_name = "INTEGER", .doc = "Node identifier" },
            .{ .name = "hub", .type_name = "FLOAT", .doc = "Hub score" },
            .{ .name = "authority", .type_name = "FLOAT", .doc = "Authority score" },
        },
        .doc = "Compute HITS hub and authority scores (Kleinberg algorithm)",
        .example = "CALL algo.hits.stream() YIELD nodeId, hub, authority",
    },
    // Triangle Counting and Clustering (#70)
    .{
        .name = "algo.triangleCounting.stream",
        .alias = "triangleCounting",
        .category = .connectivity,
        .columns = &[_]ProcedureColumn{
            .{ .name = "count", .type_name = "INTEGER", .doc = "Total triangle count" },
        },
        .doc = "Count total triangles in the graph",
        .example = "CALL algo.triangleCounting.stream() YIELD count",
    },
    .{
        .name = "algo.localClustering.stream",
        .alias = "localClustering",
        .category = .connectivity,
        .columns = &[_]ProcedureColumn{
            .{ .name = "nodeId", .type_name = "INTEGER", .doc = "Node identifier" },
            .{ .name = "coefficient", .type_name = "FLOAT", .doc = "Local clustering coefficient" },
        },
        .doc = "Compute local clustering coefficient per node",
        .example = "CALL algo.localClustering.stream() YIELD nodeId, coefficient",
    },
    // K-Core and K-Shell Decomposition (#71)
    .{
        .name = "algo.kcore.stream",
        .alias = "kcore",
        .category = .community,
        .columns = &[_]ProcedureColumn{
            .{ .name = "nodeId", .type_name = "INTEGER", .doc = "Node identifier" },
            .{ .name = "coreness", .type_name = "INTEGER", .doc = "K-core value (coreness)" },
        },
        .doc = "Compute k-core decomposition (coreness for each node)",
        .example = "CALL algo.kcore.stream() YIELD nodeId, coreness",
    },
    .{
        .name = "algo.kshell.stream",
        .alias = "kshell",
        .category = .community,
        .columns = &[_]ProcedureColumn{
            .{ .name = "nodeId", .type_name = "INTEGER", .doc = "Node identifier" },
            .{ .name = "shell", .type_name = "INTEGER", .doc = "K-shell value" },
        },
        .doc = "Compute k-shell decomposition (shell for each node)",
        .example = "CALL algo.kshell.stream() YIELD nodeId, shell",
    },
};

// ============================================================================
// Comptime Helpers
// ============================================================================

/// Get keyword names as a comptime array for lexer
pub fn getKeywordNames() [keywords.len][]const u8 {
    var names: [keywords.len][]const u8 = undefined;
    for (keywords, 0..) |kw, i| {
        names[i] = kw.name;
    }
    return names;
}

/// Get function names as a comptime array for LSP
pub fn getFunctionNames() [functions.len][]const u8 {
    var names: [functions.len][]const u8 = undefined;
    for (functions, 0..) |f, i| {
        names[i] = f.name;
    }
    return names;
}

/// Get type names as a comptime array for LSP
pub fn getTypeNames() [types.len][]const u8 {
    var names: [types.len][]const u8 = undefined;
    for (types, 0..) |t, i| {
        names[i] = t.name;
    }
    return names;
}

/// Get procedure names as a comptime array
pub fn getProcedureNames() [procedures.len][]const u8 {
    var names: [procedures.len][]const u8 = undefined;
    for (procedures, 0..) |p, i| {
        names[i] = p.name;
    }
    return names;
}

/// Check if a keyword is part of the ISO/IEC 39075:2024 standard.
pub fn isIsoKeyword(name: []const u8) bool {
    const kw = findKeyword(name) orelse return false;
    return kw.compliance == .iso_gql;
}

/// Check if a function is part of the ISO/IEC 39075:2024 standard.
pub fn isIsoFunction(name: []const u8) bool {
    const f = findFunction(name) orelse return false;
    return f.compliance == .iso_gql;
}

/// Check if a type is part of the ISO/IEC 39075:2024 standard.
pub fn isIsoType(name: []const u8) bool {
    const t = findType(name) orelse return false;
    return t.compliance == .iso_gql;
}

/// Find keyword info by name (case-insensitive)
pub fn findKeyword(name: []const u8) ?KeywordInfo {
    for (keywords) |kw| {
        if (std.ascii.eqlIgnoreCase(name, kw.name)) {
            return kw;
        }
    }
    return null;
}

/// Find function info by name (case-sensitive for functions)
pub fn findFunction(name: []const u8) ?FunctionInfo {
    for (functions) |f| {
        if (std.mem.eql(u8, name, f.name)) {
            return f;
        }
    }
    return null;
}

/// Find type info by name (case-insensitive)
pub fn findType(name: []const u8) ?TypeInfo {
    for (types) |t| {
        if (std.ascii.eqlIgnoreCase(name, t.name)) {
            return t;
        }
    }
    return null;
}

/// Find procedure info by name or alias
pub fn findProcedure(name: []const u8) ?ProcedureInfo {
    for (procedures) |p| {
        if (std.mem.eql(u8, name, p.name)) {
            return p;
        }
        if (p.alias) |alias| {
            if (std.mem.eql(u8, name, alias)) {
                return p;
            }
        }
    }
    return null;
}

// ============================================================================
// Tests
// ============================================================================

test "keywords are sorted" {
    var prev: []const u8 = "";
    for (keywords) |kw| {
        if (prev.len > 0) {
            const cmp = std.mem.order(u8, prev, kw.name);
            if (cmp != .lt) {
                std.debug.print("Keywords not sorted: '{s}' should come before '{s}'\n", .{ kw.name, prev });
            }
            try std.testing.expect(cmp == .lt);
        }
        prev = kw.name;
    }
}

test "findKeyword works" {
    const match_kw = findKeyword("MATCH");
    try std.testing.expect(match_kw != null);
    try std.testing.expectEqualStrings("MATCH", match_kw.?.name);

    const match_lower = findKeyword("match");
    try std.testing.expect(match_lower != null);
    try std.testing.expectEqualStrings("MATCH", match_lower.?.name);

    const not_found = findKeyword("NOTAKEYWORD");
    try std.testing.expect(not_found == null);
}

test "findFunction works" {
    const count_fn = findFunction("count");
    try std.testing.expect(count_fn != null);
    try std.testing.expectEqualStrings("count", count_fn.?.name);

    const not_found = findFunction("notafunction");
    try std.testing.expect(not_found == null);
}

test "findProcedure works with alias" {
    const pagerank = findProcedure("algo.pagerank.stream");
    try std.testing.expect(pagerank != null);

    const pagerank_alias = findProcedure("pagerank");
    try std.testing.expect(pagerank_alias != null);
    try std.testing.expectEqualStrings("algo.pagerank.stream", pagerank_alias.?.name);
}

test "findType works" {
    const integer_type = findType("INTEGER");
    try std.testing.expect(integer_type != null);
    try std.testing.expectEqualStrings("INTEGER", integer_type.?.name);

    const integer_lower = findType("integer");
    try std.testing.expect(integer_lower != null);
    try std.testing.expectEqualStrings("INTEGER", integer_lower.?.name);

    const vector_type = findType("VECTOR");
    try std.testing.expect(vector_type != null);
    try std.testing.expect(vector_type.?.compliance == .geode_extension);

    const not_found = findType("NOTATYPE");
    try std.testing.expect(not_found == null);
}

test "all keywords have required fields" {
    for (keywords) |kw| {
        try std.testing.expect(kw.name.len > 0);
        try std.testing.expect(kw.doc.len > 0);
    }
}

test "all functions have required fields" {
    for (functions) |f| {
        try std.testing.expect(f.name.len > 0);
        try std.testing.expect(f.return_type.len > 0);
        try std.testing.expect(f.doc.len > 0);
    }
}

test "all types have required fields" {
    for (types) |t| {
        try std.testing.expect(t.name.len > 0);
        try std.testing.expect(t.doc.len > 0);
    }
}

test "all procedures have required fields" {
    for (procedures) |p| {
        try std.testing.expect(p.name.len > 0);
        try std.testing.expect(p.doc.len > 0);
        try std.testing.expect(p.columns.len > 0);
    }
}

test "getKeywordNames returns correct count" {
    const names = comptime getKeywordNames();
    try std.testing.expectEqual(keywords.len, names.len);
}

test "getFunctionNames returns correct count" {
    const names = comptime getFunctionNames();
    try std.testing.expectEqual(functions.len, names.len);
}

test "getTypeNames returns correct count" {
    const names = comptime getTypeNames();
    try std.testing.expectEqual(types.len, names.len);
}

test "getProcedureNames returns correct count" {
    const names = comptime getProcedureNames();
    try std.testing.expectEqual(procedures.len, names.len);
}

test "keyword categories are valid" {
    var clause_count: usize = 0;
    var modifier_count: usize = 0;
    var aggregation_count: usize = 0;

    for (keywords) |kw| {
        switch (kw.category) {
            .clause => clause_count += 1,
            .modifier => modifier_count += 1,
            .aggregation => aggregation_count += 1,
            else => {},
        }
    }

    // Verify we have keywords in major categories
    try std.testing.expect(clause_count > 0);
    try std.testing.expect(modifier_count > 0);
    try std.testing.expect(aggregation_count > 0);
}

test "function categories are valid" {
    var aggregate_count: usize = 0;
    var scalar_math_count: usize = 0;
    var vector_count: usize = 0;

    for (functions) |f| {
        switch (f.category) {
            .aggregate => aggregate_count += 1,
            .scalar_math => scalar_math_count += 1,
            .vector => vector_count += 1,
            else => {},
        }
    }

    // Verify we have functions in major categories
    try std.testing.expect(aggregate_count > 0);
    try std.testing.expect(scalar_math_count > 0);
    try std.testing.expect(vector_count > 0);
}

test "iso_gql compliance keywords exist" {
    var iso_count: usize = 0;
    for (keywords) |kw| {
        if (kw.compliance == .iso_gql) {
            iso_count += 1;
        }
    }
    // Most keywords should be ISO GQL compliant
    try std.testing.expect(iso_count > keywords.len / 2);
}

test "vector functions are geode extensions" {
    const vectorf32 = findFunction("vectorf32");
    try std.testing.expect(vectorf32 != null);
    try std.testing.expect(vectorf32.?.compliance == .geode_extension);

    const vector_l2 = findFunction("vector_l2");
    try std.testing.expect(vector_l2 != null);
    try std.testing.expect(vector_l2.?.compliance == .geode_extension);
}

test "aggregate functions return correct types" {
    const count_fn = findFunction("count");
    try std.testing.expect(count_fn != null);
    try std.testing.expectEqualStrings("INTEGER", count_fn.?.return_type);

    const avg_fn = findFunction("avg");
    try std.testing.expect(avg_fn != null);
    try std.testing.expectEqualStrings("FLOAT", avg_fn.?.return_type);

    const collect_fn = findFunction("collect");
    try std.testing.expect(collect_fn != null);
    try std.testing.expectEqualStrings("LIST", collect_fn.?.return_type);
}

test "function parameters are valid" {
    const substring = findFunction("substring");
    try std.testing.expect(substring != null);
    try std.testing.expectEqual(@as(usize, 3), substring.?.params.len);

    // Check first param
    try std.testing.expectEqualStrings("str", substring.?.params[0].name);
    try std.testing.expect(!substring.?.params[0].optional);

    // Check optional param
    try std.testing.expect(substring.?.params[2].optional);
}

test "procedure columns are properly defined" {
    const pagerank = findProcedure("algo.pagerank.stream");
    try std.testing.expect(pagerank != null);
    try std.testing.expectEqual(@as(usize, 2), pagerank.?.columns.len);

    // Check column names
    try std.testing.expectEqualStrings("nodeId", pagerank.?.columns[0].name);
    try std.testing.expectEqualStrings("score", pagerank.?.columns[1].name);
}

test "VECTOR type doc mentions HNSW" {
    const vector_type = findType("VECTOR");
    try std.testing.expect(vector_type != null);
    try std.testing.expect(std.mem.indexOf(u8, vector_type.?.doc, "HNSW") != null);
}

test "ISO vs extension separation is queryable" {
    // ISO keywords
    try std.testing.expect(isIsoKeyword("MATCH"));
    try std.testing.expect(isIsoKeyword("RETURN"));
    try std.testing.expect(isIsoKeyword("WHERE"));

    // Geode extensions are properly labeled
    try std.testing.expect(!isIsoKeyword("SCAN"));
    try std.testing.expect(!isIsoKeyword("ASSERT"));

    // ISO types
    try std.testing.expect(isIsoType("INTEGER"));
    try std.testing.expect(isIsoType("STRING"));

    // Extension types
    try std.testing.expect(!isIsoType("VECTOR"));
    try std.testing.expect(!isIsoType("UUID"));

    // ISO functions
    try std.testing.expect(isIsoFunction("count"));
    try std.testing.expect(isIsoFunction("sum"));

    // Extension functions
    try std.testing.expect(!isIsoFunction("vectorf32"));
}

test "core GQL keywords present" {
    // Verify essential GQL keywords exist
    try std.testing.expect(findKeyword("MATCH") != null);
    try std.testing.expect(findKeyword("RETURN") != null);
    try std.testing.expect(findKeyword("WHERE") != null);
    try std.testing.expect(findKeyword("CREATE") != null);
    try std.testing.expect(findKeyword("DELETE") != null);
    try std.testing.expect(findKeyword("SET") != null);
    try std.testing.expect(findKeyword("ORDER") != null);
    try std.testing.expect(findKeyword("BY") != null);
    try std.testing.expect(findKeyword("LIMIT") != null);
    try std.testing.expect(findKeyword("UNION") != null);
}

test "core GQL types present" {
    // Verify essential GQL types exist
    try std.testing.expect(findType("INTEGER") != null);
    try std.testing.expect(findType("FLOAT") != null);
    try std.testing.expect(findType("STRING") != null);
    try std.testing.expect(findType("BOOLEAN") != null);
    try std.testing.expect(findType("NODE") != null);
    try std.testing.expect(findType("RELATIONSHIP") != null);
    try std.testing.expect(findType("PATH") != null);
    try std.testing.expect(findType("LIST") != null);
    try std.testing.expect(findType("MAP") != null);
}

test "core GQL functions present" {
    // Verify essential GQL functions exist
    try std.testing.expect(findFunction("count") != null);
    try std.testing.expect(findFunction("sum") != null);
    try std.testing.expect(findFunction("avg") != null);
    try std.testing.expect(findFunction("min") != null);
    try std.testing.expect(findFunction("max") != null);
    try std.testing.expect(findFunction("collect") != null);
    try std.testing.expect(findFunction("id") != null);
    try std.testing.expect(findFunction("labels") != null);
    try std.testing.expect(findFunction("type") != null);
}
