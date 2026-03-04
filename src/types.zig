const std = @import("std");
const Allocator = std.mem.Allocator;

/// Match contains the half-open [start, end) indice range of the match in input.
pub const Match = struct {
    start: usize,
    end: usize,
};

pub const Captures = struct {
    groups: []?Match,

    pub fn deinit(self: *Captures, gpa: Allocator) void {
        gpa.free(self.groups);
        self.* = undefined;
    }
};
