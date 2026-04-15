//! Bridge module to expose regex internals to tests in integration/corpus harness.

pub const Regex = @import("Regex.zig");
pub const Compiler = @import("Compiler.zig");
pub const Program = @import("Program.zig");
pub const PikeVm = @import("engine.zig").PikeVm;

// Temporarily exposing it to test harness, so the harness can make use of
// test corpus cap `anchored`.
pub const Input = @import("engine/Input.zig");

const errors = @import("errors.zig");
pub const Diagnostics = errors.Diagnostics;
pub const Span = errors.Span;
