pub const Case = struct {
    name: []const u8,
    pattern: []const u8,
    options: Regex.Options = .{},
    haystack: []const u8,
    expected: []const ?Regex.Match,
    requires: CapSet = .initEmpty(),

    pub fn expectedFind(tc: Case) ?Regex.Match {
        return if (tc.expected.len > 0) tc.expected[0] else null;
    }

    pub fn expectedMatch(tc: Case) bool {
        return tc.expectedFind() != null;
    }
};

pub const Result = struct {
    matched: bool,
    found: ?Regex.Match,
    captures: ?Regex.Captures,

    pub fn deinit(self: *Result, gpa: Allocator) void {
        if (self.captures) |capt| gpa.free(capt.groups);
    }
};

pub const RunOptions = struct {
    verbose: bool,
    trace: bool,
};

const Stats = struct {
    selected: usize = 0,
    passed: usize = 0,
    skipped: usize = 0,
    failed: usize = 0,
};

pub fn runSuite(gpa: Allocator, suite_name: []const u8, cases: []const Case, comptime backend: Backend) !void {
    comptime caps_mod.assertCapBaseline(backend);

    var config: Config = try .init(gpa);
    defer config.deinit(gpa);

    if (config.suite_filter) |filter| {
        if (mem.indexOf(u8, suite_name, filter) == null) return;
    }

    const Adapter = backend.Adapter();
    const caps: CapSet = backend.capabilities();
    var stats: Stats = .{};

    for (cases) |tc| {
        if (config.case_filter) |filter| {
            if (!matchesCaseFilter(filter, suite_name, tc.name)) continue;
        }
        stats.selected += 1;

        const missing = tc.requires.differenceWith(caps);
        if (missing.count() > 0) {
            stats.skipped += 1;
            if (config.verbose) printSkipReason(suite_name, tc.name, missing);
            continue;
        }

        var result: Result = Adapter.run(gpa, tc, .{
            .verbose = config.verbose,
            .trace = config.trace,
        }) catch |err| {
            stats.failed += 1;
            printCaseContext(suite_name, tc);
            print("  error: {s}\n", .{@errorName(err)});
            if (stats.failed >= config.max_failures) break;
            continue;
        };
        defer result.deinit(gpa);

        if (checkResult(tc, result)) |reason| {
            stats.failed += 1;
            printCaseContext(suite_name, tc);
            printFailReason(tc, result, reason);
            if (stats.failed >= config.max_failures) break;
            continue;
        }

        stats.passed += 1;
        if (config.verbose) print("[{s}/{s}] pass\n", .{ suite_name, tc.name });
    }

    print(
        "[{s}] summary: selected={d} pass={d} skip={d} fail={d}\n",
        .{ suite_name, stats.selected, stats.passed, stats.skipped, stats.failed },
    );

    if (stats.failed > 0) return error.TestUnexpectedResult;
}

fn matchesCaseFilter(filter: []const u8, suite_name: []const u8, case_name: []const u8) bool {
    if (mem.indexOfScalar(u8, filter, '/')) |slash| {
        const suite_filter = filter[0..slash];
        const case_filter = filter[slash + 1 ..];

        const suite_matches = suite_filter.len == 0 or mem.eql(u8, suite_name, suite_filter);
        const case_matches = case_filter.len == 0 or mem.eql(u8, case_name, case_filter);
        return suite_matches and case_matches;
    }

    return mem.eql(u8, suite_name, filter) or mem.eql(u8, case_name, filter);
}

fn checkResult(tc: Case, result: Result) ?[]const u8 {
    const expected_find = tc.expectedFind();
    const expected_match = tc.expectedMatch();

    if (result.matched != expected_match) return "match() expectation mismatch";
    if (!std.meta.eql(result.found, expected_find)) return "find() result mismatch";

    if (!expected_match) {
        if (result.captures != null) return "findCaptures() returned groups for non-match";
        return null;
    }

    const captures = result.captures orelse return "findCaptures() returned null";
    if (captures.groups.len != tc.expected.len) return "capture group count mismatch";

    for (captures.groups, tc.expected) |actual, expected| {
        if (!std.meta.eql(actual, expected)) return "capture group value mismatch";
    }

    return null;
}

fn printSkipReason(suite_name: []const u8, case_name: []const u8, missing: CapSet) void {
    print(
        "[{s}/{s}] skip: missing capabilities ({d}): ",
        .{ suite_name, case_name, missing.count() },
    );

    var it = missing.iterator();
    var first = true;
    while (it.next()) |cap| {
        if (!first) std.debug.print(", ", .{});
        first = false;
        print("{s}", .{@tagName(cap)});
    }
    print("\n", .{});
}

fn printCaseContext(suite_name: []const u8, tc: Case) void {
    print("[{s}/{s}]\n", .{ suite_name, tc.name });
    print("  pattern: {s}\n", .{tc.pattern});
    print("  haystack: {s}\n", .{tc.haystack});
}

fn printFailReason(tc: Case, result: Result, reason: []const u8) void {
    print("  test failed: {s}\n", .{reason});
    print("  expected.match: {any}\n", .{tc.expectedMatch()});
    print("  actual.match: {any}\n", .{result.matched});
    print("  expected.find: {any}\n", .{tc.expectedFind()});
    print("  actual.find: {any}\n", .{result.found});
    print("  expected.groups_len: {d}\n", .{tc.expected.len});
    print("  actual.groups_len: {d}\n", .{if (result.captures) |capt| capt.groups.len else 0});
    print("  expected.captures: {any}\n", .{tc.expected});
    if (result.captures) |capt| {
        print("  actual.captures: {any}\n", .{capt.groups});
    } else {
        print("  actual.captures: null\n", .{});
    }
}

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const print = std.debug.print;

const Regex = @import("export_test").Regex;
const Backend = @import("adapters.zig").Backend;
const caps_mod = @import("capabilities.zig");
const CapSet = caps_mod.CapSet;
const Config = @import("Config.zig");
