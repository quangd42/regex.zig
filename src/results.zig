const std = @import("std");
const CaptureInfo = @import("CaptureInfo.zig");

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

/// `Captures` is a wrapper around an array of `Match`es representing the capture groups
/// in a match. The first capture group is always the span of the whole match in haystack.
///
/// `Captures` does not own the allocated resources, and must not outlive the `Regex`
/// instance where it came from.
pub const Captures = struct {
    items: []?Match,
    info: *const CaptureInfo,

    /// Return the capture group at `index`, or `null` if `index` is out of bounds.
    pub fn get(self: Captures, index: usize) ?Match {
        if (index >= self.items.len) return null;
        return self.items[index];
    }

    /// Return the capture group with the given name, or `null` if the name does not
    /// exist or the group did not participate in the match.
    pub fn name(self: Captures, capture_name: []const u8) ?Match {
        const index = self.info.indexOf(capture_name) orelse return null;
        return self.get(index);
    }
};
