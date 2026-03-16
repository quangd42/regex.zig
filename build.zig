const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // b.options here

    const mod = b.addModule("regex", .{
        .root_source_file = b.path("src/Regex.zig"),
        .target = target,
        .optimize = optimize,
    });

    // This is where build-on-save check step begins.
    const exe_check = b.addExecutable(.{
        .name = "regex",
        .root_module = mod,
    });
    // There is no `b.installArtifact(exe_check);` here.

    const check = b.step("check", "Check if compile");
    check.dependOn(&exe_check.step);

    // Test step for module
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Test step for harness/integration suites.
    const harness_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_harness_tests = b.addRunArtifact(harness_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_harness_tests.step);
}
