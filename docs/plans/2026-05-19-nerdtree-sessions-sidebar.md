# NERDTree-for-Sessions Sidebar Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** A persistent left side pane that lists all of Vlad's zag sessions (across every project), shows the active session highlighted, expands per-session subagent subtrees on demand, and supports filter / rename / delete inline. Toggle with `<leader>e` or `/sessions`.

**Architecture:** Pure-Lua plugin (`src/lua/zag/builtin/sessions.lua`) renders into a scratch buffer attached to a left tile via `zag.layout.split`. Zig side gains a small `zag.sessions.*` binding (list / open / rename / delete / subagents / current), a global project registry at `~/.config/zag/projects.json` so the sidebar can aggregate sessions across cwds, and two new hooks (`SessionListChanged`, `PaneFocused`) for refresh and current-row tracking. Sidebar state (cursor, expanded set, filter, mode) lives in a module-level Lua table that survives pane teardown — toggle hide/show rebuilds the pane from saved state.

**Tech Stack:** Zig 0.15, Lua 5.4 (via ziglua), embedded stdlib (`src/lua/embedded.zig`), buffer-local keymaps (two-pass lookup in `Keymap.zig`), tile splits in `Layout.zig`.

**Design decisions locked with Vlad before drafting (see /Users/whitemonk/.claude/projects/-Users-whitemonk-projects-ai-zag/memory/MEMORY.md for context conventions):**

| Decision | Choice | Why |
|---|---|---|
| Scope | Full vision: tree + filter + rename + delete + current-row highlight | Vlad picked it explicitly |
| API shape | Generic `zag.sessions.*` | Primitives over products; future plugins reuse |
| Refresh signal | New `SessionListChanged` hook fired from `SessionManager` | Real event, no polling |
| Buffer kind | Pure Lua on `scratch` | No `BufferRegistry.Kind` enum growth; doctrine fit |
| Toggle | Rebuild pane on toggle; state in Lua | Avoids new layout primitive |
| List scope | Global across all projects | Vlad picked it |
| Subagent discovery | Lazy parse JSONL on expand | No `meta.json` schema migration |

**Acknowledged limitation:** Global `SessionListChanged` fires only for the local zag process. Sessions created by another zag instance in a different cwd appear after the sidebar pane regains focus (we refresh on `View.onFocus(true)`). Cross-process FS-watch is deferred to v2.

---

## Phase 1: Session API surface (Zig)

### Task 1.1: Add `Session.deleteSession`

`SessionManager` has create / load / list / rename but not delete. The sidebar's `dd` action needs it.

**Files:**
- Modify: `src/Session.zig` — add `pub fn deleteSession`
- Test: same file (inline tests, per project CLAUDE.md)

**Step 1.1.1: Write the failing test**

Append to `src/Session.zig` near the existing `SessionManager` tests:

```zig
test "SessionManager.deleteSession removes both .jsonl and .meta.json" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var mgr = try SessionManager.initInDir(std.testing.allocator, tmp.dir);
    defer mgr.deinit();

    const handle = try mgr.createSession("test/model");
    const id = try std.testing.allocator.dupe(u8, handle.id[0..handle.id_len]);
    defer std.testing.allocator.free(id);
    handle.close();

    try mgr.deleteSession(id);

    const sessions = try mgr.listSessions();
    defer {
        for (sessions) |*s| s.deinit(std.testing.allocator);
        std.testing.allocator.free(sessions);
    }
    try std.testing.expectEqual(@as(usize, 0), sessions.len);

    // Deleting a non-existent id should be a no-op (not an error).
    try mgr.deleteSession(id);
}
```

If `initInDir` does not exist in `SessionManager`, this is the cue to extract one (look at the existing `init` and split the path resolution out). Do that as part of this task only if needed.

**Step 1.1.2: Run, watch it fail**

```
zig build test 2>&1 | rg "deleteSession"
```

Expected: compile error (`deleteSession` not found) or test failure.

**Step 1.1.3: Implement**

Add after `SessionManager.findLastSession` (around `src/Session.zig:373`):

```zig
/// Remove a session's `.jsonl` and `.meta.json` from disk.
/// No-op if neither file exists (idempotent). Caller is responsible for
/// closing any open SessionHandle first; passing a still-open id is a
/// programming error that will leak the open fd.
pub fn deleteSession(self: *SessionManager, id: []const u8) !void {
    if (!isValidSessionId(id)) return error.InvalidSessionId;

    var jsonl_buf: [Session.max_path_len]u8 = undefined;
    var meta_buf: [Session.max_path_len]u8 = undefined;

    const jsonl_path = try std.fmt.bufPrint(&jsonl_buf, "{s}/{s}.jsonl", .{ self.base_dir, id });
    const meta_path = try std.fmt.bufPrint(&meta_buf, "{s}/{s}.meta.json", .{ self.base_dir, id });

    std.fs.cwd().deleteFile(jsonl_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    std.fs.cwd().deleteFile(meta_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}
```

You may need to add `isValidSessionId` if it does not already exist (grep first; `Session.zig` may already validate ids in `loadSession`). Reuse whatever guard is already there.

**Step 1.1.4: Run, watch it pass**

```
zig build test 2>&1 | rg "deleteSession"
```

Expected: PASS.

**Step 1.1.5: Commit**

```
git add src/Session.zig
git commit -m "$(cat <<'EOF'
session: add deleteSession to SessionManager

Idempotent removal of both the .jsonl and .meta.json files.
Sidebar dd action will call this.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 1.2: Project registry module

Sessions live at `<cwd>/.zag/sessions/`. For the sidebar to show sessions across all projects we need a registry of which cwds have ever hosted a zag session. The registry lives at `~/.config/zag/projects.json` and is written atomically (temp + rename) on every `SessionManager.init` for a fresh cwd.

**Schema:**

```json
{
  "projects": [
    { "path": "/Users/whitemonk/projects/ai/zag", "last_seen_ms": 1747641600000 },
    { "path": "/Users/whitemonk/projects/x", "last_seen_ms": 1747641700000 }
  ]
}
```

**Files:**
- Create: `src/project_registry.zig`
- Test: inline in same file

**Step 1.2.1: Failing test**

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;

const ProjectRegistry = @This();

// (definitions below; tests reference them)

test "register dedupes and bumps last_seen_ms" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    var reg = try ProjectRegistry.init(std.testing.allocator, tmp_path);
    defer reg.deinit();

    try reg.register("/projects/a", 1000);
    try reg.register("/projects/b", 2000);
    try reg.register("/projects/a", 3000); // dedupes, bumps last_seen

    const list = try reg.listProjects();
    defer {
        for (list) |p| std.testing.allocator.free(p.path);
        std.testing.allocator.free(list);
    }
    try std.testing.expectEqual(@as(usize, 2), list.len);
    // Sort order: most recent first.
    try std.testing.expectEqualStrings("/projects/a", list[0].path);
    try std.testing.expectEqual(@as(i64, 3000), list[0].last_seen_ms);
    try std.testing.expectEqualStrings("/projects/b", list[1].path);
}

test "register persists across reopen" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    {
        var reg = try ProjectRegistry.init(std.testing.allocator, tmp_path);
        defer reg.deinit();
        try reg.register("/projects/a", 1000);
    }
    {
        var reg = try ProjectRegistry.init(std.testing.allocator, tmp_path);
        defer reg.deinit();
        const list = try reg.listProjects();
        defer {
            for (list) |p| std.testing.allocator.free(p.path);
            std.testing.allocator.free(list);
        }
        try std.testing.expectEqual(@as(usize, 1), list.len);
        try std.testing.expectEqualStrings("/projects/a", list[0].path);
    }
}

test "malformed registry file recovers to empty list" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp.dir.realpath(".", &path_buf);

    {
        const f = try tmp.dir.createFile("projects.json", .{});
        defer f.close();
        try f.writeAll("{ not valid json");
    }
    var reg = try ProjectRegistry.init(std.testing.allocator, tmp_path);
    defer reg.deinit();
    const list = try reg.listProjects();
    defer std.testing.allocator.free(list);
    try std.testing.expectEqual(@as(usize, 0), list.len);
}
```

**Step 1.2.2: Implement**

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.project_registry);

const ProjectRegistry = @This();

pub const Project = struct {
    path: []const u8,
    last_seen_ms: i64,
};

allocator: Allocator,
config_dir: []const u8, // owned
file_path: []const u8,  // owned, joined config_dir + "projects.json"
projects: std.ArrayList(Project),

/// Open the registry at `<config_dir>/projects.json`. Creates the file
/// (and any missing parent dirs) on first call. Malformed file content
/// is treated as an empty registry and overwritten on the next save.
pub fn init(allocator: Allocator, config_dir: []const u8) !ProjectRegistry {
    const dir_owned = try allocator.dupe(u8, config_dir);
    errdefer allocator.free(dir_owned);

    std.fs.cwd().makePath(dir_owned) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const file_path = try std.fs.path.join(allocator, &.{ dir_owned, "projects.json" });
    errdefer allocator.free(file_path);

    var self: ProjectRegistry = .{
        .allocator = allocator,
        .config_dir = dir_owned,
        .file_path = file_path,
        .projects = .empty,
    };
    self.loadFromDisk() catch |err| {
        log.warn("could not load registry at {s}: {} (treating as empty)", .{ file_path, err });
    };
    return self;
}

pub fn deinit(self: *ProjectRegistry) void {
    for (self.projects.items) |p| self.allocator.free(p.path);
    self.projects.deinit(self.allocator);
    self.allocator.free(self.file_path);
    self.allocator.free(self.config_dir);
}

/// Insert or bump a project entry, then persist atomically.
pub fn register(self: *ProjectRegistry, path: []const u8, now_ms: i64) !void {
    for (self.projects.items) |*p| {
        if (std.mem.eql(u8, p.path, path)) {
            if (now_ms > p.last_seen_ms) p.last_seen_ms = now_ms;
            return self.saveAtomic();
        }
    }
    const dup = try self.allocator.dupe(u8, path);
    errdefer self.allocator.free(dup);
    try self.projects.append(self.allocator, .{ .path = dup, .last_seen_ms = now_ms });
    try self.saveAtomic();
}

/// Caller-owned slice; caller frees each `.path` and the outer slice.
pub fn listProjects(self: *const ProjectRegistry) ![]Project {
    const out = try self.allocator.alloc(Project, self.projects.items.len);
    for (self.projects.items, 0..) |p, i| {
        out[i] = .{
            .path = try self.allocator.dupe(u8, p.path),
            .last_seen_ms = p.last_seen_ms,
        };
    }
    std.sort.block(Project, out, {}, struct {
        fn lessThan(_: void, a: Project, b: Project) bool {
            return a.last_seen_ms > b.last_seen_ms;
        }
    }.lessThan);
    return out;
}

fn loadFromDisk(self: *ProjectRegistry) !void {
    const data = std.fs.cwd().readFileAlloc(self.allocator, self.file_path, 1 << 20) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer self.allocator.free(data);

    var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch return;
    defer parsed.deinit();

    const root_obj = switch (parsed.value) {
        .object => |o| o,
        else => return,
    };
    const arr_value = root_obj.get("projects") orelse return;
    const arr = switch (arr_value) {
        .array => |a| a,
        else => return,
    };
    for (arr.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const path_value = obj.get("path") orelse continue;
        const path_str = switch (path_value) {
            .string => |s| s,
            else => continue,
        };
        const ts_value = obj.get("last_seen_ms") orelse continue;
        const ts: i64 = switch (ts_value) {
            .integer => |i| i,
            else => continue,
        };
        const dup = try self.allocator.dupe(u8, path_str);
        errdefer self.allocator.free(dup);
        try self.projects.append(self.allocator, .{ .path = dup, .last_seen_ms = ts });
    }
}

fn saveAtomic(self: *ProjectRegistry) !void {
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{self.file_path});

    {
        const f = try std.fs.cwd().createFile(tmp_path, .{ .truncate = true });
        defer f.close();
        var w = f.writer().any();
        try w.writeAll("{\n  \"projects\": [\n");
        for (self.projects.items, 0..) |p, i| {
            try w.writeAll("    {\"path\": ");
            try std.json.encodeJsonString(p.path, .{}, w);
            try w.print(", \"last_seen_ms\": {d}}}", .{p.last_seen_ms});
            if (i + 1 < self.projects.items.len) try w.writeAll(",");
            try w.writeAll("\n");
        }
        try w.writeAll("  ]\n}\n");
    }
    try std.fs.cwd().rename(tmp_path, self.file_path);
}

test {
    @import("std").testing.refAllDecls(@This());
}
```

**Step 1.2.3: Run + commit**

```
zig build test 2>&1 | rg "project_registry"
git add src/project_registry.zig
git commit -m "$(cat <<'EOF'
project_registry: global registry of cwds with zag sessions

Atomic temp+rename writes. Used by the sessions sidebar to aggregate
sessions across projects.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 1.3: Hook ProjectRegistry into SessionManager.init

**Files:**
- Modify: `src/Session.zig` (SessionManager.init around line 203)

**Step 1.3.1: Failing test**

Append to Session.zig tests:

```zig
test "SessionManager.init records cwd in the global project registry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Redirect XDG_CONFIG_HOME so we hit a sandboxed registry.
    var cfg_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cfg_path = try tmp.dir.realpath(".", &cfg_buf);

    // SessionManager.init takes an explicit config_dir override for testing.
    var mgr = try SessionManager.initWithConfigDir(std.testing.allocator, cfg_path);
    defer mgr.deinit();

    const ProjectRegistry = @import("project_registry.zig");
    var reg = try ProjectRegistry.init(std.testing.allocator, cfg_path);
    defer reg.deinit();

    const projects = try reg.listProjects();
    defer {
        for (projects) |p| std.testing.allocator.free(p.path);
        std.testing.allocator.free(projects);
    }
    try std.testing.expectEqual(@as(usize, 1), projects.len);

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try std.process.getCwdAlloc(std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    try std.testing.expectEqualStrings(cwd, projects[0].path);
    _ = cwd_buf;
}
```

**Step 1.3.2: Implement**

In `SessionManager.init`, after the `.zag/sessions/` directory is created, add:

```zig
// Record this cwd in the global registry so the sessions sidebar can
// aggregate across projects. Failure is non-fatal: a session still
// works without registry presence.
const cfg_dir = std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME") catch null;
defer if (cfg_dir) |d| allocator.free(d);
const home = std.process.getEnvVarOwned(allocator, "HOME") catch null;
defer if (home) |h| allocator.free(h);

if (cfg_dir orelse home) |base| {
    const zag_cfg = if (cfg_dir != null)
        try std.fs.path.join(allocator, &.{ base, "zag" })
    else
        try std.fs.path.join(allocator, &.{ base, ".config", "zag" });
    defer allocator.free(zag_cfg);

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.process.getCwd(&cwd_buf)) |cwd| {
        const ProjectRegistry = @import("project_registry.zig");
        var reg = ProjectRegistry.init(allocator, zag_cfg) catch null;
        if (reg) |*r| {
            defer r.deinit();
            r.register(cwd, std.time.milliTimestamp()) catch |err| {
                log.warn("project registry register failed: {}", .{err});
            };
        }
    } else |_| {}
}
```

Also add an `initWithConfigDir` test-only variant if the production `init` is not amenable to dependency-injecting the registry path. Document it as test-only with a `/// Test helper:` doc comment.

**Step 1.3.3: Run + commit**

```
zig build test
git add src/Session.zig
git commit -m "$(cat <<'EOF'
session: register cwd in global project registry on init

So the sessions sidebar can aggregate sessions across all projects
Vlad has ever opened zag in.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 1.4: `zag.sessions.*` Lua binding module

**Files:**
- Create: `src/lua/bindings/sessions.zig`
- Modify: `src/LuaEngine.zig` (call site that constructs the `zag` table; mirror how `zag.layout` is wired)

**Step 1.4.1: Failing test**

In `src/lua/integration_test.zig`, add:

```zig
test "zag.sessions.list returns sessions from all registered projects" {
    var engine = try testEngine();
    defer engine.deinit();
    try engine.lua.doString(
        \\local sessions = zag.sessions.list()
        \\assert(type(sessions) == "table", "expected table")
    );
}

test "zag.sessions.rename + list reflects new name" {
    var engine = try testEngine();
    defer engine.deinit();

    // Create a session through the manager exposed in test wiring.
    const id = try engine.testCreateSession("anthropic/claude-sonnet-4-20250514");
    try engine.lua.doString(try std.fmt.allocPrintZ(
        std.testing.allocator,
        "zag.sessions.rename({s}, 'renamed-by-test')",
        .{id},
    ));
    try engine.lua.doString(
        \\local list = zag.sessions.list()
        \\local found = false
        \\for _, s in ipairs(list) do
        \\    if s.name == 'renamed-by-test' then found = true end
        \\end
        \\assert(found, 'renamed session not in list')
    );
}
```

(Test wiring helpers may need an extension — `engine.testCreateSession` does not exist today; grep for the existing test helpers in `integration_test.zig` and add the smallest function that opens a `SessionHandle` and returns the id.)

**Step 1.4.2: Implement the binding**

```zig
//! Lua bindings for session enumeration and mutation.
//! `zag.sessions.list()`, `.open(id)`, `.rename(id, name)`,
//! `.delete(id)`, `.subagents(id)`, `.current()`.

const std = @import("std");
const ziglua = @import("ziglua");
const Lua = ziglua.Lua;

const LuaEngine = @import("../LuaEngine.zig");
const Session = @import("../Session.zig");
const ProjectRegistry = @import("../project_registry.zig");
const WindowManager = @import("../WindowManager.zig");

// (full implementation: list walks the project registry, opens each
// project's SessionManager in read-only mode, collects []Meta into a
// single Lua array sorted by updated_ms desc, with `project` field
// added so the UI can group; open / rename / delete look up the
// project for a given id and call SessionManager methods; subagents
// loads entries lazily and filters to .task entries; current reads
// the focused pane's session id via WindowManager.)

pub fn install(lua: *Lua, engine: *LuaEngine) !void {
    // ... see model in src/lua/bindings/layout.zig for the table
    // construction pattern, error propagation via lua.raiseErrorStr,
    // and the @ptrCast/upvalue idiom used for the engine pointer.
}
```

This task block is large; flesh out the binding by mirroring `src/lua/bindings/layout.zig` line-for-line on structure: install function takes `*Lua` and `*LuaEngine`, pushes a table, sets cfunctions for each method, uses upvalues to capture the engine pointer, error path goes through `lua.raiseErrorStr`. For `list`, the loop is:

```
for project in registry.listProjects():
    if project.path == cwd: use engine.window_manager.session_manager
    else: open a transient SessionManager rooted at project.path
    for meta in mgr.listSessions():
        push { id, name, model, created_ms, updated_ms, message_count, project } to result array
sort result by updated_ms desc, return
```

For `current`: read the focused leaf via `engine.window_manager.layout.focused`, drill into the leaf's `Pane.conversation.?.session_handle` and return the id slice (use the `id[0..id_len]` pattern from `Conversation.zig:1900`). Return `nil` if focused pane has no session.

**Step 1.4.3: Wire into LuaEngine**

In `src/LuaEngine.zig`, find where `zag.layout` is installed (grep `bindings/layout.zig`); add a parallel line `try @import("lua/bindings/sessions.zig").install(self.lua, self);`.

**Step 1.4.4: Run + commit**

```
zig build test
git add src/lua/bindings/sessions.zig src/LuaEngine.zig src/lua/integration_test.zig
git commit -m "$(cat <<'EOF'
lua/bindings: add zag.sessions surface

list / open / rename / delete / subagents / current. Aggregates
across the global project registry. Sidebar plugin consumes this.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Phase 2: Hooks for refresh and current-row tracking

### Task 2.1: Add `SessionListChanged` event kind

**Files:**
- Modify: `src/Hooks.zig:11-42, 64-125` — extend `EventKind`, `parseEventName`, `HookPayload`

**Step 2.1.1: Failing test**

Append to `Hooks.zig` tests:

```zig
test "parseEventName maps SessionListChanged" {
    try std.testing.expectEqual(
        Hooks.EventKind.session_list_changed,
        Hooks.parseEventName("SessionListChanged").?,
    );
}

test "HookPayload.kind returns session_list_changed" {
    const p: HookPayload = .{ .session_list_changed = .{ .change = .created, .session_id = "abc" } };
    try std.testing.expectEqual(EventKind.session_list_changed, p.kind());
}
```

**Step 2.1.2: Implement**

Add to `EventKind` (after `pane_draft_change`):

```zig
session_list_changed,
pane_focused,
```

Add to `parseEventName` table:

```zig
.{ "SessionListChanged", .session_list_changed },
.{ "PaneFocused", .pane_focused },
```

Add to `HookPayload`:

```zig
session_list_changed: struct {
    change: enum { created, renamed, deleted },
    /// Borrowed for the duration of the hook fire only.
    session_id: []const u8,
},
pane_focused: struct {
    /// Stable layout handle of the newly focused pane. "" if none.
    pane_handle: []const u8,
    /// Stable layout handle of the previously focused pane. "" if none.
    previous_handle: []const u8,
},
```

**Step 2.1.3: Run + commit**

```
zig build test 2>&1 | rg -i "session_list\|pane_focused"
git add src/Hooks.zig
git commit -m "$(cat <<'EOF'
hooks: add SessionListChanged and PaneFocused event kinds

Wired but not fired yet; sidebar plugin will subscribe to both.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2.2: Fire `SessionListChanged` from SessionManager

**Files:**
- Modify: `src/Session.zig` — fire after createSession, rename, renameIfUnnamed, deleteSession

**Step 2.2.1: Failing test**

The test exercises the round-trip: a Lua hook captures the event, sees the change tag and id.

```zig
test "createSession fires SessionListChanged with .created" {
    var harness = try TestHarness.init(std.testing.allocator);
    defer harness.deinit();

    try harness.engine.lua.doString(
        \\seen = nil
        \\zag.hook("SessionListChanged", nil, function(evt)
        \\    seen = evt
        \\end)
    );

    const handle = try harness.session_manager.createSession("test/model");
    defer handle.close();

    try harness.engine.lua.doString(
        \\assert(seen, "no event seen")
        \\assert(seen.change == "created", "wrong change tag: " .. tostring(seen.change))
    );
}
```

(The exact `TestHarness` helper depends on what exists in `integration_test.zig`; the agent should reuse it or extend it minimally.)

**Step 2.2.2: Implement**

Sessions are created on a thread that holds the LuaEngine event-queue handle. Fire by allocating a payload, pushing through the existing `fireHook` round-trip path (see how `pane_draft_change` is fired from `WindowManager` for the wiring pattern).

Add a helper in `SessionManager` that takes a pointer to the engine (or to the event-queue) and call it from the four mutation sites.

**Step 2.2.3: Commit**

```
git add src/Session.zig
git commit -m "session: fire SessionListChanged on create/rename/delete"
```

---

### Task 2.3: Fire `PaneFocused` from WindowManager.notifyFocusSwap

**Files:**
- Modify: `src/WindowManager.zig:769` (the `notifyFocusSwap` site)

**Step 2.3.1 → 2.3.3** Same TDD shape as Task 2.2. The fire site: just after the existing `prev_leaf.view.onFocus(false)` / `next_leaf.view.onFocus(true)` calls. Format pane handles with `NodeRegistry.formatId` (same path the draft-change hook uses).

Commit message: `wm: fire PaneFocused hook on focus swap`

---

### Task 2.4: Add `zag.pane.session_id(pane_id)` binding

**Files:**
- Modify: `src/lua/bindings/layout.zig` (the `zag.pane.*` table near line 1049)

The sidebar's current-session highlight needs to know which session a pane is bound to. Add a function that takes a pane handle string, looks up the leaf, returns `pane.conversation.?.session_handle.?.id[0..id_len]` or `nil`.

TDD shape mirrors Task 1.4. Commit:

```
lua/bindings: add zag.pane.session_id

Sidebar reads this from the PaneFocused hook to highlight the
currently-active session row.
```

---

## Phase 3: Sidebar skeleton (Lua)

### Task 3.1: Create the plugin file

**Files:**
- Create: `src/lua/zag/builtin/sessions.lua`
- Modify: `src/lua/embedded.zig:20-46` (add entry to `entries` array, bump count test at line 58)

**Step 3.1.1: Skeleton with module-level state**

```lua
-- Builtin sessions sidebar. Toggle with `<leader>e` or `/sessions`.
--
-- State lives in this module table so it survives pane close/reopen.

local M = {}

-- Sidebar state. Persists across toggle.
local state = {
    pane_id = nil,        -- layout handle of the open sidebar pane, nil if hidden
    buffer_id = nil,      -- backing scratch buffer handle
    cursor_row = 1,       -- selected row in the rendered list (1-indexed)
    expanded = {},        -- set: session_id -> true
    filter = "",          -- substring filter (empty = no filter)
    mode = "normal",      -- "normal" | "filter" | "rename" | "confirm_delete"
    rename_buf = "",      -- in-progress new name
    last_render = {},     -- array of { kind, session_id?, depth, label } for keymap dispatch
    hook_ids = {},        -- registered hook ids, removed on close
    keymap_ids = {},      -- registered buffer-local keymap ids
}

function M.toggle()
    if state.pane_id then
        M.close()
    else
        M.open()
    end
end

function M.open()
    -- TODO: split, create buffer, render, bind keys, subscribe to hooks
end

function M.close()
    -- TODO: unsubscribe hooks, remove keymaps, close pane, keep state
end

-- Register slash command and global keymap on require.
zag.command {
    name = "/sessions",
    fn = M.toggle,
    desc = "Toggle the sessions sidebar",
}
zag.keymap {
    mode = "normal",
    key = "<leader>e",
    fn = M.toggle,
}

return M
```

Add to `src/lua/embedded.zig:29` (alongside `zag.builtin.model_picker`):

```zig
.{ .name = "zag.builtin.sessions", .code = @embedFile("zag/builtin/sessions.lua") },
```

Bump the count assertion at `embedded.zig:58` from 25 to 26.

**Step 3.1.2: Test**

In `src/lua/embedded.zig` tests, add:

```zig
test "find returns the entry for the sessions sidebar" {
    const e = find("zag.builtin.sessions").?;
    try std.testing.expectEqualStrings("zag.builtin.sessions", e.name);
    try std.testing.expect(std.mem.indexOf(u8, e.code, "zag.command") != null);
}
```

**Step 3.1.3: Commit**

```
git add src/lua/zag/builtin/sessions.lua src/lua/embedded.zig
git commit -m "$(cat <<'EOF'
lua/builtin: scaffold sessions sidebar plugin

Module state, /sessions command, <leader>e keymap. Open/close
implementations come in the next tasks.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3.2: Implement `M.open()` / `M.close()`

```lua
function M.open()
    if state.pane_id then return end
    local tree = zag.layout.tree()
    local root_focus = tree.focus

    state.buffer_id = zag.buffer.create({ kind = "scratch", name = "sessions" })
    state.pane_id = zag.layout.split(root_focus, "vertical", {
        buffer = state.buffer_id,
        side = "first", -- new pane is the left half; conversation moves right
        ratio = 0.2,
    })

    M._bind_keymaps()
    M._subscribe_hooks()
    M._render()
end

function M.close()
    for _, id in ipairs(state.keymap_ids) do
        pcall(zag.keymap_remove, id)
    end
    state.keymap_ids = {}
    for _, id in ipairs(state.hook_ids) do
        pcall(zag.hook_del, id)
    end
    state.hook_ids = {}

    if state.pane_id then
        pcall(zag.layout.close, state.pane_id)
        state.pane_id = nil
    end
    state.buffer_id = nil
    -- cursor_row, expanded, filter are deliberately preserved.
end
```

`zag.layout.split` may not accept a `side = "first"` option today. Inspect `src/lua/bindings/layout.zig:91-169` and add the missing parameter if needed — the existing split currently puts the new pane as the second child, but the sidebar needs to be the leftmost. If the binding needs an option, add it as part of this task with a test in `integration_test.zig`.

TDD as before. Commit:

```
sessions: implement open/close with left-side split
```

---

## Phase 4: Flat list rendering and navigation

### Task 4.1: Render flat list

```lua
function M._collect_rows()
    -- Returns an array of { kind = "session"|"subagent", session_id, depth, label }
    -- filtered by state.filter and expanded according to state.expanded.
    local sessions = zag.sessions.list()
    local rows = {}
    for _, s in ipairs(sessions) do
        local name = s.name ~= "" and s.name or s.id:sub(1, 8)
        if state.filter == "" or name:lower():find(state.filter:lower(), 1, true) then
            local glyph = state.expanded[s.id] and "▾" or "▸"
            table.insert(rows, {
                kind = "session",
                session_id = s.id,
                depth = 0,
                label = string.format("%s %s", glyph, name),
            })
            if state.expanded[s.id] then
                local subs = zag.sessions.subagents(s.id) or {}
                for _, sub in ipairs(subs) do
                    table.insert(rows, {
                        kind = "subagent",
                        session_id = s.id,
                        depth = 1,
                        label = string.format("  └ %s", sub.tool_input or "subagent"),
                    })
                end
            end
        end
    end
    return rows
end

function M._render()
    if not state.buffer_id then return end
    local rows = M._collect_rows()
    state.last_render = rows
    local lines = {}
    for _, r in ipairs(rows) do
        table.insert(lines, r.label)
    end
    if state.mode == "filter" then
        table.insert(lines, 1, "/" .. state.filter)
        state.cursor_row = math.min(state.cursor_row + 1, #lines)
    end
    zag.buffer.set_lines(state.buffer_id, lines)
    zag.buffer.set_row_style(state.buffer_id, state.cursor_row - 1, "selection")
end
```

Verify `zag.buffer.set_row_style` accepts `"selection"` as a style name (grep `src/lua/bindings/buffer.zig` and `src/Theme.zig`); if not, use whatever style key the model_picker uses for its highlight.

TDD: integration test that calls `M.open()`, asserts buffer line count matches the registered session count.

Commit: `sessions: render flat session list to sidebar buffer`

---

### Task 4.2: j/k navigation via buffer-local keymaps

```lua
function M._bind_keymaps()
    local function add(spec)
        local id = zag.keymap(spec)
        table.insert(state.keymap_ids, id)
    end
    add { mode = "normal", key = "j", buffer = state.buffer_id, fn = M._cursor_down }
    add { mode = "normal", key = "k", buffer = state.buffer_id, fn = M._cursor_up }
    add { mode = "normal", key = "<CR>", buffer = state.buffer_id, fn = M._activate }
    add { mode = "normal", key = "l", buffer = state.buffer_id, fn = M._expand }
    add { mode = "normal", key = "h", buffer = state.buffer_id, fn = M._collapse }
    add { mode = "normal", key = "q", buffer = state.buffer_id, fn = M.close }
    -- filter/rename/delete bindings added in later tasks
end

function M._cursor_down()
    state.cursor_row = math.min(state.cursor_row + 1, #state.last_render)
    M._render()
end
function M._cursor_up()
    state.cursor_row = math.max(state.cursor_row - 1, 1)
    M._render()
end
function M._activate()
    local row = state.last_render[state.cursor_row]
    if not row or row.kind ~= "session" then return end
    -- Open this session in the conversation pane. The conversation
    -- pane is the focused leaf of whatever isn't us.
    zag.sessions.open(row.session_id)
end
function M._expand()
    local row = state.last_render[state.cursor_row]
    if not row or row.kind ~= "session" then return end
    state.expanded[row.session_id] = true
    M._render()
end
function M._collapse()
    local row = state.last_render[state.cursor_row]
    if not row or row.kind ~= "session" then return end
    state.expanded[row.session_id] = nil
    M._render()
end
```

TDD: sim test (`src/sim/`) that spawns zag, sends `<leader>e`, then `j`, then `j`, asserts the highlighted row moves down. The simulator harness already supports keystroke injection (see `src/sim/Runner.zig`).

Commit: `sessions: j/k/l/h navigation and Enter to open`

---

### Task 4.3 + 4.4: Refresh subscriptions

```lua
function M._subscribe_hooks()
    table.insert(state.hook_ids, zag.hook("SessionListChanged", nil, function(evt)
        M._render()
    end))
    -- Also re-render on focus enter (covers the cross-process case).
    -- View.onFocus is not Lua-callable today; instead, listen on
    -- PaneFocused and check if the focused pane IS the sidebar.
    table.insert(state.hook_ids, zag.hook("PaneFocused", nil, function(evt)
        if evt.pane_handle == state.pane_id then
            M._render()
        end
    end))
end
```

Commit: `sessions: refresh on SessionListChanged and on sidebar focus`

---

## Phase 5: Tree expansion (subagent rows)

Already partially wired in Task 4.1. This phase adds the underlying binding.

### Task 5.1: `zag.sessions.subagents(id)`

Returns task-entry summaries from the session's JSONL.

**Files:**
- Modify: `src/lua/bindings/sessions.zig`

```zig
// Read entries lazily; filter to .task variants; expose { call_id,
// tool_input (the prompt), timestamp_ms } for each.
fn lua_subagents(L: *Lua) i32 {
    // Pull engine, get id arg, call Session.loadEntries(id, allocator)
    // (Session.zig:606). Walk the array, push a Lua table per
    // task-call entry. Free entries with Session.freeEntry afterwards.
}
```

Test: integration test that creates a session, appends a synthetic task entry, calls `zag.sessions.subagents(id)`, asserts one row returned.

Commit: `lua/bindings: add zag.sessions.subagents for lazy subagent expansion`

---

## Phase 6: Current-session highlight

### Task 6.1: Subscribe to PaneFocused and apply highlight

Extend `_render` to compute the current-session row:

```lua
local function _current_session_id()
    local tree = zag.layout.tree()
    if not tree.focus or tree.focus == state.pane_id then return nil end
    return zag.pane.session_id(tree.focus)
end

function M._render()
    -- ... (rows + lines as before)
    local current_id = _current_session_id()
    for i, row in ipairs(state.last_render) do
        if row.kind == "session" and row.session_id == current_id then
            zag.buffer.set_row_style(state.buffer_id, i - 1, "info")  -- pick a theme key
        end
    end
    zag.buffer.set_row_style(state.buffer_id, state.cursor_row - 1, "selection")
end
```

Choose the theme key by reading `src/Theme.zig` and picking the highlight bucket that visually reads as "active." Document the choice in a one-line Lua comment.

Commit: `sessions: highlight the currently-focused session in the sidebar`

---

## Phase 7: Filter, rename, delete

### Task 7.1: Filter mode (`/`)

```lua
add { mode = "normal", key = "/", buffer = state.buffer_id, fn = function()
    state.mode = "filter"
    state.filter = ""
    M._bind_filter_keymaps()
    M._render()
end }

function M._bind_filter_keymaps()
    -- For each printable char, bind it in normal mode buffer-local to
    -- append to state.filter and re-render. <BS> pops, <Esc> exits.
    -- This is heavy; alternative: read a single keystroke at a time
    -- via a custom mode the binding loop knows about.
end
```

The "many printable bindings" path is ugly. Better: ask the writer of `keymap.zig` whether a `mode = "filter"` slot exists or can be cheaply added — a third Keymap.Mode enum value alongside `normal`/`insert` (`src/Keymap.zig:16` lists them). If so, register `filter` keymaps as "any printable char → buffer M.filter_add(char)" once, and toggle `zag.mode.set("filter")` on `/`.

**Decision for the executing engineer:** if adding a third mode is more than ~30 lines of Zig, fall back to a fixed printable-char loop in Lua. Document the choice.

TDD: sim test types `/abc<Esc>`, asserts filter state cleared and full list re-rendered.

Commit: `sessions: / enters filter mode with live substring narrowing`

---

### Task 7.2: Rename mode (`r`)

Reuse the same input-capture pattern as filter. On `<CR>` call `zag.sessions.rename(row.session_id, state.rename_buf)`. On `<Esc>` discard.

Commit: `sessions: r renames the highlighted session inline`

---

### Task 7.3: Delete (`dd`) with confirm popup

```lua
add { mode = "normal", key = "dd", buffer = state.buffer_id, fn = function()
    local row = state.last_render[state.cursor_row]
    if not row or row.kind ~= "session" then return end
    local popup = require("zag.popup.list")
    popup.open {
        items = {
            { word = "yes", abbr = "yes — delete " .. row.session_id },
            { word = "no",  abbr = "no — cancel" },
        },
        on_commit = function(item)
            if item.word == "yes" then
                zag.sessions.delete(row.session_id)
            end
        end,
    }
end }
```

`dd` is a chord; verify `src/Keymap.zig` supports multi-keystroke bindings. If not, fall back to capital `D` for a v1.

Commit: `sessions: dd with confirmation popup deletes the session`

---

## Phase 8: Polish

### Task 8.1: Width pinning

The sidebar should stay ~30 cells wide. On terminal resize, `View.onResize` fires per pane. Hook into it from the scratch buffer's view? Scratch buffers do not expose a Lua resize callback today. Instead, register a hook for a (new) `LayoutResize` event, fired once per resize from `Compositor.recalculate`. The handler calls `zag.layout.resize(state.pane_id, 30 / total_cols)`.

If adding `LayoutResize` is heavyweight, skip width pinning in v1 (ratio is preserved across resizes; the absolute width drifts but the user can always re-toggle).

**Decision for the executing engineer:** if `LayoutResize` requires more than ~50 lines of Zig wiring, defer to v2 and put a TODO comment in `sessions.lua`.

---

### Task 8.2: Initial split ratio sizing

In `M.open()`, compute `ratio = 30 / tree.cols`. Source `tree.cols` from `zag.layout.tree()` (verify the field exists in `src/lua/bindings/layout.zig`; if not, add it).

Commit: `sessions: size sidebar to ~30 cells on open`

---

## Verification checklist (gate before merge)

- [ ] `zig build` succeeds
- [ ] `zig build test` passes
- [ ] `zig fmt --check .` clean
- [ ] Sim test scenario: open zag → `<leader>e` opens sidebar → j/k moves → `<CR>` switches active session → `<leader>e` toggles closed → state preserved on reopen
- [ ] Sim test scenario: type `/foo<Esc>` → filter applied then cleared
- [ ] Sim test scenario: `r new-name<CR>` renames the highlighted session
- [ ] Sim test scenario: `dd` shows confirm, `yes<CR>` deletes
- [ ] Manual: start zag in two different cwds, create a session in each, open sidebar in one — both projects' sessions are listed
- [ ] Manual: terminal resize does not destroy the sidebar pane (width may drift if Task 8.1 is deferred)
- [ ] No leaked Lua callbacks: open/close 10x, `zag.hook_del` count matches `zag.hook` count

---

## Risk register

1. **Two-pass keymap lookup may not actually swap on focus** — buffer-local keymaps fire only when the registry's `focused_buffer_id` is set, and that mechanism's wiring needs verification. If `j` in the conversation pane accidentally triggers the sidebar's `_cursor_down`, the path is wrong. Test early in Task 4.2.
2. **`zag.layout.split` side parameter does not exist** — if so, Task 3.2 grows; budget extra time.
3. **Cross-process session creation invisibility** — accepted limitation. Document in plugin comment.
4. **`dd` chord support** — if `Keymap.zig` only supports single keystrokes, fall back to `D` (uppercase). Don't grow Keymap for this v1.
5. **`SessionListChanged` firing on every meta.json append** — make sure rename and delete don't double-fire. The Lua side debounces with a one-frame coalesce if necessary.

---

## Out of scope (deferred to v2)

- Cross-process refresh (FS-watch on registry)
- Session preview pane on hover
- Drag-resize the sidebar with the mouse
- Hide-without-destroy primitive (`zag.layout.hide`)
- Custom `tree` buffer kind in Zig (we chose pure-Lua-on-scratch)
- Per-project filter toggle (`g` switches global ↔ this-project)
- Multi-select + bulk delete
