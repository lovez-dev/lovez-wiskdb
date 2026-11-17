const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Default releases retain safety checks; explicit modes apply to the library too.
    const optimize = b.option(std.builtin.Optimize, "optimize", "Prioritize performance, safety, or binary size") orelse b.standardOptimizeOption(.{
        .preferred_optimize_mode = switch (b.graph.release_mode) {
            .fast => .fast,
            .small => .small,
            else => .safe,
        },
    });
    const sanitize_thread = b.option(bool, "sanitize-thread", "Enable Thread Sanitizer") orelse false;
    const test_filter = b.option([]const u8, "test-filter", "Run tests whose names contain this string");
    const filters: []const []const u8 = if (test_filter) |value| &.{value} else &.{};

    const mod = b.addModule("wiskdb", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .sanitize_thread = sanitize_thread,
    });

    const lib_tests = b.addTest(.{ .root_module = mod, .filters = filters });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    const test_step = b.step("test", "Run unit, public contract and integration tests");
    test_step.dependOn(&run_lib_tests.step);
    b.step("test-unit", "Run internal module tests").dependOn(&run_lib_tests.step);

    const api_tests = b.addTest(.{
        .name = "wiskdb-api-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/root.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
            .imports = &.{.{ .name = "wiskdb", .module = mod }},
        }),
        .filters = filters,
    });
    const run_api_tests = b.addRunArtifact(api_tests);
    test_step.dependOn(&run_api_tests.step);
    b.step("test-api", "Run public contract and integration tests").dependOn(&run_api_tests.step);

    const fmt_step = b.step("fmt", "Check formatting (fails on non-conforming files)");
    fmt_step.dependOn(&b.addFmt(.{
        .paths = &.{ b.path("build.zig"), b.path("build.zig.zon"), b.path("src"), b.path("tests"), b.path("examples"), b.path("bench") },
        .check = true,
    }).step);
    const zlap_dep = b.dependency("zlap", .{ .target = target, .optimize = .ReleaseFast });
    const benchmark_module = b.createModule(.{
        .root_source_file = b.path("bench/main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{ .{ .name = "wiskdb", .module = mod }, .{ .name = "zlap", .module = zlap_dep.module("zlap") } },
    });
    const benchmark = b.addExecutable(.{ .name = "wiskdb-bench", .root_module = benchmark_module });
    const benchmark_step = b.step("bench", "Build the database benchmark");
    const run_benchmark_step = b.step("bench-run", "Run the database benchmark with default settings");
    run_benchmark_step.dependOn(&b.addRunArtifact(benchmark).step);
    run_benchmark_step.dependOn(&b.addInstallArtifact(benchmark, .{}).step);
    benchmark_step.dependOn(&b.addInstallArtifact(benchmark, .{}).step);
    const stress = b.addExecutable(.{
        .name = "wiskdb-stress",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/stress_bench.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = sanitize_thread,
            .imports = &.{.{ .name = "wiskdb", .module = mod }},
        }),
    });
    b.step("stress", "Build the concurrent KV stress checker").dependOn(&b.addInstallArtifact(stress, .{}).step);
    const run_stress = b.addRunArtifact(stress);
    run_stress.addPassthruArgs();
    b.step("stress-run", "Run the KV stress checker: <path> <rounds>").dependOn(&run_stress.step);
    const examples_step = b.step("examples", "Build runnable examples");
    const example_names = .{ "basic", "reopen", "batch", "crash_recovery", "collections" };
    inline for (example_names) |name| {
        const exe = b.addExecutable(.{
            .name = "wiskdb-" ++ name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/" ++ name ++ ".zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "wiskdb", .module = mod }},
            }),
        });
        const install = b.addInstallArtifact(exe, .{});
        examples_step.dependOn(&install.step);
    }
}
