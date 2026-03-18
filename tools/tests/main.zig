//! Generator entrypoint for corpus conversion tooling.
//! Usage:
//!   zig build gen-tests -- all      # default
//!   zig build gen-tests -- fowler

const std = @import("std");
const mem = std.mem;
const gen_fowler = @import("gen_fowler.zig");

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    const cmd = if (args.len >= 2) args[1] else "all";
    if (mem.eql(u8, cmd, "all")) {
        // For now, "all" maps to Fowler until additional Rust TOML suites land.
        try gen_fowler.run();
        return;
    }
    if (mem.eql(u8, cmd, "fowler")) {
        try gen_fowler.run();
        return;
    }

    std.debug.print(
        \\unknown subcommand: {s}
        \\usage:
        \\  zig build gen-tests -- all
        \\  zig build gen-tests -- fowler
        \\
    , .{cmd});
    return error.InvalidArgument;
}
