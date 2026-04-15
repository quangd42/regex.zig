pub const Input = @This();

haystack: []const u8,
anchored: bool = false,

pub fn init(haystack: []const u8) Input {
    return .{ .haystack = haystack };
}

pub fn initWithOptions(haystack: []const u8, options: Options) Input {
    return .{
        .haystack = haystack,
        .anchored = options.anchored,
    };
}

pub const Options = struct {
    anchored: bool = false,
};
