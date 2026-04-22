const std = @import("std");
const Allocator = std.mem.Allocator;

const export_test = @import("export_test");
const Regex = export_test.Regex;
const Compiler = export_test.Compiler;
const PikeVm = export_test.PikeVm;
const Program = export_test.Program;
const iterator = export_test.iterator;
const Input = Regex.Input;

/// Inclusive-exclusive byte span written as `{ start, end }`.
pub const Span = struct { usize, usize };

/// Capture spans for one match. Item 0 is the full match; later items are
/// explicit capturing groups. `null` means the group did not participate.
pub const CaptureSpans = []const ?Span;

/// Expected search result for a case.
pub const Expected = union(enum) {
    /// Leftmost first, span only.
    span: ?Span,
    /// Leftmost first, captures.
    captures: CaptureSpans,
    /// All results, each with span only.
    span_all: []const Span,
    /// All results, each with captures.
    captures_all: []const CaptureSpans,

    /// Short-hand for no-match.
    pub const none = one(null);

    /// Expect one match span, or no match.
    pub fn one(span: ?Span) Expected {
        return .{ .span = span };
    }

    /// Expect one match with capture spans.
    pub fn capt(spans: CaptureSpans) Expected {
        assertCaptures(spans);
        return .{ .captures = spans };
    }

    /// Expect all matches with whole match span.
    pub fn all(spans: []const Span) Expected {
        return .{ .span_all = spans };
    }

    /// Expect all matches with capture spans.
    pub fn allCapt(matches: []const CaptureSpans) Expected {
        for (matches) |spans| assertCaptures(spans);
        return .{ .captures_all = matches };
    }

    fn assertCaptures(spans: CaptureSpans) void {
        if (spans.len == 0 or spans[0] == null) {
            @panic("capture expectations must include group 0; use .one(null) for no match");
        }
    }

    fn hasMatch(expected: Expected) bool {
        return switch (expected) {
            .span => |span| span != null,
            .captures => true,
            .span_all => |spans| spans.len > 0,
            .captures_all => |matches| matches.len > 0,
        };
    }
};

fn toMatch(span: ?Span) ?Regex.Match {
    const actual = span orelse return null;
    return .{
        .start = actual[0],
        .end = actual[1],
    };
}

pub const Case = struct {
    name: []const u8,
    pattern: []const u8,
    haystack: []const u8,
    start: usize = 0,
    end: ?usize = null,
    anchored: bool = false,
    options: Regex.CompileOptions = .{},
    expected: Expected,

    fn input(tc: Case) Input {
        return Input.init(tc.haystack, .{
            .start = tc.start,
            .end = tc.end,
            .anchored = tc.anchored,
        });
    }
};

/// Runtime controls supplied by the suite runner.
pub const Options = struct {
    verbose: bool = false,
    trace: bool = false,
};

/// A named group of behavior cases.
pub const Suite = struct {
    name: []const u8,
    cases: []const Case,
};

pub fn runCase(
    gpa: Allocator,
    w: *std.Io.Writer,
    suite_name: []const u8,
    tc: Case,
    options: Options,
) !void {
    var runner: CaseRunner = .{
        .gpa = gpa,
        .w = w,
        .suite_name = suite_name,
        .tc = tc,
        .options = options,
    };
    try runner.run();
}

const CaseRunner = struct {
    gpa: Allocator,
    w: *std.Io.Writer,
    suite_name: []const u8,
    tc: Case,
    options: Options,

    const CaptureLocation = union(enum) {
        capture: usize,
        match: usize,
        match_capture: struct {
            match: usize,
            capture: usize,
        },
    };

    fn run(r: *CaseRunner) !void {
        var diag: Regex.Diagnostics = undefined;
        var compile_opts = r.tc.options;
        compile_opts.diag = &diag;
        const prog = Compiler.compile(r.gpa, r.tc.pattern, compile_opts) catch |err| {
            try r.compileFailure(diag, err);
            return error.TestUnexpectedResult;
        };
        defer prog.deinit();

        const input = r.tc.input();
        inline for ([_]Backend{.pikevm}) |backend| {
            backend.supports(prog, r.tc) catch |err| switch (err) {
                error.ZigSkipTest => {
                    try r.skip(backend);
                    continue;
                },
                else => return err,
            };

            try r.runBackend(backend, prog, input);
        }
    }

    fn runBackend(r: *CaseRunner, comptime backend: Backend, prog: *const Program, input: Input) !void {
        const Engine = backend.Engine();

        var engine = try Engine.init(r.gpa, prog);
        defer engine.deinit();

        if (r.options.trace) {
            try r.traceHeader(backend);
            try engine.prog.dump(r.w);
        }

        try r.checkMatch(backend, r.tc.expected.hasMatch(), engine.match(input));
        switch (r.tc.expected) {
            .span => |expected| try r.checkFind(backend, expected, engine.find(input)),
            .captures => |expected| {
                try r.checkFind(backend, expected[0], engine.find(input));
                switch (backend.captureCap()) {
                    .full => try r.checkCaptures(backend, expected, engine.findCaptures(input)),
                    .bounds_only => {},
                }
            },
            .span_all => |expected| try r.checkAll(backend, expected, &engine, input),
            .captures_all => |expected| try r.checkAllCaptures(backend, expected, &engine, input),
        }

        try r.pass(backend);
    }

    fn compileFailure(r: CaseRunner, diag: Regex.Diagnostics, err: anyerror) !void {
        try r.caseContext(null, null);
        try r.w.print("  error: {s}\n", .{@errorName(err)});
        switch (err) {
            error.Parse => switch (diag) {
                .parse => |parse| try r.w.print("  error tag: {s}\n", .{@tagName(parse.err)}),
                .compile => unreachable,
            },
            error.Compile => switch (diag) {
                .parse => unreachable,
                .compile => |compile| try r.w.print("  error tag: {s}\n", .{@tagName(compile)}),
            },
            else => {},
        }
    }

    fn checkMatch(r: CaseRunner, backend: Backend, expected: bool, actual: bool) !void {
        if (actual == expected) return;
        try r.valueMismatch(backend, "match() expectation mismatch", expected, actual);
        return error.TestUnexpectedResult;
    }

    fn checkFind(r: CaseRunner, backend: Backend, expected_span: ?Span, actual: ?Regex.Match) !void {
        const expected = toMatch(expected_span);
        if (std.meta.eql(actual, expected)) return;
        try r.valueMismatch(backend, "find() result mismatch", expected, actual);
        return error.TestUnexpectedResult;
    }

    fn checkCaptures(r: CaseRunner, backend: Backend, expected: CaptureSpans, actual: ?Regex.Captures) !void {
        Expected.assertCaptures(expected);

        const captures = actual orelse {
            try r.captureMismatch(backend, null, expected, null, "findCaptures() returned null");
            return error.TestUnexpectedResult;
        };
        if (captures.len() != expected.len) {
            try r.captureMismatch(backend, null, expected, captures, "capture group count mismatch");
            return error.TestUnexpectedResult;
        }

        for (expected, 0..) |span, i| {
            if (std.meta.eql(captures.get(i), toMatch(span))) continue;
            try r.captureMismatch(backend, .{ .capture = i }, expected, captures, "capture group value mismatch");
            return error.TestUnexpectedResult;
        }
    }

    fn checkAll(
        r: CaseRunner,
        comptime backend: Backend,
        expected: []const Span,
        engine: *backend.Engine(),
        input: Input,
    ) !void {
        var iter = iterator.Iterator(.match, backend.Engine()).init(engine, input);

        for (expected, 0..) |span, i| {
            const expected_match = toMatch(span).?;
            const actual = iter.next() orelse {
                try r.allMismatch(backend, i, expected_match, null);
                return error.TestUnexpectedResult;
            };
            if (std.meta.eql(actual, expected_match)) continue;
            try r.allMismatch(backend, i, expected_match, actual);
            return error.TestUnexpectedResult;
        }

        if (iter.next()) |actual| {
            try r.allMismatch(backend, expected.len, null, actual);
            return error.TestUnexpectedResult;
        }
    }

    fn checkAllCaptures(
        r: CaseRunner,
        comptime backend: Backend,
        expected: []const CaptureSpans,
        engine: *backend.Engine(),
        input: Input,
    ) !void {
        switch (backend.captureCap()) {
            .full => {
                var iter = iterator.Iterator(.captures, backend.Engine()).init(engine, input);

                for (expected, 0..) |expected_captures, i| {
                    Expected.assertCaptures(expected_captures);
                    const actual = iter.next() orelse {
                        try r.captureMismatch(backend, .{ .match = i }, expected_captures, null, "findAllCaptures() returned null");
                        return error.TestUnexpectedResult;
                    };
                    if (actual.len() != expected_captures.len) {
                        try r.captureMismatch(backend, .{ .match = i }, expected_captures, actual, "capture group count mismatch");
                        return error.TestUnexpectedResult;
                    }

                    for (expected_captures, 0..) |span, capture_i| {
                        if (std.meta.eql(actual.get(capture_i), toMatch(span))) continue;
                        try r.captureMismatch(
                            backend,
                            .{ .match_capture = .{ .match = i, .capture = capture_i } },
                            expected_captures,
                            actual,
                            "capture group value mismatch",
                        );
                        return error.TestUnexpectedResult;
                    }
                }

                if (iter.next()) |actual| {
                    try r.captureMismatch(backend, .{ .match = expected.len }, null, actual, "findAllCaptures() returned extra match");
                    return error.TestUnexpectedResult;
                }
            },
            .bounds_only => {
                var spans_buf: [16]Span = undefined;
                std.debug.assert(expected.len <= spans_buf.len);
                const spans = spans_buf[0..expected.len];
                for (expected, 0..) |expected_captures, i| {
                    Expected.assertCaptures(expected_captures);
                    spans[i] = expected_captures[0].?;
                }
                try r.checkAll(backend, spans, engine, input);
            },
        }
    }

    fn traceHeader(r: CaseRunner, backend: Backend) !void {
        try r.w.print(
            "[trace] backend={s} name={s}/{s} pattern=\"{s}\" haystack=\"{s}\" window={d}..{?} anchored={s}\n",
            .{
                @tagName(backend),
                r.suite_name,
                r.tc.name,
                r.tc.pattern,
                r.tc.haystack,
                r.tc.start,
                r.tc.end,
                if (r.tc.anchored) "true" else "false",
            },
        );
    }

    fn beginFailure(r: CaseRunner, backend: Backend, reason: []const u8) !void {
        try r.caseContext(backend, null);
        try r.w.writeAll("  test failed:\n");
        try r.w.print("    - {s}\n", .{reason});
    }

    fn valueMismatch(r: CaseRunner, backend: Backend, reason: []const u8, expected: anytype, actual: @TypeOf(expected)) !void {
        try r.beginFailure(backend, reason);
        try r.w.print("      ├─ expected: {any}\n", .{expected});
        try r.w.print("      └─ actual  : {any}\n", .{actual});
    }

    fn allMismatch(r: CaseRunner, backend: Backend, index: usize, expected: ?Regex.Match, actual: ?Regex.Match) !void {
        try r.beginFailure(backend, "findAll() result mismatch");
        try r.w.print("      match index: {d}\n", .{index});
        try r.w.print("      ├─ expected: {any}\n", .{expected});
        try r.w.print("      └─ actual  : {any}\n", .{actual});
    }

    fn captureMismatch(
        r: CaseRunner,
        backend: Backend,
        location: ?CaptureLocation,
        expected: ?CaptureSpans,
        actual: ?Regex.Captures,
        reason: []const u8,
    ) !void {
        try r.beginFailure(backend, switch (r.tc.expected) {
            .captures => "findCaptures() result mismatch",
            .captures_all => "findAllCaptures() result mismatch",
            .span, .span_all => unreachable,
        });
        if (location) |loc| switch (loc) {
            .capture => |capture_i| try r.w.print("      capture index: {d}\n", .{capture_i}),
            .match => |match_i| try r.w.print("      match index: {d}\n", .{match_i}),
            .match_capture => |both| {
                try r.w.print("      match index: {d}\n", .{both.match});
                try r.w.print("      capture index: {d}\n", .{both.capture});
            },
        };
        try r.w.print("      reason: {s}\n", .{reason});
        try r.w.print("      ├─ expected groups_len: {d}\n", .{if (expected) |spans| spans.len else 0});
        try r.w.print("      ├─ actual   groups_len: {d}\n", .{if (actual) |capt| capt.len() else 0});
        try r.w.print("      ├─ expected   captures: {any}\n", .{expected});
        try r.writeActualCaptures("      └─ actual     captures: ", actual);
    }

    fn caseContext(r: CaseRunner, backend: ?Backend, status: ?[]const u8) !void {
        try r.w.print("[{s}/{s} backend={?s}] {s}\n", .{
            r.suite_name,
            r.tc.name,
            if (backend) |selected| @tagName(selected) else null,
            if (status) |label| label else "",
        });
        if (status != null) return;
        try r.w.print("  pattern: {s}\n", .{r.tc.pattern});
        try r.w.print("  haystack: {s}\n", .{r.tc.haystack});
        try r.w.print("  window: {d}..{?}\n", .{ r.tc.start, r.tc.end });
        try r.w.print("  anchored: {s}\n", .{if (r.tc.anchored) "true" else "false"});
    }

    fn pass(r: CaseRunner, backend: Backend) !void {
        if (r.options.verbose) try r.caseContext(backend, "ok");
    }

    fn skip(r: CaseRunner, backend: Backend) !void {
        if (r.options.verbose) try r.caseContext(backend, "skip");
    }

    fn writeActualCaptures(r: CaseRunner, label: []const u8, actual: ?Regex.Captures) !void {
        try r.w.writeAll(label);
        const capt = actual orelse {
            try r.w.writeAll("null\n");
            return;
        };
        try r.w.writeAll("[");
        for (0..capt.len()) |i| {
            if (i > 0) try r.w.writeAll(", ");
            try r.w.print("{any}", .{capt.get(i)});
        }
        try r.w.writeAll("]\n");
    }
};

/// Execution engines available to suite cases.
const Backend = enum {
    pikevm,
    onepass,
    dfa,
    backtrack,

    const CaptureCap = enum { full, bounds_only };

    fn Engine(self: Backend) type {
        const engine_type = switch (self) {
            .pikevm => PikeVm,
            else => @panic("not yet implemented"),
        };
        return engine_type;
    }

    fn captureCap(self: Backend) CaptureCap {
        return switch (self) {
            .pikevm => .full,
            else => @panic("not yet implemented"),
        };
    }

    fn supports(self: Backend, prog: *const Program, tc: Case) !void {
        _ = prog;
        _ = tc;
        switch (self) {
            .pikevm => {},
            else => @panic("not yet implemented"),
        }
    }
};
