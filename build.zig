const std = @import("std");

pub fn build(b: *std.Build) void {
    // Shared build options.
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Public package module (what downstream users import as "regex").
    const regex_mod = b.addModule("regex", .{
        .root_source_file = b.path("src/Regex.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Demo executable. Built by default (`zig build`) but not installed.
    const demo_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    demo_mod.addImport("regex", regex_mod);

    const demo_exe = b.addExecutable(.{
        .name = "regex-demo",
        .root_module = demo_mod,
    });
    b.getInstallStep().dependOn(&demo_exe.step);

    const regex_lib_check = b.addLibrary(.{
        .name = "regex",
        .root_module = regex_mod,
        .linkage = .static,
    });

    const run_demo = b.addRunArtifact(demo_exe);
    if (b.args) |args| run_demo.addArgs(args);
    const run_step = b.step("run", "Run regex demo");
    run_step.dependOn(&run_demo.step);

    // Corpus generation tooling.
    const toml_dep = b.dependency("toml", .{
        .target = target,
        .optimize = optimize,
    });
    const gen_tests_mod = b.createModule(.{
        .root_source_file = b.path("tools/tests/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    gen_tests_mod.addImport("toml", toml_dep.module("toml"));
    const gen_tests_exe = b.addExecutable(.{
        .name = "gen-tests",
        .root_module = gen_tests_mod,
    });
    const run_gen_tests = b.addRunArtifact(gen_tests_exe);
    if (b.args) |args| run_gen_tests.addArgs(args);
    const gen_tests_step = b.step(
        "gen-tests",
        "Generate Zig corpus files from Rust TOML test suites",
    );
    gen_tests_step.dependOn(&run_gen_tests.step);

    // Build-on-save check step.
    const check = b.step("check", "Compile demo and library module");
    check.dependOn(&regex_lib_check.step);
    check.dependOn(&demo_exe.step);

    // Unit tests rooted at `src/Regex.zig`.
    const unit_tests = b.addTest(.{
        .root_module = regex_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    // Integration/corpus suites rooted at `tests/tests.zig`.
    const suite_tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    suite_tests_mod.addImport("export_test", b.createModule(.{
        .root_source_file = b.path("src/export_test.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const suite_tests = b.addTest(.{
        .root_module = suite_tests_mod,
    });
    const run_suite_tests = b.addRunArtifact(suite_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_suite_tests.step);
}
