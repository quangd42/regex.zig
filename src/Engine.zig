const std = @import("std");
const Allocator = std.mem.Allocator;

const PikeVm = @import("Engine/PikeVm.zig");
const Program = @import("Program.zig");
const types = @import("types.zig");
const Captures = types.Captures;
const Input = types.Input;
const Match = types.Match;

const Engine = @This();

pikevm: PikeVm,

pub fn init(gpa: Allocator, prog: *const Program) !Engine {
    return .{
        .pikevm = try .init(gpa, prog),
    };
}

pub fn deinit(engine: *Engine) void {
    engine.pikevm.deinit();
}

pub fn match(engine: *Engine, input: Input) bool {
    return engine.pikevm.match(input);
}

pub fn find(engine: *Engine, input: Input) ?Match {
    return engine.pikevm.find(input);
}

pub fn findCaptures(engine: *Engine, input: Input) ?Captures {
    return engine.pikevm.findCaptures(input);
}
