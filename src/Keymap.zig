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
/// keys to these by name.
pub const Action = enum {
    focus_left,
    focus_down,
    focus_up,
    focus_right,
    split_vertical,
    split_horizontal,
    close_window,
    enter_insert_mode,
    enter_normal_mode,
};

/// Map a Lua-facing action name to an Action. Returns null for unknown.
pub fn parseActionName(name: []const u8) ?Action {
    const table = [_]struct { []const u8, Action }{
        .{ "focus_left", .focus_left },
        .{ "focus_down", .focus_down },
        .{ "focus_up", .focus_up },
        .{ "focus_right", .focus_right },
        .{ "split_vertical", .split_vertical },
        .{ "split_horizontal", .split_horizontal },
        .{ "close_window", .close_window },
        .{ "enter_insert_mode", .enter_insert_mode },
        .{ "enter_normal_mode", .enter_normal_mode },
    };
    for (table) |e| {
        if (std.mem.eql(u8, e[0], name)) return e[1];
    }
    return null;
}

/// A specification of a keystroke: a Key variant + modifier flags.
/// Matches the shape emitted by input.parseBytes for real keypresses.
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
    };
    for (named_table) |e| {
        if (std.ascii.eqlIgnoreCase(e[0], rest)) {
            return .{ .key = e[1], .modifiers = modifiers };
        }
    }

    // Fallback: a single codepoint inside the angle brackets (e.g. "<C-a>").
    var it = (std.unicode.Utf8View.init(rest) catch return error.InvalidKeySpec).iterator();
    const cp = it.nextCodepoint() orelse return error.InvalidKeySpec;
    if (it.nextCodepoint() != null) return error.InvalidKeySpec;
    return .{ .key = .{ .char = cp }, .modifiers = modifiers };
}

/// A single (mode, key-spec) -> action entry stored in the registry.
pub const Binding = struct {
    mode: Mode,
    spec: KeySpec,
    action: Action,
};

/// Mutable map of (Mode, KeySpec) -> Action. Linear scan: small N, no
/// hashing of the tagged-union key needed.
pub const Registry = struct {
    allocator: Allocator,
    bindings: std.ArrayList(Binding),

    pub fn init(allocator: Allocator) Registry {
        return .{ .allocator = allocator, .bindings = .empty };
    }

    pub fn deinit(self: *Registry) void {
        self.bindings.deinit(self.allocator);
    }

    /// Register (or overwrite) a binding. If a binding already exists
    /// for (mode, spec) its action is replaced so user config can
    /// remap defaults.
    pub fn register(self: *Registry, mode: Mode, spec: KeySpec, action: Action) !void {
        for (self.bindings.items) |*b| {
            if (b.mode == mode and b.spec.eql(spec)) {
                b.action = action;
                return;
            }
        }
        try self.bindings.append(
            self.allocator,
            .{ .mode = mode, .spec = spec, .action = action },
        );
    }

    /// Find the action bound to (mode, event). Returns null if nothing matches.
    pub fn lookup(self: *const Registry, mode: Mode, event: input.KeyEvent) ?Action {
        const target: KeySpec = .{ .key = event.key, .modifiers = event.modifiers };
        for (self.bindings.items) |b| {
            if (b.mode == mode and b.spec.eql(target)) return b.action;
        }
        return null;
    }

    /// Install the built-in default bindings.
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
        };
        for (defaults) |d| {
            const spec = try parseKeySpec(d[1]);
            try self.register(d[0], spec, d[2]);
        }
    }
};

test {
    _ = @import("std").testing.refAllDecls(@This());
}

test "Mode enum has two variants" {
    try std.testing.expectEqual(@as(usize, 2), @typeInfo(Mode).@"enum".fields.len);
}

test "Action enum covers the built-in action names" {
    // Checks the count; the string mapping is covered in Task 3.
    try std.testing.expectEqual(@as(usize, 9), @typeInfo(Action).@"enum".fields.len);
}

test "parseActionName maps known and rejects unknown" {
    try std.testing.expectEqual(Action.focus_left, parseActionName("focus_left").?);
    try std.testing.expectEqual(Action.split_vertical, parseActionName("split_vertical").?);
    try std.testing.expectEqual(Action.enter_normal_mode, parseActionName("enter_normal_mode").?);
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

    try r.register(.normal, try parseKeySpec("h"), .focus_left);
    try r.register(.normal, try parseKeySpec("<C-q>"), .close_window);

    const ev_h: input.KeyEvent = .{ .key = .{ .char = 'h' }, .modifiers = .{} };
    try std.testing.expectEqual(Action.focus_left, r.lookup(.normal, ev_h).?);

    const ev_ctrl_q: input.KeyEvent = .{
        .key = .{ .char = 'q' },
        .modifiers = .{ .ctrl = true },
    };
    try std.testing.expectEqual(Action.close_window, r.lookup(.normal, ev_ctrl_q).?);

    try std.testing.expect(r.lookup(.insert, ev_h) == null);
    try std.testing.expect(r.lookup(.normal, .{ .key = .{ .char = 'z' }, .modifiers = .{} }) == null);
}

test "Registry re-register overwrites" {
    var r = Keymap.Registry.init(std.testing.allocator);
    defer r.deinit();

    const spec = try parseKeySpec("q");
    try r.register(.normal, spec, .close_window);
    try r.register(.normal, spec, .enter_insert_mode);

    try std.testing.expectEqual(
        Action.enter_insert_mode,
        r.lookup(.normal, .{ .key = .{ .char = 'q' }, .modifiers = .{} }).?,
    );
}

test "loadDefaults installs the nine built-in bindings" {
    var r = Keymap.Registry.init(std.testing.allocator);
    defer r.deinit();
    try r.loadDefaults();

    try std.testing.expectEqual(Action.focus_left, r.lookup(.normal, .{ .key = .{ .char = 'h' }, .modifiers = .{} }).?);
    try std.testing.expectEqual(Action.split_vertical, r.lookup(.normal, .{ .key = .{ .char = 'v' }, .modifiers = .{} }).?);
    try std.testing.expectEqual(Action.enter_normal_mode, r.lookup(.insert, .{ .key = .escape, .modifiers = .{} }).?);
    try std.testing.expectEqual(Action.enter_insert_mode, r.lookup(.normal, .{ .key = .{ .char = 'i' }, .modifiers = .{} }).?);
}
