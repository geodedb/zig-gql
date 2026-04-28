// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

//! Verifies one GQL query-execution span lands in an in-memory recorder
//! when `-Dwith_otel=true`. Skips under the disabled build.
//!
//! NOTE: deviation from template — we exercise the seam directly via
//! the in-memory recorder rather than driving a real parse. The seam's
//! behaviour is identical: `startQueryExecutionSpan` ->
//! `endQueryExecutionSpan` enters and leaves one tracer span carrying
//! the GraphQL semantic conventions.
//!
//! The `otel` module is only added to this test root when
//! `-Dwith_otel=true`. To compile cleanly under both flag values we
//! gate the otel-namespace identifiers behind `comptime if (enabled)`
//! and stub the alias to an empty struct when the flag is off — that
//! branch is dead code in the disabled build but the import resolves.

const std = @import("std");
const build_options = @import("build_options");
const gql = @import("gql");

const otel = if (build_options.with_otel) @import("otel") else struct {};

test "one GQL query-execution span recorded when otel enabled" {
    if (!gql.observability.enabled) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    var resource = try otel.sdk.resource.defaultResource(allocator);
    defer resource.deinit();
    try resource.attributes.putString(otel.semconv.service_name, "gql-test");

    var recorder = otel.exporters.in_memory.Recorder.init(allocator);
    defer recorder.deinit();
    var tp = try otel.sdk.trace.TracerProvider.init(allocator, .{
        .resource = &resource,
        .default_exporter = recorder.spanExporter(),
    });
    defer tp.deinit();

    var tracer = tp.tracer(.{ .name = "gql-test" });
    gql.observability.global.tracer = &tracer;
    defer gql.observability.global.tracer = null;

    const span = gql.observability.startQueryExecutionSpan("query", "Test");
    gql.observability.endQueryExecutionSpan(span, true, 0);

    try tp.forceFlush(1_000);
    try std.testing.expectEqual(@as(usize, 1), recorder.spans.items.len);

    // Verify span name shape: "gql.{operation_type}".
    const recorded = recorder.spans.items[0];
    try std.testing.expectEqualStrings("gql.query", recorded.name);

    // Verify the graphql.operation.type attribute landed on the span.
    // The in-memory recorder stores attributes as `[]KV`
    // (string-stringified key/value pairs).
    var found_type: ?[]const u8 = null;
    var found_name: ?[]const u8 = null;
    var found_system: ?[]const u8 = null;
    for (recorded.attribute_kv) |kv| {
        if (std.mem.eql(u8, kv.key, "graphql.operation.type")) {
            found_type = kv.value;
        } else if (std.mem.eql(u8, kv.key, "graphql.operation.name")) {
            found_name = kv.value;
        } else if (std.mem.eql(u8, kv.key, "db.system")) {
            found_system = kv.value;
        }
    }
    const op_type = found_type orelse return error.MissingGraphqlOperationType;
    try std.testing.expectEqualStrings("query", op_type);

    const op_name = found_name orelse return error.MissingGraphqlOperationName;
    try std.testing.expectEqualStrings("Test", op_name);

    const sys = found_system orelse return error.MissingDbSystem;
    try std.testing.expectEqualStrings("graphql", sys);
}
