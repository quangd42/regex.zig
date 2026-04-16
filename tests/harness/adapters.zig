pub const Backend = enum {
    pikevm,
    onepass,
    dfa,
    backtrack,

    pub fn supports(comptime self: Backend, cap: Capability) bool {
        const row = cap_backend_map.get(cap);
        return @field(row, @tagName(self));
    }

    pub fn capabilities(comptime self: Backend) CapSet {
        return comptime blk: {
            var set = CapSet.initEmpty();
            for (std.meta.fields(Capability)) |field| {
                const cap: Capability = @enumFromInt(field.value);
                if (self.supports(cap)) set.insert(cap);
            }
            break :blk set;
        };
    }

    pub fn Engine(comptime self: Backend) type {
        const engine_type = switch (self) {
            .pikevm => PikeVm,
            else => @panic("not yet implemented"),
        };
        comptime assertBackendType(engine_type);
        return engine_type;
    }
};

fn assertBackendType(comptime T: type) void {
    if (!@hasField(T, "prog")) @compileError("backend type must expose `prog` for trace dumps");
    if (@FieldType(T, "prog") != Program) @compileError("backend `prog` field must be Program");

    assertFnShape(
        T,
        "init",
        &.{ Allocator, Program },
        anyerror!T,
        "fn (Allocator, Program) !Backend",
    );
    assertFnShape(
        T,
        "deinit",
        &.{*T},
        void,
        "fn (*Backend) void",
    );
    assertFnShape(
        T,
        "match",
        &.{ *T, Input },
        bool,
        "fn (*Backend, Input) bool",
    );
    assertFnShape(
        T,
        "find",
        &.{ *T, Input },
        ?Regex.Match,
        "fn (*Backend, Input) ?Match",
    );
    assertFnShape(
        T,
        "findCaptures",
        &.{ *T, Input },
        ?Regex.Captures,
        "fn (*Backend, Input) ?Captures",
    );
}

fn assertFnShape(
    comptime T: type,
    comptime fn_name: []const u8,
    comptime param_types: []const type,
    comptime expected_return_type: type,
    comptime signature: []const u8,
) void {
    const message = std.fmt.comptimePrint("{s} must be defined with signature `{s}`", .{ fn_name, signature });
    const is_method = param_types.len > 0 and param_types[0] == *T;
    const has_decl = if (is_method) std.meta.hasMethod(T, fn_name) else std.meta.hasFn(T, fn_name);
    if (!has_decl) @compileError(message);

    const fn_type = @TypeOf(@field(T, fn_name));
    const fn_info = @typeInfo(fn_type).@"fn";
    if (fn_info.params.len != param_types.len) @compileError(message);
    inline for (param_types, fn_info.params) |expected, actual_param| {
        if (actual_param.type != expected) @compileError(message);
    }

    const return_type = fn_info.return_type orelse @compileError(message);
    const expected_return_info = @typeInfo(expected_return_type);
    switch (expected_return_info) {
        .error_union => |expected| {
            const return_info = @typeInfo(return_type);
            if (return_info != .error_union) @compileError(message);
            if (return_info.error_union.payload != expected.payload) @compileError(message);
        },
        else => {
            if (return_type != expected_return_type) @compileError(message);
        },
    }
}

const std = @import("std");
const Allocator = std.mem.Allocator;

const export_test = @import("export_test");
const Regex = export_test.Regex;
const PikeVm = export_test.PikeVm;
const Program = export_test.Program;
const Input = export_test.Input;

const caps = @import("capabilities.zig");
const Capability = caps.Capability;
const CapSet = caps.CapSet;
const cap_backend_map = caps.cap_backend_map;
