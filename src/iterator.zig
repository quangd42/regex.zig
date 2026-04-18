const Regex = @import("Regex.zig");
const types = @import("types.zig");
const Input = types.Input;
const Match = types.Match;
const Captures = types.Captures;

const IterKind = enum { match, captures };
pub const MatchIterator = Iterator(.match);
pub const CapturesIterator = Iterator(.captures);

fn Iterator(comptime kind: IterKind) type {
    return struct {
        const Iter = @This();

        pub const Result = switch (kind) {
            .match => Match,
            .captures => Captures,
        };

        regex: *Regex,
        input: Input,
        last_match_end: ?usize = null,

        pub fn next(iter: *Iter) ?Result {
            while (iter.input.start <= iter.input.end) {
                const result: Result = switch (kind) {
                    .match => iter.regex.findIn(iter.input),
                    .captures => iter.regex.findCapturesIn(iter.input),
                } orelse return null;

                const span: Match = switch (kind) {
                    .match => result,
                    .captures => result.span(),
                };

                // When an empty match overlaps with the end of the previous
                // match, skip it and advance by one byte to prevent both
                // infinite loops and overlapping matches.
                if (span.start == span.end) {
                    if (iter.last_match_end) |prev_end| {
                        if (span.end == prev_end) {
                            iter.input.start += 1;
                            continue;
                        }
                    }
                }

                iter.input.start = span.end;
                iter.last_match_end = span.end;
                return result;
            }
            return null;
        }
    };
}
