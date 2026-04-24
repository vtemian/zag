//! Sink: runtime-polymorphic output channel for AgentRunner content events.
//!
//! Thread-safety invariant: Sink.push is called only from the main-thread
//! drain loop (AgentRunner.drainEvents). The worker thread enqueues
//! AgentEvents into the runner's event_queue; it never calls Sink.push
//! directly. All Sink implementations assume single-threaded access to
//! their internal state.

const std = @import("std");

pub const Event = union(enum) {
    run_start: struct { user_text: []const u8 },
    assistant_delta: struct { text: []const u8 },
    assistant_reset,
    tool_use: struct {
        name: []const u8,
        call_id: ?[]const u8 = null,
        input_raw: ?[]const u8 = null,
    },
    tool_result: struct {
        content: []const u8,
        is_error: bool = false,
        call_id: ?[]const u8 = null,
    },
    run_end,
    error_event: struct { text: []const u8 },
};

pub const Sink = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        push: *const fn (ptr: *anyopaque, event: Event) void,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn push(self: Sink, event: Event) void {
        self.vtable.push(self.ptr, event);
    }

    pub fn deinit(self: Sink) void {
        self.vtable.deinit(self.ptr);
    }
};

test "Sink dispatches through vtable" {
    const Counter = struct {
        count: usize = 0,
        fn push(ptr: *anyopaque, _: Event) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.count += 1;
        }
        fn deinit(_: *anyopaque) void {}
        const vt: Sink.VTable = .{ .push = push, .deinit = deinit };
    };
    var c: Counter = .{};
    const s = Sink{ .ptr = &c, .vtable = &Counter.vt };
    s.push(.run_end);
    s.push(.{ .assistant_delta = .{ .text = "hi" } });
    try std.testing.expectEqual(@as(usize, 2), c.count);
}
