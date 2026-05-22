const std = @import("std");
const mem = std.mem;
const harness = @import("harness.zig");

const suites = [_]harness.Suite{
    @import("cases/empty.zig").suite,
    @import("cases/flags.zig").suite,
    @import("cases/match_iterator.zig").suite,
    @import("cases/multiline.zig").suite,
    @import("cases/search_window.zig").suite,
    @import("fowler/basic.zig").suite,
    @import("fowler/repetition.zig").suite,
    @import("fowler/nullsubexpr.zig").suite,
};

pub fn main(init: std.process.Init) void {
    const parsed = parseArgs(init) catch {
        std.debug.print("invalid test runner arguments\n", .{});
        std.process.exit(1);
    };

    var summary: Summary = .{};
    var matched_case = false;
    const filter: CaseFilter = .{
        .exact = parsed.case_name,
        .contains = parsed.contains,
    };
    const options: harness.Options = .{
        .verbose = parsed.verbose,
        .trace = parsed.trace,
    };

    for (suites) |suite| {
        for (suite.cases) |tc| {
            if (!filter.matches(suite.name, tc.name)) continue;
            matched_case = true;
            runOne(init.io, suite, tc, options, &summary);
        }
    }

    if (filter.active() and !matched_case) {
        filter.printNoMatches();
        std.process.exit(1);
    }

    if (parsed.verbose) std.debug.print(
        "passed: {d}; failed: {d}\n",
        .{ summary.passed, summary.failed },
    );

    if (summary.failed != 0) std.process.exit(1);
}

fn parseArgs(init: std.process.Init) !ParsedArgs {
    var it = try init.minimal.args.iterateAllocator(init.arena.allocator());
    const skipped = it.skip();
    std.debug.assert(skipped);

    var parsed: ParsedArgs = .{};
    while (it.next()) |arg| {
        if (mem.eql(u8, arg, "--trace")) {
            parsed.trace = true;
            continue;
        }
        if (mem.eql(u8, arg, "--verbose")) {
            parsed.verbose = true;
            continue;
        }
        if (try readCaseName(&it, arg, "--case")) |value| {
            parsed.case_name = value;
            continue;
        }
        if (try readCaseName(&it, arg, "--contains")) |value| {
            parsed.contains = value;
            continue;
        }
        return error.InvalidArgument;
    }

    return parsed;
}

fn readCaseName(it: *std.process.Args.Iterator, arg: [:0]const u8, comptime name: []const u8) !?[]const u8 {
    if (mem.eql(u8, arg, name)) {
        const out = it.next() orelse return error.MissingArgumentValue;
        if (out.len == 0) return error.InvalidArgument;
        return out;
    }

    const prefix = name ++ "=";
    if (mem.startsWith(u8, arg, prefix)) {
        const value = arg[prefix.len..];
        if (value.len == 0) return error.InvalidArgument;
        return value;
    }

    return null;
}

fn runOne(
    io: std.Io,
    suite: harness.Suite,
    tc: harness.Case,
    options: harness.Options,
    summary: *Summary,
) void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    const gpa = gpa_state.allocator();
    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    var failed = false;

    harness.runCase(gpa, stderr, suite.name, tc, options) catch |err| {
        stderr.flush() catch {};
        failed = true;
        std.debug.print("FAIL {s}/{s} ({s})\n", .{ suite.name, tc.name, @errorName(err) });
        std.debug.dumpCurrentStackTrace(.{});
    };
    stderr.flush() catch {};

    const leaked = gpa_state.deinit() == .leak;

    if (leaked) {
        std.debug.print("LEAK {s}/{s}\n", .{ suite.name, tc.name });
    }

    if (failed or leaked) {
        summary.failed += 1;
    } else {
        summary.passed += 1;
    }
}

const Summary = struct {
    passed: usize = 0,
    failed: usize = 0,
};

const ParsedArgs = struct {
    case_name: ?[]const u8 = null,
    contains: ?[]const u8 = null,
    verbose: bool = false,
    trace: bool = false,
};

const CaseFilter = struct {
    exact: ?[]const u8 = null,
    contains: ?[]const u8 = null,

    fn active(f: CaseFilter) bool {
        return f.exact != null or f.contains != null;
    }

    fn matches(f: CaseFilter, suite_name: []const u8, case_name: []const u8) bool {
        if (f.exact) |exact| {
            return matchesExact(exact, suite_name, case_name);
        }
        if (f.contains) |needle| {
            return containsName(needle, suite_name, case_name);
        }
        return true;
    }

    fn printNoMatches(f: CaseFilter) void {
        if (f.exact) |exact| {
            std.debug.print("unknown test case '{s}'\n", .{exact});
        } else if (f.contains) |needle| {
            std.debug.print("no test cases contain '{s}'\n", .{needle});
        }
    }

    fn matchesExact(exact: []const u8, suite_name: []const u8, case_name: []const u8) bool {
        if (mem.eql(u8, exact, case_name)) return true;

        const slash = mem.findScalarLast(u8, exact, '/') orelse return false;
        return mem.eql(u8, exact[0..slash], suite_name) and
            mem.eql(u8, exact[slash + 1 ..], case_name);
    }

    fn containsName(needle: []const u8, suite_name: []const u8, case_name: []const u8) bool {
        if (needle.len == 0) return true;

        if (mem.find(u8, suite_name, needle) != null) return true;
        if (mem.find(u8, case_name, needle) != null) return true;

        var pos: usize = 0;
        while (mem.findScalarPos(u8, needle, pos, '/')) |slash| {
            const left = needle[0..slash];
            const right = needle[slash + 1 ..];

            if (mem.endsWith(u8, suite_name, left) and
                mem.startsWith(u8, case_name, right))
            {
                return true;
            }

            pos = slash + 1;
        }

        return false;
    }
};
