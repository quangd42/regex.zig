const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;
const print = std.debug.print;

const Config = @This();

suite_filter: ?[]u8 = null,
case_filter: ?[]u8 = null,
max_failures: usize = 1,
verbose: bool = false,
trace: bool = false,

pub fn init(gpa: Allocator) !Config {
    return .{
        .suite_filter = try loadStringOwned(gpa, "REGEX_SUITE"),
        .case_filter = try loadStringOwned(gpa, "REGEX_CASE"),
        .max_failures = try loadUsize(gpa, "REGEX_MAX_FAILURES", 1),
        .verbose = try loadBool(gpa, "REGEX_VERBOSE"),
        .trace = try loadBool(gpa, "REGEX_TRACE"),
    };
}

pub fn deinit(config: *Config, gpa: Allocator) void {
    if (config.suite_filter) |suite_filter| gpa.free(suite_filter);
    if (config.case_filter) |case_filter| gpa.free(case_filter);
    config.* = undefined;
}

fn loadStringOwned(gpa: Allocator, key: []const u8) !?[]u8 {
    return std.process.getEnvVarOwned(gpa, key) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => err,
    };
}

fn loadBool(gpa: Allocator, key: []const u8) !bool {
    const value = try loadStringOwned(gpa, key) orelse return false;
    defer gpa.free(value);

    const eql = std.ascii.eqlIgnoreCase;

    if (mem.eql(u8, value, "1")) return true;
    if (eql(value, "true")) return true;
    if (eql(value, "yes")) return true;
    if (eql(value, "on")) return true;

    if (mem.eql(u8, value, "0")) return false;
    if (eql(value, "false")) return false;
    if (eql(value, "no")) return false;
    if (eql(value, "off")) return false;

    std.debug.print(
        "invalid {s} value `{s}`. use one of: 1,true,yes,on,0,false,no,off\n",
        .{ key, value },
    );
    return error.InvalidEnvironmentValue;
}

fn loadUsize(gpa: Allocator, key: []const u8, default: usize) !usize {
    const value = try loadStringOwned(gpa, key) orelse return default;
    defer gpa.free(value);

    const parsed = std.fmt.parseInt(usize, value, 10) catch {
        std.debug.print("invalid {s} value `{s}`. expected unsigned integer\n", .{ key, value });
        return error.InvalidEnvironmentValue;
    };
    if (parsed == 0) {
        std.debug.print("invalid {s} value `0`. value must be >= 1\n", .{key});
        return error.InvalidEnvironmentValue;
    }
    return parsed;
}
