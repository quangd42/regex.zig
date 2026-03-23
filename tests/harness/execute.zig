pub const Case = struct {
    name: []const u8,
    pattern: []const u8,
    options: Regex.Options = .{},
    input: Input,
    expected: []const ?Regex.Match,
    requires: CapSet = .initEmpty(),

    pub fn expectedFind(tc: Case) ?Regex.Match {
        return if (tc.expected.len > 0) tc.expected[0] else null;
    }

    pub fn expectedMatch(tc: Case) bool {
        return tc.expectedFind() != null;
    }
};

pub const Options = struct {
    verbose: bool,
    trace: bool,
};

const CaptureFailure = enum {
    non_match,
    missing,
    len,
    value,
};

pub fn execute(
    gpa: Allocator,
    tc: Case,
    comptime backend: Backend,
    opts: Options,
) !void {
    comptime caps_mod.assertCapBaseline(backend);

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    const stderr = &stderr_writer.interface;

    const missing = tc.requires.differenceWith(backend.capabilities());
    if (missing.count() > 0) {
        if (opts.verbose) {
            try printSkipReason(stderr, tc.name, missing);
            try stderr.flush();
        }
        return error.SkipZigTest;
    }

    var diag: Regex.Diagnostics = undefined;
    const prog = Compiler.compile(gpa, tc.pattern, .{
        .diagnostics = &diag,
        .limits = tc.options.limits,
    }) catch |err| {
        try printCaseContext(stderr, tc);
        try stderr.print("  error: {s}\n", .{@errorName(err)});
        switch (err) {
            error.Parse => switch (diag) {
                .parse => |parse| try stderr.print("  error tag: {s}\n", .{@tagName(parse.err)}),
                .compile => unreachable,
            },
            error.Compile => switch (diag) {
                .parse => unreachable,
                .compile => |compile| try stderr.print("  error tag: {s}\n", .{@tagName(compile)}),
            },
            else => {},
        }
        try stderr.flush();
        return error.TestUnexpectedResult;
    };

    const Engine = backend.Engine();
    var engine = try Engine.init(gpa, prog);
    defer engine.deinit();

    if (opts.trace) {
        try stderr.print(
            "[trace] name={s} pattern=\"{s}\" haystack=\"{s}\" anchored={s}\n",
            .{ tc.name, tc.pattern, tc.input.haystack, if (tc.input.anchored) "true" else "false" },
        );
        try engine.prog.dump(stderr);
        try stderr.flush();
    }

    const matched = engine.match(tc.input);
    const found = engine.find(tc.input);
    const captures = try engine.findCapturesAlloc(gpa, tc.input);
    defer if (captures) |capt| gpa.free(capt.groups);

    const match_failed = checkMatch(tc, matched);
    const find_failed = checkFind(tc, found);
    const captures_failure = checkCaptures(tc, captures);
    const failed = match_failed or find_failed or captures_failure != null;

    if (failed) {
        try printFailureHeader(stderr, tc);
        if (match_failed) try printMatchFailure(stderr, tc, matched);
        if (find_failed) try printFindFailure(stderr, tc, found);
        if (captures_failure) |capture_failure| {
            try printCapturesFailure(stderr, tc, captures, capture_failure);
        }
        try stderr.flush();
        return error.TestUnexpectedResult;
    }
}

fn checkMatch(tc: Case, matched: bool) bool {
    return matched != tc.expectedMatch();
}

fn checkFind(tc: Case, found: ?Regex.Match) bool {
    return !std.meta.eql(found, tc.expectedFind());
}

fn checkCaptures(tc: Case, captures: ?Regex.Captures) ?CaptureFailure {
    if (!tc.expectedMatch()) {
        return if (captures != null) .non_match else null;
    }

    const actual_captures = captures orelse return .missing;
    if (actual_captures.groups.len != tc.expected.len) return .len;

    for (actual_captures.groups, tc.expected) |actual, expected| {
        if (!std.meta.eql(actual, expected)) return .value;
    }

    return null;
}

fn printSkipReason(w: *std.Io.Writer, case_name: []const u8, missing: CapSet) !void {
    try w.print("[{s}] skip: missing capabilities ({d}): ", .{ case_name, missing.count() });

    var it = missing.iterator();
    var first = true;
    while (it.next()) |cap| {
        if (!first) try w.writeAll(", ");
        first = false;
        try w.print("{s}", .{@tagName(cap)});
    }
    try w.writeByte('\n');
}

fn printCaseContext(w: *std.Io.Writer, tc: Case) !void {
    try w.print("[{s}]\n", .{tc.name});
    try w.print("  pattern: {s}\n", .{tc.pattern});
    try w.print("  haystack: {s}\n", .{tc.input.haystack});
    try w.print("  anchored: {s}\n", .{if (tc.input.anchored) "true" else "false"});
}

fn printFailureHeader(w: *std.Io.Writer, tc: Case) !void {
    try printCaseContext(w, tc);
    try w.writeAll("  test failed:\n");
}

fn printMatchFailure(w: *std.Io.Writer, tc: Case, matched: bool) !void {
    try w.writeAll("    - match() expectation mismatch\n");
    try w.print("      ├─ expected: {any}\n", .{tc.expectedMatch()});
    try w.print("      └─ actual  : {any}\n", .{matched});
}

fn printFindFailure(w: *std.Io.Writer, tc: Case, found: ?Regex.Match) !void {
    try w.writeAll("    - find() result mismatch\n");
    try w.print("      ├─ expected: {any}\n", .{tc.expectedFind()});
    try w.print("      └─ actual  : {any}\n", .{found});
}

fn printCapturesFailure(
    w: *std.Io.Writer,
    tc: Case,
    captures: ?Regex.Captures,
    failure: CaptureFailure,
) !void {
    const reason = switch (failure) {
        .non_match => "findCaptures() returned groups for non-match",
        .missing => "findCaptures() returned null",
        .len => "capture group count mismatch",
        .value => "capture group value mismatch",
    };
    try w.print("    - {s}\n", .{reason});
    try w.print("      ├─ expected groups_len: {d}\n", .{tc.expected.len});
    try w.print("      ├─ actual   groups_len: {d}\n", .{if (captures) |capt| capt.groups.len else 0});
    try w.print("      ├─ expected   captures: {any}\n", .{tc.expected});
    if (captures) |capt| {
        try w.print("      └─ actual     captures: {any}\n", .{capt.groups});
    } else {
        try w.writeAll("      └─ actual     captures: null\n");
    }
}

const std = @import("std");
const Allocator = std.mem.Allocator;

const export_test = @import("export_test");
const Regex = export_test.Regex;
const Compiler = export_test.Compiler;
const Input = export_test.Input;

const Backend = @import("adapters.zig").Backend;
const caps_mod = @import("capabilities.zig");
const CapSet = caps_mod.CapSet;
