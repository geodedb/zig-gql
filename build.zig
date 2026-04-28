// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const enable_tp = b.option(bool, "thread_pool", "Enable thread-pool-based parallelism") orelse false;

    // -Dwith_otel: compile in otel instrumentation. OFF by default; when
    // off the otel dependency is never resolved and the seam collapses
    // to a comptime-known no-op (verified by
    // otel/scripts/verify-consumer-noop.sh).
    const with_otel = b.option(
        bool,
        "with_otel",
        "Compile in otel instrumentation (off by default; zero overhead when off)",
    ) orelse false;

    // Build options module — materialise ONE shared `build_options`
    // module so every consumer (lib, observability seam, tests) imports
    // the SAME instance. Without the shared instance Zig 0.16 may emit
    // "file exists in modules X and X0" when two independent
    // `addOptions` modules end up sharing a transitive file path.
    const build_options = b.addOptions();
    build_options.addOption(bool, "enable_tp", enable_tp);
    build_options.addOption(bool, "with_otel", with_otel);
    const build_options_mod = build_options.createModule();

    // Conditionally resolve thread_pool dependency
    const tp_mod: ?*std.Build.Module = if (enable_tp) blk: {
        const tp_dep = b.dependency("thread_pool", .{
            .target = target,
            .optimize = optimize,
        });
        break :blk tp_dep.module("thread_pool");
    } else null;

    // Observability seam (otel). Declared as a SHARED NAMED MODULE so
    // every consumer (`gql`, plus the disabled/enabled seam tests)
    // resolves to the same source file via `@import("observability")`.
    // Using a relative `@import("observability.zig")` from each module
    // would trip Zig's "file exists in modules X and Y" error because
    // the file would be pulled into multiple module trees. The seam's
    // `enabled` flag tracks `build_options.with_otel`; when off, every
    // helper compiles to a comptime-known no-op and the otel dependency
    // is never resolved. The optional `otel` import is wired below
    // inside the `if (with_otel)` block.
    const observability_mod = b.addModule("observability", .{
        .root_source_file = b.path("src/observability.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "build_options", .module = build_options_mod },
        },
    });

    // Main library module
    const module = b.addModule("gql", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addImport("build_options", build_options_mod);
    module.addImport("observability", observability_mod);
    if (tp_mod) |tm| {
        module.addImport("thread_pool", tm);
    }

    // Unit tests (run tests defined in the module itself)
    const test_step = b.step("test", "Run unit tests");
    const unit_test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_test_mod.addImport("build_options", build_options_mod);
    unit_test_mod.addImport("observability", observability_mod);
    if (tp_mod) |tm| {
        unit_test_mod.addImport("thread_pool", tm);
    }
    const unit_tests = b.addTest(.{
        .root_module = unit_test_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);

    // Integration tests (separate test file with module import)
    const integration_step = b.step("test-integration", "Run integration tests");
    const integration_mod = b.createModule(.{
        .root_source_file = b.path("tests/integration.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "gql", .module = module },
        },
    });
    integration_mod.addImport("build_options", build_options_mod);
    if (tp_mod) |tm| {
        integration_mod.addImport("thread_pool", tm);
    }
    const integration_tests = b.addTest(.{
        .root_module = integration_mod,
    });
    const run_integration_tests = b.addRunArtifact(integration_tests);
    integration_step.dependOn(&run_integration_tests.step);

    // Check step for IDE integration (fast syntax validation)
    const check_step = b.step("check", "Check for compilation errors");
    const check_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    check_mod.addImport("build_options", build_options_mod);
    check_mod.addImport("observability", observability_mod);
    if (tp_mod) |tm| {
        check_mod.addImport("thread_pool", tm);
    }
    const check = b.addTest(.{
        .root_module = check_mod,
    });
    check_step.dependOn(&check.step);

    // ========================================================================
    // Observability seam (otel) — gated dependency + seam tests
    // ========================================================================

    // Disabled-mode no-op tests. Verifies `build_options.with_otel == false`
    // is the default and that the seam's public surface returns a
    // comptime-known no-op when otel is off. The test is skip-guarded for
    // the enabled build so it passes under both flag values.
    const observability_disabled_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/observability_disabled_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gql", .module = module },
                .{ .name = "build_options", .module = build_options_mod },
            },
        }),
    });
    const run_observability_disabled_tests = b.addRunArtifact(observability_disabled_tests);
    test_step.dependOn(&run_observability_disabled_tests.step);

    // Enabled-mode smoke test. Skips under -Dwith_otel=false; under
    // -Dwith_otel=true it installs an in-memory recorder, drives one
    // query-execution span through the seam, and asserts the recorder
    // captured it. Compiles cleanly under both flag values because the
    // otel-namespace identifiers sit behind `comptime if (enabled)`
    // short-circuits.
    const observability_enabled_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/observability_enabled_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gql", .module = module },
                .{ .name = "build_options", .module = build_options_mod },
            },
        }),
    });

    // Gated otel dependency. The `lazy = true` entry in build.zig.zon
    // means Zig only fetches the package when this branch executes; with
    // the flag off the dependency is never resolved and the produced
    // artifacts contain zero otel symbols (verified by
    // otel/scripts/verify-consumer-noop.sh).
    if (with_otel) {
        const otel_dep = b.lazyDependency("otel", .{
            .target = target,
            .optimize = optimize,
        }) orelse return;
        const otel_module = otel_dep.module("otel");
        // The seam itself imports `otel` when enabled. Wire it onto the
        // shared observability module so every consumer sees the same
        // otel namespace.
        observability_mod.addImport("otel", otel_module);
        module.addImport("otel", otel_module);

        // Bootstrap helper. Only registered when `-Dwith_otel=true` so
        // the disabled build never compiles otel-touching code. Gated
        // from src/root.zig via
        // `if (observability.enabled) @import("observability_init")`.
        const observability_init_mod = b.addModule("observability_init", .{
            .root_source_file = b.path("src/observability_init.zig"),
            .target = target,
            .imports = &.{
                .{ .name = "otel", .module = otel_module },
                .{ .name = "observability", .module = observability_mod },
            },
        });
        module.addImport("observability_init", observability_init_mod);
        // Unit-test root and IDE check root both compile from
        // `src/root.zig`, which transitively `@import`s
        // `observability_init` under the `if (observability.enabled)`
        // branch. Wire the same import here so those test/check graphs
        // resolve under `-Dwith_otel=true`.
        unit_test_mod.addImport("observability_init", observability_init_mod);
        check_mod.addImport("observability_init", observability_init_mod);

        // Re-resolve otel for the smoke test so its `@import("otel")`
        // resolves; the disabled build skips this branch entirely.
        observability_enabled_tests.root_module.addImport("otel", otel_module);
    }
    const run_observability_enabled_tests = b.addRunArtifact(observability_enabled_tests);
    test_step.dependOn(&run_observability_enabled_tests.step);

    // =========================================================================
    // Benchmarks
    // =========================================================================

    // Basic benchmark executable
    const bench_step = b.step("bench", "Run performance benchmarks");
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "gql", .module = module },
            },
        }),
    });
    const run_bench = b.addRunArtifact(bench_exe);
    bench_step.dependOn(&run_bench.step);

    // Incremental scale benchmark executable
    const scale_bench_step = b.step("scale-bench", "Run incremental scale benchmarks with JSON output");
    const scale_bench_exe = b.addExecutable(.{
        .name = "scale-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/scale_bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "gql", .module = module },
            },
        }),
    });
    b.installArtifact(scale_bench_exe);
    const run_scale_bench = b.addRunArtifact(scale_bench_exe);
    if (b.args) |args| {
        run_scale_bench.addArgs(args);
    }
    scale_bench_step.dependOn(&run_scale_bench.step);

    // Benchmark comparison tool
    const compare_bench_step = b.step("compare-bench", "Compare benchmark results against a baseline");
    const compare_bench_exe = b.addExecutable(.{
        .name = "compare-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/compare.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    const run_compare_bench = b.addRunArtifact(compare_bench_exe);
    if (b.args) |args| {
        run_compare_bench.addArgs(args);
    }
    compare_bench_step.dependOn(&run_compare_bench.step);
}
