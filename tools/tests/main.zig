//! Generator entrypoint for corpus conversion tooling.
//! Usage:
//!   zig build gen-tests -- all      # default
//!   zig build gen-tests -- fowler
//!   zig build gen-tests -- rust-regex
//!   zig build gen-tests -- local

const std = @import("std");
const mem = std.mem;
const gen_toml_tests = @import("gen_toml_tests.zig");

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    const cmd = if (args.len >= 2) args[1] else "all";
    if (mem.eql(u8, cmd, "all")) {
        try gen_toml_tests.runAll();
        return;
    }
    if (mem.eql(u8, cmd, "fowler")) {
        try gen_toml_tests.runFowler();
        return;
    }
    if (mem.eql(u8, cmd, "rust-regex")) {
        try gen_toml_tests.runRustRegex();
        return;
    }
    if (mem.eql(u8, cmd, "local")) {
        try gen_toml_tests.runLocal();
        return;
    }

    std.debug.print(
        \\unknown subcommand: {s}
        \\usage:
        \\  zig build gen-tests -- all
        \\  zig build gen-tests -- fowler
        \\  zig build gen-tests -- rust-regex
        \\  zig build gen-tests -- local
        \\
    , .{cmd});
    return error.InvalidArgument;
}
