//! zag.layout and zag.pane Lua bindings.
//!
//! Extracted from LuaEngine.zig. Two sibling subtables on the `zag`
//! table:
//!
//!   * `zag.layout`: window-tree inspection and mutation (tree, focus,
//!     split, close, resize) plus the float surface (float, float_move,
//!     float_raise, floats). Requires a live `WindowManager`; headless
//!     runs leave the field null and these bindings raise a clean Lua
//!     error.
//!   * `zag.pane`: per-pane primitives (read, set_model, current_model,
//!     set_draft, get_draft, replace_draft_range). Mirrors the
//!     `pane_read` tool and the `/model` command's swap pathway.
//!
//! Both families share the `requireLayoutHandle` helper which parses
//! the `"n<u32>"` id string into a `NodeRegistry.Handle` and raises a
//! pointed Lua error on bad input.

const std = @import("std");
const zlua = @import("zlua");
const Lua = zlua.Lua;
const LuaEngine = @import("../../LuaEngine.zig").LuaEngine;
const BufferRegistry = @import("../../BufferRegistry.zig");
const Layout = @import("../../Layout.zig");
const NodeRegistry = @import("../../NodeRegistry.zig");
const WindowManager = @import("../../WindowManager.zig");
const lua_json = @import("../lua_json.zig");

/// `zag.layout.tree()`: return the live window tree as a Lua table
/// mirroring the WindowManager describe output.
fn zagLayoutTreeFn(lua: *Lua) i32 {
    const engine = LuaEngine.getEngineFromState(lua);
    const wm = engine.window_manager orelse {
        lua.raiseErrorStr("zag.layout.tree: no window manager bound", .{});
    };
    const bytes = wm.describe(engine.allocator) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "zag.layout.tree: describe failed: {s}", .{@errorName(err)}) catch "zag.layout.tree: describe failed";
        lua.raiseErrorStr("%s", .{msg.ptr});
    };
    defer engine.allocator.free(bytes);
    lua_json.pushJsonAsTable(lua, bytes, engine.allocator) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "zag.layout.tree: decode failed: {s}", .{@errorName(err)}) catch "zag.layout.tree: decode failed";
        lua.raiseErrorStr("%s", .{msg.ptr});
    };
    return 1;
}

/// Parse the id string on top of the Lua stack at `arg_index` and
/// resolve it into a NodeRegistry.Handle. Raises a Lua error with
/// `op_name` prefixed on bad input. Shared by all zag.layout bindings.
fn requireLayoutHandle(lua: *Lua, arg_index: i32, comptime op_name: []const u8) NodeRegistry.Handle {
    if (lua.typeOf(arg_index) != .string) {
        lua.raiseErrorStr(op_name ++ ": id must be a string", .{});
    }
    const id = lua.toString(arg_index) catch {
        lua.raiseErrorStr(op_name ++ ": id must be a string", .{});
    };
    return NodeRegistry.parseId(id) catch {
        lua.raiseErrorStr(op_name ++ ": invalid id", .{});
    };
}

/// `zag.layout.focus(id)`: move focus to the leaf identified by `id`.
fn zagLayoutFocusFn(lua: *Lua) i32 {
    const engine = LuaEngine.getEngineFromState(lua);
    const wm = engine.window_manager orelse {
        lua.raiseErrorStr("zag.layout.focus: no window manager bound", .{});
    };
    const handle = requireLayoutHandle(lua, 1, "zag.layout.focus");
    wm.focusById(handle) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "zag.layout.focus: {s}", .{@errorName(err)}) catch "zag.layout.focus failed";
        lua.raiseErrorStr("%s", .{msg.ptr});
    };
    return 0;
}

/// `zag.layout.split(id, direction, opts?)`: split the leaf
/// identified by `id` along `direction` ("horizontal" or "vertical")
/// and return the new leaf's id string.
///
/// `opts.buffer` picks the buffer the new pane shows. Two forms:
///   * `{ type = "conversation" }`: fresh conversation buffer (the
///     default when `opts.buffer` is omitted). Other `type` values
///     are rejected.
///   * `"b<u32>"`: an opaque `BufferRegistry` handle string. The new
///     pane borrows that buffer by pointer; the registry keeps it
///     alive.
fn zagLayoutSplitFn(lua: *Lua) i32 {
    const engine = LuaEngine.getEngineFromState(lua);
    const wm = engine.window_manager orelse {
        lua.raiseErrorStr("zag.layout.split: no window manager bound", .{});
    };
    const handle = requireLayoutHandle(lua, 1, "zag.layout.split");
    if (lua.typeOf(2) != .string) {
        lua.raiseErrorStr("zag.layout.split: direction must be a string", .{});
    }
    const dir = lua.toString(2) catch {
        lua.raiseErrorStr("zag.layout.split: direction must be a string", .{});
    };
    const direction: Layout.SplitDirection = if (std.mem.eql(u8, dir, "vertical"))
        .vertical
    else if (std.mem.eql(u8, dir, "horizontal"))
        .horizontal
    else {
        lua.raiseErrorStr("zag.layout.split: direction must be \"horizontal\" or \"vertical\"", .{});
    };

    // Optional opts table at arg 3: `{ buffer = <selector> }`. The
    // selector is either a table (legacy `{ type = "conversation" }`)
    // or a string (`"b<u32>"` handle). Anything else raises so the
    // caller sees the failure on the first call, not later when the
    // pane shows up empty.
    var attached: ?WindowManager.AttachedSurface = null;
    if (lua.isTable(3)) {
        _ = lua.getField(3, "buffer");
        defer lua.pop(1);
        switch (lua.typeOf(-1)) {
            .nil, .none => {},
            .string => {
                const raw = lua.toString(-1) catch {
                    lua.raiseErrorStr("zag.layout.split: buffer handle must be a string", .{});
                };
                const bh = BufferRegistry.parseId(raw) catch {
                    lua.raiseErrorStr("zag.layout.split: invalid buffer handle", .{});
                };
                const buffer_registry = engine.buffer_registry orelse {
                    lua.raiseErrorStr("zag.layout.split: no buffer registry bound", .{});
                };
                const resolved_buffer = buffer_registry.asBuffer(bh) catch {
                    lua.raiseErrorStr("zag.layout.split: stale buffer handle", .{});
                };
                const resolved_view = buffer_registry.asView(bh) catch {
                    lua.raiseErrorStr("zag.layout.split: stale buffer handle", .{});
                };
                attached = .{ .buffer = resolved_buffer, .view = resolved_view };
            },
            .table => {
                _ = lua.getField(-1, "type");
                defer lua.pop(1);
                if (!lua.isNil(-1)) {
                    const bt = lua.toString(-1) catch {
                        lua.raiseErrorStr("zag.layout.split: buffer.type must be a string", .{});
                    };
                    if (!std.mem.eql(u8, bt, "conversation")) {
                        lua.raiseErrorStr("zag.layout.split: buffer.type not yet supported", .{});
                    }
                }
            },
            else => {
                lua.raiseErrorStr("zag.layout.split: buffer must be a table or handle string", .{});
            },
        }
    }

    const new_handle = wm.splitById(handle, direction, attached) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "zag.layout.split: {s}", .{@errorName(err)}) catch "zag.layout.split failed";
        lua.raiseErrorStr("%s", .{msg.ptr});
    };
    const new_id = NodeRegistry.formatId(engine.allocator, new_handle) catch {
        lua.raiseErrorStr("zag.layout.split: id format failed", .{});
    };
    defer engine.allocator.free(new_id);
    _ = lua.pushString(new_id);
    return 1;
}

/// `zag.layout.close(id)`: close the leaf or float identified by
/// `id`. Plugin-level calls run on the main thread as user code, so
/// they bypass the caller-pane guard (no caller pane exists here).
/// `closeById` routes float handles internally so this dispatcher
/// is namespace-agnostic.
fn zagLayoutCloseFn(lua: *Lua) i32 {
    const engine = LuaEngine.getEngineFromState(lua);
    const wm = engine.window_manager orelse {
        lua.raiseErrorStr("zag.layout.close: no window manager bound", .{});
    };
    const handle = requireLayoutHandle(lua, 1, "zag.layout.close");
    wm.closeById(handle, null) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "zag.layout.close: {s}", .{@errorName(err)}) catch "zag.layout.close failed";
        lua.raiseErrorStr("%s", .{msg.ptr});
    };
    return 0;
}

/// `zag.layout.float(buffer_handle, opts)`: open a floating pane
/// over the tiled tree. Returns the float's stable handle string.
///
/// Required opts:
///   * `relative = "editor" | "cursor"` (slice 2; "win"/"mouse"/...
///     deferred to slice 3)
///   * `row`, `col` (integers; offsets from the resolved anchor)
/// Optional opts:
///   * `width`, `height` (explicit size; integers)
///   * `min_width`, `max_width`, `min_height`, `max_height`
///     (size-to-content bounds; ignored when width/height is set)
///   * `corner` ("NW" | "NE" | "SW" | "SE"; default "NW")
///   * `border` ("none" | "square" | "rounded"; default "rounded")
///   * `title` (string)
///   * `zindex` (integer; default 50)
///   * `focusable` (bool; default true)
///   * `mouse` (bool; default true)
///   * `enter` (bool; default true)
fn zagLayoutFloatFn(lua: *Lua) i32 {
    const engine = LuaEngine.getEngineFromState(lua);
    const wm = engine.window_manager orelse {
        lua.raiseErrorStr("zag.layout.float: no window manager bound", .{});
    };

    // Arg 1: buffer handle string. Slice 1 only borrows registered
    // buffers (the picker pattern); a future variant will accept a
    // table { type = "conversation" } like split does.
    if (lua.typeOf(1) != .string) {
        lua.raiseErrorStr("zag.layout.float: buffer handle must be a string", .{});
    }
    const raw_handle = lua.toString(1) catch {
        lua.raiseErrorStr("zag.layout.float: buffer handle must be a string", .{});
    };
    const bh = BufferRegistry.parseId(raw_handle) catch {
        lua.raiseErrorStr("zag.layout.float: invalid buffer handle", .{});
    };
    const buffer_registry = engine.buffer_registry orelse {
        lua.raiseErrorStr("zag.layout.float: no buffer registry bound", .{});
    };
    const buffer = buffer_registry.asBuffer(bh) catch {
        lua.raiseErrorStr("zag.layout.float: stale buffer handle", .{});
    };
    const buffer_view = buffer_registry.asView(bh) catch {
        lua.raiseErrorStr("zag.layout.float: stale buffer handle", .{});
    };

    // Arg 2: options table. Required since at minimum we need
    // `relative` + `row`/`col` (offsets) to anchor the float.
    if (!lua.isTable(2)) {
        lua.raiseErrorStr("zag.layout.float: opts must be a table", .{});
    }

    // `relative`: slice 2 accepts "editor" and "cursor". Each
    // field read pops immediately so the stack stays clean and the
    // final `pushString(id)` is the unambiguous top.
    _ = lua.getField(2, "relative");
    if (lua.typeOf(-1) != .string) {
        lua.raiseErrorStr("zag.layout.float: relative must be a string", .{});
    }
    const relative = lua.toString(-1) catch {
        lua.raiseErrorStr("zag.layout.float: relative must be a string", .{});
    };
    var anchor: Layout.FloatAnchor = .editor;
    if (std.mem.eql(u8, relative, "editor")) {
        anchor = .editor;
    } else if (std.mem.eql(u8, relative, "cursor")) {
        anchor = .cursor;
    } else if (std.mem.eql(u8, relative, "win")) {
        anchor = .win;
    } else if (std.mem.eql(u8, relative, "mouse")) {
        anchor = .mouse;
    } else if (std.mem.eql(u8, relative, "laststatus")) {
        anchor = .laststatus;
    } else if (std.mem.eql(u8, relative, "tabline")) {
        anchor = .tabline;
    } else {
        lua.raiseErrorStr("zag.layout.float: relative must be \"editor\" | \"cursor\" | \"win\" | \"mouse\" | \"laststatus\" | \"tabline\"", .{});
    }
    lua.pop(1);

    // Optional `win` (only meaningful with relative = "win"): the
    // `n<u32>` handle string of the window the float anchors to.
    // Stored as the FloatConfig.relative_to field; null falls
    // through to editor in resolveAnchor.
    var relative_to: ?NodeRegistry.Handle = null;
    _ = lua.getField(2, "win");
    switch (lua.typeOf(-1)) {
        .nil, .none => {},
        .string => {
            const handle = lua.toString(-1) catch {
                lua.raiseErrorStr("zag.layout.float: win must be a handle string", .{});
            };
            relative_to = NodeRegistry.parseId(handle) catch {
                lua.raiseErrorStr("zag.layout.float: invalid win handle", .{});
            };
        },
        else => {
            lua.raiseErrorStr("zag.layout.float: win must be a handle string", .{});
        },
    }
    lua.pop(1);

    // Optional `bufpos = { line, col }` (only meaningful with
    // relative = "win"). Read both ints and stash as a [2]i32 on
    // FloatConfig; the resolver translates through the win's
    // scroll offset. An out-of-range bufpos collapses the float
    // to a 0-cell rect (it's hidden until the position scrolls
    // back into view).
    var bufpos: ?[2]i32 = null;
    _ = lua.getField(2, "bufpos");
    switch (lua.typeOf(-1)) {
        .nil, .none => {},
        .table => {
            _ = lua.rawGetIndex(-1, 1);
            if (lua.typeOf(-1) != .number) {
                lua.raiseErrorStr("zag.layout.float: bufpos[1] (line) must be an integer", .{});
            }
            const line = lua.toInteger(-1) catch {
                lua.raiseErrorStr("zag.layout.float: bufpos[1] (line) must be an integer", .{});
            };
            lua.pop(1);
            _ = lua.rawGetIndex(-1, 2);
            if (lua.typeOf(-1) != .number) {
                lua.raiseErrorStr("zag.layout.float: bufpos[2] (col) must be an integer", .{});
            }
            const col = lua.toInteger(-1) catch {
                lua.raiseErrorStr("zag.layout.float: bufpos[2] (col) must be an integer", .{});
            };
            lua.pop(1);
            if (line < std.math.minInt(i32) or line > std.math.maxInt(i32) or
                col < std.math.minInt(i32) or col > std.math.maxInt(i32))
            {
                lua.raiseErrorStr("zag.layout.float: bufpos out of i32 range", .{});
            }
            bufpos = .{ @intCast(line), @intCast(col) };
        },
        else => {
            lua.raiseErrorStr("zag.layout.float: bufpos must be a table {line, col}", .{});
        },
    }
    lua.pop(1);

    const row_offset = readI32Field(lua, 2, "row", "zag.layout.float");
    const col_offset = readI32Field(lua, 2, "col", "zag.layout.float");

    const width_opt = readOptionalU16Field(lua, 2, "width", "zag.layout.float");
    const height_opt = readOptionalU16Field(lua, 2, "height", "zag.layout.float");

    const min_width = readOptionalU16Field(lua, 2, "min_width", "zag.layout.float");
    const max_width = readOptionalU16Field(lua, 2, "max_width", "zag.layout.float");
    const min_height = readOptionalU16Field(lua, 2, "min_height", "zag.layout.float");
    const max_height = readOptionalU16Field(lua, 2, "max_height", "zag.layout.float");

    // Float must have *some* way to determine its size. Either an
    // explicit dimension or a min/max pair. Otherwise the float
    // ends up at width=0 / height=0 and disappears, which is hard
    // to debug from a test plugin.
    if (width_opt == null and min_width == null and max_width == null) {
        lua.raiseErrorStr("zag.layout.float: width or min_width/max_width is required", .{});
    }
    if (height_opt == null and min_height == null and max_height == null) {
        lua.raiseErrorStr("zag.layout.float: height or min_height/max_height is required", .{});
    }

    var corner: Layout.FloatCorner = .NW;
    _ = lua.getField(2, "corner");
    switch (lua.typeOf(-1)) {
        .nil, .none => {},
        .string => {
            const s = lua.toString(-1) catch {
                lua.raiseErrorStr("zag.layout.float: corner must be a string", .{});
            };
            if (std.mem.eql(u8, s, "NW")) {
                corner = .NW;
            } else if (std.mem.eql(u8, s, "NE")) {
                corner = .NE;
            } else if (std.mem.eql(u8, s, "SW")) {
                corner = .SW;
            } else if (std.mem.eql(u8, s, "SE")) {
                corner = .SE;
            } else {
                lua.raiseErrorStr("zag.layout.float: corner must be \"NW\" | \"NE\" | \"SW\" | \"SE\"", .{});
            }
        },
        else => {
            lua.raiseErrorStr("zag.layout.float: corner must be a string", .{});
        },
    }
    lua.pop(1);

    var border_kind: Layout.FloatBorder = .rounded;
    _ = lua.getField(2, "border");
    switch (lua.typeOf(-1)) {
        .nil, .none => {},
        .string => {
            const s = lua.toString(-1) catch {
                lua.raiseErrorStr("zag.layout.float: border must be a string", .{});
            };
            if (std.mem.eql(u8, s, "none")) {
                border_kind = .none;
            } else if (std.mem.eql(u8, s, "square")) {
                border_kind = .square;
            } else if (std.mem.eql(u8, s, "rounded")) {
                border_kind = .rounded;
            } else {
                lua.raiseErrorStr("zag.layout.float: border must be \"none\" | \"square\" | \"rounded\"", .{});
            }
        },
        else => {
            lua.raiseErrorStr("zag.layout.float: border must be a string", .{});
        },
    }
    lua.pop(1);

    // Title bytes live in the Lua string interner: pop only after
    // openFloatPane has handed them to Layout (which dupes the
    // bytes onto its own allocator).
    var title_owned: ?[]const u8 = null;
    _ = lua.getField(2, "title");
    switch (lua.typeOf(-1)) {
        .nil, .none => {},
        .string => {
            const s = lua.toString(-1) catch {
                lua.raiseErrorStr("zag.layout.float: title must be a string", .{});
            };
            title_owned = s;
        },
        else => {
            lua.raiseErrorStr("zag.layout.float: title must be a string", .{});
        },
    }

    var z: u32 = 50;
    _ = lua.getField(2, "zindex");
    switch (lua.typeOf(-1)) {
        .nil, .none => {},
        .number => {
            const n = lua.toInteger(-1) catch {
                lua.raiseErrorStr("zag.layout.float: zindex must be an integer", .{});
            };
            if (n < 0) {
                lua.raiseErrorStr("zag.layout.float: zindex must be >= 0", .{});
            }
            z = @intCast(n);
        },
        else => {
            lua.raiseErrorStr("zag.layout.float: zindex must be an integer", .{});
        },
    }
    lua.pop(1);

    const focusable = readOptionalBoolField(lua, 2, "focusable", "zag.layout.float") orelse true;
    const mouse_flag = readOptionalBoolField(lua, 2, "mouse", "zag.layout.float") orelse true;
    const enter = readOptionalBoolField(lua, 2, "enter", "zag.layout.float") orelse true;

    // `time = N` (ms): auto-close the float after N milliseconds.
    // Read through the existing optional-u32 path; Lua integers
    // exceeding u32 raise.
    var auto_close_ms: ?u32 = null;
    _ = lua.getField(2, "time");
    switch (lua.typeOf(-1)) {
        .nil, .none => {},
        .number => {
            const n = lua.toInteger(-1) catch {
                lua.raiseErrorStr("zag.layout.float: time must be an integer", .{});
            };
            if (n < 0) {
                lua.raiseErrorStr("zag.layout.float: time must be >= 0", .{});
            }
            if (n > std.math.maxInt(u32)) {
                lua.raiseErrorStr("zag.layout.float: time exceeds u32 range", .{});
            }
            auto_close_ms = @intCast(n);
        },
        else => lua.raiseErrorStr("zag.layout.float: time must be an integer", .{}),
    }
    lua.pop(1);

    // `moved = "any"`: close the float as soon as the focused
    // pane's draft length differs from the snapshot taken at open
    // time. Other strings are reserved for future Vim-style
    // movement granularities (e.g. "word", "char") and currently
    // raise so plugins fail loud rather than silently.
    var close_on_cursor_moved = false;
    _ = lua.getField(2, "moved");
    switch (lua.typeOf(-1)) {
        .nil, .none => {},
        .string => {
            const s = lua.toString(-1) catch {
                lua.raiseErrorStr("zag.layout.float: moved must be a string", .{});
            };
            if (std.mem.eql(u8, s, "any")) {
                close_on_cursor_moved = true;
            } else {
                lua.raiseErrorStr("zag.layout.float: moved must be \"any\"", .{});
            }
        },
        else => lua.raiseErrorStr("zag.layout.float: moved must be a string", .{}),
    }
    lua.pop(1);

    // `on_close` and `on_key` are Lua functions stored in the
    // registry; the i32 slot id travels through FloatConfig.
    // closeFloatById invokes (close) and unrefs both. Fail-fast
    // if any but the function-or-nil pattern is supplied so a
    // misconfigured opts table never leaks a ref into the
    // registry.
    var on_close_ref: ?i32 = null;
    _ = lua.getField(2, "on_close");
    switch (lua.typeOf(-1)) {
        .nil, .none => lua.pop(1),
        .function => {
            on_close_ref = lua.ref(zlua.registry_index) catch {
                lua.raiseErrorStr("zag.layout.float: on_close ref alloc failed", .{});
            };
        },
        else => {
            lua.pop(1);
            lua.raiseErrorStr("zag.layout.float: on_close must be a function", .{});
        },
    }
    // Free on_close ref on any subsequent failure path so we never
    // leak a registry slot from this binding. errdefer cannot run
    // through `lua.raiseErrorStr` (longjmp-style escape), so we
    // chain the cleanup manually below.
    var on_key_ref: ?i32 = null;
    _ = lua.getField(2, "on_key");
    switch (lua.typeOf(-1)) {
        .nil, .none => lua.pop(1),
        .function => {
            on_key_ref = lua.ref(zlua.registry_index) catch {
                if (on_close_ref) |r| lua.unref(zlua.registry_index, r);
                lua.raiseErrorStr("zag.layout.float: on_key ref alloc failed", .{});
            };
        },
        else => {
            lua.pop(1);
            if (on_close_ref) |r| lua.unref(zlua.registry_index, r);
            lua.raiseErrorStr("zag.layout.float: on_key must be a function", .{});
        },
    }

    // Seed rect: openFloatPane needs *some* rect for the FloatNode
    // until `recalculateFloats` runs against the live screen. Use
    // explicit width/height when given; otherwise fall back to
    // min_* (or 1) so the seed clamps to a positive cell.
    const seed_w: u16 = width_opt orelse (min_width orelse 1);
    const seed_h: u16 = height_opt orelse (min_height orelse 1);

    const handle = wm.openFloatPane(
        .{ .buffer = buffer, .view = buffer_view },
        .{ .x = 0, .y = 0, .width = seed_w, .height = seed_h },
        .{
            .border = border_kind,
            .title = title_owned,
            .z = z,
            .focusable = focusable,
            .mouse = mouse_flag,
            .enter = enter,
            .relative = anchor,
            .relative_to = relative_to,
            .bufpos = bufpos,
            .corner = corner,
            .row_offset = row_offset,
            .col_offset = col_offset,
            .width = width_opt,
            .height = height_opt,
            .min_width = min_width,
            .max_width = max_width,
            .min_height = min_height,
            .max_height = max_height,
            .auto_close_ms = auto_close_ms,
            .close_on_cursor_moved = close_on_cursor_moved,
            .on_close_ref = on_close_ref,
            .on_key_ref = on_key_ref,
        },
    ) catch |err| {
        lua.pop(1); // title
        // openFloatPane failed before taking ownership of the
        // refs; release them so we don't leak Lua registry
        // slots. The float never existed, so nothing else will
        // do this for us.
        if (on_close_ref) |r| lua.unref(zlua.registry_index, r);
        if (on_key_ref) |r| lua.unref(zlua.registry_index, r);
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "zag.layout.float: {s}", .{@errorName(err)}) catch "zag.layout.float failed";
        lua.raiseErrorStr("%s", .{msg.ptr});
    };
    // Title bytes are now owned by the FloatNode (Layout.addFloat
    // duped them); release the borrowed Lua slice.
    lua.pop(1);

    const id = NodeRegistry.formatId(engine.allocator, handle) catch {
        lua.raiseErrorStr("zag.layout.float: id format failed", .{});
    };
    defer engine.allocator.free(id);
    _ = lua.pushString(id);
    return 1;
}

/// `zag.layout.float_move(handle, opts)`: patch a live float's
/// geometry without re-creating it. Accepts a partial opts table
/// with any of `row`, `col`, `width`, `height`, `corner`, `zindex`.
/// Triggers a `recalculateFloats` next frame.
fn zagLayoutFloatMoveFn(lua: *Lua) i32 {
    const engine = LuaEngine.getEngineFromState(lua);
    const wm = engine.window_manager orelse {
        lua.raiseErrorStr("zag.layout.float_move: no window manager bound", .{});
    };
    const handle = requireLayoutHandle(lua, 1, "zag.layout.float_move");
    if (!lua.isTable(2)) {
        lua.raiseErrorStr("zag.layout.float_move: opts must be a table", .{});
    }

    var patch: Layout.FloatMovePatch = .{};
    // row / col map onto the float's row_offset / col_offset; this
    // matches the `zag.layout.float` opts shape so float_move and
    // float share field names.
    _ = lua.getField(2, "row");
    switch (lua.typeOf(-1)) {
        .nil, .none => {},
        .number => {
            const n = lua.toInteger(-1) catch {
                lua.raiseErrorStr("zag.layout.float_move: row must be an integer", .{});
            };
            if (n < std.math.minInt(i32) or n > std.math.maxInt(i32)) {
                lua.raiseErrorStr("zag.layout.float_move: row out of i32 range", .{});
            }
            patch.row_offset = @intCast(n);
        },
        else => lua.raiseErrorStr("zag.layout.float_move: row must be an integer", .{}),
    }
    lua.pop(1);

    _ = lua.getField(2, "col");
    switch (lua.typeOf(-1)) {
        .nil, .none => {},
        .number => {
            const n = lua.toInteger(-1) catch {
                lua.raiseErrorStr("zag.layout.float_move: col must be an integer", .{});
            };
            if (n < std.math.minInt(i32) or n > std.math.maxInt(i32)) {
                lua.raiseErrorStr("zag.layout.float_move: col out of i32 range", .{});
            }
            patch.col_offset = @intCast(n);
        },
        else => lua.raiseErrorStr("zag.layout.float_move: col must be an integer", .{}),
    }
    lua.pop(1);

    patch.width = readOptionalU16Field(lua, 2, "width", "zag.layout.float_move");
    patch.height = readOptionalU16Field(lua, 2, "height", "zag.layout.float_move");

    _ = lua.getField(2, "corner");
    switch (lua.typeOf(-1)) {
        .nil, .none => {},
        .string => {
            const s = lua.toString(-1) catch {
                lua.raiseErrorStr("zag.layout.float_move: corner must be a string", .{});
            };
            if (std.mem.eql(u8, s, "NW")) {
                patch.corner = .NW;
            } else if (std.mem.eql(u8, s, "NE")) {
                patch.corner = .NE;
            } else if (std.mem.eql(u8, s, "SW")) {
                patch.corner = .SW;
            } else if (std.mem.eql(u8, s, "SE")) {
                patch.corner = .SE;
            } else {
                lua.raiseErrorStr("zag.layout.float_move: corner must be \"NW\" | \"NE\" | \"SW\" | \"SE\"", .{});
            }
        },
        else => lua.raiseErrorStr("zag.layout.float_move: corner must be a string", .{}),
    }
    lua.pop(1);

    _ = lua.getField(2, "zindex");
    switch (lua.typeOf(-1)) {
        .nil, .none => {},
        .number => {
            const n = lua.toInteger(-1) catch {
                lua.raiseErrorStr("zag.layout.float_move: zindex must be an integer", .{});
            };
            if (n < 0 or n > std.math.maxInt(u32)) {
                lua.raiseErrorStr("zag.layout.float_move: zindex out of u32 range", .{});
            }
            patch.z = @intCast(n);
        },
        else => lua.raiseErrorStr("zag.layout.float_move: zindex must be an integer", .{}),
    }
    lua.pop(1);

    wm.floatMove(handle, patch) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "zag.layout.float_move: {s}", .{@errorName(err)}) catch "zag.layout.float_move failed";
        lua.raiseErrorStr("%s", .{msg.ptr});
    };
    return 0;
}

/// `zag.layout.float_raise(handle)`: bump the float to the top of
/// the z-stack so subsequent frames paint it above every other
/// float.
fn zagLayoutFloatRaiseFn(lua: *Lua) i32 {
    const engine = LuaEngine.getEngineFromState(lua);
    const wm = engine.window_manager orelse {
        lua.raiseErrorStr("zag.layout.float_raise: no window manager bound", .{});
    };
    const handle = requireLayoutHandle(lua, 1, "zag.layout.float_raise");
    wm.floatRaise(handle) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "zag.layout.float_raise: {s}", .{@errorName(err)}) catch "zag.layout.float_raise failed";
        lua.raiseErrorStr("%s", .{msg.ptr});
    };
    return 0;
}

/// `zag.layout.floats() -> { handle, ... }`: return a Lua
/// array of `n<u32>` handle strings for every live float, in
/// ascending z order.
fn zagLayoutFloatsFn(lua: *Lua) i32 {
    const engine = LuaEngine.getEngineFromState(lua);
    const wm = engine.window_manager orelse {
        lua.raiseErrorStr("zag.layout.floats: no window manager bound", .{});
    };

    // Real layouts hold a handful of floats; a 64-entry stack
    // buffer matches the orchestrator's per-frame caps and avoids
    // a heap allocation for the common case.
    var handles: [64]NodeRegistry.Handle = undefined;
    const slice = wm.floatsList(&handles);

    lua.createTable(@intCast(slice.len), 0);
    for (slice, 0..) |h, i| {
        const id = NodeRegistry.formatId(engine.allocator, h) catch {
            lua.raiseErrorStr("zag.layout.floats: id format failed", .{});
        };
        defer engine.allocator.free(id);
        _ = lua.pushString(id);
        lua.setIndex(-2, @intCast(i + 1));
    }
    return 1;
}

/// Read an optional u16 from a Lua table; returns null when the
/// field is nil/missing. Pops the field after read.
fn readOptionalU16Field(lua: *Lua, tbl: i32, comptime name: [:0]const u8, comptime op: []const u8) ?u16 {
    _ = lua.getField(tbl, name);
    defer lua.pop(1);
    switch (lua.typeOf(-1)) {
        .nil, .none => return null,
        .number => {},
        else => lua.raiseErrorStr(op ++ ": " ++ name ++ " must be an integer", .{}),
    }
    const n = lua.toInteger(-1) catch {
        lua.raiseErrorStr(op ++ ": " ++ name ++ " must be an integer", .{});
    };
    if (n < 0) {
        lua.raiseErrorStr(op ++ ": " ++ name ++ " must be >= 0", .{});
    }
    if (n > std.math.maxInt(u16)) {
        lua.raiseErrorStr(op ++ ": " ++ name ++ " exceeds u16 range", .{});
    }
    return @intCast(n);
}

/// Read a signed integer offset (i32). Default zero on missing.
fn readI32Field(lua: *Lua, tbl: i32, comptime name: [:0]const u8, comptime op: []const u8) i32 {
    _ = lua.getField(tbl, name);
    defer lua.pop(1);
    switch (lua.typeOf(-1)) {
        .nil, .none => return 0,
        .number => {},
        else => lua.raiseErrorStr(op ++ ": " ++ name ++ " must be an integer", .{}),
    }
    const n = lua.toInteger(-1) catch {
        lua.raiseErrorStr(op ++ ": " ++ name ++ " must be an integer", .{});
    };
    if (n < std.math.minInt(i32) or n > std.math.maxInt(i32)) {
        lua.raiseErrorStr(op ++ ": " ++ name ++ " exceeds i32 range", .{});
    }
    return @intCast(n);
}

/// Read an optional boolean field. Returns null on nil/missing,
/// the value on bool, raises on anything else.
fn readOptionalBoolField(lua: *Lua, tbl: i32, comptime name: [:0]const u8, comptime op: []const u8) ?bool {
    _ = lua.getField(tbl, name);
    defer lua.pop(1);
    return switch (lua.typeOf(-1)) {
        .nil, .none => null,
        .boolean => lua.toBoolean(-1),
        else => {
            lua.raiseErrorStr(op ++ ": " ++ name ++ " must be a boolean", .{});
        },
    };
}

/// Read an integer field from a Lua table at stack index `tbl`,
/// raising a typed Lua error on miss / non-integer / negative.
/// Shared between the various `zag.layout.float` field readers so
/// the error messages stay uniform. Pops the field after read.
fn readU16Field(lua: *Lua, tbl: i32, comptime name: [:0]const u8, comptime op: []const u8) u16 {
    _ = lua.getField(tbl, name);
    defer lua.pop(1);
    if (lua.typeOf(-1) != .number) {
        lua.raiseErrorStr(op ++ ": " ++ name ++ " must be an integer", .{});
    }
    const n = lua.toInteger(-1) catch {
        lua.raiseErrorStr(op ++ ": " ++ name ++ " must be an integer", .{});
    };
    if (n < 0) {
        lua.raiseErrorStr(op ++ ": " ++ name ++ " must be >= 0", .{});
    }
    if (n > std.math.maxInt(u16)) {
        lua.raiseErrorStr(op ++ ": " ++ name ++ " exceeds u16 range", .{});
    }
    return @intCast(n);
}

/// `zag.layout.resize(id, ratio)`: apply a new split ratio to the
/// split identified by `id`. Non-split handles are rejected by the
/// window manager.
fn zagLayoutResizeFn(lua: *Lua) i32 {
    const engine = LuaEngine.getEngineFromState(lua);
    const wm = engine.window_manager orelse {
        lua.raiseErrorStr("zag.layout.resize: no window manager bound", .{});
    };
    const handle = requireLayoutHandle(lua, 1, "zag.layout.resize");
    if (lua.typeOf(2) != .number) {
        lua.raiseErrorStr("zag.layout.resize: ratio must be a number", .{});
    }
    const ratio_raw = lua.toNumber(2) catch {
        lua.raiseErrorStr("zag.layout.resize: ratio must be a number", .{});
    };
    const ratio: f32 = @floatCast(ratio_raw);
    wm.resizeById(handle, ratio) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "zag.layout.resize: {s}", .{@errorName(err)}) catch "zag.layout.resize failed";
        lua.raiseErrorStr("%s", .{msg.ptr});
    };
    return 0;
}

/// `zag.pane.read(id, lines?)`: return a snapshot of the pane's
/// rendered text as a Lua table `{ ok, text, total_lines, truncated }`,
/// mirroring the `pane_read` tool. `lines` caps the number of lines
/// returned (defaults to the WindowManager default when omitted).
fn zagPaneReadFn(lua: *Lua) i32 {
    const engine = LuaEngine.getEngineFromState(lua);
    const wm = engine.window_manager orelse {
        lua.raiseErrorStr("zag.pane.read: no window manager bound", .{});
    };
    const handle = requireLayoutHandle(lua, 1, "zag.pane.read");

    var lines_opt: ?u32 = null;
    if (!lua.isNoneOrNil(2)) {
        if (lua.typeOf(2) != .number) {
            lua.raiseErrorStr("zag.pane.read: lines must be an integer", .{});
        }
        const n = lua.toInteger(2) catch {
            lua.raiseErrorStr("zag.pane.read: lines must be an integer", .{});
        };
        if (n < 0) {
            lua.raiseErrorStr("zag.pane.read: lines must be non-negative", .{});
        }
        lines_opt = @intCast(n);
    }

    const bytes = wm.readPaneById(engine.allocator, handle, lines_opt, null) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "zag.pane.read: {s}", .{@errorName(err)}) catch "zag.pane.read failed";
        lua.raiseErrorStr("%s", .{msg.ptr});
    };
    defer engine.allocator.free(bytes);
    lua_json.pushJsonAsTable(lua, bytes, engine.allocator) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "zag.pane.read: decode failed: {s}", .{@errorName(err)}) catch "zag.pane.read: decode failed";
        lua.raiseErrorStr("%s", .{msg.ptr});
    };
    return 1;
}

/// `zag.pane.set_model(pane_id, "<provider>/<id>")`: swap the pane's
/// model override. Goes through the same drain/build/persist pipeline
/// the `/model` command triggers, so the call may block briefly while
/// an in-flight agent turn is cancelled.
fn zagPaneSetModelFn(lua: *Lua) i32 {
    const engine = LuaEngine.getEngineFromState(lua);
    const wm = engine.window_manager orelse {
        lua.raiseErrorStr("zag.pane.set_model: no window manager bound", .{});
    };
    const handle = requireLayoutHandle(lua, 1, "zag.pane.set_model");
    if (lua.typeOf(2) != .string) {
        lua.raiseErrorStr("zag.pane.set_model: model must be a string", .{});
    }
    const model_string = lua.toString(2) catch {
        lua.raiseErrorStr("zag.pane.set_model: model must be a string", .{});
    };
    const slash = std.mem.indexOfScalar(u8, model_string, '/') orelse {
        lua.raiseErrorStr("zag.pane.set_model: model must be \"provider/id\"", .{});
    };
    if (slash == 0 or slash == model_string.len - 1) {
        lua.raiseErrorStr("zag.pane.set_model: model must be \"provider/id\"", .{});
    }
    const provider_name = model_string[0..slash];
    const model_id = model_string[slash + 1 ..];
    wm.swapProviderForPane(handle, provider_name, model_id) catch |err| {
        var buf: [160]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "zag.pane.set_model: {s}", .{@errorName(err)}) catch "zag.pane.set_model failed";
        lua.raiseErrorStr("%s", .{msg.ptr});
    };
    return 0;
}

/// `zag.pane.current_model(pane_id)`: return the resolved
/// `"provider/id"` model string the pane is currently using
/// (per-pane override if present, shared default otherwise).
fn zagPaneCurrentModelFn(lua: *Lua) i32 {
    const engine = LuaEngine.getEngineFromState(lua);
    const wm = engine.window_manager orelse {
        lua.raiseErrorStr("zag.pane.current_model: no window manager bound", .{});
    };
    const handle = requireLayoutHandle(lua, 1, "zag.pane.current_model");
    const pane = wm.paneFromHandle(handle) catch |err| {
        var buf: [160]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "zag.pane.current_model: {s}", .{@errorName(err)}) catch "zag.pane.current_model failed";
        lua.raiseErrorStr("%s", .{msg.ptr});
    };
    const resolved = wm.providerFor(pane);
    _ = lua.pushString(resolved.model_id);
    return 1;
}

/// `zag.pane.set_draft(pane_id, text)`: replace the entire in-progress
/// draft of `pane_id` with `text`. Truncates silently to MAX_DRAFT
/// with a warn log (matches `appendPaste`'s policy). Used by
/// autocomplete plugins that drive the draft from Lua.
fn zagPaneSetDraftFn(lua: *Lua) i32 {
    const engine = LuaEngine.getEngineFromState(lua);
    const wm = engine.window_manager orelse {
        lua.raiseErrorStr("zag.pane.set_draft: no window manager bound", .{});
    };
    const handle = requireLayoutHandle(lua, 1, "zag.pane.set_draft");
    if (lua.typeOf(2) != .string) {
        lua.raiseErrorStr("zag.pane.set_draft: text must be a string", .{});
    }
    const text = lua.toString(2) catch {
        lua.raiseErrorStr("zag.pane.set_draft: text must be a string", .{});
    };
    const pane = wm.paneFromHandle(handle) catch |err| {
        var buf: [160]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "zag.pane.set_draft: {s}", .{@errorName(err)}) catch "zag.pane.set_draft failed";
        lua.raiseErrorStr("%s", .{msg.ptr});
    };
    pane.setDraft(text);
    return 0;
}

/// `zag.pane.get_draft(pane_id)`: return the current in-progress draft of
/// `pane_id` as a Lua string. Returns `""` for a pane that has never been
/// typed into. Pairs with `zag.pane.set_draft` so autocomplete plugins
/// can read the live draft without the orchestrator having to thread it
/// through as an explicit argument.
fn zagPaneGetDraftFn(lua: *Lua) i32 {
    const engine = LuaEngine.getEngineFromState(lua);
    const wm = engine.window_manager orelse {
        lua.raiseErrorStr("zag.pane.get_draft: no window manager bound", .{});
    };
    const handle = requireLayoutHandle(lua, 1, "zag.pane.get_draft");
    const pane = wm.paneFromHandle(handle) catch |err| {
        var buf: [160]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "zag.pane.get_draft: {s}", .{@errorName(err)}) catch "zag.pane.get_draft failed";
        lua.raiseErrorStr("%s", .{msg.ptr});
    };
    _ = lua.pushString(pane.getDraft());
    return 1;
}

/// `zag.pane.replace_draft_range(pane_id, from_byte, to_byte, replacement)`:
/// replace bytes `[from_byte, to_byte)` of `pane_id`'s draft with
/// `replacement`. **Byte offsets are 0-indexed** (raw byte positions
/// over the draft, not 1-indexed Lua positions): autocomplete plugins
/// already reason in terms of trigger byte ranges captured against
/// `getDraft()`, so 0-indexing keeps that math straight rather than
/// forcing every plugin to add and subtract one. `from_byte == to_byte`
/// is a valid pure insertion at `from_byte`. Raises on invalid range
/// or overflow past MAX_DRAFT. Autocomplete plugins know the trigger
/// position and want loud failure if anything is off.
fn zagPaneReplaceDraftRangeFn(lua: *Lua) i32 {
    const engine = LuaEngine.getEngineFromState(lua);
    const wm = engine.window_manager orelse {
        lua.raiseErrorStr("zag.pane.replace_draft_range: no window manager bound", .{});
    };
    const handle = requireLayoutHandle(lua, 1, "zag.pane.replace_draft_range");

    if (lua.typeOf(2) != .number) {
        lua.raiseErrorStr("zag.pane.replace_draft_range: from_byte must be an integer", .{});
    }
    const from_lua = lua.toInteger(2) catch {
        lua.raiseErrorStr("zag.pane.replace_draft_range: from_byte must be an integer", .{});
    };
    if (from_lua < 0) {
        lua.raiseErrorStr("zag.pane.replace_draft_range: from_byte must be >= 0", .{});
    }

    if (lua.typeOf(3) != .number) {
        lua.raiseErrorStr("zag.pane.replace_draft_range: to_byte must be an integer", .{});
    }
    const to_lua = lua.toInteger(3) catch {
        lua.raiseErrorStr("zag.pane.replace_draft_range: to_byte must be an integer", .{});
    };
    if (to_lua < 0) {
        lua.raiseErrorStr("zag.pane.replace_draft_range: to_byte must be >= 0", .{});
    }

    if (lua.typeOf(4) != .string) {
        lua.raiseErrorStr("zag.pane.replace_draft_range: replacement must be a string", .{});
    }
    const replacement = lua.toString(4) catch {
        lua.raiseErrorStr("zag.pane.replace_draft_range: replacement must be a string", .{});
    };

    const pane = wm.paneFromHandle(handle) catch |err| {
        var buf: [160]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "zag.pane.replace_draft_range: {s}", .{@errorName(err)}) catch "zag.pane.replace_draft_range failed";
        lua.raiseErrorStr("%s", .{msg.ptr});
    };

    const from_byte: usize = @intCast(from_lua);
    const to_byte: usize = @intCast(to_lua);
    pane.replaceDraftRange(from_byte, to_byte, replacement) catch |err| switch (err) {
        error.InvalidRange => {
            var buf: [192]u8 = undefined;
            const msg = std.fmt.bufPrintZ(
                &buf,
                "zag.pane.replace_draft_range: invalid range [{d}, {d}) over draft of {d} bytes",
                .{ from_byte, to_byte, pane.getDraft().len },
            ) catch "zag.pane.replace_draft_range: invalid range";
            lua.raiseErrorStr("%s", .{msg.ptr});
        },
        error.Overflow => {
            var buf: [192]u8 = undefined;
            const msg = std.fmt.bufPrintZ(
                &buf,
                "zag.pane.replace_draft_range: replacement would overflow MAX_DRAFT (replacement={d} bytes, removed={d}, draft={d})",
                .{ replacement.len, to_byte - from_byte, pane.getDraft().len },
            ) catch "zag.pane.replace_draft_range: overflow";
            lua.raiseErrorStr("%s", .{msg.ptr});
        },
    };
    return 0;
}

/// Register the `zag.layout` subtable. Caller has the `zag` table at
/// stack top; on return the `zag` table is still at stack top with
/// `layout` attached. Mirrors the original registration order from
/// `injectZagGlobal`.
pub fn registerLayoutTable(lua: *Lua) void {
    lua.newTable(); // [zag_table, layout_table]
    lua.pushFunction(zlua.wrap(zagLayoutTreeFn));
    lua.setField(-2, "tree");
    lua.pushFunction(zlua.wrap(zagLayoutFocusFn));
    lua.setField(-2, "focus");
    lua.pushFunction(zlua.wrap(zagLayoutSplitFn));
    lua.setField(-2, "split");
    lua.pushFunction(zlua.wrap(zagLayoutFloatFn));
    lua.setField(-2, "float");
    lua.pushFunction(zlua.wrap(zagLayoutFloatMoveFn));
    lua.setField(-2, "float_move");
    lua.pushFunction(zlua.wrap(zagLayoutFloatRaiseFn));
    lua.setField(-2, "float_raise");
    lua.pushFunction(zlua.wrap(zagLayoutFloatsFn));
    lua.setField(-2, "floats");
    lua.pushFunction(zlua.wrap(zagLayoutCloseFn));
    lua.setField(-2, "close");
    lua.pushFunction(zlua.wrap(zagLayoutResizeFn));
    lua.setField(-2, "resize");
    lua.setField(-2, "layout"); // zag.layout = layout_table; [zag_table]
}

/// Register the `zag.pane` subtable. Caller has the `zag` table at
/// stack top; on return the `zag` table is still at stack top with
/// `pane` attached. Mirrors the original registration order.
pub fn registerPaneTable(lua: *Lua) void {
    lua.newTable(); // [zag_table, pane_table]
    lua.pushFunction(zlua.wrap(zagPaneReadFn));
    lua.setField(-2, "read");
    lua.pushFunction(zlua.wrap(zagPaneSetModelFn));
    lua.setField(-2, "set_model");
    lua.pushFunction(zlua.wrap(zagPaneCurrentModelFn));
    lua.setField(-2, "current_model");
    lua.pushFunction(zlua.wrap(zagPaneSetDraftFn));
    lua.setField(-2, "set_draft");
    lua.pushFunction(zlua.wrap(zagPaneGetDraftFn));
    lua.setField(-2, "get_draft");
    lua.pushFunction(zlua.wrap(zagPaneReplaceDraftRangeFn));
    lua.setField(-2, "replace_draft_range");
    lua.setField(-2, "pane"); // zag.pane = pane_table; [zag_table]
}
