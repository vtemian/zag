//! Sink: runtime-polymorphic output channel for AgentRunner content events.
//!
//! Thread-safety contract: Sink implementations assume single-threaded
//! access. The owner of each Sink guarantees no concurrent push. Each
//! impl documents which thread it expects in its own module doc.

const std = @import("std");

pub const Event = union(enum) {
    run_start: struct { user_text: []const u8 },
    assistant_delta: struct { text: []const u8 },
    assistant_reset,
    /// Extended-thinking text delta. Sink implementations render the
    /// reasoning block alongside the assistant turn; those that don't
    /// care about reasoning (Collector, Null) drop these.
    thinking_delta: struct { text: []const u8 },
    /// End of an extended-thinking block. Sinks fold the live thinking
    /// node so a later delta opens a fresh one instead of mis-appending.
    thinking_stop,
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
    /// Streaming progress text from an in-flight compaction summary.
    /// Distinct from assistant_delta because compaction work is NOT
    /// the model's actual reply — sinks should render this as
    /// transient progress (dim, italic, side panel) so the user sees
    /// the agent is doing maintenance without confusing it for a
    /// turn. Sinks that don't care (Collector, Null) drop these.
    compaction_summary_delta: struct { text: []const u8 },
    /// One-shot structured event emitted at the end of a compaction
    /// cycle. Outcome string is one of: "replace", "cancel",
    /// "summarized", "drop_oldest", "refused". Sinks can clear any
    /// transient "compacting..." indicator here and surface a brief
    /// "compacted N → M (outcome)" status.
    compaction_event: struct {
        outcome: []const u8,
        messages_before: u32,
        messages_after: u32,
        estimate_tokens: u32 = 0,
        error_name: ?[]const u8 = null,
    },
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
