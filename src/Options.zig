const Diagnostics = @import("errors.zig").Diagnostics;

syntax: Syntax = .{},
limits: Limits = .{},
diag: ?*Diagnostics = null,
// meta: Meta,

/// Initial syntax flags for the regex. Equivalent to leading flags e.g. `(?imsU)`.
/// Inline flags override these defaults.
pub const Syntax = struct {
    /// `i`: match ASCII letters case-insensitively.
    case_insensitive: bool = false,
    /// `m`: make `^` and `$` match line boundaries as well as text boundaries.
    multi_line: bool = false,
    /// `s`: make `.` match `\n`.
    dot_matches_new_line: bool = false,
    /// `U`: invert the default greediness of repetition operators.
    swap_greed: bool = false,
};

pub const Limits = struct {
    /// Maximum decimal repetition value accepted by the parser, to avoid pathological
    /// NFA growth. Default is 1000, following the RE2 family (Go, Rust).
    max_repeat: u16 = 1000,

    /// Maximum number of NFA states produced by the compiler.
    /// `null` means "use compiler intrinsic limit".
    max_states: ?usize = null,
};
