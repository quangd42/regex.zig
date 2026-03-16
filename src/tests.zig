//! Entrypoint for integration and corpus suites wired by `build.zig`.
test {
    _ = @import("tests/suites/api_integration.zig");
    _ = @import("tests/suites/fowler_basic.zig");
}
