//! Lua plugin system for Zag.
//!
//! Embeds a Lua 5.4 VM (via ziglua) and exposes a `zag.tool()` registration API
//! so that plugins can define tools in Lua that appear alongside the built-in Zig tools.

const std = @import("std");
const zlua = @import("zlua");
const build_options = @import("build_options");
const types = @import("types.zig");
const tools_mod = @import("tools.zig");
const Hooks = @import("Hooks.zig");
const Keymap = @import("Keymap.zig");
const input = @import("input.zig");
const llm = @import("llm.zig");
const NodeRegistry = @import("NodeRegistry.zig");
const WindowManager = @import("WindowManager.zig");
const Allocator = std.mem.Allocator;
const Lua = zlua.Lua;
const log = std.log.scoped(.lua);

const async_scope = @import("lua/Scope.zig");
const async_job = @import("lua/Job.zig");
const cmd_handle_mod = @import("lua/primitives/cmd_handle.zig");
const http_stream_mod = @import("lua/primitives/http_stream.zig");
const job_result_mod = @import("lua/job_result.zig");
const hook_registry_mod = @import("lua/hook_registry.zig");
const lua_json = @import("lua/lua_json.zig");
const AsyncRuntime = @import("lua/AsyncRuntime.zig").AsyncRuntime;

/// Whether the Lua sandbox strips dangerous globals before user code runs.
/// Off by default: `config.lua` is user-owned code (same trust model as
/// Neovim's init.lua / VSCode extensions), so Lua plugins get full access
/// to os/io/debug/package/require. Enable with `-Dlua_sandbox=true` when
/// running untrusted plugins from a shared marketplace.
pub const sandbox_enabled = build_options.lua_sandbox;

/// Lua bootstrap that preserves a minimal safe subset of `os`
/// (date, time, clock) and nils out everything else that can touch
/// the filesystem, spawn processes, or subvert the VM.
const sandbox_strip =
    \\local _date, _time, _clock = os.date, os.time, os.clock
    \\os = nil
    \\io = nil
    \\debug = nil
    \\package = nil
    \\require = nil
    \\dofile = nil
    \\loadfile = nil
    \\load = nil
    \\loadstring = nil
    \\string.dump = nil
    \\os = { date = _date, time = _time, clock = _clock }
;

/// Pure-Lua concurrency combinators (zag.all, zag.race, zag.timeout) built
/// on zag.spawn / task:join / task:cancel / zag.sleep. Embedded at compile
/// time so plugins always get the same implementation regardless of
/// sandbox state (the Zig-side doString call bypasses the `load` strip).
const combinators_src = @embedFile("lua/combinators.lua");

/// A tool defined in Lua via `zag.tool()`.
pub const LuaTool = struct {
    /// Tool name (owned, heap-allocated).
    name: []const u8,
    /// Human-readable description (owned, heap-allocated).
    description: []const u8,
    /// JSON schema string for the tool input (owned, heap-allocated).
    input_schema_json: []const u8,
    /// Short one-line summary for the system prompt (owned, heap-allocated).
    prompt_snippet: ?[]const u8 = null,
    /// Lua registry reference to the execute function.
    func_ref: i32,
};

/// Embedded Lua VM that collects tool definitions from config files
/// and executes them on behalf of the agent loop.
pub const LuaEngine = struct {
    /// The Lua VM state.
    lua: *Lua,
    /// Allocator used for tool metadata and JSON conversion.
    allocator: Allocator,
    /// Tools registered via `zag.tool()` calls in Lua.
    tools: std.ArrayList(LuaTool),
    /// Hook registry + dispatcher. Owns the registered Lua callbacks,
    /// the veto channel, the per-hook budget, and the spawn/drain
    /// orchestration. `fireHook` routes through here via a `ResumeSink`.
    hook_dispatcher: hook_registry_mod.HookDispatcher,
    /// Keymap registry owned by the engine. Populated with built-in
    /// defaults during `init()`; `zag.keymap()` calls from `config.lua`
    /// overwrite entries here, and the window manager reads from it via
    /// `keymapRegistry()` when dispatching keys.
    keymap_registry: Keymap.Registry,
    /// Persistent escape-sequence parser owned by the engine. Defaults
    /// match `input.Parser{}`, so `zag.set_escape_timeout_ms()` from
    /// `config.lua` lands here during `loadUserConfig`; the orchestrator
    /// reads this through `window_manager.inputParser()` when polling
    /// stdin. Outlives a single tick so fragmented CSI/SS3 sequences
    /// assemble across reads.
    input_parser: input.Parser = .{},
    /// Provider names the user declared via `zag.provider{ name = "..." }`.
    /// Owned (each entry duped into `allocator`). Populated during `loadUserConfig`,
    /// read once by `llm.createProviderFromLuaConfig` at startup.
    enabled_providers: std.ArrayList([]const u8),
    /// Default model string set via `zag.set_default_model("prov/id")`.
    /// Owned. Null if the user didn't set one; factory falls back to a hardcoded default.
    default_model: ?[]const u8 = null,
    /// Worker pool + completion queue for blocking I/O primitives.
    /// Both have coupled lifetimes (pool writes to queue), so they're
    /// owned together. Null until `initAsync()` runs.
    async_runtime: ?*AsyncRuntime = null,
    /// Optional back-pointer to the live window manager. Wired by
    /// `main.zig` once the orchestrator is in its final home; stays
    /// null in headless mode so Lua layout bindings raise a clean
    /// "no window manager bound" error instead of dereferencing junk.
    window_manager: ?*WindowManager = null,
    /// Registry of active coroutines keyed by thread ref. Drives resume.
    tasks: std.AutoHashMap(i32, *Task),
    /// Root scope (parent of all agent/hook scopes).
    root_scope: ?*async_scope.Scope = null,

    pub const Task = struct {
        co: *Lua,
        thread_ref: i32,
        scope: *async_scope.Scope,
        pending_job: ?*async_job.Job = null,
        /// Coroutines blocked on :join() waiting for this task to retire.
        /// Each entry is a thread_ref of a joining task (in self.tasks).
        /// Retired + freed in retireTask; joiners resumed with (true, nil)
        /// or (nil, "cancelled") based on self.scope.isCancelled at retirement.
        joiners: std.ArrayList(i32) = .empty,
        /// Arena holding caller-side strings (argv/cwd/env for zag.cmd,
        /// url/headers for zag.http.get, and so on) for an in-flight
        /// primitive Job. Null when the task isn't currently waiting on a
        /// pool-submitted job. Cleaned up by resumeFromJob after the
        /// result is pushed onto the coroutine stack (Lua has copied the
        /// data via pushString by then). Only one primitive is in flight
        /// per task at a time (Lua coroutines are single-stack), so a
        /// single slot suffices across cmd_exec/http_get/future kinds.
        primitive_arena: ?*std.heap.ArenaAllocator = null,
        /// When non-null, this task is running a hook callback. On the
        /// final `.ok` resume (coroutine returns), resumeTask reads the
        /// top-of-stack return value (if it's a table) and applies it
        /// to the payload via `applyHookReturnFromCoroutine`. Pointer
        /// is borrowed; the `fireHook` caller owns the payload and
        /// keeps it alive across the drain loop.
        hook_payload: ?*Hooks.HookPayload = null,
        /// Wall-clock timestamp (ms since epoch) when this task was
        /// spawned. Only meaningful when `budget_ms` is non-null; the
        /// hook drain uses `now - started_at_ms` against `budget_ms`
        /// to decide whether to cancel.
        started_at_ms: i64 = 0,
        /// Per-task budget snapshot in milliseconds. Copied from
        /// `hook_dispatcher.hook_budget_ms` at spawn time so later config changes
        /// don't affect in-flight hooks. Null for non-hook tasks.
        budget_ms: ?i64 = null,
    };

    /// Lua-side handle returned from zag.spawn/zag.detach. Holds a thread_ref
    /// (resolvable against self.tasks) and a pointer back to the engine so
    /// methods can mutate state. thread_ref == 0 means the handle outlived
    /// its task (retired); methods no-op in that case.
    pub const TaskHandle = struct {
        thread_ref: i32,
        engine: *LuaEngine,

        pub const METATABLE_NAME = "zag.TaskHandle";
    };

    /// Create a new LuaEngine. Sets up the VM, installs the `zag.*`
    /// globals, and populates the keymap registry with built-in defaults.
    /// Does NOT load user config; callers invoke `loadUserConfig` for that
    /// so `zag.keymap()` overrides land on top of the defaults.
    ///
    /// Callers who drive the VM directly via `self.lua.doString(...)` and
    /// invoke `zag.*` functions MUST call `self.storeSelfPointer()` first,
    /// otherwise the bindings fail to find the engine. `loadUserConfig()`
    /// handles this automatically.
    pub fn init(allocator: Allocator) !LuaEngine {
        const lua = try Lua.init(allocator);
        errdefer lua.deinit();

        lua.openLibs();

        if (sandbox_enabled) {
            lua.doString(sandbox_strip) catch |err| {
                log.err("lua sandbox bootstrap failed: {}", .{err});
                return err;
            };
        }

        injectZagGlobal(lua);
        try registerTaskHandleMt(lua);
        try registerCmdHandleMt(lua);
        try registerHttpStreamMt(lua);

        var keymap_registry = Keymap.Registry.init(allocator);
        errdefer keymap_registry.deinit();
        try keymap_registry.loadDefaults();

        // Install pure-Lua combinators that build on zag.spawn / :join /
        // :cancel / zag.sleep. These have to run after the primitive
        // bindings exist but don't depend on any engine state.
        lua.doString(combinators_src) catch |err| {
            log.warn("failed to load lua combinators: {}", .{err});
        };

        return LuaEngine{
            .lua = lua,
            .allocator = allocator,
            .tools = .empty,
            .hook_dispatcher = hook_registry_mod.HookDispatcher.init(allocator),
            .enabled_providers = .empty,
            .keymap_registry = keymap_registry,
            .tasks = std.AutoHashMap(i32, *Task).init(allocator),
        };
    }

    /// Borrow the engine's keymap registry. The window manager reads
    /// this on every keypress; `zag.keymap()` writes through the same
    /// pointer during `loadUserConfig`.
    pub fn keymapRegistry(self: *LuaEngine) *Keymap.Registry {
        return &self.keymap_registry;
    }

    /// Borrow the engine's input parser. The orchestrator polls this on
    /// every tick; `zag.set_escape_timeout_ms()` writes through the same
    /// pointer during `loadUserConfig`.
    pub fn inputParser(self: *LuaEngine) *input.Parser {
        return &self.input_parser;
    }

    /// Resolve ~/.config/zag paths, set plugin search path, load config.lua.
    /// All failures are logged and swallowed; missing config is not an error.
    pub fn loadUserConfig(self: *LuaEngine) void {
        const home = std.process.getEnvVarOwned(self.allocator, "HOME") catch return;
        defer self.allocator.free(home);

        // Set plugin search path so require() finds ~/.config/zag/lua/*.lua
        const lua_dir = std.fmt.allocPrint(self.allocator, "{s}/.config/zag/lua", .{home}) catch return;
        defer self.allocator.free(lua_dir);
        self.setPluginPath(lua_dir) catch |err| {
            log.warn("failed to set lua plugin path: {}", .{err});
        };

        // Load config.lua (collects zag.tool() calls)
        const config_path = std.fmt.allocPrint(self.allocator, "{s}/.config/zag/config.lua", .{home}) catch return;
        defer self.allocator.free(config_path);
        self.storeSelfPointer();
        self.loadConfig(config_path) catch |err| {
            switch (err) {
                error.LuaFile => {},
                else => log.warn("config.lua error: {}", .{err}),
            }
        };
    }

    /// Shut down the VM and free all owned tool metadata.
    pub fn deinit(self: *LuaEngine) void {
        for (self.tools.items) |tool| {
            self.lua.unref(zlua.registry_index, tool.func_ref);
            self.allocator.free(tool.name);
            self.allocator.free(tool.description);
            self.allocator.free(tool.input_schema_json);
            if (tool.prompt_snippet) |s| self.allocator.free(s);
        }
        self.tools.deinit(self.allocator);
        for (self.hook_dispatcher.registry.hooks.items) |h| {
            self.lua.unref(zlua.registry_index, h.lua_ref);
        }
        self.hook_dispatcher.deinit();
        for (self.enabled_providers.items) |name| self.allocator.free(name);
        self.enabled_providers.deinit(self.allocator);
        if (self.default_model) |m| self.allocator.free(m);
        self.keymap_registry.deinit();
        self.lua.deinit();
    }

    /// Create the `zag` global table with a `tool()` function.
    /// Does not store the engine pointer yet (see `storeSelfPointer`).
    fn injectZagGlobal(lua: *Lua) void {
        lua.newTable();
        lua.pushFunction(zlua.wrap(zagToolFn));
        lua.setField(-2, "tool");
        lua.pushFunction(zlua.wrap(zagHookFn));
        lua.setField(-2, "hook");
        lua.pushFunction(zlua.wrap(zagHookDelFn));
        lua.setField(-2, "hook_del");
        lua.pushFunction(zlua.wrap(zagKeymapFn));
        lua.setField(-2, "keymap");
        lua.pushFunction(zlua.wrap(zagSetEscapeTimeoutMsFn));
        lua.setField(-2, "set_escape_timeout_ms");
        lua.pushFunction(zlua.wrap(zagSetDefaultModelFn));
        lua.setField(-2, "set_default_model");
        lua.pushFunction(zlua.wrap(zagProviderFn));
        lua.setField(-2, "provider");
        lua.pushFunction(zlua.wrap(zagSleepFn));
        lua.setField(-2, "sleep");
        lua.pushFunction(zlua.wrap(zagSpawnFn));
        lua.setField(-2, "spawn");
        lua.pushFunction(zlua.wrap(zagDetachFn));
        lua.setField(-2, "detach");

        // zag.cmd is a callable table so we can hang zag.cmd.spawn et al.
        // off the same name. Stack after this block: [zag_table].
        lua.newTable(); // [zag_table, cmd_table]
        lua.pushFunction(zlua.wrap(zagCmdSpawnFn));
        lua.setField(-2, "spawn"); // zag.cmd.spawn = fn; [zag_table, cmd_table]
        lua.pushFunction(zlua.wrap(zagCmdKillFn));
        lua.setField(-2, "kill"); // zag.cmd.kill = fn; [zag_table, cmd_table]
        lua.newTable(); // [zag_table, cmd_table, mt]
        lua.pushFunction(zlua.wrap(zagCmdCallFn));
        lua.setField(-2, "__call"); // mt.__call = fn; [zag_table, cmd_table, mt]
        lua.setMetatable(-2); // setmetatable(cmd_table, mt); [zag_table, cmd_table]
        lua.setField(-2, "cmd"); // zag.cmd = cmd_table; [zag_table]

        // zag.http; plain namespace table for HTTP primitives. Not
        // callable; users always go through zag.http.get/post/stream.
        // Stack after this block: [zag_table].
        lua.newTable(); // [zag_table, http_table]
        lua.pushFunction(zlua.wrap(zagHttpGetFn));
        lua.setField(-2, "get"); // zag.http.get = fn; [zag_table, http_table]
        lua.pushFunction(zlua.wrap(zagHttpPostFn));
        lua.setField(-2, "post"); // zag.http.post = fn; [zag_table, http_table]
        lua.pushFunction(zlua.wrap(zagHttpStreamFn));
        lua.setField(-2, "stream"); // zag.http.stream = fn; [zag_table, http_table]
        lua.setField(-2, "http"); // zag.http = http_table; [zag_table]

        // zag.fs; plain namespace table for filesystem primitives.
        // All async entries yield the coroutine; `exists` is sync.
        lua.newTable(); // [zag_table, fs_table]
        lua.pushFunction(zlua.wrap(zagFsReadFn));
        lua.setField(-2, "read");
        lua.pushFunction(zlua.wrap(zagFsWriteFn));
        lua.setField(-2, "write");
        lua.pushFunction(zlua.wrap(zagFsAppendFn));
        lua.setField(-2, "append");
        lua.pushFunction(zlua.wrap(zagFsMkdirFn));
        lua.setField(-2, "mkdir");
        lua.pushFunction(zlua.wrap(zagFsRemoveFn));
        lua.setField(-2, "remove");
        lua.pushFunction(zlua.wrap(zagFsListFn));
        lua.setField(-2, "list");
        lua.pushFunction(zlua.wrap(zagFsStatFn));
        lua.setField(-2, "stat");
        lua.pushFunction(zlua.wrap(zagFsExistsFn));
        lua.setField(-2, "exists");
        lua.setField(-2, "fs"); // zag.fs = fs_table; [zag_table]

        // zag.layout; plain namespace table for window-tree inspection
        // and mutation. Requires a live window manager, which main.zig
        // wires via `engine.window_manager`. Headless runs leave the
        // field null and these bindings raise a clean Lua error.
        lua.newTable(); // [zag_table, layout_table]
        lua.pushFunction(zlua.wrap(zagLayoutTreeFn));
        lua.setField(-2, "tree");
        lua.setField(-2, "layout"); // zag.layout = layout_table; [zag_table]

        // Private log entrypoints consumed by the Lua-side wrappers in
        // combinators.lua. User code calls `zag.log.info(fmt, ...)`; the
        // Lua wrapper runs string.format and hands the result to these.
        lua.pushFunction(zlua.wrap(zagLogDebugFn));
        lua.setField(-2, "_log_debug");
        lua.pushFunction(zlua.wrap(zagLogInfoFn));
        lua.setField(-2, "_log_info");
        lua.pushFunction(zlua.wrap(zagLogWarnFn));
        lua.setField(-2, "_log_warn");
        lua.pushFunction(zlua.wrap(zagLogErrFn));
        lua.setField(-2, "_log_err");
        lua.pushFunction(zlua.wrap(zagNotifyFn));
        lua.setField(-2, "notify");

        lua.setGlobal("zag");
    }

    /// Fetch the engine pointer stashed by `storeSelfPointer`. Must only be
    /// called from a C-closure registered after `storeSelfPointer` has run;
    /// a missing pointer is a programmer error and aborts via unreachable.
    fn getEngineFromState(lua: *Lua) *LuaEngine {
        _ = lua.getField(zlua.registry_index, "_zag_engine");
        const ptr = lua.toPointer(-1) catch unreachable;
        lua.pop(1);
        return @ptrCast(@alignCast(@constCast(ptr)));
    }

    /// Find the Task owning `co`. Linear scan over the tasks map; tasks are
    /// few in practice (tens). Candidate for an extraspace-based fast path
    /// if it ever shows up in profiles.
    pub fn taskForCoroutine(self: *LuaEngine, co: *Lua) ?*Task {
        var it = self.tasks.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.co == co) return entry.value_ptr.*;
        }
        return null;
    }

    /// Zig function backing `zag.sleep(ms)`. Allocates a sleep Job,
    /// submits it to the worker pool, and yields the coroutine. The
    /// completion drain later calls `resumeFromJob`, which pushes
    /// (true, nil) or (nil, err_tag) onto the coroutine stack and
    /// resumes it. Soft failures (submit errored after alloc) return
    /// (nil, messageing) synchronously; hard errors (bad arg type,
    /// no task) raise a Lua error and unwind.
    fn zagSleepFn(co: *Lua) i32 {
        const engine = getEngineFromState(co);

        if (!co.isYieldable()) {
            co.raiseErrorStr("zag.sleep must be called inside zag.async/hook/keymap", .{});
        }

        const ms_i = co.checkInteger(1);
        if (ms_i < 0) co.raiseErrorStr("zag.sleep: ms must be non-negative", .{});
        const ms: u64 = @intCast(ms_i);

        const task = engine.taskForCoroutine(co) orelse {
            co.raiseErrorStr("zag.sleep: no task for this coroutine", .{});
        };

        // Early-cancel short-circuit: scope already cancelled, don't bother
        // with a Job round-trip; hand back (nil, "cancelled") synchronously.
        if (task.scope.isCancelled()) {
            co.pushNil();
            _ = co.pushString("cancelled");
            return 2;
        }

        const job = engine.allocator.create(async_job.Job) catch {
            co.raiseErrorStr("zag.sleep alloc failed", .{});
        };
        job.* = .{
            .kind = .{ .sleep = .{ .ms = ms } },
            .thread_ref = task.thread_ref,
            .scope = task.scope,
        };
        task.pending_job = job;

        engine.async_runtime.?.pool.submit(job) catch {
            engine.allocator.destroy(job);
            task.pending_job = null;
            co.pushNil();
            _ = co.pushString("io_error: submit failed");
            return 2;
        };

        co.yield(0);
        // yield is noreturn on Lua 5.4.
    }

    /// `zag.spawn(fn, args...)`: starts a new coroutine and returns a
    /// TaskHandle userdata. If the caller is itself running inside a task
    /// (a hook, keymap, or another spawned coroutine), the new task's
    /// scope is parented to the caller's scope so agent-level cancellation
    /// cascades into children. Top-level callers (e.g. config.lua) spawn
    /// under `engine.root_scope`.
    fn zagSpawnFn(co: *Lua) i32 {
        const engine = getEngineFromState(co);
        const nargs = co.getTop() - 1; // first arg is fn
        if (nargs < 0) co.raiseErrorStr("zag.spawn: missing fn", .{});
        if (!co.isFunction(1)) co.raiseErrorStr("zag.spawn: arg 1 must be function", .{});

        const parent: ?*async_scope.Scope = if (engine.taskForCoroutine(co)) |t| t.scope else null;

        // spawnCoroutine operates on `engine.lua`'s stack. When zag.spawn
        // is called from inside another coroutine, [fn, args...] live on
        // `co`'s stack; move them to the main state first.
        if (co != engine.lua) {
            co.xMove(engine.lua, nargs + 1);
        }

        const thread_ref = engine.spawnCoroutine(nargs, parent) catch |err| {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrintZ(&buf, "zag.spawn failed: {s}", .{@errorName(err)}) catch "zag.spawn failed";
            co.raiseErrorStr("%s", .{msg.ptr});
        };

        // Push the TaskHandle userdata on `co`'s stack; that's where the
        // caller expects zag.spawn's return value.
        const h = co.newUserdata(TaskHandle, 0);
        h.* = .{ .thread_ref = thread_ref, .engine = engine };
        _ = co.getMetatableRegistry(TaskHandle.METATABLE_NAME);
        co.setMetatable(-2);
        return 1;
    }

    /// `zag.detach(fn, args...)`: fire-and-forget spawn. Same scope
    /// parenting rules as `zag.spawn`, but returns nothing; the caller
    /// has no handle and cannot cancel or join the child.
    fn zagDetachFn(co: *Lua) i32 {
        const engine = getEngineFromState(co);
        const nargs = co.getTop() - 1;
        if (nargs < 0) co.raiseErrorStr("zag.detach: missing fn", .{});
        if (!co.isFunction(1)) co.raiseErrorStr("zag.detach: arg 1 must be function", .{});

        const parent: ?*async_scope.Scope = if (engine.taskForCoroutine(co)) |t| t.scope else null;

        if (co != engine.lua) {
            co.xMove(engine.lua, nargs + 1);
        }
        _ = engine.spawnCoroutine(nargs, parent) catch |err| {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrintZ(&buf, "zag.detach failed: {s}", .{@errorName(err)}) catch "zag.detach failed";
            co.raiseErrorStr("%s", .{msg.ptr});
        };
        return 0;
    }

    /// `zag.cmd(argv, opts?)`: run a subprocess to completion and return a
    /// result table `{ code, stdout, stderr, truncated }` on success or
    /// `(nil, err_tag)` on failure. Yields until the worker pool finishes.
    ///
    /// Registered as a callable table (`__call` metamethod), which makes
    /// `zag.cmd` itself a Lua table; later tasks hang `.spawn`/`.kill` off
    /// it. When invoked as `zag.cmd(argv, opts)`, Lua passes the table as
    /// arg 1 and the user arguments as args 2+.
    ///
    /// Opts handled here: `cwd`, `timeout_ms`, `max_output_bytes`, `stdin`,
    /// `env`, `env_extra`. `env` replaces the inherited env entirely;
    /// `env_extra` overlays entries on top of the inherited env. Passing
    /// both is a user error.
    ///
    /// Sentinel semantics (match `Job.zig`): `timeout_ms = 0` means "no
    /// timeout, wait indefinitely"; `max_output_bytes = 0` means "unbounded
    /// capture".
    fn zagCmdCallFn(co: *Lua) i32 {
        const engine = getEngineFromState(co);

        if (!co.isYieldable()) {
            co.raiseErrorStr("zag.cmd must be called inside zag.async/hook/keymap", .{});
        }

        // __call invocation layout: [cmd_table, argv, opts?]. argv is always
        // at slot 2 because we only register zag.cmd as a callable table.
        const argv_idx: i32 = 2;
        const opts_idx: i32 = 3;

        if (!co.isTable(argv_idx)) {
            co.raiseErrorStr("zag.cmd: arg 1 must be argv table", .{});
        }

        const argv_len: usize = @intCast(co.rawLen(argv_idx));
        if (argv_len == 0) {
            co.raiseErrorStr("zag.cmd: argv empty", .{});
        }

        // Stage argv/opts strings in a per-task arena so cleanup is one call
        // regardless of how many argv entries there are. Arena is owned by
        // Task.primitive_arena once it's attached; prior to that we own it here.
        const arena_ptr = engine.allocator.create(std.heap.ArenaAllocator) catch {
            co.raiseErrorStr("zag.cmd arena alloc failed", .{});
        };
        arena_ptr.* = std.heap.ArenaAllocator.init(engine.allocator);
        const arena = arena_ptr.allocator();

        const argv = arena.alloc([]const u8, argv_len) catch {
            arena_ptr.deinit();
            engine.allocator.destroy(arena_ptr);
            co.raiseErrorStr("zag.cmd argv alloc failed", .{});
        };
        var i: usize = 0;
        while (i < argv_len) : (i += 1) {
            _ = co.rawGetIndex(argv_idx, @intCast(i + 1));
            defer co.pop(1);
            const s = co.toString(-1) catch {
                arena_ptr.deinit();
                engine.allocator.destroy(arena_ptr);
                co.raiseErrorStr("zag.cmd: argv[%d] is not a string", .{@as(i32, @intCast(i + 1))});
            };
            argv[i] = arena.dupe(u8, s) catch {
                arena_ptr.deinit();
                engine.allocator.destroy(arena_ptr);
                co.raiseErrorStr("zag.cmd argv dupe failed", .{});
            };
        }

        var opts_cwd: ?[]const u8 = null;
        var timeout_ms: u64 = 30_000;
        var max_output: usize = 10 * 1024 * 1024;
        var opts_stdin: ?[]const u8 = null;
        var opts_env_mode: async_job.CmdExecEnvMode = .inherit;
        var opts_env: ?std.process.EnvMap = null;

        if (co.isTable(opts_idx)) {
            _ = co.getField(opts_idx, "cwd");
            if (co.isString(-1)) {
                const s = co.toString(-1) catch "";
                opts_cwd = arena.dupe(u8, s) catch {
                    arena_ptr.deinit();
                    engine.allocator.destroy(arena_ptr);
                    co.raiseErrorStr("zag.cmd opts.cwd dupe failed", .{});
                };
            }
            co.pop(1);

            _ = co.getField(opts_idx, "timeout_ms");
            if (co.isInteger(-1)) {
                const v = co.toInteger(-1) catch 30_000;
                timeout_ms = if (v < 0) 0 else @intCast(v);
            }
            co.pop(1);

            _ = co.getField(opts_idx, "max_output_bytes");
            if (co.isInteger(-1)) {
                const v = co.toInteger(-1) catch @as(i64, @intCast(max_output));
                max_output = if (v < 0) 0 else @intCast(v);
            }
            co.pop(1);

            // stdin: string piped to the child's stdin. The worker closes
            // the pipe once the bytes are drained. Staged in the arena so
            // its lifetime matches the job.
            _ = co.getField(opts_idx, "stdin");
            if (co.isString(-1)) {
                const s = co.toString(-1) catch "";
                opts_stdin = arena.dupe(u8, s) catch {
                    arena_ptr.deinit();
                    engine.allocator.destroy(arena_ptr);
                    co.raiseErrorStr("zag.cmd opts.stdin dupe failed", .{});
                };
            }
            co.pop(1);

            // env vs env_extra. `env` replaces inherited env entirely;
            // `env_extra` overlays on top. Passing both is a user error;
            // the two policies would fight for the same child.env_map.
            const has_env = blk: {
                _ = co.getField(opts_idx, "env");
                const is_table = co.isTable(-1);
                co.pop(1);
                break :blk is_table;
            };
            const has_env_extra = blk: {
                _ = co.getField(opts_idx, "env_extra");
                const is_table = co.isTable(-1);
                co.pop(1);
                break :blk is_table;
            };

            if (has_env and has_env_extra) {
                arena_ptr.deinit();
                engine.allocator.destroy(arena_ptr);
                co.raiseErrorStr("zag.cmd: opts.env and opts.env_extra are mutually exclusive", .{});
            }

            if (has_env or has_env_extra) {
                opts_env_mode = if (has_env) .replace else .extend;
                // Init with the arena allocator: EnvMap owns key/value
                // copies internally, and the arena owns the EnvMap's
                // backing storage. The worker never frees either; Task
                // cleanup deinits the arena after resumeFromJob.
                opts_env = std.process.EnvMap.init(arena);

                const field_name: [:0]const u8 = if (has_env) "env" else "env_extra";
                _ = co.getField(opts_idx, field_name);
                // Iterate: push nil key, next(table) leaves (key, value)
                // on stack until it returns false.
                co.pushNil();
                while (co.next(-2)) {
                    // Stack: [..., env_table, key, value]
                    if (!co.isString(-2) or !co.isString(-1)) {
                        arena_ptr.deinit();
                        engine.allocator.destroy(arena_ptr);
                        co.raiseErrorStr("zag.cmd opts.env entries must be string->string", .{});
                    }
                    const k = co.toString(-2) catch "";
                    const v = co.toString(-1) catch "";
                    opts_env.?.put(k, v) catch {
                        arena_ptr.deinit();
                        engine.allocator.destroy(arena_ptr);
                        co.raiseErrorStr("zag.cmd opts.env put failed", .{});
                    };
                    co.pop(1); // pop value; keep key for next iteration
                }
                co.pop(1); // pop env_table
            }
        }

        const task = engine.taskForCoroutine(co) orelse {
            arena_ptr.deinit();
            engine.allocator.destroy(arena_ptr);
            co.raiseErrorStr("zag.cmd: no task for this coroutine", .{});
        };

        const job = engine.allocator.create(async_job.Job) catch {
            arena_ptr.deinit();
            engine.allocator.destroy(arena_ptr);
            co.raiseErrorStr("zag.cmd job alloc failed", .{});
        };
        job.* = .{
            .kind = .{ .cmd_exec = .{
                .argv = argv,
                .cwd = opts_cwd,
                .stdin_bytes = opts_stdin,
                .env_mode = opts_env_mode,
                .env_map = opts_env,
                .timeout_ms = timeout_ms,
                .max_output_bytes = max_output,
            } },
            .thread_ref = task.thread_ref,
            .scope = task.scope,
        };
        task.pending_job = job;
        task.primitive_arena = arena_ptr;

        if (task.scope.isCancelled()) {
            arena_ptr.deinit();
            engine.allocator.destroy(arena_ptr);
            engine.allocator.destroy(job);
            task.pending_job = null;
            task.primitive_arena = null;
            co.pushNil();
            _ = co.pushString("cancelled");
            return 2;
        }

        engine.async_runtime.?.pool.submit(job) catch {
            arena_ptr.deinit();
            engine.allocator.destroy(arena_ptr);
            engine.allocator.destroy(job);
            task.pending_job = null;
            task.primitive_arena = null;
            co.pushNil();
            _ = co.pushString("io_error: submit failed");
            return 2;
        };

        co.yield(0);
        // yield is noreturn on Lua 5.4.
    }

    /// `zag.http.get(url, opts?)`: synchronous-looking HTTP GET. Yields
    /// the coroutine until the worker finishes the request, then resumes
    /// with (response, nil) on success or (nil, err) on failure.
    /// `response` is a table `{status=int, headers=table, body=string}`;
    /// in v1 `headers` is always an empty table (see primitives/http.zig).
    ///
    /// `opts` is an optional table with:
    ///   - `headers`: map of string->string request headers
    ///   - `timeout_ms`: int, plumbed through but NOT enforced in v1
    ///   - `follow_redirects`: bool, default true (std.http handles up to 3)
    fn zagHttpGetFn(co: *Lua) i32 {
        const engine = getEngineFromState(co);

        if (!co.isYieldable()) {
            co.raiseErrorStr("zag.http.get must be called inside zag.async/hook/keymap", .{});
        }

        // zag.http.get is a plain function (not __call on a table), so
        // arg 1 is the URL and arg 2 the opts table.
        const url_raw = co.checkString(1);
        const opts_idx: i32 = 2;

        // Stage url + headers in a per-task arena so they survive the
        // yield. Arena is owned by Task.primitive_arena once attached;
        // until then we own it here and clean up on every error path.
        const arena_ptr = engine.allocator.create(std.heap.ArenaAllocator) catch {
            co.raiseErrorStr("zag.http.get arena alloc failed", .{});
        };
        arena_ptr.* = std.heap.ArenaAllocator.init(engine.allocator);
        const arena = arena_ptr.allocator();

        const url = arena.dupe(u8, url_raw) catch {
            arena_ptr.deinit();
            engine.allocator.destroy(arena_ptr);
            co.raiseErrorStr("zag.http.get url dupe failed", .{});
        };

        var timeout_ms: u64 = 30_000;
        var follow_redirects: bool = true;
        // Header list backed by the arena so we don't deinit it separately.
        var headers: std.ArrayList(async_job.HttpHeader) = .empty;

        if (co.isTable(opts_idx)) {
            _ = co.getField(opts_idx, "timeout_ms");
            if (co.isInteger(-1)) {
                const v = co.toInteger(-1) catch 30_000;
                timeout_ms = if (v < 0) 0 else @intCast(v);
            }
            co.pop(1);

            _ = co.getField(opts_idx, "follow_redirects");
            if (!co.isNil(-1)) {
                follow_redirects = co.toBoolean(-1);
            }
            co.pop(1);

            _ = co.getField(opts_idx, "headers");
            if (co.isTable(-1)) {
                // Iterate headers table: pushNil seeds the key, next()
                // leaves (key, value) on the stack each iteration.
                co.pushNil();
                while (co.next(-2)) {
                    // Stack: [..., headers_table, key, value]
                    if (!co.isString(-2) or !co.isString(-1)) {
                        arena_ptr.deinit();
                        engine.allocator.destroy(arena_ptr);
                        co.raiseErrorStr("zag.http.get headers entries must be string->string", .{});
                    }
                    const k = co.toString(-2) catch "";
                    const v = co.toString(-1) catch "";
                    const name = arena.dupe(u8, k) catch {
                        arena_ptr.deinit();
                        engine.allocator.destroy(arena_ptr);
                        co.raiseErrorStr("zag.http.get header dupe failed", .{});
                    };
                    const val = arena.dupe(u8, v) catch {
                        arena_ptr.deinit();
                        engine.allocator.destroy(arena_ptr);
                        co.raiseErrorStr("zag.http.get header dupe failed", .{});
                    };
                    headers.append(arena, .{ .name = name, .value = val }) catch {
                        arena_ptr.deinit();
                        engine.allocator.destroy(arena_ptr);
                        co.raiseErrorStr("zag.http.get headers append failed", .{});
                    };
                    co.pop(1); // pop value, keep key for next iteration
                }
            }
            co.pop(1); // pop headers table (or nil)
        }

        // toOwnedSlice transfers the ArrayList items into a plain slice;
        // since the list used the arena, the slice itself is arena-owned
        // and dies with the arena.
        const headers_slice = headers.toOwnedSlice(arena) catch &.{};

        const task = engine.taskForCoroutine(co) orelse {
            arena_ptr.deinit();
            engine.allocator.destroy(arena_ptr);
            co.raiseErrorStr("zag.http.get: no task for this coroutine", .{});
        };

        const job = engine.allocator.create(async_job.Job) catch {
            arena_ptr.deinit();
            engine.allocator.destroy(arena_ptr);
            co.raiseErrorStr("zag.http.get job alloc failed", .{});
        };
        job.* = .{
            .kind = .{ .http_get = .{
                .url = url,
                .headers = headers_slice,
                .timeout_ms = timeout_ms,
                .follow_redirects = follow_redirects,
            } },
            .thread_ref = task.thread_ref,
            .scope = task.scope,
        };
        task.pending_job = job;
        task.primitive_arena = arena_ptr;

        if (task.scope.isCancelled()) {
            arena_ptr.deinit();
            engine.allocator.destroy(arena_ptr);
            engine.allocator.destroy(job);
            task.pending_job = null;
            task.primitive_arena = null;
            co.pushNil();
            _ = co.pushString("cancelled");
            return 2;
        }

        engine.async_runtime.?.pool.submit(job) catch {
            arena_ptr.deinit();
            engine.allocator.destroy(arena_ptr);
            engine.allocator.destroy(job);
            task.pending_job = null;
            task.primitive_arena = null;
            co.pushNil();
            _ = co.pushString("io_error: submit failed");
            return 2;
        };

        co.yield(0);
        // yield is noreturn on Lua 5.4.
    }

    /// `zag.http.post(url, opts?)`: synchronous-looking HTTP POST.
    /// Mirrors `zag.http.get` plus a request body.
    ///
    /// `opts` adds (over `get`):
    ///   - `body`: string (raw bytes) OR table (auto-encoded to JSON).
    ///     Missing / nil is equivalent to an empty body.
    ///   - `content_type`: string. Overrides the defaults below.
    ///
    /// Content-Type behaviour (only applied when `body` is non-nil):
    ///   - Caller-supplied `headers["Content-Type"]` wins unconditionally.
    ///   - Else, `opts.content_type` if set.
    ///   - Else, `"application/json"` when the body came from a table.
    ///   - Else (string body, no hint), no Content-Type is injected;
    ///     the caller didn't ask for one.
    fn zagHttpPostFn(co: *Lua) i32 {
        const engine = getEngineFromState(co);

        if (!co.isYieldable()) {
            co.raiseErrorStr("zag.http.post must be called inside zag.async/hook/keymap", .{});
        }

        const url_raw = co.checkString(1);
        const opts_idx: i32 = 2;

        const arena_ptr = engine.allocator.create(std.heap.ArenaAllocator) catch {
            co.raiseErrorStr("zag.http.post arena alloc failed", .{});
        };
        arena_ptr.* = std.heap.ArenaAllocator.init(engine.allocator);
        const arena = arena_ptr.allocator();

        const url = arena.dupe(u8, url_raw) catch {
            arena_ptr.deinit();
            engine.allocator.destroy(arena_ptr);
            co.raiseErrorStr("zag.http.post url dupe failed", .{});
        };

        var timeout_ms: u64 = 30_000;
        var follow_redirects: bool = true;
        var headers: std.ArrayList(async_job.HttpHeader) = .empty;
        var body_slice: []const u8 = "";
        var body_was_table = false;
        var has_body = false;
        var content_type: []const u8 = "";

        if (co.isTable(opts_idx)) {
            _ = co.getField(opts_idx, "timeout_ms");
            if (co.isInteger(-1)) {
                const v = co.toInteger(-1) catch 30_000;
                timeout_ms = if (v < 0) 0 else @intCast(v);
            }
            co.pop(1);

            _ = co.getField(opts_idx, "follow_redirects");
            if (!co.isNil(-1)) {
                follow_redirects = co.toBoolean(-1);
            }
            co.pop(1);

            _ = co.getField(opts_idx, "content_type");
            if (co.isString(-1)) {
                const s = co.toString(-1) catch "";
                content_type = arena.dupe(u8, s) catch {
                    arena_ptr.deinit();
                    engine.allocator.destroy(arena_ptr);
                    co.raiseErrorStr("zag.http.post content_type dupe failed", .{});
                };
            }
            co.pop(1);

            _ = co.getField(opts_idx, "headers");
            if (co.isTable(-1)) {
                co.pushNil();
                while (co.next(-2)) {
                    if (!co.isString(-2) or !co.isString(-1)) {
                        arena_ptr.deinit();
                        engine.allocator.destroy(arena_ptr);
                        co.raiseErrorStr("zag.http.post headers entries must be string->string", .{});
                    }
                    const k = co.toString(-2) catch "";
                    const v = co.toString(-1) catch "";
                    const name = arena.dupe(u8, k) catch {
                        arena_ptr.deinit();
                        engine.allocator.destroy(arena_ptr);
                        co.raiseErrorStr("zag.http.post header dupe failed", .{});
                    };
                    const val = arena.dupe(u8, v) catch {
                        arena_ptr.deinit();
                        engine.allocator.destroy(arena_ptr);
                        co.raiseErrorStr("zag.http.post header dupe failed", .{});
                    };
                    headers.append(arena, .{ .name = name, .value = val }) catch {
                        arena_ptr.deinit();
                        engine.allocator.destroy(arena_ptr);
                        co.raiseErrorStr("zag.http.post headers append failed", .{});
                    };
                    co.pop(1);
                }
            }
            co.pop(1); // pop headers table (or nil)

            // Body is string OR table. Table → JSON-encoded via
            // luaValueToJson; string → raw bytes; nil → no body.
            _ = co.getField(opts_idx, "body");
            if (co.isTable(-1)) {
                body_was_table = true;
                has_body = true;
                const json = lua_json.luaTableToJson(co, -1, arena) catch {
                    arena_ptr.deinit();
                    engine.allocator.destroy(arena_ptr);
                    co.raiseErrorStr("zag.http.post body JSON encode failed", .{});
                };
                body_slice = json;
            } else if (co.isString(-1)) {
                has_body = true;
                const s = co.toString(-1) catch "";
                body_slice = arena.dupe(u8, s) catch {
                    arena_ptr.deinit();
                    engine.allocator.destroy(arena_ptr);
                    co.raiseErrorStr("zag.http.post body dupe failed", .{});
                };
            }
            co.pop(1); // pop body
        }

        // Default Content-Type only for table bodies when the caller
        // didn't give us an explicit hint. String bodies stay opaque
        // unless opts.content_type (or headers["Content-Type"]) is set.
        if (has_body and body_was_table and content_type.len == 0) {
            content_type = "application/json";
        }

        const headers_slice = headers.toOwnedSlice(arena) catch &.{};

        const task = engine.taskForCoroutine(co) orelse {
            arena_ptr.deinit();
            engine.allocator.destroy(arena_ptr);
            co.raiseErrorStr("zag.http.post: no task for this coroutine", .{});
        };

        const job = engine.allocator.create(async_job.Job) catch {
            arena_ptr.deinit();
            engine.allocator.destroy(arena_ptr);
            co.raiseErrorStr("zag.http.post job alloc failed", .{});
        };
        job.* = .{
            .kind = .{ .http_post = .{
                .url = url,
                .headers = headers_slice,
                .body = body_slice,
                .content_type = content_type,
                .timeout_ms = timeout_ms,
                .follow_redirects = follow_redirects,
            } },
            .thread_ref = task.thread_ref,
            .scope = task.scope,
        };
        task.pending_job = job;
        task.primitive_arena = arena_ptr;

        if (task.scope.isCancelled()) {
            arena_ptr.deinit();
            engine.allocator.destroy(arena_ptr);
            engine.allocator.destroy(job);
            task.pending_job = null;
            task.primitive_arena = null;
            co.pushNil();
            _ = co.pushString("cancelled");
            return 2;
        }

        engine.async_runtime.?.pool.submit(job) catch {
            arena_ptr.deinit();
            engine.allocator.destroy(arena_ptr);
            engine.allocator.destroy(job);
            task.pending_job = null;
            task.primitive_arena = null;
            co.pushNil();
            _ = co.pushString("io_error: submit failed");
            return 2;
        };

        co.yield(0);
        // yield is noreturn on Lua 5.4.
    }

    /// Lua userdata payload for a `CmdHandle`. Storing a pointer (rather
    /// than embedding the struct) keeps the handle's address stable
    /// regardless of how Lua moves the userdata around, and lets the
    /// helper thread hold a raw `*CmdHandle` without worrying about
    /// garbage collection reallocating the userdata's inline storage.
    pub const CmdHandleUd = struct {
        /// Optional so the userdata can be put on the Lua stack with a
        /// stub value BEFORE `CmdHandle.init` runs. If any Lua call
        /// between newUserdata and setMetatable longjmps on OOM, the
        /// userdata still has a metatable whose `__gc` safely no-ops
        /// on a null pointer.
        ptr: ?*cmd_handle_mod.CmdHandle,

        pub const METATABLE_NAME = cmd_handle_mod.CmdHandle.METATABLE_NAME;
    };

    /// `zag.cmd.spawn(argv, opts?)`: spawn a long-lived child process
    /// and return a `CmdHandle` userdata. For 6.4a `opts` honours
    /// `cwd`, `env`, and `env_extra` (same semantics as `zag.cmd`);
    /// `stdin`, `max_output_bytes`, and `timeout_ms` are intentionally
    /// absent; they belong to `:write`/`:lines`/per-op deadlines
    /// implemented in 6.4b/6.4c.
    fn zagCmdSpawnFn(co: *Lua) i32 {
        const engine = getEngineFromState(co);

        const argv_idx: i32 = 1;
        const opts_idx: i32 = 2;

        if (!co.isTable(argv_idx)) {
            co.raiseErrorStr("zag.cmd.spawn: arg 1 must be argv table", .{});
        }
        const argv_len: usize = @intCast(co.rawLen(argv_idx));
        if (argv_len == 0) {
            co.raiseErrorStr("zag.cmd.spawn: argv empty", .{});
        }

        // Stage argv/cwd/env into an arena that lives for the handle's
        // whole lifetime. The CmdHandle owns it and frees it in
        // shutdownAndCleanup.
        const arena_ptr = engine.allocator.create(std.heap.ArenaAllocator) catch {
            co.raiseErrorStr("zag.cmd.spawn arena alloc failed", .{});
        };
        arena_ptr.* = std.heap.ArenaAllocator.init(engine.allocator);
        const arena = arena_ptr.allocator();

        const argv = arena.alloc([]const u8, argv_len) catch {
            arena_ptr.deinit();
            engine.allocator.destroy(arena_ptr);
            co.raiseErrorStr("zag.cmd.spawn argv alloc failed", .{});
        };
        var i: usize = 0;
        while (i < argv_len) : (i += 1) {
            _ = co.rawGetIndex(argv_idx, @intCast(i + 1));
            defer co.pop(1);
            const s = co.toString(-1) catch {
                arena_ptr.deinit();
                engine.allocator.destroy(arena_ptr);
                co.raiseErrorStr("zag.cmd.spawn: argv[%d] is not a string", .{@as(i32, @intCast(i + 1))});
            };
            argv[i] = arena.dupe(u8, s) catch {
                arena_ptr.deinit();
                engine.allocator.destroy(arena_ptr);
                co.raiseErrorStr("zag.cmd.spawn argv dupe failed", .{});
            };
        }

        var opts: cmd_handle_mod.CmdHandle.SpawnOpts = .{};

        if (co.isTable(opts_idx)) {
            _ = co.getField(opts_idx, "cwd");
            if (co.isString(-1)) {
                const s = co.toString(-1) catch "";
                opts.cwd = arena.dupe(u8, s) catch {
                    arena_ptr.deinit();
                    engine.allocator.destroy(arena_ptr);
                    co.raiseErrorStr("zag.cmd.spawn opts.cwd dupe failed", .{});
                };
            }
            co.pop(1);

            // capture_stdout toggles `.Pipe` vs `.Ignore` for the
            // child's stdout. Accept any truthy Lua value; default
            // (false) keeps stdout routed to /dev/null.
            _ = co.getField(opts_idx, "capture_stdout");
            opts.capture_stdout = co.toBoolean(-1);
            co.pop(1);
            // capture_stdin mirrors capture_stdout for the stdin pipe.
            // Required to call `:write(data)`: without it the child's
            // stdin is `.Ignore` and writes surface `io_error: stdin
            // not captured or already closed`.
            _ = co.getField(opts_idx, "capture_stdin");
            opts.capture_stdin = co.toBoolean(-1);
            co.pop(1);
            // capture_stderr is not yet implemented: the helper thread
            // doesn't drain stderr, so a chatty child with a full
            // stderr pipe would stall forever. Reject at spawn time
            // rather than silently mis-wiring the child. Will be
            // enabled when `:stderr_lines()` lands.
            _ = co.getField(opts_idx, "capture_stderr");
            if (co.toBoolean(-1)) {
                co.pop(1);
                arena_ptr.deinit();
                engine.allocator.destroy(arena_ptr);
                co.raiseErrorStr("zag.cmd.spawn: capture_stderr not yet implemented; use capture_stdout or redirect 2>&1", .{});
            }
            co.pop(1);

            // max_line_bytes caps the per-line buffer used by
            // `:lines()`. Accept either an integer (bytes) or absent
            // (falls back to the SpawnOpts default). A Lua number that
            // isn't a non-negative integer is a user mistake; reject.
            _ = co.getField(opts_idx, "max_line_bytes");
            if (!co.isNil(-1)) {
                const n = co.toInteger(-1) catch {
                    co.pop(1);
                    arena_ptr.deinit();
                    engine.allocator.destroy(arena_ptr);
                    co.raiseErrorStr("zag.cmd.spawn: opts.max_line_bytes must be an integer", .{});
                };
                if (n < 0) {
                    co.pop(1);
                    arena_ptr.deinit();
                    engine.allocator.destroy(arena_ptr);
                    co.raiseErrorStr("zag.cmd.spawn: opts.max_line_bytes must be >= 0", .{});
                }
                opts.max_line_bytes = @intCast(n);
            }
            co.pop(1);

            // env vs env_extra. Same rules as zag.cmd: mutually
            // exclusive; env replaces, env_extra overlays on top of
            // the inherited environment.
            const has_env = blk: {
                _ = co.getField(opts_idx, "env");
                const t = co.isTable(-1);
                co.pop(1);
                break :blk t;
            };
            const has_env_extra = blk: {
                _ = co.getField(opts_idx, "env_extra");
                const t = co.isTable(-1);
                co.pop(1);
                break :blk t;
            };
            if (has_env and has_env_extra) {
                arena_ptr.deinit();
                engine.allocator.destroy(arena_ptr);
                co.raiseErrorStr("zag.cmd.spawn: opts.env and opts.env_extra are mutually exclusive", .{});
            }

            if (has_env or has_env_extra) {
                var env_map = std.process.EnvMap.init(arena);
                // env_extra overlays on top of the inherited env, so
                // seed the map with the parent's environment first.
                if (has_env_extra) {
                    var sys_env = std.process.getEnvMap(arena) catch {
                        arena_ptr.deinit();
                        engine.allocator.destroy(arena_ptr);
                        co.raiseErrorStr("zag.cmd.spawn: getEnvMap failed", .{});
                    };
                    var sit = sys_env.iterator();
                    while (sit.next()) |e| env_map.put(e.key_ptr.*, e.value_ptr.*) catch {};
                }

                const field_name: [:0]const u8 = if (has_env) "env" else "env_extra";
                _ = co.getField(opts_idx, field_name);
                co.pushNil();
                while (co.next(-2)) {
                    if (!co.isString(-2) or !co.isString(-1)) {
                        arena_ptr.deinit();
                        engine.allocator.destroy(arena_ptr);
                        co.raiseErrorStr("zag.cmd.spawn opts.env entries must be string->string", .{});
                    }
                    const k = co.toString(-2) catch "";
                    const v = co.toString(-1) catch "";
                    env_map.put(k, v) catch {
                        arena_ptr.deinit();
                        engine.allocator.destroy(arena_ptr);
                        co.raiseErrorStr("zag.cmd.spawn opts.env put failed", .{});
                    };
                    co.pop(1);
                }
                co.pop(1); // env_table
                opts.env_mode = if (has_env) .replace else .extend;
                opts.env_map = env_map;
            }
        }

        // CmdHandle needs a Scope pointer to stuff into completion
        // jobs; the root scope is the right borrow since the handle's
        // lifetime is driven by Lua GC, not by any individual task.
        const root = engine.root_scope orelse {
            arena_ptr.deinit();
            engine.allocator.destroy(arena_ptr);
            co.raiseErrorStr("zag.cmd.spawn: async runtime not initialized", .{});
        };
        const runtime = engine.async_runtime orelse {
            arena_ptr.deinit();
            engine.allocator.destroy(arena_ptr);
            co.raiseErrorStr("zag.cmd.spawn: async runtime not initialized", .{});
        };
        const completions = runtime.completions;

        // Pre-allocate the userdata slot with a null pointer and attach
        // the metatable BEFORE calling CmdHandle.init. If newUserdata or
        // setMetatable longjmps (Lua OOM), the child/helper thread have
        // not been created yet; nothing to leak. If they succeed and
        // init later fails, __gc runs on a null-ptr userdata and is a
        // no-op; we clean up the arena inline and raise the error.
        const ud = co.newUserdata(CmdHandleUd, 0);
        ud.* = .{ .ptr = null };
        _ = co.getMetatableRegistry(CmdHandleUd.METATABLE_NAME);
        co.setMetatable(-2);

        const handle = cmd_handle_mod.CmdHandle.init(
            engine.allocator,
            completions,
            root,
            arena_ptr,
            argv,
            opts,
        ) catch |err| {
            arena_ptr.deinit();
            engine.allocator.destroy(arena_ptr);
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrintZ(&buf, "zag.cmd.spawn failed: {s}", .{@errorName(err)}) catch "zag.cmd.spawn failed";
            co.raiseErrorStr("%s", .{msg.ptr});
        };
        ud.ptr = handle;
        return 1;
    }

    /// `zag.cmd.kill(pid, signal)`: send a POSIX signal to an arbitrary
    /// PID. Sync (no yield), useful for plugins that track external
    /// processes (from pidfiles, other tools, etc.) without going through
    /// a CmdHandle. Returns true on success, `(nil, messageing)` on
    /// failure. Unknown signal names raise a Lua error.
    ///
    /// Signal names: TERM, KILL, INT, HUP, QUIT, USR1, USR2, STOP, CONT
    /// (same set as `CmdHandle:kill`; shares `signalNameToNum`).
    fn zagCmdKillFn(co: *Lua) i32 {
        // Registered as a plain function on zag.cmd, so args start at
        // stack slot 1 (no callable-table receiver to skip).
        const pid_raw = co.checkInteger(1);
        const sig_name = co.checkString(2);

        const signo = cmd_handle_mod.signalNameToNum(sig_name) orelse {
            co.raiseErrorStr("zag.cmd.kill: unknown signal (valid: TERM, KILL, INT, HUP, QUIT, USR1, USR2, STOP, CONT)", .{});
        };

        const pid: std.posix.pid_t = @intCast(pid_raw);
        std.posix.kill(pid, signo) catch |err| {
            co.pushNil();
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrintZ(&buf, "{s}", .{@errorName(err)}) catch "kill failed";
            _ = co.pushString(msg);
            return 2;
        };

        co.pushBoolean(true);
        return 1;
    }

    /// Register the CmdHandle metatable so userdata returned from
    /// `zag.cmd.spawn` carries `:wait`, `:kill`, and `__gc`.
    fn registerCmdHandleMt(lua: *Lua) !void {
        try lua.newMetatable(CmdHandleUd.METATABLE_NAME);
        lua.pushFunction(zlua.wrap(cmdHandleWait));
        lua.setField(-2, "wait");
        lua.pushFunction(zlua.wrap(cmdHandleKill));
        lua.setField(-2, "kill");
        lua.pushFunction(zlua.wrap(cmdHandleLines));
        lua.setField(-2, "lines");
        lua.pushFunction(zlua.wrap(cmdHandleWrite));
        lua.setField(-2, "write");
        lua.pushFunction(zlua.wrap(cmdHandleCloseStdin));
        lua.setField(-2, "close_stdin");
        lua.pushFunction(zlua.wrap(cmdHandlePid));
        lua.setField(-2, "pid");
        // __index = self so `h:wait()` dispatches to wait(h).
        lua.pushValue(-1);
        lua.setField(-2, "__index");
        lua.pushFunction(zlua.wrap(cmdHandleGc));
        lua.setField(-2, "__gc");
        lua.pop(1);
    }

    /// `CmdHandle:wait()`: yield the caller's coroutine until the
    /// child exits; resume with (code, nil). Signal-killed children
    /// return a negative code (e.g. -9 for SIGKILL). If the child has
    /// already exited, returns synchronously.
    ///
    /// v1 limitation: only one coroutine may be inside `:wait()` at a
    /// time per handle. A second concurrent call raises a Lua error.
    /// A single handle is normally awaited by its owning task anyway.
    fn cmdHandleWait(co: *Lua) i32 {
        const engine = getEngineFromState(co);
        const ud = co.checkUserdata(CmdHandleUd, 1, CmdHandleUd.METATABLE_NAME);
        const h = ud.ptr orelse {
            co.raiseErrorStr("cmd:wait: invalid handle", .{});
        };

        // Fast path: child already reaped. Synchronous (code, nil).
        if (h.state.load(.acquire) == .exited) {
            co.pushInteger(h.exit_code orelse -1);
            co.pushNil();
            return 2;
        }

        if (!co.isYieldable()) {
            co.raiseErrorStr("cmd:wait must be called inside a coroutine", .{});
        }

        const task = engine.taskForCoroutine(co) orelse {
            co.raiseErrorStr("cmd:wait: no task for this coroutine", .{});
        };

        // Atomic transition .running -> .waiting. Fails if another
        // coroutine is already suspended in :wait or the child has
        // already exited (the fast path above catches the latter, but
        // the helper could have reaped between our fast-path load and
        // this CAS).
        if (!h.claimWaitSlot()) {
            // Re-check state to distinguish "another coroutine is
            // waiting" from "child was reaped between our fast-path
            // load and this CAS". Only the latter is recoverable;
            // fall through to the fast-path return with the code.
            const now_state = h.state.load(.acquire);
            if (now_state == .exited) {
                if (h.exit_code) |c| {
                    co.pushInteger(c);
                    co.pushNil();
                    return 2;
                }
                // `.exited` with no code stored shouldn't happen;
                // `runWait` always stores a code before the release
                // store. Defensive: surface as io_error so the caller
                // can see something went wrong.
                co.pushNil();
                _ = co.pushString("io_error: handle in .exited with no exit_code");
                return 2;
            }
            // State must be .waiting (we never transition .running
            // -> .running, and .exited is handled above). Another
            // coroutine is the waiter; reject this call.
            co.raiseErrorStr("cmd:wait already has a waiting coroutine", .{});
        }

        h.submit(.{ .wait = .{ .thread_ref = task.thread_ref } }) catch {
            // Revert the slot claim so GC cleanup can proceed with the
            // `.running` fast path instead of thinking a waiter is
            // pending forever.
            h.state.store(.running, .release);
            co.pushNil();
            _ = co.pushString("io_error: cmd:wait submit failed");
            return 2;
        };

        co.yield(0);
    }

    /// `CmdHandle:kill(signal)`: deliver a signal to the child.
    ///
    /// Routed through the helper thread to eliminate the PID-recycle race
    /// that would exist if we called `std.posix.kill` directly from main
    /// (the helper could reap between our state-read and our syscall,
    /// letting the kernel recycle the PID under us).
    ///
    /// Limitation: if a `:wait` is already in flight on this handle (the
    /// helper is blocked in `child.wait()`), this kill sits in the queue
    /// until the child self-exits, at which point `runKill` sees
    /// `.exited` and no-ops. So `:kill` cannot interrupt a pending
    /// `:wait` from another coroutine. To force termination while another
    /// coroutine is awaiting, cancel that coroutine's scope instead;
    /// scope cancellation fires the Job aborter, which `SIGKILL`s the
    /// child directly without going through the helper queue.
    ///
    /// Known signals: TERM, KILL, INT, HUP, QUIT, USR1, USR2, STOP, CONT.
    /// Calling after `:wait()` has returned is a no-op.
    ///
    /// Arg 1: handle userdata. Arg 2: signal name string. Returns nothing.
    fn cmdHandleKill(lua: *Lua) i32 {
        const ud = lua.checkUserdata(CmdHandleUd, 1, CmdHandleUd.METATABLE_NAME);
        const h = ud.ptr orelse {
            lua.raiseErrorStr("cmd:kill: invalid handle", .{});
        };

        const sig_name = lua.checkString(2);
        const signo = cmd_handle_mod.signalNameToNum(sig_name) orelse {
            lua.raiseErrorStr("cmd:kill: unknown signal (valid: TERM, KILL, INT, HUP, QUIT, USR1, USR2, STOP, CONT)", .{});
        };

        if (h.state.load(.acquire) == .exited) {
            // Child already reaped; nothing to signal.
            return 0;
        }

        // Route through the helper so the kill is serialised with
        // `child.wait()` (prevents the PID-recycle race). Note: if a
        // wait is already executing on the helper, the helper is
        // blocked in `child.wait()` and won't pop this kill until the
        // child exits; by which point `runKill` sees `.exited` and
        // no-ops. Use scope cancellation for force-kill while waiting.
        h.submit(.{ .kill = .{ .signo = signo } }) catch |err| {
            log.debug("cmd:kill submit failed: {s}", .{@errorName(err)});
        };
        return 0;
    }

    /// `CmdHandle:pid()`: return the child's PID as an integer. Useful
    /// when feeding the PID into `zag.cmd.kill` or external tools. The
    /// PID is stable for the handle's lifetime (until the child is
    /// reaped by `:wait()` or `__gc`); calling after reap still returns
    /// the recorded value, but signalling it risks hitting a recycled
    /// PID, so don't.
    fn cmdHandlePid(co: *Lua) i32 {
        const ud = co.checkUserdata(CmdHandleUd, 1, CmdHandleUd.METATABLE_NAME);
        const h = ud.ptr orelse {
            co.raiseErrorStr("cmd:pid: invalid handle", .{});
        };
        co.pushInteger(@intCast(h.child.id));
        return 1;
    }

    /// `CmdHandle:lines()`: returns a Lua iterator function. Used in
    /// a generic `for` loop:
    ///
    ///     for line in h:lines() do print(line) end
    ///
    /// Each iteration yields the calling coroutine until the helper
    /// thread has a full newline-terminated segment from the child's
    /// stdout (or hits EOF). Yields nil at EOF, which ends the `for`.
    ///
    /// Requires `capture_stdout = true` at spawn time; otherwise
    /// iterator invocations fail with `io_error: stdout not captured`.
    ///
    /// v1 limitation: the helper thread blocks in `read()` while a
    /// line is pending, so `:wait`/`:kill` commands queued during a
    /// pending `:lines` iteration won't be serviced until that read
    /// returns. Use scope cancellation (which SIGKILLs the child and
    /// drops the pipe → EOF) to interrupt a stuck iterator.
    ///
    /// v1 limitation: a single handle's line buffer is shared across
    /// all `:lines()` iterators; calling `:lines()` twice and
    /// interleaving reads will split lines across iterators. Treat
    /// `:lines()` as "one consumer per handle".
    fn cmdHandleLines(co: *Lua) i32 {
        // Validate the handle up front so misuse (calling on a dead
        // handle) errors here rather than at first iteration.
        const ud = co.checkUserdata(CmdHandleUd, 1, CmdHandleUd.METATABLE_NAME);
        _ = ud.ptr orelse {
            co.raiseErrorStr("cmd:lines: invalid handle", .{});
        };

        // Build a closure that captures the handle userdata as its
        // single upvalue. The `for` loop in Lua calls this closure
        // repeatedly with no arguments; it recovers the handle from
        // the upvalue on each call.
        co.pushValue(1);
        co.pushClosure(zlua.wrap(cmdHandleLinesIter), 1);
        return 1;
    }

    /// Iterator closure produced by `cmdHandleLines`. Recovers the
    /// handle from upvalue(1), submits a `.read_line` helper command,
    /// and yields the caller. The corresponding `.cmd_read_line_done`
    /// job resumes the coroutine with either the line string or nil
    /// (EOF), which is what Lua's generic-for expects.
    fn cmdHandleLinesIter(co: *Lua) i32 {
        const engine = getEngineFromState(co);

        // Retrieve the handle userdata from upvalue slot 1. zlua maps
        // `lua_upvalueindex(i)` through `Lua.upvalueIndex(i)`; we use
        // the returned pseudo-index with `checkUserdata` to validate
        // the metatable.
        const ud = co.checkUserdata(CmdHandleUd, Lua.upvalueIndex(1), CmdHandleUd.METATABLE_NAME);
        const h = ud.ptr orelse {
            co.raiseErrorStr("cmd:lines: invalid handle", .{});
        };

        if (!co.isYieldable()) {
            co.raiseErrorStr("cmd:lines iterator must be called inside a coroutine", .{});
        }

        // Fast path: EOF already observed with nothing buffered. Lua's
        // generic-for ends as soon as we return nil, so callers who
        // finish iterating then call once more (e.g. in a retry loop)
        // don't pay a helper round-trip.
        if (h.stdout_eof and h.stdout_buf.items.len == 0) {
            co.pushNil();
            return 1;
        }

        const task = engine.taskForCoroutine(co) orelse {
            co.raiseErrorStr("cmd:lines: no task for this coroutine", .{});
        };

        h.submit(.{ .read_line = .{ .thread_ref = task.thread_ref } }) catch {
            co.pushNil();
            _ = co.pushString("io_error: cmd:lines submit failed");
            return 2;
        };

        // yield is noreturn on Lua 5.4; no reachable return statement.
        co.yield(0);
    }

    /// `CmdHandle:write(data)`: feeds `data` to the child's stdin
    /// pipe. Must be called from inside a coroutine; yields until the
    /// helper thread finishes writing (or errors with EPIPE because
    /// the child closed the read end). Requires `capture_stdin = true`
    /// at spawn time, otherwise returns `(nil, "io_error: stdin not
    /// captured or already closed")` via the helper.
    fn cmdHandleWrite(co: *Lua) i32 {
        const engine = getEngineFromState(co);
        const ud = co.checkUserdata(CmdHandleUd, 1, CmdHandleUd.METATABLE_NAME);
        const h = ud.ptr orelse {
            co.raiseErrorStr("cmd:write: invalid handle", .{});
        };

        if (!co.isYieldable()) {
            co.raiseErrorStr("cmd:write must be called inside a coroutine", .{});
        }

        const data = co.checkString(2);

        const owned = engine.allocator.dupe(u8, data) catch {
            co.raiseErrorStr("cmd:write alloc failed", .{});
        };

        const task = engine.taskForCoroutine(co) orelse {
            engine.allocator.free(owned);
            co.raiseErrorStr("cmd:write: no task for this coroutine", .{});
        };

        h.submit(.{ .write = .{ .thread_ref = task.thread_ref, .data = owned } }) catch |err| {
            engine.allocator.free(owned);
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrintZ(&buf, "cmd:write submit failed: {s}", .{@errorName(err)}) catch "cmd:write submit failed";
            co.raiseErrorStr("%s", .{msg.ptr});
        };

        co.yield(0);
    }

    /// `CmdHandle:close_stdin()`: closes the child's stdin pipe so
    /// readers in the child see EOF. Idempotent helper-side. Must be
    /// called from inside a coroutine; yields until the helper
    /// confirms the close.
    fn cmdHandleCloseStdin(co: *Lua) i32 {
        const engine = getEngineFromState(co);
        const ud = co.checkUserdata(CmdHandleUd, 1, CmdHandleUd.METATABLE_NAME);
        const h = ud.ptr orelse {
            co.raiseErrorStr("cmd:close_stdin: invalid handle", .{});
        };

        if (!co.isYieldable()) {
            co.raiseErrorStr("cmd:close_stdin must be called inside a coroutine", .{});
        }

        const task = engine.taskForCoroutine(co) orelse {
            co.raiseErrorStr("cmd:close_stdin: no task for this coroutine", .{});
        };

        h.submit(.{ .close_stdin = .{ .thread_ref = task.thread_ref } }) catch |err| {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrintZ(&buf, "cmd:close_stdin submit failed: {s}", .{@errorName(err)}) catch "cmd:close_stdin submit failed";
            co.raiseErrorStr("%s", .{msg.ptr});
        };

        co.yield(0);
    }

    /// `__gc` metamethod; Lua calls this when the userdata becomes
    /// unreachable. Idempotent cleanup: SIGKILL + reap the child if
    /// still running, join the helper thread, free the handle. If the
    /// user called `:wait()` properly this is a cheap no-op.
    fn cmdHandleGc(lua: *Lua) i32 {
        const ud = lua.checkUserdata(CmdHandleUd, 1, CmdHandleUd.METATABLE_NAME);
        // Null ptr is the "spawn failed between newUserdata and
        // CmdHandle.init" case; nothing was created, nothing to tear
        // down.
        const h = ud.ptr orelse return 0;
        h.shutdownAndCleanup();
        return 0;
    }

    /// Lua userdata payload for an `HttpStreamHandle`. Mirrors
    /// `CmdHandleUd`: nullable pointer so the userdata can be placed
    /// on the stack with a stub before the handle exists (longjmp-
    /// safety during `init`), and so `__gc` on a half-built handle is
    /// a no-op.
    pub const HttpStreamHandleUd = struct {
        ptr: ?*http_stream_mod.HttpStreamHandle,

        pub const METATABLE_NAME = http_stream_mod.HttpStreamHandle.METATABLE_NAME;
    };

    /// `zag.http.stream(url, opts?)`: open a streaming GET and return
    /// a handle userdata with `:lines()` and `:close()`.
    ///
    /// `opts` is reserved for future use; v1 accepts the arg so
    /// callers don't have to pass nil but ignores its contents. Body-
    /// less GET only; streaming POST lands later.
    ///
    /// Returns `(handle, nil)` on success, `(nil, err)` on failure.
    fn zagHttpStreamFn(co: *Lua) i32 {
        const engine = getEngineFromState(co);

        const url_raw = co.checkString(1);
        // opts slot 2 is reserved for future wire-up; unused in v1.
        // Leaving the arg shape stable keeps 7.5/8.x additions
        // non-breaking for callers that already pass `nil` or `{}`.

        const root = engine.root_scope orelse {
            co.raiseErrorStr("zag.http.stream: async runtime not initialized", .{});
        };
        const runtime = engine.async_runtime orelse {
            co.raiseErrorStr("zag.http.stream: async runtime not initialized", .{});
        };
        const completions = runtime.completions;

        // Arena outlives the handle; HttpStreamHandle adopts it in
        // init and frees it in shutdownAndCleanup.
        const arena_ptr = engine.allocator.create(std.heap.ArenaAllocator) catch {
            co.raiseErrorStr("zag.http.stream arena alloc failed", .{});
        };
        arena_ptr.* = std.heap.ArenaAllocator.init(engine.allocator);
        const arena = arena_ptr.allocator();

        const url = arena.dupe(u8, url_raw) catch {
            arena_ptr.deinit();
            engine.allocator.destroy(arena_ptr);
            co.raiseErrorStr("zag.http.stream url dupe failed", .{});
        };

        // Pre-create the userdata with a null ptr + metatable BEFORE
        // HttpStreamHandle.init, so a Lua longjmp between newUserdata
        // and setMetatable can't land on a typed userdata without a
        // __gc; same pattern as zag.cmd.spawn.
        const ud = co.newUserdata(HttpStreamHandleUd, 0);
        ud.* = .{ .ptr = null };
        _ = co.getMetatableRegistry(HttpStreamHandleUd.METATABLE_NAME);
        co.setMetatable(-2);

        const handle = http_stream_mod.HttpStreamHandle.init(
            engine.allocator,
            completions,
            root,
            arena_ptr,
            url,
        ) catch |err| {
            // Init failed before the helper thread launched; arena
            // is still ours, free it and surface an error tuple. The
            // userdata already on top of the stack stays a null-ptr
            // shell; its __gc is a no-op.
            arena_ptr.deinit();
            engine.allocator.destroy(arena_ptr);
            // Drop the stub userdata so the returned tuple is
            // (nil, messageing) rather than (ud, messageing).
            co.pop(1);
            co.pushNil();
            _ = co.pushString(switch (err) {
                error.InvalidUri => "invalid_uri",
                error.ConnectFailed => "connect_failed",
                error.TlsError => "tls_error",
                error.HttpError => "http_error",
                error.IoError => "io_error",
                error.OutOfMemory => "io_error: oom",
            });
            return 2;
        };
        ud.ptr = handle;

        // Success: (handle_ud, nil)
        co.pushNil();
        return 2;
    }

    /// Register the HttpStreamHandle metatable so userdata returned
    /// from `zag.http.stream` carries `:lines`, `:close`, and `__gc`.
    fn registerHttpStreamMt(lua: *Lua) !void {
        try lua.newMetatable(HttpStreamHandleUd.METATABLE_NAME);
        lua.pushFunction(zlua.wrap(httpStreamLines));
        lua.setField(-2, "lines");
        lua.pushFunction(zlua.wrap(httpStreamClose));
        lua.setField(-2, "close");
        lua.pushValue(-1);
        lua.setField(-2, "__index");
        lua.pushFunction(zlua.wrap(httpStreamGc));
        lua.setField(-2, "__gc");
        lua.pop(1);
    }

    /// `HttpStreamHandle:lines()`: returns a Lua iterator function
    /// closing over the handle. Idiomatic use:
    ///
    ///     for line in s:lines() do print(line) end
    ///
    /// Each iteration yields the coroutine until the helper delivers
    /// the next newline-terminated segment of the response body, or
    /// returns nil at EOF to end the generic-for.
    fn httpStreamLines(co: *Lua) i32 {
        const ud = co.checkUserdata(HttpStreamHandleUd, 1, HttpStreamHandleUd.METATABLE_NAME);
        _ = ud.ptr orelse {
            co.raiseErrorStr("http_stream:lines: invalid handle", .{});
        };
        co.pushValue(1);
        co.pushClosure(zlua.wrap(httpStreamLinesIter), 1);
        return 1;
    }

    /// Iterator closure produced by `httpStreamLines`. Recovers the
    /// handle from upvalue(1), submits a `.read_line` helper command,
    /// and yields. The corresponding `.http_stream_line_done` job
    /// resumes with either the line string or nil (EOF).
    fn httpStreamLinesIter(co: *Lua) i32 {
        const engine = getEngineFromState(co);

        const ud = co.checkUserdata(HttpStreamHandleUd, Lua.upvalueIndex(1), HttpStreamHandleUd.METATABLE_NAME);
        const h = ud.ptr orelse {
            co.raiseErrorStr("http_stream:lines: invalid handle", .{});
        };

        if (!co.isYieldable()) {
            co.raiseErrorStr("http_stream:lines iterator must be called inside a coroutine", .{});
        }

        // Fast path: EOF observed with nothing buffered. Saves the
        // helper round-trip for the sentinel call after a `for` loop
        // has already seen every line.
        if (h.eof and h.line_buf.items.len == 0) {
            co.pushNil();
            return 1;
        }

        const task = engine.taskForCoroutine(co) orelse {
            co.raiseErrorStr("http_stream:lines: no task for this coroutine", .{});
        };

        h.submit(.{ .read_line = .{ .thread_ref = task.thread_ref } }) catch {
            co.pushNil();
            _ = co.pushString("io_error: http_stream:lines submit failed");
            return 2;
        };

        co.yield(0);
    }

    /// `HttpStreamHandle:close()`: abort the stream early. Flips the
    /// state flag and signals the helper to shut down; the helper
    /// thread is joined only at `__gc` time (or explicit teardown)
    /// because close() runs on the Lua-facing main thread and we
    /// don't want to block Lua on a possibly-stuck recv.
    ///
    /// v1 limitation: if the helper is already blocked inside
    /// `body_reader.read`, close does not interrupt that syscall;
    /// it returns only when the server closes its end of the socket
    /// or the kernel times the connection out. Task 7.5 will wire a
    /// real socket-close aborter.
    fn httpStreamClose(co: *Lua) i32 {
        const ud = co.checkUserdata(HttpStreamHandleUd, 1, HttpStreamHandleUd.METATABLE_NAME);
        const h = ud.ptr orelse return 0;
        h.close();
        return 0;
    }

    /// `__gc` metamethod for HttpStreamHandle userdata. Joins the
    /// helper and frees the handle. Idempotent: if `:close()` was
    /// called previously the helper is already winding down and the
    /// join is cheap. If init failed, ptr is null and we no-op.
    fn httpStreamGc(lua: *Lua) i32 {
        const ud = lua.checkUserdata(HttpStreamHandleUd, 1, HttpStreamHandleUd.METATABLE_NAME);
        const h = ud.ptr orelse return 0;
        h.shutdownAndCleanup();
        return 0;
    }

    /// Shared prelude for every async `zag.fs.*` binding. Validates we're
    /// inside a yieldable coroutine, stages the path string in a per-task
    /// arena, and returns the arena + dup'd path so the caller can build
    /// its Job spec on top. Any failure raises a Lua error; the returned
    /// arena is only valid on success.
    ///
    /// The arena is attached to the Task in `submitFsJob`. Until then the
    /// caller owns it and must tear it down on every error path the way
    /// `zagCmdCallFn` / `zagHttpGetFn` do.
    fn fsStagePath(co: *Lua, op_name: []const u8) struct {
        engine: *LuaEngine,
        arena_ptr: *std.heap.ArenaAllocator,
        path: []const u8,
    } {
        const engine = getEngineFromState(co);
        if (!co.isYieldable()) {
            var buf: [96]u8 = undefined;
            const msg = std.fmt.bufPrintZ(&buf, "{s} must be called inside zag.async/hook/keymap", .{op_name}) catch "zag.fs must be called inside a coroutine";
            co.raiseErrorStr("%s", .{msg.ptr});
        }
        const path_raw = co.checkString(1);

        const arena_ptr = engine.allocator.create(std.heap.ArenaAllocator) catch {
            var buf: [64]u8 = undefined;
            const msg = std.fmt.bufPrintZ(&buf, "{s} arena alloc failed", .{op_name}) catch "zag.fs arena alloc failed";
            co.raiseErrorStr("%s", .{msg.ptr});
        };
        arena_ptr.* = std.heap.ArenaAllocator.init(engine.allocator);
        const path = arena_ptr.allocator().dupe(u8, path_raw) catch {
            arena_ptr.deinit();
            engine.allocator.destroy(arena_ptr);
            var buf: [64]u8 = undefined;
            const msg = std.fmt.bufPrintZ(&buf, "{s} path dupe failed", .{op_name}) catch "zag.fs path dupe failed";
            co.raiseErrorStr("%s", .{msg.ptr});
        };
        return .{ .engine = engine, .arena_ptr = arena_ptr, .path = path };
    }

    /// Shared submit/yield tail for every async `zag.fs.*` binding. Takes
    /// an already-populated `JobKind` + the arena that owns its borrowed
    /// slices. On synchronous failure (no task, already-cancelled scope,
    /// submit error) tears the arena down and returns the appropriate
    /// (nil, err) tuple to Lua by returning 2; on success it attaches the
    /// job to the task, submits, and yields (never returns).
    fn submitFsJob(
        co: *Lua,
        engine: *LuaEngine,
        arena_ptr: *std.heap.ArenaAllocator,
        kind: async_job.JobKind,
        op_name: []const u8,
    ) i32 {
        const task = engine.taskForCoroutine(co) orelse {
            arena_ptr.deinit();
            engine.allocator.destroy(arena_ptr);
            var buf: [96]u8 = undefined;
            const msg = std.fmt.bufPrintZ(&buf, "{s}: no task for this coroutine", .{op_name}) catch "zag.fs: no task for this coroutine";
            co.raiseErrorStr("%s", .{msg.ptr});
        };

        const job = engine.allocator.create(async_job.Job) catch {
            arena_ptr.deinit();
            engine.allocator.destroy(arena_ptr);
            var buf: [64]u8 = undefined;
            const msg = std.fmt.bufPrintZ(&buf, "{s} job alloc failed", .{op_name}) catch "zag.fs job alloc failed";
            co.raiseErrorStr("%s", .{msg.ptr});
        };
        job.* = .{
            .kind = kind,
            .thread_ref = task.thread_ref,
            .scope = task.scope,
        };
        task.pending_job = job;
        task.primitive_arena = arena_ptr;

        if (task.scope.isCancelled()) {
            arena_ptr.deinit();
            engine.allocator.destroy(arena_ptr);
            engine.allocator.destroy(job);
            task.pending_job = null;
            task.primitive_arena = null;
            co.pushNil();
            _ = co.pushString("cancelled");
            return 2;
        }

        engine.async_runtime.?.pool.submit(job) catch {
            arena_ptr.deinit();
            engine.allocator.destroy(arena_ptr);
            engine.allocator.destroy(job);
            task.pending_job = null;
            task.primitive_arena = null;
            co.pushNil();
            _ = co.pushString("io_error: submit failed");
            return 2;
        };

        co.yield(0);
        // yield is noreturn on Lua 5.4.
    }

    /// `zag.fs.read(path)`: read a whole file. Yields until the worker
    /// finishes, then resumes with `(bytes, nil)` or `(nil, err)`.
    fn zagFsReadFn(co: *Lua) i32 {
        const staged = fsStagePath(co, "zag.fs.read");
        return submitFsJob(co, staged.engine, staged.arena_ptr, .{ .fs_read = .{
            .path = staged.path,
        } }, "zag.fs.read");
    }

    /// Shared body for `zag.fs.write` and `zag.fs.append`: identical
    /// except for the `mode` field on the job spec.
    fn zagFsWriteImpl(co: *Lua, comptime mode: enum { overwrite, append }) i32 {
        const op_name = switch (mode) {
            .overwrite => "zag.fs.write",
            .append => "zag.fs.append",
        };
        const staged = fsStagePath(co, op_name);
        const content_raw = co.checkString(2);
        const content = staged.arena_ptr.allocator().dupe(u8, content_raw) catch {
            staged.arena_ptr.deinit();
            staged.engine.allocator.destroy(staged.arena_ptr);
            co.raiseErrorStr("zag.fs write content dupe failed", .{});
        };
        return submitFsJob(co, staged.engine, staged.arena_ptr, .{ .fs_write = .{
            .path = staged.path,
            .content = content,
            .mode = switch (mode) {
                .overwrite => .overwrite,
                .append => .append,
            },
        } }, op_name);
    }

    /// `zag.fs.write(path, content)`: overwrite-or-create.
    fn zagFsWriteFn(co: *Lua) i32 {
        return zagFsWriteImpl(co, .overwrite);
    }

    /// `zag.fs.append(path, content)`: open-or-create, seek to end, write.
    fn zagFsAppendFn(co: *Lua) i32 {
        return zagFsWriteImpl(co, .append);
    }

    /// `zag.fs.mkdir(path, { parents = false })`: `parents=true` walks
    /// the chain (mkdir -p), false requires the parent to exist.
    fn zagFsMkdirFn(co: *Lua) i32 {
        const staged = fsStagePath(co, "zag.fs.mkdir");
        var parents = false;
        if (co.isTable(2)) {
            _ = co.getField(2, "parents");
            if (!co.isNil(-1)) parents = co.toBoolean(-1);
            co.pop(1);
        }
        return submitFsJob(co, staged.engine, staged.arena_ptr, .{ .fs_mkdir = .{
            .path = staged.path,
            .parents = parents,
        } }, "zag.fs.mkdir");
    }

    /// `zag.fs.remove(path, { recursive = false })`: delete a file, an
    /// empty directory, or (with recursive=true) an entire tree.
    fn zagFsRemoveFn(co: *Lua) i32 {
        const staged = fsStagePath(co, "zag.fs.remove");
        var recursive = false;
        if (co.isTable(2)) {
            _ = co.getField(2, "recursive");
            if (!co.isNil(-1)) recursive = co.toBoolean(-1);
            co.pop(1);
        }
        return submitFsJob(co, staged.engine, staged.arena_ptr, .{ .fs_remove = .{
            .path = staged.path,
            .recursive = recursive,
        } }, "zag.fs.remove");
    }

    /// `zag.fs.list(dir)`: list a directory's immediate children as an
    /// array of `{name=string, kind=string}` (kind is file/dir/symlink/
    /// other).
    fn zagFsListFn(co: *Lua) i32 {
        const staged = fsStagePath(co, "zag.fs.list");
        return submitFsJob(co, staged.engine, staged.arena_ptr, .{ .fs_list = .{
            .path = staged.path,
        } }, "zag.fs.list");
    }

    /// `zag.fs.stat(path)`: returns `{kind, size, mtime_ms, mode}` on
    /// success.
    fn zagFsStatFn(co: *Lua) i32 {
        const staged = fsStagePath(co, "zag.fs.stat");
        return submitFsJob(co, staged.engine, staged.arena_ptr, .{ .fs_stat = .{
            .path = staged.path,
        } }, "zag.fs.stat");
    }

    /// `zag.fs.exists(path)`: SYNC; returns a bool and never yields or
    /// errors. A filesystem `access` syscall on a missing file is
    /// cheaper than round-tripping through the worker pool, and a bool
    /// return keeps callsites ergonomic (`if zag.fs.exists(p) then`).
    fn zagFsExistsFn(co: *Lua) i32 {
        const path = co.checkString(1);
        std.fs.cwd().access(path, .{}) catch {
            co.pushBoolean(false);
            return 1;
        };
        co.pushBoolean(true);
        return 1;
    }

    /// `zag.layout.tree()`: return the live window tree as a Lua table
    /// with `root` and `nodes` fields, mirroring the `layout_tree` tool
    /// JSON schema. Runs on the main thread (bindings are invoked from
    /// `config.lua` / hook / keymap contexts) so it reads the window
    /// manager directly instead of round-tripping through the agent
    /// event queue.
    fn zagLayoutTreeFn(lua: *Lua) i32 {
        const engine = getEngineFromState(lua);
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

    /// Call once during LuaEngine.init after openLibs to register the
    /// TaskHandle metatable so userdata created from zag.spawn can find
    /// methods via __index.
    fn registerTaskHandleMt(lua: *Lua) !void {
        try lua.newMetatable(TaskHandle.METATABLE_NAME);
        lua.pushFunction(zlua.wrap(taskHandleCancel));
        lua.setField(-2, "cancel");
        lua.pushFunction(zlua.wrap(taskHandleJoin));
        lua.setField(-2, "join");
        lua.pushFunction(zlua.wrap(taskHandleDone));
        lua.setField(-2, "done");
        // __index = self so method calls work: handle:cancel() -> cancel(handle)
        lua.pushValue(-1);
        lua.setField(-2, "__index");
        lua.pop(1);
    }

    /// TaskHandle:cancel(): marks the task's scope for cancellation.
    /// No-op if task already retired.
    fn taskHandleCancel(lua: *Lua) i32 {
        const engine = getEngineFromState(lua);
        const h = lua.checkUserdata(TaskHandle, 1, TaskHandle.METATABLE_NAME);
        if (h.thread_ref == 0) return 0;
        const task = engine.tasks.get(h.thread_ref) orelse return 0;
        task.scope.cancel("task:cancel") catch |err| {
            log.warn("task:cancel allocator failed: {}", .{err});
        };
        return 0;
    }

    /// TaskHandle:done() -> bool. True iff task is no longer in engine.tasks.
    fn taskHandleDone(lua: *Lua) i32 {
        const engine = getEngineFromState(lua);
        const h = lua.checkUserdata(TaskHandle, 1, TaskHandle.METATABLE_NAME);
        const done = h.thread_ref == 0 or engine.tasks.get(h.thread_ref) == null;
        lua.pushBoolean(done);
        return 1;
    }

    /// TaskHandle:join() -> (true, nil) on target's success or (nil, "cancelled")
    /// if target was cancelled. Must be called inside a coroutine (yields).
    ///
    /// Known limitation: target's Lua return values are NOT forwarded; join is
    /// a completion signal, not a value-transfer. Propagating values across
    /// coroutines requires a registry-backed serializer, out of scope for v1.
    /// Callers that need return values should write to a closed-over upvalue
    /// or a shared Lua table.
    fn taskHandleJoin(co: *Lua) i32 {
        const engine = getEngineFromState(co);
        const h = co.checkUserdata(TaskHandle, 1, TaskHandle.METATABLE_NAME);

        if (!co.isYieldable()) {
            co.raiseErrorStr("task:join must be called inside a coroutine", .{});
        }

        // Resolve the caller's task up-front so the self-join guard fires
        // regardless of whether the target is still live or already retired;
        // a silent self-join would otherwise yield forever (retireTask only
        // runs when the coroutine exits).
        const my_task = engine.taskForCoroutine(co) orelse {
            co.raiseErrorStr("task:join: no task for this coroutine", .{});
        };
        if (my_task.thread_ref == h.thread_ref) {
            co.raiseErrorStr("task:join: cannot join self (would deadlock)", .{});
        }

        // Already retired? Return (true, nil) synchronously. Cancel info died
        // with the task; callers that need that distinction must race via
        // :done() before :join() or use their own completion signal.
        const target = engine.tasks.get(h.thread_ref) orelse {
            co.pushBoolean(true);
            co.pushNil();
            return 2;
        };

        // Register ourselves as a joiner on the target, then yield. Retirement
        // of the target pushes results on our stack and resumes us.
        target.joiners.append(engine.allocator, my_task.thread_ref) catch |err| {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrintZ(&buf, "task:join: {s}", .{@errorName(err)}) catch "task:join: append failed";
            co.raiseErrorStr("%s", .{msg.ptr});
        };
        co.yield(0);
        // yield is noreturn on Lua 5.4.
    }

    /// Store a pointer to this engine in the Lua registry so C callbacks can find it.
    /// Must be called after the struct is at its final memory location, before
    /// any Lua code that calls `zag.tool()`.
    pub fn storeSelfPointer(self: *LuaEngine) void {
        self.lua.pushLightUserdata(@ptrCast(self));
        self.lua.setField(zlua.registry_index, "_zag_engine");
    }

    /// Zig function backing `zag.tool(table)`.
    /// Wrapped via `zlua.wrap` so it has the correct C calling convention.
    fn zagToolFn(lua: *Lua) !i32 {
        return zagToolFnInner(lua) catch |err| {
            log.err("zag.tool() failed: {}", .{err});
            return err;
        };
    }

    fn zagToolFnInner(lua: *Lua) !i32 {
        if (!lua.isTable(1)) {
            log.err("zag.tool() expects a table argument", .{});
            return error.LuaError;
        }

        // Retrieve engine pointer from registry first (needed for allocator)
        _ = lua.getField(zlua.registry_index, "_zag_engine");
        const ptr = lua.toPointer(-1) catch {
            log.err("zag.tool(): engine pointer not set (call storeSelfPointer first)", .{});
            return error.LuaError;
        };
        lua.pop(1);
        const engine: *LuaEngine = @ptrCast(@alignCast(@constCast(ptr)));

        // Read name (Lua string, borrowed from VM; invalidated by next pop)
        _ = lua.getField(1, "name");
        const tool_name = lua.toString(-1) catch {
            log.err("zag.tool(): 'name' field must be a string", .{});
            lua.pop(1);
            return error.LuaError;
        };
        lua.pop(1);

        // Read description (Lua string, borrowed from VM; invalidated by next pop)
        _ = lua.getField(1, "description");
        const description = lua.toString(-1) catch {
            log.err("zag.tool(): 'description' field must be a string", .{});
            lua.pop(1);
            return error.LuaError;
        };
        lua.pop(1);

        // Read optional prompt_snippet (Lua string, borrowed from VM; invalidated by next pop)
        _ = lua.getField(1, "prompt_snippet");
        const prompt_snippet: ?[]const u8 = if (lua.isString(-1))
            lua.toString(-1) catch null
        else
            null;
        lua.pop(1);

        // Read input_schema table and serialize to JSON
        _ = lua.getField(1, "input_schema");
        if (!lua.isTable(-1)) {
            log.err("zag.tool(): 'input_schema' field must be a table", .{});
            lua.pop(1);
            return error.LuaError;
        }
        // input_schema table is at -1
        const schema_json = lua_json.luaTableToJson(lua, -1, engine.allocator) catch |err| {
            log.err("zag.tool(): failed to serialize input_schema: {}", .{err});
            lua.pop(1);
            return err;
        };
        lua.pop(1);
        errdefer engine.allocator.free(schema_json);

        // Read execute function and store as registry reference
        _ = lua.getField(1, "execute");
        if (!lua.isFunction(-1)) {
            log.err("zag.tool(): 'execute' field must be a function", .{});
            lua.pop(1);
            return error.LuaError;
        }
        const func_ref = lua.ref(zlua.registry_index) catch {
            log.err("zag.tool(): failed to create function reference", .{});
            return error.LuaError;
        };
        errdefer lua.unref(zlua.registry_index, func_ref);

        // Dupe borrowed Lua strings into engine allocator
        const tool_name_owned = try engine.allocator.dupe(u8, tool_name);
        errdefer engine.allocator.free(tool_name_owned);

        const description_owned = try engine.allocator.dupe(u8, description);
        errdefer engine.allocator.free(description_owned);

        const prompt_snippet_owned = if (prompt_snippet) |s| try engine.allocator.dupe(u8, s) else null;
        errdefer if (prompt_snippet_owned) |s| engine.allocator.free(s);

        try engine.tools.append(engine.allocator, .{
            .name = tool_name_owned,
            .description = description_owned,
            .input_schema_json = schema_json,
            .prompt_snippet = prompt_snippet_owned,
            .func_ref = func_ref,
        });

        log.info("registered Lua tool: {s}", .{tool_name_owned});
        return 0;
    }

    /// Zig function backing `zag.hook(event_name, opts?, fn)`.
    /// Accepts either (event_name, fn) or (event_name, opts_table, fn).
    fn zagHookFn(lua: *Lua) !i32 {
        return zagHookFnInner(lua) catch |err| {
            log.err("zag.hook() failed: {}", .{err});
            return err;
        };
    }

    fn zagHookFnInner(lua: *Lua) !i32 {
        // Borrowed from the Lua VM; only read before any stack-mutating calls.
        const event_name = lua.toString(1) catch {
            log.err("zag.hook(): first argument must be event name string", .{});
            return error.LuaError;
        };
        const kind = Hooks.parseEventName(event_name) orelse {
            log.err("zag.hook(): unknown event '{s}'", .{event_name});
            return error.LuaError;
        };

        // (name, fn) or (name, opts, fn)
        const fn_index: i32 = if (lua.isFunction(2)) 2 else 3;
        var pattern: ?[]const u8 = null;

        if (fn_index == 3) {
            if (!lua.isTable(2)) {
                log.err("zag.hook(): second argument must be options table or function", .{});
                return error.LuaError;
            }
            _ = lua.getField(2, "pattern");
            if (lua.isString(-1)) {
                pattern = lua.toString(-1) catch null;
            }
            lua.pop(1);
        }

        if (!lua.isFunction(fn_index)) {
            log.err("zag.hook(): last argument must be a function", .{});
            return error.LuaError;
        }

        _ = lua.getField(zlua.registry_index, "_zag_engine");
        const ptr = lua.toPointer(-1) catch {
            log.err("zag.hook(): engine pointer not set (call storeSelfPointer first)", .{});
            return error.LuaError;
        };
        lua.pop(1);
        const engine: *LuaEngine = @ptrCast(@alignCast(@constCast(ptr)));

        lua.pushValue(fn_index);
        const cb_ref = try lua.ref(zlua.registry_index);
        errdefer lua.unref(zlua.registry_index, cb_ref);

        const id = try engine.hook_dispatcher.registry.register(kind, pattern, cb_ref);
        lua.pushInteger(@intCast(id));
        return 1;
    }

    /// Zig function backing `zag.hook_del(id)`.
    fn zagHookDelFn(lua: *Lua) !i32 {
        return zagHookDelFnInner(lua) catch |err| {
            log.err("zag.hook_del() failed: {}", .{err});
            return err;
        };
    }

    fn zagHookDelFnInner(lua: *Lua) !i32 {
        const hook_id = lua.toInteger(1) catch {
            log.err("zag.hook_del(): first argument must be a hook id integer", .{});
            return error.LuaError;
        };

        _ = lua.getField(zlua.registry_index, "_zag_engine");
        const ptr = lua.toPointer(-1) catch {
            log.err("zag.hook_del(): engine pointer not set (call storeSelfPointer first)", .{});
            return error.LuaError;
        };
        lua.pop(1);
        const engine: *LuaEngine = @ptrCast(@alignCast(@constCast(ptr)));

        const id: u32 = @intCast(hook_id);
        // Unref the Lua callback before the hook entry is removed from the registry.
        for (engine.hook_dispatcher.registry.hooks.items) |h| {
            if (h.id == id) {
                engine.lua.unref(zlua.registry_index, h.lua_ref);
                break;
            }
        }
        _ = engine.hook_dispatcher.registry.unregister(id);
        return 0;
    }

    /// Zig function backing `zag.keymap(mode, key, action)`.
    /// Writes a binding into `engine.keymap_registry`. The registry is
    /// owned by the engine and always present, so no null check is needed.
    fn zagKeymapFn(lua: *Lua) !i32 {
        return zagKeymapFnInner(lua) catch |err| {
            log.err("zag.keymap() failed: {}", .{err});
            return err;
        };
    }

    fn zagKeymapFnInner(lua: *Lua) !i32 {
        // All three string args are borrowed from the Lua VM; read them
        // before any stack-mutating calls below.
        const mode_name = lua.toString(1) catch {
            log.err("zag.keymap(): arg 1 (mode) must be a string", .{});
            return error.LuaError;
        };
        const mode: Keymap.Mode = if (std.mem.eql(u8, mode_name, "normal"))
            .normal
        else if (std.mem.eql(u8, mode_name, "insert"))
            .insert
        else {
            log.err("zag.keymap(): unknown mode '{s}'", .{mode_name});
            return error.LuaError;
        };

        const key = lua.toString(2) catch {
            log.err("zag.keymap(): arg 2 (key) must be a string", .{});
            return error.LuaError;
        };
        const spec = Keymap.parseKeySpec(key) catch {
            log.err("zag.keymap(): invalid key spec '{s}'", .{key});
            return error.LuaError;
        };

        const action_name = lua.toString(3) catch {
            log.err("zag.keymap(): arg 3 (action) must be a string", .{});
            return error.LuaError;
        };
        const action = Keymap.parseActionName(action_name) orelse {
            log.err("zag.keymap(): unknown action '{s}'", .{action_name});
            return error.LuaError;
        };

        _ = lua.getField(zlua.registry_index, "_zag_engine");
        const ptr = lua.toPointer(-1) catch {
            log.err("zag.keymap(): engine pointer not set (call storeSelfPointer first)", .{});
            return error.LuaError;
        };
        lua.pop(1);
        const engine: *LuaEngine = @ptrCast(@alignCast(@constCast(ptr)));

        try engine.keymap_registry.register(mode, spec, action);
        return 0;
    }

    /// Zig function backing `zag.set_escape_timeout_ms(ms)`.
    /// Writes the bare-Escape deadline through `engine.input_parser`,
    /// which the orchestrator reads on every tick via
    /// `window_manager.inputParser()`. Negative timeouts are rejected
    /// as a Lua runtime error.
    fn zagSetEscapeTimeoutMsFn(lua: *Lua) !i32 {
        const ms = lua.checkInteger(1);
        if (ms < 0) {
            log.warn("zag.set_escape_timeout_ms(): negative timeout {d}", .{ms});
            return error.LuaError;
        }

        _ = lua.getField(zlua.registry_index, "_zag_engine");
        const ptr = lua.toPointer(-1) catch {
            log.warn("zag.set_escape_timeout_ms(): engine pointer not set (call storeSelfPointer first)", .{});
            return error.LuaError;
        };
        lua.pop(1);
        const engine: *LuaEngine = @ptrCast(@alignCast(@constCast(ptr)));

        engine.input_parser.escape_timeout_ms = ms;
        return 0;
    }

    /// Zig function backing `zag.set_default_model("prov/id")`.
    /// Stores the duped string into `engine.default_model`, freeing any
    /// prior value. Non-string arguments warn-log and return `error.LuaError`
    /// (which `zlua.wrap` surfaces as a Lua runtime error to the caller).
    /// We reject numbers explicitly because Lua 5.4 silently coerces them
    /// through `toString`.
    fn zagSetDefaultModelFn(lua: *Lua) !i32 {
        if (lua.typeOf(1) != .string) {
            log.warn("zag.set_default_model(): arg 1 must be a string", .{});
            return error.LuaError;
        }
        const model = lua.toString(1) catch {
            log.warn("zag.set_default_model(): arg 1 must be a string", .{});
            return error.LuaError;
        };

        _ = lua.getField(zlua.registry_index, "_zag_engine");
        const ptr = lua.toPointer(-1) catch {
            log.warn("zag.set_default_model(): engine pointer not set (call storeSelfPointer first)", .{});
            return error.LuaError;
        };
        lua.pop(1);
        const engine: *LuaEngine = @ptrCast(@alignCast(@constCast(ptr)));

        const owned = try engine.allocator.dupe(u8, model);
        if (engine.default_model) |old| engine.allocator.free(old);
        engine.default_model = owned;
        return 0;
    }

    /// Zig function backing `zag.provider{ name = "..." }`.
    /// Validates `name` against `llm.builtin_endpoints` and appends the duped
    /// string to `engine.enabled_providers`. Unknown names, missing `name`
    /// field, non-string `name`, and empty `name` all return `error.LuaError`
    /// which `zlua.wrap` surfaces as a Lua runtime error.
    fn zagProviderFn(lua: *Lua) !i32 {
        if (!lua.isTable(1)) {
            log.warn("zag.provider() expects a table argument", .{});
            return error.LuaError;
        }

        _ = lua.getField(zlua.registry_index, "_zag_engine");
        const ptr = lua.toPointer(-1) catch {
            log.warn("zag.provider(): engine pointer not set (call storeSelfPointer first)", .{});
            return error.LuaError;
        };
        lua.pop(1);
        const engine: *LuaEngine = @ptrCast(@alignCast(@constCast(ptr)));

        _ = lua.getField(1, "name");
        // Reject missing `name` (nil) and non-string values explicitly; Lua 5.4
        // would otherwise coerce numbers through `toString`.
        if (lua.typeOf(-1) != .string) {
            lua.pop(1);
            log.warn("zag.provider(): 'name' field must be a string", .{});
            return error.LuaError;
        }
        const name = lua.toString(-1) catch {
            lua.pop(1);
            log.warn("zag.provider(): 'name' field must be a string", .{});
            return error.LuaError;
        };

        if (name.len == 0) {
            lua.pop(1);
            log.warn("zag.provider(): 'name' must not be empty", .{});
            return error.LuaError;
        }

        if (!llm.isBuiltinEndpointName(name)) {
            log.warn("zag.provider(): unknown provider '{s}'", .{name});
            lua.pop(1);
            return error.LuaError;
        }

        const owned = try engine.allocator.dupe(u8, name);
        errdefer engine.allocator.free(owned);
        lua.pop(1);

        try engine.enabled_providers.append(engine.allocator, owned);
        return 0;
    }

    // -- zag.log / zag.notify --------------------------------------------------

    /// Scoped logger used by `zag.log.*` and `zag.notify`. Separate scope
    /// from `.lua` so plugin authors can filter their output distinctly
    /// from engine-internal diagnostics.
    const user_log = std.log.scoped(.lua_user);

    fn zagLogDebugFn(co: *Lua) i32 {
        const msg = co.checkString(1);
        user_log.debug("{s}", .{msg});
        return 0;
    }

    fn zagLogInfoFn(co: *Lua) i32 {
        const msg = co.checkString(1);
        user_log.info("{s}", .{msg});
        return 0;
    }

    fn zagLogWarnFn(co: *Lua) i32 {
        const msg = co.checkString(1);
        user_log.warn("{s}", .{msg});
        return 0;
    }

    fn zagLogErrFn(co: *Lua) i32 {
        const msg = co.checkString(1);
        user_log.err("{s}", .{msg});
        return 0;
    }

    /// `zag.notify(msg, opts?)`: v1 routes to `.lua_user` as an info line
    /// prefixed with `[notify]`. A future phase will push these onto a
    /// compositor notification queue and render them in the TUI; for now
    /// plugin authors get a log-level signal they can see.
    fn zagNotifyFn(co: *Lua) i32 {
        const msg = co.checkString(1);
        // opts at slot 2 is optional and currently ignored. Peek `level`
        // so typos surface in type-of-value errors later if we add it.
        if (co.isTable(2)) {
            _ = co.getField(2, "level");
            co.pop(1);
        }
        user_log.info("[notify] {s}", .{msg});
        return 0;
    }

    // -- Hook dispatch wrappers -----------------------------------------------

    /// Set the per-hook wall-clock budget in milliseconds. Delegates to
    /// the dispatcher; see `HookDispatcher.setHookBudgetMs`.
    pub fn setHookBudgetMs(self: *LuaEngine, ms: i64) void {
        self.hook_dispatcher.setHookBudgetMs(ms);
    }

    /// Fire every hook matching `payload`'s event kind from the main
    /// thread. Routes through the hook dispatcher; a `ResumeSink`
    /// wired to engine internals is constructed per call.
    pub fn fireHook(self: *LuaEngine, payload: *Hooks.HookPayload) !?[]const u8 {
        if (self.hook_dispatcher.registry.hooks.items.len == 0) return null;

        // No async runtime → legacy synchronous protectedCall path. The
        // dispatcher handles it directly; no sink needed.
        if (self.async_runtime == null) {
            try self.hook_dispatcher.fireHookSync(payload, self.lua);
            return self.hook_dispatcher.consumePendingCancel();
        }

        const sink = hook_registry_mod.ResumeSink{
            .ctx = self,
            .spawnHookFn = sinkSpawnHook,
            .drainOneFn = sinkDrainOne,
            .isAliveFn = sinkIsAlive,
            .enforceBudgetFn = sinkEnforceBudget,
        };
        return try self.hook_dispatcher.fireHook(payload, self.lua, &sink);
    }

    // -- ResumeSink implementations -------------------------------------------

    fn sinkSpawnHook(ctx: *anyopaque, payload: *Hooks.HookPayload) anyerror!i32 {
        const self: *LuaEngine = @ptrCast(@alignCast(ctx));
        return self.spawnHookCoroutine(1, null, payload);
    }

    fn sinkDrainOne(ctx: *anyopaque) anyerror!bool {
        const self: *LuaEngine = @ptrCast(@alignCast(ctx));
        const runtime = self.async_runtime orelse return false;
        const job = runtime.completions.pop() orelse return false;
        try self.resumeFromJob(job);
        return true;
    }

    fn sinkIsAlive(ctx: *anyopaque, thread_ref: i32) bool {
        const self: *LuaEngine = @ptrCast(@alignCast(ctx));
        return self.tasks.contains(thread_ref);
    }

    /// Walk every live hook task; for each whose wall-clock elapsed since
    /// spawn exceeds `budget_ms`, cancel its scope with reason
    /// "budget_exceeded". Next yield on that coroutine surfaces the
    /// cancellation as the `budget_exceeded` err tag. Safe to call
    /// repeatedly; `Scope.cancel` is idempotent.
    fn sinkEnforceBudget(ctx: *anyopaque, budget_ms: i64) void {
        const self: *LuaEngine = @ptrCast(@alignCast(ctx));
        if (budget_ms <= 0) return;
        const now = std.time.milliTimestamp();
        var it = self.tasks.iterator();
        while (it.next()) |entry| {
            const task = entry.value_ptr.*;
            if (task.hook_payload == null) continue;
            const budget = task.budget_ms orelse continue;
            if (budget <= 0) continue;
            if (now - task.started_at_ms < budget) continue;
            if (task.scope.isCancelled()) continue;
            task.scope.cancel("budget_exceeded") catch |err| {
                log.warn("hook budget cancel failed: {}", .{err});
            };
        }
    }

    // -- Tool execution --------------------------------------------------------

    /// Execute a Lua tool by name with raw JSON input. Returns a ToolResult.
    ///
    /// Errors raised here:
    /// - `InvalidInput`: the raw JSON does not parse.
    /// - `OutOfMemory`: allocator failure while marshalling input or output.
    ///
    /// Lua runtime errors (thrown `error()`, `nil, err` convention, non-string
    /// returns) are surfaced as `ToolResult { is_error = true }` so the LLM
    /// can observe and retry.
    pub fn executeTool(self: *LuaEngine, name: []const u8, input_json: []const u8, allocator: Allocator) types.ToolError!types.ToolResult {
        const tool = self.findTool(name) orelse return .{
            .content = "error: unknown lua tool",
            .is_error = true,
            .owned = false,
        };

        // Push the Lua function via its registry ref
        _ = self.lua.rawGetIndex(zlua.registry_index, tool.func_ref);

        // Parse JSON input and push as Lua table
        lua_json.pushJsonAsTable(self.lua, input_json, self.allocator) catch |err| {
            self.lua.pop(1); // pop the function
            switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    log.err("executeTool: failed to parse input JSON: {}", .{err});
                    return error.InvalidInput;
                },
            }
        };

        // pcall(fn, input_table) -> result_string or nil,err
        self.lua.protectedCall(.{ .args = 1, .results = 2 }) catch {
            const err_msg = self.lua.toString(-1) catch "unknown Lua error";
            const owned_msg = allocator.dupe(u8, err_msg) catch {
                self.lua.pop(1);
                return error.OutOfMemory;
            };
            self.lua.pop(1);
            return .{ .content = owned_msg, .is_error = true };
        };

        // Check return convention: string OR nil,messageing
        if (self.lua.isNoneOrNil(-2)) {
            const err_msg = self.lua.toString(-1) catch "unknown error from Lua tool";
            const owned = allocator.dupe(u8, err_msg) catch {
                self.lua.pop(2);
                return error.OutOfMemory;
            };
            self.lua.pop(2);
            return .{ .content = owned, .is_error = true };
        }

        // Success: first return value is the result string
        const result = self.lua.toString(-2) catch {
            self.lua.pop(2);
            return .{ .content = "error: Lua tool returned non-string", .is_error = true, .owned = false };
        };
        const output = allocator.dupe(u8, result) catch {
            self.lua.pop(2);
            return error.OutOfMemory;
        };
        self.lua.pop(2);
        return .{ .content = output, .is_error = false };
    }

    /// Find a LuaTool by name (linear scan).
    fn findTool(self: *const LuaEngine, name: []const u8) ?LuaTool {
        for (self.tools.items) |tool| {
            if (std.mem.eql(u8, tool.name, name)) return tool;
        }
        return null;
    }

    /// Register all collected Lua tools into a tools.Registry.
    /// Tools dispatch via `tools_mod.luaToolExecute`, which round-trips
    /// the call onto the main thread via the event queue.
    pub fn registerTools(self: *LuaEngine, registry: *tools_mod.Registry) !void {
        for (self.tools.items) |tool| {
            try registry.register(.{
                .definition = .{
                    .name = tool.name,
                    .description = tool.description,
                    .input_schema_json = tool.input_schema_json,
                    .prompt_snippet = tool.prompt_snippet,
                },
                .execute = &tools_mod.luaToolExecute,
            });
        }
    }

    /// Load and execute a Lua config file, collecting any `zag.tool()` calls it makes.
    /// Syntax and runtime errors are caught under protectedCall so a broken
    /// config.lua surfaces a logged warning and a clean Zig error instead of
    /// propagating a raw Lua panic out of the init chain.
    pub fn loadConfig(self: *LuaEngine, path: []const u8) !void {
        self.storeSelfPointer();
        const path_z = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(path_z);

        // Load the file into a closure on the stack without executing.
        // LuaFile/LuaSyntax bubble up here; no Lua message is pushed for LuaFile,
        // so we only drain the stack on LuaSyntax.
        self.lua.loadFile(path_z, .binary_text) catch |err| {
            if (err == error.LuaSyntax) {
                const msg = self.lua.toString(-1) catch "<unprintable>";
                log.warn("config syntax error in {s}: {s}", .{ path, msg });
                self.lua.pop(1);
            }
            return err;
        };

        // Run the loaded chunk under pcall so runtime errors surface as a Zig
        // error instead of crashing the host.
        self.lua.protectedCall(.{ .args = 0, .results = 0 }) catch |err| {
            const msg = self.lua.toString(-1) catch "<unprintable>";
            log.warn("config runtime error in {s}: {s}", .{ path, msg });
            self.lua.pop(1);
            return err;
        };
    }

    /// Adjust package.path so that `require` can find modules in the given directory.
    /// No-op when the sandbox is enabled: `package` and `require` are stripped.
    pub fn setPluginPath(self: *LuaEngine, dir: []const u8) !void {
        if (sandbox_enabled) return;

        const lua_code = try std.fmt.allocPrint(
            self.allocator,
            "package.path = package.path .. ';{s}/?.lua;{s}/?/init.lua'",
            .{ dir, dir },
        );
        defer self.allocator.free(lua_code);

        const lua_code_z = try self.allocator.dupeZ(u8, lua_code);
        defer self.allocator.free(lua_code_z);

        self.lua.doString(lua_code_z) catch |err| {
            log.err("failed to set plugin path: {}", .{err});
            return err;
        };
    }

    /// Spin up the async runtime: completion queue, I/O worker pool, task map,
    /// and root scope. Must be called after `init()` and before any Lua code
    /// tries to spawn coroutines. Failure rolls back partial state.
    pub fn initAsync(self: *LuaEngine, num_workers: usize, capacity: usize) !void {
        std.debug.assert(self.async_runtime == null);

        const runtime = try AsyncRuntime.init(self.allocator, num_workers, capacity);
        errdefer runtime.deinit();

        const root = try async_scope.Scope.init(self.allocator, null);
        errdefer root.deinit();

        self.async_runtime = runtime;
        self.root_scope = root;
    }

    /// Tear down the async runtime in the reverse order of `initAsync`. Safe
    /// to call only if `initAsync` succeeded (mirrors the init/deinit pair
    /// pattern). Must run BEFORE `deinit()` since workers may hold references
    /// into the completion queue.
    pub fn deinitAsync(self: *LuaEngine) void {
        if (self.async_runtime) |rt| {
            rt.deinit();
            self.async_runtime = null;
        }
        // tasks map: any leftover Tasks indicate a coroutine wasn't properly retired.
        // Log a warning; strict assertion would abort release builds on buggy
        // shutdown paths, which is worse than a noisy log line.
        if (self.tasks.count() > 0) {
            std.log.scoped(.lua).warn("deinitAsync: {d} tasks still alive", .{self.tasks.count()});
        }
        self.tasks.deinit();
        if (self.root_scope) |s| {
            s.deinit();
            self.root_scope = null;
        }
    }

    /// Called by the orchestrator tick after a worker posts a completion.
    /// Looks up the owning task by `thread_ref`, pushes the result tuple
    /// onto the coroutine stack via `pushJobResultOntoStack`, frees the
    /// Job, and drives one resume step via `resumeTask`. If the task is
    /// already gone (e.g. scope cancelled and retired synchronously), the
    /// Job and any `err_detail` are freed without a resume.
    pub fn resumeFromJob(self: *LuaEngine, job: *async_job.Job) !void {
        const task = self.tasks.get(job.thread_ref) orelse {
            if (job.err_detail) |d| self.allocator.free(d);
            // Free owned payload slices that would otherwise leak when
            // the task vanished before we could push them onto Lua.
            switch (job.kind) {
                .cmd_read_line_done => |r| if (r.line) |l| self.allocator.free(l),
                .http_stream_line_done => |r| if (r.line) |l| self.allocator.free(l),
                else => {},
            }
            self.allocator.destroy(job);
            return;
        };
        task.pending_job = null;

        const num_values = job_result_mod.pushJobResultOntoStack(self.allocator, task.co, job);
        const err_detail = job.err_detail;
        self.allocator.destroy(job);

        // Result strings have been copied onto the coroutine stack; the
        // per-task primitive arena (argv/cwd/url/headers) is safe to free
        // here, before the coroutine resumes and reuses the task.
        if (task.primitive_arena) |a| {
            a.deinit();
            self.allocator.destroy(a);
            task.primitive_arena = null;
        }

        self.resumeTask(task, num_values);

        if (err_detail) |d| self.allocator.free(d);
    }

    /// Creates a coroutine for the Lua function + `nargs` arguments that are
    /// already on top of `self.lua`'s stack. Layout expected before call:
    /// `[fn, arg1, ..., argN]`. The stack is fully consumed; caller must
    /// not touch the main stack at those slots after this returns.
    ///
    /// Returns the registry ref used as the `Task`'s key. NOTE: if the
    /// coroutine completes synchronously (.ok) or errors on the first
    /// resume, `retireTask` removes it from `self.tasks` and frees it
    /// before this function returns. Callers that need to know whether
    /// the task is still alive should check `self.tasks.get(ref) != null`.
    pub fn spawnCoroutine(self: *LuaEngine, nargs: i32, parent_scope: ?*async_scope.Scope) !i32 {
        return self.spawnCoroutineTagged(nargs, parent_scope, null);
    }

    /// Variant of spawnCoroutine that attaches a hook payload pointer
    /// to the Task before the first resume. This is required so that
    /// hooks which run to completion synchronously (no yields) still
    /// have their return table captured in resumeTask's ok-branch.
    /// A plain spawn-then-tag races against that synchronous retire.
    pub fn spawnHookCoroutine(
        self: *LuaEngine,
        nargs: i32,
        parent_scope: ?*async_scope.Scope,
        payload: *Hooks.HookPayload,
    ) !i32 {
        return self.spawnCoroutineTagged(nargs, parent_scope, payload);
    }

    fn spawnCoroutineTagged(
        self: *LuaEngine,
        nargs: i32,
        parent_scope: ?*async_scope.Scope,
        hook_payload: ?*Hooks.HookPayload,
    ) !i32 {
        std.debug.assert(self.async_runtime != null); // initAsync must have run

        const parent = parent_scope orelse self.root_scope.?;
        const scope = try async_scope.Scope.init(self.allocator, parent);
        errdefer scope.deinit();

        const co = self.lua.newThread();
        // After newThread main stack is [fn, arg1, ..., argN, thread].
        // Rotate thread down below fn+args: [thread, fn, arg1, ..., argN].
        self.lua.insert(-(nargs + 2));
        // Move fn+args to the coroutine; main stack is now [thread].
        self.lua.xMove(co, nargs + 1);
        // Pop thread off main and stash it in the registry.
        const thread_ref = try self.lua.ref(zlua.registry_index);
        errdefer self.lua.unref(zlua.registry_index, thread_ref);

        const task = try self.allocator.create(Task);
        errdefer self.allocator.destroy(task);
        task.* = .{
            .co = co,
            .thread_ref = thread_ref,
            .scope = scope,
            .hook_payload = hook_payload,
            .started_at_ms = if (hook_payload != null) std.time.milliTimestamp() else 0,
            .budget_ms = if (hook_payload != null) self.hook_dispatcher.hook_budget_ms else null,
        };

        try self.tasks.put(thread_ref, task);
        // From here on `task` is owned by `self.tasks`; any further cleanup
        // flows through retireTask. resumeTask is infallible from the
        // caller's POV, so no errdefer needs to fire past this point.

        self.resumeTask(task, nargs);
        return thread_ref;
    }

    /// Drive a task's coroutine one step. On `.ok` the coroutine has
    /// returned and is retired immediately. On `.yield` the task is
    /// left in the map for a later resume (from `resumeFromJob`). On
    /// error the message is logged and the task is retired. Never
    /// propagates an error to the caller; scheduler work runs on the
    /// main thread and there is no meaningful recovery path.
    fn resumeTask(self: *LuaEngine, task: *Task, num_args_on_co: i32) void {
        var num_results: i32 = 0;
        const status = task.co.resumeThread(self.lua, num_args_on_co, &num_results) catch |err| {
            const msg = task.co.toString(-1) catch "<no msg>";
            log.warn("coroutine errored: {s}: {s}", .{ @errorName(err), msg });
            task.co.pop(1);
            self.retireTask(task);
            return;
        };
        switch (status) {
            .ok => {
                // If this task is running a hook callback, peek its
                // return value before we pop. Veto/rewrite tables live
                // on `co`'s stack top and must be consumed here; the
                // coroutine retires in a moment and the values disappear.
                if (task.hook_payload) |hp| {
                    if (num_results >= 1 and task.co.isTable(-1)) {
                        self.hook_dispatcher.applyHookReturnFromCoroutine(task.co, hp) catch |err| {
                            // Fail-soft: the hook ran to completion, but its return
                            // table couldn't be marshalled back into the payload.
                            // Discard the mutations and continue with subsequent hooks.
                            log.warn("hook return apply failed (kind={s}, task={d}): {}, discarding mutations", .{
                                @tagName(hp.kind()), task.thread_ref, err,
                            });
                        };
                    }
                }
                task.co.pop(num_results);
                self.retireTask(task);
            },
            .yield => {
                // Yielded values sit on `co`: the binding that yielded
                // owns their interpretation. zag.sleep yields 0 values
                // today; pop defensively so we never leak stack slots.
                task.co.pop(num_results);
            },
        }
    }

    /// Remove a task from the active set: unregister, unref the thread
    /// from the Lua registry (letting the GC reclaim the coroutine),
    /// tear down the scope, resume any joiners, and free the Task.
    ///
    /// Order matters: we snapshot + free the joiners list BEFORE destroying
    /// the task (so the ArrayList deinit happens against a live allocator),
    /// then destroy the task, then resume joiners against the now-detached
    /// snapshot. Joiners resume with (true, nil) on normal completion or
    /// (nil, "cancelled") if the retiring task's scope was cancelled.
    fn retireTask(self: *LuaEngine, task: *Task) void {
        if (task.primitive_arena) |a| {
            a.deinit();
            self.allocator.destroy(a);
            // task about to be destroyed; no need to null the field
        }

        const was_cancelled = task.scope.isCancelled();

        // Snapshot joiners so we can safely tear down the task's state while
        // still resuming them afterwards. If snapshot alloc fails, joiners
        // block forever; log so the pathological case is visible.
        var joiners_snap: []i32 = &.{};
        if (task.joiners.items.len > 0) {
            joiners_snap = self.allocator.alloc(i32, task.joiners.items.len) catch blk: {
                log.warn(
                    "retireTask: OOM snapshotting joiners; {d} joiners will block forever",
                    .{task.joiners.items.len},
                );
                break :blk &.{};
            };
            if (joiners_snap.len == task.joiners.items.len) {
                @memcpy(joiners_snap, task.joiners.items);
            }
        }
        defer if (joiners_snap.len > 0) self.allocator.free(joiners_snap);
        task.joiners.deinit(self.allocator);

        _ = self.tasks.remove(task.thread_ref);
        self.lua.unref(zlua.registry_index, task.thread_ref);
        task.scope.deinit();
        self.allocator.destroy(task);

        for (joiners_snap) |joiner_ref| {
            const joiner = self.tasks.get(joiner_ref) orelse continue;
            if (was_cancelled) {
                joiner.co.pushNil();
                _ = joiner.co.pushString("cancelled");
            } else {
                joiner.co.pushBoolean(true);
                joiner.co.pushNil();
            }
            self.resumeTask(joiner, 2);
        }
    }
};

// -- Tests -------------------------------------------------------------------

test {
    @import("std").testing.refAllDecls(@This());
}

test "sandbox strips os.execute and friends" {
    if (!sandbox_enabled) return error.SkipZigTest;

    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();

    try engine.lua.doString(
        \\probe = {
        \\  os_execute = type(os.execute),
        \\  io = io,
        \\  debug = debug,
        \\  package = package,
        \\  require = require,
        \\  dofile = dofile,
        \\  loadfile = loadfile,
        \\  load = load,
        \\}
    );

    const checks = [_]struct { field: [:0]const u8, expect_nil: bool }{
        .{ .field = "io", .expect_nil = true },
        .{ .field = "debug", .expect_nil = true },
        .{ .field = "package", .expect_nil = true },
        .{ .field = "require", .expect_nil = true },
        .{ .field = "dofile", .expect_nil = true },
        .{ .field = "loadfile", .expect_nil = true },
        .{ .field = "load", .expect_nil = true },
    };

    _ = try engine.lua.getGlobal("probe");
    defer engine.lua.pop(1);

    _ = engine.lua.getField(-1, "os_execute");
    const os_execute_type = try engine.lua.toString(-1);
    try std.testing.expectEqualStrings("nil", os_execute_type);
    engine.lua.pop(1);

    for (checks) |check| {
        _ = engine.lua.getField(-1, check.field);
        try std.testing.expectEqual(check.expect_nil, engine.lua.isNoneOrNil(-1));
        engine.lua.pop(1);
    }
}

test "sandbox strips string.dump to block bytecode injection" {
    if (!sandbox_enabled) return error.SkipZigTest;

    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();

    try engine.lua.doString("dump_kind = type(string.dump)");
    _ = try engine.lua.getGlobal("dump_kind");
    defer engine.lua.pop(1);
    const kind = try engine.lua.toString(-1);
    try std.testing.expectEqualStrings("nil", kind);
}

test "sandbox preserves minimal os (date, time, clock)" {
    if (!sandbox_enabled) return error.SkipZigTest;

    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();

    try engine.lua.doString(
        \\probe_os = {
        \\  date = type(os.date),
        \\  time = type(os.time),
        \\  clock = type(os.clock),
        \\  execute = type(os.execute),
        \\  remove = type(os.remove),
        \\}
    );

    _ = try engine.lua.getGlobal("probe_os");
    defer engine.lua.pop(1);

    const survivors = [_][:0]const u8{ "date", "time", "clock" };
    for (survivors) |name| {
        _ = engine.lua.getField(-1, name);
        const kind = try engine.lua.toString(-1);
        try std.testing.expectEqualStrings("function", kind);
        engine.lua.pop(1);
    }

    const removed = [_][:0]const u8{ "execute", "remove" };
    for (removed) |name| {
        _ = engine.lua.getField(-1, name);
        const kind = try engine.lua.toString(-1);
        try std.testing.expectEqualStrings("nil", kind);
        engine.lua.pop(1);
    }
}

test "sandbox disabled leaves os.execute reachable" {
    if (sandbox_enabled) return error.SkipZigTest;

    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();

    try engine.lua.doString("probe_exec = type(os.execute)");
    _ = try engine.lua.getGlobal("probe_exec");
    defer engine.lua.pop(1);
    const kind = try engine.lua.toString(-1);
    try std.testing.expectEqualStrings("function", kind);
}

test "LuaEngine init and deinit" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();

    // Verify the VM is alive: we can execute trivial Lua
    try engine.lua.doString("x = 1 + 1");
    _ = try engine.lua.getGlobal("x");
    const val = try engine.lua.toInteger(-1);
    engine.lua.pop(1);
    try std.testing.expectEqual(@as(i64, 2), val);
}

test "LuaEngine.init initializes provider config state" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    try std.testing.expectEqual(@as(usize, 0), engine.enabled_providers.items.len);
    try std.testing.expectEqual(@as(?[]const u8, null), engine.default_model);
}

test "LuaEngine initAsync and deinitAsync work" {
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    try eng.initAsync(2, 16);
    eng.deinitAsync();
}

test "LuaEngine.deinitAsync is safe without initAsync" {
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    // Never call initAsync. deinitAsync must tolerate this.
    eng.deinitAsync();
}

test "spawnCoroutine runs a synchronous Lua function to completion" {
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    eng.storeSelfPointer();
    try eng.initAsync(2, 16);
    defer eng.deinitAsync();

    try eng.lua.doString("function fast() return 42 end");
    _ = try eng.lua.getGlobal("fast");
    _ = try eng.spawnCoroutine(0, null);

    // Synchronous completion retires the task immediately; tasks map is empty.
    try std.testing.expectEqual(@as(u32, 0), eng.tasks.count());
}

test "zag.sleep yields, worker sleeps, coroutine resumes with (true, nil)" {
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    eng.storeSelfPointer();
    try eng.initAsync(2, 16);
    defer eng.deinitAsync();

    // Coroutine body stores (ok, err) into a single global table so we can
    // observe `err == nil` without tripping getGlobal's nil-is-error contract.
    try eng.lua.doString(
        \\function test_sleep()
        \\  local ok, err = zag.sleep(10)
        \\  _test_sleep = { ok = ok, err_is_nil = (err == nil) }
        \\end
    );

    _ = try eng.lua.getGlobal("test_sleep");
    _ = try eng.spawnCoroutine(0, null);

    // Drive the drain-and-resume loop by hand: no orchestrator running in
    // tests, so we poll the completion queue and feed each job through
    // resumeFromJob until the coroutine retires (or the deadline trips).
    const deadline = std.time.milliTimestamp() + 500;
    while (eng.tasks.count() > 0 and std.time.milliTimestamp() < deadline) {
        if (eng.async_runtime.?.completions.pop()) |job| {
            try eng.resumeFromJob(job);
        } else {
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
    }
    try std.testing.expectEqual(@as(u32, 0), eng.tasks.count());

    _ = try eng.lua.getGlobal("_test_sleep");
    defer eng.lua.pop(1);

    _ = eng.lua.getField(-1, "ok");
    try std.testing.expect(eng.lua.toBoolean(-1));
    eng.lua.pop(1);

    _ = eng.lua.getField(-1, "err_is_nil");
    try std.testing.expect(eng.lua.toBoolean(-1));
    eng.lua.pop(1);
}

test "zag.sleep returns (nil, 'cancelled') when scope cancelled mid-sleep" {
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    eng.storeSelfPointer();
    try eng.initAsync(2, 16);
    defer eng.deinitAsync();

    try eng.lua.doString(
        \\function test_cancel()
        \\  local ok, err = zag.sleep(1000)
        \\  _test_cancel = { ok_is_nil = (ok == nil), err = err }
        \\end
    );
    _ = try eng.lua.getGlobal("test_cancel");
    const ref = try eng.spawnCoroutine(0, null);
    const task = eng.tasks.get(ref).?;

    // Cancel immediately; worker is either queued or mid-sleep. Worker's
    // 10ms poll loop in executeJob sees isCancelled() and returns the job
    // with err_tag=.cancelled.
    try task.scope.cancel("test");

    // Drive drain loop until task retires.
    const deadline = std.time.milliTimestamp() + 2000;
    while (eng.tasks.count() > 0 and std.time.milliTimestamp() < deadline) {
        if (eng.async_runtime.?.completions.pop()) |job| {
            try eng.resumeFromJob(job);
        } else {
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
    }
    try std.testing.expectEqual(@as(u32, 0), eng.tasks.count());

    _ = try eng.lua.getGlobal("_test_cancel");
    try std.testing.expect(eng.lua.isTable(-1));

    _ = eng.lua.getField(-1, "ok_is_nil");
    try std.testing.expect(eng.lua.toBoolean(-1));
    eng.lua.pop(1);

    _ = eng.lua.getField(-1, "err");
    const message = try eng.lua.toString(-1);
    try std.testing.expect(std.mem.startsWith(u8, message, "cancelled"));
    eng.lua.pop(1);
    eng.lua.pop(1); // pop table
}

test "zag.sleep returns (nil, 'cancelled') synchronously when scope already cancelled" {
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    eng.storeSelfPointer();
    try eng.initAsync(2, 16);
    defer eng.deinitAsync();

    try eng.lua.doString(
        \\function test_sync_cancel()
        \\  local ok, err = zag.sleep(1000)
        \\  _test_sync_cancel = { ok_is_nil = (ok == nil), err = err }
        \\end
    );

    // Cancel root BEFORE spawnCoroutine; the child scope inherits cancellation
    // and zag.sleep's sync-cancel shortcut returns (nil, "cancelled") without
    // ever submitting a job.
    try eng.root_scope.?.cancel("pre-test");

    _ = try eng.lua.getGlobal("test_sync_cancel");
    _ = try eng.spawnCoroutine(0, null);

    // Task retires synchronously inside spawnCoroutine's first resume.
    try std.testing.expectEqual(@as(u32, 0), eng.tasks.count());

    _ = try eng.lua.getGlobal("_test_sync_cancel");
    try std.testing.expect(eng.lua.isTable(-1));
    _ = eng.lua.getField(-1, "ok_is_nil");
    try std.testing.expect(eng.lua.toBoolean(-1));
    eng.lua.pop(1);
    _ = eng.lua.getField(-1, "err");
    const message = try eng.lua.toString(-1);
    try std.testing.expect(std.mem.eql(u8, message, "cancelled"));
    eng.lua.pop(1);
    eng.lua.pop(1);
}

test "zag.tool() collects tool definitions" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.tool({
        \\  name = "greet",
        \\  description = "Says hello",
        \\  input_schema = {
        \\    type = "object",
        \\    properties = {
        \\      name = { type = "string" }
        \\    }
        \\  },
        \\  execute = function(input)
        \\    return "Hello, " .. input.name
        \\  end
        \\})
    );

    try std.testing.expectEqual(@as(usize, 1), engine.tools.items.len);
    try std.testing.expectEqualStrings("greet", engine.tools.items[0].name);
    try std.testing.expectEqualStrings("Says hello", engine.tools.items[0].description);
    // Verify schema JSON contains expected keys
    try std.testing.expect(std.mem.indexOf(u8, engine.tools.items[0].input_schema_json, "\"type\"") != null);
}

test "luaTableToJson serializes nested tables" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();

    // Push a nested table onto the stack
    try engine.lua.doString(
        \\test_table = {
        \\  str = "hello",
        \\  num = 42,
        \\  flag = true,
        \\  nested = { a = 1 }
        \\}
    );
    _ = try engine.lua.getGlobal("test_table");
    const json = try lua_json.luaTableToJson(engine.lua, -1, std.testing.allocator);
    defer std.testing.allocator.free(json);
    engine.lua.pop(1);

    // Verify it parses back as valid JSON
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value == .object);
    const obj = parsed.value.object;
    try std.testing.expect(obj.get("str") != null);
    try std.testing.expectEqualStrings("hello", obj.get("str").?.string);
    try std.testing.expectEqual(@as(i64, 42), obj.get("num").?.integer);
    try std.testing.expectEqual(true, obj.get("flag").?.bool);
    try std.testing.expect(obj.get("nested") != null);
}

test "executeTool calls Lua function and returns result" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.tool({
        \\  name = "echo",
        \\  description = "Echoes input",
        \\  input_schema = { type = "object" },
        \\  execute = function(input)
        \\    return "echo: " .. (input.message or "nil")
        \\  end
        \\})
    );

    const result = try engine.executeTool("echo", "{\"message\": \"hi\"}", std.testing.allocator);
    defer std.testing.allocator.free(result.content);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("echo: hi", result.content);
}

test "executeTool handles Lua runtime errors" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.tool({
        \\  name = "crasher",
        \\  description = "Always errors",
        \\  input_schema = { type = "object" },
        \\  execute = function(input)
        \\    error("intentional crash")
        \\  end
        \\})
    );

    const result = try engine.executeTool("crasher", "{}", std.testing.allocator);
    defer std.testing.allocator.free(result.content);
    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "intentional crash") != null);
}

test "executeTool handles nil,err return convention" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.tool({
        \\  name = "failsoft",
        \\  description = "Returns nil,err",
        \\  input_schema = { type = "object" },
        \\  execute = function(input)
        \\    return nil, "something went wrong"
        \\  end
        \\})
    );

    const result = try engine.executeTool("failsoft", "{}", std.testing.allocator);
    defer std.testing.allocator.free(result.content);
    try std.testing.expect(result.is_error);
    try std.testing.expectEqualStrings("something went wrong", result.content);
}

test "executeTool returns error for unknown tool" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();

    const result = try engine.executeTool("nonexistent", "{}", std.testing.allocator);
    try std.testing.expect(result.is_error);
    try std.testing.expectEqualStrings("error: unknown lua tool", result.content);
    try std.testing.expect(!result.owned);
}

test "registerTools adds Lua tools to the Zig registry" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.tool({
        \\  name = "lua_test",
        \\  description = "Test tool",
        \\  input_schema = { type = "object" },
        \\  execute = function(input) return "ok" end
        \\})
    );

    var registry = tools_mod.Registry.init(std.testing.allocator);
    defer registry.deinit();

    try engine.registerTools(&registry);

    const found = registry.get("lua_test");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("lua_test", found.?.definition.name);
    try std.testing.expectEqualStrings("Test tool", found.?.definition.description);
}

test "loadConfig loads a Lua file and collects tools" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();

    // Write a temp config file
    const tmp_path = "/tmp/zag_test_config.lua";
    const config_content =
        \\zag.tool({
        \\  name = "from_file",
        \\  description = "Loaded from file",
        \\  input_schema = { type = "object" },
        \\  execute = function(input) return "file tool" end
        \\})
    ;
    {
        const file = try std.fs.createFileAbsolute(tmp_path, .{});
        defer file.close();
        try file.writeAll(config_content);
    }
    defer std.fs.deleteFileAbsolute(tmp_path) catch {};

    try engine.loadConfig(tmp_path);
    try std.testing.expectEqual(@as(usize, 1), engine.tools.items.len);
    try std.testing.expectEqualStrings("from_file", engine.tools.items[0].name);
}

test "loadConfig with nonexistent file returns error" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();

    try std.testing.expectError(
        error.LuaFile,
        engine.loadConfig("/tmp/zag_nonexistent_config_12345.lua"),
    );
}

test "loadConfig reports syntax error gracefully instead of crashing" {
    std.testing.log_level = .err;
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();

    const tmp_path = "/tmp/zag_test_config_syntax_error.lua";
    {
        const file = try std.fs.createFileAbsolute(tmp_path, .{});
        defer file.close();
        // Unclosed table literal: classic syntax error.
        try file.writeAll("local x = { 1, 2,\n");
    }
    defer std.fs.deleteFileAbsolute(tmp_path) catch {};

    try std.testing.expectError(error.LuaSyntax, engine.loadConfig(tmp_path));
}

test "loadConfig reports runtime error gracefully" {
    std.testing.log_level = .err;
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();

    const tmp_path = "/tmp/zag_test_config_runtime_error.lua";
    {
        const file = try std.fs.createFileAbsolute(tmp_path, .{});
        defer file.close();
        try file.writeAll("error('user aborted config')\n");
    }
    defer std.fs.deleteFileAbsolute(tmp_path) catch {};

    try std.testing.expectError(error.LuaRuntime, engine.loadConfig(tmp_path));
}

test "zag.hook registers a hook" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.hook("ToolPre", { pattern = "bash" }, function(evt) end)
        \\zag.hook("TurnEnd", function(evt) end)
    );

    try std.testing.expectEqual(@as(usize, 2), engine.hook_dispatcher.registry.hooks.items.len);
    try std.testing.expectEqualStrings(
        "bash",
        engine.hook_dispatcher.registry.hooks.items[0].pattern.?,
    );
    try std.testing.expect(engine.hook_dispatcher.registry.hooks.items[1].pattern == null);
}

test "zag.hook_del removes a hook" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\_G.id = zag.hook("TurnEnd", function() end)
        \\zag.hook_del(_G.id)
    );
    try std.testing.expectEqual(@as(usize, 0), engine.hook_dispatcher.registry.hooks.items.len);
}

test "fireHook invokes Lua callback for matching event" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();

    engine.storeSelfPointer();
    try engine.lua.doString(
        \\_G.hook_fired_for = nil
        \\zag.hook("TurnStart", function(evt)
        \\  _G.hook_fired_for = evt.turn_num
        \\end)
    );

    var payload: Hooks.HookPayload = .{ .turn_start = .{ .turn_num = 42, .message_count = 3 } };
    _ = try engine.fireHook(&payload);

    _ = engine.lua.getGlobal("hook_fired_for") catch {};
    try std.testing.expectEqual(@as(i64, 42), try engine.lua.toInteger(-1));
    engine.lua.pop(1);
}

test "end-to-end: config file to registry execution" {
    const agent_events = @import("agent_events.zig");
    const AgentRunner = @import("AgentRunner.zig");

    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();

    // Write config
    const tmp_path = "/tmp/zag_test_e2e.lua";
    const config_content =
        \\zag.tool({
        \\  name = "adder",
        \\  description = "Adds two numbers",
        \\  input_schema = {
        \\    type = "object",
        \\    properties = {
        \\      a = { type = "number" },
        \\      b = { type = "number" }
        \\    }
        \\  },
        \\  execute = function(input)
        \\    return tostring(input.a + input.b)
        \\  end
        \\})
    ;
    {
        const file = try std.fs.createFileAbsolute(tmp_path, .{});
        defer file.close();
        try file.writeAll(config_content);
    }
    defer std.fs.deleteFileAbsolute(tmp_path) catch {};

    // Load config
    try engine.loadConfig(tmp_path);

    // Register into registry
    var registry = tools_mod.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try engine.registerTools(&registry);

    // Lua tools now round-trip via the event queue; spawn a pump thread
    // that services `lua_tool_request` events off the queue and dispatches
    // them through dispatchHookRequests, which is the production path.
    var queue = try agent_events.EventQueue.initBounded(std.testing.allocator, 16);
    defer queue.deinit();

    var stop = std.atomic.Value(bool).init(false);
    const pump_thread = try std.Thread.spawn(.{}, struct {
        fn pump(q: *agent_events.EventQueue, eng: *LuaEngine, stop_flag: *std.atomic.Value(bool)) void {
            while (!stop_flag.load(.acquire)) {
                AgentRunner.dispatchHookRequests(q, eng, null);
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }
            // Final drain so any late pushes by the test thread are serviced.
            AgentRunner.dispatchHookRequests(q, eng, null);
        }
    }.pump, .{ &queue, &engine, &stop });
    defer {
        stop.store(true, .release);
        pump_thread.join();
    }

    tools_mod.lua_request_queue = &queue;
    defer tools_mod.lua_request_queue = null;

    // Execute through the full registry path (luaToolExecute -> queue -> dispatcher -> executeTool)
    const result = try registry.execute("adder", "{\"a\": 3, \"b\": 4}", std.testing.allocator, null);
    defer std.testing.allocator.free(result.content);
    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("7", result.content);
}

test "fireHook applies veto" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.hook("ToolPre", { pattern = "bash" }, function(evt)
        \\  return { cancel = true, reason = "no rm" }
        \\end)
    );

    var payload: Hooks.HookPayload = .{ .tool_pre = .{
        .name = "bash",
        .call_id = "id1",
        .args_json = "{\"command\":\"rm -rf /\"}",
        .args_rewrite = null,
    } };
    const reason = try engine.fireHook(&payload);
    try std.testing.expect(reason != null);
    defer std.testing.allocator.free(reason.?);
    try std.testing.expectEqualStrings("no rm", reason.?);
}

test "fireHook applies args rewrite" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.hook("ToolPre", function(evt)
        \\  return { args = { command = "echo safe" } }
        \\end)
    );

    var payload: Hooks.HookPayload = .{ .tool_pre = .{
        .name = "bash",
        .call_id = "id1",
        .args_json = "{\"command\":\"ls\"}",
        .args_rewrite = null,
    } };
    try std.testing.expectEqual(@as(?[]const u8, null), try engine.fireHook(&payload));
    try std.testing.expect(payload.tool_pre.args_rewrite != null);
    defer std.testing.allocator.free(payload.tool_pre.args_rewrite.?);
    try std.testing.expect(std.mem.indexOf(u8, payload.tool_pre.args_rewrite.?, "echo safe") != null);
}

test "UserMessagePre can veto submission" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.hook("UserMessagePre", function(evt)
        \\  if evt.text:match("^/secret") then
        \\    return { cancel = true, reason = "blocked" }
        \\  end
        \\end)
    );

    var payload: Hooks.HookPayload = .{ .user_message_pre = .{
        .text = "/secret thing",
        .text_rewrite = null,
    } };
    const reason = try engine.fireHook(&payload);
    try std.testing.expect(reason != null);
    defer std.testing.allocator.free(reason.?);
    try std.testing.expectEqualStrings("blocked", reason.?);
}

test "UserMessagePre can rewrite text" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.hook("UserMessagePre", function(evt)
        \\  return { text = "expanded: " .. evt.text }
        \\end)
    );

    var payload: Hooks.HookPayload = .{ .user_message_pre = .{
        .text = "hi",
        .text_rewrite = null,
    } };
    try std.testing.expectEqual(@as(?[]const u8, null), try engine.fireHook(&payload));
    try std.testing.expect(payload.user_message_pre.text_rewrite != null);
    defer std.testing.allocator.free(payload.user_message_pre.text_rewrite.?);
    try std.testing.expectEqualStrings("expanded: hi", payload.user_message_pre.text_rewrite.?);
}

test "hook body can call zag.sleep and complete" {
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    eng.storeSelfPointer();
    try eng.initAsync(2, 16);
    defer eng.deinitAsync();

    try eng.lua.doString(
        \\_G._hook_fired = false
        \\zag.hook("ToolPre", { pattern = "bash" }, function(evt)
        \\  zag.sleep(5)
        \\  _G._hook_fired = true
        \\end)
    );

    var payload: Hooks.HookPayload = .{ .tool_pre = .{
        .name = "bash",
        .call_id = "x",
        .args_json = "{}",
        .args_rewrite = null,
    } };
    _ = try eng.fireHook(&payload);

    _ = try eng.lua.getGlobal("_hook_fired");
    try std.testing.expect(eng.lua.toBoolean(-1));
    eng.lua.pop(1);
}

test "zag.keymap registers into the engine-owned registry" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.keymap("normal", "w", "focus_right")
        \\zag.keymap("normal", "<C-q>", "close_window")
    );

    const registry = engine.keymapRegistry();
    try std.testing.expectEqual(
        Keymap.Action.focus_right,
        registry.lookup(.normal, .{ .key = .{ .char = 'w' }, .modifiers = .{} }).?,
    );
    try std.testing.expectEqual(
        Keymap.Action.close_window,
        registry.lookup(.normal, .{
            .key = .{ .char = 'q' },
            .modifiers = .{ .ctrl = true },
        }).?,
    );
}

test "LuaEngine init populates keymap defaults" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();

    const registry = engine.keymapRegistry();
    try std.testing.expectEqual(
        Keymap.Action.focus_left,
        registry.lookup(.normal, .{ .key = .{ .char = 'h' }, .modifiers = .{} }).?,
    );
    try std.testing.expectEqual(
        Keymap.Action.enter_insert_mode,
        registry.lookup(.normal, .{ .key = .{ .char = 'i' }, .modifiers = .{} }).?,
    );
}

test "zag.set_escape_timeout_ms updates Parser.escape_timeout_ms" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString("zag.set_escape_timeout_ms(120)");

    try std.testing.expectEqual(@as(i64, 120), engine.input_parser.escape_timeout_ms);
}

test "zag.set_escape_timeout_ms applied at loadUserConfig time lands on engine parser" {
    // Regression guard for Task 8: without engine-owned input_parser, the
    // timeout silently no-opped because the parser was only wired after
    // loadUserConfig had already run. This test drives the binding through
    // the same path loadUserConfig uses (storeSelfPointer + doString) and
    // asserts the value lands on engine.input_parser.
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString("zag.set_escape_timeout_ms(50)");

    try std.testing.expectEqual(@as(i64, 50), engine.input_parser.escape_timeout_ms);
}

test "zag.set_escape_timeout_ms rejects negative" {
    std.testing.log_level = .err;
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    const result = engine.lua.doString("zag.set_escape_timeout_ms(-10)");
    try std.testing.expectError(error.LuaRuntime, result);
}

test "zag.set_default_model stores the owned string" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString("zag.set_default_model(\"openai/gpt-4o\")");

    try std.testing.expect(engine.default_model != null);
    try std.testing.expectEqualStrings("openai/gpt-4o", engine.default_model.?);
}

test "zag.set_default_model replaces prior value without leaking" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.set_default_model("first/model")
        \\zag.set_default_model("second/model")
    );
    try std.testing.expectEqualStrings("second/model", engine.default_model.?);
}

test "zag.set_default_model rejects non-string argument" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    // `zlua.wrap` surfaces returned Zig errors as Lua runtime errors,
    // which `doString` reports as `error.LuaRuntime` (same mapping as
    // `zag.set_escape_timeout_ms rejects negative`).
    try std.testing.expectError(
        error.LuaRuntime,
        engine.lua.doString("zag.set_default_model(42)"),
    );
}

test "zag.provider registers an enabled provider by name" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.provider { name = "openai" }
        \\zag.provider { name = "anthropic" }
    );

    try std.testing.expectEqual(@as(usize, 2), engine.enabled_providers.items.len);
    try std.testing.expectEqualStrings("openai", engine.enabled_providers.items[0]);
    try std.testing.expectEqualStrings("anthropic", engine.enabled_providers.items[1]);
}

test "zag.provider rejects unknown provider names" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try std.testing.expectError(
        error.LuaRuntime,
        engine.lua.doString("zag.provider { name = \"bogus\" }"),
    );
}

test "zag.provider requires a name field" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try std.testing.expectError(
        error.LuaRuntime,
        engine.lua.doString("zag.provider { }"),
    );
}

test "TaskHandle metatable is registered at engine init" {
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();

    // Retrieve the metatable by name; should be a table.
    _ = eng.lua.getMetatableRegistry(LuaEngine.TaskHandle.METATABLE_NAME);
    try std.testing.expect(eng.lua.isTable(-1));

    // Verify __index is set (the metatable itself, per our registration)
    _ = eng.lua.getField(-1, "__index");
    try std.testing.expect(eng.lua.isTable(-1));
    eng.lua.pop(1);

    // Verify cancel/join/done fields exist as functions
    _ = eng.lua.getField(-1, "cancel");
    try std.testing.expect(eng.lua.isFunction(-1));
    eng.lua.pop(1);
    _ = eng.lua.getField(-1, "join");
    try std.testing.expect(eng.lua.isFunction(-1));
    eng.lua.pop(1);
    _ = eng.lua.getField(-1, "done");
    try std.testing.expect(eng.lua.isFunction(-1));
    eng.lua.pop(1);

    eng.lua.pop(1); // pop the metatable
}

test "zag.spawn returns handle and :done() flips after sleep completes" {
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    eng.storeSelfPointer();
    try eng.initAsync(2, 16);
    defer eng.deinitAsync();

    // Parent spawns a short-sleeping child, checks :done() immediately
    // (must be false while child sleeps), then sleeps long enough for the
    // child to retire and re-checks :done() (must be true).
    try eng.lua.doString(
        \\function outer()
        \\  local t = zag.spawn(function()
        \\    zag.sleep(5)
        \\  end)
        \\  _outer_initial_done = t:done()
        \\  zag.sleep(50)
        \\  _outer_final_done = t:done()
        \\end
    );

    _ = try eng.lua.getGlobal("outer");
    _ = try eng.spawnCoroutine(0, null);

    const deadline = std.time.milliTimestamp() + 2000;
    while (eng.tasks.count() > 0 and std.time.milliTimestamp() < deadline) {
        if (eng.async_runtime.?.completions.pop()) |job| {
            try eng.resumeFromJob(job);
        } else {
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
    }
    try std.testing.expectEqual(@as(u32, 0), eng.tasks.count());

    _ = try eng.lua.getGlobal("_outer_initial_done");
    try std.testing.expect(!eng.lua.toBoolean(-1));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_outer_final_done");
    try std.testing.expect(eng.lua.toBoolean(-1));
    eng.lua.pop(1);
}

test "zag.detach spawns a fire-and-forget coroutine" {
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    eng.storeSelfPointer();
    try eng.initAsync(2, 16);
    defer eng.deinitAsync();

    // zag.detach returns nothing; the child side-effect (setting
    // _detach_ran) is the only evidence it ran.
    try eng.lua.doString(
        \\function outer()
        \\  _detach_rv_count = select('#', zag.detach(function()
        \\    zag.sleep(1)
        \\    _detach_ran = true
        \\  end))
        \\  zag.sleep(50)
        \\end
    );

    _ = try eng.lua.getGlobal("outer");
    _ = try eng.spawnCoroutine(0, null);

    const deadline = std.time.milliTimestamp() + 2000;
    while (eng.tasks.count() > 0 and std.time.milliTimestamp() < deadline) {
        if (eng.async_runtime.?.completions.pop()) |job| {
            try eng.resumeFromJob(job);
        } else {
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
    }
    try std.testing.expectEqual(@as(u32, 0), eng.tasks.count());

    _ = try eng.lua.getGlobal("_detach_rv_count");
    try std.testing.expectEqual(@as(i64, 0), eng.lua.toInteger(-1) catch unreachable);
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_detach_ran");
    try std.testing.expect(eng.lua.toBoolean(-1));
    eng.lua.pop(1);
}

test "task:join yields until target completes, returns (true, nil)" {
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    eng.storeSelfPointer();
    try eng.initAsync(2, 16);
    defer eng.deinitAsync();

    try eng.lua.doString(
        \\function outer()
        \\  local t = zag.spawn(function()
        \\    zag.sleep(10)
        \\  end)
        \\  local ok, err = t:join()
        \\  _outer_ok = ok
        \\  _outer_err_is_nil = (err == nil)
        \\end
    );
    _ = try eng.lua.getGlobal("outer");
    _ = try eng.spawnCoroutine(0, null);

    const deadline = std.time.milliTimestamp() + 2000;
    while (eng.tasks.count() > 0 and std.time.milliTimestamp() < deadline) {
        if (eng.async_runtime.?.completions.pop()) |job| {
            try eng.resumeFromJob(job);
        } else {
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
    }
    try std.testing.expectEqual(@as(u32, 0), eng.tasks.count());

    _ = try eng.lua.getGlobal("_outer_ok");
    try std.testing.expect(eng.lua.toBoolean(-1));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_outer_err_is_nil");
    try std.testing.expect(eng.lua.toBoolean(-1));
    eng.lua.pop(1);
}

test "task:join returns (nil, 'cancelled') when target is cancelled" {
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    eng.storeSelfPointer();
    try eng.initAsync(2, 16);
    defer eng.deinitAsync();

    try eng.lua.doString(
        \\function outer()
        \\  local t = zag.spawn(function()
        \\    zag.sleep(1000) -- will be cancelled mid-flight
        \\  end)
        \\  t:cancel()
        \\  local ok, err = t:join()
        \\  _outer_join = { ok_is_nil = (ok == nil), err = err }
        \\end
    );
    _ = try eng.lua.getGlobal("outer");
    _ = try eng.spawnCoroutine(0, null);

    const deadline = std.time.milliTimestamp() + 2000;
    while (eng.tasks.count() > 0 and std.time.milliTimestamp() < deadline) {
        if (eng.async_runtime.?.completions.pop()) |job| {
            try eng.resumeFromJob(job);
        } else {
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
    }
    try std.testing.expectEqual(@as(u32, 0), eng.tasks.count());

    _ = try eng.lua.getGlobal("_outer_join");
    try std.testing.expect(eng.lua.isTable(-1));
    _ = eng.lua.getField(-1, "ok_is_nil");
    try std.testing.expect(eng.lua.toBoolean(-1));
    eng.lua.pop(1);
    _ = eng.lua.getField(-1, "err");
    const message = try eng.lua.toString(-1);
    try std.testing.expect(std.mem.eql(u8, message, "cancelled"));
    eng.lua.pop(1);
    eng.lua.pop(1);
}

test "zag.all collects results in input order" {
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    eng.storeSelfPointer();
    try eng.initAsync(2, 16);
    defer eng.deinitAsync();

    // Three workers sleep out-of-order and return distinct strings. zag.all
    // must still place them back in the original input slots (1 -> "a",
    // 2 -> "b", 3 -> "c") regardless of retirement order.
    try eng.lua.doString(
        \\function test_all()
        \\  local r = zag.all({
        \\    function() zag.sleep(10); return "a" end,
        \\    function() zag.sleep(5); return "b" end,
        \\    function() zag.sleep(20); return "c" end,
        \\  })
        \\  _all_count = #r
        \\  _all_1 = r[1].value
        \\  _all_2 = r[2].value
        \\  _all_3 = r[3].value
        \\  _all_err1_is_nil = (r[1].err == nil)
        \\end
    );
    _ = try eng.lua.getGlobal("test_all");
    _ = try eng.spawnCoroutine(0, null);

    const deadline = std.time.milliTimestamp() + 2000;
    while (eng.tasks.count() > 0 and std.time.milliTimestamp() < deadline) {
        if (eng.async_runtime.?.completions.pop()) |job| {
            try eng.resumeFromJob(job);
        } else {
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
    }
    try std.testing.expectEqual(@as(u32, 0), eng.tasks.count());

    _ = try eng.lua.getGlobal("_all_count");
    try std.testing.expectEqual(@as(i64, 3), try eng.lua.toInteger(-1));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_all_1");
    try std.testing.expect(std.mem.eql(u8, try eng.lua.toString(-1), "a"));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_all_2");
    try std.testing.expect(std.mem.eql(u8, try eng.lua.toString(-1), "b"));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_all_3");
    try std.testing.expect(std.mem.eql(u8, try eng.lua.toString(-1), "c"));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_all_err1_is_nil");
    try std.testing.expect(eng.lua.toBoolean(-1));
    eng.lua.pop(1);
}

test "zag.race returns fastest value and reports winning index" {
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    eng.storeSelfPointer();
    try eng.initAsync(2, 16);
    defer eng.deinitAsync();

    // Middle worker is the shortest; it should win and losers get cancelled
    // before they return their strings.
    try eng.lua.doString(
        \\function test_race()
        \\  local v, err, idx = zag.race({
        \\    function() zag.sleep(50); return "slow" end,
        \\    function() zag.sleep(5); return "fast" end,
        \\    function() zag.sleep(100); return "slower" end,
        \\  })
        \\  _race_winner = v
        \\  _race_err_is_nil = (err == nil)
        \\  _race_idx = idx
        \\end
    );
    _ = try eng.lua.getGlobal("test_race");
    _ = try eng.spawnCoroutine(0, null);

    const deadline = std.time.milliTimestamp() + 2000;
    while (eng.tasks.count() > 0 and std.time.milliTimestamp() < deadline) {
        if (eng.async_runtime.?.completions.pop()) |job| {
            try eng.resumeFromJob(job);
        } else {
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
    }
    try std.testing.expectEqual(@as(u32, 0), eng.tasks.count());

    _ = try eng.lua.getGlobal("_race_winner");
    try std.testing.expect(std.mem.eql(u8, try eng.lua.toString(-1), "fast"));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_race_err_is_nil");
    try std.testing.expect(eng.lua.toBoolean(-1));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_race_idx");
    try std.testing.expectEqual(@as(i64, 2), try eng.lua.toInteger(-1));
    eng.lua.pop(1);
}

test "zag.timeout returns err='timeout' when fn overshoots deadline" {
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    eng.storeSelfPointer();
    try eng.initAsync(2, 16);
    defer eng.deinitAsync();

    // 50ms deadline vs 1000ms sleep: the timer fires first and cancels
    // the worker. zag.timeout should surface (nil, "timeout").
    try eng.lua.doString(
        \\function test_timeout()
        \\  local v, err = zag.timeout(50, function()
        \\    zag.sleep(1000)
        \\    return "late"
        \\  end)
        \\  _to_v_is_nil = (v == nil)
        \\  _to_err = err
        \\end
    );
    _ = try eng.lua.getGlobal("test_timeout");
    _ = try eng.spawnCoroutine(0, null);

    const deadline = std.time.milliTimestamp() + 2000;
    while (eng.tasks.count() > 0 and std.time.milliTimestamp() < deadline) {
        if (eng.async_runtime.?.completions.pop()) |job| {
            try eng.resumeFromJob(job);
        } else {
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
    }
    try std.testing.expectEqual(@as(u32, 0), eng.tasks.count());

    _ = try eng.lua.getGlobal("_to_v_is_nil");
    try std.testing.expect(eng.lua.toBoolean(-1));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_to_err");
    try std.testing.expect(std.mem.eql(u8, try eng.lua.toString(-1), "timeout"));
    eng.lua.pop(1);
}

test "zag.timeout passes through value when fn beats deadline" {
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    eng.storeSelfPointer();
    try eng.initAsync(2, 16);
    defer eng.deinitAsync();

    // fn sleeps well inside the 500ms deadline. zag.timeout must return
    // ("quick", nil) and drop the timer without firing.
    try eng.lua.doString(
        \\function test_timeout_win()
        \\  local v, err = zag.timeout(500, function()
        \\    zag.sleep(10)
        \\    return "quick"
        \\  end)
        \\  _tow_v = v
        \\  _tow_err_is_nil = (err == nil)
        \\end
    );
    _ = try eng.lua.getGlobal("test_timeout_win");
    _ = try eng.spawnCoroutine(0, null);

    const deadline = std.time.milliTimestamp() + 2000;
    while (eng.tasks.count() > 0 and std.time.milliTimestamp() < deadline) {
        if (eng.async_runtime.?.completions.pop()) |job| {
            try eng.resumeFromJob(job);
        } else {
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
    }
    try std.testing.expectEqual(@as(u32, 0), eng.tasks.count());

    _ = try eng.lua.getGlobal("_tow_v");
    try std.testing.expect(std.mem.eql(u8, try eng.lua.toString(-1), "quick"));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_tow_err_is_nil");
    try std.testing.expect(eng.lua.toBoolean(-1));
    eng.lua.pop(1);
}

test "zag.cmd({/bin/echo,hello}) returns result table with stdout" {
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    eng.storeSelfPointer();
    try eng.initAsync(2, 16);
    defer eng.deinitAsync();

    try eng.lua.doString(
        \\function test_cmd()
        \\  local r, err = zag.cmd({ "/bin/echo", "hello" })
        \\  _cmd_err_is_nil = (err == nil)
        \\  if r then
        \\    _cmd_code = r.code
        \\    _cmd_stdout = r.stdout
        \\    _cmd_truncated = r.truncated
        \\  end
        \\end
    );
    _ = try eng.lua.getGlobal("test_cmd");
    _ = try eng.spawnCoroutine(0, null);

    const deadline = std.time.milliTimestamp() + 2000;
    while (eng.tasks.count() > 0 and std.time.milliTimestamp() < deadline) {
        if (eng.async_runtime.?.completions.pop()) |job| {
            try eng.resumeFromJob(job);
        } else {
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
    }
    try std.testing.expectEqual(@as(u32, 0), eng.tasks.count());

    _ = try eng.lua.getGlobal("_cmd_err_is_nil");
    try std.testing.expect(eng.lua.toBoolean(-1));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_cmd_code");
    try std.testing.expectEqual(@as(i64, 0), try eng.lua.toInteger(-1));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_cmd_stdout");
    const stdout = try eng.lua.toString(-1);
    try std.testing.expect(std.mem.startsWith(u8, stdout, "hello"));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_cmd_truncated");
    try std.testing.expect(!eng.lua.toBoolean(-1));
    eng.lua.pop(1);
}

test "zag.cmd stdin piped to /bin/cat echoes back" {
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    eng.storeSelfPointer();
    try eng.initAsync(2, 16);
    defer eng.deinitAsync();

    try eng.lua.doString(
        \\function test_cat()
        \\  local r, err = zag.cmd({ "/bin/cat" }, { stdin = "piped-input" })
        \\  _cat_err_is_nil = (err == nil)
        \\  if r then _cat_stdout = r.stdout end
        \\end
    );
    _ = try eng.lua.getGlobal("test_cat");
    _ = try eng.spawnCoroutine(0, null);

    const deadline = std.time.milliTimestamp() + 2000;
    while (eng.tasks.count() > 0 and std.time.milliTimestamp() < deadline) {
        if (eng.async_runtime.?.completions.pop()) |job| {
            try eng.resumeFromJob(job);
        } else {
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
    }
    try std.testing.expectEqual(@as(u32, 0), eng.tasks.count());

    _ = try eng.lua.getGlobal("_cat_err_is_nil");
    try std.testing.expect(eng.lua.toBoolean(-1));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_cat_stdout");
    const s = try eng.lua.toString(-1);
    try std.testing.expect(std.mem.eql(u8, s, "piped-input"));
    eng.lua.pop(1);
}

test "zag.cmd env_extra sets env var visible to child" {
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    eng.storeSelfPointer();
    try eng.initAsync(2, 16);
    defer eng.deinitAsync();

    try eng.lua.doString(
        \\function test_env()
        \\  local r, err = zag.cmd({ "/bin/sh", "-c", "echo $ZAG_TEST_VAR" }, {
        \\    env_extra = { ZAG_TEST_VAR = "hello-env" },
        \\  })
        \\  _env_err_is_nil = (err == nil)
        \\  if r then _env_stdout = r.stdout end
        \\end
    );
    _ = try eng.lua.getGlobal("test_env");
    _ = try eng.spawnCoroutine(0, null);

    const deadline = std.time.milliTimestamp() + 2000;
    while (eng.tasks.count() > 0 and std.time.milliTimestamp() < deadline) {
        if (eng.async_runtime.?.completions.pop()) |job| {
            try eng.resumeFromJob(job);
        } else {
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
    }
    try std.testing.expectEqual(@as(u32, 0), eng.tasks.count());

    _ = try eng.lua.getGlobal("_env_err_is_nil");
    try std.testing.expect(eng.lua.toBoolean(-1));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_env_stdout");
    const s = try eng.lua.toString(-1);
    try std.testing.expect(std.mem.startsWith(u8, s, "hello-env"));
    eng.lua.pop(1);
}

test "zag.cmd timeout_ms kills long-running process" {
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    eng.storeSelfPointer();
    try eng.initAsync(2, 16);
    defer eng.deinitAsync();

    try eng.lua.doString(
        \\function test_timeout()
        \\  local r, err = zag.cmd({ "/bin/sleep", "10" }, { timeout_ms = 100 })
        \\  _to_r_is_nil = (r == nil)
        \\  _to_err = err
        \\end
    );
    _ = try eng.lua.getGlobal("test_timeout");
    _ = try eng.spawnCoroutine(0, null);

    const start = std.time.milliTimestamp();
    const deadline = start + 3000;
    while (eng.tasks.count() > 0 and std.time.milliTimestamp() < deadline) {
        if (eng.async_runtime.?.completions.pop()) |job| {
            try eng.resumeFromJob(job);
        } else {
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
    }
    const elapsed = std.time.milliTimestamp() - start;
    try std.testing.expectEqual(@as(u32, 0), eng.tasks.count());

    _ = try eng.lua.getGlobal("_to_r_is_nil");
    try std.testing.expect(eng.lua.toBoolean(-1));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_to_err");
    const message = try eng.lua.toString(-1);
    try std.testing.expect(std.mem.startsWith(u8, message, "timeout"));
    eng.lua.pop(1);
    // Must NOT have waited the full 10s.
    try std.testing.expect(elapsed < 2000);
}

test "zag.cmd.spawn + kill + wait returns signal-coded exit" {
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    eng.storeSelfPointer();
    try eng.initAsync(2, 16);
    defer eng.deinitAsync();

    try eng.lua.doString(
        \\function test_spawn_kill()
        \\  local h = zag.cmd.spawn({ "/bin/sleep", "5" })
        \\  h:kill("KILL")
        \\  local code, err = h:wait()
        \\  _spawn_kill_err_is_nil = (err == nil)
        \\  _spawn_kill_code_negative = (code ~= nil and code < 0)
        \\end
    );
    _ = try eng.lua.getGlobal("test_spawn_kill");
    _ = try eng.spawnCoroutine(0, null);

    const deadline = std.time.milliTimestamp() + 3000;
    while (eng.tasks.count() > 0 and std.time.milliTimestamp() < deadline) {
        if (eng.async_runtime.?.completions.pop()) |job| {
            try eng.resumeFromJob(job);
        } else {
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
    }
    try std.testing.expectEqual(@as(u32, 0), eng.tasks.count());

    _ = try eng.lua.getGlobal("_spawn_kill_err_is_nil");
    try std.testing.expect(eng.lua.toBoolean(-1));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_spawn_kill_code_negative");
    try std.testing.expect(eng.lua.toBoolean(-1));
    eng.lua.pop(1);

    // Force the userdata to be collected so its __gc runs before we
    // tear down the engine. Otherwise the handle's helper thread
    // outlives deinitAsync and we race on completions.
    try eng.lua.doString("collectgarbage('collect')");
}

test "zag.cmd.spawn of short-lived process: wait returns code 0" {
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    eng.storeSelfPointer();
    try eng.initAsync(2, 16);
    defer eng.deinitAsync();

    try eng.lua.doString(
        \\function test_spawn_quick()
        \\  local h = zag.cmd.spawn({ "/bin/echo", "hi" })
        \\  local code, err = h:wait()
        \\  _spawn_quick_code = code
        \\  _spawn_quick_err_is_nil = (err == nil)
        \\end
    );
    _ = try eng.lua.getGlobal("test_spawn_quick");
    _ = try eng.spawnCoroutine(0, null);

    const deadline = std.time.milliTimestamp() + 3000;
    while (eng.tasks.count() > 0 and std.time.milliTimestamp() < deadline) {
        if (eng.async_runtime.?.completions.pop()) |job| {
            try eng.resumeFromJob(job);
        } else {
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
    }
    try std.testing.expectEqual(@as(u32, 0), eng.tasks.count());

    _ = try eng.lua.getGlobal("_spawn_quick_code");
    try std.testing.expectEqual(@as(i64, 0), try eng.lua.toInteger(-1));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_spawn_quick_err_is_nil");
    try std.testing.expect(eng.lua.toBoolean(-1));
    eng.lua.pop(1);

    try eng.lua.doString("collectgarbage('collect')");
}

test "zag.cmd.spawn :wait after child exited returns code" {
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    eng.storeSelfPointer();
    try eng.initAsync(2, 16);
    defer eng.deinitAsync();

    try eng.lua.doString(
        \\function test_post_exit()
        \\  local h = zag.cmd.spawn({ "/usr/bin/true" })
        \\  zag.sleep(50)
        \\  local code, err = h:wait()
        \\  _pe_code = code
        \\  _pe_err_is_nil = (err == nil)
        \\end
    );
    _ = try eng.lua.getGlobal("test_post_exit");
    _ = try eng.spawnCoroutine(0, null);
    const deadline = std.time.milliTimestamp() + 2000;
    while (eng.tasks.count() > 0 and std.time.milliTimestamp() < deadline) {
        if (eng.async_runtime.?.completions.pop()) |job| {
            try eng.resumeFromJob(job);
        } else {
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
    }
    try std.testing.expectEqual(@as(u32, 0), eng.tasks.count());

    _ = try eng.lua.getGlobal("_pe_err_is_nil");
    try std.testing.expect(eng.lua.toBoolean(-1));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_pe_code");
    try std.testing.expectEqual(@as(i64, 0), try eng.lua.toInteger(-1));
    eng.lua.pop(1);

    try eng.lua.doString("collectgarbage('collect')");
}

test "zag.cmd.spawn GC without :wait reaps child cleanly" {
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    eng.storeSelfPointer();
    try eng.initAsync(2, 16);
    defer eng.deinitAsync();

    try eng.lua.doString(
        \\function test_gc_no_wait()
        \\  local h = zag.cmd.spawn({ "/bin/sleep", "5" })
        \\  h = nil
        \\  collectgarbage("collect")
        \\end
    );
    _ = try eng.lua.getGlobal("test_gc_no_wait");
    _ = try eng.spawnCoroutine(0, null);
    const deadline = std.time.milliTimestamp() + 2000;
    while (eng.tasks.count() > 0 and std.time.milliTimestamp() < deadline) {
        if (eng.async_runtime.?.completions.pop()) |job| {
            try eng.resumeFromJob(job);
        } else {
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
    }
    try std.testing.expectEqual(@as(u32, 0), eng.tasks.count());
    // Reaching here without testing.allocator reporting leaks means
    // the SIGKILL + helper-reap + join path closed every resource.
}

test "zag.cmd.spawn :lines yields lines then nil at EOF" {
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    eng.storeSelfPointer();
    try eng.initAsync(2, 16);
    defer eng.deinitAsync();

    try eng.lua.doString(
        \\function test_lines()
        \\  local h = zag.cmd.spawn({ "/bin/sh", "-c", "echo a; echo b; echo c" },
        \\                         { capture_stdout = true })
        \\  local lines = {}
        \\  for line in h:lines() do
        \\    table.insert(lines, line)
        \\  end
        \\  _lines_count = #lines
        \\  _lines_1 = lines[1]
        \\  _lines_2 = lines[2]
        \\  _lines_3 = lines[3]
        \\  h:wait()
        \\end
    );
    _ = try eng.lua.getGlobal("test_lines");
    _ = try eng.spawnCoroutine(0, null);
    const deadline = std.time.milliTimestamp() + 3000;
    while (eng.tasks.count() > 0 and std.time.milliTimestamp() < deadline) {
        if (eng.async_runtime.?.completions.pop()) |job| {
            try eng.resumeFromJob(job);
        } else {
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
    }
    try std.testing.expectEqual(@as(u32, 0), eng.tasks.count());

    _ = try eng.lua.getGlobal("_lines_count");
    try std.testing.expectEqual(@as(i64, 3), try eng.lua.toInteger(-1));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_lines_1");
    try std.testing.expect(std.mem.eql(u8, try eng.lua.toString(-1), "a"));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_lines_2");
    try std.testing.expect(std.mem.eql(u8, try eng.lua.toString(-1), "b"));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_lines_3");
    try std.testing.expect(std.mem.eql(u8, try eng.lua.toString(-1), "c"));
    eng.lua.pop(1);

    try eng.lua.doString("collectgarbage('collect')");
}

test "zag.cmd.spawn :lines errors when stdout not captured" {
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    eng.storeSelfPointer();
    try eng.initAsync(2, 16);
    defer eng.deinitAsync();

    try eng.lua.doString(
        \\function test_no_capture()
        \\  local h = zag.cmd.spawn({ "/bin/echo", "x" })
        \\  local iter = h:lines()
        \\  local line, err = iter()
        \\  _no_cap_line_is_nil = (line == nil)
        \\  _no_cap_err = err
        \\  h:wait()
        \\end
    );
    _ = try eng.lua.getGlobal("test_no_capture");
    _ = try eng.spawnCoroutine(0, null);

    const deadline = std.time.milliTimestamp() + 2000;
    while (eng.tasks.count() > 0 and std.time.milliTimestamp() < deadline) {
        if (eng.async_runtime.?.completions.pop()) |job| {
            try eng.resumeFromJob(job);
        } else {
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
    }

    _ = try eng.lua.getGlobal("_no_cap_line_is_nil");
    try std.testing.expect(eng.lua.toBoolean(-1));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_no_cap_err");
    const message = try eng.lua.toString(-1);
    try std.testing.expect(std.mem.startsWith(u8, message, "io_error"));
    eng.lua.pop(1);
    try eng.lua.doString("collectgarbage('collect')");
}

test "zag.cmd.spawn :write feeds stdin, :close_stdin causes cat to exit" {
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    eng.storeSelfPointer();
    try eng.initAsync(2, 16);
    defer eng.deinitAsync();

    try eng.lua.doString(
        \\function test_write()
        \\  local h = zag.cmd.spawn({ "/bin/cat" }, {
        \\    capture_stdin = true,
        \\    capture_stdout = true,
        \\  })
        \\  local ok, werr = h:write("hello")
        \\  _write_ok = ok
        \\  _write_err_is_nil = (werr == nil)
        \\  local cok, cerr = h:close_stdin()
        \\  _close_ok = cok
        \\  _close_err_is_nil = (cerr == nil)
        \\  local collected = {}
        \\  for line in h:lines() do
        \\    table.insert(collected, line)
        \\  end
        \\  _write_count = #collected
        \\  _write_line1 = collected[1]
        \\  h:wait()
        \\end
    );
    _ = try eng.lua.getGlobal("test_write");
    _ = try eng.spawnCoroutine(0, null);

    const deadline = std.time.milliTimestamp() + 3000;
    while (eng.tasks.count() > 0 and std.time.milliTimestamp() < deadline) {
        if (eng.async_runtime.?.completions.pop()) |job| {
            try eng.resumeFromJob(job);
        } else {
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
    }
    try std.testing.expectEqual(@as(u32, 0), eng.tasks.count());

    _ = try eng.lua.getGlobal("_write_ok");
    try std.testing.expect(eng.lua.toBoolean(-1));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_write_err_is_nil");
    try std.testing.expect(eng.lua.toBoolean(-1));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_close_ok");
    try std.testing.expect(eng.lua.toBoolean(-1));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_close_err_is_nil");
    try std.testing.expect(eng.lua.toBoolean(-1));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_write_count");
    try std.testing.expectEqual(@as(i64, 1), try eng.lua.toInteger(-1));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_write_line1");
    try std.testing.expectEqualStrings("hello", try eng.lua.toString(-1));
    eng.lua.pop(1);

    try eng.lua.doString("collectgarbage('collect')");
}

test "zag.cmd.kill on a spawned child exits it with the signal" {
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    eng.storeSelfPointer();
    try eng.initAsync(2, 16);
    defer eng.deinitAsync();

    // Spawn /bin/sleep, grab its PID via h:pid(), send KILL through the
    // sync zag.cmd.kill primitive, and let h:wait() reap the corpse.
    // A signal-killed child surfaces a negative exit code.
    try eng.lua.doString(
        \\function test_kill()
        \\  local h = zag.cmd.spawn({ "/bin/sleep", "30" })
        \\  local pid = h:pid()
        \\  _kill_pid_positive = (pid ~= nil and pid > 0)
        \\  local ok, err = zag.cmd.kill(pid, "KILL")
        \\  _kill_ok = ok
        \\  _kill_err_is_nil = (err == nil)
        \\  local code, werr = h:wait()
        \\  _kill_wait_code = code
        \\  _kill_werr_is_nil = (werr == nil)
        \\end
    );
    _ = try eng.lua.getGlobal("test_kill");
    _ = try eng.spawnCoroutine(0, null);

    const deadline = std.time.milliTimestamp() + 3000;
    while (eng.tasks.count() > 0 and std.time.milliTimestamp() < deadline) {
        if (eng.async_runtime.?.completions.pop()) |job| {
            try eng.resumeFromJob(job);
        } else {
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
    }
    try std.testing.expectEqual(@as(u32, 0), eng.tasks.count());

    _ = try eng.lua.getGlobal("_kill_pid_positive");
    try std.testing.expect(eng.lua.toBoolean(-1));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_kill_ok");
    try std.testing.expect(eng.lua.toBoolean(-1));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_kill_err_is_nil");
    try std.testing.expect(eng.lua.toBoolean(-1));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_kill_wait_code");
    const code = try eng.lua.toInteger(-1);
    try std.testing.expect(code < 0); // signal-killed convention
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_kill_werr_is_nil");
    try std.testing.expect(eng.lua.toBoolean(-1));
    eng.lua.pop(1);

    try eng.lua.doString("collectgarbage('collect')");
}

test "zag.http.get fetches from a local test server" {
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    eng.storeSelfPointer();
    try eng.initAsync(2, 16);
    defer eng.deinitAsync();

    // Canned HTTP/1.1 server: kernel picks the port, thread serves one
    // request then exits. Same pattern as primitives/http.zig's test.
    const listen_addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try listen_addr.listen(.{ .reuse_address = true });
    defer server.deinit();
    const port = server.listen_address.getPort();

    const ServerCtx = struct {
        fn run(srv: *std.net.Server) void {
            const conn = srv.accept() catch return;
            defer conn.stream.close();
            var buf: [4096]u8 = undefined;
            var total: usize = 0;
            while (total < buf.len) {
                const n = conn.stream.read(buf[total..]) catch return;
                if (n == 0) break;
                total += n;
                if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n") != null) break;
            }
            const resp =
                "HTTP/1.1 200 OK\r\n" ++
                "Content-Length: 14\r\n" ++
                "Content-Type: text/plain\r\n" ++
                "Connection: close\r\n" ++
                "\r\n" ++
                "hello from lua";
            conn.stream.writeAll(resp) catch {};
        }
    };
    const server_thread = try std.Thread.spawn(.{}, ServerCtx.run, .{&server});
    defer server_thread.join();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{port});

    try eng.lua.doString(
        \\function test_http(url)
        \\  local r, err = zag.http.get(url)
        \\  _http_err_is_nil = (err == nil)
        \\  if r then
        \\    _http_status = r.status
        \\    _http_body = r.body
        \\    _http_headers_is_table = (type(r.headers) == "table")
        \\  end
        \\end
    );

    _ = try eng.lua.getGlobal("test_http");
    _ = eng.lua.pushString(url);
    _ = try eng.spawnCoroutine(1, null);

    const deadline = std.time.milliTimestamp() + 3000;
    while (eng.tasks.count() > 0 and std.time.milliTimestamp() < deadline) {
        if (eng.async_runtime.?.completions.pop()) |job| {
            try eng.resumeFromJob(job);
        } else {
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
    }
    try std.testing.expectEqual(@as(u32, 0), eng.tasks.count());

    _ = try eng.lua.getGlobal("_http_err_is_nil");
    try std.testing.expect(eng.lua.toBoolean(-1));
    eng.lua.pop(1);

    _ = try eng.lua.getGlobal("_http_status");
    try std.testing.expectEqual(@as(i64, 200), try eng.lua.toInteger(-1));
    eng.lua.pop(1);

    _ = try eng.lua.getGlobal("_http_body");
    const body = try eng.lua.toString(-1);
    try std.testing.expect(std.mem.indexOf(u8, body, "hello from lua") != null);
    eng.lua.pop(1);

    _ = try eng.lua.getGlobal("_http_headers_is_table");
    try std.testing.expect(eng.lua.toBoolean(-1));
    eng.lua.pop(1);
}

// Regression test for Task 7.5 fix: std.http defaults Accept-Encoding to
// "gzip, deflate, identity". We force .omit in the inlined request() opts
// because we don't decompress; otherwise servers would hand us gzipped
// bytes and Lua callers would see garbage. The test captures the request
// bytes server-side and asserts Accept-Encoding is absent.
test "zag.http.get does not send Accept-Encoding (avoids gzip corruption)" {
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    eng.storeSelfPointer();
    try eng.initAsync(2, 16);
    defer eng.deinitAsync();

    const listen_addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try listen_addr.listen(.{ .reuse_address = true });
    defer server.deinit();
    const port = server.listen_address.getPort();

    // Capture the received request bytes so the test can assert which
    // headers the client sent. Shared by-pointer with the server
    // thread; lifetime is bounded by the server_thread.join() defer.
    const Captured = struct {
        request_bytes: [8192]u8 = undefined,
        request_len: usize = 0,
    };
    var captured = Captured{};

    const ServerCtx = struct {
        fn run(srv: *std.net.Server, cap: *Captured) void {
            const conn = srv.accept() catch return;
            defer conn.stream.close();

            var total: usize = 0;
            while (total < cap.request_bytes.len) {
                const n = conn.stream.read(cap.request_bytes[total..]) catch break;
                if (n == 0) break;
                total += n;
                if (std.mem.indexOf(u8, cap.request_bytes[0..total], "\r\n\r\n") != null) break;
            }
            cap.request_len = total;

            const resp =
                "HTTP/1.1 200 OK\r\n" ++
                "Content-Length: 2\r\n" ++
                "Content-Type: text/plain\r\n" ++
                "Connection: close\r\n" ++
                "\r\n" ++
                "ok";
            conn.stream.writeAll(resp) catch {};
        }
    };
    const server_thread = try std.Thread.spawn(.{}, ServerCtx.run, .{ &server, &captured });
    defer server_thread.join();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{port});

    try eng.lua.doString(
        \\function test_ae(url)
        \\  local r, err = zag.http.get(url)
        \\  _ae_err_is_nil = (err == nil)
        \\end
    );
    _ = try eng.lua.getGlobal("test_ae");
    _ = eng.lua.pushString(url);
    _ = try eng.spawnCoroutine(1, null);

    const deadline = std.time.milliTimestamp() + 3000;
    while (eng.tasks.count() > 0 and std.time.milliTimestamp() < deadline) {
        if (eng.async_runtime.?.completions.pop()) |job| {
            try eng.resumeFromJob(job);
        } else {
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
    }
    try std.testing.expectEqual(@as(u32, 0), eng.tasks.count());

    _ = try eng.lua.getGlobal("_ae_err_is_nil");
    try std.testing.expect(eng.lua.toBoolean(-1));
    eng.lua.pop(1);

    const req = captured.request_bytes[0..captured.request_len];
    try std.testing.expect(std.ascii.indexOfIgnoreCase(req, "Accept-Encoding:") == null);
}

test "zag.http.post sends body and parses response" {
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    eng.storeSelfPointer();
    try eng.initAsync(2, 16);
    defer eng.deinitAsync();

    const listen_addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try listen_addr.listen(.{ .reuse_address = true });
    defer server.deinit();
    const port = server.listen_address.getPort();

    // Echo server: read the request (crude but OK for small bodies
    // under a single MSS), grab everything after `\r\n\r\n`, send it
    // back as the response body. No Content-Length on the request
    // side means we also accept chunked-less small payloads.
    const ServerCtx = struct {
        fn run(srv: *std.net.Server) void {
            const conn = srv.accept() catch return;
            defer conn.stream.close();
            var buf: [8192]u8 = undefined;
            var total: usize = 0;
            // Headers first
            while (total < buf.len) {
                const n = conn.stream.read(buf[total..]) catch return;
                if (n == 0) break;
                total += n;
                if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n") != null) break;
            }
            const header_end = (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n") orelse return) + 4;

            // Parse Content-Length to know when the body is fully read.
            var content_length: usize = 0;
            const headers_view = buf[0..header_end];
            if (std.mem.indexOf(u8, headers_view, "Content-Length:")) |cl_idx| {
                const line_end = std.mem.indexOfScalarPos(u8, headers_view, cl_idx, '\r') orelse header_end;
                const value = std.mem.trim(u8, headers_view[cl_idx + "Content-Length:".len .. line_end], " \t");
                content_length = std.fmt.parseInt(usize, value, 10) catch 0;
            }

            // Keep reading until we have the full body.
            while ((total - header_end) < content_length and total < buf.len) {
                const n = conn.stream.read(buf[total..]) catch return;
                if (n == 0) break;
                total += n;
            }

            const body = buf[header_end..total];
            var resp_buf: [8192]u8 = undefined;
            const resp = std.fmt.bufPrint(&resp_buf, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n{s}", .{ body.len, body }) catch return;
            conn.stream.writeAll(resp) catch {};
        }
    };
    const server_thread = try std.Thread.spawn(.{}, ServerCtx.run, .{&server});
    defer server_thread.join();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{port});

    try eng.lua.doString(
        \\function test_post(url)
        \\  local r, err = zag.http.post(url, {
        \\    body = { hello = "world", n = 42 },
        \\    headers = { ["X-Test"] = "on" },
        \\  })
        \\  _post_err_is_nil = (err == nil)
        \\  if r then
        \\    _post_status = r.status
        \\    _post_body = r.body
        \\  end
        \\end
    );

    _ = try eng.lua.getGlobal("test_post");
    _ = eng.lua.pushString(url);
    _ = try eng.spawnCoroutine(1, null);

    const deadline = std.time.milliTimestamp() + 3000;
    while (eng.tasks.count() > 0 and std.time.milliTimestamp() < deadline) {
        if (eng.async_runtime.?.completions.pop()) |job| {
            try eng.resumeFromJob(job);
        } else {
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
    }
    try std.testing.expectEqual(@as(u32, 0), eng.tasks.count());

    _ = try eng.lua.getGlobal("_post_err_is_nil");
    try std.testing.expect(eng.lua.toBoolean(-1));
    eng.lua.pop(1);

    _ = try eng.lua.getGlobal("_post_status");
    try std.testing.expectEqual(@as(i64, 200), try eng.lua.toInteger(-1));
    eng.lua.pop(1);

    _ = try eng.lua.getGlobal("_post_body");
    const body = try eng.lua.toString(-1);
    // Server echoes the body. The Lua→JSON encoder doesn't guarantee
    // key order, so just check the encoded object contains both
    // key/value pairs somewhere.
    try std.testing.expect(std.mem.indexOf(u8, body, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "world") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "42") != null);
    eng.lua.pop(1);
}

test "zag.http.stream yields response lines then nil at EOF" {
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    eng.storeSelfPointer();
    try eng.initAsync(2, 16);
    defer eng.deinitAsync();

    var server_addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try server_addr.listen(.{ .reuse_address = true });
    defer server.deinit();
    const port = server.listen_address.getPort();

    const ServerCtx = struct {
        fn run(srv: *std.net.Server) void {
            const conn = srv.accept() catch return;
            defer conn.stream.close();
            var buf: [4096]u8 = undefined;
            var total: usize = 0;
            while (total < buf.len) {
                const n = conn.stream.read(buf[total..]) catch return;
                if (n == 0) break;
                total += n;
                if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n") != null) break;
            }
            const resp =
                "HTTP/1.1 200 OK\r\n" ++
                "Content-Length: 18\r\n" ++
                "Content-Type: text/plain\r\n" ++
                "Connection: close\r\n" ++
                "\r\n" ++
                "line1\nline2\nline3\n";
            conn.stream.writeAll(resp) catch {};
        }
    };
    const server_thread = try std.Thread.spawn(.{}, ServerCtx.run, .{&server});
    defer server_thread.join();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{port});

    try eng.lua.doString(
        \\function test_stream(url)
        \\  local s, err = zag.http.stream(url)
        \\  if err then _stream_err = err; return end
        \\  local lines = {}
        \\  for line in s:lines() do
        \\    table.insert(lines, line)
        \\  end
        \\  s:close()
        \\  _stream_count = #lines
        \\  _stream_line1 = lines[1]
        \\  _stream_line2 = lines[2]
        \\  _stream_line3 = lines[3]
        \\end
    );
    _ = try eng.lua.getGlobal("test_stream");
    _ = eng.lua.pushString(url);
    _ = try eng.spawnCoroutine(1, null);

    const deadline = std.time.milliTimestamp() + 3000;
    while (eng.tasks.count() > 0 and std.time.milliTimestamp() < deadline) {
        if (eng.async_runtime.?.completions.pop()) |job| try eng.resumeFromJob(job) else std.Thread.sleep(1 * std.time.ns_per_ms);
    }

    _ = try eng.lua.getGlobal("_stream_count");
    try std.testing.expectEqual(@as(i64, 3), try eng.lua.toInteger(-1));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_stream_line1");
    try std.testing.expectEqualStrings("line1", try eng.lua.toString(-1));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_stream_line2");
    try std.testing.expectEqualStrings("line2", try eng.lua.toString(-1));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_stream_line3");
    try std.testing.expectEqualStrings("line3", try eng.lua.toString(-1));
    eng.lua.pop(1);

    try eng.lua.doString("collectgarbage('collect')");
}

test "zag.http.stream flushes trailing partial line on EOS" {
    // Regression: server replies with content-length body whose final
    // byte is NOT '\n'. runReadLine's fast-path used to see
    // `self.eof == true` after the stream-ended branch and return nil
    // while `line_buf` still held "c". The fast path now flushes the
    // partial tail as the final line before signalling EOF.
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    eng.storeSelfPointer();
    try eng.initAsync(2, 16);
    defer eng.deinitAsync();

    var server_addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try server_addr.listen(.{ .reuse_address = true });
    defer server.deinit();
    const port = server.listen_address.getPort();

    const ServerCtx = struct {
        fn run(srv: *std.net.Server) void {
            const conn = srv.accept() catch return;
            defer conn.stream.close();
            var buf: [4096]u8 = undefined;
            var total: usize = 0;
            while (total < buf.len) {
                const n = conn.stream.read(buf[total..]) catch return;
                if (n == 0) break;
                total += n;
                if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n") != null) break;
            }
            // Body is "a\nb\nc"; 5 bytes, no trailing newline.
            const resp =
                "HTTP/1.1 200 OK\r\n" ++
                "Content-Length: 5\r\n" ++
                "Content-Type: text/plain\r\n" ++
                "Connection: close\r\n" ++
                "\r\n" ++
                "a\nb\nc";
            conn.stream.writeAll(resp) catch {};
        }
    };
    const server_thread = try std.Thread.spawn(.{}, ServerCtx.run, .{&server});
    defer server_thread.join();

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/", .{port});

    try eng.lua.doString(
        \\function test_partial(url)
        \\  local s, err = zag.http.stream(url)
        \\  if err then _partial_err = err; return end
        \\  local lines = {}
        \\  for line in s:lines() do
        \\    table.insert(lines, line)
        \\  end
        \\  s:close()
        \\  _partial_count = #lines
        \\  _partial_1 = lines[1]
        \\  _partial_2 = lines[2]
        \\  _partial_3 = lines[3]
        \\end
    );
    _ = try eng.lua.getGlobal("test_partial");
    _ = eng.lua.pushString(url);
    _ = try eng.spawnCoroutine(1, null);

    const deadline = std.time.milliTimestamp() + 3000;
    while (eng.tasks.count() > 0 and std.time.milliTimestamp() < deadline) {
        if (eng.async_runtime.?.completions.pop()) |job| try eng.resumeFromJob(job) else std.Thread.sleep(1 * std.time.ns_per_ms);
    }

    _ = try eng.lua.getGlobal("_partial_count");
    try std.testing.expectEqual(@as(i64, 3), try eng.lua.toInteger(-1));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_partial_1");
    try std.testing.expectEqualStrings("a", try eng.lua.toString(-1));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_partial_2");
    try std.testing.expectEqualStrings("b", try eng.lua.toString(-1));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_partial_3");
    try std.testing.expectEqualStrings("c", try eng.lua.toString(-1));
    eng.lua.pop(1);

    try eng.lua.doString("collectgarbage('collect')");
}

test "zag.cmd.spawn :lines flushes trailing partial line on EOF" {
    // Regression: child prints "a\nb\nc" with no trailing newline.
    // The read_line path must surface "c" as the final line before
    // returning nil at EOF; not silently drop it.
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    eng.storeSelfPointer();
    try eng.initAsync(2, 16);
    defer eng.deinitAsync();

    try eng.lua.doString(
        \\function test_partial_cmd()
        \\  local h = zag.cmd.spawn({ "/bin/sh", "-c", "printf 'a\nb\nc'" },
        \\                         { capture_stdout = true })
        \\  local lines = {}
        \\  for line in h:lines() do
        \\    table.insert(lines, line)
        \\  end
        \\  _cmd_partial_count = #lines
        \\  _cmd_partial_1 = lines[1]
        \\  _cmd_partial_2 = lines[2]
        \\  _cmd_partial_3 = lines[3]
        \\  h:wait()
        \\end
    );
    _ = try eng.lua.getGlobal("test_partial_cmd");
    _ = try eng.spawnCoroutine(0, null);
    const deadline = std.time.milliTimestamp() + 3000;
    while (eng.tasks.count() > 0 and std.time.milliTimestamp() < deadline) {
        if (eng.async_runtime.?.completions.pop()) |job| {
            try eng.resumeFromJob(job);
        } else {
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
    }
    try std.testing.expectEqual(@as(u32, 0), eng.tasks.count());

    _ = try eng.lua.getGlobal("_cmd_partial_count");
    try std.testing.expectEqual(@as(i64, 3), try eng.lua.toInteger(-1));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_cmd_partial_1");
    try std.testing.expectEqualStrings("a", try eng.lua.toString(-1));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_cmd_partial_2");
    try std.testing.expectEqualStrings("b", try eng.lua.toString(-1));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_cmd_partial_3");
    try std.testing.expectEqualStrings("c", try eng.lua.toString(-1));
    eng.lua.pop(1);

    try eng.lua.doString("collectgarbage('collect')");
}

// ----- zag.fs.* integration tests -----

/// Shared helper: drive the engine's drain loop until no tasks remain
/// or the deadline expires. Every async fs test ends with this exact
/// pattern, so pull it out to keep the test bodies focused on their
/// assertions.
fn driveDrainLoop(eng: *LuaEngine, timeout_ms: i64) !void {
    const deadline = std.time.milliTimestamp() + timeout_ms;
    while (eng.tasks.count() > 0 and std.time.milliTimestamp() < deadline) {
        if (eng.async_runtime.?.completions.pop()) |job| {
            try eng.resumeFromJob(job);
        } else {
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
    }
    try std.testing.expectEqual(@as(u32, 0), eng.tasks.count());
}

test "zag.fs.read returns file bytes" {
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    eng.storeSelfPointer();
    try eng.initAsync(2, 16);
    defer eng.deinitAsync();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "r.txt", .data = "hello-from-disk" });
    var rbuf: [std.fs.max_path_bytes]u8 = undefined;
    const base = try tmp.dir.realpath(".", &rbuf);
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&pbuf, "{s}/r.txt", .{base});

    _ = eng.lua.pushString(path);
    eng.lua.setGlobal("_read_path");

    try eng.lua.doString(
        \\function test_read()
        \\  local data, err = zag.fs.read(_read_path)
        \\  _read_err_nil = (err == nil)
        \\  _read_data = data
        \\end
    );
    _ = try eng.lua.getGlobal("test_read");
    _ = try eng.spawnCoroutine(0, null);
    try driveDrainLoop(&eng, 2000);

    _ = try eng.lua.getGlobal("_read_err_nil");
    try std.testing.expect(eng.lua.toBoolean(-1));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_read_data");
    try std.testing.expectEqualStrings("hello-from-disk", try eng.lua.toString(-1));
    eng.lua.pop(1);
}

test "zag.fs.read returns not_found for missing file" {
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    eng.storeSelfPointer();
    try eng.initAsync(2, 16);
    defer eng.deinitAsync();

    try eng.lua.doString(
        \\function test_missing()
        \\  local data, err = zag.fs.read("/nonexistent/path/to/nowhere/xyzzy")
        \\  _missing_data_nil = (data == nil)
        \\  _missing_err = err
        \\end
    );
    _ = try eng.lua.getGlobal("test_missing");
    _ = try eng.spawnCoroutine(0, null);
    try driveDrainLoop(&eng, 2000);

    _ = try eng.lua.getGlobal("_missing_data_nil");
    try std.testing.expect(eng.lua.toBoolean(-1));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_missing_err");
    const err = try eng.lua.toString(-1);
    try std.testing.expect(std.mem.startsWith(u8, err, "not_found"));
    eng.lua.pop(1);
}

test "zag.fs.write + read roundtrip" {
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    eng.storeSelfPointer();
    try eng.initAsync(2, 16);
    defer eng.deinitAsync();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var rbuf: [std.fs.max_path_bytes]u8 = undefined;
    const base = try tmp.dir.realpath(".", &rbuf);
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&pbuf, "{s}/w.txt", .{base});

    _ = eng.lua.pushString(path);
    eng.lua.setGlobal("_w_path");

    try eng.lua.doString(
        \\function test_write_read()
        \\  local ok, werr = zag.fs.write(_w_path, "payload-42")
        \\  _w_ok = ok
        \\  _w_err_nil = (werr == nil)
        \\  local data, rerr = zag.fs.read(_w_path)
        \\  _wr_data = data
        \\  _wr_err_nil = (rerr == nil)
        \\end
    );
    _ = try eng.lua.getGlobal("test_write_read");
    _ = try eng.spawnCoroutine(0, null);
    try driveDrainLoop(&eng, 2000);

    _ = try eng.lua.getGlobal("_w_ok");
    try std.testing.expect(eng.lua.toBoolean(-1));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_w_err_nil");
    try std.testing.expect(eng.lua.toBoolean(-1));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_wr_data");
    try std.testing.expectEqualStrings("payload-42", try eng.lua.toString(-1));
    eng.lua.pop(1);
}

test "zag.fs.append extends an existing file" {
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    eng.storeSelfPointer();
    try eng.initAsync(2, 16);
    defer eng.deinitAsync();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "first" });
    var rbuf: [std.fs.max_path_bytes]u8 = undefined;
    const base = try tmp.dir.realpath(".", &rbuf);
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&pbuf, "{s}/a.txt", .{base});

    _ = eng.lua.pushString(path);
    eng.lua.setGlobal("_a_path");

    try eng.lua.doString(
        \\function test_append()
        \\  local ok, err = zag.fs.append(_a_path, "-second")
        \\  _a_ok, _a_err = ok, err
        \\  local data = zag.fs.read(_a_path)
        \\  _a_data = data
        \\end
    );
    _ = try eng.lua.getGlobal("test_append");
    _ = try eng.spawnCoroutine(0, null);
    try driveDrainLoop(&eng, 2000);

    _ = try eng.lua.getGlobal("_a_ok");
    try std.testing.expect(eng.lua.toBoolean(-1));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_a_data");
    try std.testing.expectEqualStrings("first-second", try eng.lua.toString(-1));
    eng.lua.pop(1);
}

test "zag.fs.mkdir creates directories, parents=true handles nesting" {
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    eng.storeSelfPointer();
    try eng.initAsync(2, 16);
    defer eng.deinitAsync();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var rbuf: [std.fs.max_path_bytes]u8 = undefined;
    const base = try tmp.dir.realpath(".", &rbuf);
    var flat_buf: [std.fs.max_path_bytes]u8 = undefined;
    const flat_path = try std.fmt.bufPrint(&flat_buf, "{s}/flat", .{base});
    var deep_buf: [std.fs.max_path_bytes]u8 = undefined;
    const deep_path = try std.fmt.bufPrint(&deep_buf, "{s}/nested/inner/leaf", .{base});

    _ = eng.lua.pushString(flat_path);
    eng.lua.setGlobal("_mk_flat");
    _ = eng.lua.pushString(deep_path);
    eng.lua.setGlobal("_mk_deep");

    try eng.lua.doString(
        \\function test_mkdir()
        \\  local ok1, err1 = zag.fs.mkdir(_mk_flat)
        \\  _mk_flat_ok, _mk_flat_err = ok1, err1
        \\  local ok2, err2 = zag.fs.mkdir(_mk_deep, { parents = true })
        \\  _mk_deep_ok, _mk_deep_err = ok2, err2
        \\end
    );
    _ = try eng.lua.getGlobal("test_mkdir");
    _ = try eng.spawnCoroutine(0, null);
    try driveDrainLoop(&eng, 2000);

    _ = try eng.lua.getGlobal("_mk_flat_ok");
    try std.testing.expect(eng.lua.toBoolean(-1));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_mk_deep_ok");
    try std.testing.expect(eng.lua.toBoolean(-1));
    eng.lua.pop(1);

    // Verify both directories actually exist on disk.
    try tmp.dir.access("flat", .{});
    try tmp.dir.access("nested/inner/leaf", .{});
}

test "zag.fs.remove deletes a file; recursive=true deletes a tree" {
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    eng.storeSelfPointer();
    try eng.initAsync(2, 16);
    defer eng.deinitAsync();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "trash.txt", .data = "x" });
    try tmp.dir.makePath("tree/inner");
    try tmp.dir.writeFile(.{ .sub_path = "tree/inner/child.txt", .data = "y" });

    var rbuf: [std.fs.max_path_bytes]u8 = undefined;
    const base = try tmp.dir.realpath(".", &rbuf);
    var f_buf: [std.fs.max_path_bytes]u8 = undefined;
    const file_path = try std.fmt.bufPrint(&f_buf, "{s}/trash.txt", .{base});
    var t_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tree_path = try std.fmt.bufPrint(&t_buf, "{s}/tree", .{base});

    _ = eng.lua.pushString(file_path);
    eng.lua.setGlobal("_rm_file");
    _ = eng.lua.pushString(tree_path);
    eng.lua.setGlobal("_rm_tree");

    try eng.lua.doString(
        \\function test_remove()
        \\  local ok1, err1 = zag.fs.remove(_rm_file)
        \\  _rm_file_ok, _rm_file_err = ok1, err1
        \\  local ok2, err2 = zag.fs.remove(_rm_tree, { recursive = true })
        \\  _rm_tree_ok, _rm_tree_err = ok2, err2
        \\end
    );
    _ = try eng.lua.getGlobal("test_remove");
    _ = try eng.spawnCoroutine(0, null);
    try driveDrainLoop(&eng, 2000);

    _ = try eng.lua.getGlobal("_rm_file_ok");
    try std.testing.expect(eng.lua.toBoolean(-1));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_rm_tree_ok");
    try std.testing.expect(eng.lua.toBoolean(-1));
    eng.lua.pop(1);

    // Nothing should remain at those paths.
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("trash.txt", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("tree", .{}));
}

test "zag.fs.list returns directory entries" {
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    eng.storeSelfPointer();
    try eng.initAsync(2, 16);
    defer eng.deinitAsync();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "one.txt", .data = "1" });
    try tmp.dir.writeFile(.{ .sub_path = "two.txt", .data = "2" });
    try tmp.dir.makeDir("sub");

    var rbuf: [std.fs.max_path_bytes]u8 = undefined;
    const base = try tmp.dir.realpath(".", &rbuf);
    _ = eng.lua.pushString(base);
    eng.lua.setGlobal("_ls_path");

    try eng.lua.doString(
        \\function test_list()
        \\  local entries, err = zag.fs.list(_ls_path)
        \\  _ls_err_nil = (err == nil)
        \\  if entries then
        \\    _ls_count = #entries
        \\    -- Collect into two parallel sets keyed by name → kind.
        \\    _ls_kinds = {}
        \\    for i = 1, #entries do
        \\      _ls_kinds[entries[i].name] = entries[i].kind
        \\    end
        \\  end
        \\end
    );
    _ = try eng.lua.getGlobal("test_list");
    _ = try eng.spawnCoroutine(0, null);
    try driveDrainLoop(&eng, 2000);

    _ = try eng.lua.getGlobal("_ls_err_nil");
    try std.testing.expect(eng.lua.toBoolean(-1));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_ls_count");
    try std.testing.expectEqual(@as(i64, 3), try eng.lua.toInteger(-1));
    eng.lua.pop(1);

    // _ls_kinds["one.txt"] == "file"
    _ = try eng.lua.getGlobal("_ls_kinds");
    _ = eng.lua.getField(-1, "one.txt");
    try std.testing.expectEqualStrings("file", try eng.lua.toString(-1));
    eng.lua.pop(1);
    _ = eng.lua.getField(-1, "sub");
    try std.testing.expectEqualStrings("dir", try eng.lua.toString(-1));
    eng.lua.pop(1);
    eng.lua.pop(1); // _ls_kinds
}

test "zag.fs.stat returns kind, size, mtime_ms, mode" {
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    eng.storeSelfPointer();
    try eng.initAsync(2, 16);
    defer eng.deinitAsync();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "s.dat", .data = "0123456789ab" });

    var rbuf: [std.fs.max_path_bytes]u8 = undefined;
    const base = try tmp.dir.realpath(".", &rbuf);
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&pbuf, "{s}/s.dat", .{base});

    _ = eng.lua.pushString(path);
    eng.lua.setGlobal("_st_path");

    try eng.lua.doString(
        \\function test_stat()
        \\  local s, err = zag.fs.stat(_st_path)
        \\  _st_err_nil = (err == nil)
        \\  if s then
        \\    _st_kind = s.kind
        \\    _st_size = s.size
        \\    _st_mtime = s.mtime_ms
        \\    _st_mode = s.mode
        \\  end
        \\end
    );
    _ = try eng.lua.getGlobal("test_stat");
    _ = try eng.spawnCoroutine(0, null);
    try driveDrainLoop(&eng, 2000);

    _ = try eng.lua.getGlobal("_st_err_nil");
    try std.testing.expect(eng.lua.toBoolean(-1));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_st_kind");
    try std.testing.expectEqualStrings("file", try eng.lua.toString(-1));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_st_size");
    try std.testing.expectEqual(@as(i64, 12), try eng.lua.toInteger(-1));
    eng.lua.pop(1);
    // mtime_ms is whatever the fs recorded; just ensure it's positive.
    _ = try eng.lua.getGlobal("_st_mtime");
    try std.testing.expect((try eng.lua.toInteger(-1)) > 0);
    eng.lua.pop(1);
    // mode should be non-zero on POSIX.
    _ = try eng.lua.getGlobal("_st_mode");
    try std.testing.expect((try eng.lua.toInteger(-1)) > 0);
    eng.lua.pop(1);
}

test "zag.fs.exists returns true for present file, false for missing" {
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    eng.storeSelfPointer();
    try eng.initAsync(2, 16);
    defer eng.deinitAsync();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "e.txt", .data = "" });

    var rbuf: [std.fs.max_path_bytes]u8 = undefined;
    const base = try tmp.dir.realpath(".", &rbuf);
    var yes_buf: [std.fs.max_path_bytes]u8 = undefined;
    const yes_path = try std.fmt.bufPrint(&yes_buf, "{s}/e.txt", .{base});
    var no_buf: [std.fs.max_path_bytes]u8 = undefined;
    const no_path = try std.fmt.bufPrint(&no_buf, "{s}/missing.txt", .{base});

    _ = eng.lua.pushString(yes_path);
    eng.lua.setGlobal("_ex_yes");
    _ = eng.lua.pushString(no_path);
    eng.lua.setGlobal("_ex_no");

    // zag.fs.exists is sync; it can be called from the main state
    // without spawning a coroutine.
    try eng.lua.doString(
        \\_ex_yes_result = zag.fs.exists(_ex_yes)
        \\_ex_no_result = zag.fs.exists(_ex_no)
    );
    _ = try eng.lua.getGlobal("_ex_yes_result");
    try std.testing.expect(eng.lua.toBoolean(-1));
    eng.lua.pop(1);
    _ = try eng.lua.getGlobal("_ex_no_result");
    try std.testing.expect(!eng.lua.toBoolean(-1));
    eng.lua.pop(1);
}

test "zag.log.{debug,info} and zag.notify run without error" {
    // Only exercise debug/info/notify here; the Zig test runner flags
    // any .warn/.err emitted during a test as a logged error, which
    // would make a "does the binding call without raising" assertion
    // impossible to pass. warn/err wire to the same std.log machinery
    // via identical wrapper code, so covering them adds no signal.
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    eng.storeSelfPointer();

    try eng.lua.doString(
        \\_log_ran = false
        \\zag.log.debug("debug message")
        \\zag.log.info("hello %s", "world")
        \\zag.log.info("zero-arg info")
        \\zag.notify("notification")
        \\zag.notify("with opts", { level = "warn" })
        \\_log_ran = true
    );

    _ = try eng.lua.getGlobal("_log_ran");
    defer eng.lua.pop(1);
    try std.testing.expect(eng.lua.toBoolean(-1));
}

test "zag.log.warn and zag.log.err bindings exist and are callable" {
    // Separate test that silences warn/err so we can verify the
    // bindings are wired without tripping the test runner's
    // logged-error detector.
    const prev_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prev_log_level;

    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    eng.storeSelfPointer();

    // Only call warn (log_level.err silences it). We verify err is
    // callable by checking the type in Lua, without actually emitting.
    try eng.lua.doString(
        \\zag.log.warn("silenced warn %d", 1)
        \\_err_kind = type(zag.log.err)
    );
    _ = try eng.lua.getGlobal("_err_kind");
    defer eng.lua.pop(1);
    try std.testing.expectEqualStrings("function", try eng.lua.toString(-1));
}

test "zag.log.info accepts non-format strings without raising" {
    // A message that happens to contain a % character but no format
    // args must not be passed through string.format (which would raise
    // "invalid option '%q' to 'format'"). The wrapper short-circuits
    // to tostring when there are zero extra args.
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    eng.storeSelfPointer();

    try eng.lua.doString("zag.log.info('100%% done')");
}

test "hook budget cancels a runaway coroutine" {
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    eng.storeSelfPointer();
    try eng.initAsync(2, 16);
    defer eng.deinitAsync();

    // Tight budget + long sleep: enforceHookBudget cancels the scope
    // well before the sleep would naturally return.
    eng.setHookBudgetMs(30);

    try eng.lua.doString(
        \\_hook_result = nil
        \\zag.hook("ToolPre", { pattern = "bash" }, function(evt)
        \\  local ok, err = zag.sleep(10000)
        \\  _hook_result = err or "completed"
        \\end)
    );

    var payload: Hooks.HookPayload = .{ .tool_pre = .{
        .name = "bash",
        .call_id = "x",
        .args_json = "{}",
        .args_rewrite = null,
    } };

    const start = std.time.milliTimestamp();
    _ = try eng.fireHook(&payload);
    const elapsed = std.time.milliTimestamp() - start;

    // Budget is 30ms; enforcement + worker abort round-trip should
    // finish well under 5 seconds (and nowhere near 10s).
    try std.testing.expect(elapsed < 5000);

    _ = try eng.lua.getGlobal("_hook_result");
    defer eng.lua.pop(1);
    const got = try eng.lua.toString(-1);
    // The cancel reason propagates from Scope as "cancelled: budget_exceeded"
    // or similar. Either the err tag string or the "cancelled" prefix is
    // acceptable; both prove the budget fired.
    try std.testing.expect(
        std.mem.indexOf(u8, got, "cancelled") != null or
            std.mem.indexOf(u8, got, "budget_exceeded") != null,
    );
}

test "zag.layout.tree is registered and fails cleanly without a window manager" {
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    eng.storeSelfPointer();

    // The function exists on zag.layout.
    try eng.lua.doString("_has_tree = type(zag.layout) == 'table' and type(zag.layout.tree) == 'function'");
    _ = try eng.lua.getGlobal("_has_tree");
    try std.testing.expect(eng.lua.toBoolean(-1));
    eng.lua.pop(1);

    // With no window manager bound, invocation raises a Lua error.
    try eng.lua.doString("_ok, _err = pcall(function() return zag.layout.tree() end)");
    _ = try eng.lua.getGlobal("_ok");
    try std.testing.expect(!eng.lua.toBoolean(-1));
    eng.lua.pop(1);
}

test "hook budget leaves fast hooks alone" {
    // Regression: if the budget is effectively disabled (0), a long
    // sleep inside a hook must be allowed to complete. This also
    // guards against enforceHookBudget mistakenly cancelling healthy
    // hooks that just happen to be in the tasks map.
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    eng.storeSelfPointer();
    try eng.initAsync(2, 16);
    defer eng.deinitAsync();

    eng.setHookBudgetMs(0); // disabled

    try eng.lua.doString(
        \\_fast_ran = false
        \\zag.hook("TurnStart", function(evt)
        \\  zag.sleep(5)
        \\  _fast_ran = true
        \\end)
    );

    var payload: Hooks.HookPayload = .{ .turn_start = .{ .turn_num = 1, .message_count = 0 } };
    _ = try eng.fireHook(&payload);

    _ = try eng.lua.getGlobal("_fast_ran");
    defer eng.lua.pop(1);
    try std.testing.expect(eng.lua.toBoolean(-1));
}
