//! Lua async plugin runtime module root. Re-exports nothing yet; exists so
//! subsystem tests are reachable from the project-wide test target.

test {
    _ = @import("spike_test.zig");
}
