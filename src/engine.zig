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

pub fn search(engine: *Engine, comptime mode: SearchMode, input: Input) ?mode.Result() {
    return engine.pikevm.search(mode, input);
}

/// SearchMode indicates the amount of capturing group data a search must produce.
///
/// Callers can use this to pick the cheapest matching strategy for their needs.
pub const SearchMode = enum {
    /// Only report whether a match is present.
    presence,
    /// Report the span of the full match.
    span,
    /// Report the full capture group list.
    captures,

    pub fn Result(comptime mode: SearchMode) type {
        return switch (mode) {
            .presence => void,
            .span => Match,
            .captures => Captures,
        };
    }
};
