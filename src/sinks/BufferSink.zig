//! BufferSink: the UI-backed Sink implementation.
//!
//! Wraps a borrowed `*ConversationBuffer` and owns the node-correlation
//! state that used to live on `AgentRunner`: the in-progress assistant
//! node, the `call_id -> *Node` map for tool results, and the
//! last-seen tool_call fallback. Moving this state into the sink
//! removes the dangling-*Node hazard on pane / provider swaps, because
//! the runner no longer holds buffer-relative node pointers.
//!
//! Thread-safety invariant (inherited from Sink.zig): `push` is only
//! called from the main-thread drain loop in `AgentRunner.drainEvents`.
//! Internal state is touched from that one thread and needs no locking.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ConversationBuffer = @import("../ConversationBuffer.zig");
const Node = ConversationBuffer.Node;
const Sink = @import("../Sink.zig").Sink;
const Event = @import("../Sink.zig").Event;

pub const BufferSink = struct {
    /// Allocator for the `pending_tool_calls` map keys (duped call_ids).
    alloc: Allocator,
    /// Borrowed pointer to the ConversationBuffer this sink writes into.
    /// The pane that owns both is responsible for destroying the buffer
    /// only after this sink has been deinited.
    buffer: *ConversationBuffer,
    /// The assistant node currently accumulating streaming deltas, or
    /// null between turns / after an `assistant_reset`.
    current_assistant_node: ?*Node = null,
    /// call_id -> tool_call node. Populated on `tool_use`, drained on
    /// `tool_result`. Keys are owned (duped on insert, freed on remove).
    pending_tool_calls: std.StringHashMapUnmanaged(*Node) = .{},
    /// Fallback parent for tool_result events that arrive without a
    /// call_id (some providers emit unkeyed results). Always the most
    /// recent tool_call node seen this turn.
    last_tool_call: ?*Node = null,

    pub fn init(alloc: Allocator, buffer: *ConversationBuffer) BufferSink {
        return .{ .alloc = alloc, .buffer = buffer };
    }

    pub fn sink(self: *BufferSink) Sink {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn deinit(self: *BufferSink) void {
        var it = self.pending_tool_calls.iterator();
        while (it.next()) |entry| self.alloc.free(entry.key_ptr.*);
        self.pending_tool_calls.deinit(self.alloc);
    }

    fn push(ptr: *anyopaque, event: Event) void {
        const self: *BufferSink = @ptrCast(@alignCast(ptr));
        switch (event) {
            .run_start => |e| {
                _ = self.buffer.appendUserNode(e.user_text) catch return;
                self.current_assistant_node = null;
                self.last_tool_call = null;
            },
            .assistant_delta => |e| {
                if (self.current_assistant_node) |node| {
                    self.buffer.appendToNode(node, e.text) catch return;
                } else {
                    const node = self.buffer.appendNode(null, .assistant_text, e.text) catch return;
                    self.current_assistant_node = node;
                }
            },
            .assistant_reset => {
                if (self.current_assistant_node) |node| {
                    self.buffer.tree.removeNode(node);
                    self.current_assistant_node = null;
                }
            },
            .tool_use => |e| {
                const node = self.buffer.appendNode(null, .tool_call, e.name) catch return;
                self.last_tool_call = node;
                if (e.call_id) |id| {
                    const owned = self.alloc.dupe(u8, id) catch return;
                    self.pending_tool_calls.put(self.alloc, owned, node) catch {
                        self.alloc.free(owned);
                    };
                }
            },
            .tool_result => |e| {
                const parent = blk: {
                    if (e.call_id) |id| {
                        if (self.pending_tool_calls.fetchRemove(id)) |kv| {
                            self.alloc.free(kv.key);
                            break :blk kv.value;
                        }
                    }
                    break :blk self.last_tool_call;
                } orelse return;
                _ = self.buffer.appendNode(parent, .tool_result, e.content) catch return;
            },
            .run_end => {
                self.current_assistant_node = null;
            },
            .error_event => |e| {
                _ = self.buffer.appendNode(null, .err, e.text) catch return;
            },
        }
    }

    fn deinitVT(ptr: *anyopaque) void {
        const self: *BufferSink = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    const vtable: Sink.VTable = .{ .push = push, .deinit = deinitVT };
};

test "BufferSink run_start appends a user node" {
    var cb = try ConversationBuffer.init(std.testing.allocator, 0, "test");
    defer cb.deinit();

    var bs = BufferSink.init(std.testing.allocator, &cb);
    defer bs.deinit();
    const s = bs.sink();

    s.push(.{ .run_start = .{ .user_text = "hello" } });

    try std.testing.expectEqual(@as(usize, 1), cb.tree.root_children.items.len);
    const node = cb.tree.root_children.items[0];
    try std.testing.expectEqual(ConversationBuffer.NodeType.user_message, node.node_type);
    try std.testing.expectEqualStrings("hello", node.content.items);
}

test "BufferSink assistant_delta creates then extends" {
    var cb = try ConversationBuffer.init(std.testing.allocator, 0, "test");
    defer cb.deinit();

    var bs = BufferSink.init(std.testing.allocator, &cb);
    defer bs.deinit();
    const s = bs.sink();

    s.push(.{ .assistant_delta = .{ .text = "hel" } });
    s.push(.{ .assistant_delta = .{ .text = "lo" } });

    try std.testing.expectEqual(@as(usize, 1), cb.tree.root_children.items.len);
    const node = cb.tree.root_children.items[0];
    try std.testing.expectEqual(ConversationBuffer.NodeType.assistant_text, node.node_type);
    try std.testing.expectEqualStrings("hello", node.content.items);
    try std.testing.expect(bs.current_assistant_node != null);
}

test "BufferSink assistant_reset removes the in-progress node" {
    var cb = try ConversationBuffer.init(std.testing.allocator, 0, "test");
    defer cb.deinit();

    var bs = BufferSink.init(std.testing.allocator, &cb);
    defer bs.deinit();
    const s = bs.sink();

    s.push(.{ .assistant_delta = .{ .text = "wrong" } });
    try std.testing.expectEqual(@as(usize, 1), cb.tree.root_children.items.len);

    s.push(.assistant_reset);
    try std.testing.expectEqual(@as(usize, 0), cb.tree.root_children.items.len);
    try std.testing.expect(bs.current_assistant_node == null);
}

test "BufferSink tool_result correlates via call_id" {
    var cb = try ConversationBuffer.init(std.testing.allocator, 0, "test");
    defer cb.deinit();

    var bs = BufferSink.init(std.testing.allocator, &cb);
    defer bs.deinit();
    const s = bs.sink();

    s.push(.{ .tool_use = .{ .name = "read", .call_id = "id-a" } });
    s.push(.{ .tool_use = .{ .name = "bash", .call_id = "id-b" } });
    // Resolve the older call first; correlation must pick the right parent.
    s.push(.{ .tool_result = .{ .content = "result-a", .call_id = "id-a" } });

    try std.testing.expectEqual(@as(usize, 2), cb.tree.root_children.items.len);
    const first_tool = cb.tree.root_children.items[0];
    const second_tool = cb.tree.root_children.items[1];
    try std.testing.expectEqualStrings("read", first_tool.content.items);
    try std.testing.expectEqualStrings("bash", second_tool.content.items);

    try std.testing.expectEqual(@as(usize, 1), first_tool.children.items.len);
    try std.testing.expectEqual(@as(usize, 0), second_tool.children.items.len);
    try std.testing.expectEqualStrings("result-a", first_tool.children.items[0].content.items);

    // "id-a" should have been removed from the pending map; "id-b" still in flight.
    try std.testing.expectEqual(@as(u32, 1), bs.pending_tool_calls.count());
    try std.testing.expect(bs.pending_tool_calls.get("id-b") != null);
}

test "BufferSink tool_result falls back to last_tool_call without call_id" {
    var cb = try ConversationBuffer.init(std.testing.allocator, 0, "test");
    defer cb.deinit();

    var bs = BufferSink.init(std.testing.allocator, &cb);
    defer bs.deinit();
    const s = bs.sink();

    s.push(.{ .tool_use = .{ .name = "read" } }); // no call_id
    s.push(.{ .tool_result = .{ .content = "result" } });

    try std.testing.expectEqual(@as(usize, 1), cb.tree.root_children.items.len);
    const tool = cb.tree.root_children.items[0];
    try std.testing.expectEqual(@as(usize, 1), tool.children.items.len);
    try std.testing.expectEqualStrings("result", tool.children.items[0].content.items);
}

test "BufferSink error_event appends an err node" {
    var cb = try ConversationBuffer.init(std.testing.allocator, 0, "test");
    defer cb.deinit();

    var bs = BufferSink.init(std.testing.allocator, &cb);
    defer bs.deinit();
    const s = bs.sink();

    s.push(.{ .error_event = .{ .text = "boom" } });

    try std.testing.expectEqual(@as(usize, 1), cb.tree.root_children.items.len);
    const node = cb.tree.root_children.items[0];
    try std.testing.expectEqual(ConversationBuffer.NodeType.err, node.node_type);
    try std.testing.expectEqualStrings("boom", node.content.items);
}
