const std = @import("std");
const Allocator = std.mem.Allocator;

const export_test = @import("export_test");
const Regex = export_test.Regex;
const Compiler = export_test.Compiler;
const PikeVm = export_test.PikeVm;
const Program = export_test.Program;
const Input = Regex.Input;

/// Inclusive-exclusive byte span written as `{ start, end }`.
pub const Span = struct { usize, usize };

/// Capture spans for one match. Item 0 is the full match; later items are
/// explicit capturing groups. `null` means the group did not participate.
pub const CaptureSpans = []const ?Span;

/// Expected search result for a case.
pub const Expected = union(enum) {
    /// Leftmost first, span only.
    one_: ?Span,
    /// Leftmost first, captures.
    one_captures: CaptureSpans,
    /// All results, span only.
    all_: []const Span,
    /// All results, captures.
    all_captures: []const CaptureSpans,

    pub fn one(span: ?Span) Expected {
        return .{ .one_ = span };
    }

    pub fn capt(spans: CaptureSpans) Expected {
        assertCaptures(spans);
        return .{ .one_captures = spans };
    }

    pub fn all(spans: []const Span) Expected {
        return .{ .all_ = spans };
    }

    pub fn allCapt(matches: []const CaptureSpans) Expected {
        for (matches) |spans| assertCaptures(spans);
        return .{ .all_captures = matches };
    }

    fn assertCaptures(spans: CaptureSpans) void {
        if (spans.len == 0 or spans[0] == null) {
            @panic("capture expectations must include group 0; use .one(null) for no match");
        }
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

    fn expectedFind(tc: Case) ?Regex.Match {
        return switch (tc.expected) {
            .one_ => |span| toMatch(span),
            .one_captures => |spans| toMatch(spans[0]),
            .all_, .all_captures => @panic("need findAll support"),
        };
    }

    fn expectedMatch(tc: Case) bool {
        return tc.expectedFind() != null;
    }

    fn compare(tc: Case, actual: Actual) ?Failure {
        const out: Failure = .{
            .match = actual.matched != tc.expectedMatch(),
            .find = !std.meta.eql(actual.found, tc.expectedFind()),
            .captures = switch (tc.expected) {
                .one_ => null,
                .one_captures => |expected_captures| compareCaptures(expected_captures, actual.captures),
                .all_, .all_captures => @panic("need findAll support"),
            },
        };
        if (out.any()) return out;
        return null;
    }

    fn compareCaptures(expected: CaptureSpans, actual: ?Regex.Captures) ?Failure.Capture {
        Expected.assertCaptures(expected);

        const captures = actual orelse return .missing;
        if (captures.len() != expected.len) return .len;

        for (expected, 0..) |span, i| {
            if (!std.meta.eql(captures.get(i), toMatch(span))) return .value;
        }

        return null;
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

    pub fn run(s: Suite, gpa: Allocator, options: Options) !void {
        for (s.cases) |tc| {
            try s.runCase(gpa, options, tc);
        }
    }

    pub fn runCase(s: Suite, gpa: Allocator, options: Options, tc: Case) !void {
        try s.runBackend(gpa, options, tc, .pikevm);
    }

    fn runBackend(
        s: Suite,
        gpa: Allocator,
        options: Options,
        tc: Case,
        comptime backend: Backend,
    ) !void {
        var stderr_buf: [4096]u8 = undefined;
        var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
        const stderr = &stderr_writer.interface;
        const report: Reporter = .new(stderr, backend, s.name, tc);

        var diag: Regex.Diagnostics = undefined;
        var compile_opts = tc.options;
        compile_opts.diag = &diag;
        const prog = Compiler.compile(gpa, tc.pattern, compile_opts) catch |err| {
            try report.compileFailure(diag, err);
            try stderr.flush();
            return error.TestUnexpectedResult;
        };
        defer prog.deinit();

        const Engine = backend.Engine();
        var engine = try Engine.init(gpa, prog);
        defer engine.deinit();

        if (options.trace) {
            try report.traceHeader();
            try engine.prog.dump(stderr);
            try stderr.flush();
        }

        const input = tc.input();
        const matched = engine.match(input);
        const found = engine.find(input);
        const captures = switch (tc.expected) {
            .one_ => null,
            .one_captures => engine.findCaptures(input),
            .all_, .all_captures => @panic("need findAll support"),
        };
        const actual: Actual = .{
            .matched = matched,
            .found = found,
            .captures = captures,
        };
        const failure = tc.compare(actual) orelse {
            if (options.verbose) {
                try report.casePass();
                try stderr.flush();
            }
            return;
        };

        try report.caseFailure(actual, failure);
        try stderr.flush();
        return error.TestUnexpectedResult;
    }
};

const Actual = struct {
    matched: bool,
    found: ?Regex.Match,
    captures: ?Regex.Captures,
};

const Failure = struct {
    match: bool = false,
    find: bool = false,
    captures: ?Capture = null,

    fn any(failure: Failure) bool {
        return failure.match or failure.find or failure.captures != null;
    }

    const Capture = enum { missing, len, value };
};

const Reporter = struct {
    w: *std.Io.Writer,
    backend: Backend,
    suite_name: []const u8,
    tc: Case,

    fn new(w: *std.Io.Writer, backend: Backend, suite_name: []const u8, tc: Case) Reporter {
        return .{
            .w = w,
            .backend = backend,
            .suite_name = suite_name,
            .tc = tc,
        };
    }

    fn traceHeader(r: Reporter) !void {
        try r.w.print(
            "[trace] backend={s} name={s}/{s} pattern=\"{s}\" haystack=\"{s}\" window={d}..{?} anchored={s}\n",
            .{
                @tagName(r.backend),
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

    fn compileFailure(r: Reporter, diag: Regex.Diagnostics, err: anyerror) !void {
        try r.caseContext();
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

    fn caseFailure(r: Reporter, actual: Actual, f: Failure) !void {
        try r.caseContext();
        try r.w.writeAll("  test failed:\n");

        if (f.match) {
            try r.w.writeAll("    - match() expectation mismatch\n");
            try r.w.print("      ├─ expected: {any}\n", .{r.tc.expectedMatch()});
            try r.w.print("      └─ actual  : {any}\n", .{actual.matched});
        }

        if (f.find) {
            try r.w.writeAll("    - find() result mismatch\n");
            try r.w.print("      ├─ expected: {any}\n", .{r.tc.expectedFind()});
            try r.w.print("      └─ actual  : {any}\n", .{actual.found});
        }

        if (f.captures) |capture_f| {
            const expected_captures = switch (r.tc.expected) {
                .one_captures => |spans| captures: {
                    Expected.assertCaptures(spans);
                    break :captures spans;
                },
                .one_ => @panic("capture failure needs a capture expectation"),
                .all_, .all_captures => @panic("all-match expectations need findAll harness support"),
            };
            const reason = switch (capture_f) {
                .missing => "findCaptures() returned null",
                .len => "capture group count mismatch",
                .value => "capture group value mismatch",
            };
            try r.w.print("    - {s}\n", .{reason});
            try r.w.print("      ├─ expected groups_len: {d}\n", .{expected_captures.len});
            try r.w.print("      ├─ actual   groups_len: {d}\n", .{if (actual.captures) |capt| capt.len() else 0});
            try r.w.print("      ├─ expected   captures: {any}\n", .{expected_captures});
            if (actual.captures) |capt| {
                try r.w.writeAll("      └─ actual     captures: [");
                for (0..capt.len()) |i| {
                    if (i > 0) try r.w.writeAll(", ");
                    try r.w.print("{any}", .{capt.get(i)});
                }
                try r.w.writeAll("]\n");
            } else {
                try r.w.writeAll("      └─ actual     captures: null\n");
            }
        }
    }

    fn casePass(r: Reporter) !void {
        try r.w.print("[{s}/{s} backend={s}] ok\n", .{ r.suite_name, r.tc.name, @tagName(r.backend) });
    }

    fn caseContext(r: Reporter) !void {
        try r.w.print("[{s}/{s} backend={s}]\n", .{ r.suite_name, r.tc.name, @tagName(r.backend) });
        try r.w.print("  pattern: {s}\n", .{r.tc.pattern});
        try r.w.print("  haystack: {s}\n", .{r.tc.haystack});
        try r.w.print("  window: {d}..{?}\n", .{ r.tc.start, r.tc.end });
        try r.w.print("  anchored: {s}\n", .{if (r.tc.anchored) "true" else "false"});
    }
};

/// Execution engines available to suite cases.
///
/// New backends must expose the method shape checked by `assertBackendType`.
pub const Backend = enum {
    pikevm,
    onepass,
    dfa,
    backtrack,

    pub fn Engine(self: Backend) type {
        const engine_type = switch (self) {
            .pikevm => PikeVm,
            else => @panic("not yet implemented"),
        };
        comptime assertBackendType(engine_type);
        return engine_type;
    }
};

fn assertBackendType(comptime T: type) void {
    if (!@hasField(T, "prog")) @compileError("backend type must expose `prog` for trace dumps");
    if (@FieldType(T, "prog") != *const Program) @compileError("backend `prog` field must be *const Program");

    assertFnShape(
        T,
        "init",
        &.{ Allocator, *const Program },
        anyerror!T,
        "fn (Allocator, *const Program) !Backend",
    );
    assertFnShape(
        T,
        "deinit",
        &.{*T},
        void,
        "fn (*Backend) void",
    );
    assertFnShape(
        T,
        "match",
        &.{ *T, Input },
        bool,
        "fn (*Backend, Input) bool",
    );
    assertFnShape(
        T,
        "find",
        &.{ *T, Input },
        ?Regex.Match,
        "fn (*Backend, Input) ?Match",
    );
    assertFnShape(
        T,
        "findCaptures",
        &.{ *T, Input },
        ?Regex.Captures,
        "fn (*Backend, Input) ?Captures",
    );
}

fn assertFnShape(
    comptime T: type,
    comptime fn_name: []const u8,
    comptime param_types: []const type,
    comptime expected_return_type: type,
    comptime signature: []const u8,
) void {
    const message = std.fmt.comptimePrint("{s} must be defined with signature `{s}`", .{ fn_name, signature });
    const is_method = param_types.len > 0 and param_types[0] == *T;
    const has_decl = if (is_method) std.meta.hasMethod(T, fn_name) else std.meta.hasFn(T, fn_name);
    if (!has_decl) @compileError(message);

    const fn_type = @TypeOf(@field(T, fn_name));
    const fn_info = @typeInfo(fn_type).@"fn";
    if (fn_info.params.len != param_types.len) @compileError(message);
    inline for (param_types, fn_info.params) |expected, actual_param| {
        if (actual_param.type != expected) @compileError(message);
    }

    const return_type = fn_info.return_type orelse @compileError(message);
    const expected_return_info = @typeInfo(expected_return_type);
    switch (expected_return_info) {
        .error_union => |expected| {
            const return_info = @typeInfo(return_type);
            if (return_info != .error_union) @compileError(message);
            if (return_info.error_union.payload != expected.payload) @compileError(message);
        },
        else => {
            if (return_type != expected_return_type) @compileError(message);
        },
    }
}
