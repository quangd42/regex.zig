//! Entrypoint for integration and corpus suites wired by `build.zig`.
test {
    _ = @import("api_integration.zig");
    _ = @import("fowler/main.zig");
}
