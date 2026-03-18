//! Bridge module to expose regex internals to tests in integration/corpus harness.

pub const Regex = @import("Regex.zig");
pub const Compiler = @import("syntax/Compiler.zig");
pub const Program = @import("syntax/Program.zig");
pub const PikeVm = @import("engine/PikeVm.zig");

const errors = @import("errors.zig");
pub const Diagnostics = errors.Diagnostics;
pub const Span = errors.Span;
