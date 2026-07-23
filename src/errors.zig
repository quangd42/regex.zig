pub const Span = @import("types.zig").Span;

pub const Diagnostics = union(enum) {
    parse: Parse,
    compile: Compile,

    /// Parser errors surfaced to callers.
    pub const ParseError = enum {
        class_ascii_invalid,
        class_not_closed,
        class_range_invalid,
        escape_at_eof,
        escape_hex_brace_not_closed,
        escape_hex_digit_invalid,
        escape_hex_value_invalid,
        escape_invalid,
        flag_disable_op_dangling,
        flag_disable_op_duplicated,
        flag_duplicated,
        flag_unsupported,
        group_close_unexpected,
        group_name_duplicated,
        group_name_invalid,
        group_name_not_closed,
        group_not_closed,
        utf8_codepoint_invalid,
        repeat_argument_missing, // '*', '+', '?' as first item in pattern
        repeat_count_empty,
        repeat_count_format_invalid,
        repeat_count_not_closed,
        repeat_size_invalid,
        unsupported_feature,
    };

    pub const Parse = struct {
        err: ParseError,
        /// Byte offsets into the regex pattern.
        span: Span,
        /// Additional byte offsets into the regex pattern, when relevant.
        aux_span: ?Span = null,
    };

    pub const Compile = union(enum) {
        too_many_states: struct { limit: usize, count: usize },
        invalid_state_limit: usize,
        program_too_large,
        too_many_patterns,
        unsupported_feature,
        // TODO: report the source span once compile diagnostics carry spans.
        unicode_in_byte_mode,
    };

    pub fn fromParse(err: ParseError, span: Span, aux_span: ?Span) Diagnostics {
        return .{ .parse = .{
            .err = err,
            .span = span,
            .aux_span = aux_span,
        } };
    }
};
