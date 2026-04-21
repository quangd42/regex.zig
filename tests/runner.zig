const std = @import("std");
const mem = std.mem;
const harness = @import("harness.zig");

const suites = [_]harness.Suite{
    @import("cases/empty.zig").suite,
    @import("cases/flags.zig").suite,
    @import("cases/multiline.zig").suite,
    @import("fowler/basic.zig").suite,
    @import("fowler/repetition.zig").suite,
    @import("fowler/nullsubexpr.zig").suite,
};

pub fn main() void {
    var arg_buffer: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arg_buffer);
    const parsed = parseArgs(fba.allocator()) catch |err| switch (err) {
        error.InvalidArgument, error.MissingArgumentValue => {
            std.debug.print("invalid test runner arguments\n", .{});
            std.process.exit(1);
        },
        else => {
            std.debug.print("test runner error: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        },
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
            runOne(suite, tc, options, &summary);
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

fn parseArgs(gpa: mem.Allocator) !ParsedArgs {
    const args = try std.process.argsAlloc(gpa);
    // Keep the argv allocation alive for the duration of the run so
    // `ParsedArgs.case_name` can use it.

    var parsed: ParsedArgs = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (mem.eql(u8, arg, "--trace")) {
            parsed.trace = true;
            continue;
        }
        if (mem.eql(u8, arg, "--verbose")) {
            parsed.verbose = true;
            continue;
        }
        if (try readCaseName(args, &i, "--case")) |value| {
            parsed.case_name = value;
            continue;
        }
        if (try readCaseName(args, &i, "--contains")) |value| {
            parsed.contains = value;
            continue;
        }
        return error.InvalidArgument;
    }

    return parsed;
}

fn readCaseName(args: []const [:0]u8, i: *usize, comptime name: []const u8) !?[]const u8 {
    const arg = args[i.*];
    if (mem.eql(u8, arg, name)) {
        i.* += 1;
        if (i.* >= args.len) return error.MissingArgumentValue;
        if (args[i.*].len == 0) return error.InvalidArgument;
        return args[i.*];
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
    suite: harness.Suite,
    tc: harness.Case,
    options: harness.Options,
    summary: *Summary,
) void {
    var gpa_state: std.heap.GeneralPurposeAllocator(.{}) = .init;
    const gpa = gpa_state.allocator();

    var failed = false;

    suite.runCase(gpa, options, tc) catch |err| switch (err) {
        else => {
            failed = true;
            std.debug.print("FAIL {s}/{s} ({s})\n", .{ suite.name, tc.name, @errorName(err) });
            if (@errorReturnTrace()) |stack_trace| {
                std.debug.dumpStackTrace(stack_trace.*);
            }
        },
    };

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
            return containsName(needle, suite_name, case_name) catch |err| {
                std.debug.print("test runner error: {s}\n", .{@errorName(err)});
                std.process.exit(1);
            };
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

        const slash = mem.lastIndexOfScalar(u8, exact, '/') orelse return false;
        return mem.eql(u8, exact[0..slash], suite_name) and
            mem.eql(u8, exact[slash + 1 ..], case_name);
    }

    fn containsName(needle: []const u8, suite_name: []const u8, case_name: []const u8) !bool {
        var buf: [256]u8 = undefined;
        const full_len = suite_name.len + 1 + case_name.len;
        if (full_len > buf.len) return error.TestNameTooLong;

        @memcpy(buf[0..suite_name.len], suite_name);
        buf[suite_name.len] = '/';
        @memcpy(buf[suite_name.len + 1 .. full_len], case_name);

        return mem.containsAtLeast(u8, buf[0..full_len], 1, needle);
    }
};
