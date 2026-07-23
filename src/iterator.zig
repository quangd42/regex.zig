const std = @import("std");
const types = @import("types.zig");
const Input = types.Input;
const Match = types.Match;
const Span = types.Span;
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

pub fn Split(comptime Engine: type) type {
    const MatchIterator = Iterator(.span, Engine);
    return struct {
        it: MatchIterator,
        last_end: ?usize,

        const Iter = @This();

        pub fn init(engine: *Engine, input: Input) Iter {
            return .{
                .it = .init(engine, input),
                .last_end = input.start,
            };
        }

        pub fn next(iter: *Iter) ?Span {
            const last_end = iter.last_end orelse return null;
            const input_end = iter.it.input.end;
            const match_span = iter.it.next() orelse {
                const span: Span = .{ .start = last_end, .end = input_end };
                iter.last_end = null;
                return span;
            };
            const span: Span = .{ .start = last_end, .end = match_span.start };
            iter.last_end = match_span.end;
            return span;
        }

        /// Advances the iterator and returns the bytes covered by the next span.
        /// The returned slice is a view over the haystack used to create this iterator.
        pub fn nextBytes(iter: *Iter) ?[]const u8 {
            const span = iter.next() orelse return null;
            return span.bytes(iter.it.input.haystack);
        }
    };
}

pub fn SplitN(comptime Engine: type) type {
    const MatchIterator = Iterator(.span, Engine);
    return struct {
        it: MatchIterator,
        last_end: ?usize,
        remaining: usize,

        const Iter = @This();

        pub fn init(engine: *Engine, input: Input, limit: usize) Iter {
            return .{
                .it = .init(engine, input),
                .last_end = input.start,
                .remaining = limit,
            };
        }

        pub fn next(iter: *Iter) ?Span {
            if (iter.remaining == 0) return null;
            const input_end = iter.it.input.end;
            const last_end = iter.last_end orelse return null;
            defer iter.remaining -= 1;
            if (iter.remaining == 1) return .{ .start = last_end, .end = input_end };
            const match_span = iter.it.next() orelse {
                const span: Span = .{ .start = last_end, .end = input_end };
                iter.last_end = null;
                return span;
            };
            const span: Span = .{ .start = last_end, .end = match_span.start };
            iter.last_end = match_span.end;
            return span;
        }

        /// Advances the iterator and returns the bytes covered by the next span.
        /// The returned slice is a view over the haystack used to create this iterator.
        pub fn nextBytes(iter: *Iter) ?[]const u8 {
            const span = iter.next() orelse return null;
            return span.bytes(iter.it.input.haystack);
        }
    };
}
