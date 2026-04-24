//! Registry of Lua-registered subagents.
//!
//! A subagent is a delegated execution context: its own system prompt,
//! optionally its own model, optionally a restricted tool allowlist. The
//! registry holds the definitions; the `task` tool consults it to dispatch
//! a call and the agent loop reads its `taskToolSchema` to describe the
//! available delegates to the LLM.
//!
//! Ownership: every string on a `Subagent` is heap-allocated from the
//! allocator passed to `register`. `deinit` frees all strings, the tool
//! allowlist slice (and each entry), and the backing array. Lua-side
//! lifetimes never leak into the registry.
//!
//! Validation happens at registration time:
//!   - `name` must match `[a-z0-9-]+`, 1-64 chars, no leading/trailing
//!     hyphen, no double hyphen. This is the identifier the LLM emits in
//!     the `agent` enum.
//!   - `description` must be 1-1024 bytes. Empty or oversized descriptions
//!     are rejected so the enum description stays useful.
//!   - Names are unique. Re-registration returns `error.DuplicateName`
//!     rather than silently overwriting.

const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

pub const RegisterError = Allocator.Error || error{
    InvalidName,
    InvalidDescription,
    DuplicateName,
};

pub const Subagent = struct {
    name: []const u8,
    description: []const u8,
    prompt: []const u8,
    model: ?[]const u8 = null,
    tools: ?[]const []const u8 = null,

    fn deinit(self: *Subagent, alloc: Allocator) void {
        alloc.free(self.name);
        alloc.free(self.description);
        alloc.free(self.prompt);
        if (self.model) |s| alloc.free(s);
        if (self.tools) |list| {
            for (list) |t| alloc.free(t);
            alloc.free(list);
        }
    }
};

pub const SubagentRegistry = struct {
    entries: std.ArrayListUnmanaged(Subagent) = .empty,

    pub fn deinit(self: *SubagentRegistry, alloc: Allocator) void {
        for (self.entries.items) |*entry| entry.deinit(alloc);
        self.entries.deinit(alloc);
        self.* = .{};
    }

    /// Validate `sa` and append a deeply-copied entry. On success the
    /// registry owns every string. On failure no allocations leak.
    pub fn register(
        self: *SubagentRegistry,
        alloc: Allocator,
        sa: Subagent,
    ) RegisterError!void {
        if (!isValidName(sa.name)) return error.InvalidName;
        if (sa.description.len == 0 or sa.description.len > 1024) {
            return error.InvalidDescription;
        }
        if (self.lookup(sa.name) != null) return error.DuplicateName;

        const name_copy = try alloc.dupe(u8, sa.name);
        errdefer alloc.free(name_copy);
        const desc_copy = try alloc.dupe(u8, sa.description);
        errdefer alloc.free(desc_copy);
        const prompt_copy = try alloc.dupe(u8, sa.prompt);
        errdefer alloc.free(prompt_copy);
        const model_copy: ?[]const u8 = if (sa.model) |s| try alloc.dupe(u8, s) else null;
        errdefer if (model_copy) |s| alloc.free(s);

        const tools_copy: ?[]const []const u8 = if (sa.tools) |list| blk: {
            const copied = try alloc.alloc([]const u8, list.len);
            errdefer alloc.free(copied);
            var filled: usize = 0;
            errdefer for (copied[0..filled]) |t| alloc.free(t);
            while (filled < list.len) : (filled += 1) {
                copied[filled] = try alloc.dupe(u8, list[filled]);
            }
            break :blk copied;
        } else null;
        errdefer if (tools_copy) |list| {
            for (list) |t| alloc.free(t);
            alloc.free(list);
        };

        try self.entries.append(alloc, .{
            .name = name_copy,
            .description = desc_copy,
            .prompt = prompt_copy,
            .model = model_copy,
            .tools = tools_copy,
        });
    }

    /// Linear scan for a subagent by name. Registry is small in practice
    /// (single-digit entries) so a map is overkill.
    pub fn lookup(self: *const SubagentRegistry, name: []const u8) ?*const Subagent {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry;
        }
        return null;
    }

    /// Emit the minified JSON Schema for the `task` tool. The `agent`
    /// property's enum lists every registered name; its description
    /// enumerates each entry as `"<name>: <description>."` so the LLM can
    /// tell delegates apart.
    ///
    /// An empty registry still produces valid JSON (empty enum). Callers
    /// decide whether to actually register the tool.
    pub fn taskToolSchema(self: *const SubagentRegistry, writer: anytype) !void {
        try writer.writeAll("{\"name\":\"task\",\"description\":\"");
        try writeJsonEscaped(writer, "Delegate work to a subagent. Returns the subagent's final summary.");
        try writer.writeAll("\",\"parameters\":{\"type\":\"object\",\"properties\":{\"agent\":{\"type\":\"string\",\"enum\":[");
        for (self.entries.items, 0..) |entry, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeByte('"');
            try writeJsonEscaped(writer, entry.name);
            try writer.writeByte('"');
        }
        try writer.writeAll("],\"description\":");
        try writeAgentEnumDescription(self, writer);
        try writer.writeAll("},\"prompt\":{\"type\":\"string\",\"description\":\"");
        try writeJsonEscaped(writer, "The task for the subagent.");
        try writer.writeAll("\"}},\"required\":[\"agent\",\"prompt\"]}}");
    }
};

fn writeAgentEnumDescription(
    self: *const SubagentRegistry,
    writer: anytype,
) !void {
    // Build the concatenated description as a single JSON string literal.
    // Emit the opening quote, write each chunk through the JSON escaper,
    // close the quote. Avoids an auxiliary allocator parameter on the
    // writer-only API.
    try writer.writeByte('"');
    try writeJsonEscaped(writer, "Which subagent to invoke.");
    for (self.entries.items) |entry| {
        try writer.writeByte(' ');
        try writeJsonEscaped(writer, entry.name);
        try writer.writeAll(": ");
        try writeJsonEscaped(writer, entry.description);
        if (entry.description.len == 0 or entry.description[entry.description.len - 1] != '.') {
            try writer.writeByte('.');
        }
    }
    try writer.writeByte('"');
}

fn writeJsonEscaped(writer: anytype, raw: []const u8) !void {
    for (raw) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => try writer.print("\\u{x:0>4}", .{c}),
            else => try writer.writeByte(c),
        }
    }
}

fn isValidName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    if (name[0] == '-' or name[name.len - 1] == '-') return false;

    var prev_hyphen = false;
    for (name) |c| {
        const is_lower = c >= 'a' and c <= 'z';
        const is_digit = c >= '0' and c <= '9';
        const is_hyphen = c == '-';
        if (!(is_lower or is_digit or is_hyphen)) return false;
        if (is_hyphen and prev_hyphen) return false;
        prev_hyphen = is_hyphen;
    }
    return true;
}

// --- Tests ---

test "register, lookup, deinit" {
    const alloc = testing.allocator;

    var registry: SubagentRegistry = .{};
    defer registry.deinit(alloc);

    try registry.register(alloc, .{
        .name = "reviewer",
        .description = "Reviews code diffs.",
        .prompt = "You are a reviewer.",
        .model = "anthropic/claude-haiku-4-5",
    });
    try registry.register(alloc, .{
        .name = "planner",
        .description = "Plans multi-step tasks.",
        .prompt = "You are a planner.",
        .tools = &.{ "read", "grep" },
    });
    try registry.register(alloc, .{
        .name = "scout",
        .description = "Reads the codebase and reports.",
        .prompt = "You are a scout.",
    });

    try testing.expectEqual(@as(usize, 3), registry.entries.items.len);

    const reviewer = registry.lookup("reviewer") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("reviewer", reviewer.name);
    try testing.expectEqualStrings("Reviews code diffs.", reviewer.description);
    try testing.expectEqualStrings("You are a reviewer.", reviewer.prompt);
    try testing.expectEqualStrings("anthropic/claude-haiku-4-5", reviewer.model.?);
    try testing.expect(reviewer.tools == null);

    const planner = registry.lookup("planner") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("planner", planner.name);
    try testing.expect(planner.model == null);
    try testing.expectEqual(@as(usize, 2), planner.tools.?.len);
    try testing.expectEqualStrings("read", planner.tools.?[0]);
    try testing.expectEqualStrings("grep", planner.tools.?[1]);

    const scout = registry.lookup("scout") orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("scout", scout.name);
    try testing.expect(scout.model == null);
    try testing.expect(scout.tools == null);
}

test "register rejects invalid name" {
    const alloc = testing.allocator;

    var registry: SubagentRegistry = .{};
    defer registry.deinit(alloc);

    const base: Subagent = .{
        .name = "placeholder",
        .description = "ok",
        .prompt = "ok",
    };

    var bad = base;
    bad.name = "Bad_Name";
    try testing.expectError(error.InvalidName, registry.register(alloc, bad));

    bad.name = "";
    try testing.expectError(error.InvalidName, registry.register(alloc, bad));

    bad.name = "-leading";
    try testing.expectError(error.InvalidName, registry.register(alloc, bad));

    bad.name = "trailing-";
    try testing.expectError(error.InvalidName, registry.register(alloc, bad));

    bad.name = "double--hyphen";
    try testing.expectError(error.InvalidName, registry.register(alloc, bad));

    bad.name = "UPPER";
    try testing.expectError(error.InvalidName, registry.register(alloc, bad));
}

test "register rejects empty or oversized description" {
    const alloc = testing.allocator;

    var registry: SubagentRegistry = .{};
    defer registry.deinit(alloc);

    try testing.expectError(error.InvalidDescription, registry.register(alloc, .{
        .name = "foo",
        .description = "",
        .prompt = "ok",
    }));

    var big_buf: [1025]u8 = undefined;
    @memset(&big_buf, 'x');
    try testing.expectError(error.InvalidDescription, registry.register(alloc, .{
        .name = "foo",
        .description = &big_buf,
        .prompt = "ok",
    }));
}

test "register rejects duplicate name" {
    const alloc = testing.allocator;

    var registry: SubagentRegistry = .{};
    defer registry.deinit(alloc);

    try registry.register(alloc, .{
        .name = "foo",
        .description = "first",
        .prompt = "p",
    });
    try testing.expectError(error.DuplicateName, registry.register(alloc, .{
        .name = "foo",
        .description = "second",
        .prompt = "p",
    }));
    try testing.expectEqual(@as(usize, 1), registry.entries.items.len);
}

test "lookup returns null for unknown" {
    const alloc = testing.allocator;

    var registry: SubagentRegistry = .{};
    defer registry.deinit(alloc);

    try registry.register(alloc, .{
        .name = "foo",
        .description = "desc",
        .prompt = "p",
    });
    try testing.expect(registry.lookup("bar") == null);
}

test "taskToolSchema emits enum and per-entry description" {
    const alloc = testing.allocator;

    var registry: SubagentRegistry = .{};
    defer registry.deinit(alloc);

    try registry.register(alloc, .{
        .name = "reviewer",
        .description = "Reviews diffs",
        .prompt = "p",
    });
    try registry.register(alloc, .{
        .name = "planner",
        .description = "Plans work.",
        .prompt = "p",
    });

    var buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try registry.taskToolSchema(fbs.writer());
    const out = fbs.getWritten();

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, out, .{});
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqualStrings("task", root.get("name").?.string);

    const params = root.get("parameters").?.object;
    const props = params.get("properties").?.object;
    const agent = props.get("agent").?.object;

    const enum_items = agent.get("enum").?.array.items;
    try testing.expectEqual(@as(usize, 2), enum_items.len);
    try testing.expectEqualStrings("reviewer", enum_items[0].string);
    try testing.expectEqualStrings("planner", enum_items[1].string);

    const desc = agent.get("description").?.string;
    try testing.expect(std.mem.indexOf(u8, desc, "reviewer") != null);
    try testing.expect(std.mem.indexOf(u8, desc, "planner") != null);
    try testing.expect(std.mem.indexOf(u8, desc, "Reviews diffs") != null);
    try testing.expect(std.mem.indexOf(u8, desc, "Plans work.") != null);

    const prompt_prop = props.get("prompt").?.object;
    try testing.expectEqualStrings("string", prompt_prop.get("type").?.string);

    const required = params.get("required").?.array.items;
    try testing.expectEqual(@as(usize, 2), required.len);
    try testing.expectEqualStrings("agent", required[0].string);
    try testing.expectEqualStrings("prompt", required[1].string);
}

test "taskToolSchema handles empty registry" {
    const alloc = testing.allocator;

    var registry: SubagentRegistry = .{};
    defer registry.deinit(alloc);

    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try registry.taskToolSchema(fbs.writer());
    const out = fbs.getWritten();

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, out, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    const params = root.get("parameters").?.object;
    const agent = params.get("properties").?.object.get("agent").?.object;
    const enum_items = agent.get("enum").?.array.items;
    try testing.expectEqual(@as(usize, 0), enum_items.len);
}
