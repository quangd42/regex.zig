pub const Diagnostics = union(enum) {
    parse: Parse,
    compile: Compile,

    /// Parser errors surfaced to callers.
    pub const ParseError = enum {
        escape_invalid,
        escape_at_eof,
        class_not_closed,
        class_range_invalid,
        class_ascii_invalid,
        group_close_unexpected,
        group_not_closed,
        flag_duplicated,
        flag_disable_op_duplicated,
        flag_disable_op_dangling,
        flag_unsupported,
        repeat_count_not_closed,
        repeat_argument_missing, // '*', '+', '?' as first item in pattern
        repeat_count_empty,
        repeat_size_invalid,
        repeat_count_format_invalid,
        unsupported_feature,
    };

    pub const Parse = struct {
        err: ParseError,
        span: Span,
        aux_span: ?Span = null,
    };

    pub const Compile = union(enum) {
        too_many_states: struct { limit: usize, count: usize },
        invalid_state_limit: usize,
        program_too_large: void,
        too_many_patterns: void,
        unsupported_feature: void,
    };

    pub fn fromParse(err: ParseError, span: Span, aux_span: ?Span) Diagnostics {
        return .{ .parse = .{
            .err = err,
            .span = span,
            .aux_span = aux_span,
        } };
    }
};

/// Byte offsets into pattern slice.
pub const Span = struct {
    start: usize,
    end: usize, // exclusive

    pub fn isValidFor(self: Span, input_len: usize) bool {
        return self.start <= self.end and self.end <= input_len;
    }
};
