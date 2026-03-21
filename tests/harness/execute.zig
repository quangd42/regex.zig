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

    const missing = tc.requires.differenceWith(backend.capabilities());
    if (missing.count() > 0) {
        if (opts.verbose) printSkipReason(tc.name, missing);
        return error.SkipZigTest;
    }

    var diag: Regex.Diagnostics = undefined;
    const prog = Compiler.compile(gpa, tc.pattern, .{
        .diagnostics = &diag,
        .limits = tc.options.limits,
    }) catch |err| {
        printCaseContext(tc);
        print("  error: {s}\n", .{@errorName(err)});
        switch (err) {
            error.Parse => switch (diag) {
                .parse => |parse| print("  error tag: {s}\n", .{@tagName(parse.err)}),
                .compile => unreachable,
            },
            error.Compile => switch (diag) {
                .parse => unreachable,
                .compile => |compile| print("  error tag: {s}\n", .{@tagName(compile)}),
            },
            else => {},
        }
        return error.TestUnexpectedResult;
    };

    const Engine = backend.Engine();
    var engine = try Engine.init(gpa, prog);
    defer engine.deinit();

    if (opts.trace) {
        print(
            "[trace] name={s} pattern=\"{s}\" haystack=\"{s}\" anchored={s}\n",
            .{ tc.name, tc.pattern, tc.input.haystack, if (tc.input.anchored) "true" else "false" },
        );
        engine.prog.dump();
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
        printFailureHeader(tc);
        if (match_failed) printMatchFailure(tc, matched);
        if (find_failed) printFindFailure(tc, found);
        if (captures_failure) |capture_failure| {
            printCapturesFailure(tc, captures, capture_failure);
        }
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

fn printSkipReason(case_name: []const u8, missing: CapSet) void {
    print("[{s}] skip: missing capabilities ({d}): ", .{ case_name, missing.count() });

    var it = missing.iterator();
    var first = true;
    while (it.next()) |cap| {
        if (!first) print(", ", .{});
        first = false;
        print("{s}", .{@tagName(cap)});
    }
    print("\n", .{});
}

fn printCaseContext(tc: Case) void {
    print("[{s}]\n", .{tc.name});
    print("  pattern: {s}\n", .{tc.pattern});
    print("  haystack: {s}\n", .{tc.input.haystack});
    print("  anchored: {s}\n", .{if (tc.input.anchored) "true" else "false"});
}

fn printFailureHeader(tc: Case) void {
    printCaseContext(tc);
    print("  test failed:\n", .{});
}

fn printMatchFailure(tc: Case, matched: bool) void {
    print("    - match() expectation mismatch\n", .{});
    print("      ├─ expected: {any}\n", .{tc.expectedMatch()});
    print("      └─ actual  : {any}\n", .{matched});
}

fn printFindFailure(tc: Case, found: ?Regex.Match) void {
    print("    - find() result mismatch\n", .{});
    print("      ├─ expected: {any}\n", .{tc.expectedFind()});
    print("      └─ actual  : {any}\n", .{found});
}

fn printCapturesFailure(
    tc: Case,
    captures: ?Regex.Captures,
    failure: CaptureFailure,
) void {
    const reason = switch (failure) {
        .non_match => "findCaptures() returned groups for non-match",
        .missing => "findCaptures() returned null",
        .len => "capture group count mismatch",
        .value => "capture group value mismatch",
    };
    print("    - {s}\n", .{reason});
    print("      ├─ expected groups_len: {d}\n", .{tc.expected.len});
    print("      ├─ actual   groups_len: {d}\n", .{if (captures) |capt| capt.groups.len else 0});
    print("      ├─ expected   captures: {any}\n", .{tc.expected});
    if (captures) |capt| {
        print("      └─ actual     captures: {any}\n", .{capt.groups});
    } else {
        print("      └─ actual     captures: null\n", .{});
    }
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const print = std.debug.print;

const export_test = @import("export_test");
const Regex = export_test.Regex;
const Compiler = export_test.Compiler;
const Input = export_test.Input;

const Backend = @import("adapters.zig").Backend;
const caps_mod = @import("capabilities.zig");
const CapSet = caps_mod.CapSet;
