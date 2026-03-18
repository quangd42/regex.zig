//! Public prelude for integration/corpus test harness components.

pub const Config = @import("harness/Config.zig");
pub const runner = @import("harness/runner.zig");
pub const adapters = @import("harness/adapters.zig");
pub const capabilities = @import("harness/capabilities.zig");

pub const Backend = adapters.Backend;
pub const Case = runner.Case;
pub const Result = runner.Result;
pub const RunOptions = runner.RunOptions;

pub const Capability = capabilities.Capability;
pub const CapSet = capabilities.CapSet;
