const harness = @import("../harness.zig");

pub const suite: harness.Suite = .{
    .name = "empty",
    .cases = &cases,
};

const cases = [_]harness.Case{
    // Added for Zig regex.
    .{
        .name = "line-end-at-haystack-end",
        .pattern = "$",
        .haystack = "abc",
        .expected = .one(.{ 3, 3 }),
    },
};
