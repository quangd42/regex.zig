const std = @import("std");
const assert = std.debug.assert;

const Diagnostics = @import("errors.zig").Diagnostics;
const CaptureInfo = @import("CaptureInfo.zig");
const Offset = @import("Program.zig").Offset;

/// Options that control regex parsing and compilation.
///
/// These options affect the compiled program itself and are independent of any
/// particular haystack search.
pub const CompileOptions = struct {
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

    /// Limits used to guard compilation work and program size.
    pub const Limits = struct {
        /// Maximum decimal repetition value accepted by the parser, to avoid pathological
        /// NFA growth. Default is 1000, following the RE2 family (Go, Rust).
        max_repeat: u16 = 1000,

        /// Maximum number of NFA states produced by the compiler.
        /// `null` means "use compiler intrinsic limit".
        max_states: ?usize = null,
    };
};

/// `Input` is for searches that need more control than `find(haystack)`.
/// It lets you restrict the search to a window of the haystack and optionally
/// require the match to begin at a specific position.
///
/// `start` and `end` define the search window as `[start, end)`. A match may
/// begin at `start` and must end no later than `end`. A search window is not
/// the same as slicing the haystack, as assertions still inspect bytes outside
/// the window.
///
/// ```zig
/// const haystack = "a123";
/// const input = Regex.Input.init(haystack, .{ .start = 1, .end = 4 });
/// const found = re.findIn(input);
/// // Pattern `\b123\b` does not match here, because the byte before `start`
/// // is still `a`. In contrast, `re.find(haystack[1..4])` does return a match.
/// ```
///
/// When `anchored` is true, the match must begin exactly at `start`.
/// while `^` requires the match to be at offset 0 of the haystack (on start of
/// line in multi-line mode).
///
/// ```zig
/// const input = Regex.Input.init("zab", .{ .start = 1, .anchored = true });
/// // Pattern `ab` may match.
/// // Pattern `^ab` still does not match, because index 1 is not the start of
/// // the haystack or the start of a line.
/// ```
pub const Input = struct {
    /// The full haystack being searched.
    haystack: []const u8,
    /// Inclusive start index of the search window.
    start: Offset,
    /// Exclusive end index of the search window.
    end: Offset,
    /// Require any match to begin at `start`.
    anchored: bool,

    pub fn init(haystack: []const u8, opts: Options) Input {
        const end = opts.end orelse haystack.len;
        assert(opts.start <= end);
        assert(end <= haystack.len);
        assert(end <= std.math.maxInt(Offset));
        return .{
            .haystack = haystack,
            .start = @intCast(opts.start),
            .end = @intCast(end),
            .anchored = opts.anchored,
        };
    }

    /// Configuration options for constructing an `Input`.
    ///
    /// `Input` is for searches that need more control than `find(haystack)`.
    /// It lets you restrict the search to a window of the haystack and optionally
    /// require the match to begin at a specific position.
    ///
    /// `start` and `end` define the search window as `[start, end)`. A match may
    /// begin at `start` and must end no later than `end`. A search window is not
    /// the same as slicing the haystack, as assertions still inspect bytes outside
    /// the window.
    ///
    /// ```zig
    /// const haystack = "a123";
    /// const input = Regex.Input.init(haystack, .{ .start = 1, .end = 4 });
    /// const found = re.findIn(input);
    /// // Pattern `\b123\b` does not match here, because the byte before `start`
    /// // is still `a`. In contrast, `re.find(haystack[1..4])` does return a match.
    /// ```
    ///
    /// When `anchored` is true, the match must begin exactly at `start`.
    /// while `^` requires the match to be at offset 0 of the haystack (on start of
    /// line in multi-line mode).
    ///
    /// ```zig
    /// const input = Regex.Input.init("zab", .{ .start = 1, .anchored = true });
    /// // Pattern `ab` may match.
    /// // Pattern `^ab` still does not match, because index 1 is not the start of
    /// // the haystack or the start of a line.
    /// ```
    pub const Options = struct {
        /// Inclusive start index of the search window.
        start: usize = 0,
        /// Exclusive end index of the search window. Defaults to `haystack.len`.
        end: ?usize = null,
        /// Require any match to begin at `start`.
        anchored: bool = false,
    };
};

/// `Match` contains the half-open [start, end) indice range of the match in haystack.
/// It represents the boundary of a capture group in the haystack for `Captures`. It is
/// also the returned type of `Regex.find()`.
pub const Match = struct {
    start: usize,
    end: usize,

    /// Return a slice of `haystack` for this match.
    pub fn bytes(m: Match, haystack: []const u8) []const u8 {
        return haystack[m.start..m.end];
    }

    /// Return the length of the match.
    pub fn len(m: Match) usize {
        return m.end - m.start;
    }
};

/// `Captures` provides access to the capture data produced by the most recent search.
/// The first capture group is always the span of the whole match in haystack.
///
/// The returned capture data becomes invalid after the next search on this same `Regex`,
/// including advancing to the next match in the case of the future `findAllCaptures`.
/// To preserve capture data across later searches, use `copy(dest)`.
/// `Captures` must not outlive the `Regex` instance where it came from.
pub const Captures = struct {
    slots: []const ?Offset,
    info: *const CaptureInfo,

    fn decode(self: Captures, index: usize) ?Match {
        const start = self.slots[index * 2] orelse return null;
        const end = self.slots[index * 2 + 1] orelse return null;
        return .{ .start = start, .end = end };
    }

    /// Return the number of capture groups, including group 0 for the full match.
    pub fn len(self: Captures) usize {
        return self.info.count;
    }

    /// Return the span of the full match.
    pub fn span(self: Captures) Match {
        return self.decode(0).?;
    }

    /// Return the matched bytes for the full match.
    pub fn bytes(self: Captures, haystack: []const u8) []const u8 {
        return self.span().bytes(haystack);
    }

    /// Copy all capture groups into `dest` and return the filled slice, to preserve
    /// them across later searches.
    ///
    /// `dest.len` is assumed to be at least `len()`.
    pub fn copy(self: Captures, dest: []?Match) []?Match {
        const capture_count = self.len();
        std.debug.assert(dest.len >= capture_count);
        for (0..capture_count) |i| {
            dest[i] = self.decode(i);
        }
        return dest[0..capture_count];
    }

    /// Return the capture group at `index`, or `null` if `index` is out of bounds.
    pub fn get(self: Captures, index: usize) ?Match {
        if (index >= self.len()) return null;
        return self.decode(index);
    }

    /// Return the capture group with the given name, or `null` if the name does not
    /// exist or the group did not participate in the match.
    pub fn name(self: Captures, capture_name: []const u8) ?Match {
        const index = self.info.indexOf(capture_name) orelse return null;
        return self.get(index);
    }
};
