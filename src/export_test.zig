//! Bridge module to expose regex internals to tests in integration/corpus harness.

pub const Regex = @import("Regex.zig");
pub const Compiler = @import("Compiler.zig");
pub const Program = @import("Program.zig");
pub const iterator = @import("iterator.zig");
pub const PikeVm = @import("Engine/PikeVm.zig");

const errors = @import("errors.zig");
pub const Diagnostics = errors.Diagnostics;
pub const Span = errors.Span;
