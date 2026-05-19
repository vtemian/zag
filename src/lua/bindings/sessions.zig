//! zag.sessions Lua bindings.
//!
//! Read-only enumeration and mutation surface consumed by the sessions
//! sidebar plugin. The full surface is:
//!
//!   * `zag.sessions.list()` — array of `{id, name, model, created_ms,
//!     updated_ms, message_count, project}` rows aggregated across every
//!     project recorded in `ProjectRegistry`, sorted by `updated_ms`
//!     descending.
//!   * `zag.sessions.rename(id, new_name, project_path?)` — update the
//!     `meta.json` for `id` in `project_path`. When `project_path` is
//!     omitted, walks the registry to find the owning project. Raises
//!     on missing id or unknown project_path.
//!   * `zag.sessions.delete(id, project_path?)` — remove `.jsonl` +
//!     `.meta.json` for the session. Same lookup semantics as rename;
//!     a delete of an already-absent id is a no-op.
//!   * `zag.sessions.current()` — id string of the session bound to the
//!     focused conversation pane, or `nil`.
//!   * `zag.sessions.subagents(id, project_path?)` — array of
//!     `{call_id, tool_input, timestamp_ms}` rows for each `task_start`
//!     entry in `id`'s JSONL. Same lookup semantics as rename.
//!
//! The optional `project_path` argument lets callers (typically the
//! sessions sidebar, which already has `row.project` from `list()`)
//! skip the full-registry scan. When supplied it is validated against
//! the registry plus the live cwd realpath; an unknown path raises
//! rather than being treated as authoritative, so the Lua surface
//! cannot be tricked into mutating arbitrary on-disk paths.
//!
//! Cross-project lookup walks `ProjectRegistry.listProjects()` and probes
//! each project root via `Session.listSessionsAt`; the standalone helper
//! avoids re-registering visited projects in the registry (which would
//! be circular).
//!
//!   * `zag.sessions.open(id, project_path?)` — split the focused
//!     pane and bind the new leaf to the existing session `id`. v1
//!     limitation: when `project_path` is supplied and differs from
//!     the live cwd realpath, the call raises
//!     `CrossProjectOpenNotSupported` because `SessionManager` resolves
//!     `sessions_dir` against the process cwd. Cross-project opens
//!     would need either a per-pane cwd or a `loadSessionAt` variant;
//!     both are deferred to v2.

const std = @import("std");
const zlua = @import("zlua");
const Lua = zlua.Lua;

const LuaEngine = @import("../../LuaEngine.zig").LuaEngine;
const Session = @import("../../Session.zig");
const ProjectRegistry = @import("../../project_registry.zig");
const Hooks = @import("../../Hooks.zig");
const WindowManager = @import("../../WindowManager.zig");

const log = std.log.scoped(.lua_sessions);

/// Fire `SessionListChanged` for an already-successful session mutation.
/// Best-effort: hook failures (allocator pressure, a buggy plugin) are
/// logged and dropped so the mutation's success on disk is not reflected
/// as a Lua-side failure. The hook fires synchronously on the Lua main
/// thread, which is where every binding callback already runs.
///
/// `change` is the enum literal of the anonymous union-member enum
/// declared on `HookPayload.session_list_changed.change`; pass `.created`,
/// `.renamed`, or `.deleted` directly. Comptime coercion through
/// `HookPayload` initialization picks up the right tag.
fn fireSessionListChanged(
    engine: *LuaEngine,
    change: anytype,
    session_id: []const u8,
) void {
    var payload: Hooks.HookPayload = .{ .session_list_changed = .{
        .change = change,
        .session_id = session_id,
    } };
    _ = engine.fireHook(&payload) catch |err| {
        log.warn("SessionListChanged hook fire failed: {s}", .{@errorName(err)});
    };
}

/// Resolve `$HOME/.config/zag` the same way `Session.recordCwdInRegistry`
/// does. Returns an owned slice; caller frees with `allocator.free`.
fn resolveConfigDir(allocator: std.mem.Allocator) ![]u8 {
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".config", "zag" });
}

/// One row of the aggregated session list. `project_path` is borrowed
/// from the enclosing `Collection.project_paths` slot; `meta` carries
/// inline storage and owns nothing.
const Row = struct {
    meta: Session.Meta,
    project_path: []const u8,
};

/// Owned bundle returned by `collectRows`. `project_paths` holds the
/// deduped allocation backing every `Row.project_path` slice; freeing
/// the collection releases the rows array and every project_path in one
/// pass without the double-free risk of dedupe-on-free.
const Collection = struct {
    rows: []Row,
    project_paths: [][]u8,

    fn deinit(self: *Collection, allocator: std.mem.Allocator) void {
        allocator.free(self.rows);
        for (self.project_paths) |p| allocator.free(p);
        allocator.free(self.project_paths);
    }
};

/// Collect every session across every registered project plus the live
/// cwd. The cwd is included explicitly because the registry is updated
/// lazily on `SessionManager.init`; if `init` failed earlier in the
/// current process, the sidebar would otherwise miss its own project.
///
/// Returns a sorted (newest first) `Collection`. Caller calls
/// `Collection.deinit` to release every owned slot.
fn collectRows(allocator: std.mem.Allocator) !Collection {
    var rows: std.ArrayList(Row) = .empty;
    errdefer rows.deinit(allocator);

    var project_paths: std.ArrayList([]u8) = .empty;
    errdefer {
        for (project_paths.items) |p| allocator.free(p);
        project_paths.deinit(allocator);
    }

    const config_dir = resolveConfigDir(allocator) catch |err| switch (err) {
        // No HOME: degrade to "no registry projects visible". The
        // sidebar still works for whichever project the process happens
        // to be running in once that gets folded in below.
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
    defer if (config_dir) |d| allocator.free(d);

    if (config_dir) |dir| {
        var registry = ProjectRegistry.init(allocator, dir) catch |err| blk: {
            // A broken registry must not fail the whole binding: log and
            // skip the registry traversal, fall through to the cwd probe.
            log.warn("project registry open failed: {s}", .{@errorName(err)});
            break :blk null;
        };
        if (registry) |*r| {
            defer r.deinit();
            const projects = try r.listProjects();
            defer {
                for (projects) |p| allocator.free(p.path);
                allocator.free(projects);
            }
            for (projects) |p| {
                try appendProjectRows(allocator, &rows, &project_paths, p.path);
            }
        }
    }

    // Fold in the current cwd in case the registry was unreachable or
    // had not yet been updated when the sidebar first opened.
    if (std.fs.cwd().realpathAlloc(allocator, ".")) |cwd_real| {
        defer allocator.free(cwd_real);
        try appendProjectRows(allocator, &rows, &project_paths, cwd_real);
    } else |err| {
        log.warn("cwd realpath failed: {s}", .{@errorName(err)});
    }

    std.mem.sort(Row, rows.items, {}, struct {
        fn lessThan(_: void, a: Row, b: Row) bool {
            return a.meta.updated > b.meta.updated;
        }
    }.lessThan);

    return .{
        .rows = try rows.toOwnedSlice(allocator),
        .project_paths = try project_paths.toOwnedSlice(allocator),
    };
}

fn appendProjectRows(
    allocator: std.mem.Allocator,
    rows: *std.ArrayList(Row),
    project_paths: *std.ArrayList([]u8),
    project_path: []const u8,
) !void {
    // Dedupe by linear scan; project counts are tiny (tens at most),
    // so an O(n) probe beats the bookkeeping of a hash map keyed on
    // the same allocation we're tracking for free.
    for (project_paths.items) |existing| {
        if (std.mem.eql(u8, existing, project_path)) return;
    }
    const owned = try allocator.dupe(u8, project_path);
    errdefer allocator.free(owned);
    try project_paths.append(allocator, owned);

    const metas = Session.listSessionsAt(allocator, owned) catch |err| {
        log.warn("listSessionsAt({s}) failed: {s}", .{ owned, @errorName(err) });
        return;
    };
    defer allocator.free(metas);

    for (metas) |m| {
        try rows.append(allocator, .{ .meta = m, .project_path = owned });
    }
}

/// Push a single row onto the Lua stack as a table with the public
/// keys documented at the top of this file.
fn pushRow(lua: *Lua, row: Row) void {
    lua.createTable(0, 7);

    _ = lua.pushString(row.meta.idSlice());
    lua.setField(-2, "id");

    _ = lua.pushString(row.meta.nameSlice());
    lua.setField(-2, "name");

    _ = lua.pushString(row.meta.modelSlice());
    lua.setField(-2, "model");

    lua.pushInteger(row.meta.created);
    lua.setField(-2, "created_ms");

    lua.pushInteger(row.meta.updated);
    lua.setField(-2, "updated_ms");

    lua.pushInteger(@intCast(row.meta.message_count));
    lua.setField(-2, "message_count");

    _ = lua.pushString(row.project_path);
    lua.setField(-2, "project");
}

/// `zag.sessions.list()` — see top-of-file docstring.
fn zagSessionsListFn(lua: *Lua) i32 {
    const engine = LuaEngine.getEngineFromState(lua);
    var collection = collectRows(engine.allocator) catch |err| {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrintZ(&buf, "zag.sessions.list: {s}", .{@errorName(err)}) catch
            "zag.sessions.list failed";
        lua.raiseErrorStr("%s", .{msg.ptr});
    };
    defer collection.deinit(engine.allocator);

    lua.createTable(@intCast(collection.rows.len), 0);
    for (collection.rows, 0..) |row, i| {
        pushRow(lua, row);
        lua.setIndex(-2, @intCast(i + 1));
    }
    return 1;
}

/// Search every project in the registry plus the live cwd for `id` and
/// return the owning project's absolute path. Caller owns the slice and
/// frees it. Returns null when the id is not present in any project.
fn findProjectForId(allocator: std.mem.Allocator, id: []const u8) !?[]u8 {
    var collection = try collectRows(allocator);
    defer collection.deinit(allocator);
    for (collection.rows) |r| {
        if (std.mem.eql(u8, r.meta.idSlice(), id)) {
            return try allocator.dupe(u8, r.project_path);
        }
    }
    return null;
}

/// Validate that `project_path` is known to the registry or matches the
/// live cwd realpath. Returns `error.UnknownProject` if neither matches.
/// Callers pass project_path through from Lua; without this gate the
/// binding would happily mutate arbitrary on-disk paths supplied by a
/// plugin.
fn verifyProjectRegistered(allocator: std.mem.Allocator, project_path: []const u8) !void {
    // cwd realpath wins fast: the sidebar's most common case is renaming
    // a session in the current project, and that almost always matches
    // here without touching the registry file at all.
    if (std.fs.cwd().realpathAlloc(allocator, ".")) |cwd_real| {
        defer allocator.free(cwd_real);
        if (std.mem.eql(u8, cwd_real, project_path)) return;
    } else |_| {}

    const config_dir = resolveConfigDir(allocator) catch |err| switch (err) {
        // No HOME: only the cwd check above is available, and it has
        // already failed. Treat as unknown rather than silently allow.
        error.EnvironmentVariableNotFound => return error.UnknownProject,
        else => return err,
    };
    defer allocator.free(config_dir);

    var registry = ProjectRegistry.init(allocator, config_dir) catch |err| {
        log.warn("project registry open failed during verify: {s}", .{@errorName(err)});
        return error.UnknownProject;
    };
    defer registry.deinit();

    const projects = try registry.listProjects();
    defer {
        for (projects) |p| allocator.free(p.path);
        allocator.free(projects);
    }
    for (projects) |p| {
        if (std.mem.eql(u8, p.path, project_path)) return;
    }
    return error.UnknownProject;
}

/// Resolve the owning project for `id`, optionally taking a caller-
/// supplied hint at Lua arg `arg_index`. When the hint is a string,
/// validate it via `verifyProjectRegistered` and return a duped copy.
/// When the hint is absent/nil, fall back to the full-registry scan.
/// Returns null when no project owns `id` (only possible on the
/// fallback path; the hint path raises `UnknownProject` before
/// reaching here).
fn resolveProjectFor(
    lua: *Lua,
    allocator: std.mem.Allocator,
    id: []const u8,
    arg_index: i32,
) !?[]u8 {
    if (lua.isNoneOrNil(arg_index)) {
        return findProjectForId(allocator, id);
    }
    if (lua.typeOf(arg_index) != .string) {
        return error.InvalidProjectArg;
    }
    const hint = lua.toString(arg_index) catch return error.InvalidProjectArg;
    try verifyProjectRegistered(allocator, hint);
    return try allocator.dupe(u8, hint);
}

/// `zag.sessions.rename(id, new_name, project_path?)` — see top-of-file docstring.
fn zagSessionsRenameFn(lua: *Lua) i32 {
    const engine = LuaEngine.getEngineFromState(lua);

    if (lua.typeOf(1) != .string) {
        lua.raiseErrorStr("zag.sessions.rename: id must be a string", .{});
    }
    const id = lua.toString(1) catch {
        lua.raiseErrorStr("zag.sessions.rename: id must be a string", .{});
    };
    if (lua.typeOf(2) != .string) {
        lua.raiseErrorStr("zag.sessions.rename: name must be a string", .{});
    }
    const new_name = lua.toString(2) catch {
        lua.raiseErrorStr("zag.sessions.rename: name must be a string", .{});
    };

    const project_owned = resolveProjectFor(lua, engine.allocator, id, 3) catch |err| switch (err) {
        error.UnknownProject => lua.raiseErrorStr("zag.sessions.rename: unknown project", .{}),
        error.InvalidProjectArg => lua.raiseErrorStr("zag.sessions.rename: project_path must be a string", .{}),
        else => {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrintZ(&buf, "zag.sessions.rename: {s}", .{@errorName(err)}) catch
                "zag.sessions.rename: lookup failed";
            lua.raiseErrorStr("%s", .{msg.ptr});
        },
    };
    if (project_owned == null) {
        lua.raiseErrorStr("zag.sessions.rename: unknown session id", .{});
    }
    defer engine.allocator.free(project_owned.?);

    Session.renameSessionAt(engine.allocator, project_owned.?, id, new_name) catch |err| switch (err) {
        error.InvalidSessionId => lua.raiseErrorStr("zag.sessions.rename: invalid session id", .{}),
        else => {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrintZ(&buf, "zag.sessions.rename: {s}", .{@errorName(err)}) catch
                "zag.sessions.rename failed";
            lua.raiseErrorStr("%s", .{msg.ptr});
        },
    };
    fireSessionListChanged(engine, .renamed, id);
    return 0;
}

/// `zag.sessions.delete(id, project_path?)` — see top-of-file docstring.
fn zagSessionsDeleteFn(lua: *Lua) i32 {
    const engine = LuaEngine.getEngineFromState(lua);

    if (lua.typeOf(1) != .string) {
        lua.raiseErrorStr("zag.sessions.delete: id must be a string", .{});
    }
    const id = lua.toString(1) catch {
        lua.raiseErrorStr("zag.sessions.delete: id must be a string", .{});
    };

    const project_owned = resolveProjectFor(lua, engine.allocator, id, 2) catch |err| switch (err) {
        error.UnknownProject => lua.raiseErrorStr("zag.sessions.delete: unknown project", .{}),
        error.InvalidProjectArg => lua.raiseErrorStr("zag.sessions.delete: project_path must be a string", .{}),
        else => {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrintZ(&buf, "zag.sessions.delete: {s}", .{@errorName(err)}) catch
                "zag.sessions.delete: lookup failed";
            lua.raiseErrorStr("%s", .{msg.ptr});
        },
    };
    if (project_owned == null) {
        // Match SessionManager.deleteSession's idempotency contract: a
        // delete of an already-absent session is a no-op, not an error.
        // Log at debug so a typo'd id is observable in trace output
        // rather than silently swallowed.
        log.debug("zag.sessions.delete: no project owns id '{s}' (already deleted, or typo)", .{id});
        return 0;
    }
    defer engine.allocator.free(project_owned.?);

    Session.deleteSessionAt(project_owned.?, id) catch |err| switch (err) {
        error.InvalidSessionId => lua.raiseErrorStr("zag.sessions.delete: invalid session id", .{}),
        else => {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrintZ(&buf, "zag.sessions.delete: {s}", .{@errorName(err)}) catch
                "zag.sessions.delete failed";
            lua.raiseErrorStr("%s", .{msg.ptr});
        },
    };
    fireSessionListChanged(engine, .deleted, id);
    return 0;
}

/// `zag.sessions.current()` — see top-of-file docstring.
fn zagSessionsCurrentFn(lua: *Lua) i32 {
    const engine = LuaEngine.getEngineFromState(lua);
    const wm = engine.window_manager orelse {
        lua.pushNil();
        return 1;
    };

    const pane = wm.getFocusedPanePtr();
    const conv = pane.conversation orelse {
        lua.pushNil();
        return 1;
    };
    const sh = conv.session_handle orelse {
        lua.pushNil();
        return 1;
    };
    _ = lua.pushString(sh.id[0..sh.id_len]);
    return 1;
}

/// Push the ULID of an entry as a 26-char base32 string. The loader
/// backfills synthetic ids for pre-migration rows, so this slot is
/// always populated; we push the raw bytes directly because ULID's
/// base32 alphabet is already ASCII.
fn pushUlidString(lua: *Lua, ulid_bytes: [26]u8) void {
    _ = lua.pushString(ulid_bytes[0..]);
}

/// `zag.sessions.subagents(id, project_path?)` — see top-of-file docstring.
fn zagSessionsSubagentsFn(lua: *Lua) i32 {
    const engine = LuaEngine.getEngineFromState(lua);

    if (lua.typeOf(1) != .string) {
        lua.raiseErrorStr("zag.sessions.subagents: id must be a string", .{});
    }
    const id = lua.toString(1) catch {
        lua.raiseErrorStr("zag.sessions.subagents: id must be a string", .{});
    };

    const project_owned = resolveProjectFor(lua, engine.allocator, id, 2) catch |err| switch (err) {
        error.UnknownProject => lua.raiseErrorStr("zag.sessions.subagents: unknown project", .{}),
        error.InvalidProjectArg => lua.raiseErrorStr("zag.sessions.subagents: project_path must be a string", .{}),
        else => {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrintZ(&buf, "zag.sessions.subagents: {s}", .{@errorName(err)}) catch
                "zag.sessions.subagents: lookup failed";
            lua.raiseErrorStr("%s", .{msg.ptr});
        },
    };
    if (project_owned == null) {
        lua.raiseErrorStr("zag.sessions.subagents: unknown session id", .{});
    }
    defer engine.allocator.free(project_owned.?);

    const entries = Session.loadEntriesAt(engine.allocator, project_owned.?, id) catch |err| switch (err) {
        error.InvalidSessionId => lua.raiseErrorStr("zag.sessions.subagents: invalid session id", .{}),
        else => {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrintZ(&buf, "zag.sessions.subagents: {s}", .{@errorName(err)}) catch
                "zag.sessions.subagents: load failed";
            lua.raiseErrorStr("%s", .{msg.ptr});
        },
    };
    defer {
        for (entries) |e| Session.freeEntry(e, engine.allocator);
        engine.allocator.free(entries);
    }

    // Two-pass to size the result table accurately; task_start entries
    // are sparse so a flat resize would over-allocate the array part.
    var spawn_count: usize = 0;
    for (entries) |e| {
        if (e.entry_type == .task_start) spawn_count += 1;
    }

    lua.createTable(@intCast(spawn_count), 0);
    var index: i32 = 0;
    for (entries) |e| {
        if (e.entry_type != .task_start) continue;
        index += 1;
        lua.createTable(0, 3);

        pushUlidString(lua, e.id);
        lua.setField(-2, "call_id");

        _ = lua.pushString(e.content);
        lua.setField(-2, "tool_input");

        lua.pushInteger(e.timestamp);
        lua.setField(-2, "timestamp_ms");

        lua.setIndex(-2, index);
    }
    return 1;
}

/// `zag.sessions.open(id, project_path?)` — see top-of-file docstring.
///
/// Splits the focused leaf and binds the new pane to the existing
/// session `id`. Cross-project opens are rejected up-front because
/// `SessionManager.loadSession` resolves paths against the process
/// cwd; opening a session from another project would silently load
/// from the wrong directory.
fn zagSessionsOpenFn(lua: *Lua) i32 {
    const engine = LuaEngine.getEngineFromState(lua);
    const wm = engine.window_manager orelse {
        lua.raiseErrorStr("zag.sessions.open: no window manager attached", .{});
    };

    if (lua.typeOf(1) != .string) {
        lua.raiseErrorStr("zag.sessions.open: id must be a string", .{});
    }
    const id = lua.toString(1) catch {
        lua.raiseErrorStr("zag.sessions.open: id must be a string", .{});
    };

    // When the caller hands us a project_path (the sidebar does, every
    // row carries one) we verify it matches the cwd realpath. Sessions
    // from other projects on disk are visible via `list()` but cannot
    // be opened yet; see the top-of-file docstring for the v2 plan.
    if (!lua.isNoneOrNil(2)) {
        if (lua.typeOf(2) != .string) {
            lua.raiseErrorStr("zag.sessions.open: project_path must be a string", .{});
        }
        const project = lua.toString(2) catch {
            lua.raiseErrorStr("zag.sessions.open: project_path must be a string", .{});
        };
        const cwd_real = std.fs.cwd().realpathAlloc(engine.allocator, ".") catch |err| {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrintZ(&buf, "zag.sessions.open: cwd realpath: {s}", .{@errorName(err)}) catch
                "zag.sessions.open: cwd realpath failed";
            lua.raiseErrorStr("%s", .{msg.ptr});
        };
        defer engine.allocator.free(cwd_real);
        if (!std.mem.eql(u8, cwd_real, project)) {
            lua.raiseErrorStr("zag.sessions.open: CrossProjectOpenNotSupported", .{});
        }
    }

    _ = wm.splitFocusedWithSession(id) catch |err| switch (err) {
        error.InvalidSessionId => lua.raiseErrorStr("zag.sessions.open: invalid session id", .{}),
        error.SessionManagerUnavailable => lua.raiseErrorStr("zag.sessions.open: persistence disabled", .{}),
        else => {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrintZ(&buf, "zag.sessions.open: {s}", .{@errorName(err)}) catch
                "zag.sessions.open failed";
            lua.raiseErrorStr("%s", .{msg.ptr});
        },
    };
    return 0;
}

/// Register the `zag.sessions` subtable. Caller has the `zag` table at
/// stack top; on return the `zag` table is still at stack top with
/// `sessions` attached. Mirrors `registerLayoutTable`'s registration
/// shape and ordering.
pub fn registerOn(lua: *Lua) void {
    lua.newTable(); // [zag_table, sessions_table]
    lua.pushFunction(zlua.wrap(zagSessionsListFn));
    lua.setField(-2, "list");
    lua.pushFunction(zlua.wrap(zagSessionsRenameFn));
    lua.setField(-2, "rename");
    lua.pushFunction(zlua.wrap(zagSessionsDeleteFn));
    lua.setField(-2, "delete");
    lua.pushFunction(zlua.wrap(zagSessionsCurrentFn));
    lua.setField(-2, "current");
    lua.pushFunction(zlua.wrap(zagSessionsSubagentsFn));
    lua.setField(-2, "subagents");
    lua.pushFunction(zlua.wrap(zagSessionsOpenFn));
    lua.setField(-2, "open");
    lua.setField(-2, "sessions"); // zag.sessions = sessions_table; [zag_table]
}
