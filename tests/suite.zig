//! Entrypoint for suite-backed tests wired by `build.zig`.

// Use a comptime import block so Zig registers the imported tests directly
// without adding a synthetic wrapper test at the root.
comptime {
    _ = @import("fowler/basic.zig");
    _ = @import("fowler/repetition.zig");
    _ = @import("fowler/nullsubexpr.zig");
    _ = @import("generated/flags.zig");
    _ = @import("generated/multiline.zig");
    _ = @import("generated/flags-local.zig");
    _ = @import("generated/flags-local-captures.zig");
}
