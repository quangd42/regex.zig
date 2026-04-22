const std = @import("std");
const types = @import("types.zig");
const Input = types.Input;
const Match = types.Match;
const Captures = types.Captures;

pub const IterKind = enum { match, captures };

pub fn Iterator(comptime kind: IterKind, comptime Engine: type) type {
    const method_name = switch (kind) {
        .match => "find",
        .captures => "findCaptures",
    };
    if (!std.meta.hasMethod(Engine, method_name)) {
        @compileError(std.fmt.comptimePrint(
            "Iterator(.{s}, {s}) requires `{s}` to define method named `{s}`",
            .{ @tagName(kind), @typeName(Engine), @typeName(Engine), method_name },
        ));
    }
    return struct {
        const Iter = @This();

        pub const Result = switch (kind) {
            .match => Match,
            .captures => Captures,
        };

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
                const result: Result = switch (kind) {
                    .match => iter.engine.find(iter.input),
                    .captures => iter.engine.findCaptures(iter.input),
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
