//! Bridge module to expose regex internals to tests in integration/corpus harness.

pub const Regex = @import("Regex.zig");
pub const Compiler = @import("Compiler.zig");
pub const Program = @import("Program.zig");
pub const PikeVm = @import("engine.zig").PikeVm;

const errors = @import("errors.zig");
pub const Diagnostics = errors.Diagnostics;
pub const Span = errors.Span;
