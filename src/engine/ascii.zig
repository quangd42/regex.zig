const std = @import("std");
const testing = std.testing;

pub fn isWordByte(c: u8) bool {
    const set: [256]bool = comptime b: {
        var out = [_]bool{false} ** 256;
        for ('0'..'9' + 1) |i| out[i] = true;
        for ('A'..'Z' + 1) |i| out[i] = true;
        for ('a'..'z' + 1) |i| out[i] = true;
        out['_'] = true;
        break :b out;
    };
    return set[c];
}

test "word byte" {
    try testing.expect(isWordByte('z'));
    try testing.expect(isWordByte('_'));
    try testing.expect(!isWordByte(' '));
}
