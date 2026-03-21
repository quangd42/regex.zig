const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;

pub const std_options: std.Options = .{
    .logFn = log,
};

pub var verbose: bool = false;
pub var trace: bool = false;

var log_err_count: usize = 0;

pub fn main() void {
    @disableInstrumentation();
    mainImpl() catch |err| switch (err) {
        error.UnknownCase => std.process.exit(1),
        error.InvalidArgument, error.MissingArgumentValue => {
            std.debug.print("invalid test runner arguments\n", .{});
            std.process.exit(1);
        },
        else => {
            std.debug.print("test runner error: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        },
    };
}

fn mainImpl() !void {
    var arg_buffer: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arg_buffer);
    const parsed = try parseArgs(fba.allocator());

    verbose = parsed.verbose;
    trace = parsed.trace;

    var summary: Summary = .{};
    for (builtin.test_functions) |test_fn| {
        const case_name = caseName(test_fn.name);
        if (!matchesSelectedCase(parsed.case_name, case_name)) continue;
        summary.selected += 1;
        runOne(test_fn, case_name, &summary);
    }

    if (parsed.case_name) |name| if (summary.selected == 0) {
        std.debug.print("unknown test case '{s}'\n", .{name});
        return error.UnknownCase;
    };

    const success = summary.failed == 0 and summary.leaked == 0 and summary.logged_errors == 0;
    if (verbose) printSummary(summary);
    if (!success) std.process.exit(1);
}

fn parseArgs(gpa: std.mem.Allocator) !ParsedArgs {
    const args = try std.process.argsAlloc(gpa);
    // Keep the argv allocation alive for the duration of the run so
    // `ParsedArgs.case_name` can borrow slices from it.

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
        if (mem.eql(u8, arg, "--case")) {
            i += 1;
            if (i >= args.len) return error.MissingArgumentValue;
            if (args[i].len == 0) return error.InvalidArgument;
            parsed.case_name = args[i];
            continue;
        }
        if (mem.startsWith(u8, arg, "--case=")) {
            const value = arg["--case=".len..];
            if (value.len == 0) return error.InvalidArgument;
            parsed.case_name = value;
            continue;
        }
        return error.InvalidArgument;
    }

    return parsed;
}

fn runOne(test_fn: std.builtin.TestFn, test_name: []const u8, summary: *Summary) void {
    testing.allocator_instance = .{};
    testing.log_level = .warn;
    log_err_count = 0;

    var failed = false;
    var skipped = false;

    test_fn.func() catch |err| switch (err) {
        error.SkipZigTest => {
            skipped = true;
        },
        else => {
            failed = true;
            printFailure(test_name, err);
        },
    };

    const leaked = testing.allocator_instance.deinit() == .leak;
    const logged_errors = log_err_count;

    if (failed) {
        summary.failed += 1;
    } else if (skipped) {
        summary.skipped += 1;
    } else {
        summary.passed += 1;
    }

    if (leaked) {
        summary.leaked += 1;
        std.debug.print("LEAK {s}\n", .{test_name});
    }

    if (logged_errors != 0) {
        summary.logged_errors += logged_errors;
        std.debug.print("LOG ERRORS {s}: {d}\n", .{ test_name, logged_errors });
    }
}

fn matchesSelectedCase(case_name: ?[]const u8, test_name: []const u8) bool {
    const selected = case_name orelse return true;
    if (mem.indexOfScalar(u8, selected, '/')) |_| {
        return mem.eql(u8, test_name, selected);
    }

    const last_slash = mem.lastIndexOfScalar(u8, test_name, '/') orelse return mem.eql(u8, test_name, selected);
    return mem.eql(u8, test_name[last_slash + 1 ..], selected);
}

fn caseName(test_name: []const u8) []const u8 {
    const needle = ".test.";
    const start = mem.indexOf(u8, test_name, needle) orelse return test_name;
    return test_name[start + needle.len ..];
}

fn printFailure(test_name: []const u8, err: anyerror) void {
    std.debug.print("FAIL {s} ({s})\n", .{ test_name, @errorName(err) });
    if (@errorReturnTrace()) |stack_trace| {
        std.debug.dumpStackTrace(stack_trace.*);
    }
}

fn printSummary(summary: Summary) void {
    std.debug.print(
        "selected: {d}; passed: {d}; skipped: {d}; failed: {d}\n",
        .{ summary.selected, summary.passed, summary.skipped, summary.failed },
    );
    if (summary.leaked != 0) {
        std.debug.print("{d} tests leaked memory.\n", .{summary.leaked});
    }
    if (summary.logged_errors != 0) {
        std.debug.print("{d} errors were logged.\n", .{summary.logged_errors});
    }
}

pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    @disableInstrumentation();
    if (@intFromEnum(message_level) <= @intFromEnum(std.log.Level.err)) {
        log_err_count +|= 1;
    }
    if (@intFromEnum(message_level) <= @intFromEnum(testing.log_level)) {
        std.debug.print(
            "[" ++ @tagName(scope) ++ "] (" ++ @tagName(message_level) ++ "): " ++ format ++ "\n",
            args,
        );
    }
}

const mem = std.mem;

const Summary = struct {
    selected: usize = 0,
    passed: usize = 0,
    skipped: usize = 0,
    failed: usize = 0,
    leaked: usize = 0,
    logged_errors: usize = 0,
};

const ParsedArgs = struct {
    case_name: ?[]const u8 = null,
    verbose: bool = false,
    trace: bool = false,
};
