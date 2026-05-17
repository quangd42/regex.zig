const std = @import("std");
const types = @import("types.zig");
const Input = types.Input;
const Match = types.Match;
const SearchMode = @import("Engine.zig").SearchMode;

pub fn Iterator(comptime mode: SearchMode, comptime Engine: type) type {
    if (mode == .presence) {
        @compileError("Iterator(.presence, ...) is invalid; use .span or .captures");
    }
    if (!std.meta.hasMethod(Engine, "search")) {
        @compileError(std.fmt.comptimePrint(
            "Iterator(.{s}, {s}) requires `{s}` to define method named `search`",
            .{ @tagName(mode), @typeName(Engine), @typeName(Engine) },
        ));
    }
    return struct {
        const Iter = @This();

        pub const Result = mode.Result();

        engine: *Engine,
        input: Input,
        last_match_end: ?usize = null,

        pub fn init(engine: *Engine, input: Input) Iter {
            return .{
                .engine = engine,
                .input = input,
            };
        }

        pub fn next(iter: *Iter) ?Result {
            while (iter.input.start <= iter.input.end) {
                const result: Result = iter.engine.search(mode, iter.input) orelse return null;

                const span: Match = switch (mode) {
                    .span => result,
                    .captures => result.span(),
                    .presence => unreachable,
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
