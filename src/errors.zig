pub const Diagnostics = union(enum) {
    parse: Parse,
    compile: Compile,

    /// Parser errors surfaced to callers.
    pub const ParseError = enum {
        invalid_escape,
        escape_at_eof,
        class_not_closed,
        invalid_class_range,
        invalid_ascii_class,
        unexpected_group_close,
        group_not_closed,
        repeat_count_not_closed,
        missing_repeat_argument, // '*', '+', '?' as first item in pattern
        repeat_count_empty,
        invalid_repeat_size,
        invalid_repeat_count_format,
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
