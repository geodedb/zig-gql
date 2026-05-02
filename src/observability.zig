// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! observability.zig — single-file otel seam for gql.
//!
//! When `build_options.with_otel == false`, every public function in this
//! file collapses to a comptime-known no-op so the optimizer eliminates
//! the call site entirely. When true, calls forward to the appropriate
//! `otel.api.trace` / `otel.instrumentation.http` helper.
//!
//! INVARIANT: every emit is `catch {}`-discarded. A failing exporter
//! never reaches the caller — telemetry must never break GQL parsing.
//!
//! NOTE: deviation from template — gql is the ISO/IEC 39075 parser
//! library, not an HTTP server. The HTTP-shaped `startClientSpan` /
//! `startServerSpan` helpers are kept for template symmetry (and so
//! gateway/proxy consumers driving GQL over HTTP can reuse the seam).
//! The hot-path helper for gql is `startQueryExecutionSpan` /
//! `endQueryExecutionSpan` which produces a span shaped for a parse /
//! execute step:
//!
//!   - name: `"gql.{operation_type}"` (e.g. `"gql.query"`)
//!   - kind: `.client` (parser is invoked from a query-issuing client)
//!   - attributes:
//!       * `db.system = "graphql"` (per the rollout brief — even though
//!         this lib parses ISO/IEC 39075 GQL, the consumer-facing
//!         semantic-convention value is `graphql` so dashboards group
//!         it alongside other graph-query workloads)
//!       * `graphql.operation.type = operation_type`
//!       * `graphql.operation.name = operation_name` (when non-null)
//!
//! By DEFAULT we do NOT set `db.statement` to the full query body —
//! GQL queries can be long and may contain PII embedded in literals.
//! Consumers that have explicitly sanitised their query text can opt
//! in via `setQueryStatement(span, body)`, which truncates to 1024
//! bytes to keep span attribute sizes bounded.

const std = @import("std");
// 2026-05-02: hardcoded enabled=false and removed the build_options
// import + the conditional otel import. The previous pattern surfaced
// a Zig 0.16 module-dedup quirk when the lib was reached through
// multiple paths in a downstream build graph (geode), producing
// "build_options" vs "build_options0" diamonds at this file. The
// seam is preserved as a permanent no-op for forward-compat;
// restore the conditional once the upstream Zig dedup issue is
// resolved.
pub const enabled: bool = false;

const otel = struct {};

/// Maximum length we will ever store as `db.statement`. GQL queries
/// can be arbitrarily long; we cap to keep per-span attribute bytes
/// bounded.
pub const max_statement_bytes: usize = 1024;

/// Opaque handle for an in-flight operation. When disabled, this is a
/// zero-sized struct the optimizer drops entirely. The no-op fallback's
/// `end` signature MUST match `otel.api.trace.Span.end(?u64) void` so
/// callers can write `span.end(null)` regardless of `enabled` state.
pub const Span = if (enabled) otel.api.trace.Span else struct {
    pub fn end(self: @This(), _: ?u64) void {
        _ = self;
    }
};

/// Helper: reads either a `[]const u8` field OR a function-typed field
/// returning `[]const u8`, so the seam accepts both shapes — the closure
/// shape the recipe template ships AND the plain-string-field shape used
/// at hot-path call sites.
inline fn accessOr(req: anytype, comptime field: []const u8) []const u8 {
    const T = @TypeOf(@field(req, field));
    return switch (@typeInfo(T)) {
        .pointer => @field(req, field),
        .@"fn" => @field(req, field)(),
        else => @compileError("observability: unsupported field type for " ++ field),
    };
}

/// Start a span for a generic outbound operation. Kept for template
/// symmetry; gql hot paths use `startQueryExecutionSpan` instead. The
/// caller passes anything with `method` and `url` accessors (string
/// fields or zero-arg fns returning strings).
pub fn startClientSpan(req: anytype) Span {
    if (!enabled) return Span{};
    const tracer = global.tracer orelse return Span{};
    const span = otel.instrumentation.http.startClientSpan(
        tracer.*,
        .empty(),
        .{
            .method = accessOr(req, "method"),
            .url = accessOr(req, "url"),
        },
    ) catch return Span{};
    return span;
}

pub fn endClientSpan(span: Span, status: u16) void {
    if (!enabled) return;
    otel.instrumentation.http.endClientSpan(span, .{ .status_code = status });
}

/// Start a span for a generic inbound operation. Kept for template
/// symmetry; gql has no authoritative-server entry point.
pub fn startServerSpan(req: anytype) Span {
    if (!enabled) return Span{};
    const tracer = global.tracer orelse return Span{};
    const span = otel.instrumentation.http.startServerSpan(
        tracer.*,
        .empty(),
        .{
            .method = accessOr(req, "method"),
            .route = accessOr(req, "route"),
            .url = accessOr(req, "url"),
        },
    ) catch return Span{};
    return span;
}

pub fn endServerSpan(span: Span, status: u16) void {
    if (!enabled) return;
    otel.instrumentation.http.endServerSpan(span, status);
}

/// Start a span for a GQL query execution / parse step.
///
/// Span shape:
///   - name: `"gql.{operation_type}"` (e.g. `"gql.query"`,
///     `"gql.mutation"`, `"gql.subscription"`)
///   - kind: `.client`
///   - attributes:
///       * `db.system = "graphql"`
///       * `graphql.operation.type = operation_type`
///       * `graphql.operation.name = operation_name` (when non-null)
///
/// We deliberately do NOT set `db.statement` here — query bodies may
/// be long and contain PII in literals. Consumers that have sanitised
/// their query text can opt in by calling `setQueryStatement(span, body)`
/// after this returns; that helper truncates to `max_statement_bytes`.
pub fn startQueryExecutionSpan(
    operation_type: []const u8,
    operation_name: ?[]const u8,
) Span {
    if (!enabled) return Span{};
    const tracer = global.tracer orelse return Span{};
    // Compose the span name on the stack; the SDK dupes the name into
    // the span arena, so a pointer to a stack buffer is safe here.
    var name_buf: [128]u8 = undefined;
    const span_name = std.fmt.bufPrint(
        name_buf[0..],
        "gql.{s}",
        .{operation_type},
    ) catch "gql.query";
    const span = tracer.startSpan(.empty(), span_name, .{ .kind = .client }) catch return Span{};
    // Best-effort attribute attachment. Failures (OOM in the attribute
    // set) cannot block parsing — telemetry is non-fatal.
    span.setStringAttribute("db.system", "graphql") catch {};
    span.setStringAttribute("graphql.operation.type", operation_type) catch {};
    if (operation_name) |name| {
        span.setStringAttribute("graphql.operation.name", name) catch {};
    }
    return span;
}

/// Optional opt-in: attach a (possibly-truncated) query body to a span
/// as `db.statement`. Callers MUST have sanitised the body for PII
/// before calling — `db.statement` rides on every export.
pub fn setQueryStatement(span: Span, statement: []const u8) void {
    if (!enabled) return;
    const trimmed = if (statement.len > max_statement_bytes)
        statement[0..max_statement_bytes]
    else
        statement;
    span.setStringAttribute("db.statement", trimmed) catch {};
}

/// Close a query-execution span, recording success/failure and the
/// number of GQL errors observed (e.g. validation/parser diagnostics
/// that did not abort the call).
///
/// On `ok = true` we set status `.ok`; on `ok = false` we set status
/// `.error_` with an empty description, then end the span. Callers
/// typically pair this with `defer span.end(null)` at the call site so
/// the span is always ended regardless of which path is taken.
/// `setStatus` + `end` are idempotent for status reporting (only the
/// first status write wins; the deferred `end(null)` is a redundant
/// no-op).
pub fn endQueryExecutionSpan(span: Span, ok: bool, error_count: usize) void {
    if (!enabled) return;
    // The error count is informational — useful even on success-paths
    // where the parser surfaced recoverable diagnostics.
    span.setIntAttribute("graphql.errors.count", @intCast(error_count)) catch {};
    if (ok) {
        span.setStatus(.ok, "");
    } else {
        // `StatusCode` uses `@"error"` (escaped keyword) for the
        // failure variant — see otel/src/api/trace.zig.
        span.setStatus(.@"error", "");
    }
    span.end(null);
}

/// Set once at process start by `observability_init.Otel.installGlobals`.
/// Only referenced when `enabled == true`; otherwise the optimizer drops
/// the whole struct.
pub const global = if (enabled) struct {
    pub var tracer: ?*otel.api.trace.Tracer = null;
    pub var meter: ?*otel.api.metrics.Meter = null;
} else struct {};
