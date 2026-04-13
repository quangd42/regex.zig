//! Capture-group metadata shared across parsing, compilation, and matching.
//! It tracks the total capture count plus optional name lookup in both directions.

const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const hash_map = std.hash_map;
const assert = std.debug.assert;

const Span = @import("../errors.zig").Span;

pub const CaptureInfo = @This();

/// NUL-terminated capture names stored in encounter order.
/// Offsets in `name_to_index` and `index_to_name` refer into this buffer.
bytes: std.ArrayList(u8),
/// Maps each unique capture name to its user-visible capture index.
/// Group 0, the full match, is never included because it cannot be named.
name_to_index: NameToIndex,
/// Maps capture index to an optional capture name. The default capture 0, the full match,
/// is never stored because it cannot be named, so a user-visible capture index `i > 0`
/// corresponds to `index_to_name[i - 1]`. Unnamed captures are stored as `null`.
index_to_name: []const ?u32,
/// The total number of capturing groups, including the default capture 0 for the full
/// match. It is sized as `u16` so that the slot count `count * 2` will fit into an `u32`.
/// This is an implementation limit.
count: u16,
arena: std.heap.ArenaAllocator,

/// Initializes an empty `CaptureInfo`.
/// Most callers should use `Builder` to construct a populated value.
fn init(gpa: Allocator) CaptureInfo {
    return .{
        .bytes = .empty,
        .name_to_index = .empty,
        .index_to_name = &.{},
        .count = 0,
        .arena = .init(gpa),
    };
}

pub fn deinit(self: *CaptureInfo) void {
    self.arena.deinit();
    self.* = undefined;
}

/// Set this value to an empty state, making it deinit-safe, and
/// return a copy of the original.
pub fn move(self: *CaptureInfo) CaptureInfo {
    const child_allocator = self.arena.child_allocator;
    const out: CaptureInfo = .{
        .bytes = self.bytes,
        .name_to_index = self.name_to_index.move(),
        .index_to_name = self.index_to_name,
        .count = self.count,
        .arena = self.arena,
    };
    self.* = init(child_allocator);
    return out;
}

fn ctx(self: *const CaptureInfo) hash_map.StringIndexContext {
    return .{ .bytes = &self.bytes };
}

fn adapter(self: *const CaptureInfo) hash_map.StringIndexAdapter {
    return .{ .bytes = &self.bytes };
}

/// Returns the capture name for the given user-visible capture index, or null
/// when the index is 0 or the capture is unnamed.
pub fn nameAt(self: *const CaptureInfo, index: u32) ?[]const u8 {
    if (index == 0 or index >= self.count) return null;
    const internal_index = index - 1;
    const start = self.index_to_name[internal_index] orelse return null;
    return std.mem.sliceTo(self.bytes.items[start..], 0);
}

/// Returns the user-visible capture index for the given name, if present.
pub fn indexOf(self: *const CaptureInfo, name: []const u8) ?u16 {
    return self.name_to_index.getAdapted(name, self.adapter());
}

/// Iterates over capture names in capture index order.
/// Unnamed captures, including group 0 for the full match, are yielded as `null`.
pub const NameIterator = struct {
    info: *const CaptureInfo,
    index: u16 = 0,

    /// Returns the next capture name, or `null` when the iterator is exhausted.
    pub fn next(self: *NameIterator) ??[]const u8 {
        if (self.index >= self.info.count) return null;
        const out = self.info.nameAt(self.index);
        self.index += 1;
        return out;
    }
};

/// Returns an iterator over capture names in capture index order.
pub fn names(self: *const CaptureInfo) NameIterator {
    return .{ .info = self };
}

/// Maps interned name offsets in `bytes` to user-visible capture indices.
pub const NameToIndex = std.HashMapUnmanaged(
    u32,
    u16,
    std.hash_map.StringIndexContext,
    std.hash_map.default_max_load_percentage,
);

/// Builds a `CaptureInfo` value while parsing capture groups.
/// Call `.deinit()` on parse failure, or transfer ownership with `.finalize()`.
pub const Builder = struct {
    bytes: ArrayList(u8) = .empty,
    name_to_index: CaptureInfo.NameToIndex = .empty,
    index_to_name: ArrayList(?u32) = .empty,
    /// Parser-only source spans for named captures, used to report duplicates.
    name_spans: ArrayList(?Span) = .empty,
    count: u16 = 1,
    arena: std.heap.ArenaAllocator,

    pub const NamedCaptureResult = union(enum) {
        /// The newly assigned capture index for a unique name.
        added: u16,
        /// The source span of the previously seen capture with the same name.
        duplicate: Span,
    };

    pub fn init(gpa: Allocator) Builder {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(self: *Builder) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Transfers ownership of all accumulated state into a `CaptureInfo` value.
    /// After this call, the builder is reset to an empty state and may be reused or
    /// safely deinitialized.
    pub fn finalize(self: *Builder) !CaptureInfo {
        const child_allocator = self.arena.child_allocator;
        var arena = self.arena;
        const a = arena.allocator();
        const index_to_name = try self.index_to_name.toOwnedSlice(a);
        const out: CaptureInfo = .{
            .bytes = self.bytes,
            .name_to_index = self.name_to_index.move(),
            .index_to_name = index_to_name,
            .count = self.count,
            .arena = arena,
        };
        self.* = Builder.init(child_allocator);
        return out;
    }

    fn nextIndex(self: *Builder) u16 {
        assert(self.count < std.math.maxInt(u16));
        const index = self.count;
        self.count += 1;
        return index;
    }

    /// Records a new named capture and assigns the next user-visible capture index.
    /// On duplicate, returns the span of the previously seen capture with the same name.
    pub fn addNamedCapture(
        self: *Builder,
        capture_name: []const u8,
        name_span: Span,
    ) !NamedCaptureResult {
        const a = self.arena.allocator();
        const name_index: u32 = @intCast(self.bytes.items.len);
        try self.bytes.appendSlice(a, capture_name);

        const gop = try self.name_to_index.getOrPutContextAdapted(
            a,
            capture_name,
            hash_map.StringIndexAdapter{ .bytes = &self.bytes },
            hash_map.StringIndexContext{ .bytes = &self.bytes },
        );
        if (gop.found_existing) {
            self.bytes.shrinkRetainingCapacity(name_index);
            const index = gop.value_ptr.*;
            return .{ .duplicate = self.name_spans.items[index - 1].? };
        }
        const capture_index = self.nextIndex();
        gop.key_ptr.* = name_index;
        gop.value_ptr.* = capture_index;
        try self.bytes.append(a, 0);

        assert(self.index_to_name.items.len + 1 == capture_index);
        try self.index_to_name.append(a, name_index);
        try self.name_spans.append(a, name_span);

        return .{ .added = capture_index };
    }

    /// Explicitly keep track of unnamed capture so that internal index_to_name
    /// is kept in sync with encountered captures.
    pub fn addUnnamedCapture(self: *Builder) !u16 {
        const a = self.arena.allocator();
        try self.index_to_name.append(a, null);
        try self.name_spans.append(a, null);
        return self.nextIndex();
    }
};
