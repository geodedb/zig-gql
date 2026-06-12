// CANARY: REQ=REQ-0001; FEATURE="Standards & Conformance Requirements"; ASPECT=Compliance; STATUS=TESTED; TEST=tests/e2e_protocol.zig; OWNER=core; UPDATED=2026-01-15
// CANARY: REQ=REQ-0002; FEATURE="Language Surface Requirements"; ASPECT=Compliance; STATUS=TESTED; TEST=tests/e2e_protocol.zig; OWNER=core; UPDATED=2026-01-15
// CANARY: REQ=REQ-GQL-006; FEATURE="GQL Parser"; ASPECT=Parser; STATUS=TESTED; TEST=tests/e2e_protocol.zig; OWNER=parser; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-007; FEATURE="MATCH/OPTIONAL Parsing"; ASPECT=Parser; STATUS=TESTED; TEST=tests/e2e_graph_match.zig; OWNER=parser; UPDATED=2025-09-20
// CANARY: REQ=REQ-GQL-008; FEATURE="ORDER/LIMIT/OFFSET Parsing"; ASPECT=Parser; STATUS=TESTED; TEST=tests/e2e_protocol.zig; OWNER=parser; UPDATED=2025-09-20

const std = @import("std");
const tok = @import("token.zig");
const ast = @import("ast.zig");
const temporal = @import("temporal.zig");
const Lexer = @import("lexer.zig").Lexer;

// Observability seam: parser wraps `parseProgram` with one
// query-execution span per top-level call. Imports the named module
// (resolves to a comptime no-op when -Dwith_otel=false). Telemetry is
// non-fatal: every call into the seam is `catch {}`-discarded inside
// the seam itself, so a failing exporter cannot propagate into parser
// callers.
const observability = @import("observability");

pub const Parser = struct {
    lx: *Lexer,
    arena: *std.heap.ArenaAllocator,
    cur: tok.Token,
    // Optional: when true, ORDER BY keys must be simple identifiers or member chains.
    strict_order_keys: bool = false,
    // Optional: when true, ORDER BY keys must be identifiers only (no member chains).
    ident_order_only: bool = false,
    // Optional: when true, function calls are forbidden in ORDER BY expressions.
    forbid_orderby_calls: bool = false,
    // Optional: when true, path aliases are forbidden in ORDER BY keys.
    forbid_orderby_paths: bool = false,
    // Track if ordinal sort keys are used
    has_ordinal_sort_key: bool = false,
    // Track if UNWIND (non-standard GQL) syntax is used
    has_unwind: bool = false,
    // TS extensions (SERIES UDFs) allowed when true
    ts_extensions: bool = false,
    // Last error context message (static or source-backed slice).
    last_error: ?[]const u8 = null,
    // Path alias names collected from the last parsed graph pattern (MATCH or pattern comprehension).
    path_aliases: std.ArrayList([]const u8) = undefined,
    // Whether parseGraphPattern should record chain aliases into path_aliases.
    collect_chain_aliases: bool = false,
    // Track nesting depth in pattern comprehensions to handle ambiguous | tokens
    pattern_comp_depth: u32 = 0,
    // Recursion depth counter for expression parsing (guards against stack overflow)
    expr_depth: u16 = 0,
    // Recursion depth counter for the statement/query/pattern grammar. The
    // expression guard above only bounds expression nesting; this one bounds
    // structural nesting (CALL{ subquery }, parenthesized statements,
    // shortestPath(( ... )), etc.) so adversarial input cannot exhaust the
    // native call stack (SIGSEGV in ReleaseFast / panic in ReleaseSafe).
    // See GQL-APPSEC-01/02/03, QUAL-002/003.
    recur_depth: u16 = 0,

    const MAX_EXPR_DEPTH = 256;
    // Structural recursion limit. Kept well below MAX_EXPR_DEPTH because the
    // statement/query/pattern functions (parseQuery, parseStatement,
    // parseGraphPattern) have far larger stack frames than the expression
    // functions: empirically ~256 structural frames overflow an 8 MiB stack
    // while ~128 do not, so 100 leaves comfortable margin (and remains safe on
    // smaller worker-thread stacks). 100 levels of structural nesting is far
    // beyond any realistic GQL query.
    const MAX_RECUR_DEPTH = 100;

    fn advance(self: *Parser) void {
        self.cur = self.lx.next();
    }

    fn peekToken(self: *Parser) tok.TokenKind {
        // Save lexer state
        const saved_idx = self.lx.idx;
        const saved_line = self.lx.line;
        const saved_col = self.lx.col;

        // Get next token
        const next_token = self.lx.next();

        // Restore lexer state
        self.lx.idx = saved_idx;
        self.lx.line = saved_line;
        self.lx.col = saved_col;

        return next_token.kind;
    }

    fn isKeyword(self: *Parser, kind: tok.TokenKind) bool {
        _ = self;
        // Check if the token kind is a keyword (not a delimiter, literal, or identifier)
        return switch (kind) {
            .MATCH,
            .OPTIONAL,
            .WHERE,
            .RETURN,
            .WITH,
            .CASE,
            .WHEN,
            .THEN,
            .ELSE,
            .END,
            .AND,
            .OR,
            .NOT,
            .IN,
            .IS,
            .STARTS,
            .ENDS,
            .CONTAINS,
            .CALL,
            .YIELD,
            .TRUE,
            .FALSE,
            .NULL,
            .AS,
            .DISTINCT,
            .UNION,
            .INTERSECT,
            .EXCEPT,
            .ALL,
            .SESSION,
            .SET,
            .RESET,
            .CLOSE,
            .INSERT,
            .VALUE,
            .VALUES, // Re-added to allow values() function calls in expression context
            .SCAN,
            .START,
            .TRANSACTION,
            .COMMIT,
            .ROLLBACK,
            .CREATE,
            .DELETE,
            .MERGE,
            .GRAPH,
            .PROPERTY,
            .DROP,
            .ORDER,
            .BY,
            .GROUP,
            .ASC,
            .DESC,
            .LIMIT,
            .OFFSET,
            .SKIP,
            .HAVING,
            .NULLS,
            .FIRST,
            .LAST,
            .ON,
            .UNKNOWN,
            .FILTER,
            .LET,
            .SELECT,
            .FROM,
            .EXISTS,
            .DETACH,
            .REMOVE,
            .FOR,
            .FOREACH,
            .UNWIND,
            .USE,
            .USING,
            .INDEX,
            .JOIN,
            .IF,
            .TO,
            .KEY,
            // .KEYS - Removed from reserved keywords to allow keys() function calls
            .LABELS,
            .LOAD,
            .CSV,
            .PERIODIC,
            .PROPERTIES,
            .RELATIONSHIPS,
            .START_NODE,
            .END_NODE,
            .TYPE,
            .TYPES,
            // Critical missing ISO GQL keywords (avoiding duplicates)
            .ACYCLIC,
            .AGGREGATE,
            .ANY,
            .AVG,
            .CATALOG,
            .CAST,
            .CONSTRAINT,
            .COUNT,
            .CURRENT,
            .DIFFERENT,
            .DURATION,
            .EDGES,
            .ELEMENT,
            .FINISH,
            .HOME,
            .LABELED,
            .LIKE,
            .LIST,
            .MAX,
            .MIN,
            .NEXT,
            .NODE,
            .OF,
            .OTHERWISE,
            .PATH,
            .PATHS,
            .RECORD,
            .REPEATABLE,
            .REPLACE,
            .SCHEMA,
            .SHORTEST,
            .SIMPLE,
            .SUM,
            .TABLE,
            .TRAIL,
            .WALK,
            .XOR,
            .ZONED,
            .ZONE,
            .ORDINALITY,
            // Temporal type keywords - used as function names (e.g., date('2024-01-15'))
            .DATE,
            .TIME,
            .DATETIME,
            .TIMESTAMP,
            // Type name keywords - commonly used as identifiers
            .BOOLEAN,
            .DECIMAL,
            .FLOAT,
            .INTEGER,
            .STRING,
            // Additional keywords that may appear as identifiers
            .ASSERT,
            .BEGIN,
            .BINDING,
            .BINDINGS,
            .EXPLAIN,
            .LOCAL,
            .NO,
            .ONLY,
            .PROFILE,
            .READ,
            .REQUIRE,
            .SHOW,
            .WRITE,
            => true,
            else => false,
        };
    }

    fn peekKind(self: *Parser) tok.TokenKind {
        var tmp = self.lx.*;
        const tkn = tmp.next();
        return tkn.kind;
    }

    fn peek2Kind(self: *Parser) tok.TokenKind {
        var tmp = self.lx.*;
        _ = tmp.next();
        const t2 = tmp.next();
        return t2.kind;
    }

    fn expect(self: *Parser, kind: tok.TokenKind) !tok.Token {
        if (self.cur.kind != kind) {
            self.last_error = @tagName(kind);
            return error.UnexpectedToken;
        }
        const out = self.cur;
        self.advance();
        return out;
    }

    // Helper function to accept identifiers or keywords as identifiers (for aliases, etc.)
    // CANARY: REQ=REQ-GQL-001; FEATURE="KeywordsAsIdentifiers"; ASPECT=ParserSupport; STATUS=TESTED; OWNER=parser; UPDATED=2025-10-09
    // Per ISO/IEC 39075:2024, keywords can be used as identifiers in most contexts (aliases, variable names, property names, labels)
    fn expectIdentifierOrKeyword(self: *Parser) !tok.Token {
        if (self.cur.kind == .identifier or self.isKeyword(self.cur.kind)) {
            const out = self.cur;
            self.advance();
            return out;
        }
        self.last_error = "identifier";
        return error.UnexpectedToken;
    }

    // Parser operations can fail due to syntax or allocation issues.
    // We’ll thread a tiny error wrapper with a message alongside generic errors when needed.
    const ParserError = error{ UnexpectedToken, OutOfMemory, Overflow, InvalidCharacter, InvalidIndexType };

    fn unexpected(self: *Parser, what: []const u8) ParserError {
        // For now, we just return UnexpectedToken; callers like CLI can add context using 'what'.
        self.last_error = what;
        return error.UnexpectedToken;
    }

    /// Parse a LIMIT or OFFSET value: accepts either an integer literal or a $param reference.
    /// Returns .{ literal_value_or_null, param_name_or_null }.
    fn parseLimitValue(self: *Parser) !struct { value: ?u64, param: ?[]const u8 } {
        if (self.cur.kind == .dollar) {
            self.advance();
            // Accept both named ($param) and positional ($1) parameters
            if (self.cur.kind == .integer_lit) {
                const name = self.cur;
                self.advance();
                return .{ .value = null, .param = name.lexeme };
            }
            const name = try self.expectIdentifierOrKeyword();
            return .{ .value = null, .param = name.lexeme };
        }
        const lim_tok = try self.expect(.integer_lit);
        return .{ .value = try std.fmt.parseInt(u64, lim_tok.lexeme, 10), .param = null };
    }

    fn unescapeString(self: *Parser, raw: []const u8) ![]const u8 {
        // Check if we need to unescape (contains '' or \)
        var needs_unescape = false;
        var i: usize = 0;
        while (i < raw.len) : (i += 1) {
            if (raw[i] == '\\' or (raw[i] == '\'' and i + 1 < raw.len and raw[i + 1] == '\'')) {
                needs_unescape = true;
                break;
            }
        }
        if (!needs_unescape) return raw;

        // Allocate buffer for unescaped string
        var result = try self.arena.allocator().alloc(u8, raw.len);
        var write_idx: usize = 0;
        i = 0;
        while (i < raw.len) {
            if (raw[i] == '\'') {
                // Check for doubled single quote ('')
                if (i + 1 < raw.len and raw[i + 1] == '\'') {
                    result[write_idx] = '\'';
                    write_idx += 1;
                    i += 2; // Skip both quotes
                    continue;
                }
            } else if (raw[i] == '\\' and i + 1 < raw.len) {
                // Handle backslash escapes
                i += 1;
                result[write_idx] = switch (raw[i]) {
                    'n' => '\n',
                    'r' => '\r',
                    't' => '\t',
                    '\\' => '\\',
                    '\'' => '\'',
                    '"' => '"',
                    else => raw[i], // Unknown escape, keep as-is
                };
                write_idx += 1;
                i += 1;
                continue;
            }
            result[write_idx] = raw[i];
            write_idx += 1;
            i += 1;
        }
        return result[0..write_idx];
    }

    /// Result of parsing ORDER BY key modifiers (ASC/DESC, NULLS FIRST/LAST)
    const OrderKeyModifiers = struct {
        desc: bool,
        nulls: ast.OrderBy.NullsPolicy,
    };

    // CANARY: REQ=REQ-NESTING-REFACTOR-025; FEATURE="NestingReduction"; ASPECT=OrderByParsing; STATUS=TESTED; OWNER=refactor; UPDATED=2026-01-30
    /// Parses ORDER BY key modifiers (ASC/DESC and NULLS FIRST/LAST).
    /// Extracted to reduce code duplication and nesting in ORDER BY parsing.
    fn parseOrderKeyModifiers(self: *Parser) ParserError!OrderKeyModifiers {
        var desc = false;
        if (self.cur.kind == .ASC) {
            desc = false;
            self.advance();
        } else if (self.cur.kind == .DESC) {
            desc = true;
            self.advance();
        }

        var nulls: ast.OrderBy.NullsPolicy = .default;
        if (self.cur.kind == .NULLS) {
            self.advance();
            if (self.cur.kind == .FIRST) {
                nulls = .first;
                self.advance();
            } else if (self.cur.kind == .LAST) {
                nulls = .last;
                self.advance();
            } else return self.unexpected("expected FIRST/LAST after NULLS");
        }

        return .{ .desc = desc, .nulls = nulls };
    }

    /// Top-level parse entry. Emits one observability span shaped as a
    /// GraphQL query execution (`db.system="graphql"`,
    /// `graphql.operation.type="query"`). The seam is a comptime no-op
    /// when -Dwith_otel=false, so this wrapper has zero overhead in the
    /// default build. Implementation lives in `parseProgramImpl`; this
    /// thin shim only owns the span lifecycle.
    pub fn parseProgram(self: *Parser) ParserError!ast.Program {
        // We don't yet know the operation_type until at least one
        // statement is parsed. Default to "query" — matches the
        // umbrella term used by the rest of the rollout (mutations
        // appear as Insert/Delete/Merge/Update statements at the GQL
        // surface; subscriptions are not parsed here). The
        // operation_name is null at this layer because the parser
        // doesn't yet know the user-supplied label.
        var span = observability.startQueryExecutionSpan("query", null);
        // Belt-and-suspenders: even on an unhandled return path the
        // span's underlying SDK arena is freed via `end(null)`.
        defer span.end(null);
        // Failure path: any ParserError shortcut bubbles up here.
        errdefer observability.endQueryExecutionSpan(span, false, 0);

        const program = try self.parseProgramImpl();

        // Success path: status=ok, error_count=0. Recoverable
        // diagnostics aren't tracked at this layer yet — when a
        // diagnostics buffer is wired in, swap the literal 0 for its
        // length.
        observability.endQueryExecutionSpan(span, true, 0);
        return program;
    }

    fn parseProgramImpl(self: *Parser) ParserError!ast.Program {
        // initialize alias set arraylist
        self.path_aliases = std.ArrayList([]const u8).empty;
        var list = std.ArrayList(ast.Statement).empty;

        // GAP-0082: Parse CTEs if WITH keyword present at program start
        // CANARY: REQ=REQ-GQL-CTE-002; FEATURE="CTEParsing"; ASPECT=ParserProgram; STATUS=TESTED; TEST=geodetestlab/specs/recursive_and_cte.yml; OWNER=parser; UPDATED=2026-01-10
        var cte_list: ?ast.CTEList = null;
        if (self.cur.kind == .WITH) {
            // Check if this is a CTE (WITH name AS (...)) vs projection (WITH expr AS alias)
            // CTEs have: WITH identifier AS ( or WITH RECURSIVE identifier AS (
            // Projections have: WITH function(...) AS alias or WITH expr AS alias
            var tmp = self.lx.*;
            const next_tok = tmp.next();
            const is_recursive = next_tok.kind == .identifier and std.ascii.eqlIgnoreCase(next_tok.lexeme, "RECURSIVE");
            const check_tok = if (is_recursive) tmp.next() else next_tok;

            // Check for CTE pattern: identifier AS ( (not just identifier followed by AS)
            // We need to distinguish:
            //   CTE: WITH cte_name AS (SELECT...) - identifier followed by AS then (
            //   Projection: WITH date('...') AS d - function call followed by AS then identifier
            const is_cte = check_tok.kind == .identifier and blk: {
                const peek = tmp.next();
                if (peek.kind == .AS) {
                    // Check if AS is followed by ( which indicates CTE body
                    const after_as = tmp.next();
                    break :blk after_as.kind == .l_paren;
                } else if (peek.kind == .l_paren) {
                    // Could be CTE with column list: WITH name(col1, col2) AS (...)
                    // Skip to closing paren and check for AS (
                    var depth: u32 = 1;
                    while (depth > 0) {
                        const inner_tok = tmp.next();
                        if (inner_tok.kind == .l_paren) depth += 1;
                        if (inner_tok.kind == .r_paren) depth -= 1;
                        if (inner_tok.kind == .eof) break :blk false;
                    }
                    const after_paren = tmp.next();
                    if (after_paren.kind == .AS) {
                        const after_as = tmp.next();
                        break :blk after_as.kind == .l_paren;
                    }
                    break :blk false;
                } else {
                    break :blk false;
                }
            };

            if (is_cte) {
                cte_list = try self.parseCTEList();
            }
        }

        while (self.cur.kind != .eof) {
            const st = try self.parseStatement();
            // If we parsed CTEs, attach them to Query statements
            if (cte_list) |ctes| {
                switch (st) {
                    .Query => |q| {
                        var q_mut = q;
                        q_mut.cte_list = ctes;
                        q_mut.has_recursive_cte = ctes.has_recursive;
                        try list.append(self.arena.allocator(), .{ .Query = q_mut });
                        if (self.cur.kind == .semicolon) self.advance();
                        // Clear cte_list after attaching to first query
                        cte_list = null;
                        continue;
                    },
                    .Union => |u| {
                        // Attach to union's first query
                        var u_mut = u;
                        var first_mut = u_mut.first;
                        first_mut.cte_list = ctes;
                        first_mut.has_recursive_cte = ctes.has_recursive;
                        u_mut.first = first_mut;
                        try list.append(self.arena.allocator(), .{ .Union = u_mut });
                        if (self.cur.kind == .semicolon) self.advance();
                        cte_list = null;
                        continue;
                    },
                    else => {},
                }
            }
            try list.append(self.arena.allocator(), st);
            if (self.cur.kind == .semicolon) self.advance();
        }
        return .{ .statements = try list.toOwnedSlice(self.arena.allocator()) };
    }

    /// GAP-0082: Parse WITH [RECURSIVE] cte_name [(col1, col2)] AS (query) [, cte_name2 AS (query2)]
    /// CANARY: REQ=REQ-GQL-CTE-003; FEATURE="CTEListParsing"; ASPECT=Parser; STATUS=TESTED; TEST=geodetestlab/specs/recursive_and_cte.yml; OWNER=parser; UPDATED=2026-01-10
    fn parseCTEList(self: *Parser) ParserError!ast.CTEList {
        _ = self.expect(.WITH) catch return error.UnexpectedToken;

        var is_recursive = false;
        // Check for RECURSIVE keyword
        if (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "RECURSIVE")) {
            is_recursive = true;
            self.advance();
        }

        var ctes = std.ArrayList(ast.CommonTableExpression).empty;
        const any_recursive = is_recursive;

        // Parse first CTE
        const first_cte = try self.parseSingleCTE(is_recursive);
        try ctes.append(self.arena.allocator(), first_cte);

        // Parse additional CTEs separated by commas
        while (self.cur.kind == .comma) {
            self.advance(); // consume comma
            const cte = try self.parseSingleCTE(is_recursive);
            try ctes.append(self.arena.allocator(), cte);
        }

        return ast.CTEList{
            .ctes = try ctes.toOwnedSlice(self.arena.allocator()),
            .has_recursive = any_recursive,
        };
    }

    /// Parse a single CTE: name [(col1, col2)] AS (query)
    fn parseSingleCTE(self: *Parser, is_recursive_context: bool) ParserError!ast.CommonTableExpression {
        // Parse CTE name
        if (self.cur.kind != .identifier) return error.UnexpectedToken;
        const cte_name = self.cur.lexeme;
        self.advance();

        // Optional column list: (col1, col2, ...)
        var column_names: ?[]const []const u8 = null;
        if (self.cur.kind == .l_paren) {
            self.advance();
            var cols = std.ArrayList([]const u8).empty;
            if (self.cur.kind == .identifier) {
                try cols.append(self.arena.allocator(), self.cur.lexeme);
                self.advance();
                while (self.cur.kind == .comma) {
                    self.advance();
                    if (self.cur.kind != .identifier) return error.UnexpectedToken;
                    try cols.append(self.arena.allocator(), self.cur.lexeme);
                    self.advance();
                }
            }
            _ = self.expect(.r_paren) catch return error.UnexpectedToken;
            if (cols.items.len > 0) {
                column_names = try cols.toOwnedSlice(self.arena.allocator());
            }
        }

        // Expect AS
        _ = self.expect(.AS) catch return error.UnexpectedToken;

        // Expect opening paren for CTE body
        _ = self.expect(.l_paren) catch return error.UnexpectedToken;

        // Parse the CTE body - this could be a simple query or anchor UNION recursive
        // For recursive CTEs, we need to detect UNION within the body
        const body = try self.parseCTEBody(is_recursive_context, cte_name);

        // Expect closing paren
        _ = self.expect(.r_paren) catch return error.UnexpectedToken;

        return ast.CommonTableExpression{
            .name = cte_name,
            .is_recursive = is_recursive_context and body == .recursive,
            .column_names = column_names,
            .body = body,
        };
    }

    /// Parse CTE body - detect if it's anchor UNION recursive or simple query
    fn parseCTEBody(self: *Parser, is_recursive_context: bool, cte_name: []const u8) ParserError!ast.CommonTableExpression.CTEBody {
        // Parse first query (could be anchor or full query)
        const first_query = try self.parseQueryForCTE();
        const first_ptr = try self.arena.allocator().create(ast.Query);
        first_ptr.* = first_query;

        // Check for UNION (indicates recursive CTE structure)
        if (is_recursive_context and self.cur.kind == .UNION) {
            self.advance(); // consume UNION
            const union_all = self.cur.kind == .ALL;
            if (union_all) self.advance();

            // Parse recursive term
            const recursive_query = try self.parseQueryForCTE();
            const recursive_ptr = try self.arena.allocator().create(ast.Query);
            recursive_ptr.* = recursive_query;
            // Mark recursive term as referencing the CTE
            _ = cte_name; // CTE reference will be resolved during execution

            return .{
                .recursive = .{
                    .anchor = first_ptr,
                    .recursive_term = recursive_ptr,
                    .union_all = union_all,
                },
            };
        }

        return .{ .simple = first_ptr };
    }

    /// Parse a query within CTE context (limited - no outer set operations)
    fn parseQueryForCTE(self: *Parser) ParserError!ast.Query {
        // Use existing query parsing but without set operations at the top level
        // (set operations within CTE body are handled by parseCTEBody for UNION)
        return self.parseQuery();
    }

    fn parseStatement(self: *Parser) ParserError!ast.Statement {
        self.recur_depth += 1;
        defer self.recur_depth -= 1;
        if (self.recur_depth > MAX_RECUR_DEPTH) return error.UnexpectedToken;
        return switch (self.cur.kind) {
            .VALUES => self.parseValuesStatement(),
            .FOR => self.parseForStatement(),
            .LET => blk_let: {
                const first = try self.parseQuery();
                break :blk_let self.handleQueryResult(first);
            },
            .CREATE => self.parseCreateStatement(),
            .DELETE => self.parseDeleteStatement(),
            .DETACH => self.parseDeleteStatement(),
            .MERGE => self.parseMergeStatement(),
            .DROP => self.parseDropStatement(),
            .SHOW => self.parseShowStatement(),
            .EXPLAIN => self.parseExplainStatement(),
            .PROFILE => self.parseProfileStatement(),
            .USE => self.parseUseStatement(),
            .identifier => blk_ident: {
                // Check for BACKUP and RESTORE keywords
                if (std.ascii.eqlIgnoreCase(self.cur.lexeme, "BACKUP")) {
                    break :blk_ident self.parseBackupStatement();
                } else if (std.ascii.eqlIgnoreCase(self.cur.lexeme, "RESTORE")) {
                    break :blk_ident self.parseRestoreStatement();
                }
                return error.UnexpectedToken;
            },
            .INSERT => blk_ins: {
                self.advance();
                // Check if this is INSERT VALUE or INSERT pattern
                if (self.cur.kind == .VALUE) {
                    // Syntax: INSERT VALUE <expr>
                    self.advance();
                    const expr = try self.parseOrExpr();
                    break :blk_ins .{ .InsertValue = .{ .expr = expr } };
                } else {
                    // Syntax: INSERT (pattern) - like CREATE but different semantics
                    const pattern = try self.parseGraphPattern();

                    // Optional RETURN clause
                    var return_clause: ?ast.ReturnClause = null;
                    if (self.cur.kind == .RETURN) {
                        self.advance();
                        const distinct = if (self.cur.kind == .DISTINCT) blk: {
                            self.advance();
                            break :blk true;
                        } else false;
                        var return_items = std.ArrayList(ast.ReturnItem).empty;
                        try self.parseProjectionItems(&return_items);
                        return_clause = .{
                            .items = try return_items.toOwnedSlice(self.arena.allocator()),
                            .distinct = distinct,
                        };
                    }

                    break :blk_ins .{ .Insert = .{
                        .pattern = pattern,
                        .return_clause = return_clause,
                    } };
                }
            },
            .SCAN => blk_scan: {
                self.advance();
                // Syntax: SCAN VALUES; simple keyword VALUES optional
                if (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "VALUES")) {
                    self.advance();
                } else if (self.cur.kind == .VALUE) {
                    self.advance();
                }
                break :blk_scan .ScanValues;
            },
            .SELECT => blk_select: {
                // SELECT [DISTINCT] <select_list> maps to RETURN semantics
                self.advance();
                var distinct = false;
                if (self.cur.kind == .DISTINCT) {
                    distinct = true;
                    self.advance();
                }

                // Parse select list (same as RETURN items)
                var items = std.ArrayList(ast.ReturnItem).empty;
                while (true) {
                    const expr = try self.parseOrExpr();
                    var alias: ?[]const u8 = null;
                    if (self.cur.kind == .AS) {
                        self.advance();
                        const al = try self.expectIdentifierOrKeyword();
                        alias = al.lexeme;
                    }
                    try items.append(self.arena.allocator(), .{ .expr = expr, .alias = alias });
                    if (self.cur.kind != .comma) break;
                    self.advance();
                }

                // Create a minimal Query with just the return clause
                // (No FROM clause support yet - maps to current active graph)
                const query = ast.Query{
                    .optional_match = false,
                    .match = .{ .chains = &.{} }, // Empty match pattern
                    .where_clause = null,
                    .with_clause = null,
                    .ret = .{ .items = try items.toOwnedSlice(self.arena.allocator()), .distinct = distinct },
                    .order_by = null,
                    .limit = null,
                    .offset = null,
                    .next_query = null, // No chaining for minimal queries
                };
                break :blk_select .{ .Query = query };
            },
            .MATCH => blk_match: {
                // Check if this is a MATCH...DELETE pattern
                // We need to look ahead after parsing the MATCH pattern
                const saved_pos = self.lx.*;
                const saved_cur = self.cur;

                // Try to detect MATCH...DELETE pattern
                self.advance(); // Skip MATCH
                _ = self.parseGraphPattern() catch {
                    // If pattern parsing fails, restore and parse as query
                    self.lx.* = saved_pos;
                    self.cur = saved_cur;
                    const first = try self.parseQuery();
                    break :blk_match self.handleQueryResult(first);
                };

                // Check for optional WHERE
                if (self.cur.kind == .WHERE) {
                    self.advance();
                    _ = self.parseOrExpr() catch {};
                }

                // Check if DELETE or DETACH DELETE follows
                const is_delete = self.cur.kind == .DELETE or self.cur.kind == .DETACH;

                // Restore position
                self.lx.* = saved_pos;
                self.cur = saved_cur;

                if (is_delete) {
                    // Parse as MATCH...DELETE statement
                    self.advance(); // Skip MATCH
                    const match_pattern = try self.parseGraphPattern();

                    var where_clause: ?ast.Expr = null;
                    if (self.cur.kind == .WHERE) {
                        self.advance();
                        where_clause = try self.parseOrExpr();
                    }

                    // Handle optional DETACH
                    const detach = if (self.cur.kind == .DETACH) blk: {
                        self.advance();
                        break :blk true;
                    } else false;

                    _ = try self.expect(.DELETE);

                    // Parse items to delete
                    // GAP-0220 FIX: Use try for proper error propagation
                    var delete_items = try std.ArrayList(ast.DeleteItem).initCapacity(self.arena.allocator(), 0);

                    // Parse first item
                    const first_item = try self.parseDeleteItem();
                    try delete_items.append(self.arena.allocator(), first_item);

                    // Parse additional items
                    while (self.cur.kind == .comma) {
                        self.advance();
                        const item = try self.parseDeleteItem();
                        try delete_items.append(self.arena.allocator(), item);
                    }

                    // Optional RETURN clause
                    var return_clause: ?ast.ReturnClause = null;
                    if (self.cur.kind == .RETURN) {
                        self.advance();
                        const distinct = if (self.cur.kind == .DISTINCT) blk: {
                            self.advance();
                            break :blk true;
                        } else false;
                        var return_items = std.ArrayList(ast.ReturnItem).empty;
                        try self.parseProjectionItems(&return_items);
                        return_clause = .{
                            .items = try return_items.toOwnedSlice(self.arena.allocator()),
                            .distinct = distinct,
                        };
                    }

                    break :blk_match .{ .Delete = .{
                        .match_clause = match_pattern,
                        .where_clause = where_clause,
                        .detach = detach,
                        .items = try delete_items.toOwnedSlice(self.arena.allocator()),
                        .return_clause = return_clause,
                    } };
                }

                // Otherwise, parse as regular query
                const first = try self.parseQuery();
                break :blk_match self.handleQueryResult(first);
            },
            .OPTIONAL => blk_query: {
                const first = try self.parseQuery();
                break :blk_query self.handleQueryResult(first);
            },
            .WITH => blk_with: {
                // Handle WITH as statement starter: WITH expr AS alias [WITH ...] RETURN ...
                var first = try self.parseQuery();
                if (self.cur.kind == .UNION) {
                    // Move ORDER BY/LIMIT/OFFSET from first query to UNION level
                    var order_by: ?*ast.OrderBy = null;
                    if (first.order_by) |ord| {
                        const order_by_ptr = try self.arena.allocator().create(ast.OrderBy);
                        order_by_ptr.* = ord;
                        order_by = order_by_ptr;
                    }
                    var limit_val: ?u64 = if (first.limit) |l| @as(u64, @intCast(l)) else null;
                    var offset_val: ?u64 = if (first.offset) |o| @as(u64, @intCast(o)) else null;
                    var limit_param: ?[]const u8 = first.limit_param;
                    var offset_param: ?[]const u8 = first.offset_param;
                    first.order_by = null;
                    first.limit = null;
                    first.offset = null;
                    first.limit_param = null;
                    first.offset_param = null;

                    var parts = std.ArrayList(ast.UnionQuery.Part).empty;
                    while (self.cur.kind == .UNION) {
                        self.advance();
                        var all = false;
                        var distinct = false;
                        if (self.cur.kind == .ALL) {
                            all = true;
                            self.advance();
                        } else if (self.cur.kind == .DISTINCT) {
                            distinct = true;
                            self.advance();
                        }
                        if (self.cur.kind == .ALL or self.cur.kind == .DISTINCT) return self.unexpected("both ALL and DISTINCT specified");
                        var q2 = try self.parseQuery();
                        // If this is the last part, move its ORDER BY/LIMIT/OFFSET to UNION level
                        if (self.cur.kind != .UNION) {
                            if (q2.order_by) |ord| {
                                const order_by_ptr = try self.arena.allocator().create(ast.OrderBy);
                                order_by_ptr.* = ord;
                                order_by = order_by_ptr;
                            }
                            if (q2.limit) |lim| limit_val = @intCast(lim);
                            if (q2.offset) |off| offset_val = @intCast(off);
                            if (q2.limit_param) |p| limit_param = p;
                            if (q2.offset_param) |p| offset_param = p;
                        }
                        // Strip ORDER BY/LIMIT/OFFSET from tail queries
                        q2.order_by = null;
                        q2.limit = null;
                        q2.offset = null;
                        q2.limit_param = null;
                        q2.offset_param = null;
                        try parts.append(self.arena.allocator(), .{ .all = all, .distinct = distinct, .query = q2 });
                    }

                    // Parse optional ORDER BY, LIMIT, OFFSET after UNION (if not already set)

                    if (self.cur.kind == .ORDER) {
                        self.advance();
                        _ = try self.expect(.BY);
                        var keys = std.ArrayList(ast.OrderBy.OrderKey).empty;
                        while (true) {
                            const key_expr = try self.parseOrExpr();
                            const mods = try self.parseOrderKeyModifiers();
                            try keys.append(self.arena.allocator(), .{ .expr = key_expr, .desc = mods.desc, .nulls = mods.nulls });
                            if (self.cur.kind != .comma) break;
                            self.advance();
                        }
                        const order_by_ptr = try self.arena.allocator().create(ast.OrderBy);
                        order_by_ptr.* = .{ .keys = try keys.toOwnedSlice(self.arena.allocator()) };
                        order_by = order_by_ptr;
                    }

                    if (self.cur.kind == .LIMIT) {
                        self.advance();
                        const limit_expr = try self.parseOrExpr();
                        if (limit_expr != .Int) return self.unexpected("LIMIT requires integer constant");
                        limit_val = @intCast(limit_expr.Int);
                    }

                    if (self.cur.kind == .OFFSET or self.cur.kind == .SKIP) {
                        self.advance();
                        const offset_expr = try self.parseOrExpr();
                        if (offset_expr != .Int) return self.unexpected("OFFSET/SKIP requires integer constant");
                        offset_val = @intCast(offset_expr.Int);
                    }

                    break :blk_with .{ .Union = .{
                        .first = first,
                        .tails = try parts.toOwnedSlice(self.arena.allocator()),
                        .order_by = order_by,
                        .limit = limit_val,
                        .offset = offset_val,
                        .limit_param = limit_param,
                        .offset_param = offset_param,
                    } };
                }
                break :blk_with self.handleQueryResult(first);
            },
            .RETURN => blk_r: {
                // Parenthesized set expression grouping: (RETURN ... UNION ...)
                if (self.cur.kind == .l_paren) {
                    self.advance();
                    var first = try self.parseQuery();
                    var parts = std.ArrayList(ast.UnionQuery.Part).empty;
                    if (self.cur.kind != .UNION) return error.UnexpectedToken;
                    // Strip ORDER BY/LIMIT/OFFSET from first query - they apply outside the parentheses
                    first.order_by = null;
                    first.limit = null;
                    first.offset = null;

                    while (self.cur.kind == .UNION) {
                        self.advance();
                        var all = false;
                        var distinct = false;
                        if (self.cur.kind == .ALL) {
                            all = true;
                            self.advance();
                        } else if (self.cur.kind == .DISTINCT) {
                            distinct = true;
                            self.advance();
                        }
                        if (self.cur.kind == .ALL or self.cur.kind == .DISTINCT) return self.unexpected("both ALL and DISTINCT specified");
                        var q2 = try self.parseQuery();
                        // Strip ORDER BY/LIMIT/OFFSET from tail queries too
                        q2.order_by = null;
                        q2.limit = null;
                        q2.offset = null;
                        try parts.append(self.arena.allocator(), .{ .all = all, .distinct = distinct, .query = q2 });
                    }
                    _ = try self.expect(.r_paren);
                    // After grouped set expr, allow ORDER/LIMIT/OFFSET handled by outer caller; here we return a Union statement
                    break :blk_r .{ .Union = .{ .first = first, .tails = try parts.toOwnedSlice(self.arena.allocator()) } };
                }
                var first = try self.parseQuery();
                if (self.cur.kind == .UNION) {
                    // Move ORDER BY/LIMIT/OFFSET from first query to UNION level
                    var order_by: ?*ast.OrderBy = null;
                    if (first.order_by) |ord| {
                        const order_by_ptr = try self.arena.allocator().create(ast.OrderBy);
                        order_by_ptr.* = ord;
                        order_by = order_by_ptr;
                    }
                    var limit_val: ?u64 = if (first.limit) |l| @as(u64, @intCast(l)) else null;
                    var offset_val: ?u64 = if (first.offset) |o| @as(u64, @intCast(o)) else null;
                    var limit_param: ?[]const u8 = first.limit_param;
                    var offset_param: ?[]const u8 = first.offset_param;
                    first.order_by = null;
                    first.limit = null;
                    first.offset = null;
                    first.limit_param = null;
                    first.offset_param = null;

                    var parts = std.ArrayList(ast.UnionQuery.Part).empty;
                    while (self.cur.kind == .UNION) {
                        self.advance();
                        var all = false;
                        var distinct = false;
                        if (self.cur.kind == .ALL) {
                            all = true;
                            self.advance();
                        } else if (self.cur.kind == .DISTINCT) {
                            distinct = true;
                            self.advance();
                        }
                        if (self.cur.kind == .ALL or self.cur.kind == .DISTINCT) return self.unexpected("both ALL and DISTINCT specified");
                        var q2 = try self.parseQuery();
                        // If this is the last part, move its ORDER BY/LIMIT/OFFSET to UNION level
                        if (self.cur.kind != .UNION) {
                            if (q2.order_by) |ord| {
                                const order_by_ptr = try self.arena.allocator().create(ast.OrderBy);
                                order_by_ptr.* = ord;
                                order_by = order_by_ptr;
                            }
                            if (q2.limit) |lim| limit_val = @intCast(lim);
                            if (q2.offset) |off| offset_val = @intCast(off);
                            if (q2.limit_param) |p| limit_param = p;
                            if (q2.offset_param) |p| offset_param = p;
                        }
                        // Strip ORDER BY/LIMIT/OFFSET from tail queries
                        q2.order_by = null;
                        q2.limit = null;
                        q2.offset = null;
                        q2.limit_param = null;
                        q2.offset_param = null;
                        try parts.append(self.arena.allocator(), .{ .all = all, .distinct = distinct, .query = q2 });
                    }

                    // Parse optional ORDER BY, LIMIT, OFFSET after UNION (if not already set)

                    if (self.cur.kind == .ORDER) {
                        self.advance();
                        _ = try self.expect(.BY);
                        var keys = std.ArrayList(ast.OrderBy.OrderKey).empty;
                        while (true) {
                            const key_expr = try self.parseOrExpr();
                            const mods = try self.parseOrderKeyModifiers();
                            try keys.append(self.arena.allocator(), .{ .expr = key_expr, .desc = mods.desc, .nulls = mods.nulls });
                            if (self.cur.kind != .comma) break;
                            self.advance();
                        }
                        const order_by_ptr = try self.arena.allocator().create(ast.OrderBy);
                        order_by_ptr.* = .{ .keys = try keys.toOwnedSlice(self.arena.allocator()) };
                        order_by = order_by_ptr;
                    }

                    if (self.cur.kind == .LIMIT) {
                        self.advance();
                        const lim = try self.parseLimitValue();
                        limit_val = lim.value;
                        limit_param = lim.param;
                    }

                    if (self.cur.kind == .OFFSET or self.cur.kind == .SKIP) {
                        self.advance();
                        const off = try self.parseLimitValue();
                        offset_val = off.value;
                        offset_param = off.param;
                    }

                    break :blk_r .{ .Union = .{
                        .first = first,
                        .tails = try parts.toOwnedSlice(self.arena.allocator()),
                        .order_by = order_by,
                        .limit = limit_val,
                        .offset = offset_val,
                        .limit_param = limit_param,
                        .offset_param = offset_param,
                    } };
                }
                if (self.cur.kind == .INTERSECT or self.cur.kind == .EXCEPT) {
                    const kind = self.cur.kind;
                    self.advance();
                    var all = false;
                    var distinct = false;
                    if (self.cur.kind == .ALL) {
                        all = true;
                        self.advance();
                    } else if (self.cur.kind == .DISTINCT) {
                        distinct = true;
                        self.advance();
                    }
                    if (self.cur.kind == .ALL or self.cur.kind == .DISTINCT) return self.unexpected("both ALL and DISTINCT specified");
                    const rhs = try self.parseQuery();
                    if (kind == .INTERSECT) {
                        break :blk_r .{ .Intersect = .{ .left = first, .right = rhs, .all = all, .distinct = distinct } };
                    } else {
                        break :blk_r .{ .Except = .{ .left = first, .right = rhs, .all = all, .distinct = distinct } };
                    }
                }
                break :blk_r .{ .Query = first };
            },
            .SESSION => blk: {
                self.advance();
                if (self.cur.kind == .SET) {
                    break :blk try self.parseSessionSetStatement();
                }
                if (self.cur.kind == .RESET) {
                    break :blk try self.parseSessionResetStatement();
                }
                if (self.cur.kind == .CLOSE) {
                    self.advance();
                    break :blk .SessionClose;
                }
                return error.UnexpectedToken;
            },
            .SET => blk_set: {
                self.advance();
                // Check for SET SESSION syntax (alternative to SESSION SET)
                if (self.cur.kind == .SESSION) {
                    // Don't advance - parseSessionSetStatement expects to see SESSION and consume it
                    // Actually, parseSessionSetStatement expects to see SET, so we need to back up
                    // But we can't back up easily. Instead, let's call a version that skips the SET consumption
                    // For now, let's just inline the logic here
                    self.advance(); // consume SESSION

                    // Inline parseSessionSetStatement logic without the initial SET advance
                    if (self.cur.kind == .SCHEMA) {
                        self.advance();
                        const schema_name = if (self.cur.kind == .identifier or self.cur.kind == .string_lit) blk_schema: {
                            const name = self.cur.lexeme;
                            self.advance();
                            break :blk_schema name;
                        } else {
                            return error.UnexpectedToken;
                        };
                        break :blk_set .{ .SessionSet = .{
                            .clause_type = .{ .Schema = .{ .name = schema_name } },
                        } };
                    } else if (self.cur.kind == .GRAPH or self.cur.kind == .PROPERTY) {
                        const is_property = self.cur.kind == .PROPERTY;
                        if (is_property) self.advance();
                        _ = try self.expect(.GRAPH);

                        if (self.cur.kind == .eq) {
                            self.advance();
                        }

                        const graph_expr = if (self.cur.kind == .identifier or self.cur.kind == .string_lit) blk_graph: {
                            const expr = self.cur.lexeme;
                            self.advance();
                            break :blk_graph expr;
                        } else {
                            return error.UnexpectedToken;
                        };

                        break :blk_set .{ .SessionSet = .{
                            .clause_type = .{ .Graph = .{
                                .property_graph = is_property,
                                .expression = graph_expr,
                            } },
                        } };
                    }
                    return error.UnexpectedToken;
                }
                return error.UnexpectedToken;
            },
            .START => blk2: {
                self.advance();
                if (self.cur.kind == .TRANSACTION) {
                    self.advance();
                    // Parse optional transaction characteristics: READ ONLY | READ WRITE
                    if (self.cur.kind == .READ) {
                        self.advance();
                        if (self.cur.kind == .ONLY) {
                            self.advance();
                        } else if (self.cur.kind == .WRITE) {
                            self.advance();
                        }
                    }

                    // Parse optional transaction body: START TRANSACTION { statements }
                    var body: ?[]ast.Statement = null;
                    if (self.cur.kind == .l_brace) {
                        self.advance();

                        // Parse statements until we hit }
                        var statements = try std.ArrayList(ast.Statement).initCapacity(self.arena.allocator(), 4);
                        while (self.cur.kind != .r_brace and self.cur.kind != .eof) {
                            const stmt = try self.parseStatement();
                            try statements.append(self.arena.allocator(), stmt);

                            // Consume optional semicolon between statements
                            if (self.cur.kind == .semicolon) {
                                self.advance();
                            }
                        }

                        _ = try self.expect(.r_brace);
                        body = try statements.toOwnedSlice(self.arena.allocator());
                    }

                    break :blk2 .{ .StartTransaction = .{ .body = body } };
                }
                return error.UnexpectedToken;
            },
            .BEGIN => {
                self.advance();
                // BEGIN can be standalone or followed by TRANSACTION
                if (self.cur.kind == .TRANSACTION) {
                    self.advance();
                }
                return .{ .StartTransaction = .{ .body = null } };
            },
            .COMMIT => {
                self.advance();
                // COMMIT can be followed by TRANSACTION
                if (self.cur.kind == .TRANSACTION) {
                    self.advance();
                }
                return .Commit;
            },
            .ROLLBACK => {
                self.advance();
                // ROLLBACK can be followed by TRANSACTION
                if (self.cur.kind == .TRANSACTION) {
                    self.advance();
                }
                return .Rollback;
            },
            .CALL => blk_call: {
                self.advance();

                // Check if this is a subquery CALL { ... } or procedure call
                if (self.cur.kind == .l_brace) {
                    // CALL { subquery } syntax - parse as a full query with WITH support
                    self.advance();

                    // GAP-0125: Parse imported variables if WITH clause appears at start of CALL block
                    // CANARY: REQ=REQ-SUBQUERY-IMPORT-001; FEATURE="Subquery Imported Variables"; ASPECT=GQLCompliance; STATUS=TESTED; TEST=geodetestlab/specs/gql_subquery_comprehensive.yml; OWNER=parser; UPDATED=2026-01-25
                    var imported_vars: ?[][]const u8 = null;
                    if (self.cur.kind == .WITH) {
                        // Check if this is a WITH for imported variables (single variable references)
                        // vs a WITH projection clause
                        // Save lexer state to backtrack if needed
                        const saved_idx = self.lx.idx;
                        const saved_line = self.lx.line;
                        const saved_col = self.lx.col;
                        const saved_cur = self.cur;
                        self.advance();

                        // If the next token is a variable or identifier followed by comma or more variables,
                        // this is likely an import list
                        if (self.cur.kind == .dollar) {
                            var imports = std.ArrayList([]const u8).empty;
                            while (true) {
                                if (self.cur.kind == .dollar) {
                                    self.advance();
                                    if (self.cur.kind == .identifier) {
                                        const var_name = self.cur.lexeme;
                                        try imports.append(self.arena.allocator(), var_name);
                                        self.advance();
                                    }
                                }
                                if (self.cur.kind == .comma) {
                                    self.advance();
                                } else {
                                    break;
                                }
                            }
                            if (imports.items.len > 0) {
                                imported_vars = try imports.toOwnedSlice(self.arena.allocator());
                            }
                        } else {
                            // Not an import list, restore lexer position
                            self.lx.idx = saved_idx;
                            self.lx.line = saved_line;
                            self.lx.col = saved_col;
                            self.cur = saved_cur;
                        }
                    }

                    // Parse the query inside CALL { ... }
                    // This allows for queries with WITH clauses, nested CALLs, etc.
                    const query = try self.parseQuery();

                    // Wrap the query in a Statement
                    const stmt = try self.arena.allocator().create(ast.Statement);
                    stmt.* = .{ .Query = query };

                    // Expect closing brace
                    _ = try self.expect(.r_brace);

                    // If there's a WITH clause after the CALL, this needs to be parsed as a Query
                    // not as a standalone Statement.Call
                    if (self.cur.kind == .WITH or self.cur.kind == .WHERE) {
                        // Create a Query with initial_call_subquery set to the inner query
                        const query_ptr = try self.arena.allocator().create(ast.Query);
                        query_ptr.* = query;

                        // Parse the WITH and other clauses
                        // We need to create a new Query that wraps the CALL result
                        var with_clause: ?ast.WithClause = null;
                        var where_clause: ?ast.Expr = null;
                        var ret_clause: ast.ReturnClause = .{ .items = &.{}, .distinct = false };

                        if (self.cur.kind == .WITH) {
                            self.advance();
                            var witems = std.ArrayList(ast.ReturnItem).empty;
                            try self.parseProjectionItems(&witems);
                            with_clause = .{
                                .items = try witems.toOwnedSlice(self.arena.allocator()),
                                .order_by = null,
                                .limit = null,
                                .offset = null,
                            };
                        }

                        if (self.cur.kind == .WHERE) {
                            self.advance();
                            where_clause = try self.parseOrExpr();
                        }

                        if (self.cur.kind == .RETURN) {
                            self.advance();
                            const distinct = if (self.cur.kind == .DISTINCT) blk: {
                                self.advance();
                                break :blk true;
                            } else false;
                            var return_items = std.ArrayList(ast.ReturnItem).empty;
                            try self.parseProjectionItems(&return_items);
                            ret_clause = .{
                                .items = try return_items.toOwnedSlice(self.arena.allocator()),
                                .distinct = distinct,
                            };
                        }

                        // Create a Query with the CALL result as input
                        const wrapper_query = ast.Query{
                            .optional_match = false,
                            .match = .{ .chains = &.{} },
                            .where_clause = where_clause,
                            .with_clause = with_clause,
                            .ret = ret_clause,
                            .order_by = null,
                            .limit = null,
                            .offset = null,
                            .initial_call_subquery = query_ptr,
                        };

                        break :blk_call .{ .Query = wrapper_query };
                    }

                    // Optional RETURN clause after subquery
                    var return_clause: ?ast.ReturnClause = null;
                    if (self.cur.kind == .RETURN) {
                        self.advance();
                        const distinct = if (self.cur.kind == .DISTINCT) blk: {
                            self.advance();
                            break :blk true;
                        } else false;
                        var return_items = std.ArrayList(ast.ReturnItem).empty;
                        try self.parseProjectionItems(&return_items);
                        return_clause = .{
                            .items = try return_items.toOwnedSlice(self.arena.allocator()),
                            .distinct = distinct,
                        };
                    }

                    break :blk_call .{
                        .Call = .{
                            .Subquery = .{
                                .statement = stmt,
                                .imported_vars = imported_vars, // GAP-0125: Pass imported variables
                                .return_clause = return_clause,
                            },
                        },
                    };
                } else {
                    // Traditional procedure call (e.g., db.labels())
                    const procedure = try self.parseOrExpr();

                    // Optional YIELD clause
                    var yield_items: ?[]ast.ReturnItem = null;
                    if (self.cur.kind == .YIELD) {
                        self.advance();
                        var items = std.ArrayList(ast.ReturnItem).empty;
                        try self.parseProjectionItems(&items);
                        yield_items = try items.toOwnedSlice(self.arena.allocator());
                    }

                    // Optional RETURN clause
                    var return_clause: ?ast.ReturnClause = null;
                    if (self.cur.kind == .RETURN) {
                        self.advance();
                        const distinct = if (self.cur.kind == .DISTINCT) blk: {
                            self.advance();
                            break :blk true;
                        } else false;
                        var return_items = std.ArrayList(ast.ReturnItem).empty;
                        try self.parseProjectionItems(&return_items);
                        return_clause = .{
                            .items = try return_items.toOwnedSlice(self.arena.allocator()),
                            .distinct = distinct,
                        };
                    }

                    // Optional ORDER BY clause (after RETURN)
                    var order_by: ?ast.OrderBy = null;
                    if (return_clause != null and self.cur.kind == .ORDER) {
                        self.advance();
                        _ = try self.expect(.BY);
                        var keys = std.ArrayList(ast.OrderBy.OrderKey).empty;
                        const expr1 = try self.parseOrExpr();
                        const mods1 = try self.parseOrderKeyModifiers();
                        try keys.append(self.arena.allocator(), .{ .expr = expr1, .desc = mods1.desc, .nulls = mods1.nulls });
                        while (self.cur.kind == .comma) {
                            self.advance();
                            const exprk = try self.parseOrExpr();
                            const modsk = try self.parseOrderKeyModifiers();
                            try keys.append(self.arena.allocator(), .{ .expr = exprk, .desc = modsk.desc, .nulls = modsk.nulls });
                        }
                        order_by = .{ .keys = try keys.toOwnedSlice(self.arena.allocator()) };
                    }

                    // Optional LIMIT clause
                    var limit: ?usize = null;
                    var limit_param: ?[]const u8 = null;
                    if (self.cur.kind == .LIMIT) {
                        self.advance();
                        const lim = try self.parseLimitValue();
                        limit = if (lim.value) |v| @as(usize, @intCast(v)) else null;
                        limit_param = lim.param;
                    }

                    // Optional OFFSET/SKIP clause
                    var offset: ?usize = null;
                    var offset_param: ?[]const u8 = null;
                    if (self.cur.kind == .OFFSET or self.cur.kind == .SKIP) {
                        self.advance();
                        const off = try self.parseLimitValue();
                        offset = if (off.value) |v| @as(usize, @intCast(v)) else null;
                        offset_param = off.param;
                    }

                    break :blk_call .{ .Call = .{ .Procedure = .{
                        .procedure = procedure,
                        .yield_items = yield_items,
                        .return_clause = return_clause,
                        .order_by = order_by,
                        .limit = limit,
                        .offset = offset,
                        .limit_param = limit_param,
                        .offset_param = offset_param,
                    } } };
                }
            },
            .l_paren => blk_paren: {
                // CANARY: REQ=REQ-GQL-085; FEATURE="ParenthesizedSetOperations"; ASPECT=ParserSupport; STATUS=TESTED; OWNER=parser; UPDATED=2025-10-14
                // Parse parenthesized statement: (MATCH ... UNION ...) INTERSECT ...
                self.advance(); // consume (
                const inner_stmt = try self.parseStatement();
                _ = try self.expect(.r_paren);

                // Check if this is followed by set operations
                if (self.cur.kind == .UNION or self.cur.kind == .INTERSECT or self.cur.kind == .EXCEPT) {
                    // Extract the first query from the inner statement
                    const first = switch (inner_stmt) {
                        .Query => |q| q,
                        .Union => |u| blk_first: {
                            // Convert Union statement back to a query by wrapping it
                            // For now, we'll just use the first query from the union
                            break :blk_first u.first;
                        },
                        else => return error.UnexpectedToken,
                    };

                    // Parse the rest of the set operations
                    var parts = std.ArrayList(ast.UnionQuery.Part).empty;

                    // If inner_stmt was a Union, add its tails first
                    if (inner_stmt == .Union) {
                        for (inner_stmt.Union.tails) |tail| {
                            try parts.append(self.arena.allocator(), tail);
                        }
                    }

                    // Parse additional set operations
                    while (self.cur.kind == .UNION or self.cur.kind == .INTERSECT or self.cur.kind == .EXCEPT) {
                        const operation = switch (self.cur.kind) {
                            .UNION => ast.SetOperation.union_op,
                            .INTERSECT => ast.SetOperation.intersect,
                            .EXCEPT => ast.SetOperation.except,
                            else => unreachable,
                        };
                        self.advance();
                        var all = false;
                        var distinct = false;
                        if (self.cur.kind == .ALL) {
                            all = true;
                            self.advance();
                        } else if (self.cur.kind == .DISTINCT) {
                            distinct = true;
                            self.advance();
                        }
                        const q = try self.parseQuery();
                        try parts.append(self.arena.allocator(), .{ .operation = operation, .all = all, .distinct = distinct, .query = q });
                    }

                    break :blk_paren .{ .Union = .{
                        .first = first,
                        .tails = try parts.toOwnedSlice(self.arena.allocator()),
                        .order_by = null,
                        .limit = null,
                        .offset = null,
                    } };
                }

                // No set operations, just return the inner statement
                break :blk_paren inner_stmt;
            },
            else => return error.UnexpectedToken,
        };
    }

    fn handleQueryResult(self: *Parser, first: ast.Query) ParserError!ast.Statement {
        if (self.cur.kind == .UNION or self.cur.kind == .INTERSECT or self.cur.kind == .EXCEPT) {
            // CANARY: REQ=REQ-GQL-100; FEATURE="UNION Query Operations"; ASPECT=Parser; STATUS=TESTED; TEST=gql_conformance.T1; OWNER=parser; UPDATED=2025-10-14
            // When we have set operations, individual queries should not have their own ORDER BY/LIMIT/OFFSET
            // Those clauses apply to the entire set operation result
            // If the first query has these, they should be moved to the UNION level
            var first_query = first;
            var order_by: ?*ast.OrderBy = null;
            if (first.order_by) |ord| {
                const order_by_ptr = try self.arena.allocator().create(ast.OrderBy);
                order_by_ptr.* = ord;
                order_by = order_by_ptr;
            }
            var limit_val: ?u64 = if (first.limit) |l| @as(u64, @intCast(l)) else null;
            var offset_val: ?u64 = if (first.offset) |o| @as(u64, @intCast(o)) else null;
            var limit_param: ?[]const u8 = first.limit_param;
            var offset_param: ?[]const u8 = first.offset_param;
            first_query.order_by = null;
            first_query.limit = null;
            first_query.offset = null;
            first_query.limit_param = null;
            first_query.offset_param = null;

            var parts = std.ArrayList(ast.UnionQuery.Part).empty;
            while (self.cur.kind == .UNION or self.cur.kind == .INTERSECT or self.cur.kind == .EXCEPT) {
                const operation = switch (self.cur.kind) {
                    .UNION => ast.SetOperation.union_op,
                    .INTERSECT => ast.SetOperation.intersect,
                    .EXCEPT => ast.SetOperation.except,
                    else => unreachable,
                };
                self.advance();
                var all = false;
                var distinct = false;
                if (self.cur.kind == .ALL) {
                    all = true;
                    self.advance();
                } else if (self.cur.kind == .DISTINCT) {
                    distinct = true;
                    self.advance();
                }
                // Disallow both modifiers at once
                if (self.cur.kind == .ALL or self.cur.kind == .DISTINCT) return self.unexpected("both ALL and DISTINCT specified");
                var q = try self.parseQuery();
                // If this is the last part and it has ORDER BY/LIMIT/OFFSET, use those for the UNION level
                if (self.cur.kind != .UNION and self.cur.kind != .INTERSECT and self.cur.kind != .EXCEPT) {
                    if (q.order_by) |ord| {
                        const order_by_ptr = try self.arena.allocator().create(ast.OrderBy);
                        order_by_ptr.* = ord;
                        order_by = order_by_ptr;
                    }
                    if (q.limit) |lim| limit_val = @intCast(lim);
                    if (q.offset) |off| offset_val = @intCast(off);
                    if (q.limit_param) |p| limit_param = p;
                    if (q.offset_param) |p| offset_param = p;
                }
                // Strip ORDER BY/LIMIT/OFFSET from tail queries - they apply at set operation level
                q.order_by = null;
                q.limit = null;
                q.offset = null;
                q.limit_param = null;
                q.offset_param = null;
                try parts.append(self.arena.allocator(), .{ .operation = operation, .all = all, .distinct = distinct, .query = q });
            }

            // Parse optional ORDER BY, LIMIT, OFFSET after set operations (if not already set from last query)

            if (self.cur.kind == .ORDER) {
                self.advance();
                _ = try self.expect(.BY);
                var keys = std.ArrayList(ast.OrderBy.OrderKey).empty;
                while (true) {
                    const key_expr = try self.parseOrExpr();
                    const mods = try self.parseOrderKeyModifiers();
                    try keys.append(self.arena.allocator(), .{ .expr = key_expr, .desc = mods.desc, .nulls = mods.nulls });
                    if (self.cur.kind != .comma) break;
                    self.advance();
                }
                const order_by_ptr = try self.arena.allocator().create(ast.OrderBy);
                order_by_ptr.* = .{ .keys = try keys.toOwnedSlice(self.arena.allocator()) };
                order_by = order_by_ptr;
            }

            if (self.cur.kind == .LIMIT) {
                self.advance();
                const lim = try self.parseLimitValue();
                limit_val = lim.value;
                limit_param = lim.param;
            }

            if (self.cur.kind == .OFFSET or self.cur.kind == .SKIP) {
                self.advance();
                const off = try self.parseLimitValue();
                offset_val = off.value;
                offset_param = off.param;
            }

            return .{ .Union = .{
                .first = first_query,
                .tails = try parts.toOwnedSlice(self.arena.allocator()),
                .order_by = order_by,
                .limit = limit_val,
                .offset = offset_val,
                .limit_param = limit_param,
                .offset_param = offset_param,
            } };
        }
        return .{ .Query = first };
    }

    fn parseQuery(self: *Parser) ParserError!ast.Query {
        self.recur_depth += 1;
        defer self.recur_depth -= 1;
        if (self.recur_depth > MAX_RECUR_DEPTH) return error.UnexpectedToken;
        // Parse LET bindings first (LET $var = expr, ...)
        var let_bindings = std.ArrayList(ast.LetBinding).empty;
        if (self.cur.kind == .LET) {
            self.advance();
            while (true) {
                // Parse $variable
                if (self.cur.kind != .dollar) return self.unexpected("expected $ parameter variable after LET");
                self.advance();
                if (self.cur.kind != .identifier) return self.unexpected("expected identifier after $");
                const var_name = self.cur.lexeme;
                self.advance();
                _ = try self.expect(.eq);
                const value_expr = try self.parseOrExpr();
                try let_bindings.append(self.arena.allocator(), .{ .variable = var_name, .value = value_expr });
                // Allow comma for multiple bindings: LET $x = 1, $y = 2
                if (self.cur.kind == .comma) {
                    self.advance();
                    continue;
                }
                break;
            }
        }

        // Optional MATCH/OPTIONAL MATCH/CREATE pattern; allow RETURN-only queries too.
        var optional_match = false;
        var have_match = false;
        var have_create = false;
        var create_pattern: ?ast.GraphPattern = null;
        var merge_statement: ?*ast.MergeStatement = null;

        // Check for WITH at the beginning (for queries like: WITH 5 AS x RETURN x)
        // Parse WITH clause first if present, before MATCH/CREATE
        var initial_with_clause: ?ast.WithClause = null;
        var initial_where_expr: ?ast.Expr = null; // WHERE clause after initial WITH
        if (self.cur.kind == .WITH) {
            self.advance();
            // Support WITH DISTINCT for initial WITH clause
            const with_distinct = if (self.cur.kind == .DISTINCT) blk: {
                self.advance();
                break :blk true;
            } else false;
            var witems = std.ArrayList(ast.ReturnItem).empty;
            try self.parseProjectionItems(&witems);

            // Parse optional ORDER BY, LIMIT, OFFSET after WITH items
            var with_order_by: ?*ast.OrderBy = null;
            var with_limit: ?u64 = null;
            var with_offset: ?u64 = null;
            var with_limit_param: ?[]const u8 = null;
            var with_offset_param: ?[]const u8 = null;

            if (self.cur.kind == .ORDER) {
                self.advance();
                _ = try self.expect(.BY);
                var keys = std.ArrayList(ast.OrderBy.OrderKey).empty;
                while (true) {
                    const key_expr = try self.parseOrExpr();
                    const mods = try self.parseOrderKeyModifiers();
                    try keys.append(self.arena.allocator(), .{ .expr = key_expr, .desc = mods.desc, .nulls = mods.nulls });
                    if (self.cur.kind != .comma) break;
                    self.advance();
                }
                const order_by_ptr = try self.arena.allocator().create(ast.OrderBy);
                order_by_ptr.* = .{ .keys = try keys.toOwnedSlice(self.arena.allocator()) };
                with_order_by = order_by_ptr;
            }

            if (self.cur.kind == .LIMIT) {
                self.advance();
                const lim = try self.parseLimitValue();
                with_limit = lim.value;
                with_limit_param = lim.param;
            }

            if (self.cur.kind == .OFFSET or self.cur.kind == .SKIP) {
                self.advance();
                const off = try self.parseLimitValue();
                with_offset = off.value;
                with_offset_param = off.param;
            }

            initial_with_clause = .{
                .items = try witems.toOwnedSlice(self.arena.allocator()),
                .distinct = with_distinct,
                .order_by = with_order_by,
                .limit = with_limit,
                .offset = with_offset,
                .limit_param = with_limit_param,
                .offset_param = with_offset_param,
            };

            // CANARY: REQ=REQ-GQL-WITH-WHERE-003; FEATURE="InitialWithWhere"; ASPECT=ParserSupport; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=parser; UPDATED=2025-12-24
            // Allow optional WHERE after initial WITH to filter the projected bindings
            // This is for queries like: WITH 5 AS x WHERE x > 0 RETURN x
            // Or chained: MATCH (n) WITH n.name AS name WITH name WHERE name = 'Alice' RETURN name
            if (self.cur.kind == .WHERE) {
                self.advance();
                initial_where_expr = try self.parseOrExpr();
            }

            // Check for FOR after initial WITH clause
            if (self.cur.kind == .FOR) {
                // Parse FOR statement and store it in the query
                const for_stmt = try self.parseForStatement();
                // Allocate ForStatement on arena
                const for_ptr = try self.arena.allocator().create(ast.ForStatement);
                for_ptr.* = for_stmt.For;

                return ast.Query{
                    .optional_match = false,
                    .match = .{ .chains = &.{} }, // Empty match pattern
                    .create_pattern = null,
                    .where_clause = null,
                    .with_clause = initial_with_clause,
                    .set_clauses = &.{},
                    .remove_clauses = &.{},
                    .ret = for_stmt.For.return_clause,
                    .order_by = for_stmt.For.order_by,
                    .offset = for_stmt.For.offset,
                    .limit = for_stmt.For.limit,
                    .next_query = null,
                    .group_by = null,
                    .having = null,
                    .for_statement = for_ptr,
                };
            }

            // CANARY: REQ=REQ-GQL-WITH-CHAIN-003; FEATURE="ConsecutiveWithClauses"; ASPECT=ParserSupport; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=parser; UPDATED=2025-12-24
            // Check for another WITH after initial WITH (chained WITH clauses without MATCH)
            // e.g., WITH 'Alice' AS n WITH n AS n2 RETURN n2
            if (self.cur.kind == .WITH) {
                // Parse the continuation as a new query
                const next_query = try self.parseQuery();
                // Allocate on arena and store pointer
                const next_ptr = try self.arena.allocator().create(ast.Query);
                next_ptr.* = next_query;

                // Return a query with initial_with_clause and next_query
                return ast.Query{
                    .optional_match = false,
                    .match = .{ .chains = &.{} }, // Empty match pattern
                    .create_pattern = null,
                    .where_clause = initial_where_expr,
                    .with_clause = null, // WITH items become ret.items for chaining
                    .set_clauses = &.{},
                    .remove_clauses = &.{},
                    .ret = .{ .items = initial_with_clause.?.items, .distinct = false },
                    .order_by = null,
                    .limit = null,
                    .offset = null,
                    .next_query = next_ptr,
                    .group_by = null,
                    .having = null,
                };
            }

            // GAP #57: Handle MERGE after initial WITH clause (e.g., WITH a MERGE (b) RETURN ...)
            if (self.cur.kind == .MERGE) {
                const merge_stmt = try self.parseMergeStatement();
                const merge_ptr = try self.arena.allocator().create(ast.MergeStatement);
                merge_ptr.* = merge_stmt.Merge;

                return ast.Query{
                    .optional_match = false,
                    .match = .{ .chains = &.{} },
                    .create_pattern = null,
                    .where_clause = initial_where_expr,
                    .with_clause = null,
                    .is_initial_with = true,
                    .set_clauses = &.{},
                    .remove_clauses = &.{},
                    .ret = merge_stmt.Merge.return_clause orelse .{ .items = initial_with_clause.?.items, .distinct = false },
                    .order_by = null,
                    .limit = null,
                    .offset = null,
                    .next_query = null,
                    .group_by = null,
                    .having = null,
                    .merge_statement = merge_ptr,
                };
            }
        }

        // Check for SELECT at the beginning (for queries like: SELECT 1 AS x)
        // SELECT maps to RETURN semantics - treat as RETURN to allow variable access
        // When SELECT appears in UNION after CREATE, it should access CREATE variables
        var select_mode = false;
        if (self.cur.kind == .SELECT) {
            select_mode = true;
            self.advance();
            var distinct = false;
            if (self.cur.kind == .DISTINCT) {
                distinct = true;
                self.advance();
            }
            var items = std.ArrayList(ast.ReturnItem).empty;
            try self.parseProjectionItems(&items);

            // Instead of returning immediately, store as initial_with_clause
            // This allows SELECT to access variables from enclosing scope (like CREATE variables in UNION)
            initial_with_clause = .{
                .items = try items.toOwnedSlice(self.arena.allocator()),
                .order_by = null,
                .limit = null,
                .offset = null,
            };
            // Continue parsing - SELECT acts like WITH, making variables available to RETURN
        }

        // Check for UNWIND clause
        // UNWIND list_expr AS variable
        var unwind_clause: ?ast.UnwindClause = null;
        if (self.cur.kind == .UNWIND) {
            self.has_unwind = true;
            self.advance();
            const list_expr = try self.parseOrExpr();
            _ = try self.expect(.AS);
            if (self.cur.kind != .identifier) return self.unexpected("expected identifier after UNWIND ... AS");
            const var_name = self.cur.lexeme;
            self.advance();
            unwind_clause = .{ .list_expr = list_expr, .variable = var_name };
        }

        // Check for CALL { subquery } at the beginning
        var initial_call_subquery: ?*ast.Query = null;
        if (self.cur.kind == .CALL) {
            const peek_ahead = self.peekToken();
            if (peek_ahead == .l_brace) {
                // CALL { subquery } syntax - parse the subquery and continue with WITH/WHERE/RETURN
                self.advance(); // consume CALL
                self.advance(); // consume {

                // Parse the inner query
                const inner_query = try self.parseQuery();

                // Consume closing brace
                _ = try self.expect(.r_brace);

                // Store pointer to inner query for execution
                const inner_query_ptr = try self.arena.allocator().create(ast.Query);
                inner_query_ptr.* = inner_query;
                initial_call_subquery = inner_query_ptr;

                // Continue parsing - don't return yet, let the rest of parseQuery handle
                // any WITH/WHERE/RETURN that follows
            } else {
                // Regular procedure CALL - return empty query for now
                // This will be handled elsewhere in the query body
                const empty_match = ast.GraphPattern{ .chains = &.{} };
                return ast.Query{
                    .optional_match = false,
                    .match = empty_match,
                    .create_pattern = null,
                    .where_clause = null,
                    .with_clause = null,
                    .set_clauses = &.{},
                    .remove_clauses = &.{},
                    .ret = .{ .items = &.{}, .distinct = false },
                    .order_by = null,
                    .limit = null,
                    .offset = null,
                    .next_query = null,
                    .group_by = null,
                    .having = null,
                };
            }
        }

        // Check for CREATE at the beginning - support multiple consecutive CREATE clauses
        // e.g., CREATE (a:Node) CREATE (b:Node) WITH 1 AS x ...
        // CANARY: REQ=REQ-GQL-MULTI-CREATE-001; FEATURE="MultipleConsecutiveCreate"; ASPECT=Parser; STATUS=TESTED; TEST=geodetestlab/specs/gql_data_modification_comprehensive.yml; OWNER=parser; UPDATED=2025-12-27
        if (self.cur.kind == .CREATE) {
            have_create = true;
            var create_chains = std.ArrayList(ast.Chain).empty;
            while (self.cur.kind == .CREATE) {
                self.advance();
                const cp = try self.parseGraphPattern();
                for (cp.chains) |chain| {
                    try create_chains.append(self.arena.allocator(), chain);
                }
            }
            create_pattern = .{ .chains = try create_chains.toOwnedSlice(self.arena.allocator()) };
        } else if (self.cur.kind == .OPTIONAL) {
            self.advance();
            // Check for OPTIONAL { } block, OPTIONAL (...), or OPTIONAL MATCH
            if (self.cur.kind == .l_brace or self.cur.kind == .l_paren) {
                // OPTIONAL { ... } or OPTIONAL (...) block - treat as optional match without initial MATCH
                optional_match = true;
                have_match = false; // Will parse inside the block
            } else {
                optional_match = true;
                have_match = true;
            }
        }
        if (self.cur.kind == .MATCH and !have_create) {
            have_match = true;
        }
        // Handle OPTIONAL { } or OPTIONAL (...) without preceding MATCH
        if ((self.cur.kind == .l_brace or self.cur.kind == .l_paren) and optional_match and !have_match) {
            have_match = true;
        }
        // Prepare defaults
        // Initialize where_expr from initial_where_expr (from initial WITH clause if present)
        var where_expr: ?ast.Expr = initial_where_expr;
        var with_clause: ?ast.WithClause = null;
        var group_by: ?ast.GroupBy = null;
        var having_expr: ?ast.Expr = null;
        var path_variable: ?[]const u8 = null;
        const pat: ast.GraphPattern = if (have_match) blk_pat: {
            // Handle OPTIONAL { } at the start
            var all_chains = std.ArrayList(ast.Chain).empty;

            if ((self.cur.kind == .l_brace or self.cur.kind == .l_paren) and optional_match) {
                // OPTIONAL { ... } or OPTIONAL (...) at the start
                const is_paren = self.cur.kind == .l_paren;
                const close_token = if (is_paren) tok.TokenKind.r_paren else tok.TokenKind.r_brace;
                self.advance(); // consume { or (
                // Parse multiple MATCH patterns inside the block
                while (self.cur.kind != close_token and self.cur.kind != .eof) {
                    if (self.cur.kind == .MATCH) {
                        self.advance();
                        const block_gp = try self.parseGraphPattern();
                        for (block_gp.chains) |chain| {
                            try all_chains.append(self.arena.allocator(), chain);
                        }
                        // Optional semicolon separator
                        if (self.cur.kind == .semicolon) {
                            self.advance();
                        }
                    } else {
                        return error.UnexpectedToken;
                    }
                }
                if (is_paren) {
                    _ = try self.expect(.r_paren);
                } else {
                    _ = try self.expect(.r_brace);
                }
                break :blk_pat .{ .chains = try all_chains.toOwnedSlice(self.arena.allocator()) };
            }

            _ = try self.expect(.MATCH);
            // For the top-level MATCH pattern, collect aliases freshly.
            self.collect_chain_aliases = true;
            self.path_aliases.clearRetainingCapacity();

            // Path variable assignment is handled inside parseGraphPattern

            // Parse first MATCH pattern
            const first_gp = try self.parseGraphPattern();

            // Extract path variable from the first named chain
            for (first_gp.chains) |chain| {
                if (chain.name) |name| {
                    path_variable = name;
                    break;
                }
            }
            for (first_gp.chains) |chain| {
                try all_chains.append(self.arena.allocator(), chain);
            }

            // Check for additional MATCH or OPTIONAL MATCH clauses and combine their chains
            // CANARY: REQ=REQ-GQL-OPTIONAL-MATCH-002; FEATURE="OptionalMatchParsing"; ASPECT=ChainMarking; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=parser; UPDATED=2025-12-22
            while (self.cur.kind == .MATCH or self.cur.kind == .OPTIONAL) {
                // Track whether current chains are optional (for OPTIONAL MATCH)
                var is_currently_optional = false;
                // Handle OPTIONAL MATCH
                if (self.cur.kind == .OPTIONAL) {
                    self.advance();
                    is_currently_optional = true;
                    // Check for OPTIONAL { ... } or OPTIONAL (...) block syntax
                    if (self.cur.kind == .l_brace or self.cur.kind == .l_paren) {
                        const is_paren = self.cur.kind == .l_paren;
                        const close_token = if (is_paren) tok.TokenKind.r_paren else tok.TokenKind.r_brace;
                        self.advance(); // consume { or (
                        // Parse multiple MATCH patterns inside the block
                        while (self.cur.kind != close_token and self.cur.kind != .eof) {
                            if (self.cur.kind == .MATCH) {
                                self.advance();
                                const block_gp = try self.parseGraphPattern();
                                for (block_gp.chains) |chain| {
                                    // Mark chain as optional
                                    var optional_chain = chain;
                                    optional_chain.is_optional = true;
                                    try all_chains.append(self.arena.allocator(), optional_chain);
                                }
                                // Optional semicolon separator
                                if (self.cur.kind == .semicolon) {
                                    self.advance();
                                }
                            } else {
                                return error.UnexpectedToken;
                            }
                        }
                        if (is_paren) {
                            _ = try self.expect(.r_paren);
                        } else {
                            _ = try self.expect(.r_brace);
                        }
                        optional_match = true;
                        continue;
                    }
                    if (self.cur.kind != .MATCH) {
                        return error.UnexpectedToken;
                    }
                    // Mark that we have an optional match (this affects the overall query)
                    optional_match = true;
                }
                self.advance(); // consume MATCH
                const additional_gp = try self.parseGraphPattern();
                for (additional_gp.chains) |chain| {
                    // Mark chain as optional if from OPTIONAL MATCH
                    if (is_currently_optional) {
                        var optional_chain = chain;
                        optional_chain.is_optional = true;
                        try all_chains.append(self.arena.allocator(), optional_chain);
                    } else {
                        try all_chains.append(self.arena.allocator(), chain);
                    }
                }
            }

            var combined_gp = ast.GraphPattern{ .chains = try all_chains.toOwnedSlice(self.arena.allocator()) };

            // Keep aliases for ORDER BY checks that follow.
            self.collect_chain_aliases = false;
            // optional WHERE predicate
            if (self.cur.kind == .WHERE) {
                self.advance();
                where_expr = try self.parseOrExpr();
            }

            // CANARY: REQ=REQ-GQL-OPTIONAL-MATCH-003; FEATURE="OptionalMatchAfterWhere"; ASPECT=ParserSupport; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=parser; UPDATED=2025-12-24
            // Check for OPTIONAL MATCH after WHERE clause
            // e.g., MATCH (e) WHERE e.x = 1 OPTIONAL MATCH (e)-[:R]->(m) RETURN ...
            if (self.cur.kind == .OPTIONAL) {
                var post_where_chains = std.ArrayList(ast.Chain).empty;
                // First add the existing chains
                for (combined_gp.chains) |chain| {
                    try post_where_chains.append(self.arena.allocator(), chain);
                }
                // Parse OPTIONAL MATCH clauses
                while (self.cur.kind == .OPTIONAL) {
                    self.advance(); // consume OPTIONAL
                    if (self.cur.kind == .MATCH) {
                        self.advance(); // consume MATCH
                        const opt_gp = try self.parseGraphPattern();
                        for (opt_gp.chains) |chain| {
                            var optional_chain = chain;
                            optional_chain.is_optional = true;
                            try post_where_chains.append(self.arena.allocator(), optional_chain);
                        }
                    } else {
                        return error.UnexpectedToken;
                    }
                }
                combined_gp = .{ .chains = try post_where_chains.toOwnedSlice(self.arena.allocator()) };
            }

            // CANARY: REQ=REQ-GQL-MATCH-AFTER-WHERE-001; FEATURE="MatchAfterWhere"; ASPECT=ParserSupport; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=parser; UPDATED=2025-12-26
            // Check for required MATCH after WHERE clause
            // e.g., MATCH (d:Department) WHERE d.budget > 0 MATCH (e:Employee {department: d.name}) RETURN ...
            if (self.cur.kind == .MATCH) {
                var post_where_chains = std.ArrayList(ast.Chain).empty;
                // First add the existing chains
                for (combined_gp.chains) |chain| {
                    try post_where_chains.append(self.arena.allocator(), chain);
                }
                // Parse additional MATCH clauses
                while (self.cur.kind == .MATCH) {
                    self.advance(); // consume MATCH
                    const additional_pattern = try self.parseGraphPattern();
                    for (additional_pattern.chains) |additional_chain| {
                        try post_where_chains.append(self.arena.allocator(), additional_chain);
                    }
                    // Check for WHERE clause after this MATCH
                    if (self.cur.kind == .WHERE) {
                        self.advance();
                        // Combine with existing where_expr using AND
                        const new_where = try self.parseOrExpr();
                        if (where_expr) |existing_where| {
                            where_expr = try self.makeBinary(.And, existing_where, new_where);
                        } else {
                            where_expr = new_where;
                        }
                    }
                }
                combined_gp = .{ .chains = try post_where_chains.toOwnedSlice(self.arena.allocator()) };
            }

            // After MATCH ... WHERE, check for MERGE - support MATCH ... MERGE pattern
            if (self.cur.kind == .MERGE) {
                const merge_stmt = try self.parseMergeStatement();
                const merge_ptr = try self.arena.allocator().create(ast.MergeStatement);
                merge_ptr.* = merge_stmt.Merge;
                merge_statement = merge_ptr;
            }

            // After MATCH ... WHERE, check for CREATE - support multiple CREATE clauses
            // e.g., MATCH (a), (b), (c) CREATE (a)-[:R]->(b) CREATE (a)-[:R]->(c)
            if (self.cur.kind == .CREATE) {
                have_create = true;
                var create_chains = std.ArrayList(ast.Chain).empty;
                while (self.cur.kind == .CREATE) {
                    self.advance();
                    const cp = try self.parseGraphPattern();
                    for (cp.chains) |chain| {
                        try create_chains.append(self.arena.allocator(), chain);
                    }
                }
                create_pattern = .{ .chains = try create_chains.toOwnedSlice(self.arena.allocator()) };
            }

            break :blk_pat combined_gp;
        } else if (have_create) blk_create: {
            // CREATE pattern without MATCH: use empty pattern for match
            self.path_aliases.clearRetainingCapacity();
            break :blk_create .{ .chains = &.{} };
        } else blk_empty: {
            // No MATCH or CREATE: use empty pattern, and ensure no stale aliases
            self.path_aliases.clearRetainingCapacity();
            break :blk_empty .{ .chains = &.{} };
        };

        // Parse WHERE clause (for CREATE patterns or after MATCH)
        if (!have_match and where_expr == null and self.cur.kind == .WHERE) {
            self.advance();
            where_expr = try self.parseOrExpr();
        }

        // Parse FILTER clause (ISO/IEC 39075:2024)
        var filter_expr: ?ast.Expr = null;
        if (self.cur.kind == .FILTER) {
            self.advance();
            // FILTER can have optional WHERE keyword: "FILTER WHERE expr" or "FILTER expr"
            if (self.cur.kind == .WHERE) {
                self.advance();
            }
            filter_expr = try self.parseOrExpr();
        }

        // Parse inline LET clause (after MATCH/WHERE/FILTER, before WITH/RETURN)
        // Syntax: MATCH ... LET var1 = expr1, var2 = expr2 RETURN ...
        // Note: These are computed bindings (no $ prefix), different from parameter bindings
        var inline_let_bindings = std.ArrayList(ast.LetBinding).empty;
        if (self.cur.kind == .LET) {
            self.advance();
            while (true) {
                // Parse variable name (no $ prefix for inline LET)
                if (self.cur.kind != .identifier) return self.unexpected("expected identifier after LET");
                const var_name = self.cur.lexeme;
                self.advance();
                _ = try self.expect(.eq);
                const value_expr = try self.parseOrExpr();
                try inline_let_bindings.append(self.arena.allocator(), .{ .variable = var_name, .value = value_expr });
                // Allow comma for multiple bindings: LET x = 1, y = 2
                if (self.cur.kind == .comma) {
                    self.advance();
                    continue;
                }
                break;
            }
        }

        // Optional WITH projection forwarding (works for both MATCH and CREATE)
        // CANARY: REQ=REQ-GQL-CHAIN; FEATURE="Query Chaining via WITH"; ASPECT=Parser; STATUS=TESTED; TEST=graph_algorithms; OWNER=parser; UPDATED=2025-10-10
        var next_query_ptr: ?*ast.Query = null;
        if (self.cur.kind == .WITH) {
            self.advance();
            // Support WITH DISTINCT for post-MATCH WITH clause
            const post_match_with_distinct = if (self.cur.kind == .DISTINCT) blk: {
                self.advance();
                break :blk true;
            } else false;
            var witems = std.ArrayList(ast.ReturnItem).empty;
            try self.parseProjectionItems(&witems);

            // Parse optional ORDER BY, LIMIT, OFFSET after WITH items
            var with_order_by: ?*ast.OrderBy = null;
            var with_limit: ?u64 = null;
            var with_offset: ?u64 = null;
            var with_limit_param: ?[]const u8 = null;
            var with_offset_param: ?[]const u8 = null;

            if (self.cur.kind == .ORDER) {
                self.advance();
                _ = try self.expect(.BY);
                var keys = std.ArrayList(ast.OrderBy.OrderKey).empty;
                while (true) {
                    const key_expr = try self.parseOrExpr();
                    const mods = try self.parseOrderKeyModifiers();
                    try keys.append(self.arena.allocator(), .{ .expr = key_expr, .desc = mods.desc, .nulls = mods.nulls });
                    if (self.cur.kind != .comma) break;
                    self.advance();
                }
                const order_by_ptr = try self.arena.allocator().create(ast.OrderBy);
                order_by_ptr.* = .{ .keys = try keys.toOwnedSlice(self.arena.allocator()) };
                with_order_by = order_by_ptr;
            }

            if (self.cur.kind == .LIMIT) {
                self.advance();
                const lim = try self.parseLimitValue();
                with_limit = lim.value;
                with_limit_param = lim.param;
            }

            if (self.cur.kind == .OFFSET or self.cur.kind == .SKIP) {
                self.advance();
                const off = try self.parseLimitValue();
                with_offset = off.value;
                with_offset_param = off.param;
            }

            with_clause = .{
                .items = try witems.toOwnedSlice(self.arena.allocator()),
                .distinct = post_match_with_distinct,
                .order_by = with_order_by,
                .limit = with_limit,
                .offset = with_offset,
                .limit_param = with_limit_param,
                .offset_param = with_offset_param,
            };
            // Allow an additional WHERE after WITH to filter the projected bindings
            if (self.cur.kind == .WHERE) {
                self.advance();
                const cond2 = try self.parseOrExpr();
                if (where_expr) |cond1| {
                    where_expr = try self.makeBinary(.And, cond1, cond2);
                } else {
                    where_expr = cond2;
                }
            }

            // CANARY: REQ=REQ-GQL-WITH-CHAIN-001; FEATURE="ChainedWithClauses"; ASPECT=ParserSupport; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=parser; UPDATED=2025-12-24
            // Check for query chaining: WITH ... WITH/MATCH/CREATE/FOR ...
            // If we see WITH, MATCH, CREATE, or FOR after WITH, parse it as a chained query or statement
            if (self.cur.kind == .WITH or self.cur.kind == .MATCH or self.cur.kind == .CREATE or self.cur.kind == .FOR or self.cur.kind == .MERGE) {
                if (self.cur.kind == .FOR) {
                    // FOR needs special handling as it's a statement, not a query
                    // Parse the FOR statement and store it in the query
                    const for_stmt = try self.parseForStatement();
                    // Allocate ForStatement on arena
                    const for_ptr = try self.arena.allocator().create(ast.ForStatement);
                    for_ptr.* = for_stmt.For;
                    // Create a query wrapper for the FOR statement
                    const next_query = ast.Query{
                        .optional_match = false,
                        .match = .{ .chains = &.{} }, // Empty match pattern
                        .create_pattern = null,
                        .where_clause = null,
                        .with_clause = null,
                        .set_clauses = &.{},
                        .remove_clauses = &.{},
                        .ret = for_stmt.For.return_clause,
                        .order_by = for_stmt.For.order_by,
                        .offset = for_stmt.For.offset,
                        .limit = for_stmt.For.limit,
                        .next_query = null,
                        .group_by = null,
                        .having = null,
                        .for_statement = for_ptr,
                    };
                    // Allocate on arena and store pointer
                    const next_ptr = try self.arena.allocator().create(ast.Query);
                    next_ptr.* = next_query;
                    next_query_ptr = next_ptr;
                } else if (self.cur.kind == .MERGE) {
                    // GAP #57: MERGE needs special handling as it's a statement, not a query.
                    // Parse the MERGE and wrap it in a query for chaining.
                    const merge_stmt = try self.parseMergeStatement();
                    const merge_ptr = try self.arena.allocator().create(ast.MergeStatement);
                    merge_ptr.* = merge_stmt.Merge;
                    const next_query = ast.Query{
                        .optional_match = false,
                        .match = .{ .chains = &.{} },
                        .create_pattern = null,
                        .where_clause = null,
                        .with_clause = null,
                        .set_clauses = &.{},
                        .remove_clauses = &.{},
                        .ret = merge_stmt.Merge.return_clause orelse .{ .items = &.{}, .distinct = false },
                        .order_by = null,
                        .limit = null,
                        .offset = null,
                        .next_query = null,
                        .group_by = null,
                        .having = null,
                        .merge_statement = merge_ptr,
                    };
                    const next_ptr = try self.arena.allocator().create(ast.Query);
                    next_ptr.* = next_query;
                    next_query_ptr = next_ptr;
                } else {
                    // Parse the continuation as a new query
                    const next_query = try self.parseQuery();
                    // Allocate on arena and store pointer
                    const next_ptr = try self.arena.allocator().create(ast.Query);
                    next_ptr.* = next_query;
                    next_query_ptr = next_ptr;
                }

                // Current query acts as a WITH-only query (no explicit RETURN needed)
                // The WITH clause serves as an implicit RETURN for passing bindings forward
            }
        }
        // GROUP BY (optional)
        if (self.cur.kind == .GROUP) {
            self.advance();
            _ = try self.expect(.BY);
            var keys_list = std.ArrayList(ast.Expr).empty;
            // one or more expressions separated by commas
            while (true) {
                try keys_list.append(self.arena.allocator(), try self.parseOrExpr());
                if (self.cur.kind != .comma) break;
                self.advance();
            }
            group_by = .{ .keys = try keys_list.toOwnedSlice(self.arena.allocator()) };
            // Optional HAVING predicate directly after GROUP BY
            // Also accept WHERE after GROUP BY as post-aggregation filter (common user expectation)
            if (self.cur.kind == .HAVING or self.cur.kind == .WHERE) {
                self.advance();
                having_expr = try self.parseOrExpr();
            }
        }

        // Parse SET clauses if present (before RETURN)
        var set_clauses: []ast.SetClause = &.{};
        if (self.cur.kind == .SET) {
            self.advance();
            set_clauses = try self.parseSetClauses();
        }

        // Parse REMOVE clauses if present (before RETURN)
        var remove_clauses: []ast.RemoveClause = &.{};
        if (self.cur.kind == .REMOVE) {
            self.advance();
            remove_clauses = try self.parseRemoveClauses();
        }

        // Parse DELETE clause if present (for CREATE ... WITH ... DELETE ... pattern)
        // CANARY: REQ=REQ-GQL-DELETE; FEATURE="DELETE in Query"; ASPECT=Parser; STATUS=TESTED; TEST=no-id-collision-on-delete-create; OWNER=parser; UPDATED=2025-10-14
        var delete_items: []ast.DeleteItem = &.{};
        if (self.cur.kind == .DELETE) {
            self.advance();
            delete_items = try self.parseDeleteItems();

            // After DELETE, we can have another CREATE pattern
            // This allows queries like: CREATE (n) WITH ... DELETE n CREATE (m) RETURN ...
            if (self.cur.kind == .CREATE) {
                self.advance();
                create_pattern = try self.parseGraphPattern();
            }
        }

        // Parse CALL clause if present (for MATCH ... CALL ... YIELD pattern)
        var call_clause: ?ast.CallClause = null;
        if (self.cur.kind == .CALL) {
            self.advance();
            // Parse procedure call expression (e.g., algo.bfs.stream(start, {maxDepth: 3}))
            const procedure = try self.parseOrExpr();

            // YIELD clause is required for MATCH+CALL pattern
            var yield_items: ?[]ast.ReturnItem = null;
            if (self.cur.kind == .YIELD) {
                self.advance();
                var items = std.ArrayList(ast.ReturnItem).empty;
                try self.parseProjectionItems(&items);
                yield_items = try items.toOwnedSlice(self.arena.allocator());
            }

            call_clause = .{
                .procedure = procedure,
                .yield_items = yield_items,
            };
        }

        // RETURN item (, item)* (now after SET/REMOVE/CALL, optional if SET/REMOVE present or query chaining)
        var return_clause: ast.ReturnClause = undefined;
        if (self.cur.kind == .RETURN) {
            self.advance();
            const distinct = if (self.cur.kind == .DISTINCT) blk: {
                self.advance();
                break :blk true;
            } else false;
            var items = std.ArrayList(ast.ReturnItem).empty;
            try self.parseProjectionItems(&items);
            return_clause = .{ .items = try items.toOwnedSlice(self.arena.allocator()), .distinct = distinct };

            // Allow WHERE after RETURN items as post-projection filter
            if (self.cur.kind == .WHERE) {
                self.advance();
                having_expr = try self.parseOrExpr();
            }

            // Allow GROUP BY (and optional HAVING) after RETURN as well
            if (self.cur.kind == .GROUP) {
                self.advance();
                _ = try self.expect(.BY);
                var keys_list2 = std.ArrayList(ast.Expr).empty;
                while (true) {
                    try keys_list2.append(self.arena.allocator(), try self.parseOrExpr());
                    if (self.cur.kind != .comma) break;
                    self.advance();
                }
                group_by = .{ .keys = try keys_list2.toOwnedSlice(self.arena.allocator()) };
                // Also accept WHERE after GROUP BY as post-aggregation filter
                if (self.cur.kind == .HAVING or self.cur.kind == .WHERE) {
                    self.advance();
                    having_expr = try self.parseOrExpr();
                }
            }
        } else if (merge_statement != null) {
            // MERGE with optional RETURN from merge_statement
            if (merge_statement.?.return_clause) |rc| {
                return_clause = rc;
            } else {
                return_clause = .{ .items = &.{}, .distinct = false };
            }
        } else if (set_clauses.len > 0 or remove_clauses.len > 0 or delete_items.len > 0 or create_pattern != null) {
            // SET/REMOVE/DELETE/CREATE without RETURN - create empty return clause
            return_clause = .{ .items = &.{}, .distinct = false };
        } else if (next_query_ptr != null and with_clause != null) {
            // Query chaining: WITH followed by MATCH/CREATE
            // Use WITH items as implicit RETURN to pass bindings forward
            return_clause = .{ .items = with_clause.?.items, .distinct = false };
        } else if (select_mode and initial_with_clause != null) {
            // SELECT was parsed and stored in initial_with_clause
            // Use SELECT items as implicit RETURN
            return_clause = .{ .items = initial_with_clause.?.items, .distinct = false };
        } else if (!have_match and !have_create) {
            // No pattern - check if we have RETURN
            if (self.cur.kind != .RETURN) {
                _ = try self.expect(.RETURN);
                unreachable;
            }
            // RETURN-only query without pattern is allowed
        } else {
            // No SET/REMOVE/CREATE, no chaining, and no RETURN - error
            _ = try self.expect(.RETURN);
            unreachable;
        }

        var ord: ?ast.OrderBy = null;
        if (self.cur.kind == .ORDER) {
            self.advance();
            _ = try self.expect(.BY);
            var keys = std.ArrayList(ast.OrderBy.OrderKey).empty;
            // first expression key - allow expressions now
            const expr1 = try self.parseOrExpr();
            // Parse-time enforcement: forbid function calls inside ORDER BY keys when policy active.
            // We examine the AST recursively; if any call node appears, raise an IllegalOrderKey style error.
            if (self.forbid_orderby_calls and self.containsCall(expr1)) {
                // Message string matched in diagnostics mapping path (server expects substring)
                self.last_error = "function calls in ORDER BY are disabled"; // triggers IllegalOrderKey diagnostic
                return error.UnexpectedToken;
            }
            // Check if it's an ordinal
            if (expr1 == .Int and self.isValidOrdinal(expr1.Int, return_clause.items.len)) {
                self.has_ordinal_sort_key = true;
            }
            const mods1 = try self.parseOrderKeyModifiers();
            try keys.append(self.arena.allocator(), .{ .expr = expr1, .desc = mods1.desc, .nulls = mods1.nulls });
            while (self.cur.kind == .comma) {
                self.advance();
                const exprk = try self.parseOrExpr();
                if (self.forbid_orderby_calls and self.containsCall(exprk)) {
                    self.last_error = "function calls in ORDER BY are disabled";
                    return error.UnexpectedToken;
                }
                // Check if it's an ordinal
                if (exprk == .Int and self.isValidOrdinal(exprk.Int, return_clause.items.len)) {
                    self.has_ordinal_sort_key = true;
                }
                const modsk = try self.parseOrderKeyModifiers();
                try keys.append(self.arena.allocator(), .{ .expr = exprk, .desc = modsk.desc, .nulls = modsk.nulls });
            }
            ord = .{ .keys = try keys.toOwnedSlice(self.arena.allocator()) };
        }

        var limit: ?usize = null;
        var offset: ?usize = null;
        var limit_param: ?[]const u8 = null;
        var offset_param: ?[]const u8 = null;

        // Additional legality enforcement: when ident_order_only policy active, reject any ORDER BY key that is not a bare identifier.
        if (ord) |ob| {
            if (self.ident_order_only) {
                var i_chk: usize = 0;
                while (i_chk < ob.keys.len) : (i_chk += 1) {
                    const ke = ob.keys[i_chk].expr;
                    if (ke != .Ident) {
                        if (self.containsCall(ke)) {
                            self.last_error = "function calls in ORDER BY are disabled";
                        } else {
                            self.last_error = "ORDER BY key must be identifier";
                        }
                        return error.UnexpectedToken;
                    }
                }
            }
        }

        // Parse LIMIT and OFFSET in any order
        // First check for LIMIT
        if (self.cur.kind == .LIMIT) {
            self.advance();
            const lim = try self.parseLimitValue();
            limit = if (lim.value) |v| @as(usize, @intCast(v)) else null;
            limit_param = lim.param;
        }
        // Check for OFFSET/SKIP
        if (self.cur.kind == .OFFSET or self.cur.kind == .SKIP) {
            self.advance();
            const off = try self.parseLimitValue();
            offset = if (off.value) |v| @as(usize, @intCast(v)) else null;
            offset_param = off.param;
        }
        // Check for LIMIT again (in case it comes after OFFSET)
        if (limit == null and limit_param == null and self.cur.kind == .LIMIT) {
            self.advance();
            const lim = try self.parseLimitValue();
            limit = if (lim.value) |v| @as(usize, @intCast(v)) else null;
            limit_param = lim.param;
        }

        // Keep let_bindings and inline_let_bindings separate for proper evaluation timing
        // Parameter bindings (before MATCH) are evaluated once upfront
        // Inline bindings (after MATCH) are evaluated per result row with matched variables in scope

        return .{
            .let_bindings = try let_bindings.toOwnedSlice(self.arena.allocator()),
            .inline_let_bindings = try inline_let_bindings.toOwnedSlice(self.arena.allocator()),
            .optional_match = optional_match,
            .match = pat,
            .create_pattern = create_pattern,
            .where_clause = where_expr,
            .filter_clause = filter_expr,
            .with_clause = if (with_clause) |wc| wc else initial_with_clause,
            .is_initial_with = with_clause == null and initial_with_clause != null,
            .set_clauses = set_clauses,
            .remove_clauses = remove_clauses,
            .delete_items = delete_items,
            .group_by = group_by,
            .having = having_expr,
            .ret = return_clause,
            .order_by = ord,
            .limit = limit,
            .offset = offset,
            .limit_param = limit_param,
            .offset_param = offset_param,
            .path_variable = path_variable,
            .call_clause = call_clause,
            .next_query = next_query_ptr, // Query chaining support
            .initial_call_subquery = initial_call_subquery,
            .unwind_clause = unwind_clause,
            .merge_statement = merge_statement,
        };
    }
    fn isValidOrdinal(self: *Parser, n: i64, items_len: usize) bool {
        _ = self;
        if (n <= 0) return false;
        const idx: usize = @intCast(n);
        return idx >= 1 and idx <= items_len;
    }

    fn isPathAlias(self: *Parser, e: ast.Expr) bool {
        // True only if expr is an identifier that matches a collected chain alias.
        if (e != .Ident) return false;
        const name = e.Ident;
        for (self.path_aliases.items) |ali| {
            if (std.mem.eql(u8, ali, name)) return true;
        }
        return false;
    }

    fn isProjectedIdent(self: *Parser, name: []const u8, items: []ast.ReturnItem) bool {
        _ = self; // unused
        // An ORDER BY identifier is legal if it's one of the RETURN aliases or simple identifiers
        var i: usize = 0;
        while (i < items.len) : (i += 1) {
            const it = items[i];
            if (it.alias) |al| {
                if (std.mem.eql(u8, al, name)) return true;
            } else if (it.expr == .Ident) {
                if (std.mem.eql(u8, it.expr.Ident, name)) return true;
            }
        }
        return false;
    }

    fn parseGraphPattern(self: *Parser) ParserError!ast.GraphPattern {
        self.recur_depth += 1;
        defer self.recur_depth -= 1;
        if (self.recur_depth > MAX_RECUR_DEPTH) return error.UnexpectedToken;
        var chains = std.ArrayList(ast.Chain).empty;

        // CANARY: REQ=REQ-GQL-PATH-MODES-003; FEATURE="GQL Path Mode Parsing"; ASPECT=Parser; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=parser; UPDATED=2026-01-08
        // Check for path mode specifier (WALK, TRAIL, ACYCLIC, SIMPLE) before the pattern
        var path_mode: ast.PathMode = .walk;
        if (self.cur.kind == .WALK) {
            self.advance();
            path_mode = .walk;
        } else if (self.cur.kind == .TRAIL) {
            self.advance();
            path_mode = .trail;
        } else if (self.cur.kind == .ACYCLIC) {
            self.advance();
            path_mode = .acyclic;
        } else if (self.cur.kind == .SIMPLE) {
            self.advance();
            path_mode = .simple;
        }

        while (true) {
            // parse a chain with one-or-more hops
            var hops = std.ArrayList(ast.Hop).empty;
            // Optional path alias: ident '=' before a node pattern or shortestPath function
            // CANARY: REQ=REQ-GQL-091; FEATURE="PathAssignmentAfterWITH"; ASPECT=Parser; STATUS=TESTED; TEST=subgraph-isomorphism; OWNER=parser; UPDATED=2025-10-14
            var chain_name: ?[]const u8 = null;
            if ((self.cur.kind == .identifier or self.cur.kind == .PATH or self.isKeyword(self.cur.kind)) and self.peekKind() == .eq) {
                chain_name = self.cur.lexeme;
                self.advance(); // ident, PATH, or keyword
                _ = try self.expect(.eq);

                // Check if this is a shortestPath or allShortestPaths function call
                if (self.cur.kind == .identifier) {
                    const func_name = self.cur.lexeme;
                    if (std.ascii.eqlIgnoreCase(func_name, "shortestPath") or std.ascii.eqlIgnoreCase(func_name, "allShortestPaths")) {
                        // This is a path function - create a special chain with shortestPath marker
                        self.advance(); // consume function name
                        _ = try self.expect(.l_paren);
                        const inner_pattern = try self.parseGraphPattern();
                        _ = try self.expect(.r_paren);

                        // Store the shortestPath pattern as a special chain
                        // The execution engine will handle this specially
                        const is_all = std.ascii.eqlIgnoreCase(func_name, "allShortestPaths");
                        _ = is_all; // Will use this in execution

                        // For now, just return the inner pattern with the path name
                        // Mark as shortestPath so execution can distinguish from regular path assignments
                        for (inner_pattern.chains) |chain| {
                            var modified_chain = chain;
                            modified_chain.name = chain_name;
                            modified_chain.is_shortest = true;
                            modified_chain.path_mode = path_mode;
                            try chains.append(self.arena.allocator(), modified_chain);
                        }

                        // comma-separated chains
                        if (self.cur.kind != .comma) break;
                        self.advance();
                        continue;
                    }
                }
            }
            var left = try self.parseNodePattern();
            while (true) {
                // expect a connector for a hop: '-', '<-', or '->'
                var dir: ast.RelDir = .undirected;
                if (self.cur.kind == .minus) {
                    // Check for bracketless undirected relationship (--)
                    if (self.peekKind() == .minus) {
                        self.advance(); // first -
                        self.advance(); // second -
                        const rel = ast.RelPattern{
                            .name = null,
                            .types = &.{},
                            .props = null,
                            .dir = .undirected,
                            .min_len = null,
                            .max_len = null,
                        };
                        const right = try self.parseNodePattern();
                        try hops.append(self.arena.allocator(), .{ .left = left, .rel = rel, .right = right });
                        left = right;
                        continue;
                    }
                    self.advance();
                } else if (self.cur.kind == .arrow_l) {
                    self.advance();
                    // Check for bracketless left-directed relationship (<-() without bracket)
                    if (self.cur.kind == .l_paren) {
                        dir = .left;
                        const rel = ast.RelPattern{
                            .name = null,
                            .types = &.{},
                            .props = null,
                            .dir = .left,
                            .min_len = null,
                            .max_len = null,
                        };
                        const right = try self.parseNodePattern();
                        try hops.append(self.arena.allocator(), .{ .left = left, .rel = rel, .right = right });
                        left = right;
                        continue;
                    }
                    dir = .left;
                } else if (self.cur.kind == .arrow_r) {
                    self.advance();
                    // Check for bracketless right-directed relationship (->() without bracket)
                    if (self.cur.kind == .l_paren) {
                        dir = .right;
                        const rel = ast.RelPattern{
                            .name = null,
                            .types = &.{},
                            .props = null,
                            .dir = .right,
                            .min_len = null,
                            .max_len = null,
                        };
                        const right = try self.parseNodePattern();
                        try hops.append(self.arena.allocator(), .{ .left = left, .rel = rel, .right = right });
                        left = right;
                        continue;
                    }
                    dir = .right;
                } else {
                    break;
                }
                // Parse the relationship pattern first, then determine final direction from trailing connector
                var rel = try self.parseRelPattern(dir);
                // trailing connector to right node: -, ->, or <-
                // CRITICAL FIX: For patterns like -[*]-> or -[:R*1]->, the direction should come from
                // the TRAILING connector (->), not the leading one (-). Update the direction here.
                if (self.cur.kind == .arrow_r) {
                    rel.dir = .right;
                    self.advance();
                } else if (self.cur.kind == .arrow_l) {
                    rel.dir = .left;
                    self.advance();
                } else if (self.cur.kind == .minus) {
                    // Trailing - means undirected (already the default)
                    self.advance();
                }
                const right = try self.parseNodePattern();
                try hops.append(self.arena.allocator(), .{ .left = left, .rel = rel, .right = right });
                left = right; // chain continues from the right node
            }
            if (self.collect_chain_aliases) {
                if (chain_name) |an| {
                    // record alias name for ORDER BY checks later
                    try self.path_aliases.append(self.arena.allocator(), an);
                }
            }
            // If no hops were parsed, this chain is a single node pattern. Record it in head.
            const owned_hops = try hops.toOwnedSlice(self.arena.allocator());
            var head: ?ast.NodePattern = null;
            if (owned_hops.len == 0) {
                head = left;
            }
            try chains.append(self.arena.allocator(), .{ .name = chain_name, .hops = owned_hops, .head = head, .path_mode = path_mode });
            // comma-separated chains
            if (self.cur.kind != .comma) break;
            self.advance();
        }
        return .{ .chains = try chains.toOwnedSlice(self.arena.allocator()) };
    }

    fn parseNodePattern(self: *Parser) ParserError!ast.NodePattern {
        _ = try self.expect(.l_paren);
        var name: ?[]const u8 = null;
        // Accept keywords as variable names (e.g., MATCH (create:Person))
        if (self.cur.kind == .identifier or self.isKeyword(self.cur.kind)) {
            name = self.cur.lexeme;
            self.advance();
        }
        var labels = std.ArrayList([]const u8).empty;
        while (self.cur.kind == .colon) {
            self.advance();
            // Accept keywords as label names (e.g., :Property, :Type)
            const l = try self.expectIdentifierOrKeyword();
            try labels.append(self.arena.allocator(), l.lexeme);
        }
        var props: ?[]ast.Property = null;
        if (self.cur.kind == .l_brace) {
            props = try self.parsePropertyMap();
        }
        _ = try self.expect(.r_paren);
        return .{ .name = name, .labels = try labels.toOwnedSlice(self.arena.allocator()), .props = props };
    }

    fn parseRelPattern(self: *Parser, dir: ast.RelDir) ParserError!ast.RelPattern {
        _ = try self.expect(.l_bracket);
        var name: ?[]const u8 = null;
        // Accept keywords as variable names (e.g., MATCH ()-[property:KNOWS]->())
        if (self.cur.kind == .identifier or self.isKeyword(self.cur.kind)) {
            name = self.cur.lexeme;
            self.advance();
        }
        var types = std.ArrayList([]const u8).empty;
        while (self.cur.kind == .colon) {
            self.advance();
            // Accept keywords as relationship type names
            const tkn = try self.expectIdentifierOrKeyword();
            try types.append(self.arena.allocator(), tkn.lexeme);
            while (self.cur.kind == .bar) {
                // If inside pattern comprehension, only consume | if it's followed by a type identifier
                if (self.pattern_comp_depth > 0) {
                    const next = self.peekToken();
                    if (next != .identifier and !self.isKeyword(next)) break;
                }
                self.advance();
                // Accept keywords as alternative relationship type names
                const alt = try self.expectIdentifierOrKeyword();
                try types.append(self.arena.allocator(), alt.lexeme);
            }
        }
        // optional variable-length quantifier: *[min][..[max]]
        var min_len: ?u32 = null;
        var max_len: ?u32 = null;
        if (self.cur.kind == .star) {
            self.advance();
            if (self.cur.kind == .integer_lit) {
                const min_tok = self.cur;
                self.advance();
                min_len = @as(u32, @intCast(try std.fmt.parseInt(u32, min_tok.lexeme, 10)));
                max_len = min_len;
            }
            if (self.cur.kind == .dotdot) {
                self.advance();
                // may have max
                if (self.cur.kind == .integer_lit) {
                    const max_tok = self.cur;
                    self.advance();
                    max_len = @as(u32, @intCast(try std.fmt.parseInt(u32, max_tok.lexeme, 10)));
                } else {
                    // open upper bound
                    max_len = null;
                }
                // if min was integer before dotdot, keep it; else min defaults 0
                if (min_len == null) min_len = 0;
            }
            if (min_len == null and max_len == null) {
                // plain * => 0..∞
                min_len = 0;
                max_len = null;
            }
            if (min_len != null and max_len != null and min_len.? > max_len.?) {
                return self.unexpected("relationship length min>max");
            }
            // Validate that min and max are not 0 (invalid in GQL)
            if (min_len != null and min_len.? == 0 and max_len != null and max_len.? == 0) {
                return self.unexpected("variable-length relationship with length 0 is invalid");
            }
        }
        var props: ?[]ast.Property = null;
        if (self.cur.kind == .l_brace) {
            props = try self.parsePropertyMap();
        }
        _ = try self.expect(.r_bracket);
        return .{ .name = name, .types = try types.toOwnedSlice(self.arena.allocator()), .props = props, .dir = dir, .min_len = min_len, .max_len = max_len };
    }

    fn parsePropertyMap(self: *Parser) ParserError![]ast.Property {
        _ = try self.expect(.l_brace);
        var list = std.ArrayList(ast.Property).empty;
        if (self.cur.kind != .r_brace) {
            while (true) {
                // Accept identifier, string_lit, or any keyword as property keys
                // This allows {name: 'value'}, {'name': 'value'}, and {value: 1} syntax
                // Keywords like VALUE, RETURN, etc. are valid property names
                const key = if (self.cur.kind == .string_lit)
                    try self.expect(.string_lit)
                else if (self.cur.kind == .identifier or self.isKeyword(self.cur.kind)) blk: {
                    const token = self.cur;
                    self.advance();
                    break :blk token;
                } else return self.unexpected("property key");
                _ = try self.expect(.colon);
                const expr = try self.parseOrExpr();
                const a = self.arena.allocator();
                const ep = try a.create(ast.Expr);
                ep.* = expr;
                const prop = ast.Property{ .key = key.lexeme, .value = ep };
                try list.append(self.arena.allocator(), prop);
                if (self.cur.kind != .comma) break;
                self.advance();
            }
        }
        _ = try self.expect(.r_brace);
        return try list.toOwnedSlice(self.arena.allocator());
    }

    fn parseProjectionItems(self: *Parser, out: *std.ArrayList(ast.ReturnItem)) ParserError!void {
        // Handle RETURN NO BINDINGS to return 0 rows
        if (self.cur.kind == .NO) {
            self.advance();
            if (self.cur.kind == .BINDINGS) {
                self.advance();
                // Return empty list of items - this signals no rows should be returned
                return;
            } else {
                return error.UnexpectedToken;
            }
        }

        // Handle RETURN * to return all bound variables
        if (self.cur.kind == .star) {
            self.advance();
            // Create a special marker using Ident with "*" to signal executor to return all bindings
            const star_expr = ast.Expr{ .Ident = .{ .orig = "*", .cnf = "*" } };
            try out.append(self.arena.allocator(), .{ .expr = star_expr, .alias = null });
            return;
        }

        while (true) {
            const expr = try self.parseOrExpr();
            var alias: ?[]const u8 = null;
            if (self.cur.kind == .AS) {
                self.advance();
                // Accept either identifier/keyword or quoted string literal for alias
                const a = if (self.cur.kind == .string_lit) blk: {
                    const token = self.cur;
                    self.advance();
                    break :blk token;
                } else try self.expectIdentifierOrKeyword();
                alias = a.lexeme;
            }
            try out.append(self.arena.allocator(), .{ .expr = expr, .alias = alias });
            if (self.cur.kind != .comma) break;
            self.advance();
        }
    }

    fn parseOrExpr(self: *Parser) ParserError!ast.Expr {
        self.expr_depth += 1;
        defer self.expr_depth -= 1;
        if (self.expr_depth > MAX_EXPR_DEPTH) return error.UnexpectedToken;
        var left = try self.parseAndExpr();
        while (self.cur.kind == .OR or self.cur.kind == .XOR) {
            const op_kind = self.cur.kind;
            self.advance();
            const right = try self.parseAndExpr();
            const node = try self.makeBinary(if (op_kind == .OR) .Or else .Xor, left, right);
            left = node;
        }
        return left;
    }

    fn parseAndExpr(self: *Parser) ParserError!ast.Expr {
        var left = try self.parseNotExpr();
        while (self.cur.kind == .AND) {
            self.advance();
            const right = try self.parseNotExpr();
            const node = try self.makeBinary(.And, left, right);
            left = node;
        }
        return left;
    }

    fn parseNotExpr(self: *Parser) ParserError!ast.Expr {
        self.expr_depth += 1;
        defer self.expr_depth -= 1;
        if (self.expr_depth > MAX_EXPR_DEPTH) return error.UnexpectedToken;

        if (self.cur.kind == .NOT) {
            // Check if this is NOT IN (handled in parseCmpExpr)
            if (self.peekToken() == .IN) {
                // Let parseCmpExpr handle NOT IN
                return self.parseCmpExpr();
            }

            // Check if this is NOT followed by a graph pattern - e.g., NOT (n)--()
            // Patterns start with (identifier or colon or closing paren for anonymous nodes
            if (self.peekToken() == .l_paren) {
                // Look ahead two tokens to see if this looks like a node pattern start
                const saved_lx = self.lx.*;
                const saved_cur = self.cur;

                self.advance(); // consume NOT
                self.advance(); // consume (

                // CANARY: REQ=REQ-GQL-NOT-PAREN-EXPR-001; FEATURE="NotParenExpr"; ASPECT=ParserFix; STATUS=TESTED; TEST=geodetestlab/specs/gql_expressions_comprehensive.yml; OWNER=parser; UPDATED=2025-12-28
                // B10 Fix: Distinguish between NOT (n:Label...) graph pattern and NOT (n.value > 0) expression
                // If we see an identifier followed by a dot, it's a property access expression, not a node pattern
                // Node pattern indicators after identifier: :, ), {, -, <, [
                // Expression indicators after identifier: . (property access)
                const looks_like_pattern = if (self.cur.kind == .identifier)
                    // Identifier followed by . is property access (expression), not node pattern
                    self.peekToken() != .dot
                else
                    // :Label or () patterns
                    (self.cur.kind == .colon or self.cur.kind == .r_paren);

                // Restore position
                self.lx.* = saved_lx;
                self.cur = saved_cur;

                if (looks_like_pattern) {
                    // Parse as NOT followed by a graph pattern
                    self.advance(); // consume NOT
                    const pattern = try self.parseGraphPattern();

                    // Create EXISTS predicate
                    const a = self.arena.allocator();
                    const pattern_ptr = try a.create(ast.GraphPattern);
                    pattern_ptr.* = pattern;
                    const exists_expr = ast.Expr{ .Exists = .{ .pattern = pattern_ptr } };

                    // Wrap in NOT
                    const ep = try a.create(ast.Expr);
                    ep.* = exists_expr;
                    return .{ .Unary = .{ .op = .Not, .expr = ep } };
                }
            }

            self.advance();
            const e = try self.parseNotExpr();
            const a = self.arena.allocator();
            const ep = try a.create(ast.Expr);
            ep.* = e;
            return .{ .Unary = .{ .op = .Not, .expr = ep } };
        }
        return self.parseCmpExpr();
    }

    fn parseCmpExpr(self: *Parser) ParserError!ast.Expr {
        const left = try self.parseAddExpr();
        // string predicates and regex have higher precedence than boolean but sit with comparisons
        if (self.cur.kind == .STARTS) {
            self.advance();
            _ = try self.expect(.WITH);
            const rhs = try self.parseAddExpr();
            const a = self.arena.allocator();
            const lp = try a.create(ast.Expr);
            const rp = try a.create(ast.Expr);
            lp.* = left;
            rp.* = rhs;
            return .{ .StartsWith = .{ .value = lp, .prefix = rp } };
        }
        if (self.cur.kind == .ENDS) {
            self.advance();
            _ = try self.expect(.WITH);
            const rhs = try self.parseAddExpr();
            const a = self.arena.allocator();
            const lp = try a.create(ast.Expr);
            const rp = try a.create(ast.Expr);
            lp.* = left;
            rp.* = rhs;
            return .{ .EndsWith = .{ .value = lp, .suffix = rp } };
        }
        if (self.cur.kind == .CONTAINS) {
            self.advance();
            const rhs = try self.parseAddExpr();
            const a = self.arena.allocator();
            const lp = try a.create(ast.Expr);
            const rp = try a.create(ast.Expr);
            lp.* = left;
            rp.* = rhs;
            return .{ .Contains = .{ .value = lp, .needle = rp } };
        }
        // Label test: n:Label (only if left is an identifier)
        if (self.cur.kind == .colon and left == .Ident) {
            self.advance();
            const label_token = try self.expectIdentifierOrKeyword();
            return .{ .HasLabel = .{ .node = left.Ident.orig, .label = label_token.lexeme } };
        }
        const op_kind = switch (self.cur.kind) {
            .eq => ast.BinOp.Eq,
            .ne => ast.BinOp.Ne,
            .lt => ast.BinOp.Lt,
            .le => ast.BinOp.Le,
            .gt => ast.BinOp.Gt,
            .ge => ast.BinOp.Ge,
            .regex_match => ast.BinOp.RegexMatch,
            .regex_not_match => ast.BinOp.RegexNotMatch,
            else => {
                if (self.cur.kind == .IN) {
                    self.advance();

                    // CANARY: REQ=REQ-GQL-IN-EXPR-001; FEATURE="InOperator"; ASPECT=ParserSupport; STATUS=TESTED; TEST=geodetestlab/specs/gql_expressions_comprehensive.yml; OWNER=parser; UPDATED=2025-12-27
                    // Check if this is IN (subquery), IN [list], or IN <expression>
                    if (self.cur.kind == .l_paren) {
                        // IN (subquery) - parse as subquery
                        self.advance(); // consume (
                        const subquery = try self.parseQuery();
                        _ = try self.expect(.r_paren);

                        const a = self.arena.allocator();
                        const vp = try a.create(ast.Expr);
                        vp.* = left;
                        const qp = try a.create(ast.Query);
                        qp.* = subquery;
                        return .{ .InSubquery = .{ .value = vp, .subquery = qp } };
                    } else if (self.cur.kind == .l_bracket) {
                        // IN [list] - parse as list
                        self.advance(); // consume [
                        var elems = std.ArrayList(*ast.Expr).empty;
                        if (self.cur.kind != .r_bracket) {
                            while (true) {
                                const it = try self.parseOrExpr();
                                const ap = try self.arena.allocator().create(ast.Expr);
                                ap.* = it;
                                try elems.append(self.arena.allocator(), ap);
                                if (self.cur.kind != .comma) break;
                                self.advance();
                            }
                        }
                        _ = try self.expect(.r_bracket);
                        const a = self.arena.allocator();
                        const vp = try a.create(ast.Expr);
                        vp.* = left;
                        return .{ .In = .{ .value = vp, .set = try elems.toOwnedSlice(self.arena.allocator()) } };
                    } else {
                        // CANARY: REQ=REQ-GQL-IN-LISTEXPR-001; FEATURE="InListExpr"; ASPECT=FunctionCall; STATUS=TESTED; TEST=geodetestlab/specs/gql_expressions_comprehensive.yml; OWNER=parser; UPDATED=2025-12-27
                        // IN <expression> - expression that evaluates to a list (e.g., labels(n))
                        // Use parsePostfixExpr to handle function calls like labels(n), not just identifiers
                        const list_expr = try self.parsePostfixExpr();
                        const a = self.arena.allocator();
                        const vp = try a.create(ast.Expr);
                        vp.* = left;
                        const lep = try a.create(ast.Expr);
                        lep.* = list_expr;
                        return .{ .InListExpr = .{ .value = vp, .list_expr = lep } };
                    }
                }
                if (self.cur.kind == .NOT) {
                    // NOT IN
                    self.advance();
                    _ = try self.expect(.IN);

                    // CANARY: REQ=REQ-GQL-IN-EXPR-002; FEATURE="NotInOperator"; ASPECT=ParserSupport; STATUS=TESTED; TEST=geodetestlab/specs/gql_expressions_comprehensive.yml; OWNER=parser; UPDATED=2025-12-27
                    // Check if this is NOT IN (subquery), NOT IN [list], or NOT IN <expression>
                    if (self.cur.kind == .l_paren) {
                        // NOT IN (subquery)
                        self.advance(); // consume (
                        const subquery = try self.parseQuery();
                        _ = try self.expect(.r_paren);

                        const a = self.arena.allocator();
                        const vp = try a.create(ast.Expr);
                        vp.* = left;
                        const qp = try a.create(ast.Query);
                        qp.* = subquery;
                        return .{ .NotInSubquery = .{ .value = vp, .subquery = qp } };
                    } else if (self.cur.kind == .l_bracket) {
                        // NOT IN [list]
                        self.advance(); // consume [
                        var elems = std.ArrayList(*ast.Expr).empty;
                        if (self.cur.kind != .r_bracket) {
                            while (true) {
                                const it = try self.parseOrExpr();
                                const ap = try self.arena.allocator().create(ast.Expr);
                                ap.* = it;
                                try elems.append(self.arena.allocator(), ap);
                                if (self.cur.kind != .comma) break;
                                self.advance();
                            }
                        }
                        _ = try self.expect(.r_bracket);
                        const a = self.arena.allocator();
                        const vp = try a.create(ast.Expr);
                        vp.* = left;
                        return .{ .NotIn = .{ .value = vp, .set = try elems.toOwnedSlice(self.arena.allocator()) } };
                    } else {
                        // CANARY: REQ=REQ-GQL-IN-LISTEXPR-002; FEATURE="NotInListExpr"; ASPECT=FunctionCall; STATUS=TESTED; TEST=geodetestlab/specs/gql_expressions_comprehensive.yml; OWNER=parser; UPDATED=2025-12-27
                        // NOT IN <expression> - expression that evaluates to a list (e.g., labels(n))
                        // Use parsePostfixExpr to handle function calls like labels(n), not just identifiers
                        const list_expr = try self.parsePostfixExpr();
                        const a = self.arena.allocator();
                        const vp = try a.create(ast.Expr);
                        vp.* = left;
                        const lep = try a.create(ast.Expr);
                        lep.* = list_expr;
                        return .{ .NotInListExpr = .{ .value = vp, .list_expr = lep } };
                    }
                }
                if (self.cur.kind == .IS) {
                    self.advance();
                    var neg = false;
                    if (self.cur.kind == .NOT) {
                        neg = true;
                        self.advance();
                    }
                    if (self.cur.kind == .NULL) {
                        self.advance();
                        const a = self.arena.allocator();
                        const tp = try a.create(ast.Expr);
                        tp.* = left;
                        return .{ .IsNull = .{ .target = tp, .negated = neg } };
                    } else if (self.cur.kind == .UNKNOWN) {
                        self.advance();
                        const a = self.arena.allocator();
                        const tp = try a.create(ast.Expr);
                        tp.* = left;
                        return .{ .IsUnknown = .{ .target = tp, .negated = neg } };
                    } else {
                        return self.unexpected("expected NULL or UNKNOWN after IS");
                    }
                }
                return left;
            },
        };
        self.advance();
        var right = try self.parseAddExpr();

        // CANARY: REQ=REQ-GQL-090; FEATURE="ChainedComparisons"; ASPECT=Parser; STATUS=TESTED; OWNER=parser; UPDATED=2025-10-14
        // Handle chained comparisons: a < b < c becomes (a < b) AND (b < c)
        var result = try self.makeBinary(op_kind, left, right);

        // Check if another comparison operator follows
        while (true) {
            const next_op = switch (self.cur.kind) {
                .eq => ast.BinOp.Eq,
                .ne => ast.BinOp.Ne,
                .lt => ast.BinOp.Lt,
                .le => ast.BinOp.Le,
                .gt => ast.BinOp.Gt,
                .ge => ast.BinOp.Ge,
                else => break,
            };

            self.advance();
            const next_right = try self.parseAddExpr();

            // Create the next comparison: right op next_right
            const next_comp = try self.makeBinary(next_op, right, next_right);

            // Combine with AND: result AND next_comp
            result = try self.makeBinary(.And, result, next_comp);

            // Update right for next iteration
            right = next_right;
        }

        return result;
    }

    fn parseAddExpr(self: *Parser) ParserError!ast.Expr {
        var left = try self.parseMulExpr();
        while (self.cur.kind == .plus or self.cur.kind == .minus or self.cur.kind == .concat) {
            const op = switch (self.cur.kind) {
                .plus => ast.BinOp.Add,
                .minus => ast.BinOp.Sub,
                .concat => ast.BinOp.Concat,
                else => unreachable,
            };
            self.advance();
            const right = try self.parseMulExpr();
            left = try self.makeBinary(op, left, right);
        }
        return left;
    }

    fn parseMulExpr(self: *Parser) ParserError!ast.Expr {
        var left = try self.parsePowerExpr();
        while (self.cur.kind == .star or self.cur.kind == .slash or self.cur.kind == .percent) {
            const op = if (self.cur.kind == .star)
                ast.BinOp.Mul
            else if (self.cur.kind == .slash)
                ast.BinOp.Div
            else
                ast.BinOp.Mod;
            self.advance();
            const right = try self.parsePowerExpr();
            left = try self.makeBinary(op, left, right);
        }
        return left;
    }

    // CANARY: REQ=REQ-GQL-POWER-002; FEATURE="PowerOperator"; ASPECT=ParserSupport; STATUS=TESTED; TEST=geodetestlab/specs/geode_advanced_math_algorithms.yml; OWNER=parser; UPDATED=2025-12-27
    // Power operator has higher precedence than multiplication
    fn parsePowerExpr(self: *Parser) ParserError!ast.Expr {
        var left = try self.parseUnaryExpr();
        while (self.cur.kind == .caret) {
            self.advance();
            // Right-associative: parse right side with same precedence
            const right = try self.parseUnaryExpr();
            left = try self.makeBinary(.Power, left, right);
        }
        return left;
    }

    fn parseUnaryExpr(self: *Parser) ParserError!ast.Expr {
        self.expr_depth += 1;
        defer self.expr_depth -= 1;
        if (self.expr_depth > MAX_EXPR_DEPTH) return error.UnexpectedToken;

        // NOT is now handled in parseNotExpr at correct precedence level
        if (self.cur.kind == .EXISTS and self.peekToken() == .l_brace) {
            // CANARY: REQ=REQ-GQL-EXISTS-001; FEATURE="ExistsSubquery"; ASPECT=ParserSupport; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=parser; UPDATED=2025-12-24
            // CANARY: REQ=REQ-GQL-EXISTS-002; FEATURE="ExistsSubquery"; ASPECT=WhereClause; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=parser; UPDATED=2025-12-27
            // This is EXISTS { ... } - EXISTS predicate
            // Supports: EXISTS { pattern }, EXISTS { MATCH pattern }, EXISTS { MATCH pattern WHERE condition }
            self.advance(); // consume EXISTS
            _ = try self.expect(.l_brace);

            // Check if this is EXISTS { MATCH pattern } or EXISTS { pattern }
            if (self.cur.kind == .MATCH) {
                self.advance(); // consume MATCH
            }

            const pattern = try self.parseGraphPattern();

            // Parse optional WHERE clause inside EXISTS
            var where_clause: ?*ast.Expr = null;
            if (self.cur.kind == .WHERE) {
                self.advance(); // consume WHERE
                const where_expr = try self.parseOrExpr();
                const a = self.arena.allocator();
                const where_ptr = try a.create(ast.Expr);
                where_ptr.* = where_expr;
                where_clause = where_ptr;
            }

            _ = try self.expect(.r_brace);
            const a = self.arena.allocator();
            const pattern_ptr = try a.create(ast.GraphPattern);
            pattern_ptr.* = pattern;
            return .{ .Exists = .{ .pattern = pattern_ptr, .where = where_clause } };
        }
        if (self.cur.kind == .minus) {
            self.advance();
            const e = try self.parseUnaryExpr();
            const a = self.arena.allocator();
            const ep = try a.create(ast.Expr);
            ep.* = e;
            return .{ .Unary = .{ .op = .Neg, .expr = ep } };
        }
        if (self.cur.kind == .plus) {
            self.advance();
            const e = try self.parseUnaryExpr();
            const a = self.arena.allocator();
            const ep = try a.create(ast.Expr);
            ep.* = e;
            return .{ .Unary = .{ .op = .Pos, .expr = ep } };
        }
        return self.parsePostfixExpr();
    }

    fn parsePostfixExpr(self: *Parser) ParserError!ast.Expr {
        var base = try self.parsePrimaryExpr();
        while (true) {
            if (self.cur.kind == .dot) {
                self.advance();
                const field = if (self.cur.kind == .identifier or self.isKeyword(self.cur.kind)) blk: {
                    const token = self.cur;
                    self.advance();
                    break :blk token;
                } else try self.expect(.identifier);
                const a = self.arena.allocator();
                const bp = try a.create(ast.Expr);
                bp.* = base;
                base = .{ .Member = .{ .target = bp, .field = field.lexeme } };
                continue;
            }
            // CANARY: REQ=REQ-GQL-COUNT-001; FEATURE="CountSubquery"; ASPECT=ParserSupport; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=parser; UPDATED=2025-12-28
            // C02 Fix: Check for COUNT { MATCH pattern WHERE expr } subquery syntax
            if (self.cur.kind == .l_brace and base == .Ident and std.ascii.eqlIgnoreCase(base.Ident.orig, "count")) {
                self.advance(); // consume '{'
                // Check if this is COUNT { MATCH pattern } or COUNT { pattern }
                if (self.cur.kind == .MATCH) {
                    self.advance(); // consume MATCH
                }
                const pattern = try self.parseGraphPattern();
                const a = self.arena.allocator();
                const pat_ptr = try a.create(ast.GraphPattern);
                pat_ptr.* = pattern;

                // C02 Fix: Parse optional WHERE clause inside COUNT subquery
                var where_expr: ?*ast.Expr = null;
                if (self.cur.kind == .WHERE) {
                    self.advance(); // consume WHERE
                    const where_e = try self.parseOrExpr();
                    const we_ptr = try a.create(ast.Expr);
                    we_ptr.* = where_e;
                    where_expr = we_ptr;
                }

                _ = try self.expect(.r_brace);
                base = .{ .PatternCount = .{ .pattern = pat_ptr, .where = where_expr } };
                continue;
            }
            if (self.cur.kind == .l_paren) {
                // Check for shortestPath/allShortestPaths or size() with pattern
                if (base == .Ident) {
                    const name = base.Ident.orig;
                    if (std.ascii.eqlIgnoreCase(name, "shortestPath") or std.ascii.eqlIgnoreCase(name, "allShortestPaths")) {
                        const is_all = std.ascii.eqlIgnoreCase(name, "allShortestPaths");
                        self.advance(); // consume '('
                        // CANARY: REQ=REQ-GQL-PATH-NULL-001; FEATURE="ShortestPath"; ASPECT=NullHandling; STATUS=TESTED; TEST=geodetestlab/specs/gap_0087_0089_resolution.yml; OWNER=parser; UPDATED=2026-01-25
                        // Handle NULL input - shortestPath(null) should return NULL
                        if (self.cur.kind == .NULL) {
                            self.advance(); // consume NULL
                            _ = try self.expect(.r_paren);
                            base = .Null;
                            continue;
                        }
                        // Parse graph pattern argument
                        const pattern = try self.parseGraphPattern();
                        _ = try self.expect(.r_paren);
                        const a = self.arena.allocator();
                        const pat_ptr = try a.create(ast.GraphPattern);
                        pat_ptr.* = pattern;
                        base = .{ .ShortestPath = .{ .pattern = pat_ptr, .all = is_all } };
                        continue;
                    }
                    // Check for size() with direct graph pattern: size((n)-[r]->(m))
                    if (std.ascii.eqlIgnoreCase(name, "size")) {
                        // Peek ahead to see if this is size((pattern))
                        if (self.peekToken() == .l_paren) {
                            self.advance(); // consume '('
                            const pattern = try self.parseGraphPattern();
                            _ = try self.expect(.r_paren);
                            const a = self.arena.allocator();
                            const pat_ptr = try a.create(ast.GraphPattern);
                            pat_ptr.* = pattern;
                            base = .{ .PatternCount = .{ .pattern = pat_ptr, .where = null } };
                            continue;
                        }
                        // Otherwise fall through to regular function call handling
                        // This handles size([ pattern | expr ]) and size(expr)
                    }
                }
                // function call: base(args)
                self.advance();

                // CANARY: REQ=REQ-GQL-089; FEATURE="ListComprehension"; ASPECT=Parser; STATUS=TESTED; TEST=geodetestlab/specs/gql_expressions_comprehensive.ymlEMENTED; OWNER=parser; UPDATED=2025-10-14
                // Special handling: all(x IN list WHERE condition) or any(x IN list WHERE condition)
                if (base == .Ident and (std.ascii.eqlIgnoreCase(base.Ident.orig, "all") or std.ascii.eqlIgnoreCase(base.Ident.orig, "any")) and self.cur.kind == .identifier) {
                    // Check if this is a list comprehension: identifier IN ...
                    const saved_idx = self.lx.idx;
                    const saved_line = self.lx.line;
                    const saved_col = self.lx.col;
                    const saved_cur = self.cur;

                    const var_token = self.cur;
                    self.advance(); // Move to token after identifier

                    if (self.cur.kind == .IN) {
                        // This is a list comprehension: all(x IN list WHERE condition)
                        self.advance(); // consume IN

                        const source_expr = try self.parseOrExpr();
                        const a = self.arena.allocator();
                        const sp = try a.create(ast.Expr);
                        sp.* = source_expr;

                        var filter: ?*ast.Expr = null;
                        if (self.cur.kind == .WHERE) {
                            self.advance(); // consume WHERE
                            const filter_expr = try self.parseOrExpr();
                            const fp = try a.create(ast.Expr);
                            fp.* = filter_expr;
                            filter = fp;
                        }

                        _ = try self.expect(.r_paren);

                        // Create ListComprehension node
                        const comp_expr = ast.Expr{ .ListComprehension = .{ .variable = var_token.lexeme, .source = sp, .filter = filter } };

                        // Wrap in Call node with function name as callee
                        const cp = try a.create(ast.Expr);
                        cp.* = base;
                        const comp_ptr = try a.create(ast.Expr);
                        comp_ptr.* = comp_expr;
                        const args_arr = try a.alloc(*ast.Expr, 1);
                        args_arr[0] = comp_ptr;
                        base = .{ .Call = .{ .callee = cp, .args = args_arr } };
                        continue;
                    } else {
                        // Not a list comprehension, restore lexer state and current token
                        self.lx.idx = saved_idx;
                        self.lx.line = saved_line;
                        self.lx.col = saved_col;
                        self.cur = saved_cur;
                    }
                }

                var args = std.ArrayList(*ast.Expr).empty;
                var saw_distinct = false;
                if (self.cur.kind != .r_paren) {
                    // Special handling: COUNT(DISTINCT expr)
                    if (base == .Ident and std.ascii.eqlIgnoreCase(base.Ident.orig, "count") and self.cur.kind == .DISTINCT) {
                        saw_distinct = true;
                        self.advance();
                    }
                    // Special handling: COUNT(*)
                    if (base == .Ident and std.ascii.eqlIgnoreCase(base.Ident.orig, "count") and self.cur.kind == .star) {
                        // Create a special identifier node for "*"
                        const star_token = self.cur;
                        self.advance();
                        const ap = try self.arena.allocator().create(ast.Expr);
                        const unicode = @import("unicode/unicode_tables.zig");
                        const cnf = unicode.caseFoldToUpper(self.arena.allocator(), star_token.lexeme) catch star_token.lexeme;
                        ap.* = .{ .Ident = .{ .orig = star_token.lexeme, .cnf = cnf } };
                        try args.append(self.arena.allocator(), ap);
                    } else {
                        while (true) {
                            // Parse expression, handling named parameter syntax: identifier => expression
                            // We peek ahead: if we see identifier/keyword followed by =>, skip both and parse value
                            const arg = blk: {
                                // Allow identifiers AND keywords as named parameter names (GQL spec allows keywords)
                                const is_potential_param_name = self.cur.kind == .identifier or
                                    self.cur.kind == .LIMIT or self.cur.kind == .ORDER or
                                    self.cur.kind == .WHERE;

                                if (is_potential_param_name) {
                                    // Save lexer state to check for =>
                                    const saved_idx = self.lx.idx;
                                    const saved_line = self.lx.line;
                                    const saved_col = self.lx.col;

                                    // Try to peek ahead
                                    const next_tok = self.lx.next();

                                    if (next_tok.kind == .double_arrow) {
                                        // This is a named parameter (identifier => value)
                                        // Skip the identifier and => , update current token, then parse value
                                        self.cur = self.lx.next();
                                        break :blk try self.parseOrExpr();
                                    } else {
                                        // Not a named parameter, restore lexer and parse normally
                                        self.lx.idx = saved_idx;
                                        self.lx.line = saved_line;
                                        self.lx.col = saved_col;
                                        break :blk try self.parseOrExpr();
                                    }
                                } else {
                                    break :blk try self.parseOrExpr();
                                }
                            };

                            const ap = try self.arena.allocator().create(ast.Expr);
                            ap.* = arg;
                            try args.append(self.arena.allocator(), ap);
                            if (self.cur.kind != .comma) break;
                            self.advance();
                        }
                    }
                }
                _ = try self.expect(.r_paren);
                const a = self.arena.allocator();
                const cp = try a.create(ast.Expr);
                cp.* = base;
                const args_slice = try args.toOwnedSlice(self.arena.allocator());
                // Simple built-in validation: enforce arity for a few known functions
                if (base == .Ident) {
                    var name = base.Ident;
                    if (saw_distinct and std.ascii.eqlIgnoreCase(name.orig, "count")) {
                        // Rewrite to synthetic function name countDistinct so executor picks it up.
                        name = .{ .orig = "countDistinct", .cnf = "COUNTDISTINCT" };
                        // Allocate new ident expr for callee
                        const np = try a.create(ast.Expr);
                        np.* = .{ .Ident = name };
                        cp.* = np.*;
                    }
                    // Convert []*Expr -> []Expr view for validator
                    var flat = std.ArrayList(ast.Expr).empty;
                    for (args_slice) |p| try flat.append(self.arena.allocator(), p.*);
                    if (!validateBuiltinCall(name.orig, try flat.toOwnedSlice(self.arena.allocator()), self.ts_extensions) and !std.ascii.eqlIgnoreCase(name.orig, "countDistinct")) return self.unexpected("invalid builtin function call");
                }
                base = .{ .Call = .{ .callee = cp, .args = args_slice } };
                continue;
            }
            if (self.cur.kind == .l_bracket) {
                // CANARY: REQ=REQ-GQL-SLICE-002; FEATURE="ListSlicing"; ASPECT=ParserSupport; STATUS=TESTED; TEST=geodetestlab/specs/gql_expressions_comprehensive.yml; OWNER=parser; UPDATED=2025-12-24
                // array index: base[index] or slice: base[start..end]
                self.advance();
                const a = self.arena.allocator();
                const bp = try a.create(ast.Expr);
                bp.* = base;

                // Check for slice syntax: [..end], [start..], [start..end]
                if (self.cur.kind == .dotdot) {
                    // [..end] - slice from beginning
                    self.advance();
                    const end_expr = try self.parseOrExpr();
                    _ = try self.expect(.r_bracket);
                    const ep = try a.create(ast.Expr);
                    ep.* = end_expr;
                    base = .{ .Slice = .{ .target = bp, .start = null, .end = ep } };
                    continue;
                }

                const first_expr = try self.parseOrExpr();

                if (self.cur.kind == .dotdot) {
                    // [start..] or [start..end] - slice with start
                    self.advance();
                    const sp = try a.create(ast.Expr);
                    sp.* = first_expr;

                    if (self.cur.kind == .r_bracket) {
                        // [start..] - slice to end
                        self.advance();
                        base = .{ .Slice = .{ .target = bp, .start = sp, .end = null } };
                    } else {
                        // [start..end] - full slice
                        const end_expr = try self.parseOrExpr();
                        _ = try self.expect(.r_bracket);
                        const ep = try a.create(ast.Expr);
                        ep.* = end_expr;
                        base = .{ .Slice = .{ .target = bp, .start = sp, .end = ep } };
                    }
                    continue;
                }

                // Regular index: base[index]
                _ = try self.expect(.r_bracket);
                const ip = try a.create(ast.Expr);
                ip.* = first_expr;
                base = .{ .Index = .{ .target = bp, .index = ip } };
                continue;
            }
            if (self.cur.kind == .l_brace) {
                // Map projection: n {.name, .age}
                self.advance();
                var fields = std.ArrayList([]const u8).empty;

                // Parse fields: .prop1, .prop2, ...
                while (self.cur.kind == .dot) {
                    self.advance();
                    const field_token = try self.expectIdentifierOrKeyword();
                    try fields.append(self.arena.allocator(), field_token.lexeme);

                    if (self.cur.kind == .comma) {
                        self.advance();
                    } else {
                        break;
                    }
                }

                _ = try self.expect(.r_brace);
                const a = self.arena.allocator();
                const bp = try a.create(ast.Expr);
                bp.* = base;
                base = .{ .MapProjection = .{ .source = bp, .fields = try fields.toOwnedSlice(self.arena.allocator()) } };
                continue;
            }
            // Label test: n:Label (only if base is an identifier)
            if (self.cur.kind == .colon and base == .Ident) {
                self.advance();
                const label_token = try self.expectIdentifierOrKeyword();
                return .{ .HasLabel = .{ .node = base.Ident.orig, .label = label_token.lexeme } };
            }
            break;
        }
        return base;
    }

    fn parsePrimaryExpr(self: *Parser) ParserError!ast.Expr {
        return switch (self.cur.kind) {
            .dollar => blk_param: {
                // Parameter: $identifier or $N (positional)
                // Named: $param_name, $count, $name (identifier or keyword after $)
                // Positional: $1, $2, $3 (integer literal after $, used by Go client)
                self.advance();
                if (self.cur.kind == .integer_lit) {
                    const name = self.cur;
                    self.advance();
                    break :blk_param .{ .Param = name.lexeme };
                }
                const name = try self.expectIdentifierOrKeyword();
                break :blk_param .{ .Param = name.lexeme };
            },
            .date_lit => blk_dt: {
                const tkn = self.cur;
                self.advance();
                const parsed = temporal.parseDate(tkn.lexeme) catch return self.unexpected("invalid DATE literal");
                break :blk_dt .{ .Date = .{ .raw = tkn.lexeme, .parsed = parsed } };
            },
            .datetime_lit => blk_dtt: {
                const tkn = self.cur;
                self.advance();
                const parsed = temporal.parseDateTime(tkn.lexeme, true) catch return self.unexpected("invalid DATETIME literal");
                break :blk_dtt .{ .DateTime = .{ .raw = tkn.lexeme, .parsed = parsed } };
            },
            .time_lit => blk_t: {
                const tkn = self.cur;
                self.advance();
                const parsed = temporal.parseTime(tkn.lexeme, true) catch return self.unexpected("invalid TIME literal");
                break :blk_t .{ .Time = .{ .raw = tkn.lexeme, .parsed = parsed } };
            },
            .local_datetime_lit => blk_ldt: {
                const tkn = self.cur;
                self.advance();
                const parsed = temporal.parseDateTime(tkn.lexeme, false) catch return self.unexpected("invalid LOCAL DATETIME literal");
                break :blk_ldt .{ .LocalDateTime = .{ .raw = tkn.lexeme, .parsed = parsed } };
            },
            .CASE => blk_case: {
                self.advance();
                var operand_opt: ?*ast.Expr = null;
                // Optional simple CASE operand
                if (self.cur.kind != .WHEN) {
                    const opnd = try self.parseOrExpr();
                    const pp = try self.arena.allocator().create(ast.Expr);
                    pp.* = opnd;
                    operand_opt = pp;
                }
                var whens = std.ArrayList(ast.CaseWhen).empty;
                while (self.cur.kind == .WHEN) {
                    self.advance();
                    const when_expr = try self.parseOrExpr();
                    _ = try self.expect(.THEN);
                    const then_expr = try self.parseOrExpr();
                    const a = self.arena.allocator();
                    const wp = try a.create(ast.Expr);
                    const tp = try a.create(ast.Expr);
                    wp.* = when_expr;
                    tp.* = then_expr;
                    try whens.append(self.arena.allocator(), .{ .when = wp, .then_expr = tp });
                }
                var else_p: ?*ast.Expr = null;
                if (self.cur.kind == .ELSE) {
                    self.advance();
                    const e = try self.parseOrExpr();
                    const ep = try self.arena.allocator().create(ast.Expr);
                    ep.* = e;
                    else_p = ep;
                }
                _ = try self.expect(.END);
                const wh_slice = try whens.toOwnedSlice(self.arena.allocator());
                break :blk_case .{ .Case = .{ .operand = operand_opt, .whens = wh_slice, .else_expr = else_p } };
            },
            .identifier => blk: {
                const tkn = self.cur;
                self.advance();
                // Create CNF representation for identifiers
                const unicode = @import("unicode/unicode_tables.zig");
                const cnf = unicode.caseFoldToUpper(self.arena.allocator(), tkn.lexeme) catch tkn.lexeme;
                break :blk .{ .Ident = .{ .orig = tkn.lexeme, .cnf = cnf } };
            },
            .string_lit => blk: {
                const tkn = self.cur;
                self.advance();
                // CANARY: REQ=REQ-GQL-STRING-ESCAPE-001; FEATURE="StringEscaping"; ASPECT=Unescaping; STATUS=TESTED; TEST=geodetestlab/specs/gql_expressions_comprehensive.yml; OWNER=parser; UPDATED=2026-01-09
                // Unescape the string literal to handle \' -> ' and other escape sequences
                break :blk .{ .String = try self.unescapeString(tkn.lexeme) };
            },
            .integer_lit => blk: {
                const tkn = self.cur;
                self.advance();
                break :blk .{ .Int = try std.fmt.parseInt(i64, tkn.lexeme, 10) };
            },
            .float_lit => blk_f: {
                const tkn = self.cur;
                self.advance();
                const lex = tkn.lexeme;

                // Check if this is scientific notation (contains e/E)
                var has_exp = false;
                var exp_idx: usize = 0;
                for (lex, 0..) |c, i| {
                    if (c == 'e' or c == 'E') {
                        has_exp = true;
                        exp_idx = i;
                        break;
                    }
                }

                if (has_exp) {
                    // Parse scientific notation: parse as f64 and convert to decimal
                    const value = try std.fmt.parseFloat(f64, lex);
                    // Use 15 decimal places to preserve precision for small values (e.g. 1.23e-7)
                    const scaled = value * 1_000_000_000_000_000;
                    if (!std.math.isFinite(scaled) or @abs(scaled) >= 1e37) {
                        return error.UnexpectedToken;
                    }
                    const coeff = @as(i128, @intFromFloat(scaled));
                    break :blk_f .{ .Decimal = .{ .coeff = coeff, .scale = 15 } };
                } else {
                    // Standard decimal notation
                    var dot_idx: usize = 0;
                    while (dot_idx < lex.len and lex[dot_idx] != '.') : (dot_idx += 1) {}
                    if (dot_idx >= lex.len) return error.UnexpectedToken;
                    const int_part = lex[0..dot_idx];
                    const frac_part = lex[dot_idx + 1 .. lex.len];
                    const scale: u8 = @intCast(@min(frac_part.len, 255));
                    // coeff = parse int_part ++ frac_part as i128
                    var buf = std.ArrayList(u8).empty;
                    try buf.appendSlice(self.arena.allocator(), int_part);
                    try buf.appendSlice(self.arena.allocator(), frac_part);
                    const coeff = try std.fmt.parseInt(i128, buf.items, 10);
                    break :blk_f .{ .Decimal = .{ .coeff = coeff, .scale = scale } };
                }
            },
            .TRUE => {
                self.advance();
                return .{ .Bool = true };
            },
            .FALSE => {
                self.advance();
                return .{ .Bool = false };
            },
            .NULL => {
                self.advance();
                return .Null;
            },
            .CAST => blk_cast: {
                // CANARY: REQ=REQ-GQL-CAST-001; FEATURE="TypeCasting"; ASPECT=Parser; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=parser; UPDATED=2026-01-25
                // Parse CAST(expr AS type) or CAST(expr AS type(precision)) or CAST(expr AS type(precision, scale))
                self.advance(); // consume CAST
                _ = try self.expect(.l_paren);

                // Parse the expression to cast
                const expr = try self.parseOrExpr();
                const expr_ptr = try self.arena.allocator().create(ast.Expr);
                expr_ptr.* = expr;

                // Expect AS keyword
                _ = try self.expect(.AS);

                // Parse target type - accept identifier or any keyword (type names like DECIMAL are parsed as identifiers)
                const type_name: []const u8 = self.cur.lexeme;
                if (self.cur.kind == .identifier or self.cur.lexeme.len > 0) {
                    self.advance();
                } else {
                    return self.unexpected("expected type name in CAST");
                }

                // Check for optional precision/scale: (precision) or (precision, scale)
                var full_type_name = type_name;
                if (self.cur.kind == .l_paren) {
                    self.advance(); // consume (
                    var type_buf = try std.ArrayList(u8).initCapacity(self.arena.allocator(), 32);
                    try type_buf.appendSlice(self.arena.allocator(), type_name);
                    try type_buf.appendSlice(self.arena.allocator(), "(");

                    // Parse precision
                    if (self.cur.kind != .integer_lit) return self.unexpected("expected precision in CAST type");
                    try type_buf.appendSlice(self.arena.allocator(), self.cur.lexeme);
                    self.advance();

                    // Optional scale
                    if (self.cur.kind == .comma) {
                        self.advance();
                        try type_buf.appendSlice(self.arena.allocator(), ",");
                        if (self.cur.kind != .integer_lit) return self.unexpected("expected scale in CAST type");
                        try type_buf.appendSlice(self.arena.allocator(), self.cur.lexeme);
                        self.advance();
                    }

                    _ = try self.expect(.r_paren);
                    try type_buf.appendSlice(self.arena.allocator(), ")");
                    full_type_name = try type_buf.toOwnedSlice(self.arena.allocator());
                }

                _ = try self.expect(.r_paren); // closing paren of CAST

                // Create a Call node with "cast" as the function name
                const a = self.arena.allocator();
                const callee_ptr = try a.create(ast.Expr);
                callee_ptr.* = .{ .Ident = .{ .orig = "cast", .cnf = "CAST" } };

                const type_ptr = try a.create(ast.Expr);
                type_ptr.* = .{ .String = full_type_name };

                const args = try a.alloc(*ast.Expr, 2);
                args[0] = expr_ptr;
                args[1] = type_ptr;

                break :blk_cast .{ .Call = .{ .callee = callee_ptr, .args = args } };
            },
            .l_paren => blk_paren: {
                // grouping
                self.advance();
                const inner = try self.parseOrExpr();
                _ = try self.expect(.r_paren);
                break :blk_paren inner;
            },
            .l_brace => blk_map: {
                const props = try self.parsePropertyMap();
                break :blk_map .{ .Map = props };
            },
            .l_bracket => blk_pc: {
                // Try to parse pattern comprehension: [ pattern (WHERE expr)? | expr ]
                // Heuristic: next meaningful token starts a node/connector or alias (identifier '=')
                self.advance();
                var starts_pattern = false;
                if (self.cur.kind == .l_paren or self.cur.kind == .arrow_l or self.cur.kind == .minus or ((self.cur.kind == .identifier or self.cur.kind == .PATH) and self.peekKind() == .eq)) {
                    starts_pattern = true;
                }
                if (!starts_pattern) {
                    // Check for list comprehension: [x IN list WHERE cond | expr]
                    // Detected by: identifier IN ...
                    if (self.cur.kind == .identifier and self.peekKind() == .IN) {
                        // Parse list comprehension
                        const var_name = self.cur.lexeme;
                        self.advance(); // consume identifier
                        self.advance(); // consume IN

                        // Parse source expression
                        const source_expr = try self.parseOrExpr();
                        const source_ptr = try self.arena.allocator().create(ast.Expr);
                        source_ptr.* = source_expr;

                        // Optional WHERE filter
                        var filter_ptr: ?*ast.Expr = null;
                        if (self.cur.kind == .WHERE) {
                            self.advance();
                            const filter_expr = try self.parseOrExpr();
                            const fp = try self.arena.allocator().create(ast.Expr);
                            fp.* = filter_expr;
                            filter_ptr = fp;
                        }

                        // Optional | map expression
                        var map_ptr: ?*ast.Expr = null;
                        if (self.cur.kind == .bar) {
                            self.advance();
                            const map_expr = try self.parseOrExpr();
                            const mp = try self.arena.allocator().create(ast.Expr);
                            mp.* = map_expr;
                            map_ptr = mp;
                        }

                        _ = try self.expect(.r_bracket);
                        break :blk_pc .{ .ListComprehension = .{
                            .variable = var_name,
                            .source = source_ptr,
                            .filter = filter_ptr,
                            .map = map_ptr,
                        } };
                    }

                    // Try to parse as array literal: [expr, expr, ...]
                    var elements = std.ArrayList(*ast.Expr).empty;

                    // Handle empty array
                    if (self.cur.kind == .r_bracket) {
                        self.advance();
                        const elements_slice = try elements.toOwnedSlice(self.arena.allocator());
                        break :blk_pc .{ .ArrayLit = elements_slice };
                    }

                    // Parse comma-separated expressions
                    while (true) {
                        const elem = try self.parseOrExpr();
                        const ep = try self.arena.allocator().create(ast.Expr);
                        ep.* = elem;
                        try elements.append(self.arena.allocator(), ep);

                        if (self.cur.kind != .comma) break;
                        self.advance();
                    }

                    _ = try self.expect(.r_bracket);
                    const elements_slice = try elements.toOwnedSlice(self.arena.allocator());
                    break :blk_pc .{ .ArrayLit = elements_slice };
                }
                // CANARY: REQ=REQ-GQL-164; FEATURE="Pattern Comprehension Shorthand"; ASPECT=Parser; STATUS=TESTED; OWNER=parser; UPDATED=2025-10-14
                self.pattern_comp_depth += 1;
                const pat_val = try self.parseGraphPattern();
                var where_expr: ?*ast.Expr = null;
                if (self.cur.kind == .WHERE) {
                    self.advance();
                    const w = try self.parseOrExpr();
                    const wp = try self.arena.allocator().create(ast.Expr);
                    wp.* = w;
                    where_expr = wp;
                }

                // Make | optional - when omitted, return the matched path/nodes
                // Syntax: [(a)--()]  is shorthand for  [(a)--(x) | x]
                // We'll create a synthetic identifier for the last node in the pattern
                var map_expr_v: ast.Expr = undefined;
                if (self.cur.kind == .bar) {
                    self.advance();
                    map_expr_v = try self.parseOrExpr();
                } else {
                    // No | provided - create synthetic expression to return matched nodes
                    // Find the last node variable in the pattern to return
                    // For pattern (a)--(), the unnamed node should be bound to a synthetic var
                    // We'll use a special marker to indicate "return all matched nodes"
                    // The execution engine will interpret this as returning the target node
                    const unicode = @import("unicode/unicode_tables.zig");
                    const synthetic_name = "__pattern_target__";
                    const cnf = unicode.caseFoldToUpper(self.arena.allocator(), synthetic_name) catch synthetic_name;
                    map_expr_v = .{ .Ident = .{ .orig = synthetic_name, .cnf = cnf } };
                }
                const mp = try self.arena.allocator().create(ast.Expr);
                mp.* = map_expr_v;
                _ = try self.expect(.r_bracket);
                self.pattern_comp_depth -= 1;
                const a = self.arena.allocator();
                const pat_ptr = try a.create(ast.GraphPattern);
                pat_ptr.* = pat_val;
                // Optional alias for comprehension result: allow preceding identifier '=' before '[' already handled in outer parse? Here we support inline alias via a prior token check.
                // We accept syntax like: p = [ pattern | expr ] by handling in parsePostfix callsite normally as a top-level expression using Binary Eq? Simpler: support a prefix alias in primary by checking for preceding identifier '=' is not feasible here.
                // Implement simpler form: allow after comprehension an optional 'AS ident' alias; or embed none. We'll stick to none here; aliasing can be carried by outer ReturnItem alias.
                break :blk_pc .{ .PatternComp = .{ .pattern = pat_ptr, .where = where_expr, .map = mp, .alias = null } };
            },
            else => blk: {
                // Accept keywords as identifiers (ISO/IEC 39075:2024 compliance)
                // This handles cases like: MATCH (create:Person) RETURN create
                if (self.isKeyword(self.cur.kind)) {
                    const tkn = self.cur;
                    self.advance();
                    // Create CNF representation for identifiers
                    const unicode = @import("unicode/unicode_tables.zig");
                    const cnf = unicode.caseFoldToUpper(self.arena.allocator(), tkn.lexeme) catch tkn.lexeme;
                    break :blk .{ .Ident = .{ .orig = tkn.lexeme, .cnf = cnf } };
                }
                // Not an identifier or keyword, return error
                return error.UnexpectedToken;
            },
        };
    }

    fn makeBinary(self: *Parser, op: ast.BinOp, left: ast.Expr, right: ast.Expr) ParserError!ast.Expr {
        const a = self.arena.allocator();
        const lp = try a.create(ast.Expr);
        const rp = try a.create(ast.Expr);
        lp.* = left;
        rp.* = right;
        return .{ .Binary = .{ .op = op, .left = lp, .right = rp } };
    }

    fn isSimpleOrderKey(self: *Parser, expr: ast.Expr) bool {
        // Simple: IDENT or nested Member chains like a.b.c
        return switch (expr) {
            .Ident => true,
            .Member => |m| self.isSimpleOrderPtr(m.target.*),
            else => false,
        };
    }

    fn isSimpleOrderPtr(self: *Parser, e: ast.Expr) bool {
        return switch (e) {
            .Ident => true,
            .Member => |m| self.isSimpleOrderPtr(m.target.*),
            else => false,
        };
    }

    pub fn containsCall(self: *Parser, e: ast.Expr) bool {
        return switch (e) {
            .Call => true,
            .Member => |m| self.containsCall(m.target.*),
            .Unary => |u| self.containsCall(u.expr.*),
            .Binary => |b| self.containsCall(b.left.*) or self.containsCall(b.right.*),
            .List => |items| blk: {
                for (items) |it| if (self.containsCall(it.*)) break :blk true;
                break :blk false;
            },
            .In => |x| blk2: {
                if (self.containsCall(x.value.*)) break :blk2 true;
                for (x.set) |it| if (self.containsCall(it.*)) break :blk2 true;
                break :blk2 false;
            },
            .IsNull => |z| self.containsCall(z.target.*),
            else => false,
        };
    }

    // Static variant for post-parse validation (no Parser instance state needed)
    pub fn containsCallStatic(e: ast.Expr) bool {
        return switch (e) {
            .Call => true,
            .Member => |m| containsCallStatic(m.target.*),
            .Unary => |u| containsCallStatic(u.expr.*),
            .Binary => |b| containsCallStatic(b.left.*) or containsCallStatic(b.right.*),
            .List => |items| blk: {
                for (items) |it| if (containsCallStatic(it.*)) break :blk true;
                break :blk false;
            },
            .In => |x| blk2: {
                if (containsCallStatic(x.value.*)) break :blk2 true;
                for (x.set) |it| if (containsCallStatic(it.*)) break :blk2 true;
                break :blk2 false;
            },
            .IsNull => |z| containsCallStatic(z.target.*),
            else => false,
        };
    }

    fn argIsPropertyLike(e: ast.Expr) bool {
        return switch (e) {
            .Member => true, // n.prop
            .Ident => true, // bare identifier accepted
            else => false,
        };
    }

    fn argIsNumericLike(e: ast.Expr) bool {
        return switch (e) {
            .Int => true,
            .Decimal => true,
            .Binary => true, // allow arithmetic expressions
            .Unary => true,
            .Ident => true,
            .Member => true,
            .Call => true, // allow nested function calls
            .Null => true, // NULL is valid for functions like abs(NULL)
            else => false,
        };
    }

    fn argIsStringLike(e: ast.Expr) bool {
        return switch (e) {
            .String => true,
            .Ident => true,
            .Member => true,
            .Call => true, // allow nested function calls
            else => false,
        };
    }

    fn validateBuiltinCall(name: []const u8, args: []ast.Expr, ts_enabled: bool) bool {
        const n = args.len;
        // Table of builtins: name, min_arity, max_arity (usize max means unbounded), validator
        if (std.ascii.eqlIgnoreCase(name, "exists")) {
            if (n != 1) return false;
            return argIsPropertyLike(args[0]);
        }
        if (std.ascii.eqlIgnoreCase(name, "length")) {
            return n == 1;
        }
        if (std.ascii.eqlIgnoreCase(name, "id")) {
            return n == 1 and argIsPropertyLike(args[0]);
        }
        if (std.ascii.eqlIgnoreCase(name, "labels")) {
            return n == 1 and (args[0] == .Ident or args[0] == .Member);
        }
        if (std.ascii.eqlIgnoreCase(name, "type")) {
            // Accept any single expression for type() function
            return n == 1;
        }
        if (std.ascii.eqlIgnoreCase(name, "coalesce")) {
            return n >= 1;
        }
        if (std.ascii.eqlIgnoreCase(name, "toInteger")) {
            // Accept any single expression for toInteger() function
            return n == 1;
        }
        if (std.ascii.eqlIgnoreCase(name, "toString")) {
            // Accept any single expression for toString() function
            return n == 1;
        }
        // CANARY: REQ=REQ-GQL-CAST-003; FEATURE="TypeCasting"; ASPECT=Validation; STATUS=TESTED; TEST=geodetestlab/specs/geode_functions_comprehensive.yml; OWNER=parser; UPDATED=2026-01-25
        if (std.ascii.eqlIgnoreCase(name, "cast")) {
            // CAST(expr, type_string) - requires exactly 2 args
            return n == 2;
        }
        if (std.ascii.eqlIgnoreCase(name, "abs")) {
            return n == 1 and argIsNumericLike(args[0]);
        }
        // Vector types - accept array literal or string
        if (std.ascii.eqlIgnoreCase(name, "VectorF32")) {
            return n == 1 and (args[0] == .ArrayLit or argIsStringLike(args[0]));
        }
        if (std.ascii.eqlIgnoreCase(name, "VectorI32")) {
            return n == 1 and (args[0] == .ArrayLit or argIsStringLike(args[0]));
        }
        // Geographic types - accept two numbers or one string
        if (std.ascii.eqlIgnoreCase(name, "LatLon")) {
            return (n == 2 and argIsNumericLike(args[0]) and argIsNumericLike(args[1])) or (n == 1 and argIsStringLike(args[0]));
        }
        if (std.ascii.eqlIgnoreCase(name, "LatLonAlt")) {
            // Accept 3 numeric args (lat, lon, alt) or 4 args (lat, lon, alt, ref) or 1 string
            if (n == 1 and argIsStringLike(args[0])) return true;
            if (n == 3 and argIsNumericLike(args[0]) and argIsNumericLike(args[1]) and argIsNumericLike(args[2])) return true;
            if (n == 4 and argIsNumericLike(args[0]) and argIsNumericLike(args[1]) and argIsNumericLike(args[2])) return true;
            return false;
        }
        if (std.ascii.eqlIgnoreCase(name, "GeoPoint")) {
            return (n == 2 and argIsNumericLike(args[0]) and argIsNumericLike(args[1])) or (n == 1 and argIsStringLike(args[0]));
        }
        // JSON/Geometry types - accept string
        if (std.ascii.eqlIgnoreCase(name, "Jsonb")) {
            return n == 1 and argIsStringLike(args[0]);
        }
        if (std.ascii.eqlIgnoreCase(name, "GeometryFromText")) {
            return n == 1 and argIsStringLike(args[0]);
        }
        // Map functions
        if (std.ascii.eqlIgnoreCase(name, "keys")) {
            return n == 1; // Accept any expression that evaluates to a map
        }
        if (std.ascii.eqlIgnoreCase(name, "values")) {
            return n == 1; // Accept any expression that evaluates to a map
        }
        if (ts_enabled) {
            // Core time-series functions
            if (std.ascii.eqlIgnoreCase(name, "last_value")) {
                if (n != 1) return false;
                return argIsPropertyLike(args[0]) or args[0] == .Ident or args[0] == .Member or argIsStringLike(args[0]);
            }
            if (std.ascii.eqlIgnoreCase(name, "value_at")) {
                if (n != 2) return false;
                return (argIsPropertyLike(args[0]) or args[0] == .Ident or args[0] == .Member or argIsStringLike(args[0])) and argIsNumericLike(args[1]);
            }
            if (std.ascii.eqlIgnoreCase(name, "sample_by")) {
                if (n < 2 or n > 5) return false; // series, interval, [start_ts, end_ts, aggregation]
                if (!(argIsPropertyLike(args[0]) or args[0] == .Ident or args[0] == .Member or argIsStringLike(args[0]))) return false;
                if (!argIsNumericLike(args[1])) return false;
                if (n >= 3 and !argIsNumericLike(args[2])) return false;
                if (n >= 4 and !argIsNumericLike(args[3])) return false;
                if (n == 5 and !(argIsStringLike(args[4]) or args[4] == .Ident)) return false;
                return true;
            }
            // Advanced time-series functions
            if (std.ascii.eqlIgnoreCase(name, "interpolate")) {
                if (n < 2 or n > 3) return false; // series, timestamp, [method]
                if (!(argIsPropertyLike(args[0]) or args[0] == .Ident or args[0] == .Member or argIsStringLike(args[0]))) return false;
                if (!argIsNumericLike(args[1])) return false;
                if (n == 3 and !(argIsStringLike(args[2]) or args[2] == .Ident)) return false;
                return true;
            }
            if (std.ascii.eqlIgnoreCase(name, "moving_avg")) {
                if (n != 3) return false; // series, window_ms, step_ms
                if (!(argIsPropertyLike(args[0]) or args[0] == .Ident or args[0] == .Member or argIsStringLike(args[0]))) return false;
                if (!argIsNumericLike(args[1])) return false;
                if (!argIsNumericLike(args[2])) return false;
                return true;
            }
            if (std.ascii.eqlIgnoreCase(name, "rate")) {
                if (n != 2) return false; // series, interval_ms
                if (!(argIsPropertyLike(args[0]) or args[0] == .Ident or args[0] == .Member or argIsStringLike(args[0]))) return false;
                if (!argIsNumericLike(args[1])) return false;
                return true;
            }
            if (std.ascii.eqlIgnoreCase(name, "derivative")) {
                if (n < 1 or n > 2) return false; // series, [order]
                if (!(argIsPropertyLike(args[0]) or args[0] == .Ident or args[0] == .Member or argIsStringLike(args[0]))) return false;
                if (n == 2 and !argIsNumericLike(args[1])) return false;
                return true;
            }
            if (std.ascii.eqlIgnoreCase(name, "time_bucket")) {
                if (n != 4) return false; // series, bucket_ms, start_ts, end_ts
                if (!(argIsPropertyLike(args[0]) or args[0] == .Ident or args[0] == .Member or argIsStringLike(args[0]))) return false;
                if (!argIsNumericLike(args[1])) return false;
                if (!argIsNumericLike(args[2])) return false;
                if (!argIsNumericLike(args[3])) return false;
                return true;
            }
        }
        // Unknown functions: allow any arity for now
        return true;
    }

    // Parse CREATE statement (CREATE pattern or CREATE INDEX)
    fn parseCreateStatement(self: *Parser) ParserError!ast.Statement {
        _ = try self.expect(.CREATE);

        // Check for OR REPLACE
        var or_replace = false;
        if (self.cur.kind == .OR) {
            self.advance();
            if (self.cur.kind == .REPLACE) {
                self.advance();
                or_replace = true;
            } else {
                return error.UnexpectedToken;
            }
        }

        // Check if this is CREATE INDEX
        if (self.cur.kind == .INDEX or
            (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "INDEX")) or
            (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "UNIQUE")))
        {
            return self.parseCreateIndex();
        }

        // Check if this is CREATE CONSTRAINT
        if (self.cur.kind == .CONSTRAINT) {
            self.advance();
            return self.parseCreateConstraint();
        }

        // Check if this is CREATE SCHEMA
        if (self.cur.kind == .SCHEMA) {
            return self.parseCreateSchema();
        }

        // Check if this is CREATE GRAPH or CREATE PROPERTY GRAPH
        if (self.cur.kind == .GRAPH or
            self.cur.kind == .PROPERTY or
            (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "PROPERTY")))
        {
            // For now, let the individual functions handle TYPE detection
            return self.parseCreateGraphWithReplace(or_replace);
        }

        // Otherwise, parse the pattern to create - support multiple consecutive CREATE clauses
        // e.g., CREATE (a:Node) CREATE (b:Node) WITH 1 AS x ...
        // CANARY: REQ=REQ-GQL-MULTI-CREATE-002; FEATURE="MultipleConsecutiveCreate"; ASPECT=ParserCreateStatement; STATUS=TESTED; TEST=geodetestlab/specs/gql_data_modification_comprehensive.yml; OWNER=parser; UPDATED=2025-12-27
        var pattern: ast.GraphPattern = undefined;
        {
            var create_chains = std.ArrayList(ast.Chain).empty;
            // First pattern already consumed the CREATE keyword
            const first_pattern = try self.parseGraphPattern();
            for (first_pattern.chains) |chain| {
                try create_chains.append(self.arena.allocator(), chain);
            }
            // Handle additional CREATE patterns
            while (self.cur.kind == .CREATE) {
                self.advance();
                const next_pattern = try self.parseGraphPattern();
                for (next_pattern.chains) |chain| {
                    try create_chains.append(self.arena.allocator(), chain);
                }
            }
            pattern = .{ .chains = try create_chains.toOwnedSlice(self.arena.allocator()) };
        }

        // CANARY: REQ=REQ-GQL-083; FEATURE="CreateWithClause"; ASPECT=ParserSupport; STATUS=TESTED; OWNER=parser; UPDATED=2025-10-09
        // Check if this is followed by WITH, SET, REMOVE, or DELETE - if so, this should be a Query, not a standalone CREATE
        if (self.cur.kind == .WITH or self.cur.kind == .SET or self.cur.kind == .REMOVE or self.cur.kind == .DELETE) {
            // This is CREATE ... WITH/SET/REMOVE ... RETURN
            // We need to construct a Query with create_pattern set

            // Parse WITH clause if present
            var with_clause: ?ast.WithClause = null;
            var next_query_ptr: ?*ast.Query = null;
            if (self.cur.kind == .WITH) {
                self.advance();
                var witems = std.ArrayList(ast.ReturnItem).empty;
                try self.parseProjectionItems(&witems);

                // Parse optional ORDER BY, LIMIT, OFFSET after WITH items
                var with_order_by: ?*ast.OrderBy = null;
                var with_limit: ?u64 = null;
                var with_offset: ?u64 = null;
                var with_limit_param: ?[]const u8 = null;
                var with_offset_param: ?[]const u8 = null;

                if (self.cur.kind == .ORDER) {
                    self.advance();
                    _ = try self.expect(.BY);
                    var keys = std.ArrayList(ast.OrderBy.OrderKey).empty;
                    while (true) {
                        const key_expr = try self.parseOrExpr();
                        const mods = try self.parseOrderKeyModifiers();
                        try keys.append(self.arena.allocator(), .{ .expr = key_expr, .desc = mods.desc, .nulls = mods.nulls });
                        if (self.cur.kind != .comma) break;
                        self.advance();
                    }
                    const order_by_ptr = try self.arena.allocator().create(ast.OrderBy);
                    order_by_ptr.* = .{ .keys = try keys.toOwnedSlice(self.arena.allocator()) };
                    with_order_by = order_by_ptr;
                }

                if (self.cur.kind == .LIMIT) {
                    self.advance();
                    const lim = try self.parseLimitValue();
                    with_limit = lim.value;
                    with_limit_param = lim.param;
                }

                if (self.cur.kind == .OFFSET or self.cur.kind == .SKIP) {
                    self.advance();
                    const off = try self.parseLimitValue();
                    with_offset = off.value;
                    with_offset_param = off.param;
                }

                with_clause = .{
                    .items = try witems.toOwnedSlice(self.arena.allocator()),
                    .order_by = with_order_by,
                    .limit = with_limit,
                    .offset = with_offset,
                    .limit_param = with_limit_param,
                    .offset_param = with_offset_param,
                };

                // CANARY: REQ=REQ-GQL-CHAIN; FEATURE="Query Chaining via WITH"; ASPECT=Parser; STATUS=TESTED; TEST=graph_algorithms; OWNER=parser; UPDATED=2026-01-17
                // Check for query chaining: WITH ... MATCH/CREATE ...
                // If we see MATCH or CREATE after WITH, parse it as a chained query
                if (self.cur.kind == .MATCH or self.cur.kind == .CREATE) {
                    // Parse the continuation as a new query
                    const next_query = try self.parseQuery();
                    // Allocate on arena and store pointer
                    const next_ptr = try self.arena.allocator().create(ast.Query);
                    next_ptr.* = next_query;
                    next_query_ptr = next_ptr;

                    // Current query acts as a WITH-only query (implicit RETURN from WITH items)
                    // Return a Query with create_pattern and next_query set
                    return .{
                        .Query = .{
                            .optional_match = false,
                            .match = .{ .chains = &.{} }, // Empty match pattern
                            .create_pattern = pattern, // CREATE pattern goes here
                            .where_clause = null,
                            .with_clause = with_clause,
                            .set_clauses = &.{},
                            .remove_clauses = &.{},
                            .ret = .{ .items = with_clause.?.items, .distinct = false }, // Implicit RETURN
                            .order_by = null,
                            .limit = null,
                            .offset = null,
                            .next_query = next_query_ptr,
                        },
                    };
                }
            }

            // Parse SET clauses if present
            var set_clauses: []ast.SetClause = &.{};
            if (self.cur.kind == .SET) {
                self.advance();
                set_clauses = try self.parseSetClauses();
            }

            // Parse REMOVE clauses if present
            var remove_clauses: []ast.RemoveClause = &.{};
            if (self.cur.kind == .REMOVE) {
                self.advance();
                remove_clauses = try self.parseRemoveClauses();
            }

            // Parse DELETE clause if present (for CREATE ... WITH ... DELETE ... pattern)
            // CANARY: REQ=REQ-GQL-DELETE; FEATURE="DELETE in Query"; ASPECT=ParserCreateStatement; STATUS=TESTED; TEST=no-id-collision-on-delete-create; OWNER=parser; UPDATED=2025-10-14
            var delete_items: []ast.DeleteItem = &.{};
            if (self.cur.kind == .DELETE) {
                self.advance();
                delete_items = try self.parseDeleteItems();
            }

            // Parse RETURN clause (required for Query)
            var return_clause: ast.ReturnClause = undefined;
            if (self.cur.kind == .RETURN) {
                self.advance();
                const distinct = if (self.cur.kind == .DISTINCT) blk: {
                    self.advance();
                    break :blk true;
                } else false;
                var items = std.ArrayList(ast.ReturnItem).empty;
                try self.parseProjectionItems(&items);
                return_clause = .{ .items = try items.toOwnedSlice(self.arena.allocator()), .distinct = distinct };
            } else if (set_clauses.len > 0 or remove_clauses.len > 0 or delete_items.len > 0) {
                // SET/REMOVE/DELETE without RETURN - create empty return clause
                return_clause = .{ .items = &.{}, .distinct = false };
            } else {
                // No SET/REMOVE/DELETE and no RETURN after WITH - error
                _ = try self.expect(.RETURN);
                unreachable;
            }

            // Return a Query with create_pattern set (no chaining)
            return .{
                .Query = .{
                    .optional_match = false,
                    .match = .{ .chains = &.{} }, // Empty match pattern
                    .create_pattern = pattern, // CREATE pattern goes here
                    .where_clause = null,
                    .with_clause = with_clause,
                    .set_clauses = set_clauses,
                    .remove_clauses = remove_clauses,
                    .delete_items = delete_items,
                    .ret = return_clause,
                    .order_by = null,
                    .limit = null,
                    .offset = null,
                },
            };
        }

        // Optional RETURN clause (for standalone CREATE without WITH/SET/REMOVE)
        var return_clause: ?ast.ReturnClause = null;
        if (self.cur.kind == .RETURN) {
            self.advance();
            const distinct = if (self.cur.kind == .DISTINCT) blk: {
                self.advance();
                break :blk true;
            } else false;
            var return_items = std.ArrayList(ast.ReturnItem).empty;
            try self.parseProjectionItems(&return_items);
            return_clause = .{
                .items = try return_items.toOwnedSlice(self.arena.allocator()),
                .distinct = distinct,
            };

            // Check if RETURN is followed by UNION, ORDER BY, LIMIT, or OFFSET
            // If so, convert to Query and handle through handleQueryResult
            if (self.cur.kind == .UNION or self.cur.kind == .ORDER or self.cur.kind == .LIMIT or self.cur.kind == .OFFSET or self.cur.kind == .SKIP) {
                // Convert CREATE ... RETURN to a Query
                const query = ast.Query{
                    .optional_match = false,
                    .match = .{ .chains = &.{} },
                    .where_clause = null,
                    .with_clause = null,
                    .create_pattern = pattern,
                    .ret = return_clause.?,
                    .order_by = null,
                    .limit = null,
                    .offset = null,
                    .next_query = null,
                };
                // handleQueryResult will parse UNION, ORDER BY, LIMIT, OFFSET
                return self.handleQueryResult(query);
            }
        }

        return .{ .Create = .{
            .pattern = pattern,
            .return_clause = return_clause,
        } };
    }

    // Parse DELETE statement
    fn parseDeleteStatement(self: *Parser) ParserError!ast.Statement {
        const detach = if (self.cur.kind == .DETACH) blk: {
            self.advance();
            break :blk true;
        } else false;

        _ = try self.expect(.DELETE);

        // Optional MATCH clause
        var match_clause: ?ast.GraphPattern = null;
        var where_clause: ?ast.Expr = null;

        if (self.cur.kind == .MATCH) {
            self.advance();
            match_clause = try self.parseGraphPattern();

            if (self.cur.kind == .WHERE) {
                self.advance();
                where_clause = try self.parseOrExpr();
            }
        }

        // Parse items to delete
        // GAP-0220 FIX: Use try for proper error propagation
        var items = try std.ArrayList(ast.DeleteItem).initCapacity(self.arena.allocator(), 0);

        // Parse first item
        const first_item = try self.parseDeleteItem();
        try items.append(self.arena.allocator(), first_item);

        // Parse additional items
        while (self.cur.kind == .comma) {
            self.advance();
            const item = try self.parseDeleteItem();
            try items.append(self.arena.allocator(), item);
        }

        // Optional RETURN clause
        var return_clause: ?ast.ReturnClause = null;
        if (self.cur.kind == .RETURN) {
            self.advance();
            const distinct = if (self.cur.kind == .DISTINCT) blk: {
                self.advance();
                break :blk true;
            } else false;
            var return_items = std.ArrayList(ast.ReturnItem).empty;
            try self.parseProjectionItems(&return_items);
            return_clause = .{
                .items = try return_items.toOwnedSlice(self.arena.allocator()),
                .distinct = distinct,
            };
        }

        return .{ .Delete = .{
            .match_clause = match_clause,
            .where_clause = where_clause,
            .detach = detach,
            .items = try items.toOwnedSlice(self.arena.allocator()),
            .return_clause = return_clause,
        } };
    }

    fn parseDeleteItem(self: *Parser) ParserError!ast.DeleteItem {
        if (self.cur.kind != .identifier) return error.UnexpectedToken;
        const name = self.cur.lexeme;
        self.advance();
        return .{ .Variable = name };
    }

    // Parse MERGE statement
    fn parseMergeStatement(self: *Parser) ParserError!ast.Statement {
        _ = try self.expect(.MERGE);

        // Parse the pattern to merge
        const pattern = try self.parseGraphPattern();

        // Parse ON CREATE/MATCH clauses
        // GAP-0220 FIX: Use try for proper error propagation
        var on_create = try std.ArrayList(ast.SetClause).initCapacity(self.arena.allocator(), 0);
        var on_match = try std.ArrayList(ast.SetClause).initCapacity(self.arena.allocator(), 0);

        while (self.cur.kind == .ON) {
            self.advance();

            if (self.cur.kind == .CREATE) {
                self.advance();
                _ = try self.expect(.SET);
                const clauses = try self.parseSetClauses();
                try on_create.appendSlice(self.arena.allocator(), clauses);
            } else if (self.cur.kind == .MATCH) {
                self.advance();
                _ = try self.expect(.SET);
                const clauses = try self.parseSetClauses();
                try on_match.appendSlice(self.arena.allocator(), clauses);
            } else {
                return error.UnexpectedToken;
            }
        }

        // Handle bare SET (applies to both create and match paths) - GAP #59
        if (self.cur.kind == .SET) {
            self.advance();
            const clauses = try self.parseSetClauses();
            try on_create.appendSlice(self.arena.allocator(), clauses);
            try on_match.appendSlice(self.arena.allocator(), clauses);
        }

        // Optional RETURN clause
        var return_clause: ?ast.ReturnClause = null;
        if (self.cur.kind == .RETURN) {
            self.advance();
            const distinct = if (self.cur.kind == .DISTINCT) blk: {
                self.advance();
                break :blk true;
            } else false;
            var return_items = std.ArrayList(ast.ReturnItem).empty;
            try self.parseProjectionItems(&return_items);
            return_clause = .{
                .items = try return_items.toOwnedSlice(self.arena.allocator()),
                .distinct = distinct,
            };
        }

        return .{ .Merge = .{
            .pattern = pattern,
            .on_create = try on_create.toOwnedSlice(self.arena.allocator()),
            .on_match = try on_match.toOwnedSlice(self.arena.allocator()),
            .return_clause = return_clause,
        } };
    }

    fn parseSetClauses(self: *Parser) ParserError![]ast.SetClause {
        // GAP-0220 FIX: Use try for proper error propagation
        var clauses = try std.ArrayList(ast.SetClause).initCapacity(self.arena.allocator(), 0);

        // Parse first clause
        const first = try self.parseSetClause();
        try clauses.append(self.arena.allocator(), first);

        // Parse additional clauses
        while (self.cur.kind == .comma) {
            self.advance();
            const clause = try self.parseSetClause();
            try clauses.append(self.arena.allocator(), clause);
        }

        return clauses.toOwnedSlice(self.arena.allocator());
    }

    fn parseSetClause(self: *Parser) ParserError!ast.SetClause {
        // Parse identifier (e.g., n)
        if (self.cur.kind != .identifier) return error.UnexpectedToken;
        const object = self.cur.lexeme;
        self.advance();

        // Check what follows the identifier
        if (self.cur.kind == .colon) {
            // Parse label(s): SET n:Label or SET n:Label1:Label2
            // GAP-0220 FIX: Use try for proper error propagation
            var labels = try std.ArrayList([]const u8).initCapacity(self.arena.allocator(), 0);

            while (self.cur.kind == .colon) {
                self.advance(); // consume ':'
                const label_token = try self.expectIdentifierOrKeyword();
                try labels.append(self.arena.allocator(), label_token.lexeme);
            }

            return .{ .Labels = .{
                .node = object,
                .labels = try labels.toOwnedSlice(self.arena.allocator()),
            } };
        } else if (self.cur.kind == .eq) {
            // SET n = {properties}: Replace all properties
            self.advance(); // consume '='
            const properties = try self.parseOrExpr();

            return .{ .AllProperties = .{
                .node = object,
                .properties = properties,
            } };
        } else {
            // Property setting: n.property = value
            _ = try self.expect(.dot);

            const property_token = try self.expectIdentifierOrKeyword();
            const property = property_token.lexeme;

            _ = try self.expect(.eq);

            const value = try self.parseOrExpr();

            return .{ .Property = .{
                .target = .{ .object = object, .property = property },
                .value = value,
            } };
        }
    }

    fn parseRemoveClauses(self: *Parser) ParserError![]ast.RemoveClause {
        // GAP-0220 FIX: Use try for proper error propagation
        var clauses = try std.ArrayList(ast.RemoveClause).initCapacity(self.arena.allocator(), 0);

        // Parse first clause
        const first = try self.parseRemoveClause();
        try clauses.append(self.arena.allocator(), first);

        // Parse additional clauses
        while (self.cur.kind == .comma) {
            self.advance();
            const clause = try self.parseRemoveClause();
            try clauses.append(self.arena.allocator(), clause);
        }

        return clauses.toOwnedSlice(self.arena.allocator());
    }

    fn parseRemoveClause(self: *Parser) ParserError!ast.RemoveClause {
        // Parse identifier (e.g., n)
        if (self.cur.kind != .identifier) return error.UnexpectedToken;
        const object = self.cur.lexeme;
        self.advance();

        // Check if it's a label removal (n:Label) or property removal (n.property)
        if (self.cur.kind == .colon) {
            // Parse label(s): REMOVE n:Label or REMOVE n:Label1:Label2
            // GAP-0220 FIX: Use try for proper error propagation
            var labels = try std.ArrayList([]const u8).initCapacity(self.arena.allocator(), 0);

            while (self.cur.kind == .colon) {
                self.advance(); // consume ':'
                const label_token = try self.expectIdentifierOrKeyword();
                try labels.append(self.arena.allocator(), label_token.lexeme);
            }

            return .{ .Labels = .{
                .node = object,
                .labels = try labels.toOwnedSlice(self.arena.allocator()),
            } };
        } else {
            // Property removal: n.property
            _ = try self.expect(.dot);

            const property_token = try self.expectIdentifierOrKeyword();
            const property = property_token.lexeme;

            return .{ .Property = .{ .object = object, .property = property } };
        }
    }

    fn parseDeleteItems(self: *Parser) ParserError![]ast.DeleteItem {
        // GAP-0220 FIX: Use try for proper error propagation
        var items = try std.ArrayList(ast.DeleteItem).initCapacity(self.arena.allocator(), 0);

        // Parse first item
        const first = try self.parseDeleteItem();
        try items.append(self.arena.allocator(), first);

        // Parse additional items
        while (self.cur.kind == .comma) {
            self.advance();
            const item = try self.parseDeleteItem();
            try items.append(self.arena.allocator(), item);
        }

        return items.toOwnedSlice(self.arena.allocator());
    }

    // Parse CREATE INDEX statement
    fn parseCreateIndex(self: *Parser) ParserError!ast.Statement {
        var unique = false;

        // Check for UNIQUE keyword
        if (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "UNIQUE")) {
            unique = true;
            self.advance();
        }

        // Expect INDEX keyword
        if (self.cur.kind == .INDEX) {
            self.advance();
        } else if (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "INDEX")) {
            self.advance();
        } else {
            return error.UnexpectedToken;
        }

        // Optional IF NOT EXISTS
        var if_not_exists = false;
        if (self.cur.kind == .IF) {
            self.advance();
            if (self.cur.kind == .NOT) {
                self.advance();
                if (self.cur.kind == .EXISTS) {
                    self.advance();
                    if_not_exists = true;
                } else {
                    return error.UnexpectedToken;
                }
            } else {
                return error.UnexpectedToken;
            }
        }

        // Index name (optional - may be omitted when ON or FOR follows directly)
        var name: ?[]const u8 = null;
        if (self.cur.kind == .identifier) {
            name = self.cur.lexeme;
            self.advance();
        } else if (self.cur.kind != .ON and self.cur.kind != .FOR) {
            return error.UnexpectedToken;
        }

        var label: []const u8 = "";
        var pattern_variable: ?[]const u8 = null;

        // Check for ISO GQL syntax: FOR (n:Label) ON (n.property)
        if (self.cur.kind == .FOR) {
            self.advance();

            // Parse pattern: (n:Label) or ()-[r:RelType]-()
            if (self.cur.kind != .l_paren) return error.UnexpectedToken;
            self.advance();

            // Check for relationship pattern: ()-[r:RelType]-()
            if (self.cur.kind == .r_paren) {
                // ()-[r:RelType]-() syntax for relationship indexes
                self.advance(); // consume )
                if (self.cur.kind != .minus) return error.UnexpectedToken;
                self.advance(); // consume -
                if (self.cur.kind != .l_bracket) return error.UnexpectedToken;
                self.advance(); // consume [

                // Variable name
                if (self.cur.kind != .identifier) return error.UnexpectedToken;
                pattern_variable = self.cur.lexeme;
                self.advance();

                // :RelType
                if (self.cur.kind != .colon) return error.UnexpectedToken;
                self.advance();
                if (self.cur.kind != .identifier) return error.UnexpectedToken;
                label = self.cur.lexeme;
                self.advance();

                // Close bracket and remaining pattern: ]-()
                if (self.cur.kind != .r_bracket) return error.UnexpectedToken;
                self.advance(); // consume ]
                if (self.cur.kind != .minus) return error.UnexpectedToken;
                self.advance(); // consume -
                if (self.cur.kind != .l_paren) return error.UnexpectedToken;
                self.advance(); // consume (
                if (self.cur.kind != .r_paren) return error.UnexpectedToken;
                self.advance(); // consume ) - end of pattern
            } else {
                // Node pattern: (n:Label)
                if (self.cur.kind != .identifier) return error.UnexpectedToken;
                pattern_variable = self.cur.lexeme;
                self.advance();

                if (self.cur.kind != .colon) return error.UnexpectedToken;
                self.advance();

                if (self.cur.kind != .identifier) return error.UnexpectedToken;
                label = self.cur.lexeme;
                self.advance();

                if (self.cur.kind != .r_paren) return error.UnexpectedToken;
                self.advance();
            }

            // ON keyword
            if (self.cur.kind != .ON) return error.UnexpectedToken;
            self.advance();
        } else {
            // Legacy syntax: ON Label or ON :Label
            if (self.cur.kind != .ON) return error.UnexpectedToken;
            self.advance();

            // Label (e.g., :Person or Person)
            // Allow keywords as label names (e.g., :SCAN, :MATCH, :NODE)
            if (self.cur.kind == .colon) {
                self.advance();
                if (self.cur.kind != .identifier and !self.isKeyword(self.cur.kind)) return error.UnexpectedToken;
                label = self.cur.lexeme;
                self.advance();
            } else if (self.cur.kind == .identifier or self.isKeyword(self.cur.kind)) {
                label = self.cur.lexeme;
                self.advance();
            } else {
                return error.UnexpectedToken;
            }
        }

        // Optional USING index_type (before properties)
        var index_type = ast.IndexType.btree;
        if (self.cur.kind == .USING) {
            self.advance();
            if (self.cur.kind == .identifier) {
                const type_str = self.cur.lexeme;
                if (std.ascii.eqlIgnoreCase(type_str, "btree") or std.ascii.eqlIgnoreCase(type_str, "BTree")) {
                    index_type = .btree;
                } else if (std.ascii.eqlIgnoreCase(type_str, "hash") or std.ascii.eqlIgnoreCase(type_str, "Hash")) {
                    index_type = .hash;
                } else if (std.ascii.eqlIgnoreCase(type_str, "fulltext") or std.ascii.eqlIgnoreCase(type_str, "FullText")) {
                    index_type = .fulltext;
                } else if (std.ascii.eqlIgnoreCase(type_str, "spatial") or std.ascii.eqlIgnoreCase(type_str, "RTree")) {
                    index_type = .spatial;
                } else if (std.ascii.eqlIgnoreCase(type_str, "vector") or std.ascii.eqlIgnoreCase(type_str, "HNSW")) {
                    index_type = .vector;
                } else if (std.ascii.eqlIgnoreCase(type_str, "vector_f32")) {
                    index_type = .vector_f32;
                } else if (std.ascii.eqlIgnoreCase(type_str, "spatial_geographic")) {
                    index_type = .spatial_geographic;
                } else if (std.ascii.eqlIgnoreCase(type_str, "network_cidr") or std.ascii.eqlIgnoreCase(type_str, "PatriciaTrie") or std.ascii.eqlIgnoreCase(type_str, "trie")) {
                    index_type = .network_cidr;
                } else if (std.ascii.eqlIgnoreCase(type_str, "signature_crypto")) {
                    index_type = .signature_crypto;
                } else if (std.ascii.eqlIgnoreCase(type_str, "IntervalTree")) {
                    // IntervalTree - temporal/interval index (map to btree for now)
                    index_type = .btree;
                } else if (std.ascii.eqlIgnoreCase(type_str, "JsonbInverted")) {
                    // JsonbInverted - JSONB GIN-style index (map to btree for now)
                    index_type = .btree;
                } else if (std.ascii.eqlIgnoreCase(type_str, "DomainTrie")) {
                    // DomainTrie - domain name trie (map to btree for now)
                    index_type = .btree;
                } else {
                    // Reject unrecognized index types
                    return error.InvalidIndexType;
                }
                self.advance();
            }
        }

        // Properties in parentheses
        if (self.cur.kind != .l_paren) return error.UnexpectedToken;
        self.advance();

        // GAP-0220 FIX: Use try for proper error propagation
        var properties = try std.ArrayList([]const u8).initCapacity(self.arena.allocator(), 1);

        // Parse properties - handle both (property) and (n.property) syntax
        // CANARY: REQ=REQ-GQL-084; FEATURE="CreateIndexKeywordProperties"; ASPECT=ParserSupport; STATUS=TESTED; OWNER=parser; UPDATED=2025-10-14
        while (true) {
            // Allow keywords as property names (common case: "value", "type", etc.)
            if (self.cur.kind != .identifier and !self.isKeyword(self.cur.kind)) return error.UnexpectedToken;

            // Check for qualified property (n.property)
            if (pattern_variable != null) {
                const first_part = self.cur.lexeme;
                self.advance();

                // Check for dot
                if (self.cur.kind == .dot) {
                    self.advance();
                    // Allow keywords as property names after dot
                    if (self.cur.kind != .identifier and !self.isKeyword(self.cur.kind)) return error.UnexpectedToken;
                    // Use the property name after the dot
                    try properties.append(self.arena.allocator(), self.cur.lexeme);
                    self.advance();
                } else {
                    // No dot, use the identifier as-is (fallback for unqualified)
                    try properties.append(self.arena.allocator(), first_part);
                }
            } else {
                // Unqualified property
                try properties.append(self.arena.allocator(), self.cur.lexeme);
                self.advance();
            }

            // Check for more properties
            if (self.cur.kind == .comma) {
                self.advance();
            } else {
                break;
            }
        }

        if (self.cur.kind != .r_paren) return error.UnexpectedToken;
        self.advance();

        // Optional USING index_type (after properties) - Neo4j/Cypher syntax
        if (self.cur.kind == .USING) {
            self.advance();
            if (self.cur.kind == .identifier) {
                const type_str = self.cur.lexeme;
                if (std.ascii.eqlIgnoreCase(type_str, "btree") or std.ascii.eqlIgnoreCase(type_str, "BTree")) {
                    index_type = .btree;
                } else if (std.ascii.eqlIgnoreCase(type_str, "hash") or std.ascii.eqlIgnoreCase(type_str, "Hash")) {
                    index_type = .hash;
                } else if (std.ascii.eqlIgnoreCase(type_str, "fulltext") or std.ascii.eqlIgnoreCase(type_str, "FullText")) {
                    index_type = .fulltext;
                } else if (std.ascii.eqlIgnoreCase(type_str, "spatial") or std.ascii.eqlIgnoreCase(type_str, "RTree")) {
                    index_type = .spatial;
                } else if (std.ascii.eqlIgnoreCase(type_str, "vector") or std.ascii.eqlIgnoreCase(type_str, "HNSW")) {
                    index_type = .vector;
                } else if (std.ascii.eqlIgnoreCase(type_str, "vector_f32")) {
                    index_type = .vector_f32;
                } else if (std.ascii.eqlIgnoreCase(type_str, "spatial_geographic")) {
                    index_type = .spatial_geographic;
                } else if (std.ascii.eqlIgnoreCase(type_str, "network_cidr") or std.ascii.eqlIgnoreCase(type_str, "PatriciaTrie") or std.ascii.eqlIgnoreCase(type_str, "trie")) {
                    index_type = .network_cidr;
                } else if (std.ascii.eqlIgnoreCase(type_str, "signature_crypto")) {
                    index_type = .signature_crypto;
                } else if (std.ascii.eqlIgnoreCase(type_str, "IntervalTree")) {
                    index_type = .btree;
                } else if (std.ascii.eqlIgnoreCase(type_str, "JsonbInverted")) {
                    index_type = .btree;
                } else if (std.ascii.eqlIgnoreCase(type_str, "DomainTrie")) {
                    index_type = .btree;
                } else {
                    // Reject unrecognized index types
                    return error.InvalidIndexType;
                }
                self.advance();
            }
        }

        // Optional WITH clause for index parameters (parse but ignore for now)
        if (self.cur.kind == .WITH) {
            self.advance();
            if (self.cur.kind == .l_paren) {
                self.advance();
                // Skip parameters until closing paren
                var paren_depth: u32 = 1;
                while (paren_depth > 0 and self.cur.kind != .eof) {
                    if (self.cur.kind == .l_paren) {
                        paren_depth += 1;
                    } else if (self.cur.kind == .r_paren) {
                        paren_depth -= 1;
                    }
                    if (paren_depth > 0) self.advance();
                }
                if (self.cur.kind == .r_paren) {
                    self.advance();
                }
            }
        }

        // Optional OPTIONS clause (alternative to USING/WITH)
        if (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "OPTIONS")) {
            self.advance();
            if (self.cur.kind == .l_brace) {
                self.advance();
                // Skip options until closing brace
                var brace_depth: u32 = 1;
                while (brace_depth > 0 and self.cur.kind != .eof) {
                    if (self.cur.kind == .l_brace) {
                        brace_depth += 1;
                    } else if (self.cur.kind == .r_brace) {
                        brace_depth -= 1;
                    }
                    if (brace_depth > 0) self.advance();
                }
                if (self.cur.kind == .r_brace) {
                    self.advance();
                }
            }
        }

        return .{ .CreateIndex = .{
            .name = name,
            .unique = unique,
            .index_type = index_type,
            .label = label,
            .properties = try properties.toOwnedSlice(self.arena.allocator()),
            .if_not_exists = if_not_exists,
        } };
    }

    // Parse CREATE CONSTRAINT statement
    fn parseCreateConstraint(self: *Parser) ParserError!ast.Statement {
        // Optional IF NOT EXISTS
        var if_not_exists = false;
        if (self.cur.kind == .IF) {
            self.advance();
            if (self.cur.kind == .NOT) {
                self.advance();
                if (self.cur.kind == .EXISTS) {
                    self.advance();
                    if_not_exists = true;
                } else {
                    return error.UnexpectedToken;
                }
            } else {
                return error.UnexpectedToken;
            }
        }

        // Constraint name (required)
        if (self.cur.kind != .identifier) return error.UnexpectedToken;
        const name = self.cur.lexeme;
        self.advance();

        var label: []const u8 = "";
        // GAP-0220 FIX: Use try for proper error propagation
        var properties = try std.ArrayList([]const u8).initCapacity(self.arena.allocator(), 1);
        var constraint_type: ast.ConstraintType = .unique;

        // Check for ISO GQL syntax: FOR (n:Label) REQUIRE ...
        if (self.cur.kind == .FOR) {
            self.advance();

            // Parse pattern: (n:Label)
            if (self.cur.kind != .l_paren) return error.UnexpectedToken;
            self.advance();

            // Variable name
            if (self.cur.kind != .identifier) return error.UnexpectedToken;
            const pattern_var = self.cur.lexeme;
            self.advance();

            // :Label
            if (self.cur.kind != .colon) return error.UnexpectedToken;
            self.advance();

            if (self.cur.kind != .identifier) return error.UnexpectedToken;
            label = self.cur.lexeme;
            self.advance();

            if (self.cur.kind != .r_paren) return error.UnexpectedToken;
            self.advance();

            // REQUIRE keyword
            if (self.cur.kind != .REQUIRE) return error.UnexpectedToken;
            self.advance();

            // Parse constraint condition
            constraint_type = try self.parseConstraintCondition(pattern_var, &properties);
        } else {
            // Legacy syntax: ON :Label ASSERT ...
            if (self.cur.kind != .ON) return error.UnexpectedToken;
            self.advance();

            // :Label or Label
            if (self.cur.kind == .colon) {
                self.advance();
                if (self.cur.kind != .identifier) return error.UnexpectedToken;
                label = self.cur.lexeme;
                self.advance();
            } else if (self.cur.kind == .identifier) {
                label = self.cur.lexeme;
                self.advance();
            } else {
                return error.UnexpectedToken;
            }

            // ASSERT keyword
            if (self.cur.kind != .ASSERT) return error.UnexpectedToken;
            self.advance();

            // Parse constraint condition (legacy format)
            constraint_type = try self.parseConstraintConditionLegacy(&properties);
        }

        return .{ .CreateConstraint = .{
            .name = name,
            .constraint_type = constraint_type,
            .label = label,
            .properties = try properties.toOwnedSlice(self.arena.allocator()),
            .if_not_exists = if_not_exists,
        } };
    }

    // Helper: Parse REQUIRE condition (ISO GQL)
    fn parseConstraintCondition(self: *Parser, pattern_var: []const u8, properties: *std.ArrayList([]const u8)) ParserError!ast.ConstraintType {
        _ = pattern_var;

        // Check for composite constraint: (n.prop1, n.prop2)
        if (self.cur.kind == .l_paren) {
            self.advance();

            // Parse property list
            while (true) {
                if (self.cur.kind != .identifier) return error.UnexpectedToken;
                const var_name = self.cur.lexeme;
                self.advance();

                if (self.cur.kind == .dot) {
                    self.advance();
                    if (self.cur.kind != .identifier) return error.UnexpectedToken;
                    try properties.append(self.arena.allocator(), self.cur.lexeme);
                    self.advance();
                } else {
                    try properties.append(self.arena.allocator(), var_name);
                }

                if (self.cur.kind == .comma) {
                    self.advance();
                } else {
                    break;
                }
            }

            if (self.cur.kind != .r_paren) return error.UnexpectedToken;
            self.advance();

            // IS NODE KEY
            if (self.cur.kind == .IS) {
                self.advance();
                if (self.cur.kind == .NODE) {
                    self.advance();
                    if (self.cur.kind == .KEY) {
                        self.advance();
                        return .node_key;
                    }
                    return error.UnexpectedToken;
                }
                return error.UnexpectedToken;
            }
            return error.UnexpectedToken;
        }

        // Single property: n.prop IS UNIQUE / IS NOT NULL
        if (self.cur.kind != .identifier) return error.UnexpectedToken;
        const var_name = self.cur.lexeme;
        self.advance();

        if (self.cur.kind == .dot) {
            self.advance();
            if (self.cur.kind != .identifier) return error.UnexpectedToken;
            try properties.append(self.arena.allocator(), self.cur.lexeme);
            self.advance();
        } else {
            try properties.append(self.arena.allocator(), var_name);
        }

        // IS UNIQUE / IS NOT NULL
        if (self.cur.kind == .IS) {
            self.advance();

            if (self.cur.kind == .NOT) {
                self.advance();
                if (self.cur.kind == .NULL) {
                    self.advance();
                    return .not_null;
                }
                return error.UnexpectedToken;
            }

            if (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "UNIQUE")) {
                self.advance();
                return .unique;
            }
        }

        return error.UnexpectedToken;
    }

    // Helper: Parse ASSERT condition (Legacy)
    fn parseConstraintConditionLegacy(self: *Parser, properties: *std.ArrayList([]const u8)) ParserError!ast.ConstraintType {
        // EXISTS (prop) - property existence
        if (self.cur.kind == .EXISTS) {
            self.advance();
            if (self.cur.kind != .l_paren) return error.UnexpectedToken;
            self.advance();

            if (self.cur.kind != .identifier) return error.UnexpectedToken;
            try properties.append(self.arena.allocator(), self.cur.lexeme);
            self.advance();

            if (self.cur.kind != .r_paren) return error.UnexpectedToken;
            self.advance();

            return .exists;
        }

        // (prop) IS NODE KEY or (prop1, prop2, ...) IS NODE KEY
        if (self.cur.kind == .l_paren) {
            self.advance();

            // Parse property list
            while (true) {
                if (self.cur.kind != .identifier) return error.UnexpectedToken;
                try properties.append(self.arena.allocator(), self.cur.lexeme);
                self.advance();

                if (self.cur.kind == .comma) {
                    self.advance();
                } else {
                    break;
                }
            }

            if (self.cur.kind != .r_paren) return error.UnexpectedToken;
            self.advance();

            if (self.cur.kind == .IS) {
                self.advance();
                if (self.cur.kind == .NODE) {
                    self.advance();
                    if (self.cur.kind == .KEY) {
                        self.advance();
                        return .node_key;
                    }
                    return error.UnexpectedToken;
                }
                if (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "UNIQUE")) {
                    self.advance();
                    return .unique;
                }
                return error.UnexpectedToken;
            }
            return error.UnexpectedToken;
        }

        // prop IS UNIQUE
        if (self.cur.kind == .identifier) {
            try properties.append(self.arena.allocator(), self.cur.lexeme);
            self.advance();

            if (self.cur.kind == .IS) {
                self.advance();
                if (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "UNIQUE")) {
                    self.advance();
                    return .unique;
                }
            }
        }

        return error.UnexpectedToken;
    }

    // Parse SHOW statement
    fn parseShowStatement(self: *Parser) ParserError!ast.Statement {
        _ = try self.expect(.SHOW);

        // Determine what to show based on next token
        const show_type: ast.ShowType = if (self.cur.kind == .identifier) blk: {
            const type_str = self.cur.lexeme;
            self.advance();

            if (std.ascii.eqlIgnoreCase(type_str, "INDEXES") or
                std.ascii.eqlIgnoreCase(type_str, "INDEX"))
            {
                break :blk .indexes;
            } else if (std.ascii.eqlIgnoreCase(type_str, "CONSTRAINTS") or
                std.ascii.eqlIgnoreCase(type_str, "CONSTRAINT"))
            {
                break :blk .constraints;
            } else if (std.ascii.eqlIgnoreCase(type_str, "TABLES") or
                std.ascii.eqlIgnoreCase(type_str, "TABLE"))
            {
                break :blk .tables;
            } else if (std.ascii.eqlIgnoreCase(type_str, "GRAPHS") or
                std.ascii.eqlIgnoreCase(type_str, "GRAPH"))
            {
                break :blk .graphs;
            } else if (std.ascii.eqlIgnoreCase(type_str, "PROCEDURES") or
                std.ascii.eqlIgnoreCase(type_str, "PROCEDURE"))
            {
                break :blk .procedures;
            } else if (std.ascii.eqlIgnoreCase(type_str, "FUNCTIONS") or
                std.ascii.eqlIgnoreCase(type_str, "FUNCTION"))
            {
                break :blk .functions;
            } else {
                return error.UnexpectedToken;
            }
        } else {
            return error.UnexpectedToken;
        };

        return .{ .Show = .{ .show_type = show_type } };
    }

    fn parseValuesStatement(self: *Parser) ParserError!ast.Statement {
        _ = try self.expect(.VALUES);

        // Parse rows: (expr1), (expr2), ...
        var rows_list = std.ArrayList([]ast.Expr).empty;

        while (true) {
            // Expect opening paren for row
            _ = try self.expect(.l_paren);

            // Parse expressions in this row
            var row_exprs = std.ArrayList(ast.Expr).empty;

            // Parse first expression
            const first_expr = try self.parseOrExpr();
            try row_exprs.append(self.arena.allocator(), first_expr);

            // Parse additional expressions (if multi-column)
            while (self.cur.kind == .comma) {
                self.advance();
                const expr = try self.parseOrExpr();
                try row_exprs.append(self.arena.allocator(), expr);
            }

            _ = try self.expect(.r_paren);

            try rows_list.append(self.arena.allocator(), try row_exprs.toOwnedSlice(self.arena.allocator()));

            // Check for more rows
            if (self.cur.kind == .comma) {
                self.advance();
                continue;
            }
            break;
        }

        // Expect AS keyword
        _ = try self.expect(.AS);

        // Parse column names: (col1, col2, ...)
        _ = try self.expect(.l_paren);

        var column_names = std.ArrayList([]const u8).empty;

        // Parse first column name
        if (self.cur.kind != .identifier) return self.unexpected("expected column name after AS (");
        try column_names.append(self.arena.allocator(), self.cur.lexeme);
        self.advance();

        // Parse additional column names
        while (self.cur.kind == .comma) {
            self.advance();
            if (self.cur.kind != .identifier) return self.unexpected("expected column name");
            try column_names.append(self.arena.allocator(), self.cur.lexeme);
            self.advance();
        }

        _ = try self.expect(.r_paren);

        // Parse continuation (RETURN, MATCH, etc.)
        var next_stmt: ?*ast.Statement = null;
        if (self.cur.kind != .eof and self.cur.kind != .semicolon) {
            const stmt_ptr = try self.arena.allocator().create(ast.Statement);
            stmt_ptr.* = try self.parseStatement();
            next_stmt = stmt_ptr;
        }

        return .{ .Values = .{
            .rows = try rows_list.toOwnedSlice(self.arena.allocator()),
            .column_names = try column_names.toOwnedSlice(self.arena.allocator()),
            .next_statement = next_stmt,
        } };
    }

    fn parseForStatement(self: *Parser) ParserError!ast.Statement {
        _ = try self.expect(.FOR);

        // Parse iteration variable: FOR item IN ...
        if (self.cur.kind != .identifier) return self.unexpected("expected identifier after FOR");
        const variable = self.cur.lexeme;
        self.advance();

        // Expect IN keyword
        _ = try self.expect(.IN);

        // Parse collection expression (list, variable reference, etc.)
        const collection = try self.parseOrExpr();

        // Check for WITH ORDINALITY or WITH OFFSET
        var ordinality_var: ?[]const u8 = null;
        var offset_var: ?[]const u8 = null;

        if (self.cur.kind == .WITH) {
            self.advance();
            if (self.cur.kind == .ORDINALITY) {
                self.advance();
                // Expect variable name after ORDINALITY
                if (self.cur.kind != .identifier) return self.unexpected("expected identifier after ORDINALITY");
                ordinality_var = self.cur.lexeme;
                self.advance();
            } else if (self.cur.kind == .OFFSET) {
                self.advance();
                // Expect variable name after OFFSET
                if (self.cur.kind != .identifier) return self.unexpected("expected identifier after OFFSET");
                offset_var = self.cur.lexeme;
                self.advance();
            } else {
                return self.unexpected("expected ORDINALITY or OFFSET after WITH");
            }
        }

        // Expect RETURN clause
        _ = try self.expect(.RETURN);

        // Parse RETURN clause
        const distinct = if (self.cur.kind == .DISTINCT) blk: {
            self.advance();
            break :blk true;
        } else false;

        var return_items = std.ArrayList(ast.ReturnItem).empty;
        try self.parseProjectionItems(&return_items);

        const return_clause = ast.ReturnClause{
            .items = try return_items.toOwnedSlice(self.arena.allocator()),
            .distinct = distinct,
        };

        // Optional ORDER BY
        var order_by: ?ast.OrderBy = null;
        if (self.cur.kind == .ORDER) {
            self.advance();
            _ = try self.expect(.BY);
            var keys = std.ArrayList(ast.OrderBy.OrderKey).empty;

            // Parse first key
            const expr1 = try self.parseOrExpr();
            const mods1 = try self.parseOrderKeyModifiers();
            try keys.append(self.arena.allocator(), .{ .expr = expr1, .desc = mods1.desc, .nulls = mods1.nulls });

            // Parse additional keys
            while (self.cur.kind == .comma) {
                self.advance();
                const exprk = try self.parseOrExpr();
                const modsk = try self.parseOrderKeyModifiers();
                try keys.append(self.arena.allocator(), .{ .expr = exprk, .desc = modsk.desc, .nulls = modsk.nulls });
            }
            order_by = .{ .keys = try keys.toOwnedSlice(self.arena.allocator()) };
        }

        // Optional LIMIT
        var limit: ?usize = null;
        var limit_param: ?[]const u8 = null;
        if (self.cur.kind == .LIMIT) {
            self.advance();
            const lim = try self.parseLimitValue();
            limit = if (lim.value) |v| @as(usize, @intCast(v)) else null;
            limit_param = lim.param;
        }

        // Optional OFFSET
        var offset: ?usize = null;
        var offset_param: ?[]const u8 = null;
        if (self.cur.kind == .OFFSET or self.cur.kind == .SKIP) {
            self.advance();
            const off = try self.parseLimitValue();
            offset = if (off.value) |v| @as(usize, @intCast(v)) else null;
            offset_param = off.param;
        }

        return .{ .For = .{
            .variable = variable,
            .collection = collection,
            .ordinality_var = ordinality_var,
            .offset_var = offset_var,
            .return_clause = return_clause,
            .order_by = order_by,
            .limit = limit,
            .offset = offset,
            .limit_param = limit_param,
            .offset_param = offset_param,
        } };
    }

    fn parseExplainStatement(self: *Parser) ParserError!ast.Statement {
        _ = try self.expect(.EXPLAIN);

        // Parse the query to explain
        const query_stmt_ptr = try self.arena.allocator().create(ast.Statement);
        query_stmt_ptr.* = try self.parseStatement();

        return .{ .Explain = .{ .query = query_stmt_ptr } };
    }

    fn parseProfileStatement(self: *Parser) ParserError!ast.Statement {
        _ = try self.expect(.PROFILE);

        // Parse the query to profile
        const query_stmt_ptr = try self.arena.allocator().create(ast.Statement);
        query_stmt_ptr.* = try self.parseStatement();

        return .{ .Profile = .{ .query = query_stmt_ptr } };
    }

    // Parse DROP statement (DROP INDEX, DROP SCHEMA, DROP GRAPH, etc.)
    fn parseDropStatement(self: *Parser) ParserError!ast.Statement {
        _ = try self.expect(.DROP);

        // Check if this is DROP INDEX
        if (self.cur.kind == .INDEX or
            (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "INDEX")))
        {
            return self.parseDropIndex();
        }

        // Check if this is DROP SCHEMA
        if (self.cur.kind == .SCHEMA) {
            return self.parseDropSchema();
        }

        // Check if this is DROP GRAPH or DROP PROPERTY GRAPH
        if (self.cur.kind == .GRAPH or
            self.cur.kind == .PROPERTY or
            (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "PROPERTY")))
        {
            // For now, let the individual functions handle TYPE detection
            return self.parseDropGraph();
        }

        // Check if this is DROP CONSTRAINT
        if (self.cur.kind == .CONSTRAINT) {
            return self.parseDropConstraint();
        }

        // Future: handle DROP DATABASE, etc.
        return error.UnexpectedToken;
    }

    // Parse DROP INDEX statement
    fn parseDropIndex(self: *Parser) ParserError!ast.Statement {
        // Expect INDEX keyword
        if (self.cur.kind == .INDEX) {
            self.advance();
        } else if (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "INDEX")) {
            self.advance();
        } else {
            return error.UnexpectedToken;
        }

        // Optional IF EXISTS
        var if_exists = false;
        if (self.cur.kind == .IF) {
            self.advance();
            if (self.cur.kind == .EXISTS) {
                self.advance();
                if_exists = true;
            } else {
                return error.UnexpectedToken;
            }
        }

        // Index name
        if (self.cur.kind != .identifier) return error.UnexpectedToken;
        const name = self.cur.lexeme;
        self.advance();

        return .{ .DropIndex = .{
            .name = name,
            .if_exists = if_exists,
        } };
    }

    // Parse DROP CONSTRAINT statement
    fn parseDropConstraint(self: *Parser) ParserError!ast.Statement {
        // Expect CONSTRAINT keyword
        if (self.cur.kind == .CONSTRAINT) {
            self.advance();
        } else {
            return error.UnexpectedToken;
        }

        // Optional IF EXISTS
        var if_exists = false;
        if (self.cur.kind == .IF) {
            self.advance();
            if (self.cur.kind == .EXISTS) {
                self.advance();
                if_exists = true;
            } else {
                return error.UnexpectedToken;
            }
        }

        // Constraint name
        if (self.cur.kind != .identifier) return error.UnexpectedToken;
        const name = self.cur.lexeme;
        self.advance();

        return .{ .DropConstraint = .{
            .name = name,
            .if_exists = if_exists,
        } };
    }

    // Parse CREATE SCHEMA statement
    fn parseCreateSchema(self: *Parser) ParserError!ast.Statement {
        _ = try self.expect(.SCHEMA);

        // Optional IF NOT EXISTS
        var if_not_exists = false;
        if (self.cur.kind == .IF) {
            self.advance();
            if (self.cur.kind == .NOT) {
                self.advance();
                if (self.cur.kind == .EXISTS) {
                    self.advance();
                    if_not_exists = true;
                } else {
                    return error.UnexpectedToken;
                }
            } else {
                return error.UnexpectedToken;
            }
        }

        // Schema name
        if (self.cur.kind != .identifier) return error.UnexpectedToken;
        const name = self.cur.lexeme;
        self.advance();

        return .{ .CreateSchema = .{
            .name = name,
            .if_not_exists = if_not_exists,
        } };
    }

    // Parse CREATE GRAPH statement with optional OR REPLACE
    fn parseCreateGraphWithReplace(self: *Parser, or_replace: bool) ParserError!ast.Statement {
        var property_graph = true;

        // Check for PROPERTY keyword
        if (self.cur.kind == .PROPERTY or
            (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "PROPERTY")))
        {
            self.advance();
            property_graph = true;
        }

        // Expect GRAPH keyword
        if (self.cur.kind != .GRAPH) return error.UnexpectedToken;
        self.advance();

        // Optional IF NOT EXISTS
        var if_not_exists = false;
        if (self.cur.kind == .IF) {
            self.advance();
            if (self.cur.kind == .NOT) {
                self.advance();
                if (self.cur.kind == .EXISTS) {
                    self.advance();
                    if_not_exists = true;
                } else {
                    return error.UnexpectedToken;
                }
            } else {
                return error.UnexpectedToken;
            }
        }

        // Check for TYPE (graph type creation) immediately after GRAPH (and optional IF NOT EXISTS)
        if (self.cur.kind == .TYPE or
            (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "TYPE")))
        {
            // This is CREATE [PROPERTY] GRAPH TYPE
            // TYPE is already detected, don't consume it here - let parseCreateGraphType handle it
            return self.parseCreateGraphType(or_replace, property_graph);
        }

        // Graph name (for regular CREATE GRAPH statements)
        // Support qualified names: schema.graph or just graph
        if (self.cur.kind != .identifier) return error.UnexpectedToken;
        var name = self.cur.lexeme;
        self.advance();

        // Check for qualified name (schema.graph)
        if (self.cur.kind == .dot) {
            self.advance(); // consume dot
            if (self.cur.kind != .identifier) return error.UnexpectedToken;
            // Concatenate schema.graph
            const graph_part = self.cur.lexeme;
            const qualified_name = try std.fmt.allocPrint(self.arena.allocator(), "{s}.{s}", .{ name, graph_part });
            name = qualified_name;
            self.advance();
        }

        // Initialize optional fields
        var typed_spec: ?[]const u8 = null;
        var like_source: ?[]const u8 = null;
        var copy_source: ?[]const u8 = null;

        // Check for TYPED clause
        if (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "TYPED")) {
            self.advance(); // Skip TYPED
            // Expect type specification
            if (self.cur.kind == .identifier) {
                typed_spec = self.cur.lexeme;
                self.advance();
            } else if (self.cur.kind == .ANY) {
                typed_spec = "ANY";
                self.advance();
            } else {
                return error.UnexpectedToken;
            }
            // Optional PROPERTY GRAPH after type spec
            if (self.cur.kind == .PROPERTY or
                (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "PROPERTY")))
            {
                self.advance();
                if (self.cur.kind == .GRAPH) {
                    self.advance();
                }
            }
        }
        // Check for ANY keyword (without TYPED)
        else if (self.cur.kind == .ANY) {
            self.advance();
            // Optional PROPERTY GRAPH keywords after ANY
            if (self.cur.kind == .PROPERTY or
                (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "PROPERTY")))
            {
                self.advance();
                if (self.cur.kind == .GRAPH) {
                    self.advance();
                }
            } else if (self.cur.kind == .GRAPH) {
                self.advance();
            }
        }
        // Check for LIKE clause first (independent of TYPED/ANY)
        else if (self.cur.kind == .LIKE) {
            self.advance(); // Skip LIKE
            if (self.cur.kind == .identifier) {
                like_source = self.cur.lexeme;
                self.advance();
            } else {
                return error.UnexpectedToken;
            }
        }

        // Check for AS COPY OF clause (can be combined with TYPED/ANY but not LIKE)
        if (self.cur.kind == .AS and like_source == null) {
            self.advance(); // Skip AS
            if (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "COPY")) {
                self.advance(); // Skip COPY
                if (self.cur.kind == .OF or
                    (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "OF")))
                {
                    self.advance(); // Skip OF
                    if (self.cur.kind == .identifier) {
                        copy_source = self.cur.lexeme;
                        self.advance();
                    } else {
                        return error.UnexpectedToken;
                    }
                } else {
                    return error.UnexpectedToken;
                }
            } else {
                return error.UnexpectedToken;
            }
        }

        return .{ .CreateGraph = .{
            .name = name,
            .if_not_exists = if_not_exists,
            .or_replace = or_replace,
            .property_graph = property_graph,
            .typed_spec = typed_spec,
            .like_source = like_source,
            .copy_source = copy_source,
        } };
    }

    // Parse CREATE GRAPH statement (wrapper for compatibility)
    fn parseCreateGraph(self: *Parser) ParserError!ast.Statement {
        return self.parseCreateGraphWithReplace(false);
    }

    // Parse CREATE GRAPH TYPE statement
    // Field-Level Encryption Parser Extensions
    // CANARY: REQ=REQ-FLE-PARSER-001; FEATURE="FieldLevelEncryption"; ASPECT=PARSER; STATUS=TESTED; TEST=tests/test_tde_kms_integration.zig; OWNER=security; UPDATED=2026-01-15

    /// Parse field definitions within graph type: { field1 TYPE, field2 TYPE @annotations, ... }
    fn parseFieldDefinitions(self: *Parser) ParserError![]ast.FieldDefinition {
        _ = try self.expect(.l_brace); // Consume opening brace

        var fields = std.ArrayList(ast.FieldDefinition).empty;

        // Parse fields until we hit closing brace
        while (self.cur.kind != .r_brace and self.cur.kind != .eof) {
            // Field name
            if (self.cur.kind != .identifier) return error.UnexpectedToken;
            const field_name = self.cur.lexeme;
            self.advance();

            // Field type (required)
            if (self.cur.kind != .identifier) return error.UnexpectedToken;
            const type_name = self.cur.lexeme;
            self.advance();

            // Optional PRIMARY KEY
            var primary_key = false;
            if (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "PRIMARY")) {
                self.advance();
                if (self.cur.kind == .KEY or (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "KEY"))) {
                    self.advance();
                    primary_key = true;
                }
            }

            // Parse annotations (e.g., @encrypted(...), @searchable(...))
            var annotations = std.ArrayList(ast.FieldAnnotation).empty;
            while (self.cur.kind == .at) {
                // Track start of annotation (@)
                const at_lexeme = self.cur.lexeme;
                const annotation_start = @intFromPtr(at_lexeme.ptr) - @intFromPtr(self.lx.src.ptr);
                self.advance(); // Skip @

                // Annotation name
                if (self.cur.kind != .identifier) return error.UnexpectedToken;
                const annot_name = self.cur.lexeme;
                var annotation_end = @intFromPtr(annot_name.ptr) - @intFromPtr(self.lx.src.ptr) + annot_name.len;
                self.advance();

                // Annotation parameters (optional)
                if (self.cur.kind == .l_paren) {
                    self.advance(); // Skip opening paren

                    // Skip until matching closing paren
                    var paren_count: i32 = 1;
                    while (paren_count > 0 and self.cur.kind != .eof) {
                        if (self.cur.kind == .l_paren) {
                            paren_count += 1;
                        } else if (self.cur.kind == .r_paren) {
                            paren_count -= 1;
                        }
                        annotation_end = @intFromPtr(self.cur.lexeme.ptr) - @intFromPtr(self.lx.src.ptr) + self.cur.lexeme.len;
                        if (paren_count > 0) {
                            self.advance();
                        }
                    }

                    if (paren_count != 0) return error.UnexpectedToken;
                    self.advance(); // Skip closing paren
                }

                // Extract full annotation text from source
                const annot_text = self.lx.src[annotation_start..annotation_end];

                try annotations.append(self.arena.allocator(), .{
                    .name = annot_name,
                    .text = annot_text,
                });
            }

            // Add field definition
            try fields.append(self.arena.allocator(), .{
                .name = field_name,
                .type_name = type_name,
                .nullable = true, // Default to nullable
                .primary_key = primary_key,
                .annotations = try annotations.toOwnedSlice(self.arena.allocator()),
            });

            // Expect comma or closing brace
            if (self.cur.kind == .comma) {
                self.advance();
                // Allow trailing comma before closing brace
                if (self.cur.kind == .r_brace) break;
            } else if (self.cur.kind == .r_brace) {
                break;
            } else {
                return error.UnexpectedToken;
            }
        }

        _ = try self.expect(.r_brace); // Consume closing brace

        return try fields.toOwnedSlice(self.arena.allocator());
    }

    fn parseCreateGraphType(self: *Parser, or_replace: bool, property_graph: bool) ParserError!ast.Statement {
        // Expect TYPE keyword
        if (self.cur.kind != .TYPE and
            !(self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "TYPE")))
        {
            return error.UnexpectedToken;
        }
        self.advance();

        // Optional IF NOT EXISTS
        var if_not_exists = false;
        if (self.cur.kind == .IF) {
            self.advance();
            if (self.cur.kind == .NOT) {
                self.advance();
                if (self.cur.kind == .EXISTS) {
                    self.advance();
                    if_not_exists = true;
                } else {
                    return error.UnexpectedToken;
                }
            } else {
                return error.UnexpectedToken;
            }
        }

        // Graph type name
        if (self.cur.kind != .identifier) return error.UnexpectedToken;
        const name = self.cur.lexeme;
        self.advance();

        // Initialize optional fields
        var like_source: ?[]const u8 = null;
        var copy_source: ?[]const u8 = null;
        const type_definition: []const u8 = "{ }"; // Default empty type definition

        // Check for AS keyword (COPY OF or type definition)
        if (self.cur.kind == .AS) {
            self.advance(); // Skip AS

            // Check for COPY OF
            if (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "COPY")) {
                self.advance(); // Skip COPY
                if (self.cur.kind == .OF or
                    (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "OF")))
                {
                    self.advance(); // Skip OF
                    if (self.cur.kind == .identifier) {
                        copy_source = self.cur.lexeme;
                        self.advance();
                    } else {
                        return error.UnexpectedToken;
                    }
                } else {
                    return error.UnexpectedToken;
                }
            } else {
                // This should be a type definition starting with {
                if (self.cur.kind == .l_brace) {
                    // Parse field definitions
                    const fields = try self.parseFieldDefinitions();
                    return .{
                        .CreateGraphType = .{
                            .name = name,
                            .if_not_exists = if_not_exists,
                            .or_replace = or_replace,
                            .property_graph = property_graph,
                            .type_definition = "{ }", // Keep for backward compatibility
                            .fields = fields,
                            .like_source = like_source,
                            .copy_source = copy_source,
                        },
                    };
                } else {
                    return error.UnexpectedToken;
                }
            }
        }
        // Check for LIKE clause
        else if (self.cur.kind == .LIKE) {
            self.advance(); // Skip LIKE
            if (self.cur.kind == .identifier) {
                like_source = self.cur.lexeme;
                self.advance();
            } else {
                return error.UnexpectedToken;
            }
        }

        return .{
            .CreateGraphType = .{
                .name = name,
                .if_not_exists = if_not_exists,
                .or_replace = or_replace,
                .property_graph = property_graph,
                .type_definition = type_definition,
                .fields = &.{}, // Empty fields for LIKE/COPY OF cases
                .like_source = like_source,
                .copy_source = copy_source,
            },
        };
    }

    // Parse DROP SCHEMA statement
    fn parseDropSchema(self: *Parser) ParserError!ast.Statement {
        _ = try self.expect(.SCHEMA);

        // Optional IF EXISTS
        var if_exists = false;
        if (self.cur.kind == .IF) {
            self.advance();
            if (self.cur.kind == .EXISTS) {
                self.advance();
                if_exists = true;
            } else {
                return error.UnexpectedToken;
            }
        }

        // Schema name
        if (self.cur.kind != .identifier) return error.UnexpectedToken;
        const name = self.cur.lexeme;
        self.advance();

        return .{ .DropSchema = .{
            .name = name,
            .if_exists = if_exists,
        } };
    }

    // Parse DROP GRAPH statement
    fn parseDropGraph(self: *Parser) ParserError!ast.Statement {
        var property_graph = true;

        // Check for PROPERTY keyword
        if (self.cur.kind == .PROPERTY or
            (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "PROPERTY")))
        {
            self.advance();
            property_graph = true;
        }

        // Expect GRAPH keyword
        if (self.cur.kind != .GRAPH) return error.UnexpectedToken;
        self.advance();

        // Check for TYPE keyword (DROP GRAPH TYPE)
        if (self.cur.kind == .TYPE or
            (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "TYPE")))
        {
            return self.parseDropGraphType(property_graph);
        }

        // Optional IF EXISTS
        var if_exists = false;
        if (self.cur.kind == .IF) {
            self.advance();
            if (self.cur.kind == .EXISTS) {
                self.advance();
                if_exists = true;
            } else {
                return error.UnexpectedToken;
            }
        }

        // Graph name
        // Support qualified names: schema.graph or just graph
        if (self.cur.kind != .identifier) return error.UnexpectedToken;
        var name = self.cur.lexeme;
        self.advance();

        // Check for qualified name (schema.graph)
        if (self.cur.kind == .dot) {
            self.advance(); // consume dot
            if (self.cur.kind != .identifier) return error.UnexpectedToken;
            // Concatenate schema.graph
            const graph_part = self.cur.lexeme;
            const qualified_name = try std.fmt.allocPrint(self.arena.allocator(), "{s}.{s}", .{ name, graph_part });
            name = qualified_name;
            self.advance();
        }

        return .{ .DropGraph = .{
            .name = name,
            .if_exists = if_exists,
            .property_graph = property_graph,
        } };
    }

    // Parse DROP GRAPH TYPE statement (disabled for now)
    fn parseDropGraphType(self: *Parser, property_graph: bool) ParserError!ast.Statement {
        // Expect TYPE keyword
        if (self.cur.kind != .TYPE and
            !(self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "TYPE")))
        {
            return error.UnexpectedToken;
        }
        self.advance();

        // Optional IF EXISTS
        var if_exists = false;
        if (self.cur.kind == .IF) {
            self.advance();
            if (self.cur.kind == .EXISTS) {
                self.advance();
                if_exists = true;
            } else {
                return error.UnexpectedToken;
            }
        }

        // Graph type name
        if (self.cur.kind != .identifier) return error.UnexpectedToken;
        const name = self.cur.lexeme;
        self.advance();

        return .{ .DropGraphType = .{
            .name = name,
            .if_exists = if_exists,
            .property_graph = property_graph,
        } };
    }

    // Parse BACKUP statement
    fn parseBackupStatement(self: *Parser) ParserError!ast.Statement {
        _ = try self.expect(.identifier); // Expect BACKUP

        // TO keyword or path
        if (self.cur.kind == .TO) {
            self.advance();
        }

        // Parse path as string literal
        if (self.cur.kind != .string_lit) return error.UnexpectedToken;
        const path = self.cur.lexeme;
        self.advance();

        var incremental = false;
        var compressed = false;
        var encrypted = false;
        var encryption_key: ?[]const u8 = null;

        // Parse options
        while (self.cur.kind == .WITH or self.cur.kind == .identifier) {
            if (self.cur.kind == .WITH) {
                self.advance();
            }

            if (self.cur.kind == .identifier) {
                const option = self.cur.lexeme;
                if (std.ascii.eqlIgnoreCase(option, "INCREMENTAL")) {
                    incremental = true;
                } else if (std.ascii.eqlIgnoreCase(option, "COMPRESSED")) {
                    compressed = true;
                } else if (std.ascii.eqlIgnoreCase(option, "ENCRYPTED")) {
                    encrypted = true;
                    self.advance();
                    // Optional encryption key
                    if (self.cur.kind == .string_lit) {
                        encryption_key = self.cur.lexeme;
                        self.advance();
                    }
                    continue;
                }
                self.advance();
            }
        }

        return .{ .Backup = .{
            .path = path,
            .incremental = incremental,
            .compressed = compressed,
            .encrypted = encrypted,
            .encryption_key = encryption_key,
        } };
    }

    // Parse RESTORE statement
    fn parseRestoreStatement(self: *Parser) ParserError!ast.Statement {
        _ = try self.expect(.identifier); // Expect RESTORE

        // FROM keyword or path
        if (self.cur.kind == .FROM) {
            self.advance();
        }

        // Parse path as string literal
        if (self.cur.kind != .string_lit) return error.UnexpectedToken;
        const path = self.cur.lexeme;
        self.advance();

        var timestamp: ?[]const u8 = null;
        var verify_only = false;

        // Parse options
        while (self.cur.kind == .TO or self.cur.kind == .identifier) {
            if (self.cur.kind == .TO) {
                self.advance();
                // Expect timestamp
                if (self.cur.kind == .string_lit) {
                    timestamp = self.cur.lexeme;
                    self.advance();
                }
            } else if (self.cur.kind == .identifier) {
                const option = self.cur.lexeme;
                if (std.ascii.eqlIgnoreCase(option, "VERIFY")) {
                    verify_only = true;
                    self.advance();
                    if (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "ONLY")) {
                        self.advance();
                    }
                }
            }
        }

        return .{ .Restore = .{
            .path = path,
            .timestamp = timestamp,
            .verify_only = verify_only,
        } };
    }

    // Parse SESSION SET statement with full ISO GQL syntax
    fn parseSessionSetStatement(self: *Parser) ParserError!ast.Statement {
        self.advance(); // consume SET

        // Parse the different types of SESSION SET clauses
        if (self.cur.kind == .SCHEMA) {
            self.advance();
            // Parse schema reference
            const schema_name = if (self.cur.kind == .identifier or self.cur.kind == .string_lit) blk: {
                const name = self.cur.lexeme;
                self.advance();
                break :blk name;
            } else {
                return error.UnexpectedToken;
            };

            return .{ .SessionSet = .{
                .clause_type = .{ .Schema = .{ .name = schema_name } },
            } };
        } else if (self.cur.kind == .GRAPH or self.cur.kind == .PROPERTY) {
            // Check if this is a parameter clause (GRAPH $param = ...) or graph setting (GRAPH name)
            const is_property = self.cur.kind == .PROPERTY;
            if (is_property) self.advance();

            _ = try self.expect(.GRAPH);

            // If next token is IF NOT EXISTS or a parameter ($...), parse as GRAPH parameter clause
            if (self.cur.kind == .IF or self.cur.kind == .dollar) {
                const param_name = try self.parseSessionParameterName();
                var initializer: ?[]const u8 = null;
                if (self.cur.kind == .eq) {
                    self.advance();
                    // Parse the initializer expression - accept various formats
                    if (self.cur.kind == .l_brace) {
                        // Graph literal like {} or { MATCH ... }
                        const start_idx = self.lx.idx - 1; // Include the opening brace
                        var brace_depth: u32 = 1;
                        self.advance(); // consume {
                        while (brace_depth > 0 and self.cur.kind != .eof) {
                            if (self.cur.kind == .l_brace) brace_depth += 1;
                            if (self.cur.kind == .r_brace) brace_depth -= 1;
                            self.advance();
                        }
                        const end_idx = self.lx.idx;
                        initializer = self.lx.src[start_idx..end_idx];
                    } else if (self.cur.kind == .identifier or self.cur.kind == .string_lit or self.cur.kind == .integer_lit or self.cur.kind == .TRUE or self.cur.kind == .FALSE) {
                        initializer = self.cur.lexeme;
                        self.advance();
                    }
                }

                return .{ .SessionSet = .{
                    .clause_type = .{ .Parameter = .{ .GraphParam = .{
                        .property_graph = is_property,
                        .parameter_name = param_name,
                        .initializer = initializer,
                    } } },
                } };
            }

            // Otherwise, parse as graph expression
            // Optional = before graph name (e.g., SET SESSION GRAPH = 'name')
            if (self.cur.kind == .eq) {
                self.advance();
            }

            const graph_expr = if (self.cur.kind == .identifier or self.cur.kind == .string_lit) blk: {
                const expr = self.cur.lexeme;
                self.advance();
                break :blk expr;
            } else {
                return error.UnexpectedToken;
            };

            return .{ .SessionSet = .{
                .clause_type = .{ .Graph = .{
                    .property_graph = is_property,
                    .expression = graph_expr,
                } },
            } };
        } else if (self.cur.kind == .time_lit or self.cur.kind == .TIME or
            (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "TIME")))
        {
            // Handle TIME ZONE in SESSION SET context
            // Note: "TIME" without following string literal is now lexed as .TIME keyword
            self.advance();
            _ = try self.expect(.ZONE);

            // Parse time zone value - can be string literal or LOCAL keyword
            const tz_value = if (self.cur.kind == .string_lit) blk: {
                const val = self.cur.lexeme;
                self.advance();
                break :blk val;
            } else if (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "LOCAL")) blk2: {
                const val = self.cur.lexeme;
                self.advance();
                break :blk2 val;
            } else {
                return error.UnexpectedToken;
            };

            return .{ .SessionSet = .{
                .clause_type = .{ .TimeZone = .{ .value = tz_value } },
            } };
        } else if (self.cur.kind == .VALUE or self.cur.kind == .BINDING or self.cur.kind == .TABLE) {
            // Parse parameter clauses
            return .{ .SessionSet = .{
                .clause_type = .{ .Parameter = try self.parseSessionParameterClause() },
            } };
        } else {
            return error.UnexpectedToken;
        }
    }

    // Parse SESSION RESET statement with full ISO GQL syntax
    fn parseSessionResetStatement(self: *Parser) ParserError!ast.Statement {
        self.advance(); // consume RESET

        // Parse optional reset arguments
        if (self.cur.kind == .semicolon or self.cur.kind == .eof) {
            // SESSION RESET without arguments
            return .{ .SessionReset = .{ .arguments = null } };
        }

        // Parse reset arguments
        if (self.cur.kind == .ALL) {
            self.advance();
            // Parse ALL PARAMETERS or ALL CHARACTERISTICS
            if (self.cur.kind == .identifier) {
                const type_arg = self.cur.lexeme;
                self.advance();
                if (std.ascii.eqlIgnoreCase(type_arg, "PARAMETERS")) {
                    return .{ .SessionReset = .{
                        .arguments = .{ .All = .Parameters },
                    } };
                } else if (std.ascii.eqlIgnoreCase(type_arg, "CHARACTERISTICS")) {
                    return .{ .SessionReset = .{
                        .arguments = .{ .All = .Characteristics },
                    } };
                }
            }
        } else if (self.cur.kind == .identifier) {
            const arg = self.cur.lexeme;
            if (std.ascii.eqlIgnoreCase(arg, "PARAMETERS")) {
                // SESSION RESET PARAMETERS (equivalent to ALL PARAMETERS)
                self.advance();
                return .{ .SessionReset = .{
                    .arguments = .{ .All = .Parameters },
                } };
            } else if (std.ascii.eqlIgnoreCase(arg, "PARAMETER")) {
                self.advance();
                // Parse parameter specification (with $ prefix)
                _ = try self.expect(.dollar); // Consume $
                // Allow any keyword to be used as a parameter name (like count, name, etc.)
                const param_spec = if (self.cur.kind == .string_lit) blk: {
                    const spec = self.cur.lexeme;
                    self.advance();
                    break :blk spec;
                } else blk: {
                    const token = try self.expectIdentifierOrKeyword();
                    break :blk token.lexeme;
                };

                return .{ .SessionReset = .{
                    .arguments = .{ .Parameter = param_spec },
                } };
            } else if (std.ascii.eqlIgnoreCase(arg, "TIME")) {
                // SESSION RESET TIME ZONE
                self.advance(); // consume TIME
                _ = try self.expect(.ZONE);
                return .{ .SessionReset = .{
                    .arguments = .TimeZone,
                } };
            }
        } else if (self.cur.kind == .SCHEMA) {
            self.advance();
            return .{ .SessionReset = .{
                .arguments = .Schema,
            } };
        } else if (self.cur.kind == .GRAPH or self.cur.kind == .PROPERTY) {
            // Parse [PROPERTY] GRAPH
            const property_graph = if (self.cur.kind == .PROPERTY) blk: {
                self.advance();
                _ = try self.expect(.GRAPH);
                break :blk true;
            } else blk: {
                self.advance(); // consume GRAPH
                break :blk false;
            };

            return .{ .SessionReset = .{
                .arguments = .{ .Graph = property_graph },
            } };
        } else if (self.cur.kind == .identifier and std.ascii.eqlIgnoreCase(self.cur.lexeme, "TIME")) {
            // Handle TIME ZONE
            self.advance(); // consume TIME
            _ = try self.expect(.ZONE);
            return .{ .SessionReset = .{
                .arguments = .TimeZone,
            } };
        }

        return error.UnexpectedToken;
    }

    // Parse session parameter clause (for SESSION SET parameter)
    fn parseSessionParameterClause(self: *Parser) ParserError!ast.ParameterClause {
        if (self.cur.kind == .VALUE) {
            self.advance();
            const param_name = try self.parseSessionParameterName();
            // Optional typed value initializer
            var initializer: ?[]const u8 = null;
            if (self.cur.kind == .eq) {
                self.advance();
                if (self.cur.kind == .string_lit or self.cur.kind == .identifier or self.cur.kind == .integer_lit or self.cur.kind == .TRUE or self.cur.kind == .FALSE) {
                    initializer = self.cur.lexeme;
                    self.advance();
                }
            }

            return .{ .ValueParam = .{
                .parameter_name = param_name,
                .initializer = initializer,
            } };
        } else if (self.cur.kind == .BINDING or self.cur.kind == .TABLE) {
            // [BINDING] TABLE
            if (self.cur.kind == .BINDING) {
                self.advance();
                _ = try self.expect(.TABLE);
            } else {
                self.advance(); // consume TABLE
            }

            const param_name = try self.parseSessionParameterName();
            var initializer: ?[]const u8 = null;
            if (self.cur.kind == .eq) {
                self.advance();
                // Accept various initializer formats: string, identifier, number, or braces for table literals
                if (self.cur.kind == .l_brace) {
                    // Table literal like {} or { MATCH ... }
                    const start_idx = self.lx.idx - 1; // Include the opening brace
                    var brace_depth: u32 = 1;
                    self.advance(); // consume {
                    while (brace_depth > 0 and self.cur.kind != .eof) {
                        if (self.cur.kind == .l_brace) brace_depth += 1;
                        if (self.cur.kind == .r_brace) brace_depth -= 1;
                        self.advance();
                    }
                    const end_idx = self.lx.idx;
                    initializer = self.lx.src[start_idx..end_idx];
                } else if (self.cur.kind == .string_lit or self.cur.kind == .identifier or self.cur.kind == .integer_lit or self.cur.kind == .TRUE or self.cur.kind == .FALSE) {
                    initializer = self.cur.lexeme;
                    self.advance();
                }
            }

            return .{ .BindingTableParam = .{
                .parameter_name = param_name,
                .initializer = initializer,
            } };
        } else if (self.cur.kind == .GRAPH or self.cur.kind == .PROPERTY) {
            // [PROPERTY] GRAPH parameter
            const property_graph = if (self.cur.kind == .PROPERTY) blk: {
                self.advance();
                _ = try self.expect(.GRAPH);
                break :blk true;
            } else blk: {
                self.advance(); // consume GRAPH
                break :blk false;
            };

            const param_name = try self.parseSessionParameterName();
            var initializer: ?[]const u8 = null;
            if (self.cur.kind == .eq) {
                self.advance();
                // Accept various initializer formats including braces for graph literals
                if (self.cur.kind == .l_brace) {
                    // Graph literal like {} or { MATCH ... }
                    const start_idx = self.lx.idx - 1; // Include the opening brace
                    var brace_depth: u32 = 1;
                    self.advance(); // consume {
                    while (brace_depth > 0 and self.cur.kind != .eof) {
                        if (self.cur.kind == .l_brace) brace_depth += 1;
                        if (self.cur.kind == .r_brace) brace_depth -= 1;
                        self.advance();
                    }
                    const end_idx = self.lx.idx;
                    initializer = self.lx.src[start_idx..end_idx];
                } else if (self.cur.kind == .string_lit or self.cur.kind == .identifier or self.cur.kind == .integer_lit) {
                    initializer = self.cur.lexeme;
                    self.advance();
                }
            }

            return .{ .GraphParam = .{
                .property_graph = property_graph,
                .parameter_name = param_name,
                .initializer = initializer,
            } };
        } else {
            return error.UnexpectedToken;
        }
    }

    // Parse session parameter name with optional IF NOT EXISTS
    fn parseSessionParameterName(self: *Parser) ParserError!ast.SessionParameterName {
        var if_not_exists = false;

        // Check for optional IF NOT EXISTS
        if (self.cur.kind == .IF) {
            self.advance();
            _ = try self.expect(.NOT);
            _ = try self.expect(.EXISTS);
            if_not_exists = true;
        }

        // Consume the $ token
        _ = try self.expect(.dollar);

        // Parse parameter specification (identifier or keyword after the $)
        // Allow any keyword to be used as a parameter name since it follows $
        const specification = if (self.cur.kind == .string_lit) blk: {
            const spec = self.cur.lexeme;
            self.advance();
            break :blk spec;
        } else blk: {
            const token = try self.expectIdentifierOrKeyword();
            break :blk token.lexeme;
        };

        return .{
            .if_not_exists = if_not_exists,
            .specification = specification,
        };
    }

    // Parse USE GRAPH statement
    fn parseUseStatement(self: *Parser) ParserError!ast.Statement {
        self.advance(); // consume USE

        // Optional GRAPH keyword
        if (self.cur.kind == .GRAPH) {
            self.advance();
        }

        // Expect graph name (identifier or string literal)
        const graph_name = if (self.cur.kind == .identifier or self.cur.kind == .string_lit) blk: {
            const name = self.cur.lexeme;
            self.advance();
            break :blk name;
        } else {
            return error.UnexpectedToken;
        };

        return .{ .UseGraph = .{
            .graph_name = graph_name,
        } };
    }
};

test "parser - != operator in RETURN expression" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var lx = Lexer{ .src = "RETURN 1 != 2 AS x" };
    var parser = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    const program = parser.parseProgram() catch |err| {
        std.debug.print("Parse error: {s}\n", .{@errorName(err)});
        return err;
    };
    try std.testing.expect(program.statements.len > 0);
}

test "parser - != operator in WHERE clause" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var lx = Lexer{ .src = "MATCH (n:Group) WHERE n.trust_level != 'unknown' RETURN n" };
    var parser = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    const program = parser.parseProgram() catch |err| {
        std.debug.print("Parse error: {s}\n", .{@errorName(err)});
        return err;
    };
    try std.testing.expect(program.statements.len > 0);
}

test "parser - <> operator works" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var lx = Lexer{ .src = "RETURN 1 <> 2 AS x" };
    var parser = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    const program = parser.parseProgram() catch |err| {
        std.debug.print("Parse error: {s}\n", .{@errorName(err)});
        return err;
    };
    try std.testing.expect(program.statements.len > 0);
}

// --- Regression tests for unbounded structural recursion (stack-exhaustion DoS) ---
// GQL-APPSEC-01/02/03, QUAL-002/003: deeply nested statement/query/pattern grammar
// must return a ParserError rather than overflowing the native call stack (SIGSEGV
// in ReleaseFast, panic in ReleaseSafe). Each test builds input far past the depth
// limit and asserts parseProgram returns an error instead of crashing the process.

test "parser - deeply nested CALL subqueries return error, not crash" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const depth: usize = 5000;
    var src = std.ArrayList(u8).empty;
    defer src.deinit(allocator);
    var i: usize = 0;
    while (i < depth) : (i += 1) try src.appendSlice(allocator, "CALL{");
    try src.appendSlice(allocator, "RETURN 1");
    i = 0;
    while (i < depth) : (i += 1) try src.append(allocator, '}');

    var lx = Lexer{ .src = src.items };
    var parser = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    try std.testing.expectError(error.UnexpectedToken, parser.parseProgram());
}

test "parser - deeply nested parenthesized statements return error, not crash" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const depth: usize = 5000;
    var src = std.ArrayList(u8).empty;
    defer src.deinit(allocator);
    var i: usize = 0;
    while (i < depth) : (i += 1) try src.append(allocator, '(');
    try src.appendSlice(allocator, "RETURN 1");
    i = 0;
    while (i < depth) : (i += 1) try src.append(allocator, ')');

    var lx = Lexer{ .src = src.items };
    var parser = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    try std.testing.expectError(error.UnexpectedToken, parser.parseProgram());
}

test "parser - deeply nested shortestPath patterns return error, not crash" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const depth: usize = 5000;
    var src = std.ArrayList(u8).empty;
    defer src.deinit(allocator);
    try src.appendSlice(allocator, "MATCH ");
    var i: usize = 0;
    while (i < depth) : (i += 1) try src.appendSlice(allocator, "p=shortestPath(");
    try src.appendSlice(allocator, "(a)-[]->(b)");
    i = 0;
    while (i < depth) : (i += 1) try src.append(allocator, ')');
    try src.appendSlice(allocator, " RETURN 1");

    var lx = Lexer{ .src = src.items };
    var parser = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    // Either a structural-depth error or a normal parse error is acceptable; the
    // contract is "does not crash the process".
    const result = parser.parseProgram();
    try std.testing.expectError(error.UnexpectedToken, result);
}

test "parser - moderately nested parenthesized statements within limit still parse" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // 50 levels of parenthesized statement nesting is well within the structural
    // recursion limit and must continue to parse without error.
    const depth: usize = 50;
    var src = std.ArrayList(u8).empty;
    defer src.deinit(allocator);
    var i: usize = 0;
    while (i < depth) : (i += 1) try src.append(allocator, '(');
    try src.appendSlice(allocator, "RETURN 1");
    i = 0;
    while (i < depth) : (i += 1) try src.append(allocator, ')');

    var lx = Lexer{ .src = src.items };
    var parser = Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    const program = try parser.parseProgram();
    try std.testing.expect(program.statements.len > 0);
}
