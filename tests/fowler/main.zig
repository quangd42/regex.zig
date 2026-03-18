//! Runs generated Fowler corpora through the shared harness.

const std = @import("std");
const gpa = std.testing.allocator;

const runner = @import("../harness.zig").runner;

test "fowler basic" {
    const basic = &@import("basic.zig").cases;
    try runner.runSuite(gpa, "fowler/basic", basic, .pikevm);
}

test "fowler repetition" {
    const repetition = &@import("repetition.zig").cases;
    try runner.runSuite(gpa, "fowler/repetition", repetition, .pikevm);
}

test "fowler nullsubexpr" {
    const nullsubexpr = &@import("nullsubexpr.zig").cases;
    try runner.runSuite(gpa, "fowler/nullsubexpr", nullsubexpr, .pikevm);
}
