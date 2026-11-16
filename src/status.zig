// ISO/IEC 39075:2024 GQL Status and Diagnostics
const std = @import("std");

pub const StatusClass = enum {
    SUCCESS,
    WARNING,
    ERROR,
};

pub const GqlStatus = struct {
    sqlstate: [5]u8,
    class: StatusClass,
    message: []const u8,
    line: ?u32 = null,
    column: ?u32 = null,
    token: ?[]const u8 = null,
    diagnostics: []const Diagnostic = &.{},
};

pub const Diagnostic = struct {
    code: []const u8,
    message: []const u8,
    severity: StatusClass,
};

// Common SQLSTATE codes per ISO
pub const SQLSTATE = struct {
    pub const SUCCESS = "00000".*;
    pub const WARNING = "01000".*;
    pub const NO_DATA = "02000".*;
    pub const FEATURE_NOT_SUPPORTED = "0A000".*;
    pub const CARDINALITY_VIOLATION = "21000".*;
    pub const DATA_EXCEPTION = "22000".*;
    pub const INVALID_CHARACTER = "22018".*;
    pub const INTEGRITY_CONSTRAINT = "23000".*;
    pub const INVALID_CURSOR_STATE = "24000".*;
    pub const INVALID_TRANSACTION_STATE = "25000".*;
    pub const SYNTAX_ERROR = "42601".*;
    pub const UNDEFINED_OBJECT = "42703".*;
    pub const DUPLICATE_ALIAS = "42712".*;
    pub const INVALID_SCHEMA = "3F000".*; // ISO SQL SQLSTATE class 3F — invalid schema name
    pub const PRIVILEGE_VIOLATION = "42501".*; // ISO 39075 §4.2.4.2 — insufficient privilege
    pub const CONFUSABLE_IDENTIFIER = "42004".*; // ISO 39075 §6 — visually confusable identifiers
    pub const TRANSACTION_ROLLBACK = "40003".*; // ISO 39075 §4.2.3.2 — connection failure during statement
    pub const CONNECTION_FAILURE_COMMIT = "08007".*; // ISO 39075 §4.2.3.2 — connection failure during commit
};

// Create standard error statuses
pub fn syntaxError(message: []const u8, line: u32, column: u32, token: ?[]const u8) GqlStatus {
    return GqlStatus{
        .sqlstate = SQLSTATE.SYNTAX_ERROR,
        .class = .ERROR,
        .message = message,
        .line = line,
        .column = column,
        .token = token,
    };
}

pub fn undefinedIdentifier(name: []const u8, line: u32, column: u32) GqlStatus {
    return GqlStatus{
        .sqlstate = SQLSTATE.UNDEFINED_OBJECT,
        .class = .ERROR,
        .message = "undefined identifier or alias",
        .line = line,
        .column = column,
        .token = name,
    };
}

pub fn duplicateAlias(name: []const u8, line: u32, column: u32) GqlStatus {
    return GqlStatus{
        .sqlstate = SQLSTATE.DUPLICATE_ALIAS,
        .class = .ERROR,
        .message = "duplicate identifier (case-insensitive collision)",
        .line = line,
        .column = column,
        .token = name,
    };
}

pub fn featureNotSupported(feature: []const u8) GqlStatus {
    return GqlStatus{
        .sqlstate = SQLSTATE.FEATURE_NOT_SUPPORTED,
        .class = .ERROR,
        .message = feature,
    };
}

pub fn invalidCharacter(message: []const u8, line: u32, column: u32) GqlStatus {
    return GqlStatus{
        .sqlstate = SQLSTATE.INVALID_CHARACTER,
        .class = .ERROR,
        .message = message,
        .line = line,
        .column = column,
    };
}

pub fn success() GqlStatus {
    return GqlStatus{
        .sqlstate = SQLSTATE.SUCCESS,
        .class = .SUCCESS,
        .message = "OK",
    };
}

// Write JSON diagnostics with stable key order
pub fn writeJson(writer: anytype, status: GqlStatus) !void {
    try writer.writeByte('{');

    // Always include sqlstate first
    try writer.print("\"sqlstate\":\"{s}\"", .{status.sqlstate});

    // Then class
    const class_str = switch (status.class) {
        .SUCCESS => "SUCCESS",
        .WARNING => "WARNING",
        .ERROR => "ERROR",
    };
    try writer.print(",\"class\":\"{s}\"", .{class_str});

    // Then message
    try writer.print(",\"message\":\"{s}\"", .{status.message});

    // Optional fields in order
    if (status.line) |l| {
        try writer.print(",\"line\":{}", .{l});
    }
    if (status.column) |c| {
        try writer.print(",\"column\":{}", .{c});
    }
    if (status.token) |t| {
        try writer.print(",\"token\":\"{s}\"", .{t});
    }

    // Diagnostics array
    try writer.writeAll(",\"diagnostics\":[");
    for (status.diagnostics, 0..) |diag, i| {
        if (i > 0) try writer.writeByte(',');
        try writer.writeByte('{');
        try writer.print("\"code\":\"{s}\",", .{diag.code});
        try writer.print("\"message\":\"{s}\",", .{diag.message});
        const sev_str = switch (diag.severity) {
            .SUCCESS => "SUCCESS",
            .WARNING => "WARNING",
            .ERROR => "ERROR",
        };
        try writer.print("\"severity\":\"{s}\"", .{sev_str});
        try writer.writeByte('}');
    }
    try writer.writeAll("]");

    try writer.writeByte('}');
}

pub fn confusableIdentifier(name: []const u8, line: u32, column: u32) GqlStatus {
    return GqlStatus{
        .sqlstate = SQLSTATE.CONFUSABLE_IDENTIFIER,
        .class = .ERROR,
        .message = "visually confusable identifiers in same program (ISO 39075 §6)",
        .line = line,
        .column = column,
        .token = name,
    };
}

pub fn privilegeViolation(operation: []const u8) GqlStatus {
    return GqlStatus{
        .sqlstate = SQLSTATE.PRIVILEGE_VIOLATION,
        .class = .ERROR,
        .message = "access rule violation: insufficient privilege",
        .token = operation,
    };
}

pub fn connectionFailure() GqlStatus {
    return GqlStatus{
        .sqlstate = SQLSTATE.TRANSACTION_ROLLBACK,
        .class = .ERROR,
        .message = "connection failure during statement execution — transaction outcome unknown",
    };
}

pub fn connectionFailureCommit() GqlStatus {
    return GqlStatus{
        .sqlstate = SQLSTATE.CONNECTION_FAILURE_COMMIT,
        .class = .ERROR,
        .message = "connection failure during commit — transaction resolution unknown",
    };
}
// GQL-39075 conformance SQLSTATE tests
// CANARY: REQ=GQL-39075-RQ-0012; FEATURE="GQLStatus/SQLSTATE42004"; ASPECT=ConfusableIdentifier; STATUS=TESTED; TEST=GQL39075_RQ0012_sqlstate_42004_exists,GQL39075_RQ0012_confusable_identifier_helper; OWNER=conformance; UPDATED=2026-02-23
// CANARY: REQ=GQL-39075-RQ-0019; FEATURE="GQLStatus/SQLSTATE42501"; ASPECT=PrivilegeViolation; STATUS=TESTED; TEST=GQL39075_RQ0019_sqlstate_42501_privilege_violation,GQL39075_RQ0019_privilege_violation_helper; OWNER=conformance; UPDATED=2026-03-22
// CANARY: REQ=GQL-39075-RQ-0020; FEATURE="GQLStatus/SQLSTATE40003/08007"; ASPECT=ConnectionLoss; STATUS=TESTED; TEST=GQL39075_RQ0020_sqlstate_40003_exists,GQL39075_RQ0020_sqlstate_08007_exists; OWNER=conformance; UPDATED=2026-02-23

test "GQL39075_RQ0012_sqlstate_42004_exists" {
    const code: [5]u8 = SQLSTATE.CONFUSABLE_IDENTIFIER;
    try std.testing.expectEqualStrings("42004", &code);
}

test "GQL39075_RQ0019_sqlstate_42501_privilege_violation" {
    const code: [5]u8 = SQLSTATE.PRIVILEGE_VIOLATION;
    try std.testing.expectEqualStrings("42501", &code);
}

test "GQL39075_RQ0019_sqlstate_3F000_invalid_schema" {
    const code: [5]u8 = SQLSTATE.INVALID_SCHEMA;
    try std.testing.expectEqualStrings("3F000", &code);
}

test "GQL39075_RQ0020_sqlstate_40003_exists" {
    const code: [5]u8 = SQLSTATE.TRANSACTION_ROLLBACK;
    try std.testing.expectEqualStrings("40003", &code);
}

test "GQL39075_RQ0020_sqlstate_08007_exists" {
    const code: [5]u8 = SQLSTATE.CONNECTION_FAILURE_COMMIT;
    try std.testing.expectEqualStrings("08007", &code);
}

test "GQL39075_RQ0012_confusable_identifier_helper" {
    const s = confusableIdentifier("myVar", 1, 5);
    try std.testing.expectEqualStrings("42004", &s.sqlstate);
    try std.testing.expectEqual(StatusClass.ERROR, s.class);
}

test "GQL39075_RQ0019_privilege_violation_helper" {
    const s = privilegeViolation("CREATE GRAPH");
    try std.testing.expectEqualStrings("42501", &s.sqlstate);
    try std.testing.expectEqual(StatusClass.ERROR, s.class);
}

test "GQL39075_RQ0020_connection_failure_helper" {
    const s = connectionFailure();
    try std.testing.expectEqualStrings("40003", &s.sqlstate);
}

test "GQL39075_RQ0020_connection_failure_commit_helper" {
    const s = connectionFailureCommit();
    try std.testing.expectEqualStrings("08007", &s.sqlstate);
}

// SONNY-6543: the codes ISO/IEC 39075:2024 clause 23 (Table 8) defines for
// the conditions these helpers report.
// CANARY: REQ=GQL-39075-RQ-0021; FEATURE="GQLStatus/Table8"; ASPECT=InvalidReferenceSyntaxCast; STATUS=TESTED; TEST=GQL39075_RQ0021_undefined_identifier_is_42002,GQL39075_RQ0021_syntax_error_is_42000,GQL39075_RQ0021_invalid_character_value_for_cast; OWNER=conformance; UPDATED=2026-11-16

test "GQL39075_RQ0021_undefined_identifier_is_42002" {
    const code: [5]u8 = SQLSTATE.INVALID_REFERENCE;
    try std.testing.expectEqualStrings("42002", &code);
    const legacy: [5]u8 = SQLSTATE.UNDEFINED_OBJECT;
    try std.testing.expectEqualStrings("42002", &legacy);
    const s = undefinedIdentifier("x", 2, 7);
    try std.testing.expectEqualStrings("42002", &s.sqlstate);
    try std.testing.expectEqualStrings("x", s.token.?);
}

test "GQL39075_RQ0021_syntax_error_is_42000" {
    const code: [5]u8 = SQLSTATE.SYNTAX_ERROR;
    try std.testing.expectEqualStrings("42000", &code);
    const invalid_syntax: [5]u8 = SQLSTATE.INVALID_SYNTAX;
    try std.testing.expectEqualStrings("42001", &invalid_syntax);
    const s = syntaxError("unexpected token", 1, 3, "RETURN");
    try std.testing.expectEqualStrings("42000", &s.sqlstate);
    try std.testing.expectEqual(@as(?u32, 1), s.line);
}

test "GQL39075_RQ0021_invalid_character_value_for_cast" {
    // 22018 is a data exception of a cast, raised by a value: it carries no
    // source position (a lexical error is class 42).
    const code: [5]u8 = SQLSTATE.INVALID_CHARACTER_VALUE_FOR_CAST;
    try std.testing.expectEqualStrings("22018", &code);
    const s = invalidCharacterValueForCast("'abc' is not an INTEGER");
    try std.testing.expectEqualStrings("22018", &s.sqlstate);
    try std.testing.expectEqual(@as(?u32, null), s.line);
    try std.testing.expectEqual(@as(?u32, null), s.column);
}
