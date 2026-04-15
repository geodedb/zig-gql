// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2025 CodePros

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const enable_tp = b.option(bool, "thread_pool", "Enable thread-pool-based parallelism") orelse false;

    // Build options module
    const build_options = b.addOptions();
    build_options.addOption(bool, "enable_tp", enable_tp);

    // Conditionally resolve thread_pool dependency
    const tp_mod: ?*std.Build.Module = if (enable_tp) blk: {
        const tp_dep = b.dependency("thread_pool", .{
            .target = target,
            .optimize = optimize,
        });
        break :blk tp_dep.module("thread_pool");
    } else null;

    // Main library module
    const module = b.addModule("gql", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addOptions("build_options", build_options);
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
    unit_test_mod.addOptions("build_options", build_options);
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
    integration_mod.addOptions("build_options", build_options);
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
    check_mod.addOptions("build_options", build_options);
    if (tp_mod) |tm| {
        check_mod.addImport("thread_pool", tm);
    }
    const check = b.addTest(.{
        .root_module = check_mod,
    });
    check_step.dependOn(&check.step);

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
