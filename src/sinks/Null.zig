//! Null sink: drops every event.
//!
//! Used as a placeholder in AgentRunner tests that do not need to observe
//! output, and during teardown paths where the prior Sink is being replaced.

const Sink = @import("../Sink.zig").Sink;
const Event = @import("../Sink.zig").Event;

pub const Null = struct {
    pub fn sink(self: *Null) Sink {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn push(_: *anyopaque, _: Event) void {}
    fn deinit(_: *anyopaque) void {}

    const vtable: Sink.VTable = .{ .push = push, .deinit = deinit };
};

test "Null sink accepts events without panic" {
    var n: Null = .{};
    const s = n.sink();
    s.push(.{ .run_start = .{ .user_text = "hi" } });
    s.push(.run_end);
    s.deinit();
}
