const std = @import("std");
const temporal = @import("temporal.zig");

// A very small AST subset sufficient for an initial pipeline.
pub const Program = struct { statements: []Statement };

pub const Statement = union(enum) {
    Query: Query,
    Union: UnionQuery,
    Intersect: BinarySet,
    Except: BinarySet,
    SessionSet: SessionSetStatement,
    SessionReset: SessionResetStatement,
    SessionClose,
    UseGraph: UseGraphStatement,
    StartTransaction: StartTransactionStatement,
    Commit,
    Rollback,
    // Simple DML prototype: INSERT VALUE <expr>
    InsertValue: struct { expr: Expr },
    // INSERT pattern syntax: INSERT (n:Label {props})
    Insert: InsertStatement,
    // Scan all inserted values (heap table prototype)
    ScanValues,
    // Graph mutations
    Create: CreateStatement,
    Delete: DeleteStatement,
    Merge: MergeStatement,
    // Procedure calls
    Call: CallStatement,
    // Index operations
    CreateIndex: CreateIndexStatement,
    DropIndex: DropIndexStatement,
    // Constraint operations
    CreateConstraint: CreateConstraintStatement,
    DropConstraint: DropConstraintStatement,
    Show: ShowStatement,
    // Backup operations
    Backup: BackupStatement,
    Restore: RestoreStatement,
    // Catalog operations
    CreateSchema: CreateSchemaStatement,
    DropSchema: DropSchemaStatement,
    CreateGraph: CreateGraphStatement,
    DropGraph: DropGraphStatement,
    CreateGraphType: CreateGraphTypeStatement,
    DropGraphType: DropGraphTypeStatement,
    // Query introspection
    Explain: ExplainStatement,
    Profile: ProfileStatement,
    // FOR loop iteration
    For: ForStatement,
    // VALUES table constructor
    Values: ValuesStatement,
};

/// UNWIND clause: transforms a list into multiple rows
/// UNWIND list_expr AS variable
pub const UnwindClause = struct {
    list_expr: Expr,
    variable: []const u8,
};

pub const Query = struct {
    let_bindings: []LetBinding = &.{}, // LET $var = expr bindings (before MATCH)
    inline_let_bindings: []LetBinding = &.{}, // LET var = expr bindings (after MATCH)
    optional_match: bool,
    match: GraphPattern,
    unwind_clause: ?UnwindClause = null, // UNWIND list AS var
    create_pattern: ?GraphPattern = null, // Support CREATE in queries
    where_clause: ?Expr,
    filter_clause: ?Expr = null, // FILTER clause (ISO/IEC 39075:2024)
    with_clause: ?WithClause,
    /// GAP-0082: CTEs defined via WITH [RECURSIVE] clause before the main query
    cte_list: ?CTEList = null,
    set_clauses: []SetClause = &.{},
    remove_clauses: []RemoveClause = &.{},
    delete_items: []DeleteItem = &.{},
    group_by: ?GroupBy = null,
    having: ?Expr = null,
    ret: ReturnClause,
    order_by: ?OrderBy,
    limit: ?usize,
    offset: ?usize,
    limit_param: ?[]const u8 = null,
    offset_param: ?[]const u8 = null,
    // Path variable assignment: MATCH path_var = pattern
    path_variable: ?[]const u8 = null,
    // Indicates this query is part of a WITH RECURSIVE CTE block (parser recognition only for now)
    // CANARY: REQ=REQ-GQL-079; FEATURE="RecursiveExecution"; ASPECT=ParserRecognition; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_079_ParserRecognitionNegativeCycle|TestCANARY_REQ_GQL_079_ParserRecognition; OWNER=engine; UPDATED=2025-09-26
    has_recursive_cte: bool = false,
    // True when the WITH clause originated from an initial WITH (before MATCH),
    // signaling the semantic analyzer to use additive scope instead of clearing.
    is_initial_with: bool = false,
    // CALL clause for MATCH ... CALL pattern (e.g., MATCH (n) CALL algo.bfs.stream(n) YIELD ...)
    call_clause: ?CallClause = null,
    // Query chaining: supports CREATE ... WITH ... MATCH ... pattern
    // When WITH clause is present and followed by MATCH/CREATE, the next query is stored here
    // CANARY: REQ=REQ-GQL-CHAIN; FEATURE="Query Chaining via WITH"; ASPECT=AST; STATUS=TESTED; TEST=graph_algorithms; OWNER=parser; UPDATED=2025-10-10
    next_query: ?*Query = null,
    // FOR statement that follows WITH (for queries like WITH ... FOR ... RETURN)
    for_statement: ?*ForStatement = null,
    // Initial CALL subquery for CALL { ... } WITH ... RETURN pattern
    // When set, this subquery should be executed first and its results used as input to WITH/WHERE/RETURN
    initial_call_subquery: ?*Query = null,
    // GAP #57: MERGE statement within a query chain (e.g., WITH a MERGE (b:T) RETURN ...)
    merge_statement: ?*MergeStatement = null,
};

pub const UnionQuery = struct {
    pub const Part = struct { operation: SetOperation = .union_op, all: bool, distinct: bool, query: Query };
    first: Query,
    tails: []Part,
    order_by: ?*OrderBy = null,
    limit: ?u64 = null,
    offset: ?u64 = null,
    limit_param: ?[]const u8 = null,
    offset_param: ?[]const u8 = null,
};

pub const SetOperation = enum {
    union_op,
    intersect,
    except,
};

pub const BinarySet = struct { left: Query, right: Query, all: bool = false, distinct: bool = false };

pub const Property = struct { key: []const u8, value: *Expr };

pub const NodePattern = struct {
    name: ?[]const u8,
    labels: [][]const u8,
    props: ?[]Property,
};

pub const RelDir = enum { right, left, undirected };

pub const RelPattern = struct {
    name: ?[]const u8,
    types: [][]const u8,
    props: ?[]Property,
    dir: RelDir,
    // Optional variable-length quantifier: *min..max
    // *      => min_len=0, max_len=null
    // *k     => min_len=k, max_len=k
    // *k..m  => min_len=k, max_len=m
    // *..m   => min_len=0, max_len=m
    // *k..   => min_len=k, max_len=null
    min_len: ?u32 = null,
    max_len: ?u32 = null,
};

pub const Hop = struct { left: NodePattern, rel: RelPattern, right: NodePattern };

// CANARY: REQ=REQ-GQL-PATH-MODES-001; FEATURE="GQL Path Mode Execution"; ASPECT=AST; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=parser; UPDATED=2026-01-08
/// Path mode specifiers per ISO/IEC 39075:2024
/// Controls path traversal semantics for variable-length paths
pub const PathMode = enum {
    /// Default - no restrictions on path traversal
    walk,
    /// TRAIL - edges cannot repeat (each edge visited at most once)
    trail,
    /// ACYCLIC - no repeated nodes allowed (no cycles)
    acyclic,
    /// SIMPLE - no repeated nodes except start/end may be same
    simple,
};

pub const Chain = struct {
    name: ?[]const u8 = null,
    hops: []Hop,
    // When a graph pattern chain contains only a single node pattern (no relationship hops),
    // the parser records that standalone node here so executors can perform a NodeScan.
    // For chains with one or more hops, this remains null and executors should ignore it.
    head: ?NodePattern = null,
    // Flag to indicate this is a shortestPath/allShortestPaths pattern
    // Set by parser when parsing shortestPath((pattern)) syntax
    is_shortest: bool = false,
    // CANARY: REQ=REQ-GQL-OPTIONAL-MATCH-001; FEATURE="OptionalMatchChain"; ASPECT=AST; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=parser; UPDATED=2025-12-22
    // Flag to indicate this chain is from an OPTIONAL MATCH clause
    // Optional chains should be treated as left outer joins during execution
    is_optional: bool = false,
    // CANARY: REQ=REQ-GQL-PATH-MODES-002; FEATURE="GQL Path Mode AST"; ASPECT=Chain; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; OWNER=parser; UPDATED=2026-01-08
    // Path mode specifier for variable-length path traversal semantics
    path_mode: PathMode = .walk,
};

pub const GraphPattern = struct { chains: []Chain };

pub const ReturnItem = struct { expr: Expr, alias: ?[]const u8 };

pub const ReturnClause = struct { items: []ReturnItem, distinct: bool };

pub const WithClause = struct {
    items: []ReturnItem,
    distinct: bool = false,
    order_by: ?*OrderBy = null,
    limit: ?u64 = null,
    offset: ?u64 = null,
    limit_param: ?[]const u8 = null,
    offset_param: ?[]const u8 = null,
};

/// GAP-0082: Common Table Expression (CTE) for WITH [RECURSIVE] clauses
/// CANARY: REQ=REQ-GQL-CTE-001; FEATURE="CommonTableExpression"; ASPECT=AST; STATUS=TESTED; TEST=geodetestlab/specs/recursive_and_cte.yml; OWNER=parser; UPDATED=2026-01-10
pub const CommonTableExpression = struct {
    name: []const u8,
    is_recursive: bool,
    /// Column names if explicitly specified: WITH cte_name(col1, col2) AS (...)
    column_names: ?[]const []const u8 = null,
    /// The CTE body - either a simple query or a union for recursive
    body: CTEBody,

    pub const CTEBody = union(enum) {
        /// Simple query: WITH cte AS (SELECT ...)
        simple: *Query,
        /// Recursive query: WITH RECURSIVE cte AS (anchor UNION [ALL] recursive)
        recursive: RecursiveCTE,
    };

    pub const RecursiveCTE = struct {
        anchor: *Query,
        recursive_term: *Query,
        union_all: bool, // true for UNION ALL, false for UNION
    };
};

/// GAP-0082: CTEList holds all CTEs defined in a WITH clause
pub const CTEList = struct {
    ctes: []CommonTableExpression,
    /// Whether any CTE in the list is recursive (for easy checking)
    has_recursive: bool,
};

pub const LetBinding = struct { variable: []const u8, value: Expr };

pub const GroupBy = struct { keys: []Expr };

pub const OrderBy = struct {
    pub const NullsPolicy = enum { default, first, last };
    pub const OrderKey = struct { expr: Expr, desc: bool, nulls: NullsPolicy = .default };
    keys: []OrderKey,
};

// Identifier with canonical name form for case-insensitive matching
pub const IdentRepr = struct {
    orig: []const u8, // Original identifier as written
    cnf: []const u8, // Canonical name form (uppercase)
};

pub const Expr = union(enum) {
    Ident: IdentRepr,
    String: []const u8,
    Int: i64,
    // Fixed-point decimal literal: coeff * 10^-scale
    Decimal: struct { coeff: i128, scale: u8 },
    Bool: bool,
    Null,
    Date: struct { raw: []const u8, parsed: temporal.Date },
    DateTime: struct { raw: []const u8, parsed: temporal.DateTime },
    Time: struct { raw: []const u8, parsed: temporal.Time },
    LocalDateTime: struct { raw: []const u8, parsed: temporal.DateTime },
    List: []*Expr,
    // New type constructor literals
    SmallIntLit: i16,
    BigIntLit: i64,
    RealLit: f32,
    DoubleLit: f64,
    CharLit: struct { text: []const u8, n: u16 },
    VarcharLit: struct { text: []const u8, n: u16 },
    TextLit: []const u8,
    ByteaLit: []const u8,
    JsonLit: []const u8,
    JsonbLit: []const u8,
    XmlLit: []const u8,
    UrlLit: []const u8,
    DomainLit: []const u8,
    UuidLit: []const u8,
    EnumLit: struct { type_name: []const u8, value: []const u8 },
    ArrayLit: []*Expr,
    BitLit: []const u8,
    VarBitLit: []const u8,
    Member: struct { target: *Expr, field: []const u8 },
    PropertyAccess: struct { object: []const u8, property: []const u8 }, // n.name syntax
    Index: struct { target: *Expr, index: *Expr },
    // CANARY: REQ=REQ-GQL-SLICE-001; FEATURE="ListSlicing"; ASPECT=ASTNode; STATUS=TESTED; TEST=geodetestlab/specs/gql_expressions_comprehensive.yml; OWNER=parser; UPDATED=2025-12-24
    Slice: struct { target: *Expr, start: ?*Expr, end: ?*Expr },
    Call: struct { callee: *Expr, args: []*Expr },
    Unary: struct { op: UnaryOp, expr: *Expr },
    Binary: struct { op: BinOp, left: *Expr, right: *Expr },
    In: struct { value: *Expr, set: []*Expr },
    InSubquery: struct { value: *Expr, subquery: *Query },
    // CANARY: REQ=REQ-GQL-IN-EXPR-001; FEATURE="InOperator"; ASPECT=ListExpression; STATUS=TESTED; TEST=geodetestlab/specs/gql_expressions_comprehensive.yml; OWNER=parser; UPDATED=2025-12-27
    // IN with list expression (e.g., 'Person' IN labels(n))
    InListExpr: struct { value: *Expr, list_expr: *Expr },
    IsNull: struct { target: *Expr, negated: bool },
    IsUnknown: struct { target: *Expr, negated: bool },
    // String predicates
    StartsWith: struct { value: *Expr, prefix: *Expr },
    EndsWith: struct { value: *Expr, suffix: *Expr },
    Contains: struct { value: *Expr, needle: *Expr },
    NotIn: struct { value: *Expr, set: []*Expr },
    NotInSubquery: struct { value: *Expr, subquery: *Query },
    // CANARY: REQ=REQ-GQL-IN-EXPR-002; FEATURE="NotInOperator"; ASPECT=ListExpression; STATUS=TESTED; TEST=geodetestlab/specs/gql_expressions_comprehensive.yml; OWNER=parser; UPDATED=2025-12-27
    // NOT IN with list expression
    NotInListExpr: struct { value: *Expr, list_expr: *Expr },
    // CASE expression
    Case: struct { operand: ?*Expr, whens: []CaseWhen, else_expr: ?*Expr },
    // Parameter reference: $name
    Param: []const u8,
    Map: []Property,
    PatternComp: struct { pattern: *GraphPattern, where: ?*Expr, map: *Expr, alias: ?[]const u8 = null },
    // EXISTS predicate with subquery pattern
    // CANARY: REQ=REQ-GQL-EXISTS-002; FEATURE="ExistsSubquery"; ASPECT=WhereClause; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=parser; UPDATED=2025-12-27
    Exists: struct { pattern: *GraphPattern, where: ?*Expr = null },
    // Label test: n:Label (checks if node has label)
    HasLabel: struct { node: []const u8, label: []const u8 },
    // Path finding functions and pattern comprehensions
    ShortestPath: struct { pattern: *GraphPattern, all: bool },
    // CANARY: REQ=REQ-GQL-COUNT-SUBQUERY-001; FEATURE="CountSubquery"; ASPECT=WhereClause; STATUS=TESTED; TEST=geodetestlab/specs/gql_query_comprehensive.yml; OWNER=parser; UPDATED=2025-12-28
    PatternCount: struct { pattern: *GraphPattern, where: ?*Expr = null },
    // Map projection: n {.name, .age} - projects specified properties from an object
    MapProjection: struct { source: *Expr, fields: [][]const u8 },
    // CANARY: REQ=REQ-GQL-089; FEATURE="ListComprehension"; ASPECT=AST; STATUS=TESTED; TEST=geodetestlab/specs/gql_expressions_comprehensive.ymlEMENTED; OWNER=parser; UPDATED=2025-12-23
    // List comprehension with optional filter and map: [x IN list WHERE cond | x.name]
    // or all(x IN list WHERE condition)
    ListComprehension: struct {
        variable: []const u8,
        source: *Expr,
        filter: ?*Expr,
        // CANARY: REQ=REQ-LIST-COMP-MAP-001; FEATURE="ListComprehension"; ASPECT=MapExpression; STATUS=TESTED; TEST=geodetestlab/specs/gql_expressions_comprehensive.yml; OWNER=parser; UPDATED=2025-12-23
        // Map expression after |, e.g., [x IN list | x.name] - if null, returns the variable itself
        map: ?*Expr = null,
    },
};

pub const BinOp = enum { And, Or, Xor, Eq, Ne, Lt, Le, Gt, Ge, Add, Sub, Mul, Div, Mod, Power, Concat, RegexMatch, RegexNotMatch };
pub const UnaryOp = enum { Not, Neg, Pos };

pub const CaseWhen = struct { when: *Expr, then_expr: *Expr };

// Graph mutation statements
pub const CreateStatement = struct {
    pattern: GraphPattern,
    return_clause: ?ReturnClause = null,
};

pub const InsertStatement = struct {
    pattern: GraphPattern,
    return_clause: ?ReturnClause = null,
};

pub const DeleteStatement = struct {
    match_clause: ?GraphPattern = null,
    where_clause: ?Expr = null,
    detach: bool = false,
    items: []DeleteItem,
    return_clause: ?ReturnClause = null,
};

pub const DeleteItem = union(enum) {
    Variable: []const u8,
    Node: []const u8,
    Relationship: []const u8,
};

pub const MergeStatement = struct {
    pattern: GraphPattern,
    on_create: []SetClause = &.{},
    on_match: []SetClause = &.{},
    return_clause: ?ReturnClause = null,
};

pub const CallProcedure = struct {
    procedure: Expr, // Function call expression: db.labels()
    yield_items: ?[]ReturnItem = null, // YIELD clause items
    return_clause: ?ReturnClause = null, // Optional RETURN clause
    order_by: ?OrderBy = null, // ORDER BY clause
    limit: ?usize = null, // LIMIT clause
    offset: ?usize = null, // OFFSET clause
    limit_param: ?[]const u8 = null,
    offset_param: ?[]const u8 = null,
};

pub const CallSubquery = struct {
    statement: *Statement, // The statement inside CALL { ... } (can be Query, Call, Create, etc.)
    imported_vars: ?[][]const u8 = null, // Variables imported from outer scope
    return_clause: ?ReturnClause = null, // Optional RETURN clause after subquery
};

pub const CallStatement = union(enum) {
    Procedure: CallProcedure,
    Subquery: CallSubquery,
};

// CallClause for use within MATCH queries (MATCH ... CALL ... YIELD)
pub const CallClause = struct {
    procedure: Expr, // Function call expression: algo.bfs.stream(node)
    yield_items: ?[]ReturnItem = null, // YIELD clause items (required for MATCH+CALL)
};

pub const SetClause = union(enum) {
    Property: struct { target: PropertyAccess, value: Expr },
    Labels: struct { node: []const u8, labels: [][]const u8 },
    AllProperties: struct { node: []const u8, properties: Expr }, // SET n = {prop1: val1, prop2: val2}
};

pub const RemoveClause = union(enum) {
    Property: PropertyAccess,
    Labels: struct { node: []const u8, labels: [][]const u8 },
};

pub const PropertyAccess = struct {
    object: []const u8,
    property: []const u8,
};

pub const SessionSetStatement = struct {
    clause_type: SessionSetClauseType,
};

pub const SessionSetClauseType = union(enum) {
    Schema: SchemaReference,
    Graph: GraphClause,
    TimeZone: TimeZoneClause,
    Parameter: ParameterClause,
};

pub const SchemaReference = struct {
    name: []const u8,
};

pub const GraphClause = struct {
    property_graph: bool = true, // [PROPERTY] GRAPH
    expression: []const u8, // graph expression or reference
};

pub const TimeZoneClause = struct {
    value: []const u8, // time zone string value
};

pub const ParameterClause = union(enum) {
    GraphParam: GraphParameterClause,
    BindingTableParam: BindingTableParameterClause,
    ValueParam: ValueParameterClause,
};

pub const GraphParameterClause = struct {
    property_graph: bool = true, // [PROPERTY] GRAPH
    parameter_name: SessionParameterName,
    initializer: ?[]const u8 = null, // typed graph initializer
};

pub const BindingTableParameterClause = struct {
    parameter_name: SessionParameterName,
    initializer: ?[]const u8 = null, // typed binding table initializer
};

pub const ValueParameterClause = struct {
    parameter_name: SessionParameterName,
    initializer: ?[]const u8 = null, // typed value initializer
};

pub const SessionParameterName = struct {
    if_not_exists: bool = false,
    specification: []const u8, // parameter specification
};

pub const SessionResetStatement = struct {
    arguments: ?SessionResetArguments = null,
};

pub const SessionResetArguments = union(enum) {
    All: SessionResetAllType,
    Schema,
    Graph: bool, // true if PROPERTY GRAPH, false if just GRAPH
    TimeZone,
    Parameter: []const u8, // parameter specification
};

pub const SessionResetAllType = enum {
    Parameters, // ALL PARAMETERS
    Characteristics, // ALL CHARACTERISTICS
};

pub const UseGraphStatement = struct {
    graph_name: []const u8, // e.g., "my_graph"
};

// Transaction control statements
pub const StartTransactionStatement = struct {
    body: ?[]Statement = null, // Optional body for START TRANSACTION { statements }
};

// Index operation statements
pub const CreateIndexStatement = struct {
    name: ?[]const u8 = null, // Optional - auto-generated from label+properties if omitted
    unique: bool = false,
    index_type: IndexType = .btree,
    label: []const u8,
    properties: [][]const u8,
    if_not_exists: bool = false,
};

pub const CreateConstraintStatement = struct {
    name: []const u8,
    constraint_type: ConstraintType,
    label: []const u8,
    properties: [][]const u8,
    if_not_exists: bool = false,
};

pub const ConstraintType = enum {
    unique, // IS UNIQUE
    node_key, // IS NODE KEY
    not_null, // IS NOT NULL
    exists, // EXISTS (prop) - legacy syntax
};

pub const DropIndexStatement = struct {
    name: []const u8,
    if_exists: bool = false,
};

pub const DropConstraintStatement = struct {
    name: []const u8,
    if_exists: bool = false,
};

pub const ShowStatement = struct {
    show_type: ShowType,
};

pub const ShowType = enum {
    indexes,
    constraints,
    tables,
    graphs,
    procedures,
    functions,
};

pub const IndexType = enum {
    btree,
    hash,
    fulltext,
    spatial,
    vector,
    // Advanced type indexes
    vector_f32,
    spatial_geographic,
    network_cidr,
    signature_crypto,
};

// Backup and restore statements
pub const BackupStatement = struct {
    path: []const u8,
    incremental: bool = false,
    compressed: bool = false,
    encrypted: bool = false,
    /// SECURITY: This field contains a raw key from parsed GQL. Callers MUST NOT
    /// log, serialize, or transmit this value without redaction.
    encryption_key: ?[]const u8 = null,
};

pub const RestoreStatement = struct {
    path: []const u8,
    timestamp: ?[]const u8 = null,
    verify_only: bool = false,
};

// Catalog operation statements
pub const CreateSchemaStatement = struct {
    name: []const u8,
    if_not_exists: bool = false,
};

pub const DropSchemaStatement = struct {
    name: []const u8,
    if_exists: bool = false,
};

pub const CreateGraphStatement = struct {
    name: []const u8,
    if_not_exists: bool = false,
    or_replace: bool = false,
    property_graph: bool = true, // GQL property graphs are default
    typed_spec: ?[]const u8 = null, // TYPED type_name
    like_source: ?[]const u8 = null, // LIKE source_graph
    copy_source: ?[]const u8 = null, // AS COPY OF source_graph
};

pub const DropGraphStatement = struct {
    name: []const u8,
    if_exists: bool = false,
    property_graph: bool = true, // GQL property graphs are default
};

// ============================================================================
// Field-Level Encryption AST Extensions (Geode Extension)
// ============================================================================
// These types support parsing of FLE annotations (@encrypted, @searchable) in
// CREATE GRAPH TYPE statements. They are Geode-specific extensions to the GQL
// AST and are included here because they are part of the parser's output. The
// FLE execution logic remains in Geode.
// CANARY: REQ=REQ-FLE-AST-001; FEATURE="FieldLevelEncryption"; ASPECT=AST; STATUS=TESTED; TEST=tests/test_tde_kms_integration.zig; OWNER=security; UPDATED=2026-01-15

/// Field annotation for FLE (e.g., @encrypted, @searchable)
pub const FieldAnnotation = struct {
    name: []const u8, // Annotation name (e.g., "encrypted", "searchable")
    text: []const u8, // Full annotation text with parameters
};

/// Field definition within a graph type
pub const FieldDefinition = struct {
    name: []const u8,
    type_name: []const u8, // e.g., "STRING", "INT", "UUID"
    nullable: bool = true,
    primary_key: bool = false,
    annotations: []FieldAnnotation = &.{}, // FLE annotations
};

pub const CreateGraphTypeStatement = struct {
    name: []const u8,
    if_not_exists: bool = false,
    or_replace: bool = false,
    property_graph: bool = true, // GQL property graphs are default
    type_definition: []const u8, // The graph type definition (e.g., "{ }") - DEPRECATED, use fields
    fields: []FieldDefinition = &.{}, // Parsed field definitions (NEW for FLE)
    like_source: ?[]const u8 = null, // LIKE source_graph
    copy_source: ?[]const u8 = null, // AS COPY OF source_type
};

pub const DropGraphTypeStatement = struct {
    name: []const u8,
    if_exists: bool = false,
    property_graph: bool = true, // GQL property graphs are default
};

// Query introspection statements
pub const ExplainStatement = struct {
    query: *Statement, // The query to explain (wrapped in a heap-allocated Statement)
};

pub const ProfileStatement = struct {
    query: *Statement, // The query to profile (wrapped in a heap-allocated Statement)
};

// FOR loop iteration statement
// Syntax: FOR item IN list_expr [WITH ORDINALITY var | WITH OFFSET var] RETURN ...
pub const ForStatement = struct {
    variable: []const u8, // The iteration variable name
    collection: Expr, // The collection to iterate over
    ordinality_var: ?[]const u8 = null, // WITH ORDINALITY variable name (1-based)
    offset_var: ?[]const u8 = null, // WITH OFFSET variable name (0-based)
    return_clause: ReturnClause, // RETURN clause for each iteration
    order_by: ?OrderBy = null,
    limit: ?usize = null,
    offset: ?usize = null,
    limit_param: ?[]const u8 = null,
    offset_param: ?[]const u8 = null,
};

pub const ValuesStatement = struct {
    rows: [][]Expr, // Each row is a list of expressions: VALUES (expr1, expr2), (expr3, expr4)
    column_names: [][]const u8, // Column names from AS (col1, col2, ...)
    next_statement: ?*Statement = null, // Continuation: MATCH, RETURN, etc.
};

// ============================================================================
// Unit Tests — GAP-QUAL-002
// ============================================================================

test "Query struct default values" {
    // Construct a minimal Query with required fields, verify defaults
    const empty_chains: []Chain = &.{};
    const empty_items: []ReturnItem = &.{};

    const q = Query{
        .optional_match = true,
        .match = GraphPattern{ .chains = empty_chains },
        .where_clause = null,
        .with_clause = null,
        .ret = ReturnClause{ .items = empty_items, .distinct = false },
        .order_by = null,
        .limit = null,
        .offset = null,
    };

    try std.testing.expectEqual(true, q.optional_match);
    try std.testing.expectEqual(@as(usize, 0), q.let_bindings.len);
    try std.testing.expectEqual(false, q.has_recursive_cte);
    try std.testing.expectEqual(false, q.is_initial_with);
    try std.testing.expectEqual(@as(?UnwindClause, null), q.unwind_clause);
    try std.testing.expectEqual(@as(?*Query, null), q.next_query);
}

test "NodePattern struct fields can be set" {
    const labels: []const []const u8 = &.{"Person"};

    const np = NodePattern{
        .name = "n",
        .labels = @constCast(labels),
        .props = null,
    };

    try std.testing.expectEqualStrings("n", np.name.?);
    try std.testing.expectEqual(@as(usize, 1), np.labels.len);
    try std.testing.expectEqualStrings("Person", np.labels[0]);
    try std.testing.expectEqual(@as(?[]Property, null), np.props);
}

test "RelPattern struct defaults and field setting" {
    const rel = RelPattern{
        .name = null,
        .types = &.{},
        .props = null,
        .dir = .right,
    };

    try std.testing.expectEqual(RelDir.right, rel.dir);
    try std.testing.expectEqual(@as(?u32, null), rel.min_len);
    try std.testing.expectEqual(@as(?u32, null), rel.max_len);

    // Test with quantifier values set
    const rel2 = RelPattern{
        .name = "r",
        .types = &.{},
        .props = null,
        .dir = .left,
        .min_len = 1,
        .max_len = 5,
    };

    try std.testing.expectEqual(RelDir.left, rel2.dir);
    try std.testing.expectEqual(@as(?u32, 1), rel2.min_len);
    try std.testing.expectEqual(@as(?u32, 5), rel2.max_len);
}

test "Chain struct defaults" {
    const chain = Chain{
        .hops = &.{},
    };

    try std.testing.expectEqual(false, chain.is_shortest);
    try std.testing.expectEqual(false, chain.is_optional);
    try std.testing.expectEqual(PathMode.walk, chain.path_mode);
    try std.testing.expectEqual(@as(?[]const u8, null), chain.name);
    try std.testing.expectEqual(@as(?NodePattern, null), chain.head);
}

test "BinOp enum variants exist" {
    // Verify all expected variants are valid enum values
    const ops = [_]BinOp{
        .And,
        .Or,
        .Eq,
        .Ne,
        .Add,
        .Sub,
        .Mul,
        .Div,
    };
    // Ensure each variant has a distinct tag value
    for (ops, 0..) |op, i| {
        for (ops[0..i]) |prev| {
            try std.testing.expect(op != prev);
        }
    }
    // Additional variants
    try std.testing.expect(BinOp.Lt != BinOp.Gt);
    try std.testing.expect(BinOp.Le != BinOp.Ge);
    try std.testing.expect(BinOp.Mod != BinOp.Power);
    try std.testing.expect(BinOp.Concat != BinOp.RegexMatch);
}

test "UnaryOp enum variants exist" {
    try std.testing.expect(UnaryOp.Not != UnaryOp.Neg);
    try std.testing.expect(UnaryOp.Not != UnaryOp.Pos);
    try std.testing.expect(UnaryOp.Neg != UnaryOp.Pos);
}

test "PathMode enum variants exist" {
    const modes = [_]PathMode{ .walk, .trail, .acyclic, .simple };
    // Verify all four are distinct
    for (modes, 0..) |mode, i| {
        for (modes[0..i]) |prev| {
            try std.testing.expect(mode != prev);
        }
    }
}

test "SetOperation enum variants exist" {
    try std.testing.expect(SetOperation.union_op != SetOperation.intersect);
    try std.testing.expect(SetOperation.intersect != SetOperation.except);
    try std.testing.expect(SetOperation.union_op != SetOperation.except);
}

test "RelDir enum variants exist" {
    try std.testing.expect(RelDir.right != RelDir.left);
    try std.testing.expect(RelDir.left != RelDir.undirected);
    try std.testing.expect(RelDir.right != RelDir.undirected);
}

test "IndexType enum variants exist" {
    const types = [_]IndexType{ .btree, .hash, .fulltext, .spatial, .vector };
    for (types, 0..) |t, i| {
        for (types[0..i]) |prev| {
            try std.testing.expect(t != prev);
        }
    }
}

test "ShowType enum variants exist" {
    const types = [_]ShowType{ .indexes, .constraints, .tables, .graphs, .procedures, .functions };
    for (types, 0..) |t, i| {
        for (types[0..i]) |prev| {
            try std.testing.expect(t != prev);
        }
    }
}

test "Statement union tag correctness" {
    const commit_stmt = Statement{ .Commit = {} };
    try std.testing.expectEqual(std.meta.Tag(Statement).Commit, std.meta.activeTag(commit_stmt));

    const rollback_stmt = Statement{ .Rollback = {} };
    try std.testing.expectEqual(std.meta.Tag(Statement).Rollback, std.meta.activeTag(rollback_stmt));

    const session_close_stmt = Statement{ .SessionClose = {} };
    try std.testing.expectEqual(std.meta.Tag(Statement).SessionClose, std.meta.activeTag(session_close_stmt));

    // Verify they are distinct tags
    try std.testing.expect(std.meta.activeTag(commit_stmt) != std.meta.activeTag(rollback_stmt));
    try std.testing.expect(std.meta.activeTag(rollback_stmt) != std.meta.activeTag(session_close_stmt));
}

test "Expr union variants: Int" {
    const expr = Expr{ .Int = 42 };
    try std.testing.expectEqual(@as(i64, 42), expr.Int);
    try std.testing.expectEqual(std.meta.Tag(Expr).Int, std.meta.activeTag(expr));
}

test "Expr union variants: Bool" {
    const expr_true = Expr{ .Bool = true };
    try std.testing.expectEqual(true, expr_true.Bool);
    try std.testing.expectEqual(std.meta.Tag(Expr).Bool, std.meta.activeTag(expr_true));

    const expr_false = Expr{ .Bool = false };
    try std.testing.expectEqual(false, expr_false.Bool);
}

test "Expr union variants: Null" {
    const expr = Expr{ .Null = {} };
    try std.testing.expectEqual(std.meta.Tag(Expr).Null, std.meta.activeTag(expr));
}

test "Expr union variants: String" {
    const expr = Expr{ .String = "hello" };
    try std.testing.expectEqualStrings("hello", expr.String);
    try std.testing.expectEqual(std.meta.Tag(Expr).String, std.meta.activeTag(expr));
}
