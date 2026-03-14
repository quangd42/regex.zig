const Diagnostics = @import("errors.zig").Diagnostics;

// syntax: Syntax = .{},
limits: Limits = .{},
diagnostics: ?*Diagnostics = null,
// meta: Meta,

pub const Syntax = struct {
    case_insensitive: bool = false, // i
    multiline: bool = false, // m
    dot_matches_new_line: bool = false, // s
    ungreedy: bool = false, // U
};

pub const Limits = struct {
    /// Maximum decimal repetition value accepted by the parser, to avoid pathological
    /// NFA growth. Default is 1000, following the RE2 family (Go, Rust).
    repeat_size: u16 = 1000,

    /// Maximum number of NFA states produced by the compiler.
    /// `null` means "use compiler intrinsic limit".
    states_count: ?usize = null,
};
