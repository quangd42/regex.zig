const std = @import("std");
const Backend = @import("adapters.zig").Backend;

pub const Capability = enum {
    // Core syntax.
    literal,
    escaped_literal,
    dot,
    concat,
    alternation,

    // Groups and captures.
    capture_group,
    noncapture_group,
    named_capture_group,

    // Repetition.
    rep_zero_or_one,
    rep_zero_or_more,
    rep_one_or_more,
    rep_exact,
    rep_min,
    rep_range,
    rep_lazy,
    rep_possessive,

    // Character classes.
    class_simple,
    class_range,
    class_negated,
    class_posix,
    class_perl,
    class_unicode_property,
    class_unicode_script_or_block,

    // Assertions and boundaries.
    anchor_line_start,
    anchor_line_end,
    anchor_text_start,
    anchor_text_end,
    word_boundary,
    not_word_boundary,
    word_boundary_start,
    word_boundary_end,
    word_boundary_start_half,
    word_boundary_end_half,

    // Escapes.
    escape_c_style,
    escape_hex_byte,
    escape_hex_braced,
    escape_unicode_short,
    escape_unicode_long,
    escape_octal,
    escape_literal_mode,

    // Flags and parser modes.
    ignore_case, // i
    multi_line, // m
    dot_matches_new_line, // s
    swap_greed, // U
    crlf_mode, // R
    inline_flags_global,
    inline_flags_scoped,
    inline_flags_toggle,
    unicode_mode,
    utf8_mode,
    line_terminator_override,

    // Search and match semantics.
    search_leftmost,
    search_earliest,
    search_overlapping,
    match_kind_leftmost_first,
    match_kind_all,
    match_kind_leftmost_longest,
    empty_match_no_split_codepoint,

    // Input controls.
    input_anchored,
    input_bounds,
    input_bytes,
    input_utf8_text,

    // API surface.
    api_is_match,
    api_find,
    api_captures,
    api_find_iter,
    api_captures_iter,
    api_pattern_set,
    api_which,

    // Harness directives.
    case_unescape,
    case_match_limit,
    case_compiles_true,
    case_compiles_false,

    // Explicitly unsupported/advanced syntax.
    lookahead,
    negative_lookahead,
    lookbehind,
    negative_lookbehind,
    backref_numeric,
    backref_named,
};

pub const CapSet = std.EnumSet(Capability);

/// The entry for Capability x Backend matrix (the column).
pub const CapBackendMapEntry = std.enums.EnumFieldStruct(Backend, bool, false);

/// Single source-of-truth capability x backend matrix.
///
/// Each capability row must explicitly set support for every backend.
pub const cap_backend_map = std.EnumArray(Capability, CapBackendMapEntry).init(.{
    // Core syntax.
    .literal = .{ .pikevm = true },
    .escaped_literal = .{ .pikevm = true },
    .dot = .{ .pikevm = true },
    .concat = .{ .pikevm = true },
    .alternation = .{ .pikevm = true },

    // Groups and captures.
    .capture_group = .{ .pikevm = true },
    .noncapture_group = .{ .pikevm = false },
    .named_capture_group = .{ .pikevm = false },

    // Repetition.
    .rep_zero_or_one = .{ .pikevm = true },
    .rep_zero_or_more = .{ .pikevm = true },
    .rep_one_or_more = .{ .pikevm = true },
    .rep_exact = .{ .pikevm = true },
    .rep_min = .{ .pikevm = true },
    .rep_range = .{ .pikevm = true },
    .rep_lazy = .{ .pikevm = true },
    .rep_possessive = .{ .pikevm = false },

    // Character classes.
    .class_simple = .{ .pikevm = true },
    .class_range = .{ .pikevm = true },
    .class_negated = .{ .pikevm = true },
    .class_posix = .{ .pikevm = true },
    .class_perl = .{ .pikevm = true },
    .class_unicode_property = .{ .pikevm = false },
    .class_unicode_script_or_block = .{ .pikevm = false },

    // Assertions and boundaries.
    .anchor_line_start = .{ .pikevm = true },
    .anchor_line_end = .{ .pikevm = true },
    .anchor_text_start = .{ .pikevm = false },
    .anchor_text_end = .{ .pikevm = false },
    .word_boundary = .{ .pikevm = true },
    .not_word_boundary = .{ .pikevm = true },
    .word_boundary_start = .{ .pikevm = false },
    .word_boundary_end = .{ .pikevm = false },
    .word_boundary_start_half = .{ .pikevm = false },
    .word_boundary_end_half = .{ .pikevm = false },

    // Escapes.
    .escape_c_style = .{ .pikevm = true },
    .escape_hex_byte = .{ .pikevm = true },
    .escape_hex_braced = .{ .pikevm = false },
    .escape_unicode_short = .{ .pikevm = false },
    .escape_unicode_long = .{ .pikevm = false },
    .escape_octal = .{ .pikevm = false },
    .escape_literal_mode = .{ .pikevm = false },

    // Flags and parser modes.
    .ignore_case = .{ .pikevm = false },
    .multi_line = .{ .pikevm = false },
    .dot_matches_new_line = .{ .pikevm = false },
    .swap_greed = .{ .pikevm = false },
    .crlf_mode = .{ .pikevm = false },
    .inline_flags_global = .{ .pikevm = false },
    .inline_flags_scoped = .{ .pikevm = false },
    .inline_flags_toggle = .{ .pikevm = false },
    .unicode_mode = .{ .pikevm = false },
    .utf8_mode = .{ .pikevm = false },
    .line_terminator_override = .{ .pikevm = false },

    // Search and match semantics.
    .search_leftmost = .{ .pikevm = true },
    .search_earliest = .{ .pikevm = true },
    .search_overlapping = .{ .pikevm = false },
    .match_kind_leftmost_first = .{ .pikevm = true },
    .match_kind_all = .{ .pikevm = false },
    .match_kind_leftmost_longest = .{ .pikevm = false },
    .empty_match_no_split_codepoint = .{ .pikevm = false },

    // Input controls.
    .input_anchored = .{ .pikevm = false },
    .input_bounds = .{ .pikevm = false },
    .input_bytes = .{ .pikevm = false },
    .input_utf8_text = .{ .pikevm = false },

    // API surface.
    .api_is_match = .{ .pikevm = true },
    .api_find = .{ .pikevm = true },
    .api_captures = .{ .pikevm = true },
    .api_find_iter = .{ .pikevm = false },
    .api_captures_iter = .{ .pikevm = false },
    .api_pattern_set = .{ .pikevm = false },
    .api_which = .{ .pikevm = false },

    // Harness directives.
    .case_unescape = .{ .pikevm = false },
    .case_match_limit = .{ .pikevm = true },
    .case_compiles_true = .{ .pikevm = true },
    .case_compiles_false = .{ .pikevm = false },

    // Explicitly unsupported/advanced syntax.
    .lookahead = .{ .pikevm = false },
    .negative_lookahead = .{ .pikevm = false },
    .lookbehind = .{ .pikevm = false },
    .negative_lookbehind = .{ .pikevm = false },
    .backref_numeric = .{ .pikevm = false },
    .backref_named = .{ .pikevm = false },
});
