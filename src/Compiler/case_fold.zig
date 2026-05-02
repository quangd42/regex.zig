// Temp function for unicode simple case folding so we can test
pub fn appendSimpleFold(gpa: Allocator, set: *ScalarRangeSet, range: ScalarRange) Allocator.Error!void {
    try range.appendAsciiFold(gpa, set);
    for (table) |entry| {
        if (!range.contains(entry.key)) continue;
        for (entry.val) |cp| {
            try set.append(gpa, .init(cp, cp));
        }
    }
}

const Entry = struct {
    key: u21,
    val: []const u21,
};

const kelvin: u21 = 0x212A;
const long_s: u21 = 0x017F;
const sigma_upper: u21 = 0x03A3;
const sigma_lower: u21 = 0x03C3;
const sigma_final: u21 = 0x03C2;

const table = [_]Entry{
    .{ .key = 'K', .val = &.{ 'k', kelvin } },
    .{ .key = 'k', .val = &.{ 'K', kelvin } },
    .{ .key = kelvin, .val = &.{ 'K', 'k' } },
    .{ .key = 'S', .val = &.{ 's', long_s } },
    .{ .key = 's', .val = &.{ 'S', long_s } },
    .{ .key = long_s, .val = &.{ 'S', 's' } },
    .{ .key = sigma_upper, .val = &.{ sigma_lower, sigma_final } },
    .{ .key = sigma_lower, .val = &.{ sigma_upper, sigma_final } },
    .{ .key = sigma_final, .val = &.{ sigma_upper, sigma_lower } },
};

const std = @import("std");
const Allocator = std.mem.Allocator;

const ranges = @import("ranges.zig");
const ScalarRange = ranges.ScalarRange;
const ScalarRangeSet = ranges.ScalarRangeSet;
