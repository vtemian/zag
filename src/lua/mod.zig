//! Lua async plugin runtime module root. Re-exports nothing yet; exists so
//! subsystem tests are reachable from the project-wide test target.

pub const Scope = @import("Scope.zig").Scope;
pub const CompletionQueue = @import("LuaCompletionQueue.zig").Queue;

test {
    _ = @import("spike_test.zig");
    _ = @import("Scope.zig");
    _ = @import("Job.zig");
    _ = @import("LuaCompletionQueue.zig");
}
