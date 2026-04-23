//! Slash command registry. Built-in commands (`/quit`, `/perf`,
//! `/perf-dump`, `/model`) are registered at WindowManager init;
//! Lua plugins add more via `zag.command{}`.
//!
//! Keys are the user-visible form including the leading slash so the
//! match is a plain string equality. Lua registrations shadow built-ins
//! when keyed on the same name (plugin override semantics).

const std = @import("std");
const Allocator = std.mem.Allocator;

const CommandRegistry = @This();

/// Zig-baked commands dispatched by the window manager itself. Lua
/// plugins declare their own commands through `registerLua`, which
/// stores a registry ref instead of one of these tags.
pub const BuiltIn = enum { quit, perf, perf_dump, model };

/// One command entry. Built-ins dispatch inline in `handleCommand`;
/// Lua callbacks fire through `LuaEngine.invokeCallback`.
pub const Command = union(enum) {
    built_in: BuiltIn,
    lua_callback: i32,
};

/// Owns duped key storage for every entry.
allocator: Allocator,
/// Slash-prefixed name -> command. Keys are heap-owned strings
/// allocated via `allocator`.
entries: std.StringHashMap(Command),

pub fn init(allocator: Allocator) CommandRegistry {
    return .{
        .allocator = allocator,
        .entries = std.StringHashMap(Command).init(allocator),
    };
}

pub fn deinit(self: *CommandRegistry) void {
    var it = self.entries.iterator();
    while (it.next()) |e| self.allocator.free(e.key_ptr.*);
    self.entries.deinit();
}

/// Register a zig-baked command. If the slash name is already taken,
/// the old entry is replaced (the previous key is freed so storage
/// does not leak).
pub fn registerBuiltIn(
    self: *CommandRegistry,
    slash_name: []const u8,
    kind: BuiltIn,
) !void {
    try self.put(slash_name, .{ .built_in = kind });
}

/// Register a Lua-backed command. `ref` is a registry reference held
/// by the Lua engine; the engine's registry teardown is what
/// ultimately releases the callback, not this map.
pub fn registerLua(
    self: *CommandRegistry,
    slash_name: []const u8,
    ref: i32,
) !void {
    try self.put(slash_name, .{ .lua_callback = ref });
}

/// Lookup by the full slash-prefixed form (e.g. `"/quit"`). Returns
/// null when no command matches; WindowManager interprets that as
/// `CommandResult.not_a_command`.
pub fn lookup(self: *const CommandRegistry, command: []const u8) ?Command {
    return self.entries.get(command);
}

fn put(self: *CommandRegistry, slash_name: []const u8, command: Command) !void {
    const gop = try self.entries.getOrPut(slash_name);
    if (gop.found_existing) {
        gop.value_ptr.* = command;
        return;
    }
    const key = self.allocator.dupe(u8, slash_name) catch |err| {
        // Roll back the reserved slot so the transient key pointer (the
        // borrowed `slash_name`) never survives in the map.
        _ = self.entries.remove(slash_name);
        return err;
    };
    gop.key_ptr.* = key;
    gop.value_ptr.* = command;
}

test "registerBuiltIn + lookup round trip" {
    var r = CommandRegistry.init(std.testing.allocator);
    defer r.deinit();
    try r.registerBuiltIn("/quit", .quit);
    const hit = r.lookup("/quit") orelse return error.TestExpected;
    try std.testing.expect(hit == .built_in);
    try std.testing.expectEqual(BuiltIn.quit, hit.built_in);
}

test "lookup miss returns null" {
    var r = CommandRegistry.init(std.testing.allocator);
    defer r.deinit();
    try r.registerBuiltIn("/quit", .quit);
    try std.testing.expectEqual(@as(?Command, null), r.lookup("/nope"));
}

test "registerLua stores callback ref" {
    var r = CommandRegistry.init(std.testing.allocator);
    defer r.deinit();
    try r.registerLua("/greet", 42);
    const hit = r.lookup("/greet") orelse return error.TestExpected;
    try std.testing.expect(hit == .lua_callback);
    try std.testing.expectEqual(@as(i32, 42), hit.lua_callback);
}

test "registerLua shadows a built-in keyed on the same name" {
    var r = CommandRegistry.init(std.testing.allocator);
    defer r.deinit();
    try r.registerBuiltIn("/quit", .quit);
    try r.registerLua("/quit", 7);
    const hit = r.lookup("/quit") orelse return error.TestExpected;
    try std.testing.expect(hit == .lua_callback);
    try std.testing.expectEqual(@as(i32, 7), hit.lua_callback);
}

test "deinit frees every duped key" {
    var r = CommandRegistry.init(std.testing.allocator);
    try r.registerBuiltIn("/quit", .quit);
    try r.registerBuiltIn("/perf", .perf);
    try r.registerLua("/greet", 11);
    r.deinit();
}

test {
    std.testing.refAllDecls(@This());
}
