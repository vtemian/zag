//! Collector sink: captures the final assistant text for headless runs.
//!
//! Accumulates `assistant_delta` text, clears on `assistant_reset`, and
//! flips `done = true` on `run_end`. Every other event variant is dropped.
//! Intended for subagent task tools that need a concluding message string
//! without a UI-backed buffer.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Sink = @import("../Sink.zig").Sink;
const Event = @import("../Sink.zig").Event;

pub const Collector = struct {
    alloc: Allocator,
    final_text: std.ArrayList(u8) = .empty,
    done: bool = false,

    pub fn init(alloc: Allocator) Collector {
        return .{ .alloc = alloc };
    }

    pub fn sink(self: *Collector) Sink {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn deinit(self: *Collector) void {
        self.final_text.deinit(self.alloc);
    }

    fn push(ptr: *anyopaque, event: Event) void {
        const self: *Collector = @ptrCast(@alignCast(ptr));
        switch (event) {
            .assistant_delta => |e| {
                self.final_text.appendSlice(self.alloc, e.text) catch {};
            },
            .assistant_reset => self.final_text.clearRetainingCapacity(),
            .run_end => self.done = true,
            else => {},
        }
    }

    fn deinitVT(ptr: *anyopaque) void {
        const self: *Collector = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    const vtable: Sink.VTable = .{ .push = push, .deinit = deinitVT };
};

test "Collector accumulates deltas and flips done on run_end" {
    var c = Collector.init(std.testing.allocator);
    defer c.deinit();
    const s = c.sink();
    s.push(.{ .assistant_delta = .{ .text = "hello " } });
    s.push(.{ .assistant_delta = .{ .text = "world" } });
    try std.testing.expect(!c.done);
    s.push(.run_end);
    try std.testing.expect(c.done);
    try std.testing.expectEqualStrings("hello world", c.final_text.items);
}

test "Collector clears on assistant_reset" {
    var c = Collector.init(std.testing.allocator);
    defer c.deinit();
    const s = c.sink();
    s.push(.{ .assistant_delta = .{ .text = "wrong" } });
    s.push(.assistant_reset);
    s.push(.{ .assistant_delta = .{ .text = "right" } });
    s.push(.run_end);
    try std.testing.expectEqualStrings("right", c.final_text.items);
}
