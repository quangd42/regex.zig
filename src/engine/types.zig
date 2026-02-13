pub const Program = @import("../syntax/Program.zig");
pub const StateId = Program.StateId;

/// Match contains the half-open [start, end) indice range of the match in input.
pub const Match = struct {
    start: usize,
    end: usize,
};
