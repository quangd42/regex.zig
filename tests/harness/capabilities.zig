const std = @import("std");
const Backend = @import("adapters.zig").Backend;

pub const Capability = enum {
    // Core syntax.
    /// Plain literal character matching.
    literal,
    /// Escaped metacharacter treated as literal text.
    escaped_literal,
    /// Dot wildcard that matches a single codepoint.
    dot,
    /// Adjacent expressions match in sequence.
    concat,
    /// Alternation with `|` across branches.
    alternation,

    // Groups and captures.
    /// Parenthesized capturing group `(...)`.
    capture_group,
    /// Parenthesized non-capturing group `(?:...)`.
    noncapture_group,
    /// Named capturing group such as `(?P<name>...)`.
    named_capture_group,

    // Repetition.
    /// Optional quantifier `?`.
    rep_zero_or_one,
    /// Kleene star quantifier `*`.
    rep_zero_or_more,
    /// One-or-more quantifier `+`.
    rep_one_or_more,
    /// Counted repetition `{m}`.
    rep_exact,
    /// Lower-bounded repetition `{m,}`.
    rep_min,
    /// Bounded repetition `{m,n}`.
    rep_range,
    /// Reluctant quantifiers such as `*?` and `+?`.
    rep_lazy,
    /// Possessive quantifiers such as `*+` and `++`.
    rep_possessive,

    // Character classes.
    /// Character class like `[abc]`.
    class_simple,
    /// Character range inside class like `[a-z]`.
    class_range,
    /// Negated character class such as `[^abc]`.
    class_negated,
    /// POSIX character classes like `[[:alpha:]]`.
    class_posix,
    /// Perl classes like `\d`, `\w`, and `\s`.
    class_perl,
    /// Unicode property class such as `\p{Letter}`.
    class_unicode_property,
    /// Unicode script or block class such as `\p{Greek}`.
    class_unicode_script_or_block,

    // Assertions and boundaries.
    /// Line-start anchor `^`.
    anchor_line_start,
    /// Line-end anchor `$`.
    anchor_line_end,
    /// Text-start anchor `\A`.
    anchor_text_start,
    /// Text-end anchor `\z`.
    anchor_text_end,
    /// Word boundary assertion `\b`.
    word_boundary,
    /// Non-word boundary assertion `\B`.
    not_word_boundary,
    /// Start-of-word boundary assertion.
    word_boundary_start,
    /// End-of-word boundary assertion.
    word_boundary_end,
    /// Half boundary for start-of-word checks.
    word_boundary_start_half,
    /// Half boundary for end-of-word checks.
    word_boundary_end_half,

    // Escapes.
    /// Escapes like `\n`, `\r`, and `\t`.
    escape_c_style,
    /// Byte hex escape `\xNN`.
    escape_hex_byte,
    /// Braced hex escape `\x{...}`.
    escape_hex_braced,
    /// Short Unicode escape `\uNNNN`.
    escape_unicode_short,
    /// Long Unicode escape `\UNNNNNNNN`.
    escape_unicode_long,
    /// Octal escape `\NNN`.
    escape_octal,
    /// Literal mode delimiters `\Q...\E`.
    escape_literal_mode,

    // Flags and parser modes.
    /// Case-insensitive mode, including inline and compile options (`i`).
    ignore_case, // i
    /// Multi-line mode for line anchors (`m`).
    multi_line, // m
    /// Dot-all mode where dot matches newline (`s`).
    dot_matches_new_line, // s
    /// Ungreedy mode that swaps greedy defaults (`U`).
    swap_greed, // U
    /// CRLF-aware line anchor behavior (`R`).
    crlf_mode, // R
    /// Global inline flags, e.g. `(?im)`.
    inline_flags_global,
    /// Scoped inline flags, e.g. `(?i:...)`.
    inline_flags_scoped,
    /// Inline enabling/disabling flags, e.g. `(?i-m)`.
    inline_flags_toggle,
    /// Unicode-enabled parsing and character semantics.
    unicode_mode,
    /// UTF-8-aware parsing and search behavior.
    utf8_mode,
    /// Custom line terminator for anchors and dot.
    line_terminator_override,

    // Search and match semantics.
    /// Search chooses the leftmost possible match start.
    search_leftmost,
    /// Search can stop at the earliest acceptable match.
    search_earliest,
    /// Iterator can report overlapping matches.
    search_overlapping,
    /// Leftmost-first match disambiguation.
    match_kind_leftmost_first,
    /// Mode that reports all match candidates.
    match_kind_all,
    /// Leftmost-longest match disambiguation.
    match_kind_leftmost_longest,
    /// Avoid splitting UTF-8 codepoints for empty matches.
    empty_match_no_split_codepoint,

    // Input controls.
    /// Input configuration forcing anchored matches.
    input_anchored,
    /// Input start/end bounds for restricted search.
    input_bounds,
    /// Byte-oriented input mode.
    input_bytes,
    /// UTF-8 text-oriented input mode.
    input_utf8_text,

    // API surface.
    /// Boolean match query API.
    api_is_match,
    /// First-match location API.
    api_find,
    /// Capture-groups API.
    api_captures,
    /// Iterator API over successive matches.
    api_find_iter,
    /// Iterator API over successive captures.
    api_captures_iter,
    /// API for matching multiple patterns at once.
    api_pattern_set,
    /// API returning which pattern matched.
    api_which,

    // Harness directives.
    /// Harness can unescape case input fields before running.
    case_unescape,
    /// Harness can enforce per-case match step limits.
    case_match_limit,
    /// Harness can assert a pattern must compile.
    case_compiles_true,
    /// Harness can assert a pattern must fail to compile.
    case_compiles_false,

    // Explicitly unsupported/advanced syntax.
    /// Positive lookahead assertion `(?=...)`.
    lookahead,
    /// Negative lookahead assertion `(?!...)`.
    negative_lookahead,
    /// Positive lookbehind assertion `(?<=...)`.
    lookbehind,
    /// Negative lookbehind assertion `(?<!...)`.
    negative_lookbehind,
    /// Numeric backreference like `\1`.
    backref_numeric,
    /// Named backreference like `\k<name>`.
    backref_named,
};

pub const CapSet = std.EnumSet(Capability);

/// Helper for generated corpus cases. It centralizes the comptime branch budget
/// needed to build many `CapSet` literals across large generated files.
pub fn requires(comptime init: std.enums.EnumFieldStruct(Capability, bool, false)) CapSet {
    @setEvalBranchQuota(50_000);
    return CapSet.init(init);
}

/// The entry for Capability x Backend matrix (the column).
pub const CapBackendMapEntry = std.enums.EnumFieldStruct(Backend, bool, null);

/// Capabilities intentionally omitted from generated `Case.requires`.
/// Backends that run corpus suites must support all of them.
pub const implicit_case_baseline = [_]Capability{
    .literal,
    .escaped_literal,
    .concat,
    .capture_group,
    .search_leftmost,
    .match_kind_leftmost_first,
    .api_is_match,
    .api_find,
    .api_captures,
};

pub fn assertCapBaseline(comptime backend: Backend) void {
    inline for (implicit_case_baseline) |cap| {
        if (!backend.supports(cap)) {
            @compileError(std.fmt.comptimePrint(
                "backend `{s}` must support case baseline capability `{s}`",
                .{ @tagName(backend), @tagName(cap) },
            ));
        }
    }
}

/// Single source-of-truth capability x backend matrix.
///
/// Each capability row must explicitly set support for every backend.
pub const cap_backend_map = std.EnumArray(Capability, CapBackendMapEntry).init(.{
    // zig fmt: off
    // Core syntax.
    .literal                        = .{ .pikevm = true,  .onepass = false, .dfa = false, .backtrack = false },
    .escaped_literal                = .{ .pikevm = true,  .onepass = false, .dfa = false, .backtrack = false },
    .dot                            = .{ .pikevm = true,  .onepass = false, .dfa = false, .backtrack = false },
    .concat                         = .{ .pikevm = true,  .onepass = false, .dfa = false, .backtrack = false },
    .alternation                    = .{ .pikevm = true,  .onepass = false, .dfa = false, .backtrack = false },

    // Groups and captures.
    .capture_group                  = .{ .pikevm = true,  .onepass = false, .dfa = false, .backtrack = false },
    .noncapture_group               = .{ .pikevm = false, .onepass = false, .dfa = false, .backtrack = false },
    .named_capture_group            = .{ .pikevm = false, .onepass = false, .dfa = false, .backtrack = false },

    // Repetition.
    .rep_zero_or_one                = .{ .pikevm = true,  .onepass = false, .dfa = false, .backtrack = false },
    .rep_zero_or_more               = .{ .pikevm = true,  .onepass = false, .dfa = false, .backtrack = false },
    .rep_one_or_more                = .{ .pikevm = true,  .onepass = false, .dfa = false, .backtrack = false },
    .rep_exact                      = .{ .pikevm = true,  .onepass = false, .dfa = false, .backtrack = false },
    .rep_min                        = .{ .pikevm = true,  .onepass = false, .dfa = false, .backtrack = false },
    .rep_range                      = .{ .pikevm = true,  .onepass = false, .dfa = false, .backtrack = false },
    .rep_lazy                       = .{ .pikevm = true,  .onepass = false, .dfa = false, .backtrack = false },
    .rep_possessive                 = .{ .pikevm = false, .onepass = false, .dfa = false, .backtrack = false }, // not supported

    // Character classes.
    .class_simple                   = .{ .pikevm = true,  .onepass = false, .dfa = false, .backtrack = false },
    .class_range                    = .{ .pikevm = true,  .onepass = false, .dfa = false, .backtrack = false },
    .class_negated                  = .{ .pikevm = true,  .onepass = false, .dfa = false, .backtrack = false },
    .class_posix                    = .{ .pikevm = true,  .onepass = false, .dfa = false, .backtrack = false },
    .class_perl                     = .{ .pikevm = true,  .onepass = false, .dfa = false, .backtrack = false },
    .class_unicode_property         = .{ .pikevm = false, .onepass = false, .dfa = false, .backtrack = false },
    .class_unicode_script_or_block  = .{ .pikevm = false, .onepass = false, .dfa = false, .backtrack = false },

    // Assertions and boundaries.
    .anchor_line_start              = .{ .pikevm = true,  .onepass = false, .dfa = false, .backtrack = false },
    .anchor_line_end                = .{ .pikevm = true,  .onepass = false, .dfa = false, .backtrack = false },
    .anchor_text_start              = .{ .pikevm = true,  .onepass = false, .dfa = false, .backtrack = false },
    .anchor_text_end                = .{ .pikevm = true,  .onepass = false, .dfa = false, .backtrack = false },
    .word_boundary                  = .{ .pikevm = true,  .onepass = false, .dfa = false, .backtrack = false },
    .not_word_boundary              = .{ .pikevm = true,  .onepass = false, .dfa = false, .backtrack = false },
    .word_boundary_start            = .{ .pikevm = false, .onepass = false, .dfa = false, .backtrack = false },
    .word_boundary_end              = .{ .pikevm = false, .onepass = false, .dfa = false, .backtrack = false },
    .word_boundary_start_half       = .{ .pikevm = false, .onepass = false, .dfa = false, .backtrack = false },
    .word_boundary_end_half         = .{ .pikevm = false, .onepass = false, .dfa = false, .backtrack = false },

    // Escapes.
    .escape_c_style                 = .{ .pikevm = true,  .onepass = false, .dfa = false, .backtrack = false },
    .escape_hex_byte                = .{ .pikevm = true,  .onepass = false, .dfa = false, .backtrack = false },
    .escape_hex_braced              = .{ .pikevm = false, .onepass = false, .dfa = false, .backtrack = false },
    .escape_unicode_short           = .{ .pikevm = false, .onepass = false, .dfa = false, .backtrack = false },
    .escape_unicode_long            = .{ .pikevm = false, .onepass = false, .dfa = false, .backtrack = false },
    .escape_octal                   = .{ .pikevm = false, .onepass = false, .dfa = false, .backtrack = false },
    .escape_literal_mode            = .{ .pikevm = false, .onepass = false, .dfa = false, .backtrack = false },

    // Flags and parser modes.
    .ignore_case                    = .{ .pikevm = false, .onepass = false, .dfa = false, .backtrack = false },
    .multi_line                     = .{ .pikevm = false, .onepass = false, .dfa = false, .backtrack = false },
    .dot_matches_new_line           = .{ .pikevm = false, .onepass = false, .dfa = false, .backtrack = false },
    .swap_greed                     = .{ .pikevm = false, .onepass = false, .dfa = false, .backtrack = false },
    .crlf_mode                      = .{ .pikevm = false, .onepass = false, .dfa = false, .backtrack = false },
    .inline_flags_global            = .{ .pikevm = false, .onepass = false, .dfa = false, .backtrack = false },
    .inline_flags_scoped            = .{ .pikevm = false, .onepass = false, .dfa = false, .backtrack = false },
    .inline_flags_toggle            = .{ .pikevm = false, .onepass = false, .dfa = false, .backtrack = false },
    .unicode_mode                   = .{ .pikevm = false, .onepass = false, .dfa = false, .backtrack = false },
    .utf8_mode                      = .{ .pikevm = false, .onepass = false, .dfa = false, .backtrack = false },
    .line_terminator_override       = .{ .pikevm = false, .onepass = false, .dfa = false, .backtrack = false },

    // Search and match semantics.
    .search_leftmost                = .{ .pikevm = true,  .onepass = false, .dfa = false, .backtrack = false },
    .search_earliest                = .{ .pikevm = false, .onepass = false, .dfa = false, .backtrack = false },
    .search_overlapping             = .{ .pikevm = false, .onepass = false, .dfa = false, .backtrack = false },
    .match_kind_leftmost_first      = .{ .pikevm = true,  .onepass = false, .dfa = false, .backtrack = false },
    .match_kind_all                 = .{ .pikevm = false, .onepass = false, .dfa = false, .backtrack = false },
    .match_kind_leftmost_longest    = .{ .pikevm = false, .onepass = false, .dfa = false, .backtrack = false },
    .empty_match_no_split_codepoint = .{ .pikevm = false, .onepass = false, .dfa = false, .backtrack = false },

    // Input controls.
    .input_anchored                 = .{ .pikevm = true,  .onepass = false, .dfa = false, .backtrack = false },
    .input_bounds                   = .{ .pikevm = false, .onepass = false, .dfa = false, .backtrack = false },
    .input_bytes                    = .{ .pikevm = false, .onepass = false, .dfa = false, .backtrack = false },
    .input_utf8_text                = .{ .pikevm = false, .onepass = false, .dfa = false, .backtrack = false },

    // API surface.
    .api_is_match                   = .{ .pikevm = true,  .onepass = false, .dfa = false, .backtrack = false },
    .api_find                       = .{ .pikevm = true,  .onepass = false, .dfa = false, .backtrack = false },
    .api_captures                   = .{ .pikevm = true,  .onepass = false, .dfa = false, .backtrack = false },
    .api_find_iter                  = .{ .pikevm = false, .onepass = false, .dfa = false, .backtrack = false },
    .api_captures_iter              = .{ .pikevm = false, .onepass = false, .dfa = false, .backtrack = false },
    .api_pattern_set                = .{ .pikevm = false, .onepass = false, .dfa = false, .backtrack = false },
    .api_which                      = .{ .pikevm = false, .onepass = false, .dfa = false, .backtrack = false },

    // Harness directives.
    .case_unescape                  = .{ .pikevm = false, .onepass = false, .dfa = false, .backtrack = false },
    .case_match_limit               = .{ .pikevm = false, .onepass = false, .dfa = false, .backtrack = false },
    .case_compiles_true             = .{ .pikevm = true,  .onepass = false, .dfa = false, .backtrack = false },
    .case_compiles_false            = .{ .pikevm = false, .onepass = false, .dfa = false, .backtrack = false },

    // Explicitly unsupported/advanced syntax.
    .lookahead                      = .{ .pikevm = false, .onepass = false, .dfa = false, .backtrack = false },
    .negative_lookahead             = .{ .pikevm = false, .onepass = false, .dfa = false, .backtrack = false },
    .lookbehind                     = .{ .pikevm = false, .onepass = false, .dfa = false, .backtrack = false },
    .negative_lookbehind            = .{ .pikevm = false, .onepass = false, .dfa = false, .backtrack = false },
    .backref_numeric                = .{ .pikevm = false, .onepass = false, .dfa = false, .backtrack = false },
    .backref_named                  = .{ .pikevm = false, .onepass = false, .dfa = false, .backtrack = false },
    // zig fmt: on
});
