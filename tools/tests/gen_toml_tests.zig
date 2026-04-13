//! Corpus generator used by `tools/tests/main.zig`.
//! It consumes Rust regex style TOML test suites via `zig-toml` and emits
//! per-case Zig tests under `tests/`.

const std = @import("std");
const toml = @import("toml");
const Allocator = std.mem.Allocator;

const SuiteSpec = struct {
    source_path: []const u8,
    output_path: []const u8,
    suite_name: []const u8,
    generator_cmd: []const u8,
    matches_format: MatchesFormat,
};

const MatchesFormat = enum {
    matches,
    captures,
};

const SourceConfig = struct {
    command: []const u8,
    source_dir: []const u8,
    output_dir: []const u8,
    suite_prefix: []const u8,
    files: []const []const u8,
    matches_format: MatchesFormat,
};

const RawCase = struct {
    name: []const u8,
    regex: []const u8,
    haystack: []const u8,
    expected_groups: []const MatchGroup,
    @"match-limit": usize = 1,
    compiles: ?bool = null,
    anchored: bool = false,
    unescape: bool = false,
    @"case-insensitive": bool = false,
    @"multi-line": bool = false,
    @"dot-matches-new-line": bool = false,
    @"swap-greed": bool = false,
    unicode: ?bool = null,
};

const Span = [2]usize;
const MatchGroup = ?Span;

fn ParsedCase(comptime MatchesT: type) type {
    return struct {
        name: []const u8,
        regex: []const u8,
        haystack: []const u8,
        matches: MatchesT,
        @"match-limit": usize = 1,
        compiles: ?bool = null,
        anchored: bool = false,
        unescape: bool = false,
        @"case-insensitive": bool = false,
        @"multi-line": bool = false,
        @"dot-matches-new-line": bool = false,
        @"swap-greed": bool = false,
        unicode: ?bool = null,
    };
}

fn ParsedFile(comptime MatchesT: type) type {
    return struct {
        @"test": []const ParsedCase(MatchesT),
    };
}

const Matches = []const Span;
const Captures = []const []const []const usize;
const MatchesFile = ParsedFile(Matches);
const CapturesFile = ParsedFile(Captures);

const GroupsError = error{InvalidMatchGroupShape} || Allocator.Error;

const CapKey = enum {
    // Syntax.
    dot,
    alternation,
    noncapture_group,
    named_capture_group,
    rep_zero_or_one,
    rep_zero_or_more,
    rep_one_or_more,
    rep_exact,
    rep_min,
    rep_range,
    rep_lazy,
    rep_possessive,
    class_simple,
    class_range,
    class_negated,
    class_posix,
    class_perl,
    class_unicode_property,
    class_unicode_script_or_block,
    anchor_line_start,
    anchor_line_end,
    anchor_text_start,
    anchor_text_end,
    word_boundary,
    not_word_boundary,
    escape_c_style,
    escape_hex_byte,
    escape_hex_braced,
    escape_unicode_short,
    escape_unicode_long,
    escape_octal,
    escape_literal_mode,
    inline_flags_global,
    inline_flags_scoped,
    inline_flags_toggle,
    ignore_case,
    multi_line,
    dot_matches_new_line,
    swap_greed,
    unicode_mode,
    crlf_mode,
    lookahead,
    negative_lookahead,
    lookbehind,
    negative_lookbehind,
    backref_numeric,
    backref_named,

    // Harness / directives.
    case_unescape,
    case_match_limit,
    case_compiles_true,
    case_compiles_false,
    input_anchored,
};

const CapKeySet = std.EnumSet(CapKey);

const fowler_source: SourceConfig = .{
    .command = "fowler",
    .source_dir = "tests/fowler/data",
    .output_dir = "tests/fowler",
    .suite_prefix = "fowler",
    .files = &.{ "basic", "repetition", "nullsubexpr" },
    .matches_format = .captures,
};

const rust_regex_source: SourceConfig = .{
    .command = "rust-regex",
    .source_dir = "tests/data",
    .output_dir = "tests/generated",
    .suite_prefix = "rust-regex",
    .files = &.{ "flags", "multiline" },
    .matches_format = .matches,
};

const local_matches_source: SourceConfig = .{
    .command = "local",
    .source_dir = "tests/data",
    .output_dir = "tests/generated",
    .suite_prefix = "local",
    .files = &.{"flags-local"},
    .matches_format = .matches,
};

const local_captures_source: SourceConfig = .{
    .command = "local",
    .source_dir = "tests/data",
    .output_dir = "tests/generated",
    .suite_prefix = "local",
    .files = &.{"flags-local-captures"},
    .matches_format = .captures,
};

const fowler_sources = [_]SourceConfig{fowler_source};
const rust_regex_sources = [_]SourceConfig{rust_regex_source};
const local_sources = [_]SourceConfig{ local_matches_source, local_captures_source };

pub fn run() !void {
    try runAll();
}

pub fn runAll() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var total: usize = 0;
    total += try generateSources(arena.allocator(), "fowler", &fowler_sources);
    total += try generateSources(arena.allocator(), "rust-regex", &rust_regex_sources);
    total += try generateSources(arena.allocator(), "local", &local_sources);
    std.debug.print("TOML test generation complete ({d} total cases)\n", .{total});
}

pub fn runFowler() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    _ = try generateSources(arena.allocator(), "fowler", &fowler_sources);
}

pub fn runRustRegex() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    _ = try generateSources(arena.allocator(), "rust-regex", &rust_regex_sources);
}

pub fn runLocal() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    _ = try generateSources(arena.allocator(), "local", &local_sources);
}

fn generateSources(alloc: Allocator, command: []const u8, sources: []const SourceConfig) !usize {
    var total: usize = 0;
    for (sources) |source| {
        total += try generateSource(alloc, source);
    }
    std.debug.print("{s} generation complete ({d} total cases)\n", .{ command, total });
    return total;
}

fn generateSource(alloc: Allocator, source: SourceConfig) !usize {
    var total: usize = 0;
    for (source.files) |stem| {
        var source_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        var output_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        var suite_name_buf: [std.fs.max_path_bytes]u8 = undefined;
        const suite = SuiteSpec{
            .source_path = try std.fmt.bufPrint(
                &source_path_buf,
                "{s}/{s}.toml",
                .{ source.source_dir, stem },
            ),
            .output_path = try std.fmt.bufPrint(
                &output_path_buf,
                "{s}/{s}.zig",
                .{ source.output_dir, stem },
            ),
            .suite_name = try std.fmt.bufPrint(
                &suite_name_buf,
                "{s}/{s}",
                .{ source.suite_prefix, stem },
            ),
            .generator_cmd = source.command,
            .matches_format = source.matches_format,
        };
        const count = try generateSuite(alloc, suite);
        total += count;
        std.debug.print(
            "generated {s} from {s} ({d} cases)\n",
            .{ suite.output_path, suite.source_path, count },
        );
    }
    return total;
}

fn generateSuite(alloc: Allocator, spec: SuiteSpec) !usize {
    const cwd = std.fs.cwd();
    const input = try cwd.readFileAlloc(alloc, spec.source_path, std.math.maxInt(usize));

    const cases = switch (spec.matches_format) {
        .matches => blk: {
            var parser = toml.Parser(MatchesFile).init(alloc);
            defer parser.deinit();

            const parsed = try parser.parseString(input);
            break :blk try normalizeCases(Matches, alloc, parsed.value.@"test", firstMatchFromMatches);
        },
        .captures => blk: {
            var parser = toml.Parser(CapturesFile).init(alloc);
            defer parser.deinit();

            const parsed = try parser.parseString(input);
            break :blk try normalizeCases(Captures, alloc, parsed.value.@"test", firstMatchFromCaptures);
        },
    };
    try writeGeneratedFile(spec, cases);
    return cases.len;
}

fn normalizeCases(
    comptime MatchesT: type,
    alloc: Allocator,
    parsed_cases: []const ParsedCase(MatchesT),
    comptime extractGroups: *const fn (Allocator, MatchesT) GroupsError![]const MatchGroup,
) ![]const RawCase {
    const cases = try alloc.alloc(RawCase, parsed_cases.len);
    for (parsed_cases, 0..) |parsed_case, i| {
        cases[i] = initRawCase(parsed_case, try extractGroups(alloc, parsed_case.matches));
    }
    return cases;
}

fn initRawCase(parsed_case: anytype, expected_groups: []const MatchGroup) RawCase {
    return .{
        .name = parsed_case.name,
        .regex = parsed_case.regex,
        .haystack = parsed_case.haystack,
        .expected_groups = expected_groups,
        .@"match-limit" = parsed_case.@"match-limit",
        .compiles = parsed_case.compiles,
        .anchored = parsed_case.anchored,
        .unescape = parsed_case.unescape,
        .@"case-insensitive" = parsed_case.@"case-insensitive",
        .@"multi-line" = parsed_case.@"multi-line",
        .@"dot-matches-new-line" = parsed_case.@"dot-matches-new-line",
        .@"swap-greed" = parsed_case.@"swap-greed",
        .unicode = parsed_case.unicode,
    };
}

fn firstMatchFromMatches(alloc: Allocator, matches: Matches) GroupsError![]const MatchGroup {
    if (matches.len == 0) return alloc.alloc(MatchGroup, 0);

    const groups = try alloc.alloc(MatchGroup, 1);
    groups[0] = matches[0];
    return groups;
}

fn firstMatchFromCaptures(alloc: Allocator, matches: Captures) GroupsError![]const MatchGroup {
    if (matches.len == 0) return alloc.alloc(MatchGroup, 0);

    const first = matches[0];
    const groups = try alloc.alloc(MatchGroup, first.len);
    for (first, 0..) |span, i| {
        groups[i] = try parseCaptureGroup(span);
    }
    return groups;
}

fn parseCaptureGroup(span: []const usize) GroupsError!MatchGroup {
    if (span.len == 0) return null;
    if (span.len != 2) return error.InvalidMatchGroupShape;
    return .{ span[0], span[1] };
}

fn writeGeneratedFile(spec: SuiteSpec, cases: []const RawCase) !void {
    const cwd = std.fs.cwd();
    const out_dir = std.fs.path.dirname(spec.output_path) orelse return error.InvalidOutputPath;
    try cwd.makePath(out_dir);

    const file = try cwd.createFile(spec.output_path, .{});
    defer file.close();

    var file_writer_buf: [8192]u8 = undefined;
    var file_writer = file.writer(&file_writer_buf);
    const w = &file_writer.interface;
    try w.print("//! GENERATED by `zig build gen-tests -- {s}`.\n", .{spec.generator_cmd});
    try w.print("//! Source: {s}\n", .{spec.source_path});
    try w.writeAll("//! DO NOT EDIT.\n\n");
    try w.writeAll("const std = @import(\"std\");\n");
    try w.writeAll("const gpa = std.testing.allocator;\n");
    try w.writeAll("const harness = @import(\"../harness.zig\");\n");
    try w.writeAll("const exec = harness.execute;\n");
    try w.writeAll("const caps = harness.capabilities;\n");
    try w.writeAll("const root = @import(\"root\");\n");
    try w.writeAll("const Match = @import(\"export_test\").Regex.Match;\n\n");
    try w.writeAll(
        \\fn config() exec.Options {
        \\    return .{ .verbose = root.verbose, .trace = root.trace };
        \\}
        \\
        \\fn executeCase(tc: exec.Case) !void {
        \\    try exec.execute(gpa, tc, .pikevm, config());
        \\}
        \\
    );
    try writeSuiteTests(w, spec, cases);
    try w.flush();
}

fn writeCaseLiteral(
    w: *std.Io.Writer,
    spec: SuiteSpec,
    tc: RawCase,
    indent: []const u8,
) !void {
    try w.writeByte('\n');
    try w.print("{s}    .name = ", .{indent});
    try w.print("\"{s}/{s}\"", .{ spec.suite_name, tc.name });
    try w.writeAll(",\n");

    try w.print("{s}    .pattern = ", .{indent});
    try writeEscapedZigString(w, tc.regex);
    try w.writeAll(",\n");

    try w.print("{s}    .input = .{{", .{indent});
    try w.writeAll(" .haystack = ");
    try writeEscapedZigString(w, tc.haystack);
    try w.writeAll(", .anchored = ");
    try writeBool(w, tc.anchored);
    try w.writeAll(" },\n");

    const groups = tc.expected_groups;

    if (groups.len == 0) {
        try w.print("{s}    .expected = &[_]?Match{{}},\n", .{indent});
    } else if (groups.len == 1) {
        try w.print("{s}    .expected = &[_]?Match{{", .{indent});
        const group = groups[0];
        if (group) |gr| {
            try w.print(".{{ .start = {d}, .end = {d} }}", .{ gr[0], gr[1] });
            try w.writeAll("},\n");
        } else {
            try w.writeAll("null},\n");
        }
    } else {
        try w.print("{s}    .expected = &[_]?Match{{", .{indent});
        try w.writeAll("\n");
        for (groups) |group| {
            try w.print("{s}        ", .{indent});
            if (group) |gr| {
                try w.print(".{{ .start = {d}, .end = {d} }},\n", .{ gr[0], gr[1] });
            } else {
                try w.writeAll("null,\n");
            }
        }
        try w.print("{s}    }},\n", .{indent});
    }

    var requires = inferPatternCaps(tc.regex);
    if (tc.anchored) requires.insert(.input_anchored);
    if (tc.unescape) requires.insert(.case_unescape);
    if (tc.@"case-insensitive") {
        requires.insert(.ignore_case);
    }
    if (tc.@"multi-line") requires.insert(.multi_line);
    if (tc.@"dot-matches-new-line") requires.insert(.dot_matches_new_line);
    if (tc.@"swap-greed") requires.insert(.swap_greed);
    if (tc.unicode) |unicode| {
        if (unicode) requires.insert(.unicode_mode);
    }
    if (tc.@"match-limit" != 1) requires.insert(.case_match_limit);
    if (tc.compiles) |compiles| {
        requires.insert(if (compiles) .case_compiles_true else .case_compiles_false);
    }

    if (requires.count() > 0) {
        if (tc.@"case-insensitive" or
            tc.@"multi-line" or
            tc.@"dot-matches-new-line" or
            tc.@"swap-greed")
        {
            try w.print("{s}    .options = .{{ .syntax = .{{\n", .{indent});
            if (tc.@"case-insensitive") {
                try w.print("{s}        .case_insensitive = true,\n", .{indent});
            }
            if (tc.@"multi-line") {
                try w.print("{s}        .multi_line = true,\n", .{indent});
            }
            if (tc.@"dot-matches-new-line") {
                try w.print("{s}        .dot_matches_new_line = true,\n", .{indent});
            }
            if (tc.@"swap-greed") {
                try w.print("{s}        .swap_greed = true,\n", .{indent});
            }
            try w.print("{s}    }} }},\n", .{indent});
        }
        try w.print("{s}    .requires = caps.requires(.{{ ", .{indent});
        var first = true;
        inline for (std.meta.fields(CapKey)) |field| {
            const cap: CapKey = @enumFromInt(field.value);
            if (requires.contains(cap)) {
                try writeCapKey(w, &first, cap);
            }
        }
        try w.writeAll(" }),\n");
    }
}

fn writeCapKey(w: *std.Io.Writer, first: *bool, cap: CapKey) !void {
    if (!first.*) try w.writeAll(", ");
    first.* = false;
    try w.print(".{s} = true", .{@tagName(cap)});
}

fn writeEscapedZigString(w: *std.Io.Writer, bytes: []const u8) !void {
    try w.writeByte('"');
    for (bytes) |b| {
        switch (b) {
            '\\' => try w.writeAll("\\\\"),
            '"' => try w.writeAll("\\\""),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (b < 0x20 or b > 0x7e) {
                    try w.print("\\x{X:0>2}", .{b});
                } else {
                    try w.writeByte(b);
                }
            },
        }
    }
    try w.writeByte('"');
}

fn writeBool(w: *std.Io.Writer, b: bool) !void {
    if (b) try w.writeAll("true") else try w.writeAll("false");
}

fn writeSuiteTests(w: *std.Io.Writer, spec: SuiteSpec, cases: []const RawCase) !void {
    for (cases) |tc| {
        try w.print(
            \\
            \\test "{s}/{s}" {{
            \\    try executeCase(.{{
        , .{ spec.suite_name, tc.name });
        try writeCaseLiteral(w, spec, tc, "    ");
        try w.writeAll(
            \\    });
            \\}
            \\
        );
    }
}

fn inferPatternCaps(pattern: []const u8) CapKeySet {
    // This intentionally derives only syntax capabilities heuristically from the
    // pattern text. Case-level capabilities from TOML fields are still added by
    // the generator separately.
    //
    // Long term, syntax capability detection should move to the parser/AST once
    // the parser can recognize and categorize the full syntax surface we care
    // about. Doing that earlier would just trade one partial heuristic for
    // another partial classifier.
    var caps = CapKeySet.initEmpty();
    var in_class = false;
    var class_started = false;
    var class_first = false;
    var escaped = false;

    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        const c = pattern[i];
        if (escaped) {
            i = handleEscapeAt(pattern, i, &caps);
            escaped = false;
            continue;
        }
        if (c == '\\') {
            escaped = true;
            continue;
        }

        if (in_class) {
            if (class_first) {
                class_first = false;
                if (c == '^') {
                    caps.insert(.class_negated);
                    continue;
                }
            }

            if (c == '[' and i + 1 < pattern.len and pattern[i + 1] == ':') {
                caps.insert(.class_posix);
            } else if (c == '-' and i + 1 < pattern.len and pattern[i + 1] != ']' and class_started) {
                caps.insert(.class_range);
            } else if (c == ']' and class_started) {
                in_class = false;
                continue;
            }

            class_started = true;
            continue;
        }

        switch (c) {
            '[' => {
                in_class = true;
                class_started = false;
                class_first = true;
                caps.insert(.class_simple);
            },
            '.' => caps.insert(.dot),
            '|' => caps.insert(.alternation),
            '^' => caps.insert(.anchor_line_start),
            '$' => caps.insert(.anchor_line_end),
            '(' => handleGroup(pattern, &i, &caps),
            '?' => {
                caps.insert(.rep_zero_or_one);
                if (i + 1 < pattern.len and pattern[i + 1] == '+') caps.insert(.rep_possessive);
            },
            '*' => {
                caps.insert(.rep_zero_or_more);
                if (i + 1 < pattern.len and pattern[i + 1] == '?') caps.insert(.rep_lazy);
                if (i + 1 < pattern.len and pattern[i + 1] == '+') caps.insert(.rep_possessive);
            },
            '+' => {
                caps.insert(.rep_one_or_more);
                if (i + 1 < pattern.len and pattern[i + 1] == '?') caps.insert(.rep_lazy);
                if (i + 1 < pattern.len and pattern[i + 1] == '+') caps.insert(.rep_possessive);
            },
            '{' => handleRepeatRange(pattern, &i, &caps),
            else => {},
        }
    }

    return caps;
}

fn handleGroup(pattern: []const u8, i: *usize, caps: *CapKeySet) void {
    if (i.* + 1 >= pattern.len or pattern[i.* + 1] != '?') return;
    if (i.* + 2 >= pattern.len) return;

    const marker = pattern[i.* + 2];
    switch (marker) {
        ':' => {
            caps.insert(.noncapture_group);
            return;
        },
        '=' => {
            caps.insert(.lookahead);
            return;
        },
        '!' => {
            caps.insert(.negative_lookahead);
            return;
        },
        '<' => {
            if (i.* + 3 < pattern.len and pattern[i.* + 3] == '=') {
                caps.insert(.lookbehind);
                return;
            }
            if (i.* + 3 < pattern.len and pattern[i.* + 3] == '!') {
                caps.insert(.negative_lookbehind);
                return;
            }
            return;
        },
        'P' => {
            if (i.* + 3 < pattern.len and pattern[i.* + 3] == '<') {
                caps.insert(.named_capture_group);
            }
            return;
        },
        else => {},
    }

    var j = i.* + 2;
    var saw_flag = false;
    var saw_toggle = false;
    while (j < pattern.len) : (j += 1) {
        const c = pattern[j];
        if (c == ':') {
            caps.insert(.inline_flags_scoped);
            if (saw_toggle) caps.insert(.inline_flags_toggle);
            i.* = j;
            return;
        }
        if (c == ')') {
            if (saw_flag) caps.insert(.inline_flags_global);
            if (saw_toggle) caps.insert(.inline_flags_toggle);
            i.* = j;
            return;
        }
        if (c == '-') {
            saw_toggle = true;
            continue;
        }
        if (c == 'i' or c == 'm' or c == 's' or c == 'U' or c == 'u' or c == 'R') {
            saw_flag = true;
            switch (c) {
                'i' => caps.insert(.ignore_case),
                'm' => caps.insert(.multi_line),
                's' => caps.insert(.dot_matches_new_line),
                'U' => caps.insert(.swap_greed),
                'u' => caps.insert(.unicode_mode),
                'R' => caps.insert(.crlf_mode),
                else => unreachable,
            }
            continue;
        }
        break;
    }
}

fn handleRepeatRange(pattern: []const u8, i: *usize, caps: *CapKeySet) void {
    var j = i.* + 1;
    while (j < pattern.len and pattern[j] != '}') : (j += 1) {}
    if (j >= pattern.len) return;

    const body = pattern[i.* + 1 .. j];
    if (body.len == 0) return;

    const comma = std.mem.indexOfScalar(u8, body, ',');
    if (comma == null) {
        caps.insert(.rep_exact);
    } else if (comma.? + 1 == body.len) {
        caps.insert(.rep_min);
    } else {
        caps.insert(.rep_range);
    }

    if (j + 1 < pattern.len and pattern[j + 1] == '?') caps.insert(.rep_lazy);
    if (j + 1 < pattern.len and pattern[j + 1] == '+') caps.insert(.rep_possessive);
    i.* = j;
}

fn handleEscapeAt(pattern: []const u8, index: usize, caps: *CapKeySet) usize {
    var i = index;
    const c = pattern[i];
    if (c >= '1' and c <= '9') {
        caps.insert(.backref_numeric);
        if (c <= '7') caps.insert(.escape_octal);
        return i;
    }
    if (c == '0') {
        caps.insert(.escape_octal);
        return i;
    }

    switch (c) {
        'A' => caps.insert(.anchor_text_start),
        'z' => caps.insert(.anchor_text_end),
        'b' => caps.insert(.word_boundary),
        'B' => caps.insert(.not_word_boundary),
        'd', 'D', 'w', 'W', 's', 'S' => caps.insert(.class_perl),
        'x' => {
            if (i + 1 < pattern.len and pattern[i + 1] == '{') {
                caps.insert(.escape_hex_braced);
                if (consumeBracedEscape(pattern, i + 1)) |end| i = end;
            } else {
                caps.insert(.escape_hex_byte);
            }
        },
        'u' => caps.insert(.escape_unicode_short),
        'U' => caps.insert(.escape_unicode_long),
        'a', 'f', 'n', 'r', 't', 'v' => caps.insert(.escape_c_style),
        'Q', 'E' => caps.insert(.escape_literal_mode),
        'p', 'P' => {
            caps.insert(.class_unicode_property);
            if (i + 1 < pattern.len and pattern[i + 1] == '{') {
                const end = consumeBracedEscape(pattern, i + 1) orelse return i;
                const content = pattern[i + 2 .. end];
                if (isUnicodeScriptOrBlock(content)) caps.insert(.class_unicode_script_or_block);
                i = end;
            }
        },
        'k' => {
            if (i + 1 < pattern.len and pattern[i + 1] == '<') caps.insert(.backref_named);
        },
        else => {},
    }
    return i;
}

fn consumeBracedEscape(pattern: []const u8, open_index: usize) ?usize {
    if (pattern[open_index] != '{') return null;
    var i = open_index + 1;
    while (i < pattern.len) : (i += 1) {
        if (pattern[i] == '}') return i;
    }
    return null;
}

fn isUnicodeScriptOrBlock(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.startsWith(u8, name, "sc=") or std.mem.startsWith(u8, name, "scx=")) return true;
    if (std.mem.startsWith(u8, name, "script=") or std.mem.startsWith(u8, name, "Script=")) return true;
    if (std.mem.startsWith(u8, name, "blk=") or std.mem.startsWith(u8, name, "block=")) return true;
    if (std.mem.startsWith(u8, name, "In")) return true;
    return false;
}
