const std = @import("std");
const Allocator = std.mem.Allocator;

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

/// `Captures` is a wrapper around an array of `Match`es, which represents capture groups
/// in the match, and provides convenient methods to work with those capture groups. The
/// first capture group is always the span of the whole match in haystack.
///
/// `Captures` does not own the allocated resources.
pub const Captures = struct {
    items: []?Match,

    /// Return the capture group at `index`, or `null` if `index` is out of bounds.
    pub fn get(self: Captures, index: usize) ?Match {
        if (index >= self.items.len) return null;
        return self.items[index];
    }

    /// Return a slice of `haystack` for the capture group at `index`.
    /// Return `null` if `index` is out of bounds or the group did not match.
    pub fn bytes(self: Captures, index: usize, haystack: []const u8) ?[]const u8 {
        const m = self.get(index) orelse return null;
        return haystack[m.start..m.end];
    }
};
