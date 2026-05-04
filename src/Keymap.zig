//! Vim-style modal keymap.
//!
//! Two global modes (insert / normal). The registry maps (mode, KeySpec)
//! to an Action name. `main.zig` resolves the action to a concrete
//! side-effect via a switch; Lua config can register overrides via
//! `zag.keymap()`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const input = @import("input.zig");

const Keymap = @This();

/// Editing mode. Insert fills the input buffer (typing). Normal fires
/// keymap bindings and disables typing.
pub const Mode = enum { insert, normal };

/// The closed set of built-in actions v1 supports. Lua config binds
/// keys to these by name. `.lua_callback` carries a ziglua registry
/// ref so plugins can bind arbitrary Lua functions to keys; Task 4
/// wires the dispatch arm that invokes it.
pub const Action = union(enum) {
    focus_left,
    focus_down,
    focus_up,
    focus_right,
    split_vertical,
    split_horizontal,
    close_window,
    resize,
    enter_insert_mode,
    enter_normal_mode,
    /// Drill into the focused pane's most recent subagent (i.e. the
    /// last `.subagent_link` node in its Conversation tree). No-op when
    /// the pane has no Conversation or no subagent links.
    enter_subagent,
    lua_callback: i32,
};

/// Map a Lua-facing action name to an Action. Returns null for unknown.
/// `.lua_callback` is constructed directly in the `zag.keymap()` binding
/// when a function argument is supplied, so it is intentionally absent
/// from this string table.
pub fn parseActionName(name: []const u8) ?Action {
    const table = [_]struct { []const u8, Action }{
        .{ "focus_left", .focus_left },
        .{ "focus_down", .focus_down },
        .{ "focus_up", .focus_up },
        .{ "focus_right", .focus_right },
        .{ "split_vertical", .split_vertical },
        .{ "split_horizontal", .split_horizontal },
        .{ "close_window", .close_window },
        .{ "resize", .resize },
        .{ "enter_insert_mode", .enter_insert_mode },
        .{ "enter_normal_mode", .enter_normal_mode },
        .{ "enter_subagent", .enter_subagent },
    };
    for (table) |e| {
        if (std.mem.eql(u8, e[0], name)) return e[1];
    }
    return null;
}

/// Inverse of `parseActionName`: render a built-in Action variant to
/// its Lua-facing string name. Returns null for `.lua_callback`, which
/// has no string representation (the Lua wrapper owns the registry ref
/// behind it; a plugin cannot re-register a Lua callback it didn't
/// create). Used by the `zag.keymap` wrapper to emit a `displaced_spec`
/// table that callers can pass back through `zag.keymap{...}` to
/// restore an overwritten built-in binding.
pub fn actionName(action: Action) ?[]const u8 {
    return switch (action) {
        .focus_left => "focus_left",
        .focus_down => "focus_down",
        .focus_up => "focus_up",
        .focus_right => "focus_right",
        .split_vertical => "split_vertical",
        .split_horizontal => "split_horizontal",
        .close_window => "close_window",
        .resize => "resize",
        .enter_insert_mode => "enter_insert_mode",
        .enter_normal_mode => "enter_normal_mode",
        .enter_subagent => "enter_subagent",
        .lua_callback => null,
    };
}

/// A specification of a keystroke: a Key variant + modifier flags.
/// Matches the shape emitted by input.Parser for real keypresses.
pub const KeySpec = struct {
    key: input.KeyEvent.Key,
    modifiers: input.KeyEvent.Modifiers = .{},

    /// Two specs match iff both key and all modifier flags are equal.
    pub fn eql(a: KeySpec, b: KeySpec) bool {
        if (std.meta.activeTag(a.key) != std.meta.activeTag(b.key)) return false;
        switch (a.key) {
            .char => |c| if (c != b.key.char) return false,
            .function => |n| if (n != b.key.function) return false,
            else => {},
        }
        return a.modifiers.shift == b.modifiers.shift and
            a.modifiers.alt == b.modifiers.alt and
            a.modifiers.ctrl == b.modifiers.ctrl;
    }
};

pub const ParseError = error{InvalidKeySpec};

/// Parse a vim-style key spec into a KeySpec.
///
/// Accepted forms:
///   - bare char: "h", "A", "1"
///   - angle-bracket special: "<Esc>", "<CR>", "<Tab>", "<BS>", "<Space>"
///   - modifier: "<C-a>" (Ctrl), "<M-x>" (Meta/Alt), "<S-x>" (Shift)
///   - combined: "<C-M-x>", "<C-Space>"
///
/// Anything else returns error.InvalidKeySpec.
pub fn parseKeySpec(s: []const u8) ParseError!KeySpec {
    if (s.len == 0) return error.InvalidKeySpec;

    // Bare char (single codepoint, no angle brackets).
    if (s[0] != '<') {
        var it = (std.unicode.Utf8View.init(s) catch return error.InvalidKeySpec).iterator();
        const cp = it.nextCodepoint() orelse return error.InvalidKeySpec;
        if (it.nextCodepoint() != null) return error.InvalidKeySpec;
        return .{ .key = .{ .char = cp } };
    }

    // Angle-bracket form: strip surrounding < >.
    if (s[s.len - 1] != '>') return error.InvalidKeySpec;
    const inner = s[1 .. s.len - 1];
    if (inner.len == 0) return error.InvalidKeySpec;

    // Stackable modifier prefixes: <C-M-x>, <C-Space>, etc.
    var modifiers: input.KeyEvent.Modifiers = .{};
    var rest = inner;
    while (rest.len >= 2 and rest[1] == '-') {
        switch (rest[0]) {
            'C', 'c' => modifiers.ctrl = true,
            'M', 'm', 'A', 'a' => modifiers.alt = true,
            'S', 's' => modifiers.shift = true,
            else => return error.InvalidKeySpec,
        }
        rest = rest[2..];
    }
    if (rest.len == 0) return error.InvalidKeySpec;

    // Named specials.
    const named_table = [_]struct { []const u8, input.KeyEvent.Key }{
        .{ "Esc", .escape },
        .{ "CR", .enter },
        .{ "Enter", .enter },
        .{ "Tab", .tab },
        .{ "BS", .backspace },
        .{ "Space", .{ .char = ' ' } },
        .{ "Up", .up },
        .{ "Down", .down },
        .{ "Left", .left },
        .{ "Right", .right },
        .{ "Home", .home },
        .{ "End", .end },
        .{ "PageUp", .page_up },
        .{ "PageDown", .page_down },
        .{ "Del", .delete },
        .{ "Ins", .insert },
    };
    for (named_table) |e| {
        if (std.ascii.eqlIgnoreCase(e[0], rest)) {
            return .{ .key = e[1], .modifiers = modifiers };
        }
    }

    // Function keys: <F1>..<F12> (or any number). Function keys live
    // outside the named_table because they carry an integer payload.
    if ((rest[0] == 'F' or rest[0] == 'f') and rest.len >= 2) {
        const n = std.fmt.parseInt(u8, rest[1..], 10) catch return error.InvalidKeySpec;
        return .{ .key = .{ .function = n }, .modifiers = modifiers };
    }

    // Fallback: a single codepoint inside the angle brackets (e.g. "<C-a>").
    var it = (std.unicode.Utf8View.init(rest) catch return error.InvalidKeySpec).iterator();
    const cp = it.nextCodepoint() orelse return error.InvalidKeySpec;
    if (it.nextCodepoint() != null) return error.InvalidKeySpec;
    return .{ .key = .{ .char = cp }, .modifiers = modifiers };
}

/// Render a `KeyEvent` (or any equivalent key + modifiers tuple) into
/// the canonical key-spec string that `parseKeySpec` accepts. Used by
/// the orchestrator to feed Lua-side `on_key` filters the same string
/// shape plugin authors write for `zag.keymap{ key = ... }`. Bare ASCII
/// printables with no modifiers stringify to themselves ("h"); all
/// other forms use angle brackets ("<C-S-x>", "<Esc>", "<CR>", ...).
/// Returns the slice of `buf` actually filled.
pub fn formatKeySpec(buf: []u8, ev: input.KeyEvent) []const u8 {
    var stream = std.io.fixedBufferStream(buf);
    const w = stream.writer();

    // Bare-char shortcut: a single printable ASCII char with no
    // modifiers round-trips through `parseKeySpec` as a bare char,
    // which is the canonical compact form for typing letters.
    const has_mods = ev.modifiers.ctrl or ev.modifiers.alt or ev.modifiers.shift;
    if (!has_mods) switch (ev.key) {
        .char => |ch| if (ch >= 0x20 and ch < 0x7f and ch != ' ') {
            w.writeByte(@intCast(ch)) catch {};
            return stream.getWritten();
        },
        else => {},
    };

    w.writeAll("<") catch {};
    if (ev.modifiers.ctrl) w.writeAll("C-") catch {};
    if (ev.modifiers.alt) w.writeAll("M-") catch {};
    if (ev.modifiers.shift) w.writeAll("S-") catch {};
    switch (ev.key) {
        .char => |ch| {
            if (ch == ' ') {
                w.writeAll("Space") catch {};
            } else if (ch >= 0x20 and ch < 0x7f) {
                w.writeByte(@intCast(ch)) catch {};
            } else {
                std.fmt.format(w, "u{d}", .{@as(u32, ch)}) catch {};
            }
        },
        .escape => w.writeAll("Esc") catch {},
        .enter => w.writeAll("CR") catch {},
        .tab => w.writeAll("Tab") catch {},
        .backspace => w.writeAll("BS") catch {},
        .up => w.writeAll("Up") catch {},
        .down => w.writeAll("Down") catch {},
        .left => w.writeAll("Left") catch {},
        .right => w.writeAll("Right") catch {},
        .home => w.writeAll("Home") catch {},
        .end => w.writeAll("End") catch {},
        .page_up => w.writeAll("PageUp") catch {},
        .page_down => w.writeAll("PageDown") catch {},
        .delete => w.writeAll("Del") catch {},
        .insert => w.writeAll("Ins") catch {},
        .function => |n| std.fmt.format(w, "F{d}", .{n}) catch {},
    }
    w.writeAll(">") catch {};
    return stream.getWritten();
}

/// A single (mode, key-spec) -> action entry stored in the registry.
///
/// `buffer_id == null` is a global binding (fires in any focused buffer).
/// A non-null `buffer_id` scopes the binding to that buffer handle only,
/// which lets plugins attach keymaps to scratch buffers without leaking
/// them into conversation panes.
///
/// `id` is a stable monotonic handle minted by `Registry.register`; Lua
/// callers stash it from `zag.keymap{...}` and pass it back to
/// `zag.keymap_remove(id)` to unregister the binding (and unref the
/// `.lua_callback` ref). Mirrors the `Hooks.Registry` shape.
pub const Binding = struct {
    id: u32,
    mode: Mode,
    spec: KeySpec,
    buffer_id: ?u32,
    action: Action,
};

/// Mutable map of (Mode, KeySpec) -> Action. Linear scan: small N, no
/// hashing of the tagged-union key needed.
pub const Registry = struct {
    allocator: Allocator,
    bindings: std.ArrayList(Binding),
    next_id: u32,

    pub fn init(allocator: Allocator) Registry {
        return .{ .allocator = allocator, .bindings = .empty, .next_id = 1 };
    }

    pub fn deinit(self: *Registry) void {
        self.bindings.deinit(self.allocator);
    }

    /// Outcome of `Registry.register`. `id` is the stable handle for the
    /// binding (newly minted on a fresh insert, reused on overwrite).
    /// `displaced` carries the prior action when overwriting so the
    /// caller can release any resources it owned (chiefly the Lua
    /// registry ref behind `.lua_callback`); it is null on fresh
    /// inserts. Mirrors `CommandRegistry.registerLua`.
    pub const RegisterResult = struct {
        id: u32,
        displaced: ?Action,
    };

    /// Register (or overwrite) a binding. If a binding already exists
    /// for (mode, spec, buffer_id) its action is replaced so user config
    /// can remap defaults without duplicating entries. Scope is part of
    /// the identity: a global `j` and a buffer-local `j` coexist.
    ///
    /// Returns the binding's stable id alongside the displaced `Action`
    /// when an existing entry was overwritten. Callers that bind
    /// `.lua_callback` payloads MUST inspect `displaced` and unref the
    /// prior callback themselves; the registry never touches the Lua
    /// VM. Re-registering an existing (mode, spec, buffer_id) reuses
    /// the EXISTING id — not a fresh one.
    ///
    /// Ids are minted from a monotonic u32 counter that never recycles
    /// removed slots. After `std.math.maxInt(u32)` fresh registrations
    /// the counter is exhausted and this function returns
    /// `error.IdSpaceExhausted` rather than wrapping silently (id 0
    /// would otherwise collide with the Lua wrapper's "no id" sentinel).
    /// `next_id` is left unchanged on the exhaustion path so the
    /// registry stays internally consistent.
    pub fn register(
        self: *Registry,
        mode: Mode,
        spec: KeySpec,
        buffer_id: ?u32,
        action: Action,
    ) (Allocator.Error || error{IdSpaceExhausted})!RegisterResult {
        for (self.bindings.items) |*b| {
            if (b.mode == mode and b.spec.eql(spec) and scopeEq(b.buffer_id, buffer_id)) {
                const displaced = b.action;
                b.action = action;
                return .{ .id = b.id, .displaced = displaced };
            }
        }
        const id = self.next_id;
        const next = std.math.add(u32, self.next_id, 1) catch return error.IdSpaceExhausted;
        try self.bindings.append(
            self.allocator,
            .{ .id = id, .mode = mode, .spec = spec, .buffer_id = buffer_id, .action = action },
        );
        self.next_id = next;
        return .{ .id = id, .displaced = null };
    }

    /// Remove a binding by id. Returns the removed `Action` so the
    /// caller can clean up Lua registry refs held in `.lua_callback`
    /// payloads. Returns `error.NotFound` when no binding has that id.
    /// Does NOT unref `.lua_callback` itself; the Lua engine wrapper
    /// owns that side of the contract because it owns the Lua VM.
    pub fn unregister(self: *Registry, id: u32) error{NotFound}!Action {
        for (self.bindings.items, 0..) |b, i| {
            if (b.id == id) {
                _ = self.bindings.orderedRemove(i);
                return b.action;
            }
        }
        return error.NotFound;
    }

    /// Find the action bound to (mode, event). Two-pass: buffer-local
    /// bindings that match `focused_buffer_id` win; otherwise fall back
    /// to the first matching global binding. Returns null if nothing
    /// matches in either pass.
    pub fn lookup(
        self: *const Registry,
        mode: Mode,
        event: input.KeyEvent,
        focused_buffer_id: ?u32,
    ) ?Action {
        const target: KeySpec = .{ .key = event.key, .modifiers = event.modifiers };
        if (focused_buffer_id) |fid| {
            for (self.bindings.items) |b| {
                if (b.mode == mode and b.spec.eql(target) and b.buffer_id != null and b.buffer_id.? == fid) {
                    return b.action;
                }
            }
        }
        for (self.bindings.items) |b| {
            if (b.mode == mode and b.spec.eql(target) and b.buffer_id == null) return b.action;
        }
        return null;
    }

    /// Install the built-in default bindings. All defaults are global
    /// (buffer_id = null); plugins introduce buffer-scoped bindings.
    pub fn loadDefaults(self: *Registry) !void {
        const defaults = [_]struct { Mode, []const u8, Action }{
            // Normal-mode window ops.
            .{ .normal, "h", .focus_left },
            .{ .normal, "j", .focus_down },
            .{ .normal, "k", .focus_up },
            .{ .normal, "l", .focus_right },
            .{ .normal, "v", .split_vertical },
            .{ .normal, "s", .split_horizontal },
            .{ .normal, "q", .close_window },
            // Mode transitions.
            .{ .normal, "i", .enter_insert_mode },
            .{ .insert, "<Esc>", .enter_normal_mode },
            // Drill into the focused pane's most recent subagent. No-op
            // on panes without a Conversation or without subagent links.
            .{ .normal, "<CR>", .enter_subagent },
            // Insert-mode line editing (Ctrl-W "delete word", printable
            // chars, Backspace, Enter) is handled inside the focused
            // buffer's `handleKey` (see Conversation.handleKey), not
            // here. Adding Ctrl-U / Ctrl-A / Ctrl-E would belong on the
            // buffer too, so the keymap stays free of line-edit concerns.
        };
        for (defaults) |d| {
            const spec = try parseKeySpec(d[1]);
            _ = try self.register(d[0], spec, null, d[2]);
        }
    }
};

/// Treat two optional buffer ids as equal when both null or both same
/// non-null value. Kept internal to the module; `register` uses it to
/// decide when an existing binding is overwritten vs appended.
fn scopeEq(a: ?u32, b: ?u32) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.? == b.?;
}

test {
    _ = @import("std").testing.refAllDecls(@This());
}

test "Mode enum has two variants" {
    try std.testing.expectEqual(@as(usize, 2), @typeInfo(Mode).@"enum".fields.len);
}

test "Action union covers the built-in action names plus lua_callback" {
    // Eleven payload-less built-in variants plus `.lua_callback: i32`.
    try std.testing.expectEqual(@as(usize, 12), @typeInfo(Action).@"union".fields.len);
}

test "parseActionName maps known and rejects unknown" {
    try std.testing.expect(parseActionName("focus_left").? == .focus_left);
    try std.testing.expect(parseActionName("split_vertical").? == .split_vertical);
    try std.testing.expect(parseActionName("enter_normal_mode").? == .enter_normal_mode);
    try std.testing.expect(parseActionName("no_such_action") == null);
}

test "parseKeySpec bare char" {
    const spec = try parseKeySpec("h");
    try std.testing.expectEqual(@as(u21, 'h'), spec.key.char);
    try std.testing.expect(!spec.modifiers.ctrl);
    try std.testing.expect(!spec.modifiers.alt);
}

test "parseKeySpec Esc / Enter / Tab / BS / Space" {
    try std.testing.expectEqual(input.KeyEvent.Key.escape, (try parseKeySpec("<Esc>")).key);
    try std.testing.expectEqual(input.KeyEvent.Key.enter, (try parseKeySpec("<CR>")).key);
    try std.testing.expectEqual(input.KeyEvent.Key.tab, (try parseKeySpec("<Tab>")).key);
    try std.testing.expectEqual(input.KeyEvent.Key.backspace, (try parseKeySpec("<BS>")).key);
    try std.testing.expectEqual(@as(u21, ' '), (try parseKeySpec("<Space>")).key.char);
}

test "parseKeySpec Ctrl and Alt modifiers" {
    const c = try parseKeySpec("<C-a>");
    try std.testing.expectEqual(@as(u21, 'a'), c.key.char);
    try std.testing.expect(c.modifiers.ctrl);

    const m = try parseKeySpec("<M-x>");
    try std.testing.expectEqual(@as(u21, 'x'), m.key.char);
    try std.testing.expect(m.modifiers.alt);
}

test "parseKeySpec named specials are case-insensitive" {
    try std.testing.expectEqual(input.KeyEvent.Key.escape, (try parseKeySpec("<esc>")).key);
    try std.testing.expectEqual(input.KeyEvent.Key.escape, (try parseKeySpec("<ESC>")).key);
    try std.testing.expectEqual(input.KeyEvent.Key.tab, (try parseKeySpec("<TAB>")).key);
}

test "parseKeySpec stacked modifiers" {
    const spec = try parseKeySpec("<C-M-a>");
    try std.testing.expectEqual(@as(u21, 'a'), spec.key.char);
    try std.testing.expect(spec.modifiers.ctrl);
    try std.testing.expect(spec.modifiers.alt);
    try std.testing.expect(!spec.modifiers.shift);
}

test "parseKeySpec Ctrl + named special" {
    const spec = try parseKeySpec("<C-Space>");
    try std.testing.expectEqual(@as(u21, ' '), spec.key.char);
    try std.testing.expect(spec.modifiers.ctrl);
}

test "parseKeySpec rejects empty and malformed" {
    try std.testing.expectError(error.InvalidKeySpec, parseKeySpec(""));
    try std.testing.expectError(error.InvalidKeySpec, parseKeySpec("<>"));
    try std.testing.expectError(error.InvalidKeySpec, parseKeySpec("<C->"));
    try std.testing.expectError(error.InvalidKeySpec, parseKeySpec("<ctrl-a>"));
}

test "Registry round-trip: register then lookup" {
    var r = Keymap.Registry.init(std.testing.allocator);
    defer r.deinit();

    _ = try r.register(.normal, try parseKeySpec("h"), null, .focus_left);
    _ = try r.register(.normal, try parseKeySpec("<C-q>"), null, .close_window);

    const ev_h: input.KeyEvent = .{ .key = .{ .char = 'h' }, .modifiers = .{} };
    try std.testing.expect(r.lookup(.normal, ev_h, null).? == .focus_left);

    const ev_ctrl_q: input.KeyEvent = .{
        .key = .{ .char = 'q' },
        .modifiers = .{ .ctrl = true },
    };
    try std.testing.expect(r.lookup(.normal, ev_ctrl_q, null).? == .close_window);

    try std.testing.expect(r.lookup(.insert, ev_h, null) == null);
    try std.testing.expect(r.lookup(.normal, .{ .key = .{ .char = 'z' }, .modifiers = .{} }, null) == null);
}

test "Registry re-register overwrites" {
    var r = Keymap.Registry.init(std.testing.allocator);
    defer r.deinit();

    const spec = try parseKeySpec("q");
    _ = try r.register(.normal, spec, null, .close_window);
    _ = try r.register(.normal, spec, null, .enter_insert_mode);

    try std.testing.expect(
        r.lookup(.normal, .{ .key = .{ .char = 'q' }, .modifiers = .{} }, null).? == .enter_insert_mode,
    );
}

test "loadDefaults installs the nine built-in bindings" {
    var r = Keymap.Registry.init(std.testing.allocator);
    defer r.deinit();
    try r.loadDefaults();

    try std.testing.expect(r.lookup(.normal, .{ .key = .{ .char = 'h' }, .modifiers = .{} }, null).? == .focus_left);
    try std.testing.expect(r.lookup(.normal, .{ .key = .{ .char = 'v' }, .modifiers = .{} }, null).? == .split_vertical);
    try std.testing.expect(r.lookup(.insert, .{ .key = .escape, .modifiers = .{} }, null).? == .enter_normal_mode);
    try std.testing.expect(r.lookup(.normal, .{ .key = .{ .char = 'i' }, .modifiers = .{} }, null).? == .enter_insert_mode);
}

test "parseActionName recognizes resize" {
    try std.testing.expect(parseActionName("resize").? == .resize);
}

test "actionName round-trips through parseActionName for every built-in" {
    // Every built-in Action variant must stringify to a name that
    // parseActionName recognizes; otherwise `zag.keymap` can't emit a
    // displaced_spec table that a caller can pass back to restore the
    // overwritten binding.
    const variants = [_]Action{
        .focus_left,        .focus_down,     .focus_up,
        .focus_right,       .split_vertical, .split_horizontal,
        .close_window,      .resize,         .enter_insert_mode,
        .enter_normal_mode,
    };
    for (variants) |a| {
        const name = actionName(a) orelse return error.TestExpected;
        const round = parseActionName(name) orelse return error.TestExpected;
        try std.testing.expect(std.meta.activeTag(round) == std.meta.activeTag(a));
    }
}

test "actionName returns null for lua_callback" {
    try std.testing.expectEqual(@as(?[]const u8, null), actionName(.{ .lua_callback = 7 }));
}

test "registry lookup prefers buffer-local binding over global" {
    var r = Keymap.Registry.init(std.testing.allocator);
    defer r.deinit();
    // Global binding
    _ = try r.register(.normal, .{ .key = .{ .char = 'j' }, .modifiers = .{} }, null, .focus_down);
    // Buffer-local overrides it for buffer 42
    _ = try r.register(.normal, .{ .key = .{ .char = 'j' }, .modifiers = .{} }, 42, .focus_up);

    const ev: input.KeyEvent = .{ .key = .{ .char = 'j' }, .modifiers = .{} };
    const hit_local = r.lookup(.normal, ev, 42) orelse return error.TestExpected;
    try std.testing.expect(hit_local == .focus_up);
    const hit_other = r.lookup(.normal, ev, 99) orelse return error.TestExpected;
    try std.testing.expect(hit_other == .focus_down);
    const hit_unscoped = r.lookup(.normal, ev, null) orelse return error.TestExpected;
    try std.testing.expect(hit_unscoped == .focus_down);
}

test "Action.lua_callback carries a Lua registry ref" {
    const a: Action = .{ .lua_callback = 7 };
    try std.testing.expect(a == .lua_callback);
    try std.testing.expectEqual(@as(i32, 7), a.lua_callback);
}

test "formatKeySpec round-trips through parseKeySpec for the common shapes" {
    // The on_key filter passes a string description to Lua plugins;
    // they're expected to compare it against the same form
    // `parseKeySpec` accepts. Round-trip the canonical shapes so the
    // two functions can never drift.
    var buf: [32]u8 = undefined;

    const cases = [_]struct {
        ev: input.KeyEvent,
        text: []const u8,
    }{
        .{ .ev = .{ .key = .{ .char = 'h' }, .modifiers = .{} }, .text = "h" },
        .{ .ev = .{ .key = .{ .char = 'a' }, .modifiers = .{ .ctrl = true } }, .text = "<C-a>" },
        .{ .ev = .{ .key = .{ .char = 'x' }, .modifiers = .{ .ctrl = true, .shift = true } }, .text = "<C-S-x>" },
        .{ .ev = .{ .key = .escape, .modifiers = .{} }, .text = "<Esc>" },
        .{ .ev = .{ .key = .enter, .modifiers = .{} }, .text = "<CR>" },
        .{ .ev = .{ .key = .tab, .modifiers = .{} }, .text = "<Tab>" },
        .{ .ev = .{ .key = .backspace, .modifiers = .{} }, .text = "<BS>" },
        .{ .ev = .{ .key = .{ .char = ' ' }, .modifiers = .{} }, .text = "<Space>" },
        .{ .ev = .{ .key = .{ .char = ' ' }, .modifiers = .{ .ctrl = true } }, .text = "<C-Space>" },
        .{ .ev = .{ .key = .up, .modifiers = .{} }, .text = "<Up>" },
        .{ .ev = .{ .key = .home, .modifiers = .{} }, .text = "<Home>" },
        .{ .ev = .{ .key = .page_down, .modifiers = .{} }, .text = "<PageDown>" },
        .{ .ev = .{ .key = .delete, .modifiers = .{} }, .text = "<Del>" },
        .{ .ev = .{ .key = .{ .function = 5 }, .modifiers = .{} }, .text = "<F5>" },
    };
    for (cases) |c| {
        const got = formatKeySpec(&buf, c.ev);
        try std.testing.expectEqualStrings(c.text, got);
        const parsed = try parseKeySpec(got);
        try std.testing.expect(parsed.eql(.{ .key = c.ev.key, .modifiers = c.ev.modifiers }));
    }
}

test "Registry register returns a stable id; unregister removes by id" {
    var r = Keymap.Registry.init(std.testing.allocator);
    defer r.deinit();

    const id1 = (try r.register(.normal, try parseKeySpec("a"), null, .focus_left)).id;
    const id2 = (try r.register(.normal, try parseKeySpec("b"), null, .focus_right)).id;
    try std.testing.expect(id1 != id2);

    const removed = try r.unregister(id1);
    try std.testing.expect(removed == .focus_left);

    const ev_a: input.KeyEvent = .{ .key = .{ .char = 'a' }, .modifiers = .{} };
    try std.testing.expectEqual(@as(?Action, null), r.lookup(.normal, ev_a, null));

    // The surviving binding is unaffected.
    const ev_b: input.KeyEvent = .{ .key = .{ .char = 'b' }, .modifiers = .{} };
    try std.testing.expect(r.lookup(.normal, ev_b, null).? == .focus_right);

    // A subsequent register mints a fresh id (monotonic, not recycled).
    const id3 = (try r.register(.normal, try parseKeySpec("c"), null, .focus_up)).id;
    try std.testing.expect(id3 != id1);
    try std.testing.expect(id3 != id2);
}

test "Registry unregister returns the lua_callback action so the caller can unref" {
    var r = Keymap.Registry.init(std.testing.allocator);
    defer r.deinit();

    const id = (try r.register(.normal, try parseKeySpec("x"), null, .{ .lua_callback = 42 })).id;
    const removed = try r.unregister(id);
    try std.testing.expect(removed == .lua_callback);
    try std.testing.expectEqual(@as(i32, 42), removed.lua_callback);
}

test "Registry unregister returns NotFound for unknown id" {
    var r = Keymap.Registry.init(std.testing.allocator);
    defer r.deinit();

    try std.testing.expectError(error.NotFound, r.unregister(99999));
}

test "Registry register overwrite returns the existing id" {
    var r = Keymap.Registry.init(std.testing.allocator);
    defer r.deinit();

    const spec = try parseKeySpec("q");
    const first = try r.register(.normal, spec, null, .close_window);
    try std.testing.expectEqual(@as(?Action, null), first.displaced);
    const second = try r.register(.normal, spec, null, .enter_insert_mode);
    try std.testing.expectEqual(first.id, second.id);
    try std.testing.expectEqual(@as(usize, 1), r.bindings.items.len);
}

test "Registry register replacing a lua_callback returns the displaced action for unref" {
    // Re-binding the same (mode, spec, buffer_id) overwrites in place.
    // When the prior action was a `.lua_callback`, the registry must
    // surface its ref back to the caller so the Lua engine can release
    // it; otherwise the ref leaks until process teardown sweeps it up.
    var r = Keymap.Registry.init(std.testing.allocator);
    defer r.deinit();

    const spec = try parseKeySpec("<CR>");
    const first = try r.register(.insert, spec, null, .{ .lua_callback = 100 });
    try std.testing.expectEqual(@as(?Action, null), first.displaced);

    const second = try r.register(.insert, spec, null, .{ .lua_callback = 200 });
    try std.testing.expectEqual(first.id, second.id);
    try std.testing.expect(second.displaced != null);
    try std.testing.expect(second.displaced.? == .lua_callback);
    try std.testing.expectEqual(@as(i32, 100), second.displaced.?.lua_callback);

    // The live binding now points at the new ref.
    const live = r.lookup(.insert, .{ .key = .enter, .modifiers = .{} }, null) orelse
        return error.TestExpected;
    try std.testing.expect(live == .lua_callback);
    try std.testing.expectEqual(@as(i32, 200), live.lua_callback);
}

test "Registry register surfaces IdSpaceExhausted when next_id is at u32 max" {
    // Synthetic exhaustion: the registry counter is u32, so 4B fresh
    // registrations are infeasible to drive in a unit test. Pin
    // `next_id` to `maxInt(u32)` directly via the `Registry` struct
    // field, then assert that the next fresh insert returns
    // `error.IdSpaceExhausted` and leaves `next_id` unchanged so the
    // registry stays internally consistent.
    var r = Keymap.Registry.init(std.testing.allocator);
    defer r.deinit();

    r.next_id = std.math.maxInt(u32);
    const before = r.next_id;
    const result = r.register(.normal, try parseKeySpec("z"), null, .focus_left);
    try std.testing.expectError(error.IdSpaceExhausted, result);
    try std.testing.expectEqual(before, r.next_id);
    try std.testing.expectEqual(@as(usize, 0), r.bindings.items.len);
}

test "registry lookup skips Pass 1 entirely when focused_buffer_id is null" {
    // Invariant: with no global binding registered, a keystroke whose only
    // matches are buffer-local (to *any* buffer) must not fire when no
    // buffer is focused. Pass 1 is keyed on `focused_buffer_id` and must
    // be skipped, not short-circuited to the first buffer-local match.
    var r = Keymap.Registry.init(std.testing.allocator);
    defer r.deinit();
    const spec: KeySpec = .{ .key = .{ .char = 'j' }, .modifiers = .{} };
    _ = try r.register(.normal, spec, 42, .focus_down);
    _ = try r.register(.normal, spec, 43, .focus_up);

    const ev: input.KeyEvent = .{ .key = .{ .char = 'j' }, .modifiers = .{} };
    try std.testing.expectEqual(@as(?Action, null), r.lookup(.normal, ev, null));
}
