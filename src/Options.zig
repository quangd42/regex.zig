const Diagnostics = @import("errors.zig").Diagnostics;

syntax: Syntax = .{},
limits: Limits = .{},
diag: ?*Diagnostics = null,
// meta: Meta,

pub const Syntax = struct {
    case_insensitive: bool = false, // i
    multi_line: bool = false, // m
    dot_matches_new_line: bool = false, // s
    swap_greed: bool = false, // U
};

pub const Limits = struct {
    /// Maximum decimal repetition value accepted by the parser, to avoid pathological
    /// NFA growth. Default is 1000, following the RE2 family (Go, Rust).
    max_repeat: u16 = 1000,

    /// Maximum number of NFA states produced by the compiler.
    /// `null` means "use compiler intrinsic limit".
    max_states: ?usize = null,
};
