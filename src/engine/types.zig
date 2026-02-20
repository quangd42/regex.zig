const std = @import("std");
const Allocator = std.mem.Allocator;

pub const StateId = u32;

/// Position of a character into input `haystack`.
pub const Offset = u32;

/// Sentinel value for null offset. There is no check for null because in practice an input of anything
/// close to this size might already cause other problems before it gets here.
pub const null_offset = std.math.maxInt(Offset);

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
