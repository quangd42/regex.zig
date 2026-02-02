const std = @import("std");
const Allocator = std.mem.Allocator;

const Ast = @import("Ast.zig");

const Op = enum(u8) {
    char,
    ranges,
    empty,
    alt,
    match,
    fail,
};

pub const Index = u32;
const Length = u16;
pub const ByteRange = struct { start: u8, end: u8 };

pub const State = union(Op) {
    char: struct { byte: u8, out: Index },
    ranges: struct { start: Index, len: Length, out: Index },
    empty: struct { out: Index },
    alt: struct { start: Index, len: Length },
    match,
    fail,
};

pub const Program = @This();

states: std.MultiArrayList(State).Slice,
ranges: []ByteRange,
alt_outs: []Index,
arena: std.heap.ArenaAllocator,
