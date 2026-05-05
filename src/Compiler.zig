//! The Compiler compiles parsed Ast into a Thompson-style NFA: a linked collection of State
//! structures. This follows the algorithm presented in http://swtch.com/~rsc/regexp/

const Compiler = @This();

states: ArrayList(State) = .empty,
ranges: ArrayList(ByteRange) = .empty,
branches: ArrayList(StateId) = .empty,
arena: std.heap.ArenaAllocator,
options: Options,

/// See `Program.matcher_count`.
matcher_count: u32 = 0,

const Error = error{Compile} || Allocator.Error;

const Options = struct {
    // Syntax
    syntax: SyntaxOptions,
    // Limits
    max_states: usize,
    // Diag
    diag: ?*Diagnostics,

    fn fromTopLevel(options: TopLevelOptions) !Options {
        return .{
            .syntax = options.syntax,
            .max_states = try maxState(options.limits.max_states, options.diag),
            .diag = options.diag,
        };
    }

    fn maxState(configured: ?usize, diag: ?*Diagnostics) error{Compile}!usize {
        const max = PatchList.Ptr.max;
        const limit = configured orelse return max;
        if (limit <= max) return limit;
        if (diag) |d| {
            d.* = .{ .compile = .{ .invalid_state_limit = limit } };
        }
        return error.Compile;
    }
};

/// Resources allocated are owned by Program after compilation is done, and caller is expected
/// to call Program.deinit() to free them.
pub fn compile(gpa: Allocator, pattern: []const u8, options: TopLevelOptions) !*Program {
    var parser: Parser = .init(gpa, pattern, .{
        .max_repeat = options.limits.max_repeat,
        .diag = options.diag,
    });
    var ast = try parser.parse();
    defer ast.deinit();
    var compiler: Compiler = .{
        .arena = .init(gpa),
        .options = try .fromTopLevel(options),
    };
    errdefer compiler.arena.deinit();
    return compiler.compileAst(&ast);
}

/// Compile a parsed AST into a Program. Compilation moves capture metadata out of `ast`
/// into Program.
fn compileAst(c: *Compiler, ast: *Ast) Error!*Program {
    const a = c.arena.allocator();

    // PatchList uses state id 0 as the dangling sentinel, so the start capture for
    // the whole match at id 0 must stay outside normal Frag patching.
    const start_capture = try c.emitState(.{ .capture = .{ .slot = 0, .out = 0 } });
    assert(start_capture == 0);

    var frag = try c.compileNode(ast, ast.root());
    assert(frag.id != 0);
    c.states.items[start_capture].capture.out = frag.id;
    frag = c.cat(frag, try c.cap(1));
    _ = c.cat(frag, try c.state(.match));

    if (builtin.mode == .Debug) {
        assert(c.matcher_count == countMatcherStates(c.states.items));
    }

    const prog = try a.create(Program);
    prog.* = .{
        .states = try c.states.toOwnedSlice(a),
        .ranges = try c.ranges.toOwnedSlice(a),
        .branches = try c.branches.toOwnedSlice(a),
        // Important that we move capture_info **after** fallible actions above, so it
        // can be cleaned up by `ast.deinit` in the fail path.
        .capture_info = ast.capture_info.move(),
        .matcher_count = c.matcher_count,
        .arena = c.arena,
    };
    return prog;
}

fn compileNode(c: *Compiler, ast: *const Ast, node_index: Ast.Node.Index) Error!Frag {
    const a = c.arena.allocator();
    const node = ast.nodes[node_index];
    switch (node) {
        .literal => |lit| {
            return c.literal(lit);
        },
        .dot => {
            const any_kind: State.Any.Kind =
                if (c.options.syntax.dot_matches_new_line) .all else .not_lf;
            return c.state(.{ .any = .{ .kind = any_kind, .out = 0 } });
        },
        .class_perl => |cl| return c.namedClass(perlRanges(cl), cl.negated),
        .class => |cl| return c.class(ast, cl),
        .group => |gr| {
            const capture_index = switch (gr.kind) {
                .numbered => |index| index,
                .named => |named_capture| named_capture.index,
                .non_capturing => |flags| {
                    const before: SyntaxOptions = c.options.syntax;
                    defer c.options.syntax = before;
                    c.applySyntaxFlags(flags);
                    return c.compileNode(ast, gr.node);
                },
            };
            const before: SyntaxOptions = c.options.syntax;
            defer c.options.syntax = before;
            const slot_2k = @as(u32, capture_index) * 2;
            const frag = c.cat(try c.cap(slot_2k), try c.compileNode(ast, gr.node));
            return c.cat(frag, try c.cap(slot_2k + 1));
        },
        .set_flags => |flags| {
            c.applySyntaxFlags(flags);
            return c.empty();
        },
        .concat => |c_node| {
            if (c_node.len == 0) {
                // Occurs in empty alternation branch
                return c.empty();
            }
            const concat = ast.indexSlice(c_node.start, c_node.len);
            var frag = try c.compileNode(ast, concat[0]);
            for (concat[1..]) |index| {
                frag = c.cat(frag, try c.compileNode(ast, index));
            }
            return frag;
        },
        .alternation => |a_node| {
            const alt = ast.indexSlice(a_node.start, a_node.len);
            switch (alt.len) {
                0 => return c.empty(),
                1 => return c.compileNode(ast, alt[0]),
                2 => return c.alt2(
                    try c.compileNode(ast, alt[0]),
                    try c.compileNode(ast, alt[1]),
                ),
                else => {
                    const start = c.branches.items.len;
                    try c.branches.ensureTotalCapacity(a, start + alt.len);

                    var frag = try c.state(.{
                        .alt = .{ .start = @intCast(start), .len = @intCast(alt.len) },
                    });
                    for (alt) |index| {
                        const branch = try c.compileNode(ast, index);
                        c.branches.appendAssumeCapacity(branch.id);
                        frag.outs = frag.outs.append(c, branch.outs);
                        frag.nullable = frag.nullable or branch.nullable;
                    }
                    return frag;
                },
            }
        },
        .repetition => |rep| {
            const Kind = Ast.Repetition.Kind;
            const lazy = rep.lazy_suffix != c.options.syntax.swap_greed;
            rep_kind: switch (rep.kind) {
                .zero_or_one => {
                    return c.quest(try c.compileNode(ast, rep.node), lazy);
                },
                .zero_or_more => {
                    return c.star(try c.compileNode(ast, rep.node), lazy);
                },
                .one_or_more => {
                    return c.plus(try c.compileNode(ast, rep.node), lazy);
                },
                .exactly => |min| {
                    return c.compileNTimes(ast, rep.node, min);
                },
                .at_least => |min| {
                    switch (min) {
                        0 => continue :rep_kind Kind.zero_or_more,
                        1 => continue :rep_kind Kind.one_or_more,
                        else => return c.cat(
                            try c.compileNTimes(ast, rep.node, min - 1),
                            try c.plus(try c.compileNode(ast, rep.node), lazy),
                        ),
                    }
                },
                .between => |b| {
                    assert(b.min <= b.max); // Handled in parse phase
                    if (b.max == 0) return c.empty();
                    if (b.max == 1 and b.min == 0) continue :rep_kind Kind.zero_or_one;
                    if (b.max == b.min) continue :rep_kind .{ .exactly = b.min };

                    // Lower x{n,m} as a required prefix plus a nested optional
                    // suffix, e.g. x{2,5} => xx(x(x(x)?)?)?. A flat chain like
                    // xx x? x? x? would admit many equivalent epsilon paths for
                    // the same repetition count. The nested form preserves the
                    // same language while doing less VM work.
                    //
                    // Reference:
                    // https://github.com/golang/go/blob/master/src/regexp/syntax/simplify.go
                    var suffix = try c.quest(try c.compileNode(ast, rep.node), lazy);
                    for (b.min..b.max - 1) |_| {
                        suffix = try c.quest(
                            c.cat(try c.compileNode(ast, rep.node), suffix),
                            lazy,
                        );
                    }
                    if (b.min == 0) return suffix;
                    return c.cat(try c.compileNTimes(ast, rep.node, b.min), suffix);
                },
            }
        },
        .assertion => |asrt| {
            return c.state(.{ .assert = .{
                .pred = switch (asrt) {
                    .start_line_or_text => if (c.options.syntax.multi_line) .start_line else .start_text,
                    .end_line_or_text => if (c.options.syntax.multi_line) .end_line else .end_text,
                    .start_text => .start_text,
                    .end_text => .end_text,
                    .word_boundary => .word_boundary,
                    .not_word_boundary => .not_word_boundary,
                },
                .out = 0,
            } });
        },
    }
}

fn err(c: *Compiler, compile_diag: Diagnostics.Compile) error{Compile} {
    if (c.options.diag) |diagnostics| {
        diagnostics.* = .{ .compile = compile_diag };
    }
    return error.Compile;
}

fn checkStateLimit(c: *Compiler) error{Compile}!void {
    const limit = c.options.max_states;
    if (c.states.items.len < limit) return;
    return c.err(.{ .too_many_states = .{
        .limit = limit,
        .count = c.states.items.len + 1,
    } });
}

fn emitState(c: *Compiler, s: State) !StateId {
    try c.checkStateLimit();
    const id: StateId = @intCast(c.states.items.len);
    try c.states.append(c.arena.allocator(), s);
    switch (s) {
        .char, .ranges, .any, .fail, .match => c.matcher_count += 1,
        .empty, .capture, .assert, .alt, .alt2 => {},
    }
    return id;
}

fn state(c: *Compiler, s: State) !Frag {
    const id = try c.emitState(s);
    return .{
        .id = id,
        .outs = switch (s) {
            .char, .ranges, .any, .empty, .capture, .assert => .fromOne(id),
            .fail, .match, .alt, .alt2 => .empty,
        },
        // .alt and .alt2 are typically emitted before their branch fragments are
        // known, so callers overwrite their nullable value once children are
        // attached.
        .nullable = switch (s) {
            .char, .ranges, .any, .alt, .alt2, .fail => false,
            .empty, .capture, .assert, .match => true,
        },
    };
}

fn cap(c: *Compiler, slot: u32) !Frag {
    return c.state(.{ .capture = .{ .slot = slot, .out = 0 } });
}

fn cat(c: *Compiler, lhs: Frag, rhs: Frag) Frag {
    if (lhs.id == 0 or rhs.id == 0) return .zero;
    lhs.outs.patch(c, rhs.id);
    return .{
        .id = lhs.id,
        .outs = rhs.outs,
        .nullable = lhs.nullable and rhs.nullable,
    };
}

fn alt2(c: *Compiler, lhs: Frag, rhs: Frag) !Frag {
    if (lhs.id == 0) return rhs;
    if (rhs.id == 0) return lhs;

    var frag = try c.state(.{ .alt2 = .{ .left = lhs.id, .right = rhs.id } });
    frag.outs = lhs.outs.append(c, rhs.outs);
    frag.nullable = lhs.nullable or rhs.nullable;
    return frag;
}

fn quest(c: *Compiler, f1: Frag, lazy: bool) !Frag {
    var frag = try c.state(.{ .alt2 = .{ .left = 0, .right = 0 } });
    const alt = &c.states.items[frag.id].alt2;
    if (lazy) {
        alt.right = f1.id;
        frag.outs = .fromOne(frag.id);
    } else {
        alt.left = f1.id;
        frag.outs = .fromOneRight(frag.id);
    }
    frag.outs = frag.outs.append(c, f1.outs);
    frag.nullable = true;
    return frag;
}

/// Returns the fragment for the main loop of a plus or star. When `lazy` =
/// false, creates the following shape:
/// ```
/// f1  -> alt2: left  -> f1
///              right -> next (dangling)
/// ```
/// When `lazy` = true, `left` and `right` are reversed.
fn loop(c: *Compiler, f1: Frag, lazy: bool) !Frag {
    var frag = try c.state(.{ .alt2 = .{ .left = 0, .right = 0 } });
    const alt = &c.states.items[frag.id].alt2;
    if (lazy) {
        alt.right = f1.id;
        frag.outs = .fromOne(frag.id);
    } else {
        alt.left = f1.id;
        frag.outs = .fromOneRight(frag.id);
    }
    f1.outs.patch(c, frag.id);
    frag.nullable = true;
    return frag;
}

fn plus(c: *Compiler, f1: Frag, lazy: bool) !Frag {
    const loop_frag = try c.loop(f1, lazy);
    return .{
        .id = f1.id,
        .outs = loop_frag.outs,
        .nullable = f1.nullable,
    };
}

fn star(c: *Compiler, f1: Frag, lazy: bool) !Frag {
    if (f1.nullable) {
        // Use (f1+)? to get priority match order correct.
        // https://github.com/golang/go/issues/46123
        return c.quest(try c.plus(f1, lazy), lazy);
    }
    return c.loop(f1, lazy);
}

fn compileNTimes(c: *Compiler, ast: *const Ast, node_index: Ast.Node.Index, count: u16) !Frag {
    if (count == 0) return c.empty();

    var frag = try c.compileNode(ast, node_index);
    for (1..count) |_| {
        frag = c.cat(frag, try c.compileNode(ast, node_index));
    }
    return frag;
}

fn empty(c: *Compiler) !Frag {
    return c.state(.{ .empty = .{ .out = 0 } });
}

fn literal(c: *Compiler, lit: Ast.Literal) !Frag {
    const byte = lit.char();
    if (!c.options.syntax.case_insensitive) {
        return c.state(.{ .char = .{ .byte = byte, .out = 0 } });
    }
    const folded = asciiSimpleFold(byte) orelse
        return c.state(.{ .char = .{ .byte = byte, .out = 0 } });

    const a = c.arena.allocator();
    const start = c.ranges.items.len;
    try c.ranges.ensureUnusedCapacity(a, 2);
    const first = @min(byte, folded);
    const second = @max(byte, folded);
    c.ranges.appendAssumeCapacity(.{ .from = first, .to = first });
    c.ranges.appendAssumeCapacity(.{ .from = second, .to = second });
    return c.state(.{ .ranges = .{
        .start = @intCast(start),
        .len = 2,
        .negated = false,
        .out = 0,
    } });
}

/// Compiles a top-level named class (for example `\w`) into a matcher fragment.
/// Non-negated inputs defer normalization in `appendNamedClass`, so this function
/// performs that final normalize pass before emitting the state.
fn namedClass(c: *Compiler, source: []const ByteRange, negated: bool) !Frag {
    const start = c.ranges.items.len;
    const len = try c.appendNamedClass(source, negated) orelse c.normalizeTailRanges(start);
    return c.finishTailClass(start, len);
}

/// Compiles a bracket class. It appends all items to Compiler.ranges, then normalizes
/// them (the class tail segment) once at the class boundary and negates the result if necessary.
fn class(c: *Compiler, ast: *const Ast, cls: Ast.Class) !Frag {
    const start = c.ranges.items.len;
    for (ast.classItems(cls)) |item| {
        try c.appendClassItem(item);
    }

    const len = if (cls.negated) blk: {
        try c.ranges.ensureUnusedCapacity(c.arena.allocator(), 1);
        break :blk c.negateTailRanges(start);
    } else c.normalizeTailRanges(start);
    return c.finishTailClass(start, len);
}

/// Appends a class item into the current class tail segment.
/// Literal/range items always append raw/folded ranges, while named items may
/// normalize immediately only when negated.
fn appendClassItem(c: *Compiler, item: Ast.Class.Item) !void {
    const a = c.arena.allocator();
    switch (item) {
        .literal => |lit| {
            try c.ranges.ensureUnusedCapacity(a, c.classItemUpperBound(item));
            c.foldRangeAssumeCapacity(lit.char(), lit.char());
        },
        .range => |range| {
            try c.ranges.ensureUnusedCapacity(a, c.classItemUpperBound(item));
            c.foldRangeAssumeCapacity(
                range.from.char(),
                range.to.char(),
            );
        },
        .perl => |perl| {
            // Only negated named items are normalized. Non-negated items
            // are left for the containing class's final normalize pass.
            _ = try c.appendNamedClass(perlRanges(perl), perl.negated);
        },
        .ascii => |ascii| {
            // Only negated named items are normalized. Non-negated items
            // are left for the containing class's final normalize pass.
            _ = try c.appendNamedClass(asciiRanges(ascii), ascii.negated);
        },
    }
}

/// Appends a named class into the current class tail segment.
///
/// Returns:
/// - `null`: when `negated == false`; this function only appends/folds and leaves
///   normalization to the caller so it can be done with other class items.
/// - `len`: the appended tail is already normalized and negated, and `len` is the
///   final logical segment length.
fn appendNamedClass(c: *Compiler, source: []const ByteRange, negated: bool) !?usize {
    const start = c.ranges.items.len;
    const needed_capacity = c.namedClassUpperBound(source.len, negated);
    try c.ranges.ensureUnusedCapacity(c.arena.allocator(), needed_capacity);

    for (source) |range| {
        c.foldRangeAssumeCapacity(range.from, range.to);
    }

    if (!negated) return null;
    return c.negateTailRanges(start);
}

/// Apply parsed `Ast.Flags` to `SyntaxOptions`. `Ast.Flags` value is assumed to be
/// structurally correct: each flag and `-` only appears once.
fn applySyntaxFlags(c: *Compiler, flags: Ast.Flags) void {
    const opts = &c.options.syntax;
    var flag_value = true;
    for (flags.slice()) |item| {
        switch (item) {
            .case_insensitive => opts.case_insensitive = flag_value,
            .multi_line => opts.multi_line = flag_value,
            .dot_matches_new_line => opts.dot_matches_new_line = flag_value,
            .swap_greed => opts.swap_greed = flag_value,
            .disable_op => flag_value = false,
        }
    }
}

/// ASCII-only folding via range overlap arithmetic.
fn foldRangeAssumeCapacity(
    c: *Compiler,
    from: u8,
    to: u8,
) void {
    c.ranges.appendAssumeCapacity(.{ .from = from, .to = to });
    if (!c.options.syntax.case_insensitive) return;
    if (to < 'A' or from > 'z') return;

    if (intersectByteRange(from, to, 'A', 'Z')) |upper| {
        c.ranges.appendAssumeCapacity(.{
            .from = upper.from + 32,
            .to = upper.to + 32,
        });
    }
    if (intersectByteRange(from, to, 'a', 'z')) |lower| {
        c.ranges.appendAssumeCapacity(.{
            .from = lower.from - 32,
            .to = lower.to - 32,
        });
    }
}

fn intersectByteRange(from: u8, to: u8, overlap_from: u8, overlap_to: u8) ?ByteRange {
    if (to < overlap_from or from > overlap_to) return null;
    return .{
        .from = @max(from, overlap_from),
        .to = @min(to, overlap_to),
    };
}

fn asciiSimpleFold(byte: u8) ?u8 {
    return switch (byte) {
        'A'...'Z' => byte + 32,
        'a'...'z' => byte - 32,
        else => null,
    };
}

/// Returns a safe upper bound for ranges appended by one class item.
/// Used to reserve per-item capacity before `appendAssumeCapacity` calls.
fn classItemUpperBound(c: *Compiler, item: Ast.Class.Item) usize {
    return switch (item) {
        .literal, .range => if (c.options.syntax.case_insensitive) 3 else 1,
        .perl => |perl| c.namedClassUpperBound(perlRanges(perl).len, perl.negated),
        .ascii => |ascii| c.namedClassUpperBound(asciiRanges(ascii).len, ascii.negated),
    };
}

/// Returns a safe upper bound for a named class expansion in current mode.
/// Case folding can expand each source range up to 3 ranges, and negation can
/// add at most one additional range.
fn namedClassUpperBound(c: *Compiler, source_len: usize, negated: bool) usize {
    var n = if (c.options.syntax.case_insensitive) source_len * 3 else source_len;
    if (negated) n += 1;
    return n;
}

/// Normalizes `ranges[start..]` in place (sort + merge) and truncates stale tail.
/// Returns the logical normalized length for the segment.
fn normalizeTailRanges(c: *Compiler, start: usize) usize {
    const len = normalizeRanges(c.ranges.items[start..]);
    c.ranges.shrinkRetainingCapacity(start + len);
    return len;
}

fn countMatcherStates(states: []const State) u32 {
    var count: u32 = 0;
    for (states) |s| {
        switch (s) {
            .char, .ranges, .any, .fail, .match => count += 1,
            .empty, .capture, .assert, .alt, .alt2 => {},
        }
    }
    return count;
}

/// Normalize + negate the ranges at `Compiler.ranges[start..]` in place.
/// Returns the new logical tail length.
///
/// Negation can produce at most one more range than its normalized input.
/// The caller must have reserved this spare slot in capacity before calling.
fn negateTailRanges(c: *Compiler, start: usize) usize {
    const len = c.normalizeTailRanges(start);

    assert(c.ranges.capacity >= start + len + 1);
    c.ranges.items.len = start + len + 1;

    const max_byte = std.math.maxInt(u8);

    var write_i: usize = start;
    var next_from: u8 = 0;

    for (start..start + len) |read_i| {
        const range = c.ranges.items[read_i];
        if (next_from < range.from) {
            c.ranges.items[write_i] = .{
                .from = next_from,
                .to = range.from - 1,
            };
            write_i += 1;
        }
        if (range.to == max_byte) break;
        next_from = range.to + 1;
    } else {
        c.ranges.items[write_i] = .{
            .from = next_from,
            .to = max_byte,
        };
        write_i += 1;
    }

    const new_len = write_i - start;
    c.ranges.shrinkRetainingCapacity(start + new_len);
    return new_len;
}

/// Finalizes a class tail segment into the most specific matcher state:
/// `fail` for empty, `char` for singleton byte, otherwise `ranges`.
fn finishTailClass(c: *Compiler, start: usize, len: usize) !Frag {
    c.ranges.shrinkRetainingCapacity(start + len);

    if (len == 0) {
        c.ranges.shrinkRetainingCapacity(start);
        return c.state(.fail);
    }

    const ranges = c.ranges.items[start..][0..len];
    if (ranges.len == 1 and ranges[0].from == ranges[0].to) {
        c.ranges.shrinkRetainingCapacity(start);
        return c.state(.{ .char = .{ .byte = ranges[0].from, .out = 0 } });
    }

    return c.state(.{ .ranges = .{
        .start = @intCast(start),
        .len = @intCast(len),
        .negated = false,
        .out = 0,
    } });
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

/// A compiled fragment returned by compileNode.
/// - id: the id of the entry state of the fragment
/// - outs: dangling out-edges that must be patched to the next fragment
///
/// In the state list for execution, id 0 is reserved for .capture slot 0 state,
/// so `Frag.zero` can be used as an internal sentinel and never refers to a
/// real patchable fragment.
const Frag = struct {
    id: StateId,
    outs: PatchList,
    nullable: bool,

    const zero: Frag = .{
        .id = 0,
        .outs = .empty,
        .nullable = false,
    };
};

/// In the state list for execution, id 0 is reserved for .capture slot 0 state,
/// so it's safe to repurpose it during building as dangling (i.e. to be patched).
/// For `PatchList`, this means that `Ptr` with StateId = 0 indicates dangling.
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
    return expectProgramWithOptions(pattern, expected, .{});
}

fn expectProgramWithOptions(pattern: []const u8, expected: []const Vertex, opts: TopLevelOptions) !void {
    const a = testing.allocator;
    const prog = try Compiler.compile(a, pattern, opts);
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

test "non-capturing group" {
    // does not emit capture states
    try expectProgram("(?:a)(b)", &.{
        g.capt(0, 1),
        g.char('a', 2),
        g.capt(2, 3),
        g.char('b', 4),
        g.capt(3, 5),
        g.capt(1, 6),
        g.match(),
    });
}

test "named capturing group" {
    try expectProgram("(?<first>a)(?P<last>b)", &.{
        g.capt(0, 1),
        g.capt(2, 2),
        g.char('a', 3),
        g.capt(3, 4),
        g.capt(4, 5),
        g.char('b', 6),
        g.capt(5, 7),
        g.capt(1, 8),
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

test "swap greed option" {
    try expectProgramWithOptions("a*", &.{
        g.capt(0, 1),
        g.alt2(2, 3),
        g.capt(1, 4),
        g.char('a', 1),
        g.match(),
    }, .{ .syntax = .{ .swap_greed = true } });

    try expectProgramWithOptions("a*?", &.{
        g.capt(0, 1),
        g.alt2(2, 3),
        g.char('a', 1),
        g.capt(1, 4),
        g.match(),
    }, .{ .syntax = .{ .swap_greed = true } });
}

test "dot compile" {
    try expectProgram(".", &.{
        g.capt(0, 1),
        g.any(.not_lf, 2),
        g.capt(1, 3),
        g.match(),
    });
    try expectProgramWithOptions(".", &.{
        g.capt(0, 1),
        g.any(.all, 2),
        g.capt(1, 3),
        g.match(),
    }, .{ .syntax = .{ .dot_matches_new_line = true } });
}

test "case insensitive compile" {
    try expectProgramWithOptions("a", &.{
        g.capt(0, 1),
        g.ranges(&.{ g.r('A', 'A'), g.r('a', 'a') }, false, 2),
        g.capt(1, 3),
        g.match(),
    }, .{ .syntax = .{ .case_insensitive = true } });

    try expectProgramWithOptions("1", &.{
        g.capt(0, 1),
        g.char('1', 2),
        g.capt(1, 3),
        g.match(),
    }, .{ .syntax = .{ .case_insensitive = true } });

    try expectProgramWithOptions("[A-Z]", &.{
        g.capt(0, 1),
        g.ranges(&.{ g.r('A', 'Z'), g.r('a', 'z') }, false, 2),
        g.capt(1, 3),
        g.match(),
    }, .{ .syntax = .{ .case_insensitive = true } });

    try expectProgramWithOptions("\\A[[:^lower:]]+\\z", &.{
        g.capt(0, 1),
        g.asrt(.start_text, 2),
        g.ranges(&.{ g.r(0x00, '@'), g.r('[', '`'), g.r('{', 0xFF) }, false, 3),
        g.alt2(2, 4),
        g.asrt(.end_text, 5),
        g.capt(1, 6),
        g.match(),
    }, .{ .syntax = .{ .case_insensitive = true } });
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
    try expectProgram("\\Are\\z", &.{
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
    try expectProgramWithOptions("^re$", &.{
        g.capt(0, 1),
        g.asrt(.start_line, 2),
        g.char('r', 3),
        g.char('e', 4),
        g.asrt(.end_line, 5),
        g.capt(1, 6),
        g.match(),
    }, .{ .syntax = .{ .multi_line = true } });
}

test "literal prefix" {
    const test_cases = &[_]struct {
        pattern: []const u8,
        expected: ?u8,
    }{
        .{ .pattern = "abc", .expected = 'a' },
        .{ .pattern = "(a)", .expected = 'a' },
        .{ .pattern = "(?:)abc", .expected = 'a' },
        .{ .pattern = "a|b", .expected = null },
        .{ .pattern = "^a", .expected = null },
        .{ .pattern = ".", .expected = null },
        .{ .pattern = "[ab]", .expected = null },
    };

    for (test_cases) |tc| {
        const prog = try Compiler.compile(testing.allocator, tc.pattern, .{});
        defer prog.deinit();
        try testing.expectEqual(tc.expected, prog.literalPrefix());
    }
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const assert = std.debug.assert;
const builtin = @import("builtin");

pub const Ast = @import("Ast.zig");
const errors = @import("errors.zig");
const Diagnostics = errors.Diagnostics;
const TopLevelOptions = @import("types.zig").CompileOptions;
const SyntaxOptions = TopLevelOptions.Syntax;
pub const Parser = @import("Parser.zig");
const Program = @import("Program.zig");
const g = @import("program_graph.zig");
const State = Program.State;
const StateId = Program.StateId;
const ByteRange = Program.ByteRange;
const Vertex = g.Vertex;
