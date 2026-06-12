const std = @import("std");
const language_metadata = @import("language_metadata.zig");

// CANARY: REQ=REQ-LEXER-METADATA-001; FEATURE="MetadataIntegration"; ASPECT=KeywordLookup; STATUS=EXEMPT; OWNER=lexer; UPDATED=2026-01-03
// Minimal ISO/IEC 39075:2024 GQL token set (subset; expandable).
pub const TokenKind = enum {
    // delimiters/operators
    l_paren,
    r_paren,
    l_bracket,
    r_bracket,
    l_brace,
    r_brace,
    comma,
    colon,
    semicolon,
    dot,
    dotdot,
    plus,
    minus,
    star,
    slash,
    percent,
    lt,
    gt,
    le,
    ge,
    eq,
    ne,
    regex_match, // =~
    regex_not_match, // !~
    concat, // ||
    bar, // |
    dollar, // $
    arrow_r, // ->
    arrow_l, // <-
    double_arrow, // =>
    at, // @ (for field annotations - Geode extension)
    caret, // ^ (power operator)

    // literals & identifiers
    identifier,
    quoted_identifier,
    integer_lit,
    float_lit,
    string_lit,
    date_lit,
    datetime_lit,
    time_lit,
    local_datetime_lit,

    // keywords (ISO/IEC 39075:2024 reserved words; case-insensitive in lexer)
    MATCH,
    OPTIONAL,
    WHERE,
    RETURN,
    WITH,
    CASE,
    WHEN,
    THEN,
    ELSE,
    END,
    AND,
    OR,
    NOT,
    IN,
    IS,
    STARTS,
    ENDS,
    CONTAINS,
    CALL,
    YIELD,
    TRUE,
    FALSE,
    NULL,
    AS,
    DISTINCT,
    UNION,
    INTERSECT,
    EXCEPT,
    ALL,
    SESSION,
    SET,
    RESET,
    CLOSE,
    INSERT,
    VALUE,
    VALUES,
    SCAN,
    START,
    TRANSACTION,
    BEGIN,
    COMMIT,
    ROLLBACK,
    CREATE,
    DELETE,
    MERGE,
    SHOW,
    EXPLAIN,
    PROFILE,
    GRAPH,
    PROPERTY,
    DROP,
    ORDER,
    BY,
    GROUP,
    ASC,
    DESC,
    LIMIT,
    OFFSET,
    SKIP,
    HAVING,
    NULLS,
    FIRST,
    LAST,
    ON,
    UNKNOWN,
    // Additional ISO reserved words
    FILTER,
    LET,
    SELECT,
    FROM,
    EXISTS,
    DETACH,
    REMOVE,
    FOR,
    FOREACH,
    UNWIND,
    USE,
    USING,
    INDEX,
    JOIN,
    IF,
    TO,
    KEY,
    KEYS,
    LABELS,
    LOAD,
    CSV,
    PERIODIC,
    PROPERTIES,
    RELATIONSHIPS,
    START_NODE,
    END_NODE,
    TYPE,
    TYPES,

    // Critical missing ISO GQL keywords (avoiding duplicates)
    ACYCLIC,
    AGGREGATE,
    ANY,
    AVG,
    CATALOG,
    CAST,
    CONSTRAINT,
    COUNT,
    CURRENT,
    DIFFERENT,
    DURATION,
    EDGES,
    ELEMENT,
    FINISH,
    HOME,
    LABELED,
    LIKE,
    LIST,
    LOCAL,
    MAX,
    MIN,
    NEXT,
    NODE,
    OF,
    OTHERWISE,
    PATH,
    PATHS,
    RECORD,
    REPEATABLE,
    REPLACE,
    REQUIRE,
    ASSERT,
    SCHEMA,
    SHORTEST,
    SIMPLE,
    SUM,
    TABLE,
    TRAIL,
    WALK,
    XOR,
    ZONED,
    ZONE,
    BINDING,
    ORDINALITY,
    READ,
    WRITE,
    NO,
    BINDINGS,
    ONLY,

    // Type keywords for CAST expressions
    DECIMAL,
    INTEGER,
    FLOAT,
    STRING,
    BOOLEAN,
    TIMESTAMP,
    DATETIME,
    DATE,
    TIME,

    eof,
    invalid,
};

pub const Location = struct { line: u32, column: u32 };

pub const Token = struct {
    kind: TokenKind,
    lexeme: []const u8, // slice into source buffer
    loc: Location,
};

const unicode = @import("unicode/unicode_tables.zig");

// Unicode-aware identifier checking
pub fn isIdentifierStart(cp: u21) bool {
    return unicode.isIdentifierStart(cp);
}

pub fn isIdentifierContinue(cp: u21) bool {
    return unicode.isIdentifierContinue(cp);
}

// ASCII digit check (for compatibility)
pub fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

// Unicode digit check
pub fn isUnicodeDigit(cp: u21) bool {
    return unicode.isDecimalDigit(cp);
}

// Convert Unicode digit to ASCII value
pub fn digitToAscii(cp: u21) ?u8 {
    return unicode.digitToAscii(cp);
}

// CANARY: REQ=REQ-LEXER-METADATA-002; FEATURE="MetadataIntegration"; ASPECT=ComptimeKeywordMap; STATUS=EXEMPT; OWNER=lexer; UPDATED=2026-01-03
// Comptime-generated keyword map using StaticStringMap for O(1) lookup
// Keywords are sourced from language_metadata.zig for single source of truth
const KeywordMap = std.StaticStringMap(TokenKind).initComptime(.{
    // Core clauses
    .{ "MATCH", .MATCH },
    .{ "OPTIONAL", .OPTIONAL },
    .{ "WHERE", .WHERE },
    .{ "RETURN", .RETURN },
    .{ "WITH", .WITH },
    .{ "CASE", .CASE },
    .{ "WHEN", .WHEN },
    .{ "THEN", .THEN },
    .{ "ELSE", .ELSE },
    .{ "END", .END },
    // Boolean operators
    .{ "AND", .AND },
    .{ "OR", .OR },
    .{ "NOT", .NOT },
    .{ "XOR", .XOR },
    // Comparison
    .{ "IN", .IN },
    .{ "IS", .IS },
    .{ "STARTS", .STARTS },
    .{ "ENDS", .ENDS },
    .{ "CONTAINS", .CONTAINS },
    .{ "LIKE", .LIKE },
    // Procedures
    .{ "CALL", .CALL },
    .{ "YIELD", .YIELD },
    // Literals
    .{ "TRUE", .TRUE },
    .{ "FALSE", .FALSE },
    .{ "NULL", .NULL },
    // Modifiers
    .{ "AS", .AS },
    .{ "DISTINCT", .DISTINCT },
    .{ "ALL", .ALL },
    .{ "ANY", .ANY },
    // Set operations
    .{ "UNION", .UNION },
    .{ "INTERSECT", .INTERSECT },
    .{ "EXCEPT", .EXCEPT },
    // Session
    .{ "SESSION", .SESSION },
    .{ "SET", .SET },
    .{ "RESET", .RESET },
    .{ "CLOSE", .CLOSE },
    // DML
    .{ "INSERT", .INSERT },
    .{ "VALUE", .VALUE },
    .{ "VALUES", .VALUES },
    .{ "SCAN", .SCAN },
    // Transaction
    .{ "START", .START },
    .{ "TRANSACTION", .TRANSACTION },
    .{ "BEGIN", .BEGIN },
    .{ "COMMIT", .COMMIT },
    .{ "ROLLBACK", .ROLLBACK },
    // DDL
    .{ "CREATE", .CREATE },
    .{ "DELETE", .DELETE },
    .{ "MERGE", .MERGE },
    .{ "DROP", .DROP },
    .{ "GRAPH", .GRAPH },
    .{ "PROPERTY", .PROPERTY },
    .{ "CONSTRAINT", .CONSTRAINT },
    .{ "SCHEMA", .SCHEMA },
    .{ "CATALOG", .CATALOG },
    // Query control
    .{ "SHOW", .SHOW },
    .{ "EXPLAIN", .EXPLAIN },
    .{ "PROFILE", .PROFILE },
    // Ordering
    .{ "ORDER", .ORDER },
    .{ "BY", .BY },
    .{ "GROUP", .GROUP },
    .{ "ASC", .ASC },
    .{ "DESC", .DESC },
    .{ "LIMIT", .LIMIT },
    .{ "OFFSET", .OFFSET },
    .{ "SKIP", .SKIP },
    .{ "HAVING", .HAVING },
    .{ "NULLS", .NULLS },
    .{ "FIRST", .FIRST },
    .{ "LAST", .LAST },
    // Additional ISO reserved words
    .{ "ON", .ON },
    .{ "UNKNOWN", .UNKNOWN },
    .{ "FILTER", .FILTER },
    .{ "LET", .LET },
    .{ "SELECT", .SELECT },
    .{ "FROM", .FROM },
    .{ "EXISTS", .EXISTS },
    .{ "DETACH", .DETACH },
    .{ "REMOVE", .REMOVE },
    .{ "FOR", .FOR },
    .{ "FOREACH", .FOREACH },
    .{ "UNWIND", .UNWIND },
    .{ "USE", .USE },
    .{ "USING", .USING },
    .{ "INDEX", .INDEX },
    .{ "JOIN", .JOIN },
    .{ "IF", .IF },
    .{ "TO", .TO },
    .{ "KEY", .KEY },
    .{ "KEYS", .KEYS },
    .{ "LABELS", .LABELS },
    .{ "LOAD", .LOAD },
    .{ "CSV", .CSV },
    .{ "PERIODIC", .PERIODIC },
    .{ "PROPERTIES", .PROPERTIES },
    .{ "RELATIONSHIPS", .RELATIONSHIPS },
    .{ "START_NODE", .START_NODE },
    .{ "END_NODE", .END_NODE },
    .{ "TYPE", .TYPE },
    .{ "TYPES", .TYPES },
    // ISO GQL keywords
    .{ "ACYCLIC", .ACYCLIC },
    .{ "AGGREGATE", .AGGREGATE },
    .{ "AVG", .AVG },
    .{ "CAST", .CAST },
    .{ "COUNT", .COUNT },
    .{ "CURRENT", .CURRENT },
    .{ "DIFFERENT", .DIFFERENT },
    .{ "DURATION", .DURATION },
    .{ "EDGES", .EDGES },
    .{ "ELEMENT", .ELEMENT },
    .{ "FINISH", .FINISH },
    .{ "HOME", .HOME },
    .{ "LABELED", .LABELED },
    .{ "LIST", .LIST },
    .{ "LOCAL", .LOCAL },
    .{ "MAX", .MAX },
    .{ "MIN", .MIN },
    .{ "NEXT", .NEXT },
    .{ "NODE", .NODE },
    .{ "OF", .OF },
    .{ "OTHERWISE", .OTHERWISE },
    .{ "PATH", .PATH },
    .{ "PATHS", .PATHS },
    .{ "RECORD", .RECORD },
    .{ "REPEATABLE", .REPEATABLE },
    .{ "REPLACE", .REPLACE },
    .{ "REQUIRE", .REQUIRE },
    .{ "ASSERT", .ASSERT },
    .{ "SHORTEST", .SHORTEST },
    .{ "SIMPLE", .SIMPLE },
    .{ "SUM", .SUM },
    .{ "TABLE", .TABLE },
    .{ "TRAIL", .TRAIL },
    .{ "WALK", .WALK },
    .{ "ZONED", .ZONED },
    .{ "ZONE", .ZONE },
    .{ "BINDING", .BINDING },
    .{ "BINDINGS", .BINDINGS },
    .{ "ORDINALITY", .ORDINALITY },
    .{ "READ", .READ },
    .{ "WRITE", .WRITE },
    .{ "NO", .NO },
    .{ "ONLY", .ONLY },
    // Type keywords for CAST expressions
    .{ "DECIMAL", .DECIMAL },
    .{ "INTEGER", .INTEGER },
    .{ "FLOAT", .FLOAT },
    .{ "STRING", .STRING },
    .{ "BOOLEAN", .BOOLEAN },
    .{ "TIMESTAMP", .TIMESTAMP },
    .{ "DATETIME", .DATETIME },
    .{ "DATE", .DATE },
    .{ "TIME", .TIME },
});

// Export keyword checking to lexer using comptime-generated map
// CANARY: REQ=REQ-GQL-KEYWORDS-001; FEATURE="GQL Reserved Words"; ASPECT=ISO39075Compliance; STATUS=TESTED; TEST=geodetestlab/specs/geode_keyword_fixes.yml; OWNER=parser; UPDATED=2026-01-03
pub fn keywordKind(word: []const u8) TokenKind {
    // Convert to uppercase for case-insensitive lookup
    var upper_buf: [64]u8 = undefined;
    if (word.len > upper_buf.len) return .identifier;

    for (word, 0..) |c, i| {
        upper_buf[i] = std.ascii.toUpper(c);
    }
    const upper = upper_buf[0..word.len];

    // O(1) lookup in comptime-generated map
    return KeywordMap.get(upper) orelse .identifier;
}

/// Check if a keyword exists in the metadata (for validation)
pub fn isKeywordInMetadata(name: []const u8) bool {
    return language_metadata.findKeyword(name) != null;
}

/// Get keyword metadata for documentation/completion
pub fn getKeywordMetadata(name: []const u8) ?language_metadata.KeywordInfo {
    return language_metadata.findKeyword(name);
}

// ============================================================================
// Unit Tests
// ============================================================================

// CANARY: REQ=REQ-GQL-CAST-KEYWORDS-001; FEATURE="CastTypeKeywords"; ASPECT=UnitTests; STATUS=TESTED; TEST=self; OWNER=parser; UPDATED=2026-01-25

test "keywordKind recognizes DECIMAL type keyword" {
    try std.testing.expectEqual(TokenKind.DECIMAL, keywordKind("DECIMAL"));
    try std.testing.expectEqual(TokenKind.DECIMAL, keywordKind("decimal"));
    try std.testing.expectEqual(TokenKind.DECIMAL, keywordKind("Decimal"));
}

test "keywordKind recognizes INTEGER type keyword" {
    try std.testing.expectEqual(TokenKind.INTEGER, keywordKind("INTEGER"));
    try std.testing.expectEqual(TokenKind.INTEGER, keywordKind("integer"));
    try std.testing.expectEqual(TokenKind.INTEGER, keywordKind("Integer"));
}

test "keywordKind recognizes FLOAT type keyword" {
    try std.testing.expectEqual(TokenKind.FLOAT, keywordKind("FLOAT"));
    try std.testing.expectEqual(TokenKind.FLOAT, keywordKind("float"));
    try std.testing.expectEqual(TokenKind.FLOAT, keywordKind("Float"));
}

test "keywordKind recognizes STRING type keyword" {
    try std.testing.expectEqual(TokenKind.STRING, keywordKind("STRING"));
    try std.testing.expectEqual(TokenKind.STRING, keywordKind("string"));
    try std.testing.expectEqual(TokenKind.STRING, keywordKind("String"));
}

test "keywordKind recognizes BOOLEAN type keyword" {
    try std.testing.expectEqual(TokenKind.BOOLEAN, keywordKind("BOOLEAN"));
    try std.testing.expectEqual(TokenKind.BOOLEAN, keywordKind("boolean"));
    try std.testing.expectEqual(TokenKind.BOOLEAN, keywordKind("Boolean"));
}

test "keywordKind recognizes TIMESTAMP type keyword" {
    try std.testing.expectEqual(TokenKind.TIMESTAMP, keywordKind("TIMESTAMP"));
    try std.testing.expectEqual(TokenKind.TIMESTAMP, keywordKind("timestamp"));
    try std.testing.expectEqual(TokenKind.TIMESTAMP, keywordKind("Timestamp"));
}

test "keywordKind recognizes DATETIME type keyword" {
    try std.testing.expectEqual(TokenKind.DATETIME, keywordKind("DATETIME"));
    try std.testing.expectEqual(TokenKind.DATETIME, keywordKind("datetime"));
    try std.testing.expectEqual(TokenKind.DATETIME, keywordKind("DateTime"));
}

test "keywordKind recognizes DATE type keyword" {
    try std.testing.expectEqual(TokenKind.DATE, keywordKind("DATE"));
    try std.testing.expectEqual(TokenKind.DATE, keywordKind("date"));
    try std.testing.expectEqual(TokenKind.DATE, keywordKind("Date"));
}

test "keywordKind recognizes TIME type keyword" {
    try std.testing.expectEqual(TokenKind.TIME, keywordKind("TIME"));
    try std.testing.expectEqual(TokenKind.TIME, keywordKind("time"));
    try std.testing.expectEqual(TokenKind.TIME, keywordKind("Time"));
}

test "keywordKind returns identifier for unknown words" {
    try std.testing.expectEqual(TokenKind.UNKNOWN, keywordKind("unknown"));
    try std.testing.expectEqual(TokenKind.identifier, keywordKind("foo"));
    try std.testing.expectEqual(TokenKind.identifier, keywordKind("myVariable"));
}

test "keywordKind handles CAST keyword" {
    try std.testing.expectEqual(TokenKind.CAST, keywordKind("CAST"));
    try std.testing.expectEqual(TokenKind.CAST, keywordKind("cast"));
    try std.testing.expectEqual(TokenKind.CAST, keywordKind("Cast"));
}

test "keywordKind handles AS keyword" {
    try std.testing.expectEqual(TokenKind.AS, keywordKind("AS"));
    try std.testing.expectEqual(TokenKind.AS, keywordKind("as"));
    try std.testing.expectEqual(TokenKind.AS, keywordKind("As"));
}

test "TokenKind has all required type keywords" {
    // Verify type keywords exist in the enum
    _ = TokenKind.DECIMAL;
    _ = TokenKind.INTEGER;
    _ = TokenKind.FLOAT;
    _ = TokenKind.STRING;
    _ = TokenKind.BOOLEAN;
    _ = TokenKind.TIMESTAMP;
    _ = TokenKind.DATETIME;
    _ = TokenKind.DATE;
    _ = TokenKind.TIME;
}

test "keywordKind handles words exceeding buffer length" {
    // Words longer than 64 characters should return identifier
    const long_word = "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnop";
    try std.testing.expect(long_word.len > 64);
    try std.testing.expectEqual(TokenKind.identifier, keywordKind(long_word));
}

test "every tokenized keyword has language metadata (drift guard)" {
    // token.zig's KeywordMap and language_metadata.keywords are two hand-
    // maintained lists that must stay in sync (QUAL-005). This guard fails if
    // any tokenized keyword lacks a metadata entry, so LSP completion /
    // syntax highlighting can never silently omit a real keyword again.
    for (KeywordMap.keys()) |kw| {
        if (language_metadata.findKeyword(kw) == null) {
            std.debug.print("Keyword '{s}' is tokenized but missing from language_metadata.keywords\n", .{kw});
            try std.testing.expect(false);
        }
    }
}
