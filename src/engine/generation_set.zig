const std = @import("std");
const Allocator = std.mem.Allocator;

pub fn GenerationSet(comptime T: type) type {
    return struct {
        const Self = @This();

        visited: []T,
        generation: T,

        pub fn init(gpa: Allocator, n: usize) !Self {
            const visited = try gpa.alloc(T, n);
            @memset(visited, 0);
            return .{ .visited = visited, .generation = 1 };
        }

        pub fn deinit(self: *Self, gpa: Allocator) void {
            gpa.free(self.visited);
            self.* = undefined;
        }

        pub fn add(self: *Self, i: usize) bool {
            if (self.contains(i)) return false;
            self.visited[i] = self.generation;
            return true;
        }

        pub fn contains(self: *const Self, i: usize) bool {
            return self.visited[i] == self.generation;
        }

        pub fn clear(self: *Self) void {
            self.generation +%= 1; // wrapping add

            // If generation wrapped to 0, reset the whole array once.
            if (self.generation == 0) {
                @memset(self.visited, 0);
                self.generation = 1;
            }
        }
    };
}
