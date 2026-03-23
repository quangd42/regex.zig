//! The Compiler compiles parsed Ast into a Thompson-style NFA: a linked collection of State
//! structures. This follows the algorithm presented in http://swtch.com/~rsc/regexp/

const Compiler = @This();

states: ArrayList(State) = .empty,
ranges: ArrayList(ByteRange) = .empty,
scratch_ranges: ArrayList(ByteRange) = .empty,
branches: ArrayList(StateId) = .empty,
arena: std.heap.ArenaAllocator,
options: struct {
    diagnostics: ?*Diagnostics,
    state_limit: usize,
},

/// See `Program.matcher_count`.
matcher_count: u32 = 0,

/// Resources allocated are owned by Program after compilation is done, and caller is expected
/// to call Program.deinit() to free them.
pub fn compile(gpa: Allocator, pattern: []const u8, options: Options) !Program {
    const state_limit = try resolveStateLimit(options.limits.states_count, options.diagnostics);
    var parser: Parser = .init(gpa, pattern, .{
        .diagnostics = options.diagnostics,
        .max_repeat = options.limits.repeat_size,
    });
    var ast = try parser.parse();
    defer ast.deinit(gpa);
    var compiler: Compiler = .{
        .arena = .init(gpa),
        .options = .{
            .diagnostics = options.diagnostics,
            .state_limit = state_limit,
        },
    };
    errdefer compiler.arena.deinit();
    return compiler.compileAst(ast);
}

fn compileAst(c: *Compiler, ast: Ast) !Program {
    const a = c.arena.allocator();

    _ = try c.emitState(.{ .capture = .{ .slot = 0, .out = 1 } }); // capture_0
    const frag = try c.compileNode(ast, ast.root());
    const capture_1 = try c.emitState(.{
        .capture = .{ .slot = 1, .out = c.nextStateId() },
    });
    frag.outs.patch(c, capture_1);
    _ = try c.emitState(.match);
    return .{
        .states = try c.states.toOwnedSlice(a),
        .ranges = try c.ranges.toOwnedSlice(a),
        .branches = try c.branches.toOwnedSlice(a),
        .arena = c.arena,
        .group_count = ast.group_count,
        .matcher_count = c.matcher_count,
    };
}

fn compileNode(c: *Compiler, ast: Ast, node_index: Ast.Node.Index) !Frag {
    const a = c.arena.allocator();
    const node = ast.nodes[node_index];
    switch (node) {
        .literal => |lit| {
            const id = try c.emitState(.{ .char = .{ .byte = lit.char(), .out = 0 } });
            return .{ .id = id, .outs = .fromOne(id) };
        },
        .dot => {
            const id = try c.emitState(.{ .any = .{ .out = 0 } });
            return .{ .id = id, .outs = .fromOne(id) };
        },
        .class_perl => |cl| {
            const ranges = perlRanges(cl);
            const start = c.ranges.items.len;
            try c.ranges.ensureUnusedCapacity(a, ranges.len);
            c.ranges.appendSliceAssumeCapacity(ranges);
            const id = try c.emitState(.{ .ranges = .{
                .start = @intCast(start),
                .len = @intCast(ranges.len),
                .negated = cl.negated,
                .out = 0,
            } });
            return .{ .id = id, .outs = .fromOne(id) };
        },
        .class => |cl| return c.compileClass(cl),
        .group => |gr| {
            const slot_2k = @as(u32, gr.index) * 2;
            const capture_left = try c.emitState(.{ .capture = .{
                .slot = slot_2k,
                .out = c.nextStateId(),
            } });
            const sub_frag = try c.compileNode(ast, gr.node);
            const capture_right = try c.emitState(.{ .capture = .{ .slot = slot_2k + 1, .out = 0 } });
            sub_frag.outs.patch(c, capture_right);
            return .{ .id = capture_left, .outs = .fromOne(capture_right) };
        },
        .concat => |cat| {
            if (cat.nodes.len == 0) {
                // Occurs in empty alternation branch
                return c.compileEmpty();
            }
            var frag = try c.compileNode(ast, cat.nodes[0]);
            for (cat.nodes[1..]) |index| {
                const next = try c.compileNode(ast, index);
                frag.outs.patch(c, next.id);
                frag.outs = next.outs;
            }
            return frag;
        },
        .alternation => |alt| {
            if (alt.nodes.len == 2) {
                const id = try c.emitAlt2();
                const left = try c.compileNode(ast, alt.nodes[0]);
                const right = try c.compileNode(ast, alt.nodes[1]);
                c.states.items[id] = .{ .alt2 = .{ .left = left.id, .right = right.id } };
                return .{ .id = id, .outs = left.outs.append(c, right.outs) };
            }

            const id = try c.emitState(.{
                .alt = .{ .start = @intCast(c.branches.items.len), .len = @intCast(alt.nodes.len) },
            });
            // branches order preserves leftmost-first semantics.
            try c.branches.ensureTotalCapacity(a, c.branches.items.len + alt.nodes.len);
            var frag: Frag = .{ .id = id, .outs = .empty };
            for (alt.nodes) |index| {
                const sub_frag = try c.compileNode(ast, index);
                c.branches.appendAssumeCapacity(sub_frag.id);
                frag.outs = frag.outs.append(c, sub_frag.outs);
            }
            return frag;
        },
        .repetition => |rep| {
            const Kind = Ast.Repetition.Kind;
            rep_kind: switch (rep.kind) {
                .zero_or_one => {
                    // alt: left -> node, right -> next
                    const alt = try c.emitAlt2();
                    var sub_frag = try c.compileNode(ast, rep.node);
                    const rep_outs = c.repetitionAlt(alt, sub_frag.id, rep.lazy);
                    sub_frag.outs = sub_frag.outs.append(c, rep_outs);
                    return .{ .id = alt, .outs = sub_frag.outs };
                },
                .zero_or_more => {
                    // (alt: left -> node, right -> next); node -> alt
                    const alt = try c.emitAlt2();
                    const sub_frag = try c.compileNode(ast, rep.node);
                    sub_frag.outs.patch(c, alt);
                    const outs = c.repetitionAlt(alt, sub_frag.id, rep.lazy);
                    return .{ .id = alt, .outs = outs };
                },
                .one_or_more => {
                    // node -> (alt: left -> node, right -> next)
                    const sub_frag = try c.compileNode(ast, rep.node);
                    const alt = try c.emitAlt2();
                    sub_frag.outs.patch(c, alt);
                    const outs = c.repetitionAlt(alt, sub_frag.id, rep.lazy);
                    return .{ .id = sub_frag.id, .outs = outs };
                },
                // TODO: Compilation for counted repetition perhaps will be cut once
                // the ast is simplified.
                .exactly => |min| {
                    if (min == 0) return c.compileEmpty();
                    var frag = try c.compileNode(ast, rep.node);
                    for (0..min - 1) |_| {
                        const next_frag = try c.compileNode(ast, rep.node);
                        frag.outs.patch(c, next_frag.id);
                        frag.outs = next_frag.outs;
                    }
                    return frag;
                },
                .at_least => |min| {
                    switch (min) {
                        0 => continue :rep_kind Kind.zero_or_more,
                        1 => continue :rep_kind Kind.one_or_more,
                        else => {
                            const result_id = c.nextStateId();
                            var frag: ?Frag = null;
                            for (0..min) |_| {
                                const next_frag = try c.compileNode(ast, rep.node);
                                if (frag) |f| f.outs.patch(c, next_frag.id);
                                frag = next_frag;
                            }
                            const alt = try c.emitAlt2();
                            const last_frag = frag.?; //  frag != null because `min` >= 2
                            last_frag.outs.patch(c, alt);
                            const outs = c.repetitionAlt(alt, last_frag.id, rep.lazy);
                            return .{ .id = result_id, .outs = outs };
                        },
                    }
                },
                .between => |b| {
                    if (b.max == 0) return c.compileEmpty();
                    if (b.max == 1 and b.min == 0) continue :rep_kind Kind.zero_or_one;
                    if (b.max == b.min) continue :rep_kind .{ .exactly = b.min };
                    const result_id = c.nextStateId();
                    // Compile repeat arg node min times (can be 0)
                    var frag: ?Frag = null;
                    for (0..b.min) |_| {
                        const next_frag = try c.compileNode(ast, rep.node);
                        if (frag) |f| f.outs.patch(c, next_frag.id);
                        frag = next_frag;
                    }

                    // For (max - min) times, create this shape (lazy = false):
                    // alt2: left  -> arg node (arg node: out -> the next alt2)
                    //       right -> dangling
                    // When lazy = true, left and right are reversed.
                    // This loop runs at least once because max < min case is handled
                    // in parsing phase, max == min case is sent to .exactly case.
                    assert(b.max > b.min);
                    var outs: PatchList = .empty;
                    for (0..b.max - b.min) |_| {
                        const alt = try c.emitAlt2();
                        const repeat_arg = try c.compileNode(ast, rep.node);
                        outs = outs.append(c, c.repetitionAlt(alt, repeat_arg.id, rep.lazy));
                        if (frag) |f| f.outs.patch(c, alt);
                        frag = .{ .id = alt, .outs = repeat_arg.outs };
                    }
                    // frag != null because the loop ran at least once
                    outs = outs.append(c, frag.?.outs);
                    return .{ .id = result_id, .outs = outs };
                },
            }
        },
        .assertion => |asrt| {
            const id = try c.emitState(.{ .assert = .{
                .pred = switch (asrt) {
                    .start_line_or_text => .start_text,
                    .end_line_or_text => .end_text,
                    .word_boundary => .word_boundary,
                    .not_word_boundary => .not_word_boundary,
                },
                .out = 0,
            } });
            return .{ .id = id, .outs = .fromOne(id) };
        },
    }
}

fn nextStateId(c: *Compiler) StateId {
    return @intCast(c.states.items.len + 1);
}

fn err(c: *Compiler, compile_diag: Diagnostics.Compile) error{Compile} {
    if (c.options.diagnostics) |diagnostics| {
        diagnostics.* = .{ .compile = compile_diag };
    }
    return error.Compile;
}

fn resolveStateLimit(configured: ?usize, diagnostics: ?*Diagnostics) error{Compile}!usize {
    const max = PatchList.Ptr.max;
    const limit = configured orelse return max;
    if (limit <= max) return limit;
    if (diagnostics) |diag| {
        diag.* = .{ .compile = .{ .invalid_state_limit = limit } };
    }
    return error.Compile;
}

fn checkStateLimit(c: *Compiler) error{Compile}!void {
    const limit = c.options.state_limit;
    if (c.states.items.len < limit) return;
    return c.err(.{ .too_many_states = .{
        .limit = limit,
        .count = c.states.items.len + 1,
    } });
}

fn emitState(c: *Compiler, state: State) !StateId {
    try c.checkStateLimit();
    const state_id: StateId = @intCast(c.states.items.len);
    try c.states.append(c.arena.allocator(), state);
    switch (state) {
        .char, .ranges, .any, .fail, .match => c.matcher_count += 1,
        .empty, .capture, .assert, .alt, .alt2 => {},
    }
    return state_id;
}

/// Emit State.alt2 with both ends dangling.
fn emitAlt2(c: *Compiler) !StateId {
    return c.emitState(.{ .alt2 = .{ .left = 0, .right = 0 } });
}

/// Helper to compile repetition. When `lazy` = false, creates the following shape:
/// ```
/// alt2: left  -> arg
///       right -> next (dangling)
/// ```
/// When `lazy` = true, `left` and `right` are reversed.
/// Returns the dangling patch list to `next`.
fn repetitionAlt(c: *Compiler, alt: StateId, arg: StateId, lazy: bool) PatchList {
    if (!lazy) {
        c.states.items[alt] = .{ .alt2 = .{ .left = arg, .right = 0 } };
        return .fromOneRight(alt);
    } else {
        c.states.items[alt] = .{ .alt2 = .{ .left = 0, .right = arg } };
        return .fromOne(alt);
    }
}

/// Creates a Frag that only contains a single State.empty.
fn compileEmpty(c: *Compiler) !Frag {
    const id = try c.emitState(.{ .empty = .{ .out = 0 } });
    return .{ .id = id, .outs = .fromOne(id) };
}

fn compileClass(c: *Compiler, cls: Ast.Class) !Frag {
    const a = c.arena.allocator();
    const start = c.ranges.items.len;

    // Calculate upper bound of this class and reserve memory for worst case.
    var reserve: usize = 0;
    for (cls.items) |item| {
        reserve += itemRangeUpperBound(item);
    }
    // Negation of normalized ranges can add at most one extra range.
    if (cls.negated) reserve += reserve + 1;
    try c.ranges.ensureTotalCapacity(a, c.ranges.items.len + reserve);

    for (cls.items) |item| {
        switch (item) {
            .literal => |lit| c.ranges.appendAssumeCapacity(.{
                .from = lit.char(),
                .to = lit.char(),
            }),
            .range => |range| c.ranges.appendAssumeCapacity(.{
                .from = range.from.char(),
                .to = range.to.char(),
            }),
            .perl => |perl| {
                const ranges = perlRanges(perl);
                if (!perl.negated) {
                    c.ranges.appendSliceAssumeCapacity(ranges);
                } else {
                    const negated_ranges = try c.negateRanges(ranges);
                    c.ranges.appendSliceAssumeCapacity(negated_ranges);
                }
            },
            .ascii => |ascii| {
                const ranges = asciiRanges(ascii);
                if (!ascii.negated) {
                    c.ranges.appendSliceAssumeCapacity(ranges);
                } else {
                    const negated_ranges = try c.negateRanges(ranges);
                    c.ranges.appendSliceAssumeCapacity(negated_ranges);
                }
            },
        }
    }

    var len = normalizeRanges(c.ranges.items[start..]);
    c.ranges.shrinkRetainingCapacity(start + len);
    if (cls.negated) {
        const negated = try c.negateRanges(c.ranges.items[start..]);
        // c.ranges capacity was reserved above for worst-case above (+1 range),
        // so this is safe if negated.len > len. If negated.len < len, this does
        // the job of shrinkRetainingCapacity().
        c.ranges.items.len = start + negated.len;
        @memcpy(c.ranges.items[start..], negated);
        len = negated.len;
    }

    // This might happen when class items cancel each other, e.g. [^\d\D]
    if (len == 0) {
        const id = try c.emitState(.fail);
        return .{ .id = id, .outs = .empty };
    }

    const ranges = c.ranges.items[start..][0..len];
    // When the class amounts to a single char, we'll just emit a State.char.
    if (ranges.len == 1 and ranges[0].from == ranges[0].to) {
        c.ranges.shrinkRetainingCapacity(start);
        const id = try c.emitState(.{ .char = .{ .byte = ranges[0].from, .out = 0 } });
        return .{ .id = id, .outs = .fromOne(id) };
    }

    const id = try c.emitState(.{ .ranges = .{
        .start = @intCast(start),
        .len = @intCast(len),
        .negated = false,
        .out = 0,
    } });
    return .{ .id = id, .outs = .fromOne(id) };
}

fn itemRangeUpperBound(item: Ast.Class.Item) usize {
    return switch (item) {
        .literal, .range => 1,
        .perl => |perl| {
            const ranges = perlRanges(perl);
            return if (perl.negated) ranges.len + 1 else ranges.len;
        },
        .ascii => |ascii| {
            const ranges = asciiRanges(ascii);
            return if (ascii.negated) ranges.len + 1 else ranges.len;
        },
    };
}

/// Helper to generate []const ByteRange from short hand tuples, such as in
/// `perlRanges()` and `asciiRanges()`.
fn byteRanges(comptime tuples: anytype) []const ByteRange {
    const tuples_info = @typeInfo(@TypeOf(tuples));
    comptime {
        if (tuples_info != .@"struct" or !tuples_info.@"struct".is_tuple) {
            @compileError("byteRanges expects a tuple of (from, to) byte tuples");
        }
    }

    return comptime blk: {
        var ranges: [tuples_info.@"struct".fields.len]ByteRange = undefined;
        for (tuples, &ranges) |pair, *range| {
            const pair_info = @typeInfo(@TypeOf(pair));
            if (pair_info != .@"struct" or !pair_info.@"struct".is_tuple or pair_info.@"struct".fields.len != 2) {
                @compileError("byteRanges entries must be 2-tuples");
            }
            range.* = .{ .from = @as(u8, pair[0]), .to = @as(u8, pair[1]) };
        }
        const final = ranges;
        break :blk &final;
    };
}

fn perlRanges(perl: Ast.Class.Perl) []const ByteRange {
    return switch (perl.kind) {
        .digit => byteRanges(.{
            .{ '0', '9' },
        }),
        .word => byteRanges(.{
            .{ '0', '9' },
            .{ 'A', 'Z' },
            .{ '_', '_' },
            .{ 'a', 'z' },
        }),
        .space => byteRanges(.{
            .{ '\t', '\r' },
            .{ ' ', ' ' },
        }),
    };
}

fn asciiRanges(ascii: Ast.Class.Ascii) []const ByteRange {
    return switch (ascii.kind) {
        .alnum => byteRanges(.{
            .{ '0', '9' },
            .{ 'A', 'Z' },
            .{ 'a', 'z' },
        }),
        .alpha => byteRanges(.{
            .{ 'A', 'Z' },
            .{ 'a', 'z' },
        }),
        .ascii => byteRanges(.{
            .{ 0x00, 0x7F },
        }),
        .blank => byteRanges(.{
            .{ '\t', '\t' },
            .{ ' ', ' ' },
        }),
        .cntrl => byteRanges(.{
            .{ 0x00, 0x1F },
            .{ 0x7F, 0x7F },
        }),
        .digit => byteRanges(.{
            .{ '0', '9' },
        }),
        .graph => byteRanges(.{
            .{ '!', '~' },
        }),
        .lower => byteRanges(.{
            .{ 'a', 'z' },
        }),
        .print => byteRanges(.{
            .{ ' ', '~' },
        }),
        .punct => byteRanges(.{
            .{ '!', '/' },
            .{ ':', '@' },
            .{ '[', '`' },
            .{ '{', '~' },
        }),
        .space => byteRanges(.{
            .{ '\t', '\r' },
            .{ ' ', ' ' },
        }),
        .upper => byteRanges(.{
            .{ 'A', 'Z' },
        }),
        .word => byteRanges(.{
            .{ '0', '9' },
            .{ 'A', 'Z' },
            .{ '_', '_' },
            .{ 'a', 'z' },
        }),
        .xdigit => byteRanges(.{
            .{ '0', '9' },
            .{ 'A', 'F' },
            .{ 'a', 'f' },
        }),
    };
}

/// Sorts and merges `ranges` in place into normalized byte ranges
/// (ascending, non-overlapping, non-adjacent).
/// Returns the logical output length stored at the front of `ranges`.
/// Caller is expected to truncate any stale trailing entries.
fn normalizeRanges(ranges: []ByteRange) usize {
    if (ranges.len == 0) return 0;
    std.mem.sortUnstable(ByteRange, ranges, {}, lessRange);

    var i: usize = 1;
    for (ranges[1..]) |current| {
        var previous = &ranges[i - 1];
        if (current.from <= previous.to +| 1) {
            previous.to = @max(previous.to, current.to);
        } else {
            ranges[i] = current;
            i += 1;
        }
    }
    return i;
}

fn lessRange(_: void, lhs: ByteRange, rhs: ByteRange) bool {
    if (lhs.from < rhs.from) return true;
    if (lhs.from > rhs.from) return false;
    return lhs.to > rhs.to;
}

/// Computes the negation of normalized `source` ranges into `c.scratch_ranges`
/// and returns the immutable result slice.
fn negateRanges(c: *Compiler, source: []const ByteRange) ![]const ByteRange {
    const scratch = &c.scratch_ranges;
    scratch.clearRetainingCapacity();
    try scratch.ensureTotalCapacity(c.arena.allocator(), source.len + 1);

    const byte_max = std.math.maxInt(u8);
    var next_from: u8 = 0;
    for (source) |range| {
        if (next_from < range.from) {
            scratch.appendAssumeCapacity(.{
                .from = next_from,
                .to = range.from - 1,
            });
        }
        if (range.to == byte_max) break;
        next_from = range.to + 1;
    } else scratch.appendAssumeCapacity(.{
        .from = next_from,
        .to = byte_max,
    });

    return scratch.items;
}

/// A compiled fragment returned by compileNode.
/// - id: the id of the entry state of the fragment
/// - outs: dangling out-edges that must be patched to the next fragment
const Frag = struct {
    id: StateId,
    outs: PatchList,
};

/// In the state list for execution, id 0 is reserved for .capture slot 0 state,
/// so it's safe to repurpose it during building as dangling (i.e. to be patched).
///
/// All `Id` value referenced by PatchList are encoded into Ptr.
///
/// Reference: https://github.com/golang/go/blob/master/src/regexp/syntax/compile.go
const PatchList = struct {
    head: Ptr,
    tail: Ptr,

    const empty: PatchList = .{ .head = .zero, .tail = .zero };

    fn fromOne(id: StateId) PatchList {
        assert(id <= Ptr.max);
        const ptr: Ptr = .{ .id = @truncate(id), .field = .left };
        return .{ .head = ptr, .tail = ptr };
    }

    /// Like `fromOne`, but encode the patch target to .right.
    fn fromOneRight(id: StateId) PatchList {
        assert(id <= Ptr.max);
        const ptr: Ptr = .{ .id = @truncate(id), .field = .right };
        return .{ .head = ptr, .tail = ptr };
    }

    /// Decode the head value for the index of State (and which field) to patch.
    /// If the decoded value is 0 (dangling), then patching is finished.
    fn patch(l1: PatchList, c: *Compiler, value: StateId) void {
        assert(value != 0);
        var head = l1.head;
        while (head.toId() != 0) {
            const next = head.get(c);
            head.set(c, value);
            head = next;
        }
    }

    fn append(l1: PatchList, c: *Compiler, l2: PatchList) PatchList {
        if (l1.head.toId() == 0) return l2;
        if (l2.head.toId() == 0) return l1;
        l1.tail.set(c, l2.head.toId());
        return .{ .head = l1.head, .tail = l2.tail };
    }

    const Ptr = packed struct {
        id: u31,
        field: Field,

        const zero: Ptr = .{ .id = 0, .field = .left };
        const max = std.math.maxInt(u31);

        /// Indicates which 'out' field to patched in State.
        /// The field bit is ignored unless the State is alt2.
        const Field = enum(u1) { left = 0, right = 1 };

        fn toId(self: Ptr) StateId {
            return (@as(StateId, self.id) << 1) | @intFromEnum(self.field);
        }

        fn fromId(id: StateId) Ptr {
            return .{ .id = @truncate(id >> 1), .field = @enumFromInt(id & 1) };
        }

        /// Sets the field of State encoded by Ptr to `value`.
        /// The field set is usually .out, except for when State is alt2,
        /// in which case Ptr.field determines alt2.left or .right.
        fn set(self: Ptr, c: *Compiler, value: StateId) void {
            switch (c.states.items[self.id]) {
                .fail, .match, .alt => unreachable,
                .alt2 => |*pl| switch (self.field) {
                    .left => pl.left = value,
                    .right => pl.right = value,
                },
                inline else => |*pl| pl.out = value,
            }
        }

        /// Finds the value at the field encoded by Ptr. This value is assumed to be
        /// encoded and is turned into a new Ptr and returned.
        fn get(self: Ptr, c: *Compiler) Ptr {
            return .fromId(
                switch (c.states.items[self.id]) {
                    .fail, .match, .alt => unreachable,
                    .alt2 => |pl| switch (self.field) {
                        .left => pl.left,
                        .right => pl.right,
                    },
                    inline else => |pl| pl.out,
                },
            );
        }
    };
};

const testing = std.testing;

fn expectProgram(pattern: []const u8, expected: []const Vertex) !void {
    const a = testing.allocator;
    var prog = try Compiler.compile(a, pattern, .{});
    defer prog.deinit();
    const graph = try g.graphView(prog, a);
    defer graph.deinit(a);
    const actual = graph.vertices;

    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual, 0..) |want, got, i| {
        if (want.eql(got)) continue;
        const want_dump = try g.dumpGraphAlloc(a, expected);
        defer a.free(want_dump);
        const got_dump = try g.dumpGraphAlloc(a, actual);
        defer a.free(got_dump);
        std.debug.print(
            "graph mismatch for `{s}` at s{d}\nwant: {any}\ngot:  {any}\n\nwant graph:\n{s}\n\ngot graph:\n{s}\n",
            .{ pattern, i, want, got, want_dump, got_dump },
        );
        return error.TestExpectedEqual;
    }
}

test "basic compile" {
    try expectProgram("a((b|c)|\\d|)(x|y)z", &.{
        g.capt(0, 1),
        g.char('a', 2),
        g.capt(2, 3),
        g.alt(&.{ 4, 5, 6 }),
        g.capt(4, 7),
        g.ranges(&.{g.r('0', '9')}, false, 11),
        g.empty(11),
        g.alt2(8, 9),
        g.char('b', 10),
        g.char('c', 10),
        g.capt(5, 11),
        g.capt(3, 12),
        g.capt(6, 13),
        g.alt2(14, 15),
        g.char('x', 16),
        g.char('y', 16),
        g.capt(7, 17),
        g.char('z', 18),
        g.capt(1, 19),
        g.match(),
    });
}

test "greedy repetition" {
    try expectProgram("a?", &.{
        g.capt(0, 1),
        g.alt2(2, 3),
        g.char('a', 3),
        g.capt(1, 4),
        g.match(),
    });
    try expectProgram("a*", &.{
        g.capt(0, 1),
        g.alt2(2, 3),
        g.char('a', 1),
        g.capt(1, 4),
        g.match(),
    });
    try expectProgram("a+", &.{
        g.capt(0, 1),
        g.char('a', 2),
        g.alt2(1, 3),
        g.capt(1, 4),
        g.match(),
    });
}

test "lazy repetition" {
    try expectProgram("a??", &.{
        g.capt(0, 1),
        g.alt2(2, 3),
        g.capt(1, 4),
        g.char('a', 2),
        g.match(),
    });
    try expectProgram("a*?", &.{
        g.capt(0, 1),
        g.alt2(2, 3),
        g.capt(1, 4),
        g.char('a', 1),
        g.match(),
    });
    try expectProgram("a+?", &.{
        g.capt(0, 1),
        g.char('a', 2),
        g.alt2(3, 1),
        g.capt(1, 4),
        g.match(),
    });
}

test "counted repetition" {
    try expectProgram("a{3}", &.{
        g.capt(0, 1),
        g.char('a', 2),
        g.char('a', 3),
        g.char('a', 4),
        g.capt(1, 5),
        g.match(),
    });
    try expectProgram("a{2,}", &.{
        g.capt(0, 1),
        g.char('a', 2),
        g.char('a', 3),
        g.alt2(2, 4),
        g.capt(1, 5),
        g.match(),
    });
    try expectProgram("a{2,}?", &.{
        g.capt(0, 1),
        g.char('a', 2),
        g.char('a', 3),
        g.alt2(4, 2),
        g.capt(1, 5),
        g.match(),
    });
    try expectProgram("a{2,4}", &.{
        g.capt(0, 1),
        g.char('a', 2),
        g.char('a', 3),
        g.alt2(4, 5),
        g.char('a', 6),
        g.capt(1, 8),
        g.alt2(7, 5),
        g.char('a', 5),
        g.match(),
    });
    try expectProgram("a{2,4}?", &.{
        g.capt(0, 1),
        g.char('a', 2),
        g.char('a', 3),
        g.alt2(4, 5),
        g.capt(1, 6),
        g.char('a', 7),
        g.match(),
        g.alt2(4, 8),
        g.char('a', 4),
    });
}

test "ascii class compile" {
    try expectProgram("[^[:digit:]]", &.{
        g.capt(0, 1),
        g.ranges(&.{ g.r(0x00, '/'), g.r(':', 0xFF) }, false, 2),
        g.capt(1, 3),
        g.match(),
    });
    try expectProgram("[[:digit:][:^digit:]]", &.{
        g.capt(0, 1),
        g.ranges(&.{g.r(0x00, 0xFF)}, false, 2),
        g.capt(1, 3),
        g.match(),
    });
    try expectProgram("[^[:digit:][:^digit:]]", &.{
        g.capt(0, 1),
        g.fail(),
    });
}

test "assertions" {
    try expectProgram("^re$", &.{
        g.capt(0, 1),
        g.asrt(.start_text, 2),
        g.char('r', 3),
        g.char('e', 4),
        g.asrt(.end_text, 5),
        g.capt(1, 6),
        g.match(),
    });
    try expectProgram("\\b\\B", &.{
        g.capt(0, 1),
        g.asrt(.word_boundary, 2),
        g.asrt(.not_word_boundary, 3),
        g.capt(1, 4),
        g.match(),
    });
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const assert = std.debug.assert;

const Ast = @import("Ast.zig");
const errors = @import("../errors.zig");
const Diagnostics = errors.Diagnostics;
const Options = @import("../Options.zig");
const Parser = @import("Parser.zig");
const Program = @import("Program.zig");
const g = @import("program_graph.zig");
const State = Program.State;
const StateId = Program.StateId;
const ByteRange = Program.ByteRange;
const Vertex = g.Vertex;
