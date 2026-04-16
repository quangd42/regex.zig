const std = @import("std");
const CaptureInfo = @import("CaptureInfo.zig");
const Offset = @import("Program.zig").Offset;

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
