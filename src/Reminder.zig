//! Reminder queue: short text snippets that get folded into the next
//! user-message boundary as `<system-reminder>` blocks.
//!
//! Lua plugins push entries via `zag.reminder(text, opts)`; the harness
//! drains the queue when it builds the next turn's request. Entries with
//! `scope = .next_turn` are removed on drain; `scope = .persistent`
//! survive across drains so they keep firing on every turn until cleared
//! by id.
//!
//! Capacity is bounded so a misbehaving plugin can't push reminders
//! faster than the harness drains them. Overflow drops the oldest entry
//! to keep the most recent context, which is the policy that matches
//! how humans use these reminders in practice (the latest nag wins).
//!
//! The queue is shared between the AgentRunner thread and Lua callbacks
//! marshalled onto the main thread, so every public method takes the
//! mutex.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;
const log = std.log.scoped(.reminder);

const Reminder = @This();

/// Hard cap on queued entries. When the queue is full, `push` evicts the
/// oldest entry before appending. 32 is enough headroom for a few
/// persistent reminders plus a burst of next-turn ones; anything beyond
/// that is almost certainly a plugin bug.
pub const MAX_ENTRIES: usize = 32;

/// When a reminder fires and how it survives.
///
/// - `next_turn`: included in the very next turn's drain, then dropped.
/// - `persistent`: included on every drain until cleared by id.
pub const Scope = enum { next_turn, persistent };

/// One queued reminder. `text` and the optional `id` are owned by the
/// allocator passed to `push`; `Queue.deinit` frees both.
pub const Entry = struct {
    /// Stable identifier so plugins can target `clearById`. Optional
    /// because next-turn reminders rarely need re-targeting.
    id: ?[]const u8 = null,
    /// The body of the reminder. Folded into a `<system-reminder>` block
    /// by the injection step in Harness.
    text: []const u8,
    /// Lifetime policy. See `Scope`.
    scope: Scope,
    /// Reserved for future once-per-turn dedup logic. Present so the
    /// Lua binding API stays stable; today every push is treated as
    /// once-per-drain regardless of this flag.
    once: bool = true,
};

/// FIFO queue of reminders. Owned entries are heap-allocated copies of
/// the text and id strings, so callers can free their inputs immediately
/// after `push` returns.
pub const Queue = struct {
    entries: std.ArrayList(Entry) = .empty,
    mutex: std.Thread.Mutex = .{},

    /// Free all queued entries and the backing array. Safe to call on a
    /// queue that has already been drained.
    pub fn deinit(self: *Queue, alloc: Allocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.entries.items) |entry| freeEntry(alloc, entry);
        self.entries.deinit(alloc);
    }

    /// Append `entry` to the queue, duping the strings so the caller's
    /// memory can go away. When the queue is at `MAX_ENTRIES`, the
    /// oldest entry is evicted first; we log a warning so the operator
    /// can spot a runaway producer.
    pub fn push(self: *Queue, alloc: Allocator, entry: Entry) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.entries.items.len >= MAX_ENTRIES) {
            const oldest = self.entries.orderedRemove(0);
            log.warn("queue full ({d}); dropping oldest reminder", .{MAX_ENTRIES});
            freeEntry(alloc, oldest);
        }

        const owned = try dupeEntry(alloc, entry);
        errdefer freeEntry(alloc, owned);
        try self.entries.append(alloc, owned);
    }

    /// Remove every entry whose `id` matches `id`. No-op when nothing
    /// matches. Entries with a null id are never matched.
    pub fn clearById(self: *Queue, alloc: Allocator, id: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var i: usize = 0;
        while (i < self.entries.items.len) {
            const entry = self.entries.items[i];
            const matches = entry.id != null and std.mem.eql(u8, entry.id.?, id);
            if (matches) {
                _ = self.entries.orderedRemove(i);
                freeEntry(alloc, entry);
                continue;
            }
            i += 1;
        }
    }

    /// Drain the entries that should fire on the next turn. Returns a
    /// fresh slice owned by `alloc`; persistent entries appear in the
    /// returned slice and remain in the queue for future drains.
    ///
    /// Each returned `Entry` aliases the strings owned by the queue for
    /// persistent entries, and owns its strings outright for next-turn
    /// entries. Free the slice with `freeDrained` to release both kinds
    /// uniformly.
    pub fn drainForTurn(self: *Queue, alloc: Allocator) ![]Entry {
        self.mutex.lock();
        defer self.mutex.unlock();

        var drained: std.ArrayList(Entry) = .empty;
        errdefer {
            for (drained.items) |entry| freeEntry(alloc, entry);
            drained.deinit(alloc);
        }

        var i: usize = 0;
        while (i < self.entries.items.len) {
            const entry = self.entries.items[i];
            const copy = try dupeEntry(alloc, entry);
            errdefer freeEntry(alloc, copy);
            try drained.append(alloc, copy);

            if (entry.scope == .next_turn) {
                _ = self.entries.orderedRemove(i);
                freeEntry(alloc, entry);
            } else {
                i += 1;
            }
        }

        return try drained.toOwnedSlice(alloc);
    }

    /// Snapshot every queued entry without removing anything. Useful
    /// for diagnostics and for tests that need to inspect persistent
    /// state without disturbing it. Free with `freeDrained`.
    pub fn snapshot(self: *Queue, alloc: Allocator) ![]Entry {
        self.mutex.lock();
        defer self.mutex.unlock();

        var copies: std.ArrayList(Entry) = .empty;
        errdefer {
            for (copies.items) |entry| freeEntry(alloc, entry);
            copies.deinit(alloc);
        }

        try copies.ensureTotalCapacity(alloc, self.entries.items.len);
        for (self.entries.items) |entry| {
            const copy = try dupeEntry(alloc, entry);
            errdefer freeEntry(alloc, copy);
            copies.appendAssumeCapacity(copy);
        }
        return try copies.toOwnedSlice(alloc);
    }

    /// Number of queued entries. Mostly for tests.
    pub fn len(self: *Queue) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.entries.items.len;
    }
};

/// Free a slice returned by `drainForTurn` or `snapshot`.
pub fn freeDrained(alloc: Allocator, drained: []Entry) void {
    for (drained) |entry| freeEntry(alloc, entry);
    alloc.free(drained);
}

fn dupeEntry(alloc: Allocator, entry: Entry) !Entry {
    const text = try alloc.dupe(u8, entry.text);
    errdefer alloc.free(text);
    const id_copy: ?[]const u8 = if (entry.id) |id| try alloc.dupe(u8, id) else null;
    return .{
        .id = id_copy,
        .text = text,
        .scope = entry.scope,
        .once = entry.once,
    };
}

fn freeEntry(alloc: Allocator, entry: Entry) void {
    alloc.free(entry.text);
    if (entry.id) |id| alloc.free(id);
}

test "push then drain returns FIFO order" {
    var q: Queue = .{};
    defer q.deinit(testing.allocator);

    try q.push(testing.allocator, .{ .text = "first", .scope = .next_turn });
    try q.push(testing.allocator, .{ .text = "second", .scope = .next_turn });
    try q.push(testing.allocator, .{ .text = "third", .scope = .next_turn });

    const drained = try q.drainForTurn(testing.allocator);
    defer freeDrained(testing.allocator, drained);

    try testing.expectEqual(@as(usize, 3), drained.len);
    try testing.expectEqualStrings("first", drained[0].text);
    try testing.expectEqualStrings("second", drained[1].text);
    try testing.expectEqualStrings("third", drained[2].text);
    try testing.expectEqual(@as(usize, 0), q.len());
}

test "persistent entries survive drain" {
    var q: Queue = .{};
    defer q.deinit(testing.allocator);

    try q.push(testing.allocator, .{ .text = "transient", .scope = .next_turn });
    try q.push(testing.allocator, .{ .id = "p1", .text = "sticky", .scope = .persistent });
    try q.push(testing.allocator, .{ .text = "also transient", .scope = .next_turn });

    const first = try q.drainForTurn(testing.allocator);
    defer freeDrained(testing.allocator, first);
    try testing.expectEqual(@as(usize, 3), first.len);
    try testing.expectEqual(@as(usize, 1), q.len());

    const second = try q.drainForTurn(testing.allocator);
    defer freeDrained(testing.allocator, second);
    try testing.expectEqual(@as(usize, 1), second.len);
    try testing.expectEqualStrings("sticky", second[0].text);
    try testing.expectEqual(Scope.persistent, second[0].scope);
}

test "clearById removes matching persistent entries" {
    var q: Queue = .{};
    defer q.deinit(testing.allocator);

    try q.push(testing.allocator, .{ .id = "keep", .text = "stay", .scope = .persistent });
    try q.push(testing.allocator, .{ .id = "drop", .text = "go", .scope = .persistent });
    try q.push(testing.allocator, .{ .id = "drop", .text = "go again", .scope = .persistent });
    try q.push(testing.allocator, .{ .text = "anonymous", .scope = .persistent });

    q.clearById(testing.allocator, "drop");
    try testing.expectEqual(@as(usize, 2), q.len());

    const snap = try q.snapshot(testing.allocator);
    defer freeDrained(testing.allocator, snap);
    try testing.expectEqualStrings("stay", snap[0].text);
    try testing.expectEqualStrings("anonymous", snap[1].text);
}

test "capacity overflow evicts oldest" {
    var q: Queue = .{};
    defer q.deinit(testing.allocator);

    var i: usize = 0;
    while (i < MAX_ENTRIES) : (i += 1) {
        var name_buf: [16]u8 = undefined;
        const text = try std.fmt.bufPrint(&name_buf, "n{d}", .{i});
        try q.push(testing.allocator, .{ .text = text, .scope = .next_turn });
    }
    try testing.expectEqual(MAX_ENTRIES, q.len());

    try q.push(testing.allocator, .{ .text = "newest", .scope = .next_turn });
    try testing.expectEqual(MAX_ENTRIES, q.len());

    const snap = try q.snapshot(testing.allocator);
    defer freeDrained(testing.allocator, snap);
    // The oldest ("n0") got evicted; the newest sits at the tail.
    try testing.expectEqualStrings("n1", snap[0].text);
    try testing.expectEqualStrings("newest", snap[snap.len - 1].text);
}

test "snapshot leaves queue intact" {
    var q: Queue = .{};
    defer q.deinit(testing.allocator);

    try q.push(testing.allocator, .{ .text = "a", .scope = .next_turn });
    try q.push(testing.allocator, .{ .id = "p", .text = "b", .scope = .persistent });

    const snap = try q.snapshot(testing.allocator);
    defer freeDrained(testing.allocator, snap);

    try testing.expectEqual(@as(usize, 2), snap.len);
    try testing.expectEqual(@as(usize, 2), q.len());
}

test "drained entries own their strings independent of queue" {
    var q: Queue = .{};
    defer q.deinit(testing.allocator);

    try q.push(testing.allocator, .{ .id = "live", .text = "stays alive", .scope = .persistent });

    const drained = try q.drainForTurn(testing.allocator);
    defer freeDrained(testing.allocator, drained);

    // Mutating the queue (clearing the persistent entry's source) must
    // not invalidate the slice we already drained.
    q.clearById(testing.allocator, "live");
    try testing.expectEqual(@as(usize, 0), q.len());
    try testing.expectEqualStrings("stays alive", drained[0].text);
}
