//! zag.buffer Lua bindings.
//!
//! Extracted from LuaEngine.zig. Twelve cfunctions form a subtable on
//! the `zag` table. Each binding resolves a `"b<u32>"` handle string
//! through the live `BufferRegistry` (wired by main.zig) and operates
//! on the underlying entry. Scratch and image buffers expose different
//! surfaces; misuse raises a Lua error rather than silently no-oping.

const std = @import("std");
const zlua = @import("zlua");
const Lua = zlua.Lua;
const LuaEngine = @import("../../LuaEngine.zig").LuaEngine;
const BufferRegistry = @import("../../BufferRegistry.zig");
const ImageBuffer = @import("../../buffers/image.zig");
const Theme = @import("../../Theme.zig");

/// Parses the handle string on the Lua stack at `arg_index`, resolves
/// it through the live `BufferRegistry`, and returns the entry. Any
/// failure surfaces as a Lua error prefixed with `op_name` so plugin
/// authors get a pointed diagnostic instead of a stack trace into
/// bufGetId.
fn requireBufferEntry(
    lua: *Lua,
    arg_index: i32,
    comptime op_name: []const u8,
) BufferRegistry.Entry {
    const engine = LuaEngine.getEngineFromState(lua);
    const registry = engine.buffer_registry orelse {
        lua.raiseErrorStr(op_name ++ ": no buffer registry bound", .{});
    };
    if (lua.typeOf(arg_index) != .string) {
        lua.raiseErrorStr(op_name ++ ": handle must be a string", .{});
    }
    const handle_value = lua.toString(arg_index) catch {
        lua.raiseErrorStr(op_name ++ ": handle must be a string", .{});
    };
    const handle = BufferRegistry.parseId(handle_value) catch {
        lua.raiseErrorStr(op_name ++ ": invalid handle", .{});
    };
    const entry = registry.resolve(handle) catch {
        lua.raiseErrorStr(op_name ++ ": stale handle", .{});
    };
    return entry;
}

/// Shared rejection arm for `zag.buffer.*` ops that only operate on
/// scratch buffers. Image buffers expose a different surface (pixel
/// data, no row addressing) so calling line/cursor APIs on them is a
/// plugin bug worth surfacing as a Lua error rather than silently
/// no-oping.
fn rejectImageBuffer(lua: *Lua, comptime op_name: []const u8) noreturn {
    lua.raiseErrorStr(op_name ++ ": not supported on graphics buffers", .{});
}

/// Shared rejection arm for `zag.buffer.*` ops that target scratch or
/// image buffers but were called on a text buffer. Text buffers
/// hold raw byte content (used by ConversationTree nodes) and don't
/// expose the line/cursor or pixel surfaces.
fn rejectTextBuffer(lua: *Lua, comptime op_name: []const u8) noreturn {
    lua.raiseErrorStr(op_name ++ ": not supported on text buffers", .{});
}

/// `zag.buffer.create{ kind = "scratch", name? = "..." }`: allocate a
/// new buffer in the live registry and return its handle string.
/// Only `.scratch` is valid at this point; future kinds add arms to
/// the switch and their own factory wiring.
fn zagBufferCreateFn(lua: *Lua) i32 {
    const engine = LuaEngine.getEngineFromState(lua);
    const registry = engine.buffer_registry orelse {
        lua.raiseErrorStr("zag.buffer.create: no buffer registry bound", .{});
    };
    if (!lua.isTable(1)) {
        lua.raiseErrorStr("zag.buffer.create: argument must be a table", .{});
    }

    _ = lua.getField(1, "kind");
    if (lua.typeOf(-1) != .string) {
        lua.raiseErrorStr("zag.buffer.create: field 'kind' must be a string", .{});
    }
    const kind = lua.toString(-1) catch {
        lua.raiseErrorStr("zag.buffer.create: field 'kind' must be a string", .{});
    };
    // Copy-out before popping: the Lua string lives in the table
    // slot we release on pop, and the downstream branch compares
    // against it. The enum value carries the decision forward so
    // we don't keep the borrowed slice alive past the pop.
    const KindTag = enum { scratch, image };
    const kind_tag: KindTag = if (std.mem.eql(u8, kind, "scratch"))
        .scratch
    else if (std.mem.eql(u8, kind, "graphics"))
        .image
    else {
        lua.raiseErrorStr("zag.buffer.create: unknown kind (valid kinds: \"scratch\", \"graphics\")", .{});
    };
    lua.pop(1);

    var name_buf: []const u8 = switch (kind_tag) {
        .scratch => "scratch",
        .image => "graphics",
    };
    _ = lua.getField(1, "name");
    if (!lua.isNil(-1)) {
        if (lua.typeOf(-1) != .string) {
            lua.raiseErrorStr("zag.buffer.create: field 'name' must be a string", .{});
        }
        name_buf = lua.toString(-1) catch {
            lua.raiseErrorStr("zag.buffer.create: field 'name' must be a string", .{});
        };
    }
    // Name is copied into the buffer's own allocation inside the
    // factory, so letting the Lua slice go away after this call is
    // safe.
    const handle_result: anyerror!BufferRegistry.Handle = switch (kind_tag) {
        .scratch => registry.createScratch(name_buf),
        .image => registry.createImage(name_buf),
    };
    const handle = handle_result catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "zag.buffer.create: {s}", .{@errorName(err)}) catch "zag.buffer.create failed";
        lua.raiseErrorStr("%s", .{msg.ptr});
    };
    lua.pop(1);

    const buffer_id = BufferRegistry.formatId(engine.allocator, handle) catch {
        // Best effort: if we can't format the id, the buffer still
        // lives in the registry. Remove it so we don't leak a slot
        // the caller can't name.
        registry.remove(handle) catch {};
        lua.raiseErrorStr("zag.buffer.create: id format failed", .{});
    };
    defer engine.allocator.free(buffer_id);
    _ = lua.pushString(buffer_id);
    return 1;
}

/// `zag.buffer.set_lines(handle, lines_table)`: replace the buffer's
/// lines with the array-style Lua table on the stack.
fn zagBufferSetLinesFn(lua: *Lua) i32 {
    const entry = requireBufferEntry(lua, 1, "zag.buffer.set_lines");
    if (!lua.isTable(2)) {
        lua.raiseErrorStr("zag.buffer.set_lines: arg 2 must be a table", .{});
    }
    const engine = LuaEngine.getEngineFromState(lua);

    const len = lua.rawLen(2);
    // Gather the lines into a transient slice before handing off to
    // setLines. ScratchBuffer.setLines dupes every entry, so the
    // caller-side borrowed Lua strings are fine to discard on return.
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(engine.allocator);
    lines.ensureTotalCapacity(engine.allocator, len) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "zag.buffer.set_lines: {s}", .{@errorName(err)}) catch "zag.buffer.set_lines failed";
        lua.raiseErrorStr("%s", .{msg.ptr});
    };
    for (0..len) |i| {
        _ = lua.rawGetIndex(2, @intCast(i + 1));
        if (lua.typeOf(-1) != .string) {
            lua.pop(1);
            lua.raiseErrorStr("zag.buffer.set_lines: entries must be strings", .{});
        }
        const s = lua.toString(-1) catch {
            lua.pop(1);
            lua.raiseErrorStr("zag.buffer.set_lines: entries must be strings", .{});
        };
        lines.appendAssumeCapacity(s);
        // Leave the string on the stack until after setLines dupes
        // it, in case Lua reuses the slice. setLines copies every
        // entry immediately so we can pop once at the end of the
        // loop body.
        lua.pop(1);
    }

    switch (entry) {
        .scratch => |sb| {
            sb.setLines(lines.items) catch |err| {
                var buf: [128]u8 = undefined;
                const msg = std.fmt.bufPrintZ(&buf, "zag.buffer.set_lines: {s}", .{@errorName(err)}) catch "zag.buffer.set_lines failed";
                lua.raiseErrorStr("%s", .{msg.ptr});
            };
        },
        .image => rejectImageBuffer(lua, "zag.buffer.set_lines"),
        .text => rejectTextBuffer(lua, "zag.buffer.set_lines"),
    }
    return 0;
}

/// `zag.buffer.get_lines(handle)`: return the buffer's lines as an
/// array-style Lua table.
fn zagBufferGetLinesFn(lua: *Lua) i32 {
    const entry = requireBufferEntry(lua, 1, "zag.buffer.get_lines");
    switch (entry) {
        .scratch => |sb| {
            lua.newTable();
            for (sb.lines.items, 0..) |line, i| {
                _ = lua.pushString(line);
                lua.rawSetIndex(-2, @intCast(i + 1));
            }
            return 1;
        },
        .image => rejectImageBuffer(lua, "zag.buffer.get_lines"),
        .text => rejectTextBuffer(lua, "zag.buffer.get_lines"),
    }
}

/// `zag.buffer.line_count(handle)`: return the buffer's line count.
fn zagBufferLineCountFn(lua: *Lua) i32 {
    const entry = requireBufferEntry(lua, 1, "zag.buffer.line_count");
    switch (entry) {
        .scratch => |sb| {
            lua.pushInteger(@intCast(sb.lines.items.len));
            return 1;
        },
        .image => rejectImageBuffer(lua, "zag.buffer.line_count"),
        .text => rejectTextBuffer(lua, "zag.buffer.line_count"),
    }
}

/// `zag.buffer.cursor_row(handle)`: return the 1-indexed cursor row.
/// Returns 0 when the buffer is empty (no row under the cursor).
fn zagBufferCursorRowFn(lua: *Lua) i32 {
    const entry = requireBufferEntry(lua, 1, "zag.buffer.cursor_row");
    switch (entry) {
        .scratch => |sb| {
            if (sb.lines.items.len == 0) {
                lua.pushInteger(0);
            } else {
                lua.pushInteger(@intCast(sb.cursor_row + 1));
            }
            return 1;
        },
        .image => rejectImageBuffer(lua, "zag.buffer.cursor_row"),
        .text => rejectTextBuffer(lua, "zag.buffer.cursor_row"),
    }
}

/// `zag.buffer.set_cursor_row(handle, row)`: accept a 1-indexed row
/// and clamp against the current line count.
fn zagBufferSetCursorRowFn(lua: *Lua) i32 {
    const entry = requireBufferEntry(lua, 1, "zag.buffer.set_cursor_row");
    if (lua.typeOf(2) != .number) {
        lua.raiseErrorStr("zag.buffer.set_cursor_row: row must be an integer", .{});
    }
    const row = lua.toInteger(2) catch {
        lua.raiseErrorStr("zag.buffer.set_cursor_row: row must be an integer", .{});
    };
    if (row < 1) {
        lua.raiseErrorStr("zag.buffer.set_cursor_row: row must be >= 1", .{});
    }
    switch (entry) {
        .scratch => |sb| {
            const zero_based: u32 = @intCast(row - 1);
            const count: u32 = @intCast(sb.lines.items.len);
            sb.cursor_row = if (count == 0) 0 else @min(zero_based, count - 1);
            sb.dirty = true;
        },
        .image => rejectImageBuffer(lua, "zag.buffer.set_cursor_row"),
        .text => rejectTextBuffer(lua, "zag.buffer.set_cursor_row"),
    }
    return 0;
}

/// `zag.buffer.current_line(handle)`: return the line at the cursor
/// or nil when the buffer is empty.
fn zagBufferCurrentLineFn(lua: *Lua) i32 {
    const entry = requireBufferEntry(lua, 1, "zag.buffer.current_line");
    switch (entry) {
        .scratch => |sb| {
            if (sb.currentLine()) |line| {
                _ = lua.pushString(line);
            } else {
                lua.pushNil();
            }
            return 1;
        },
        .image => rejectImageBuffer(lua, "zag.buffer.current_line"),
        .text => rejectTextBuffer(lua, "zag.buffer.current_line"),
    }
}

/// `zag.buffer.delete(handle)`: destroy the buffer and free its
/// registry slot. The handle's generation advances so subsequent
/// lookups surface `stale handle`.
fn zagBufferDeleteFn(lua: *Lua) i32 {
    const engine = LuaEngine.getEngineFromState(lua);
    const registry = engine.buffer_registry orelse {
        lua.raiseErrorStr("zag.buffer.delete: no buffer registry bound", .{});
    };
    if (lua.typeOf(1) != .string) {
        lua.raiseErrorStr("zag.buffer.delete: handle must be a string", .{});
    }
    const handle_value = lua.toString(1) catch {
        lua.raiseErrorStr("zag.buffer.delete: handle must be a string", .{});
    };
    const handle = BufferRegistry.parseId(handle_value) catch {
        lua.raiseErrorStr("zag.buffer.delete: invalid handle", .{});
    };
    registry.remove(handle) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "zag.buffer.delete: {s}", .{@errorName(err)}) catch "zag.buffer.delete failed";
        lua.raiseErrorStr("%s", .{msg.ptr});
    };
    return 0;
}

/// `zag.buffer.set_png(handle, bytes)`: decode PNG bytes and store
/// the RGBA image on the image buffer referenced by `handle`.
/// Lua 5.4 strings are 8-bit clean, so the PNG payload passes
/// through unmangled. Scratch handles raise a Lua error instead of
/// silently no-oping.
fn zagBufferSetPngFn(lua: *Lua) i32 {
    const entry = requireBufferEntry(lua, 1, "zag.buffer.set_png");
    if (lua.typeOf(2) != .string) {
        lua.raiseErrorStr("zag.buffer.set_png: arg 2 must be a string of PNG bytes", .{});
    }
    const bytes = lua.toString(2) catch {
        lua.raiseErrorStr("zag.buffer.set_png: arg 2 must be a string of PNG bytes", .{});
    };
    switch (entry) {
        .image => |ib| {
            ib.setPng(bytes) catch |err| {
                var buf: [128]u8 = undefined;
                const msg = std.fmt.bufPrintZ(&buf, "zag.buffer.set_png: {s}", .{@errorName(err)}) catch "zag.buffer.set_png failed";
                lua.raiseErrorStr("%s", .{msg.ptr});
            };
        },
        .scratch => lua.raiseErrorStr("zag.buffer.set_png: handle is not a graphics buffer", .{}),
        .text => lua.raiseErrorStr("zag.buffer.set_png: handle is not a graphics buffer", .{}),
    }
    return 0;
}

/// `zag.buffer.set_fit(handle, fit)`: set the image buffer's fit
/// policy. `fit` is one of `"contain"`, `"fill"`, `"actual"`. Any
/// other string raises a Lua error; scratch handles raise a Lua
/// error.
fn zagBufferSetFitFn(lua: *Lua) i32 {
    const entry = requireBufferEntry(lua, 1, "zag.buffer.set_fit");
    if (lua.typeOf(2) != .string) {
        lua.raiseErrorStr("zag.buffer.set_fit: arg 2 must be a string", .{});
    }
    const fit_value = lua.toString(2) catch {
        lua.raiseErrorStr("zag.buffer.set_fit: arg 2 must be a string", .{});
    };
    const fit: ImageBuffer.Fit = if (std.mem.eql(u8, fit_value, "contain"))
        .contain
    else if (std.mem.eql(u8, fit_value, "fill"))
        .fill
    else if (std.mem.eql(u8, fit_value, "actual"))
        .actual
    else {
        lua.raiseErrorStr("zag.buffer.set_fit: fit must be \"contain\", \"fill\", or \"actual\"", .{});
    };
    switch (entry) {
        .image => |ib| ib.setFit(fit),
        .scratch => lua.raiseErrorStr("zag.buffer.set_fit: handle is not a graphics buffer", .{}),
        .text => lua.raiseErrorStr("zag.buffer.set_fit: handle is not a graphics buffer", .{}),
    }
    return 0;
}

/// `zag.buffer.set_row_style(handle, row, slot)`: tag a 1-indexed
/// row with a theme highlight slot string. The row override paints
/// across the row's background at render time. Raises on
/// out-of-range row, unknown slot, or image handles.
fn zagBufferSetRowStyleFn(lua: *Lua) i32 {
    const entry = requireBufferEntry(lua, 1, "zag.buffer.set_row_style");
    if (lua.typeOf(2) != .number) {
        lua.raiseErrorStr("zag.buffer.set_row_style: row must be an integer", .{});
    }
    const row_lua = lua.toInteger(2) catch {
        lua.raiseErrorStr("zag.buffer.set_row_style: row must be an integer", .{});
    };
    if (row_lua < 1) {
        lua.raiseErrorStr("zag.buffer.set_row_style: row must be >= 1", .{});
    }
    if (lua.typeOf(3) != .string) {
        lua.raiseErrorStr("zag.buffer.set_row_style: slot must be a string", .{});
    }
    const slot_value = lua.toString(3) catch {
        lua.raiseErrorStr("zag.buffer.set_row_style: slot must be a string", .{});
    };
    const slot = Theme.parseHighlightSlot(slot_value) orelse {
        lua.raiseErrorStr("zag.buffer.set_row_style: unknown slot (valid: \"selection\", \"current_line\", \"error\", \"warning\")", .{});
    };
    const row_zero: u32 = @intCast(row_lua - 1);
    switch (entry) {
        .scratch => |sb| {
            sb.setRowStyle(row_zero, slot) catch |err| switch (err) {
                error.RowOutOfRange => lua.raiseErrorStr("zag.buffer.set_row_style: row %d is out of range", .{@as(i32, @intCast(row_lua))}),
                else => {
                    var buf: [128]u8 = undefined;
                    const msg = std.fmt.bufPrintZ(&buf, "zag.buffer.set_row_style: {s}", .{@errorName(err)}) catch "zag.buffer.set_row_style failed";
                    lua.raiseErrorStr("%s", .{msg.ptr});
                },
            };
        },
        .image => lua.raiseErrorStr("zag.buffer.set_row_style: not supported on graphics buffers (no row addressing)", .{}),
        .text => rejectTextBuffer(lua, "zag.buffer.set_row_style"),
    }
    return 0;
}

/// `zag.buffer.clear_row_style(handle, row)`: drop a row's
/// highlight override. No-op when the row has no override, and a
/// no-op on image buffers (which carry no row-style state).
/// Cleanup is permissive; only `set_row_style` raises on image
/// buffers since it expresses an intent that cannot take effect.
fn zagBufferClearRowStyleFn(lua: *Lua) i32 {
    const entry = requireBufferEntry(lua, 1, "zag.buffer.clear_row_style");
    if (lua.typeOf(2) != .number) {
        lua.raiseErrorStr("zag.buffer.clear_row_style: row must be an integer", .{});
    }
    const row_lua = lua.toInteger(2) catch {
        lua.raiseErrorStr("zag.buffer.clear_row_style: row must be an integer", .{});
    };
    if (row_lua < 1) {
        lua.raiseErrorStr("zag.buffer.clear_row_style: row must be >= 1", .{});
    }
    const row_zero: u32 = @intCast(row_lua - 1);
    switch (entry) {
        .scratch => |sb| sb.clearRowStyle(row_zero),
        .image => {},
        .text => {},
    }
    return 0;
}

/// Register the `zag.buffer` subtable. Caller has the `zag` table at
/// stack top; on return the `zag` table is still at stack top with
/// `buffer` attached. Mirrors the original registration order from
/// `injectZagGlobal`.
pub fn registerOn(lua: *Lua) void {
    lua.newTable();
    lua.pushFunction(zlua.wrap(zagBufferCreateFn));
    lua.setField(-2, "create");
    lua.pushFunction(zlua.wrap(zagBufferSetLinesFn));
    lua.setField(-2, "set_lines");
    lua.pushFunction(zlua.wrap(zagBufferGetLinesFn));
    lua.setField(-2, "get_lines");
    lua.pushFunction(zlua.wrap(zagBufferLineCountFn));
    lua.setField(-2, "line_count");
    lua.pushFunction(zlua.wrap(zagBufferCursorRowFn));
    lua.setField(-2, "cursor_row");
    lua.pushFunction(zlua.wrap(zagBufferSetCursorRowFn));
    lua.setField(-2, "set_cursor_row");
    lua.pushFunction(zlua.wrap(zagBufferCurrentLineFn));
    lua.setField(-2, "current_line");
    lua.pushFunction(zlua.wrap(zagBufferDeleteFn));
    lua.setField(-2, "delete");
    lua.pushFunction(zlua.wrap(zagBufferSetPngFn));
    lua.setField(-2, "set_png");
    lua.pushFunction(zlua.wrap(zagBufferSetFitFn));
    lua.setField(-2, "set_fit");
    lua.pushFunction(zlua.wrap(zagBufferSetRowStyleFn));
    lua.setField(-2, "set_row_style");
    lua.pushFunction(zlua.wrap(zagBufferClearRowStyleFn));
    lua.setField(-2, "clear_row_style");
    lua.setField(-2, "buffer");
}
