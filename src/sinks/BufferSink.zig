//! BufferSink: the UI-backed Sink implementation.
//!
//! BufferSink owns the call_id correlation map and current_assistant_node
//! so AgentRunner stays free of node-pointer state. It wraps a borrowed
//! `*Conversation` and tracks the in-progress assistant node, the
//! `call_id -> *Node` map for tool results, and the last-seen tool_call
//! fallback. Keeping this state inside the sink removes the dangling-*Node
//! hazard on pane / provider swaps, because the runner does not hold
//! buffer-relative node pointers.
//!
//! Thread-safety: single-threaded; the owner guarantees no concurrent
//! push. The owner is the pane's main-thread drain loop: pushes happen
//! only from `AgentRunner.handleAgentEvent` running on the main thread.
//! Internal state is touched from that one thread and needs no locking.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Conversation = @import("../Conversation.zig");
const ConversationTree = @import("../ConversationTree.zig");
const Node = Conversation.Node;
const Sink = @import("../Sink.zig").Sink;
const Event = @import("../Sink.zig").Event;

pub const BufferSink = struct {
    /// Allocator for the `pending_tool_calls` map keys (duped call_ids).
    alloc: Allocator,
    /// Borrowed pointer to the Conversation this sink writes into.
    /// The pane that owns both is responsible for destroying the buffer
    /// only after this sink has been deinited.
    buffer: *Conversation,
    /// The assistant node currently accumulating streaming deltas, or
    /// null between turns / after an `assistant_reset`.
    current_assistant_node: ?*Node = null,
    /// Most recent assistant_text node for this run, kept ALIVE across
    /// the `.assistant_delta` -> `.thinking_delta` boundary. Lets the
    /// post-response thinking-delta path parent a new thinking node
    /// under the assistant instead of appending an orphan at root.
    /// Cleared on `.run_end` and the next `.run_start` so it never
    /// crosses turns. See Issue 4 in
    /// docs/plans/2026-05-28-conversation-layout-fixes.md.
    last_assistant_node: ?*Node = null,
    /// call_id -> tool_call node. Populated on `tool_use`, drained on
    /// `tool_result`. Keys are owned (duped on insert, freed on remove).
    pending_tool_calls: std.StringHashMapUnmanaged(*Node) = .{},
    /// Fallback parent for tool_result events that arrive without a
    /// call_id (some providers emit unkeyed results). Always the most
    /// recent tool_call node seen this turn.
    last_tool_call: ?*Node = null,
    /// Live extended-thinking node. Lives across consecutive
    /// `.thinking_delta` events and closes on `.thinking_stop` or any
    /// content boundary (assistant_delta, tool_use, error, run_end)
    /// so a missed thinking_stop can't mis-parent later events.
    current_thinking_node: ?*Node = null,

    pub fn init(alloc: Allocator, buffer: *Conversation) BufferSink {
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

    /// Drop every cross-event correlation: the live assistant/thinking
    /// nodes, the in-flight tool_call -> *Node map, and the
    /// last-tool fallback. Frees the duped keys but keeps the map's
    /// buckets so the next turn reuses the same allocation.
    ///
    /// Called from `.run_end` (every turn) and from
    /// `WindowManager.swapProviderOnPanePtr` after the runner has been
    /// shut down (every model swap), so cancelled-mid-turn tool calls
    /// don't leave orphan entries that outlive the pane.
    pub fn resetCorrelation(self: *BufferSink) void {
        self.current_assistant_node = null;
        self.current_thinking_node = null;
        self.last_assistant_node = null;
        var it = self.pending_tool_calls.iterator();
        while (it.next()) |entry| self.alloc.free(entry.key_ptr.*);
        self.pending_tool_calls.clearRetainingCapacity();
        self.last_tool_call = null;
    }

    fn push(ptr: *anyopaque, event: Event) void {
        const self: *BufferSink = @ptrCast(@alignCast(ptr));
        switch (event) {
            .run_start => |e| {
                self.buffer.clearStatusNodes();
                _ = self.buffer.appendUserNode(e.user_text) catch return;
                self.current_assistant_node = null;
                self.current_thinking_node = null;
                self.last_assistant_node = null;
                self.last_tool_call = null;
            },
            .assistant_delta => |e| {
                // The first visible assistant token closes any open
                // thinking block; leaving it live would let the next
                // thinking_delta (new turn) fall into stale reasoning.
                self.current_thinking_node = null;
                if (self.current_assistant_node) |node| {
                    self.buffer.appendToNode(node, e.text) catch return;
                } else {
                    const node = self.buffer.appendNode(null, .assistant_text, e.text) catch return;
                    self.current_assistant_node = node;
                }
                // Survives past the next .thinking_delta so a post-response
                // extended-thinking block parents under the assistant_text
                // instead of appearing as an orphan root-level sibling.
                self.last_assistant_node = self.current_assistant_node;
            },
            .assistant_reset => {
                if (self.current_assistant_node) |node| {
                    self.buffer.tree.removeNode(node);
                    self.current_assistant_node = null;
                }
            },
            .thinking_delta => |e| {
                if (self.current_thinking_node) |node| {
                    self.buffer.appendToNode(node, e.text) catch return;
                } else {
                    // Parent under the most recent assistant_text if one exists
                    // for this run: extended-thinking events that arrive AFTER
                    // assistant_delta belong inside the response, not between
                    // turns. With no assistant yet (pre-response thinking),
                    // parent at root as before.
                    const parent = self.last_assistant_node;
                    const node = self.buffer.appendNode(parent, .thinking, e.text) catch return;
                    // Collapsed even during streaming: the user opts into reasoning content with Ctrl-R.
                    node.collapsed = true;
                    self.current_thinking_node = node;
                }
            },
            .thinking_stop => {
                if (self.current_thinking_node) |node| {
                    node.collapsed = true;
                    node.markDirty();
                    self.buffer.tree.generation +%= 1;
                    self.buffer.tree.dirty_nodes.push(node.id);
                }
                self.current_thinking_node = null;
            },
            .tool_use => |e| {
                // Boundary: close any live assistant/thinking node before
                // opening a tool call, otherwise later deltas mis-parent.
                // Tool invocation ends the surrounding assistant context: a
                // subsequent thinking_delta belongs at root (pre-next-text
                // reasoning), not nested under the now-stale assistant_text.
                self.current_assistant_node = null;
                self.current_thinking_node = null;
                self.last_assistant_node = null;
                // Pair the live provider id onto the node itself (Kimi's
                // `<name>:<index>`, Anthropic's `toolu_*`, ...). The wire
                // projection reads it back through `Conversation.projectNode`
                // so the next-turn request echoes the model's original ids
                // verbatim, keeping the live and projected paths consistent.
                // `input_raw` (raw JSON arguments) is carried alongside so
                // the renderer can surface the actual edit/command/path
                // inline instead of the generic `[tool] <name>` header.
                const node = self.buffer.appendToolCallNode(null, e.name, e.call_id, e.input_raw) catch return;
                node.collapsed = true;
                self.last_tool_call = node;
                if (e.call_id) |id| {
                    const gop = self.pending_tool_calls.getOrPut(self.alloc, id) catch return;
                    if (gop.found_existing) {
                        // Duplicate call_id from the LLM. Keep the original key
                        // (the map already owns it) and overwrite the value with
                        // the new node. No dupe happened, so nothing to free.
                        gop.value_ptr.* = node;
                    } else {
                        // First sighting; getOrPut inserted a key pointing at the
                        // event-owned `id` slice, which becomes invalid after this
                        // handler returns. Replace it with a duped copy we own.
                        const owned = self.alloc.dupe(u8, id) catch {
                            // Roll back so the dangling key isn't observed.
                            _ = self.pending_tool_calls.remove(id);
                            return;
                        };
                        gop.key_ptr.* = owned;
                        gop.value_ptr.* = node;
                    }
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
                const result_node = self.buffer.appendNode(parent, .tool_result, e.content) catch return;
                result_node.tool_result_is_error = e.is_error;
                // Bump the parent so the cached one-line tool_call rendering
                // refreshes into the collapsed-with-hint two-line rendering
                // now that a non-empty tool_result child exists.
                parent.markDirty();
                self.buffer.tree.generation +%= 1;
                self.buffer.tree.dirty_nodes.push(parent.id);
            },
            .run_end => {
                // Clear the full correlation state, not just the live
                // assistant/thinking nodes. A turn cancelled mid-tool
                // leaves entries in `pending_tool_calls` that no
                // tool_result will ever drain; without this they sit
                // around until pane teardown.
                self.resetCorrelation();
            },
            .error_event => |e| {
                self.current_thinking_node = null;
                _ = self.buffer.appendNode(null, .err, e.text) catch return;
            },
            .compaction_summary_delta, .compaction_event => {
                // Surfaced to the AgentRunner sink as part of the
                // compaction telemetry plumbing. BufferSink doesn't
                // render these today — visual choice (transient
                // status line, dim text in a footer, side panel) is
                // pending; the event surface is observable so the UI
                // layer can subscribe without a churn round-trip.
                // Sinks that DO render (TUI status bar) can hook in
                // by switching on these variants.
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
    var cb = try Conversation.init(std.testing.allocator, 0, "test");
    defer cb.deinit();

    var bs = BufferSink.init(std.testing.allocator, &cb);
    defer bs.deinit();
    const s = bs.sink();

    s.push(.{ .run_start = .{ .user_text = "hello" } });

    try std.testing.expectEqual(@as(usize, 1), cb.tree.root_children.items.len);
    const node = cb.tree.root_children.items[0];
    try std.testing.expectEqual(Conversation.NodeType.user_message, node.node_type);
    const tb = try cb.buffer_registry.asText(node.buffer_id.?);
    try std.testing.expectEqualStrings("hello", tb.bytesView());
}

test "BufferSink run_start clears welcome status nodes" {
    var cb = try Conversation.init(std.testing.allocator, 0, "test");
    defer cb.deinit();

    // Simulate welcome banner posted at startup
    _ = try cb.appendNode(null, .status, "Welcome to zag");
    _ = try cb.appendNode(null, .status, "model: test");
    try std.testing.expectEqual(@as(usize, 2), cb.tree.root_children.items.len);

    var bs = BufferSink.init(std.testing.allocator, &cb);
    defer bs.deinit();
    const s = bs.sink();

    s.push(.{ .run_start = .{ .user_text = "hello" } });

    try std.testing.expectEqual(@as(usize, 1), cb.tree.root_children.items.len);
    const node = cb.tree.root_children.items[0];
    try std.testing.expectEqual(Conversation.NodeType.user_message, node.node_type);
    const tb = try cb.buffer_registry.asText(node.buffer_id.?);
    try std.testing.expectEqualStrings("hello", tb.bytesView());
}

test "BufferSink assistant_delta creates then extends" {
    var cb = try Conversation.init(std.testing.allocator, 0, "test");
    defer cb.deinit();

    var bs = BufferSink.init(std.testing.allocator, &cb);
    defer bs.deinit();
    const s = bs.sink();

    s.push(.{ .assistant_delta = .{ .text = "hel" } });
    s.push(.{ .assistant_delta = .{ .text = "lo" } });

    try std.testing.expectEqual(@as(usize, 1), cb.tree.root_children.items.len);
    const node = cb.tree.root_children.items[0];
    try std.testing.expectEqual(Conversation.NodeType.assistant_text, node.node_type);
    const tb = try cb.buffer_registry.asText(node.buffer_id.?);
    try std.testing.expectEqualStrings("hello", tb.bytesView());
    try std.testing.expect(bs.current_assistant_node != null);
}

test "BufferSink assistant_reset removes the in-progress node" {
    var cb = try Conversation.init(std.testing.allocator, 0, "test");
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
    var cb = try Conversation.init(std.testing.allocator, 0, "test");
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
    // tool_call carries its tool name on `custom_tag` (see Conversation.appendNode).
    try std.testing.expectEqualStrings("read", first_tool.custom_tag.?);
    try std.testing.expectEqualStrings("bash", second_tool.custom_tag.?);

    try std.testing.expectEqual(@as(usize, 1), first_tool.children.items.len);
    try std.testing.expectEqual(@as(usize, 0), second_tool.children.items.len);
    const result_tb = try cb.buffer_registry.asText(first_tool.children.items[0].buffer_id.?);
    try std.testing.expectEqualStrings("result-a", result_tb.bytesView());

    // "id-a" should have been removed from the pending map; "id-b" still in flight.
    try std.testing.expectEqual(@as(u32, 1), bs.pending_tool_calls.count());
    try std.testing.expect(bs.pending_tool_calls.get("id-b") != null);
}

test "BufferSink tool_result falls back to last_tool_call without call_id" {
    var cb = try Conversation.init(std.testing.allocator, 0, "test");
    defer cb.deinit();

    var bs = BufferSink.init(std.testing.allocator, &cb);
    defer bs.deinit();
    const s = bs.sink();

    s.push(.{ .tool_use = .{ .name = "read" } }); // no call_id
    s.push(.{ .tool_result = .{ .content = "result" } });

    try std.testing.expectEqual(@as(usize, 1), cb.tree.root_children.items.len);
    const tool = cb.tree.root_children.items[0];
    try std.testing.expectEqual(@as(usize, 1), tool.children.items.len);
    const result_tb = try cb.buffer_registry.asText(tool.children.items[0].buffer_id.?);
    try std.testing.expectEqualStrings("result", result_tb.bytesView());
}

test "BufferSink handles duplicate call_id without leaking the key" {
    const alloc = std.testing.allocator;
    var cb = try Conversation.init(alloc, 0, "test");
    defer cb.deinit();
    var bs = BufferSink.init(alloc, &cb);
    defer bs.deinit();
    const s = bs.sink();

    s.push(.{ .tool_use = .{ .name = "first", .call_id = "id-A" } });
    s.push(.{ .tool_use = .{ .name = "second", .call_id = "id-A" } });

    // Only one map entry should exist; the second tool_use overwrites the
    // value for the existing key rather than leaking a duplicate dup.
    try std.testing.expectEqual(@as(u32, 1), bs.pending_tool_calls.count());
    // testing.allocator catches any leaked dup of "id-A".
}

test "BufferSink clears pending_tool_calls on run_end" {
    const alloc = std.testing.allocator;
    var cb = try Conversation.init(alloc, 0, "test");
    defer cb.deinit();
    var bs = BufferSink.init(alloc, &cb);
    defer bs.deinit();
    const s = bs.sink();

    s.push(.{ .tool_use = .{ .name = "t1", .call_id = "id-A" } });
    s.push(.{ .tool_use = .{ .name = "t2", .call_id = "id-B" } });
    try std.testing.expectEqual(@as(u32, 2), bs.pending_tool_calls.count());

    s.push(.run_end);
    try std.testing.expectEqual(@as(u32, 0), bs.pending_tool_calls.count());
    // testing.allocator catches any leaked keys.
}

test "BufferSink resetCorrelation can be called externally" {
    const alloc = std.testing.allocator;
    var cb = try Conversation.init(alloc, 0, "test");
    defer cb.deinit();
    var bs = BufferSink.init(alloc, &cb);
    defer bs.deinit();
    const s = bs.sink();

    s.push(.{ .tool_use = .{ .name = "t1", .call_id = "id-A" } });
    bs.resetCorrelation();
    try std.testing.expectEqual(@as(u32, 0), bs.pending_tool_calls.count());
}

test "tool_use event creates collapsed tool_call by default" {
    var cb = try Conversation.init(std.testing.allocator, 0, "test");
    defer cb.deinit();

    var bs = BufferSink.init(std.testing.allocator, &cb);
    defer bs.deinit();
    const s = bs.sink();

    s.push(.{ .tool_use = .{ .name = "bash", .call_id = null } });

    try std.testing.expectEqual(@as(usize, 1), cb.tree.root_children.items.len);
    const node = cb.tree.root_children.items[0];
    try std.testing.expectEqual(Conversation.NodeType.tool_call, node.node_type);
    try std.testing.expect(node.collapsed);
}

test "thinking_delta event creates collapsed thinking by default" {
    var cb = try Conversation.init(std.testing.allocator, 0, "test");
    defer cb.deinit();

    var bs = BufferSink.init(std.testing.allocator, &cb);
    defer bs.deinit();
    const s = bs.sink();

    s.push(.{ .thinking_delta = .{ .text = "first thoughts" } });

    try std.testing.expectEqual(@as(usize, 1), cb.tree.root_children.items.len);
    const node = cb.tree.root_children.items[0];
    try std.testing.expectEqual(Conversation.NodeType.thinking, node.node_type);
    try std.testing.expect(node.collapsed);
}

test "tool_result event bumps parent tool_call dirty state" {
    var cb = try Conversation.init(std.testing.allocator, 0, "test");
    defer cb.deinit();

    var bs = BufferSink.init(std.testing.allocator, &cb);
    defer bs.deinit();
    const s = bs.sink();

    s.push(.{ .tool_use = .{ .name = "bash", .call_id = "id-A" } });
    const parent = cb.tree.root_children.items[0];
    const version_before_result = parent.content_version;

    s.push(.{ .tool_result = .{ .content = "some output", .call_id = "id-A" } });

    try std.testing.expect(parent.content_version != version_before_result);

    // The parent id must land in the dirty ring so the renderer drops the
    // cached one-line tool_call rendering. appendNode for the child already
    // pushes the *child* id; this assertion is what pins the parent bump.
    var out: [ConversationTree.DirtyRing.capacity]u32 = undefined;
    const drained = cb.tree.dirty_nodes.drain(&out);
    var saw_parent = false;
    for (out[0..drained.written]) |id| if (id == parent.id) {
        saw_parent = true;
        break;
    };
    try std.testing.expect(saw_parent);
}

test "BufferSink error_event appends an err node" {
    var cb = try Conversation.init(std.testing.allocator, 0, "test");
    defer cb.deinit();

    var bs = BufferSink.init(std.testing.allocator, &cb);
    defer bs.deinit();
    const s = bs.sink();

    s.push(.{ .error_event = .{ .text = "boom" } });

    try std.testing.expectEqual(@as(usize, 1), cb.tree.root_children.items.len);
    const node = cb.tree.root_children.items[0];
    try std.testing.expectEqual(Conversation.NodeType.err, node.node_type);
    const tb = try cb.buffer_registry.asText(node.buffer_id.?);
    try std.testing.expectEqualStrings("boom", tb.bytesView());
}

test "post-response thinking_delta parents under the assistant_text node" {
    const allocator = std.testing.allocator;

    var cb = try Conversation.init(allocator, 1, "test");
    defer cb.deinit();

    var bs = BufferSink.init(allocator, &cb);
    defer bs.deinit();
    const s = bs.sink();

    // Turn 1: user message, assistant_delta (closes any open thinking),
    // then a LATE thinking_delta that arrives after the visible reply.
    s.push(.{ .run_start = .{ .user_text = "hello" } });
    s.push(.{ .assistant_delta = .{ .text = "hi there" } });
    s.push(.{ .thinking_delta = .{ .text = "post-response reasoning" } });
    s.push(.thinking_stop);
    s.push(.run_end);

    // Tree must be: [user_msg, assistant_text]
    // The post-response thinking is a CHILD of assistant_text, not a
    // root sibling.
    const roots = cb.tree.root_children.items;
    try std.testing.expectEqual(@as(usize, 2), roots.len);
    try std.testing.expectEqual(Conversation.NodeType.user_message, roots[0].node_type);
    try std.testing.expectEqual(Conversation.NodeType.assistant_text, roots[1].node_type);

    const assistant = roots[1];
    try std.testing.expectEqual(@as(usize, 1), assistant.children.items.len);
    try std.testing.expectEqual(Conversation.NodeType.thinking, assistant.children.items[0].node_type);
}

test "pre-response thinking_delta still parents at root" {
    // The opposite-direction contract: when thinking_delta arrives
    // BEFORE any assistant_delta this turn, last_assistant_node is
    // still null from the previous turn's run_end, so the new thinking
    // node parents at root as today.
    const allocator = std.testing.allocator;

    var cb = try Conversation.init(allocator, 1, "test");
    defer cb.deinit();

    var bs = BufferSink.init(allocator, &cb);
    defer bs.deinit();
    const s = bs.sink();

    s.push(.{ .run_start = .{ .user_text = "hello" } });
    s.push(.{ .thinking_delta = .{ .text = "let me think" } });
    s.push(.thinking_stop);
    s.push(.{ .assistant_delta = .{ .text = "answer" } });
    s.push(.run_end);

    const roots = cb.tree.root_children.items;
    try std.testing.expectEqual(@as(usize, 3), roots.len);
    try std.testing.expectEqual(Conversation.NodeType.user_message, roots[0].node_type);
    try std.testing.expectEqual(Conversation.NodeType.thinking, roots[1].node_type);
    try std.testing.expectEqual(Conversation.NodeType.assistant_text, roots[2].node_type);
}
