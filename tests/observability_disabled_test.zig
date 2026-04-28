// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Verifies the no-op invariant when -Dwith_otel=false (the default).
//!
//! gql publishes its public surface as the "gql" module rooted at
//! src/root.zig. The seam is exposed as `gql.observability` so this test
//! drives the disabled-mode invariants through the public root.
//!
//! NOTE: deviation from template — gql is a parser library (ISO/IEC
//! 39075). The "operation" in this domain is parsing a GQL query body
//! (the parser-side analog of "execute"). The seam therefore exposes
//! `startQueryExecutionSpan(operation_type, operation_name)` which
//! produces span name `"gql.{operation_type}"` and the
//! `db.system="gql"` / `graphql.operation.type` /
//! `graphql.operation.name` semantic-convention attributes.

const std = @import("std");
const gql = @import("gql");

test "build_options.with_otel exists and defaults to false" {
    const build_options = @import("build_options");
    try std.testing.expect(@hasDecl(build_options, "with_otel"));
    // The "default" assertion only holds for the disabled build. When
    // the operator forces -Dwith_otel=true, this test runs against the
    // enabled module and must skip rather than misreport the default.
    if (build_options.with_otel) return error.SkipZigTest;
    try std.testing.expectEqual(false, build_options.with_otel);
}

test "observability.enabled tracks build_options.with_otel" {
    const build_options = @import("build_options");
    try std.testing.expectEqual(build_options.with_otel, gql.observability.enabled);
}

test "client/server seams are no-ops when otel disabled" {
    if (gql.observability.enabled) return error.SkipZigTest;
    var span = gql.observability.startClientSpan(.{
        .method = "POST",
        .route = "/gql",
        .url = "https://example.test/gql",
    });
    gql.observability.endClientSpan(span, 200);
    // Belt-and-suspenders: the seam's `endClientSpan` already covers
    // the lifecycle; this line just verifies the no-op fallback's
    // signature matches the real API's `Span.end(?u64) void`.
    span.end(null);

    var sspan = gql.observability.startServerSpan(.{
        .method = "POST",
        .route = "/gql",
        .url = "/gql",
    });
    gql.observability.endServerSpan(sspan, 200);
    sspan.end(null);
}

test "GQL query-execution span helper is a no-op when otel disabled" {
    if (gql.observability.enabled) return error.SkipZigTest;
    var span = gql.observability.startQueryExecutionSpan("query", "MyOp");
    gql.observability.endQueryExecutionSpan(span, true, 0);
    span.end(null);

    // operation_name is optional (null is valid).
    var span2 = gql.observability.startQueryExecutionSpan("query", null);
    gql.observability.endQueryExecutionSpan(span2, false, 3);
    span2.end(null);
}
