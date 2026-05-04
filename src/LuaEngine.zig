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
const Buffer = @import("Buffer.zig");
const BufferRegistry = @import("BufferRegistry.zig");
const ScratchBuffer = @import("buffers/scratch.zig");
const GraphicsBuffer = @import("buffers/graphics.zig");
const Theme = @import("Theme.zig");
const CommandRegistry = @import("CommandRegistry.zig");
const input = @import("input.zig");
const llm = @import("llm.zig");
const Layout = @import("Layout.zig");
const NodeRegistry = @import("NodeRegistry.zig");
const subagents_mod = @import("subagents.zig");
const frontmatter_mod = @import("frontmatter.zig");
const prompt = @import("prompt.zig");
const Instruction = @import("Instruction.zig");
const Reminder = @import("Reminder.zig");
const WindowManager = @import("WindowManager.zig");
const agent_events = @import("agent_events.zig");
const width = @import("width.zig");
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
const embedded = @import("lua/embedded.zig");

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
    /// Slash-command registry for plugin-defined commands. Starts empty
    /// and fills via `zag.command{}`. The window manager owns its own
    /// registry for built-ins (`/quit`, `/perf`, `/model`, ...) and
    /// checks this one first so Lua plugins can shadow built-ins under
    /// the same slash name.
    command_registry: CommandRegistry,
    /// Persistent escape-sequence parser owned by the engine. Defaults
    /// match `input.Parser{}`, so `zag.set_escape_timeout_ms()` from
    /// `config.lua` lands here during `loadUserConfig`; the orchestrator
    /// reads this through `window_manager.inputParser()` when polling
    /// stdin. Outlives a single tick so fragmented CSI/SS3 sequences
    /// assemble across reads.
    input_parser: input.Parser = .{},
    /// Runtime registry of LLM endpoints declared via `zag.provider{...}`.
    /// Seeded with the builtins at `init`; each `zag.provider{}` call in
    /// `config.lua` overrides (removes then re-adds) the matching entry so
    /// a full-schema Lua declaration always wins. Read at startup by
    /// `llm.createProviderFromLuaConfig` through a borrowed pointer.
    providers_registry: llm.Registry,
    /// Registry of subagents declared via `zag.subagent.register{...}`.
    /// Starts empty; each `register` call deep-copies strings into
    /// `allocator` so the registry outlives the Lua snippet that
    /// produced the entry. The `task` tool and future inspection
    /// bindings read through `subagentRegistry()`.
    subagents: subagents_mod.SubagentRegistry = .{},
    /// System-prompt layer registry shared across turns. Built-in layers
    /// (identity, skills catalog, tool list, guidelines) are seeded at
    /// `init`. Lua plugins append more via `zag.prompt.layer{...}`; each
    /// Lua layer stashes its render function in the Lua registry and
    /// stores the slot index on `Layer.lua_ref`. The agent loop drives
    /// `assembleSystem` through `renderPromptLayers` per turn.
    prompt_registry: prompt.Registry = .{},
    /// Owned names of Lua-registered prompt layers. `Layer.name` is a
    /// borrowed slice; we dupe the Lua-side string into this list so
    /// `deinit` can free every entry without walking the registry's
    /// layers for ownership bookkeeping.
    prompt_layer_names: std.ArrayList([]const u8) = .empty,
    /// Queue of `<system-reminder>` snippets pushed by Lua plugins via
    /// `zag.reminders.push(...)`. The harness drains this at the user-message
    /// boundary on each turn (Task 7.3); persistent entries survive every
    /// drain until cleared by id. Lua bindings own the queue's lifetime,
    /// so the engine's allocator backs every entry copy.
    reminders: Reminder.Queue = .{},
    /// Default model string set via `zag.set_default_model("prov/id")`.
    /// Owned. Null if the user didn't set one; factory falls back to a hardcoded default.
    default_model: ?[]const u8 = null,
    /// Active reasoning_effort level set by `zag.set_thinking_effort`,
    /// or null if unset. Read by chat-completions providers that opted
    /// into the knob via `effort_request_field`. Module-level rather
    /// than per-pane so the same setting applies across all turns
    /// within a session; per-pane override is a future PR. Owned by
    /// the engine's allocator.
    thinking_effort: ?[]const u8 = null,
    /// Worker pool + completion queue for blocking I/O primitives.
    /// Both have coupled lifetimes (pool writes to queue), so they're
    /// owned together. Null until `initAsync()` runs.
    async_runtime: ?*AsyncRuntime = null,
    /// Optional back-pointer to the live window manager. Wired by
    /// `main.zig` once the orchestrator is in its final home; stays
    /// null in headless mode so Lua layout bindings raise a clean
    /// "no window manager bound" error instead of dereferencing junk.
    window_manager: ?*WindowManager = null,
    /// Optional back-pointer to the live buffer registry. Wired by
    /// `main.zig` (points at `WindowManager.buffer_registry`). Tests
    /// can set it directly to a stand-alone registry. Null when no
    /// window manager is bound; in that case `zag.buffer.*` bindings
    /// raise a clean Lua error, and `zag.keymap{buffer=...}` cannot
    /// resolve handle strings.
    buffer_registry: ?*BufferRegistry = null,
    /// Registry of active coroutines keyed by thread ref. Drives resume.
    tasks: std.AutoHashMap(i32, *Task),
    /// Handlers registered via `zag.context.on_tool_result(name, fn)`.
    /// Keyed by tool name (the engine owns the key bytes; see `JitHandler`).
    /// Walked by `AgentRunner.dispatchHookRequests` when a
    /// `jit_context_request` arrives so the JIT context layer can attach
    /// `Instructions from: ...` content under a fresh tool result.
    /// Re-registering an existing tool name unrefs the old function and
    /// reuses the owned key, so memory does not bloat across reloads.
    jit_context_handlers: std.StringHashMapUnmanaged(JitHandler) = .empty,
    /// Handlers registered via `zag.tools.transform_output(name, fn)`.
    /// Same lifecycle and re-registration semantics as
    /// `jit_context_handlers`; the difference is purely how the agent
    /// loop consumes the return value: transforms REPLACE the tool
    /// output rather than appending under it.
    tool_transform_handlers: std.StringHashMapUnmanaged(JitHandler) = .empty,
    /// Single global handler registered via `zag.tools.gate(fn)`. The
    /// gate runs once per turn (before each `callLlm`) and returns the
    /// allowed-tool subset for that turn. There is no per-name keying:
    /// re-registering swaps the function (the previous Lua ref is
    /// unrefed). `null` means "no gate", so the agent uses the full
    /// registry. Released in `deinit`.
    tool_gate_handler: ?i32 = null,
    /// Single global handler registered via `zag.loop.detect(fn)`. The
    /// detector runs after each tool execution and returns either a
    /// reminder to push onto the next turn or an abort decision. Same
    /// re-registration semantics as `tool_gate_handler`: swap the ref,
    /// unref the old. `null` means "no detector", so the agent loops
    /// without intervention. Released in `deinit`.
    loop_detect_handler: ?i32 = null,
    /// Single global handler registered via `zag.compact.strategy(fn)`.
    /// The strategy runs at the top of each agent iteration when the
    /// running token estimate crosses the high-water threshold and
    /// returns either a replacement message array (which the agent
    /// installs in place of the existing history) or nil (skip
    /// compaction this turn). Same re-registration semantics as
    /// `tool_gate_handler`: swap the ref, unref the old. `null` means
    /// "no strategy", so the agent never compacts. Released in
    /// `deinit`.
    compact_handler: ?i32 = null,
    /// Root scope (parent of all agent/hook scopes).
    root_scope: ?*async_scope.Scope = null,

    /// Per-tool-name JIT context handler. The map key aliases
    /// `tool_name` so insert/remove operates on a single owned slice
    /// per registration.
    pub const JitHandler = struct {
        /// Owned tool-name copy. Same bytes referenced by the
        /// `StringHashMap` key; freed on unregister/deinit.
        tool_name: []u8,
        /// Lua registry ref to the handler function. Released via
        /// `lua.unref(zlua.registry_index, fn_ref)`.
        fn_ref: i32,
    };

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

    /// Borrowed view of the active provider registry. Callers that may not
    /// have a `LuaEngine` (engine boot failed, or the path was sandboxed
    /// before init) hand the optional pointer to `RegistryView.init`; with
    /// an engine, the source of truth is the engine's `providers_registry`,
    /// without one, an empty `llm.Registry` is allocated as a fallback so
    /// downstream code never has to special-case `null`.
    pub const RegistryView = struct {
        engine: ?*LuaEngine,
        fallback: ?llm.Registry,

        pub fn init(allocator: std.mem.Allocator, engine: ?*LuaEngine) RegistryView {
            return .{
                .engine = engine,
                .fallback = if (engine == null) llm.Registry.init(allocator) else null,
            };
        }

        pub fn ptr(self: *const RegistryView) *const llm.Registry {
            if (self.engine) |eng| return &eng.providers_registry;
            return &self.fallback.?;
        }

        pub fn deinit(self: *RegistryView) void {
            if (self.fallback) |*r| r.deinit();
        }
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

        // Install custom package.searchers so require() resolves
        // `~/.config/zag/lua/a/b.lua` (user override) before falling through
        // to the embedded stdlib baked into the binary. Standard Lua searchers
        // remain at the tail for anything else. No-op under sandbox mode
        // since `require`/`package` are stripped.
        try installSearchers(allocator, lua);

        var keymap_registry = Keymap.Registry.init(allocator);
        errdefer keymap_registry.deinit();
        try keymap_registry.loadDefaults();

        var providers_registry = llm.Registry.init(allocator);
        errdefer providers_registry.deinit();

        // Seed the prompt layer registry with the always-on built-ins
        // (identity, skills catalog, tool list, guidelines). Lua plugins
        // append more via `zag.prompt.layer{...}` during config load.
        var prompt_registry_value: prompt.Registry = .{};
        errdefer prompt_registry_value.deinit(allocator);
        try prompt.registerBuiltinLayers(&prompt_registry_value, allocator);

        // Install pure-Lua combinators that build on zag.spawn / :join /
        // :cancel / zag.sleep. These have to run after the primitive
        // bindings exist but don't depend on any engine state.
        lua.doString(combinators_src) catch |err| {
            log.warn("failed to load lua combinators: {}", .{err});
        };

        var command_registry = CommandRegistry.init(allocator);
        errdefer command_registry.deinit();
        // Seed the Zig-baked slash commands. Tests share this seeding via
        // `WindowManager.testCommandRegistry`; production calls land here.
        try command_registry.registerBuiltIn("/quit", .quit);
        try command_registry.registerBuiltIn("/q", .quit);
        try command_registry.registerBuiltIn("/perf", .perf);
        try command_registry.registerBuiltIn("/perf-dump", .perf_dump);

        return LuaEngine{
            .lua = lua,
            .allocator = allocator,
            .tools = .empty,
            .hook_dispatcher = hook_registry_mod.HookDispatcher.init(allocator),
            .providers_registry = providers_registry,
            .keymap_registry = keymap_registry,
            .command_registry = command_registry,
            .tasks = std.AutoHashMap(i32, *Task).init(allocator),
            .prompt_registry = prompt_registry_value,
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

    /// Borrow a read-only view of the subagent registry. The `task`
    /// tool and schema-emitters call through this handle; they must
    /// not mutate the registry so the binding stays the single writer.
    pub fn subagentRegistry(self: *const LuaEngine) *const subagents_mod.SubagentRegistry {
        return &self.subagents;
    }

    /// Resolve ~/.config/zag paths and load config.lua. All failures are
    /// logged and swallowed; missing config is not an error. The user-dir
    /// searcher that covers `~/.config/zag/lua/*.lua` is installed once in
    /// `init`, so `require()` works here without any additional setup.
    pub fn loadUserConfig(self: *LuaEngine) void {
        const home = std.process.getEnvVarOwned(self.allocator, "HOME") catch return;
        defer self.allocator.free(home);

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

    /// Require every embedded `zag.builtin.*`, `zag.layers.*`,
    /// `zag.jit.*`, `zag.loop.*`, `zag.compact.*`, and the `zag.prompt`
    /// dispatcher so the side effects (slash command registrations,
    /// keymap bindings, prompt layer registrations, JIT context
    /// handlers, loop detector handlers, compaction strategy handlers)
    /// land in the engine's registries. Must be called before
    /// `loadUserConfig` so a user's
    /// overrides win via the command registry's last-write-wins
    /// semantics and so that stable-class prompt layers register before
    /// the user's config has a chance to trigger the first render.
    ///
    /// `zag.prompt` (without a sub-segment) is the dispatcher itself;
    /// requiring it installs the catch-all `for_model(".*", ...)` that
    /// routes to a pack module on first render. The per-pack files
    /// (`zag.prompt.anthropic`, `zag.prompt.openai-codex`,
    /// `zag.prompt.default`) are deliberately *not* eager-loaded: the
    /// dispatcher pulls them in lazily via `require()` so a pack only
    /// registers when its model selects it.
    ///
    /// Failures are logged and swallowed; a broken builtin must never
    /// block engine startup.
    pub fn loadBuiltinPlugins(self: *LuaEngine) void {
        self.storeSelfPointer();
        for (embedded.entries) |entry| {
            const is_builtin = std.mem.startsWith(u8, entry.name, "zag.builtin.");
            const is_layer = std.mem.startsWith(u8, entry.name, "zag.layers.");
            const is_jit = std.mem.startsWith(u8, entry.name, "zag.jit.");
            const is_loop = std.mem.startsWith(u8, entry.name, "zag.loop.");
            const is_compact = std.mem.startsWith(u8, entry.name, "zag.compact.");
            const is_prompt_dispatcher = std.mem.eql(u8, entry.name, "zag.prompt");
            if (!is_builtin and !is_layer and !is_jit and !is_loop and !is_compact and !is_prompt_dispatcher) continue;
            var src_buf: [128]u8 = undefined;
            const src = std.fmt.bufPrintZ(&src_buf, "require('{s}')", .{entry.name}) catch {
                log.warn("builtin plugin: module name too long: {s}", .{entry.name});
                continue;
            };
            self.lua.doString(src) catch |err| {
                log.warn("builtin plugin load failed: {s}: {}", .{ entry.name, err });
            };
        }
    }

    /// Iterate the embedded stdlib manifest and `require(...)` each entry so
    /// the engine's `providers_registry` ends up populated with every shipped
    /// provider. Called from main when `config.lua` left the registry empty
    /// (first run, or a config that explicitly declared zero providers); also
    /// used by the CLI subcommand paths that need a working provider table
    /// without a user's config.lua.
    ///
    /// Failures on individual modules are logged and skipped; one broken
    /// stdlib entry must not take down the whole picker. Returns the number
    /// of modules that loaded successfully.
    pub fn bootstrapStdlibProviders(self: *LuaEngine) usize {
        self.storeSelfPointer();
        var loaded: usize = 0;
        for (embedded.entries) |entry| {
            if (!std.mem.startsWith(u8, entry.name, "zag.providers.")) continue;
            var src_buf: [128]u8 = undefined;
            const src = std.fmt.bufPrintZ(&src_buf, "require('{s}')", .{entry.name}) catch {
                log.warn("stdlib bootstrap: module name too long: {s}", .{entry.name});
                continue;
            };
            self.lua.doString(src) catch |err| {
                log.warn("stdlib bootstrap: failed to load {s}: {}", .{ entry.name, err });
                continue;
            };
            loaded += 1;
        }
        return loaded;
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
        // Unref every Lua callback held by Lua-registered prompt layers
        // and free the names we duped when the layer was registered.
        // Built-in layers carry a `lua_ref` of null and borrow their
        // names from rodata, so they skip both paths.
        for (self.prompt_registry.layers.items) |layer| {
            if (layer.lua_ref) |ref| self.lua.unref(zlua.registry_index, ref);
        }
        for (self.prompt_layer_names.items) |name| self.allocator.free(name);
        self.prompt_layer_names.deinit(self.allocator);
        self.prompt_registry.deinit(self.allocator);
        self.reminders.deinit(self.allocator);
        for (self.hook_dispatcher.registry.hooks.items) |h| {
            self.lua.unref(zlua.registry_index, h.lua_ref);
        }
        self.hook_dispatcher.deinit();
        self.providers_registry.deinit();
        self.subagents.deinit(self.allocator);
        if (self.default_model) |m| self.allocator.free(m);
        if (self.thinking_effort) |e| self.allocator.free(e);
        // Release every Lua callback ref a keymap binding still holds.
        // Bindings stored as `Action.lua_callback` own a registry slot
        // that would otherwise leak when the VM is torn down.
        for (self.keymap_registry.bindings.items) |b| {
            switch (b.action) {
                .lua_callback => |ref| self.lua.unref(zlua.registry_index, ref),
                else => {},
            }
        }
        self.keymap_registry.deinit();
        // Release Lua callback refs held by slash commands registered
        // through `zag.command{}`. Same rationale as the keymap loop
        // above: otherwise the refs leak until the VM itself is torn
        // down on the next line.
        var cmd_iter = self.command_registry.entries.iterator();
        while (cmd_iter.next()) |entry| {
            switch (entry.value_ptr.*) {
                .lua_callback => |ref| self.lua.unref(zlua.registry_index, ref),
                .built_in => {},
            }
        }
        self.command_registry.deinit();
        // Release every JIT context handler registered via
        // `zag.context.on_tool_result(name, fn)`. Keys are owned by the
        // entry's `tool_name` slice (the map borrows the bytes), so we
        // free that single slice per entry; the StringHashMap itself
        // releases its bucket storage in `deinit`.
        var jit_iter = self.jit_context_handlers.iterator();
        while (jit_iter.next()) |entry| {
            self.lua.unref(zlua.registry_index, entry.value_ptr.fn_ref);
            self.allocator.free(entry.value_ptr.tool_name);
        }
        self.jit_context_handlers.deinit(self.allocator);
        // Same release dance for transform handlers registered via
        // `zag.tools.transform_output`. Both maps share `JitHandler` so
        // the cleanup is identical.
        var transform_iter = self.tool_transform_handlers.iterator();
        while (transform_iter.next()) |entry| {
            self.lua.unref(zlua.registry_index, entry.value_ptr.fn_ref);
            self.allocator.free(entry.value_ptr.tool_name);
        }
        self.tool_transform_handlers.deinit(self.allocator);
        // Release the single global tool-gate handler (set by
        // `zag.tools.gate(fn)`). Null means no handler was ever
        // registered or it was cleared; either way nothing to unref.
        if (self.tool_gate_handler) |fn_ref| {
            self.lua.unref(zlua.registry_index, fn_ref);
            self.tool_gate_handler = null;
        }
        // Same release dance for the single global loop-detector
        // handler (set by `zag.loop.detect(fn)`).
        if (self.loop_detect_handler) |fn_ref| {
            self.lua.unref(zlua.registry_index, fn_ref);
            self.loop_detect_handler = null;
        }
        // Same release dance for the single global compaction strategy
        // handler (set by `zag.compact.strategy(fn)`).
        if (self.compact_handler) |fn_ref| {
            self.lua.unref(zlua.registry_index, fn_ref);
            self.compact_handler = null;
        }
        self.lua.deinit();
    }

    /// Create the `zag` global table with a `tool()` function.
    /// Does not store the engine pointer yet (see `storeSelfPointer`).
    fn injectZagGlobal(lua: *Lua) void {
        lua.newTable();
        // zag.tool is a callable table: `zag.tool{...}` registers a
        // Lua-defined tool. Collection-of-tools sockets like
        // `transform_output` and `gate` live under `zag.tools` so all
        // tool-registry hooks share one namespace. Stack after this
        // block: [zag_table].
        lua.newTable(); // [zag_table, tool_table]
        lua.newTable(); // [zag_table, tool_table, mt]
        lua.pushFunction(zlua.wrap(zagToolCallFn));
        lua.setField(-2, "__call"); // mt.__call = zagToolCallFn
        lua.setMetatable(-2); // setmetatable(tool_table, mt)
        lua.setField(-2, "tool"); // zag.tool = tool_table; [zag_table]
        lua.pushFunction(zlua.wrap(zagHookFn));
        lua.setField(-2, "hook");
        lua.pushFunction(zlua.wrap(zagHookDelFn));
        lua.setField(-2, "hook_del");
        lua.pushFunction(zlua.wrap(zagKeymapFn));
        lua.setField(-2, "keymap");
        lua.pushFunction(zlua.wrap(zagKeymapRemoveFn));
        lua.setField(-2, "keymap_remove");
        lua.pushFunction(zlua.wrap(zagCommandFn));
        lua.setField(-2, "command");
        lua.pushFunction(zlua.wrap(zagSetEscapeTimeoutMsFn));
        lua.setField(-2, "set_escape_timeout_ms");
        lua.pushFunction(zlua.wrap(zagSetDefaultModelFn));
        lua.setField(-2, "set_default_model");
        lua.pushFunction(zlua.wrap(zagSetThinkingEffortFn));
        lua.setField(-2, "set_thinking_effort");
        lua.pushFunction(zlua.wrap(zagProviderFn));
        lua.setField(-2, "provider");
        lua.pushFunction(zlua.wrap(zagSleepFn));
        lua.setField(-2, "sleep");
        lua.pushFunction(zlua.wrap(zagSpawnFn));
        lua.setField(-2, "spawn");
        lua.pushFunction(zlua.wrap(zagDetachFn));
        lua.setField(-2, "detach");
        // zag.reminders; namespace for the reminder queue. `push(text, opts)`
        // enqueues an entry, `clear(id)` drops a pending entry, `list()`
        // snapshots the queue. Stack: [zag_table].
        lua.newTable(); // [zag_table, reminders_table]
        lua.pushFunction(zlua.wrap(zagReminderFn));
        lua.setField(-2, "push");
        lua.pushFunction(zlua.wrap(zagReminderClearFn));
        lua.setField(-2, "clear");
        lua.pushFunction(zlua.wrap(zagReminderListFn));
        lua.setField(-2, "list");
        lua.setField(-2, "reminders"); // zag.reminders = reminders_table; [zag_table]

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
        lua.pushFunction(zlua.wrap(zagFsReadFileSyncFn));
        lua.setField(-2, "read_file_sync");
        lua.pushFunction(zlua.wrap(zagFsListDirSyncFn));
        lua.setField(-2, "list_dir_sync");
        lua.setField(-2, "fs"); // zag.fs = fs_table; [zag_table]

        // zag.layout; plain namespace table for window-tree inspection
        // and mutation. Requires a live window manager, which main.zig
        // wires via `engine.window_manager`. Headless runs leave the
        // field null and these bindings raise a clean Lua error.
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

        // zag.pane; per-pane inspection + mutation primitives. Mirrors
        // the `pane_read` tool for reads, and carries `set_model` /
        // `current_model` so a Lua picker plugin can drive the same
        // swap pathway the built-in `/model` command uses.
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

        // zag.providers; read-only view of the endpoint registry so a
        // Lua model picker can enumerate providers/models without
        // re-implementing the stdlib bookkeeping.
        lua.newTable(); // [zag_table, providers_table]
        lua.pushFunction(zlua.wrap(zagProvidersListFn));
        lua.setField(-2, "list");
        lua.setField(-2, "providers"); // zag.providers = providers_table; [zag_table]

        // zag.mode; switch the global editing mode from Lua. Modal
        // pickers (e.g. /model) flip to "normal" on open so their
        // normal-mode key bindings actually fire, and restore the
        // previous mode on close.
        lua.newTable(); // [zag_table, mode_table]
        lua.pushFunction(zlua.wrap(zagModeSetFn));
        lua.setField(-2, "set");
        lua.pushFunction(zlua.wrap(zagModeGetFn));
        lua.setField(-2, "get");
        lua.setField(-2, "mode"); // zag.mode = mode_table; [zag_table]

        // zag.subagent; declarative registry for Lua-defined subagents.
        // `register{}` validates and deep-copies the entry into the
        // engine-owned SubagentRegistry so the `task` tool can dispatch
        // to it later without chasing Lua-side lifetimes.
        lua.newTable(); // [zag_table, subagent_table]
        lua.pushFunction(zlua.wrap(zagSubagentRegisterFn));
        lua.setField(-2, "register");
        lua.setField(-2, "subagent"); // zag.subagent = subagent_table; [zag_table]

        // zag.prompt; system-prompt layer registration. `layer{}` appends
        // to the engine's shared `prompt.Registry`; the agent loop drives
        // render through `renderPromptLayers` each turn. See Task 3.1.
        lua.newTable(); // [zag_table, prompt_table]
        lua.pushFunction(zlua.wrap(zagPromptLayerFn));
        lua.setField(-2, "layer");
        lua.pushFunction(zlua.wrap(zagPromptForModelFn));
        lua.setField(-2, "for_model");
        lua.setField(-2, "prompt"); // zag.prompt = prompt_table; [zag_table]

        // zag.context; project-context lookups for prompt layers. The
        // walk-up logic lives in `Instruction.zig`; this binding hands
        // back a ready-to-render `{path, content}` table so a Lua layer
        // can drop in without re-implementing filesystem traversal.
        lua.newTable(); // [zag_table, context_table]
        lua.pushFunction(zlua.wrap(zagContextFindUpFn));
        lua.setField(-2, "find_up");
        lua.pushFunction(zlua.wrap(zagContextOnToolResultFn));
        lua.setField(-2, "on_tool_result");
        lua.setField(-2, "context"); // zag.context = context_table; [zag_table]

        // zag.buffer; buffer primitives for Lua plugins. Each binding
        // resolves a `"b<u32>"` handle string through the live
        // `BufferRegistry` (wired by main.zig) and operates on the
        // underlying entry. Only `.scratch` is valid at this point;
        // future kinds add arms to the match below.
        lua.newTable(); // [zag_table, buffer_table]
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
        lua.setField(-2, "buffer"); // zag.buffer = buffer_table; [zag_table]

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

        // zag.parse_frontmatter; narrow YAML parser reused by stdlib
        // loaders (subagents, skills). Sync helper so Lua modules can
        // call it during `require` without spinning up a coroutine.
        lua.pushFunction(zlua.wrap(zagParseFrontmatterFn));
        lua.setField(-2, "parse_frontmatter");

        // zag.tools; namespace for tool-registry sockets. `gate(fn)` is a
        // single global pre-callLlm hook; `transform_output(name, fn)`
        // hangs a per-tool post-execution output rewriter. Future tool-
        // facing sockets hang off the same table. Stack: [zag_table].
        lua.newTable(); // [zag_table, tools_table]
        lua.pushFunction(zlua.wrap(zagToolsGateFn));
        lua.setField(-2, "gate");
        lua.pushFunction(zlua.wrap(zagToolTransformOutputFn));
        lua.setField(-2, "transform_output");
        lua.setField(-2, "tools"); // zag.tools = tools_table; [zag_table]

        // zag.loop; namespace for agent-loop sockets. Today only
        // `detect(fn)` (single global post-tool-result hook). The
        // detector returns either a reminder to inject on the next
        // turn or an abort to stop the loop. Stack: [zag_table].
        lua.newTable(); // [zag_table, loop_table]
        lua.pushFunction(zlua.wrap(zagLoopDetectFn));
        lua.setField(-2, "detect");
        lua.setField(-2, "loop"); // zag.loop = loop_table; [zag_table]

        // zag.compact; namespace for context-compaction sockets. Today
        // only `strategy(fn)` (single global pre-callLlm hook fired at
        // the high-water threshold). The strategy returns a replacement
        // message array (installed in place of the existing history) or
        // nil (skip this turn). Stack: [zag_table].
        lua.newTable(); // [zag_table, compact_table]
        lua.pushFunction(zlua.wrap(zagCompactStrategyFn));
        lua.setField(-2, "strategy");
        lua.setField(-2, "compact"); // zag.compact = compact_table; [zag_table]

        // zag.width; grapheme-aware terminal-cell width measurement. Plugins
        // doing column alignment (e.g. popup-completion menus with mixed
        // ASCII/CJK/emoji content) must call `cells(s)` instead of `#s` so
        // wide and zero-width clusters don't skew the layout.
        lua.newTable(); // [zag_table, width_table]
        lua.pushFunction(zlua.wrap(zagWidthCellsFn));
        lua.setField(-2, "cells");
        lua.setField(-2, "width"); // zag.width = width_table; [zag_table]

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

    /// `zag.fs.read_file_sync(path)`: SYNC file read. Returns the file
    /// contents as a Lua string, or `nil` on any error (missing file,
    /// permission denied, OOM). Intended for stdlib loaders that run at
    /// `require` time outside any coroutine; heavy callers should
    /// continue to use the async `zag.fs.read`.
    ///
    /// Cap at 4 MiB to stop a runaway load from blocking the main
    /// thread with a multi-megabyte copy. Files larger than the cap
    /// return nil; the caller logs and moves on.
    fn zagFsReadFileSyncFn(co: *Lua) i32 {
        const max_bytes: usize = 4 * 1024 * 1024;
        const path = co.checkString(1);
        const engine = getEngineFromState(co);

        const file = std.fs.cwd().openFile(path, .{}) catch {
            co.pushNil();
            return 1;
        };
        defer file.close();

        const bytes = file.readToEndAlloc(engine.allocator, max_bytes) catch {
            co.pushNil();
            return 1;
        };
        defer engine.allocator.free(bytes);

        _ = co.pushString(bytes);
        return 1;
    }

    /// `zag.fs.list_dir_sync(path)`: SYNC directory listing. Returns a
    /// Lua array of filename strings (excluding `.` and `..`), or `nil`
    /// if the directory can't be opened. Subdirectories are listed as
    /// their own names; the caller filters by extension when needed.
    fn zagFsListDirSyncFn(co: *Lua) i32 {
        const path = co.checkString(1);

        var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch {
            co.pushNil();
            return 1;
        };
        defer dir.close();

        co.newTable();
        var it = dir.iterate();
        var idx: i32 = 0;
        while (true) {
            const entry = it.next() catch {
                // Partial listings aren't useful; drop the table and
                // signal the caller to skip this directory.
                co.pop(1);
                co.pushNil();
                return 1;
            };
            const e = entry orelse break;
            idx += 1;
            _ = co.pushString(e.name);
            co.rawSetIndex(-2, idx);
        }
        return 1;
    }

    /// `zag.parse_frontmatter(src)`: parse the YAML frontmatter at the
    /// start of `src` and return `{ fields = {...}, body = "..." }`.
    /// `fields` is a Lua table keyed by frontmatter name; scalar values
    /// map to strings, list values to Lua arrays of strings. `body` is
    /// the markdown tail (bytes after the closing `---`), empty when
    /// the document has no frontmatter.
    ///
    /// Raises a Lua error on unterminated frontmatter or allocator
    /// failure; both are caller-fixable and should surface loudly.
    /// `zag.width.cells(s)`: return the terminal-cell display width of
    /// `s`, with grapheme-cluster awareness (CJK is 2, emoji is 2, ZWJ
    /// sequences and combining marks are absorbed). Falls back to byte
    /// length for invalid UTF-8 — the iterator runs over `Utf8View.initUnchecked`,
    /// so callers passing arbitrary bytes get a "best effort" width
    /// rather than a Lua error. Lua plugins use this in place of `#s`
    /// when laying out columns over user-supplied content.
    fn zagWidthCellsFn(lua: *Lua) i32 {
        const text = lua.checkString(1);
        const cells = width.displayWidth(text);
        lua.pushInteger(@intCast(cells));
        return 1;
    }

    fn zagParseFrontmatterFn(lua: *Lua) i32 {
        const engine = getEngineFromState(lua);
        const src = lua.checkString(1);

        var parsed = frontmatter_mod.parse(engine.allocator, src) catch |err| {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrintZ(
                &buf,
                "zag.parse_frontmatter: {s}",
                .{@errorName(err)},
            ) catch "zag.parse_frontmatter: error";
            lua.raiseErrorStr("%s", .{msg.ptr});
        };
        defer parsed.deinit(engine.allocator);

        // { fields = {...}, body = "..." }
        lua.newTable();

        lua.newTable();
        var it = parsed.fields.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const key_z = engine.allocator.dupeZ(u8, key) catch {
                lua.raiseErrorStr("zag.parse_frontmatter: OOM copying key", .{});
            };
            defer engine.allocator.free(key_z);

            switch (entry.value_ptr.*) {
                .string => |s| {
                    _ = lua.pushString(s);
                },
                .list => |items| {
                    lua.newTable();
                    for (items, 0..) |item, i| {
                        _ = lua.pushString(item);
                        lua.rawSetIndex(-2, @intCast(i + 1));
                    }
                },
            }
            lua.setField(-2, key_z);
        }
        lua.setField(-2, "fields");

        const body = if (parsed.body_start <= src.len)
            src[parsed.body_start..]
        else
            "";
        _ = lua.pushString(body);
        lua.setField(-2, "body");

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
        const engine = getEngineFromState(lua);
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
        const engine = getEngineFromState(lua);
        const wm = engine.window_manager orelse {
            lua.raiseErrorStr("zag.layout.split: no window manager bound", .{});
        };
        const handle = requireLayoutHandle(lua, 1, "zag.layout.split");
        if (lua.typeOf(2) != .string) {
            lua.raiseErrorStr("zag.layout.split: direction must be a string", .{});
        }
        const dir_str = lua.toString(2) catch {
            lua.raiseErrorStr("zag.layout.split: direction must be a string", .{});
        };
        const direction: Layout.SplitDirection = if (std.mem.eql(u8, dir_str, "vertical"))
            .vertical
        else if (std.mem.eql(u8, dir_str, "horizontal"))
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
        const engine = getEngineFromState(lua);
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
        const engine = getEngineFromState(lua);
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

        // `relative` — slice 2 accepts "editor" and "cursor". Each
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
                const handle_str = lua.toString(-1) catch {
                    lua.raiseErrorStr("zag.layout.float: win must be a handle string", .{});
                };
                relative_to = NodeRegistry.parseId(handle_str) catch {
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
        const engine = getEngineFromState(lua);
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
        const engine = getEngineFromState(lua);
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

    /// `zag.layout.floats() -> { handle_str, ... }`: return a Lua
    /// array of `n<u32>` handle strings for every live float, in
    /// ascending z order.
    fn zagLayoutFloatsFn(lua: *Lua) i32 {
        const engine = getEngineFromState(lua);
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
        const engine = getEngineFromState(lua);
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
        const engine = getEngineFromState(lua);
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
        const engine = getEngineFromState(lua);
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
        const engine = getEngineFromState(lua);
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
        const engine = getEngineFromState(lua);
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
        const engine = getEngineFromState(lua);
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
    /// or overflow past MAX_DRAFT — autocomplete plugins know the trigger
    /// position and want loud failure if anything is off.
    fn zagPaneReplaceDraftRangeFn(lua: *Lua) i32 {
        const engine = getEngineFromState(lua);
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

    /// `zag.mode.set("normal" | "insert")`: flip the global editing
    /// mode. Returns nothing. Used by modal popups (`/model` etc.) so
    /// their normal-mode key bindings fire without the user pressing
    /// Esc first.
    fn zagModeSetFn(lua: *Lua) i32 {
        const engine = getEngineFromState(lua);
        const wm = engine.window_manager orelse {
            lua.raiseErrorStr("zag.mode.set: no window manager bound", .{});
        };
        if (lua.typeOf(1) != .string) {
            lua.raiseErrorStr("zag.mode.set: mode must be a string", .{});
        }
        const name = lua.toString(1) catch {
            lua.raiseErrorStr("zag.mode.set: mode must be a string", .{});
        };
        if (std.mem.eql(u8, name, "normal")) {
            wm.current_mode = .normal;
        } else if (std.mem.eql(u8, name, "insert")) {
            wm.current_mode = .insert;
        } else {
            lua.raiseErrorStr("zag.mode.set: mode must be \"normal\" or \"insert\"", .{});
        }
        return 0;
    }

    /// `zag.mode.get()`: return the current editing mode as a string,
    /// either `"normal"` or `"insert"`. Lets a popup snapshot the mode
    /// on open so it can restore exactly that mode on close.
    fn zagModeGetFn(lua: *Lua) i32 {
        const engine = getEngineFromState(lua);
        const wm = engine.window_manager orelse {
            lua.raiseErrorStr("zag.mode.get: no window manager bound", .{});
        };
        const name: []const u8 = switch (wm.current_mode) {
            .normal => "normal",
            .insert => "insert",
        };
        _ = lua.pushString(name);
        return 1;
    }

    /// `zag.providers.list()`: snapshot the endpoint registry as a Lua
    /// table keyed by provider name. Each entry carries `default_model`
    /// and a `models` array of `{ id, label?, recommended }` rows so a
    /// Lua picker can render them without touching the Zig registry.
    fn zagProvidersListFn(lua: *Lua) i32 {
        const engine = getEngineFromState(lua);
        lua.newTable();
        for (engine.providers_registry.endpoints.items) |ep| {
            lua.newTable();

            _ = lua.pushString(ep.default_model);
            lua.setField(-2, "default_model");

            lua.newTable();
            for (ep.models, 0..) |m, idx| {
                lua.newTable();
                _ = lua.pushString(m.id);
                lua.setField(-2, "id");
                if (m.label) |lbl| {
                    _ = lua.pushString(lbl);
                    lua.setField(-2, "label");
                }
                lua.pushBoolean(m.recommended);
                lua.setField(-2, "recommended");
                // Lua arrays are 1-indexed; rawSetIndex writes at that slot.
                lua.rawSetIndex(-2, @intCast(idx + 1));
            }
            lua.setField(-2, "models");

            // Copy the name for the key so the `[]const u8` slice does
            // not escape the loop body.
            var name_buf: [64]u8 = undefined;
            const key = std.fmt.bufPrintZ(&name_buf, "{s}", .{ep.name}) catch {
                lua.raiseErrorStr("zag.providers.list: name too long", .{});
            };
            lua.setField(-2, key);
        }
        return 1;
    }

    /// Shared prelude for every `zag.buffer.*` binding (except `create`).
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
        const engine = getEngineFromState(lua);
        const registry = engine.buffer_registry orelse {
            lua.raiseErrorStr(op_name ++ ": no buffer registry bound", .{});
        };
        if (lua.typeOf(arg_index) != .string) {
            lua.raiseErrorStr(op_name ++ ": handle must be a string", .{});
        }
        const handle_str = lua.toString(arg_index) catch {
            lua.raiseErrorStr(op_name ++ ": handle must be a string", .{});
        };
        const handle = BufferRegistry.parseId(handle_str) catch {
            lua.raiseErrorStr(op_name ++ ": invalid handle", .{});
        };
        const entry = registry.resolve(handle) catch {
            lua.raiseErrorStr(op_name ++ ": stale handle", .{});
        };
        return entry;
    }

    /// Shared rejection arm for `zag.buffer.*` ops that only operate on
    /// scratch buffers. Graphics buffers expose a different surface (pixel
    /// data, no row addressing) so calling line/cursor APIs on them is a
    /// plugin bug worth surfacing as a Lua error rather than silently
    /// no-oping.
    fn rejectGraphicsBuffer(lua: *Lua, comptime op_name: []const u8) noreturn {
        lua.raiseErrorStr(op_name ++ ": not supported on graphics buffers", .{});
    }

    /// Shared rejection arm for `zag.buffer.*` ops that target scratch or
    /// graphics buffers but were called on a text buffer. Text buffers
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
        const engine = getEngineFromState(lua);
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
        const kind_str = lua.toString(-1) catch {
            lua.raiseErrorStr("zag.buffer.create: field 'kind' must be a string", .{});
        };
        // Copy-out before popping: the Lua string lives in the table
        // slot we release on pop, and the downstream branch compares
        // against it. The enum value carries the decision forward so
        // we don't keep the borrowed slice alive past the pop.
        const KindTag = enum { scratch, graphics };
        const kind_tag: KindTag = if (std.mem.eql(u8, kind_str, "scratch"))
            .scratch
        else if (std.mem.eql(u8, kind_str, "graphics"))
            .graphics
        else {
            lua.raiseErrorStr("zag.buffer.create: unknown kind (valid kinds: \"scratch\", \"graphics\")", .{});
        };
        lua.pop(1);

        var name_buf: []const u8 = switch (kind_tag) {
            .scratch => "scratch",
            .graphics => "graphics",
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
            .graphics => registry.createGraphics(name_buf),
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
        const engine = getEngineFromState(lua);

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
            .graphics => rejectGraphicsBuffer(lua, "zag.buffer.set_lines"),
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
            .graphics => rejectGraphicsBuffer(lua, "zag.buffer.get_lines"),
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
            .graphics => rejectGraphicsBuffer(lua, "zag.buffer.line_count"),
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
            .graphics => rejectGraphicsBuffer(lua, "zag.buffer.cursor_row"),
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
            .graphics => rejectGraphicsBuffer(lua, "zag.buffer.set_cursor_row"),
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
            .graphics => rejectGraphicsBuffer(lua, "zag.buffer.current_line"),
            .text => rejectTextBuffer(lua, "zag.buffer.current_line"),
        }
    }

    /// `zag.buffer.delete(handle)`: destroy the buffer and free its
    /// registry slot. The handle's generation advances so subsequent
    /// lookups surface `stale handle`.
    fn zagBufferDeleteFn(lua: *Lua) i32 {
        const engine = getEngineFromState(lua);
        const registry = engine.buffer_registry orelse {
            lua.raiseErrorStr("zag.buffer.delete: no buffer registry bound", .{});
        };
        if (lua.typeOf(1) != .string) {
            lua.raiseErrorStr("zag.buffer.delete: handle must be a string", .{});
        }
        const handle_str = lua.toString(1) catch {
            lua.raiseErrorStr("zag.buffer.delete: handle must be a string", .{});
        };
        const handle = BufferRegistry.parseId(handle_str) catch {
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
    /// the RGBA image on the graphics buffer referenced by `handle`.
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
            .graphics => |gb| {
                gb.setPng(bytes) catch |err| {
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

    /// `zag.buffer.set_fit(handle, fit)`: set the graphics buffer's fit
    /// policy. `fit` is one of `"contain"`, `"fill"`, `"actual"`. Any
    /// other string raises a Lua error; scratch handles raise a Lua
    /// error.
    fn zagBufferSetFitFn(lua: *Lua) i32 {
        const entry = requireBufferEntry(lua, 1, "zag.buffer.set_fit");
        if (lua.typeOf(2) != .string) {
            lua.raiseErrorStr("zag.buffer.set_fit: arg 2 must be a string", .{});
        }
        const fit_str = lua.toString(2) catch {
            lua.raiseErrorStr("zag.buffer.set_fit: arg 2 must be a string", .{});
        };
        const fit: GraphicsBuffer.Fit = if (std.mem.eql(u8, fit_str, "contain"))
            .contain
        else if (std.mem.eql(u8, fit_str, "fill"))
            .fill
        else if (std.mem.eql(u8, fit_str, "actual"))
            .actual
        else {
            lua.raiseErrorStr("zag.buffer.set_fit: fit must be \"contain\", \"fill\", or \"actual\"", .{});
        };
        switch (entry) {
            .graphics => |gb| gb.setFit(fit),
            .scratch => lua.raiseErrorStr("zag.buffer.set_fit: handle is not a graphics buffer", .{}),
            .text => lua.raiseErrorStr("zag.buffer.set_fit: handle is not a graphics buffer", .{}),
        }
        return 0;
    }

    /// `zag.buffer.set_row_style(handle, row, slot)`: tag a 1-indexed
    /// row with a theme highlight slot string. The row override paints
    /// across the row's background at render time. Raises on
    /// out-of-range row, unknown slot, or graphics handles.
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
        const slot_str = lua.toString(3) catch {
            lua.raiseErrorStr("zag.buffer.set_row_style: slot must be a string", .{});
        };
        const slot = Theme.parseHighlightSlot(slot_str) orelse {
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
            .graphics => lua.raiseErrorStr("zag.buffer.set_row_style: not supported on graphics buffers (no row addressing)", .{}),
            .text => rejectTextBuffer(lua, "zag.buffer.set_row_style"),
        }
        return 0;
    }

    /// `zag.buffer.clear_row_style(handle, row)`: drop a row's
    /// highlight override. No-op when the row has no override, and a
    /// no-op on graphics buffers (which carry no row-style state).
    /// Cleanup is permissive; only `set_row_style` raises on graphics
    /// since it expresses an intent that cannot take effect.
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
            .graphics => {},
            .text => {},
        }
        return 0;
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
        return zagToolFnInner(lua, 1) catch |err| {
            log.err("zag.tool() failed: {}", .{err});
            return err;
        };
    }

    /// Metatable __call entry: when a user writes `zag.tool{...}`, Lua
    /// invokes this with the callable table at slot 1 and the user
    /// table at slot 2. Delegate to the inner reader with a shifted
    /// base index so the callable-vs-direct callsites share one body.
    fn zagToolCallFn(lua: *Lua) !i32 {
        return zagToolFnInner(lua, 2) catch |err| {
            log.err("zag.tool() failed: {}", .{err});
            return err;
        };
    }

    fn zagToolFnInner(lua: *Lua, table_idx: i32) !i32 {
        if (!lua.isTable(table_idx)) {
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
        _ = lua.getField(table_idx, "name");
        const tool_name = lua.toString(-1) catch {
            log.err("zag.tool(): 'name' field must be a string", .{});
            lua.pop(1);
            return error.LuaError;
        };
        lua.pop(1);

        // Read description (Lua string, borrowed from VM; invalidated by next pop)
        _ = lua.getField(table_idx, "description");
        const description = lua.toString(-1) catch {
            log.err("zag.tool(): 'description' field must be a string", .{});
            lua.pop(1);
            return error.LuaError;
        };
        lua.pop(1);

        // Read optional prompt_snippet (Lua string, borrowed from VM; invalidated by next pop)
        _ = lua.getField(table_idx, "prompt_snippet");
        const prompt_snippet: ?[]const u8 = if (lua.isString(-1))
            lua.toString(-1) catch null
        else
            null;
        lua.pop(1);

        // Read input_schema table and serialize to JSON
        _ = lua.getField(table_idx, "input_schema");
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
        _ = lua.getField(table_idx, "execute");
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

    /// Zig function backing `zag.command{name, fn, desc?}`.
    /// Registers a slash command into the engine-owned `command_registry`.
    /// Built-ins keyed on the same slash form are shadowed by the new
    /// Lua callback; the window manager checks the engine's registry
    /// before its own, so plugins always win.
    fn zagCommandFn(lua: *Lua) !i32 {
        return zagCommandFnInner(lua) catch |err| {
            log.warn("zag.command() failed: {}", .{err});
            return err;
        };
    }

    fn zagCommandFnInner(lua: *Lua) !i32 {
        if (!lua.isTable(1)) {
            log.warn("zag.command() expects a table argument", .{});
            return error.LuaError;
        }

        _ = lua.getField(zlua.registry_index, "_zag_engine");
        const ptr = lua.toPointer(-1) catch {
            log.warn("zag.command(): engine pointer not set (call storeSelfPointer first)", .{});
            return error.LuaError;
        };
        lua.pop(1);
        const engine: *LuaEngine = @ptrCast(@alignCast(@constCast(ptr)));

        // `name` is required. Borrowed from the Lua VM; we stringify it
        // with the leading slash into a local buffer before any call that
        // could pop the string off the stack.
        _ = lua.getField(1, "name");
        if (!lua.isString(-1)) {
            log.warn("zag.command(): 'name' field must be a string", .{});
            lua.pop(1);
            return error.LuaError;
        }
        const raw_name = lua.toString(-1) catch {
            log.warn("zag.command(): 'name' field must be a string", .{});
            lua.pop(1);
            return error.LuaError;
        };
        // The Lua form omits the leading slash so `zag.command{name="model"}`
        // reads naturally; the registry keys on the user-visible form.
        var slash_buf: [128]u8 = undefined;
        const slash_name = std.fmt.bufPrint(&slash_buf, "/{s}", .{raw_name}) catch {
            log.warn("zag.command(): name '{s}' too long", .{raw_name});
            lua.pop(1);
            return error.LuaError;
        };
        lua.pop(1);

        // `fn` is required; grab it last so the registry ref is the top
        // of stack when we call `lua.ref`.
        _ = lua.getField(1, "fn");
        if (!lua.isFunction(-1)) {
            log.warn("zag.command(): 'fn' field must be a function", .{});
            lua.pop(1);
            return error.LuaError;
        }
        const func_ref = lua.ref(zlua.registry_index) catch {
            log.warn("zag.command(): failed to create function reference", .{});
            return error.LuaError;
        };
        errdefer lua.unref(zlua.registry_index, func_ref);

        const displaced = try engine.command_registry.registerLua(slash_name, func_ref);
        if (displaced) |prev| switch (prev) {
            .lua_callback => |old_ref| lua.unref(zlua.registry_index, old_ref),
            .built_in => log.info("command {s} shadowed by Lua plugin", .{slash_name}),
        };

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

    /// Zig function backing `zag.reminders.push(text, opts?)`.
    ///
    /// `text` is the body folded into a `<system-reminder>` block at the
    /// next user-message boundary. `opts` is an optional table accepting:
    ///   - `scope`: "next_turn" (default) or "persistent".
    ///   - `id`:    optional string used by `zag.reminders.clear`.
    ///   - `once`:  optional boolean (default true); reserved for future
    ///              once-per-turn dedup, surfaced today so the schema is
    ///              stable.
    ///
    /// The queue dupes both `text` and `id` onto the engine allocator so
    /// callers may free their inputs immediately.
    fn zagReminderFn(lua: *Lua) !i32 {
        return zagReminderFnInner(lua) catch |err| {
            log.warn("zag.reminders.push() failed: {}", .{err});
            return err;
        };
    }

    fn zagReminderFnInner(lua: *Lua) !i32 {
        if (lua.typeOf(1) != .string) {
            log.warn("zag.reminders.push(): first argument must be a string", .{});
            return error.LuaError;
        }
        const text = lua.toString(1) catch {
            log.warn("zag.reminders.push(): first argument must be a string", .{});
            return error.LuaError;
        };

        var scope: Reminder.Scope = .next_turn;
        var id: ?[]const u8 = null;
        var once: bool = true;
        var id_pushed = false;
        defer if (id_pushed) lua.pop(1);

        if (!lua.isNoneOrNil(2)) {
            if (!lua.isTable(2)) {
                log.warn("zag.reminders.push(): second argument must be an options table", .{});
                return error.LuaError;
            }
            const opts_idx = lua.absIndex(2);

            _ = lua.getField(opts_idx, "scope");
            if (!lua.isNil(-1)) {
                if (lua.typeOf(-1) != .string) {
                    lua.pop(1);
                    log.warn("zag.reminders.push(): opts.scope must be a string", .{});
                    return error.LuaError;
                }
                const scope_name = lua.toString(-1) catch {
                    lua.pop(1);
                    return error.LuaError;
                };
                if (std.mem.eql(u8, scope_name, "next_turn")) {
                    scope = .next_turn;
                } else if (std.mem.eql(u8, scope_name, "persistent")) {
                    scope = .persistent;
                } else {
                    log.warn("zag.reminders.push(): opts.scope must be 'next_turn' or 'persistent', got '{s}'", .{scope_name});
                    lua.pop(1);
                    return error.LuaError;
                }
            }
            lua.pop(1);

            _ = lua.getField(opts_idx, "once");
            if (!lua.isNil(-1)) once = lua.toBoolean(-1);
            lua.pop(1);

            // `id` stays on the stack across the queue push so the
            // borrowed slice is anchored by Lua until `Queue.push` has
            // duped it onto the engine allocator. The deferred pop above
            // releases it on every exit path once we've pushed.
            _ = lua.getField(opts_idx, "id");
            id_pushed = true;
            if (!lua.isNil(-1)) {
                if (lua.typeOf(-1) != .string) {
                    log.warn("zag.reminders.push(): opts.id must be a string", .{});
                    return error.LuaError;
                }
                id = lua.toString(-1) catch return error.LuaError;
            }
        }

        const engine = try engineFromRegistry(lua);
        engine.reminders.push(engine.allocator, .{
            .id = id,
            .text = text,
            .scope = scope,
            .once = once,
        }) catch |err| {
            log.warn("zag.reminders.push(): queue push failed: {}", .{err});
            return error.LuaError;
        };
        return 0;
    }

    /// Zig function backing `zag.reminders.clear(id)`.
    fn zagReminderClearFn(lua: *Lua) !i32 {
        return zagReminderClearFnInner(lua) catch |err| {
            log.warn("zag.reminders.clear() failed: {}", .{err});
            return err;
        };
    }

    fn zagReminderClearFnInner(lua: *Lua) !i32 {
        if (lua.typeOf(1) != .string) {
            log.warn("zag.reminders.clear(): first argument must be a string id", .{});
            return error.LuaError;
        }
        const id = lua.toString(1) catch {
            log.warn("zag.reminders.clear(): first argument must be a string id", .{});
            return error.LuaError;
        };
        const engine = try engineFromRegistry(lua);
        engine.reminders.clearById(engine.allocator, id);
        return 0;
    }

    /// Zig function backing `zag.reminders.list()`. Returns a Lua array of
    /// `{ text, scope, id?, once }` tables snapshotting the queue without
    /// disturbing it. Useful for diagnostics and tests.
    fn zagReminderListFn(lua: *Lua) !i32 {
        return zagReminderListFnInner(lua) catch |err| {
            log.warn("zag.reminders.list() failed: {}", .{err});
            return err;
        };
    }

    fn zagReminderListFnInner(lua: *Lua) !i32 {
        const engine = try engineFromRegistry(lua);
        const snapshot = engine.reminders.snapshot(engine.allocator) catch |err| {
            log.warn("zag.reminders.list(): snapshot failed: {}", .{err});
            return error.LuaError;
        };
        defer Reminder.freeDrained(engine.allocator, snapshot);

        lua.newTable();
        for (snapshot, 0..) |entry, i| {
            lua.newTable();
            _ = lua.pushString(entry.text);
            lua.setField(-2, "text");
            _ = lua.pushString(switch (entry.scope) {
                .next_turn => "next_turn",
                .persistent => "persistent",
            });
            lua.setField(-2, "scope");
            if (entry.id) |entry_id| {
                _ = lua.pushString(entry_id);
                lua.setField(-2, "id");
            }
            lua.pushBoolean(entry.once);
            lua.setField(-2, "once");
            lua.rawSetIndex(-2, @intCast(i + 1));
        }
        return 1;
    }

    /// Resolve the `*LuaEngine` stashed in the Lua registry by
    /// `storeSelfPointer`. Centralizes the lookup so reminder bindings
    /// stay symmetrical with the older copy-paste pattern.
    fn engineFromRegistry(lua: *Lua) !*LuaEngine {
        _ = lua.getField(zlua.registry_index, "_zag_engine");
        defer lua.pop(1);
        const ptr = lua.toPointer(-1) catch {
            log.warn("engine pointer not set (call storeSelfPointer first)", .{});
            return error.LuaError;
        };
        return @ptrCast(@alignCast(@constCast(ptr)));
    }

    /// Zig function backing `zag.keymap(...)`. Accepts either the
    /// positional string form `(mode, key, action)` or a single table
    /// form `{ mode, key, buffer?, fn? | action? }` where exactly one of
    /// `fn` (a Lua function -> `Action.lua_callback`) or `action` (a
    /// string naming a built-in action) must be present, and `buffer` is
    /// the `"b<u32>"` handle string produced by `BufferRegistry.formatId`.
    fn zagKeymapFn(lua: *Lua) !i32 {
        return zagKeymapFnInner(lua) catch |err| {
            // User-config schema errors surface as warn (same as zag.provider).
            // The inner call site logs its own specific diagnostic before
            // returning; this is the final fallback line.
            log.warn("zag.keymap() failed: {}", .{err});
            return err;
        };
    }

    fn zagKeymapFnInner(lua: *Lua) !i32 {
        if (lua.isTable(1)) return zagKeymapTableFormInner(lua);
        return zagKeymapPositionalFormInner(lua);
    }

    fn zagKeymapPositionalFormInner(lua: *Lua) !i32 {
        // All three string args are borrowed from the Lua VM; read them
        // before any stack-mutating calls below.
        const mode_name = lua.toString(1) catch {
            log.err("zag.keymap(): arg 1 (mode) must be a string", .{});
            return error.LuaError;
        };
        const mode = parseModeName(mode_name) orelse {
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

        const engine = try keymapEnginePointer(lua);
        const result = try engine.keymap_registry.register(mode, spec, null, action);
        if (result.displaced) |prev| switch (prev) {
            .lua_callback => |old_ref| lua.unref(zlua.registry_index, old_ref),
            else => {},
        };
        lua.pushInteger(@intCast(result.id));
        pushDisplacedSpec(lua, mode, spec, null, result.displaced);
        return 2;
    }

    fn zagKeymapTableFormInner(lua: *Lua) !i32 {
        // Read mode.
        _ = lua.getField(1, "mode");
        if (lua.typeOf(-1) != .string) {
            log.err("zag.keymap{{}}: field 'mode' must be a string", .{});
            return error.LuaError;
        }
        const mode_name = lua.toString(-1) catch {
            log.err("zag.keymap{{}}: field 'mode' must be a string", .{});
            return error.LuaError;
        };
        const mode = parseModeName(mode_name) orelse {
            log.err("zag.keymap{{}}: unknown mode '{s}'", .{mode_name});
            return error.LuaError;
        };
        lua.pop(1);

        // Read key.
        _ = lua.getField(1, "key");
        if (lua.typeOf(-1) != .string) {
            log.err("zag.keymap{{}}: field 'key' must be a string", .{});
            return error.LuaError;
        }
        const key = lua.toString(-1) catch {
            log.err("zag.keymap{{}}: field 'key' must be a string", .{});
            return error.LuaError;
        };
        const spec = Keymap.parseKeySpec(key) catch {
            log.err("zag.keymap{{}}: invalid key spec '{s}'", .{key});
            return error.LuaError;
        };
        lua.pop(1);

        // Optional buffer handle string. Resolve the handle through the
        // live BufferRegistry and store the resulting `Buffer.getId()`
        // value in `binding.buffer_id` so it matches what
        // `EventOrchestrator` passes to `registry.lookup` at dispatch
        // time (`focused.conversation.buf().getId()`). Storing the packed Handle
        // directly would create two disjoint u32 namespaces and the
        // binding would never fire in production.
        var buffer_id: ?u32 = null;
        _ = lua.getField(1, "buffer");
        if (!lua.isNil(-1)) {
            if (lua.typeOf(-1) != .string) {
                log.err("zag.keymap{{}}: field 'buffer' must be a \"b<id>\" handle string", .{});
                return error.LuaError;
            }
            const handle_str = lua.toString(-1) catch {
                log.err("zag.keymap{{}}: field 'buffer' must be a \"b<id>\" handle string", .{});
                return error.LuaError;
            };
            const handle = BufferRegistry.parseId(handle_str) catch {
                log.err("zag.keymap{{}}: invalid buffer handle '{s}'", .{handle_str});
                return error.LuaError;
            };
            const engine_for_resolve = try keymapEnginePointer(lua);
            const registry = engine_for_resolve.buffer_registry orelse {
                log.warn("zag.keymap{{}}: no buffer registry bound; cannot resolve '{s}'", .{handle_str});
                return error.LuaError;
            };
            const entry = registry.asBuffer(handle) catch {
                log.warn("zag.keymap{{}}: stale buffer handle '{s}'", .{handle_str});
                return error.LuaError;
            };
            buffer_id = entry.getId();
        }
        lua.pop(1);

        // Detect action vs fn. Exactly one must be present.
        _ = lua.getField(1, "action");
        const has_action = !lua.isNil(-1);
        lua.pop(1);

        _ = lua.getField(1, "fn");
        const has_fn = !lua.isNil(-1);
        lua.pop(1);

        if (has_action and has_fn) {
            log.warn("zag.keymap{{}}: 'action' and 'fn' are mutually exclusive", .{});
            return error.LuaError;
        }
        if (!has_action and !has_fn) {
            log.warn("zag.keymap{{}}: exactly one of 'action' or 'fn' is required", .{});
            return error.LuaError;
        }

        const engine = try keymapEnginePointer(lua);

        if (has_action) {
            _ = lua.getField(1, "action");
            if (lua.typeOf(-1) != .string) {
                log.err("zag.keymap{{}}: field 'action' must be a string", .{});
                return error.LuaError;
            }
            const action_name = lua.toString(-1) catch {
                log.err("zag.keymap{{}}: field 'action' must be a string", .{});
                return error.LuaError;
            };
            const action = Keymap.parseActionName(action_name) orelse {
                log.err("zag.keymap{{}}: unknown action '{s}'", .{action_name});
                return error.LuaError;
            };
            lua.pop(1);
            const result = try engine.keymap_registry.register(mode, spec, buffer_id, action);
            if (result.displaced) |prev| switch (prev) {
                .lua_callback => |old_ref| lua.unref(zlua.registry_index, old_ref),
                else => {},
            };
            lua.pushInteger(@intCast(result.id));
            pushDisplacedSpec(lua, mode, spec, buffer_id, result.displaced);
            return 2;
        }

        // fn form: stash the Lua function in the registry and store the
        // ref in an `Action.lua_callback` payload. Teardown in `deinit`
        // unrefs every `.lua_callback` binding so the registry entry is
        // eligible for collection.
        _ = lua.getField(1, "fn");
        if (!lua.isFunction(-1)) {
            log.err("zag.keymap{{}}: field 'fn' must be a function", .{});
            return error.LuaError;
        }
        const cb_ref = try lua.ref(zlua.registry_index);
        errdefer lua.unref(zlua.registry_index, cb_ref);
        const result = try engine.keymap_registry.register(mode, spec, buffer_id, .{ .lua_callback = cb_ref });
        // When overwriting an existing binding whose action was a Lua
        // callback, the prior ref is now orphaned: unref it so the
        // registry slot becomes eligible for collection. Built-in
        // actions don't own anything that needs releasing.
        if (result.displaced) |prev| switch (prev) {
            .lua_callback => |old_ref| lua.unref(zlua.registry_index, old_ref),
            else => {},
        };
        lua.pushInteger(@intCast(result.id));
        pushDisplacedSpec(lua, mode, spec, buffer_id, result.displaced);
        return 2;
    }

    /// Zig function backing `zag.keymap_remove(id)`.
    /// Removes the binding minted by a prior `zag.keymap{...}` call and
    /// unrefs its `.lua_callback` ref (if any) so the registered Lua
    /// function becomes eligible for collection. Mirrors `zag.hook_del`.
    /// Raises a Lua error if `id` is not a positive integer or names no
    /// live binding.
    fn zagKeymapRemoveFn(lua: *Lua) !i32 {
        return zagKeymapRemoveFnInner(lua) catch |err| {
            log.warn("zag.keymap_remove() failed: {}", .{err});
            return err;
        };
    }

    fn zagKeymapRemoveFnInner(lua: *Lua) !i32 {
        // `checkInteger` raises a Lua error if the argument is missing,
        // not a number, or a non-integer-representable number (e.g.
        // 3.7). Using `toInteger` here would silently truncate floats,
        // so `zag.keymap_remove(3.7)` would unbind id 3 instead of
        // surfacing the bug to the plugin.
        const raw = lua.checkInteger(1);
        if (raw <= 0 or raw > std.math.maxInt(u32)) {
            log.warn("zag.keymap_remove(): id must be a positive u32, got {d}", .{raw});
            return error.LuaError;
        }
        const id: u32 = @intCast(raw);
        const engine = try keymapEnginePointer(lua);
        const removed = engine.keymap_registry.unregister(id) catch |err| switch (err) {
            error.NotFound => {
                log.warn("zag.keymap_remove(): no keymap binding with id {d}", .{id});
                return error.LuaError;
            },
        };
        switch (removed) {
            .lua_callback => |ref| engine.lua.unref(zlua.registry_index, ref),
            else => {},
        }
        return 0;
    }

    fn parseModeName(name: []const u8) ?Keymap.Mode {
        if (std.mem.eql(u8, name, "normal")) return .normal;
        if (std.mem.eql(u8, name, "insert")) return .insert;
        return null;
    }

    fn modeName(mode: Keymap.Mode) []const u8 {
        return switch (mode) {
            .normal => "normal",
            .insert => "insert",
        };
    }

    /// Push the second return value of `zag.keymap{...}` onto the Lua
    /// stack: a `displaced_spec` table `{mode, key, action}` describing
    /// the prior binding so a caller can pass it back through
    /// `zag.keymap{...}` to restore the override on cleanup, or `nil`
    /// when restoration is not possible. Restoration is unsupported
    /// in three cases, all surfaced as a `nil` second return:
    ///   * No prior binding existed (`displaced == null`).
    ///   * The displaced action was `.lua_callback` — the wrapper
    ///     already released the registry ref, so a plugin cannot
    ///     re-register a Lua callback it did not own.
    ///   * The displaced binding was buffer-scoped. The registry
    ///     stores the buffer's `getId()` value; reconstructing the
    ///     `b<id>` Handle the wrapper accepts would require an
    ///     id->Handle reverse lookup that doesn't exist today.
    /// The picker only registers global bindings whose displaced
    /// targets are built-in actions, so it never trips the latter
    /// two limitations. Allocates no heap memory; the key string is
    /// formatted into a stack buffer and copied into the Lua VM by
    /// `pushString`.
    fn pushDisplacedSpec(
        lua: *Lua,
        mode: Keymap.Mode,
        spec: Keymap.KeySpec,
        buffer_id: ?u32,
        displaced: ?Keymap.Action,
    ) void {
        const prev = displaced orelse {
            lua.pushNil();
            return;
        };
        const action_name = Keymap.actionName(prev) orelse {
            lua.pushNil();
            return;
        };
        if (buffer_id != null) {
            lua.pushNil();
            return;
        }

        var key_buf: [32]u8 = undefined;
        const key_text = Keymap.formatKeySpec(&key_buf, .{
            .key = spec.key,
            .modifiers = spec.modifiers,
        });

        lua.newTable();
        _ = lua.pushString(modeName(mode));
        lua.setField(-2, "mode");
        _ = lua.pushString(key_text);
        lua.setField(-2, "key");
        _ = lua.pushString(action_name);
        lua.setField(-2, "action");
    }

    fn keymapEnginePointer(lua: *Lua) !*LuaEngine {
        _ = lua.getField(zlua.registry_index, "_zag_engine");
        const ptr = lua.toPointer(-1) catch {
            log.err("zag.keymap(): engine pointer not set (call storeSelfPointer first)", .{});
            return error.LuaError;
        };
        lua.pop(1);
        return @ptrCast(@alignCast(@constCast(ptr)));
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

    /// Read accessor for the runtime reasoning_effort level. Providers
    /// that opted into `effort_request_field` consult this on each call
    /// to decide whether to inject the knob into the outgoing request.
    pub fn currentThinkingEffort(self: *LuaEngine) ?[]const u8 {
        return self.thinking_effort;
    }

    /// Zig function backing `zag.set_thinking_effort(level)`.
    /// Accepts one of `"minimal"`, `"low"`, `"medium"`, `"high"`, or
    /// `nil` to clear the runtime setting. Stored module-level on the
    /// engine so it survives across turns within a session. Providers
    /// that didn't opt in via `effort_request_field` see the value but
    /// drop it silently; this matches pi-mono's "providers carry their
    /// own quirks" stance and keeps the knob declarative.
    fn zagSetThinkingEffortFn(lua: *Lua) !i32 {
        _ = lua.getField(zlua.registry_index, "_zag_engine");
        const ptr = lua.toPointer(-1) catch {
            log.warn("zag.set_thinking_effort(): engine pointer not set (call storeSelfPointer first)", .{});
            return error.LuaError;
        };
        lua.pop(1);
        const engine: *LuaEngine = @ptrCast(@alignCast(@constCast(ptr)));

        // Nil clears the level; pass-through for users who want to
        // turn the knob off mid-session without restarting.
        if (lua.typeOf(1) == .nil or lua.typeOf(1) == .none) {
            if (engine.thinking_effort) |old| engine.allocator.free(old);
            engine.thinking_effort = null;
            return 0;
        }

        if (lua.typeOf(1) != .string) {
            log.warn("zag.set_thinking_effort(): arg 1 must be a string or nil", .{});
            return error.LuaError;
        }
        const level = lua.toString(1) catch {
            log.warn("zag.set_thinking_effort(): arg 1 must be a string or nil", .{});
            return error.LuaError;
        };
        _ = try requireOneOf(level, &[_][]const u8{ "minimal", "low", "medium", "high" }, "set_thinking_effort");

        const owned = try engine.allocator.dupe(u8, level);
        if (engine.thinking_effort) |old| engine.allocator.free(old);
        engine.thinking_effort = owned;
        return 0;
    }

    // -- Lua table reader helpers (used by zag.provider, future schema work) ---

    /// Required vs optional semantics for `readStringField`. Required mode
    /// raises on missing/nil; optional mode returns null.
    const FieldMode = enum { required, optional };

    /// Read a string field from the Lua table at `table_idx` and duplicate
    /// the value onto `allocator`. Returns `null` in optional mode when the
    /// field is absent or nil. Logs a descriptive warning and returns
    /// `error.LuaError` in required mode when the field is missing or when
    /// the value is present but not a string.
    ///
    /// Caller owns the returned memory. The stack is left untouched (the
    /// getField/pop happens inside).
    fn readStringField(
        lua: *Lua,
        table_idx: i32,
        name: [:0]const u8,
        mode: FieldMode,
        allocator: Allocator,
    ) !?[]const u8 {
        _ = lua.getField(table_idx, name);
        defer lua.pop(1);

        if (lua.isNil(-1)) {
            return switch (mode) {
                .optional => null,
                .required => blk: {
                    log.warn("zag.provider(): required string field '{s}' missing", .{name});
                    break :blk error.LuaError;
                },
            };
        }
        if (lua.typeOf(-1) != .string) {
            log.warn("zag.provider(): field '{s}' must be a string", .{name});
            return error.LuaError;
        }
        const borrowed = lua.toString(-1) catch {
            log.warn("zag.provider(): field '{s}' could not be read as a string", .{name});
            return error.LuaError;
        };
        return try allocator.dupe(u8, borrowed);
    }

    /// Read a Lua array-of-strings field at `name`. Absent or nil →
    /// empty slice. Each string is duped onto `allocator`. Caller owns
    /// the outer slice and each inner string. Errors when the field is
    /// present but not an array, or when any entry is not a string.
    /// Mirrors `readHeaderList`'s array branch but for a flat list.
    fn readStringArray(
        lua: *Lua,
        table_idx: i32,
        name: [:0]const u8,
        allocator: Allocator,
    ) ![][]const u8 {
        _ = lua.getField(table_idx, name);
        defer lua.pop(1);

        if (lua.isNil(-1)) return try allocator.alloc([]const u8, 0);
        if (!lua.isTable(-1)) {
            log.warn("zag.provider(): field '{s}' must be an array of strings", .{name});
            return error.LuaError;
        }

        const inner = lua.absIndex(-1);

        var items: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (items.items) |s| allocator.free(s);
            items.deinit(allocator);
        }

        const len = lua.rawLen(inner);
        for (0..len) |i| {
            _ = lua.rawGetIndex(inner, @intCast(i + 1));
            defer lua.pop(1);
            if (lua.typeOf(-1) != .string) {
                log.warn("zag.provider(): field '{s}' entry {d} must be a string", .{ name, i + 1 });
                return error.LuaError;
            }
            const borrowed = lua.toString(-1) catch {
                log.warn("zag.provider(): field '{s}' entry {d} could not be read", .{ name, i + 1 });
                return error.LuaError;
            };
            const owned = try allocator.dupe(u8, borrowed);
            errdefer allocator.free(owned);
            try items.append(allocator, owned);
        }

        return try items.toOwnedSlice(allocator);
    }

    /// Read a headers field from the Lua table at `table_idx`. Accepts two
    /// shapes:
    ///   (a) Array of pairs:   { { name = "x", value = "1" }, { name = "y", value = "2" } }
    ///   (b) Map of strings:   { ["x"] = "1", ["y"] = "2" }
    ///
    /// Returns an owned slice of `llm.Endpoint.Header`. An absent or nil
    /// field yields an empty slice. Order is preserved for form (a);
    /// iteration order for form (b) is Lua-implementation-defined, so
    /// callers that need deterministic order must use form (a).
    ///
    /// Each `.name` and `.value` is duped onto `allocator`. Caller owns
    /// both the outer slice and each duped string.
    fn readHeaderList(
        lua: *Lua,
        table_idx: i32,
        name: [:0]const u8,
        allocator: Allocator,
    ) ![]llm.Endpoint.Header {
        _ = lua.getField(table_idx, name);
        defer lua.pop(1);

        if (lua.isNil(-1)) return try allocator.alloc(llm.Endpoint.Header, 0);
        if (!lua.isTable(-1)) {
            log.warn("zag.provider(): field '{s}' must be a table (array or map)", .{name});
            return error.LuaError;
        }

        // Absolute index for the inner table so `pushNil`/`next` interleaving
        // and helper pushes don't invalidate relative offsets.
        const inner = lua.absIndex(-1);

        var headers: std.ArrayList(llm.Endpoint.Header) = .empty;
        errdefer {
            for (headers.items) |h| {
                allocator.free(h.name);
                allocator.free(h.value);
            }
            headers.deinit(allocator);
        }

        if (lua_json.isLuaArray(lua, inner)) {
            const len = lua.rawLen(inner);
            for (0..len) |i| {
                _ = lua.rawGetIndex(inner, @intCast(i + 1));
                defer lua.pop(1);
                if (!lua.isTable(-1)) {
                    log.warn("zag.provider(): field '{s}' entry {d} must be a table", .{ name, i + 1 });
                    return error.LuaError;
                }
                const header_name = (try readStringField(lua, -1, "name", .required, allocator)) orelse unreachable;
                errdefer allocator.free(header_name);
                const header_value = (try readStringField(lua, -1, "value", .required, allocator)) orelse unreachable;
                errdefer allocator.free(header_value);
                try headers.append(allocator, .{ .name = header_name, .value = header_value });
            }
        } else {
            // Map form: iterate with next() against the absolute inner index.
            lua.pushNil();
            while (lua.next(inner)) {
                // Stack: [..., inner_table, ..., key, value]
                if (lua.typeOf(-2) != .string) {
                    log.warn("zag.provider(): field '{s}' map keys must be strings", .{name});
                    lua.pop(2);
                    return error.LuaError;
                }
                if (lua.typeOf(-1) != .string) {
                    log.warn("zag.provider(): field '{s}' map values must be strings", .{name});
                    lua.pop(2);
                    return error.LuaError;
                }
                const k_borrowed = lua.toString(-2) catch {
                    lua.pop(2);
                    return error.LuaError;
                };
                const v_borrowed = lua.toString(-1) catch {
                    lua.pop(2);
                    return error.LuaError;
                };
                const k_owned = try allocator.dupe(u8, k_borrowed);
                errdefer allocator.free(k_owned);
                const v_owned = try allocator.dupe(u8, v_borrowed);
                errdefer allocator.free(v_owned);
                try headers.append(allocator, .{ .name = k_owned, .value = v_owned });
                lua.pop(1); // pop value; keep key for next iteration
            }
        }

        return try headers.toOwnedSlice(allocator);
    }

    /// Parse the closed `wire` enum surfaced by `zag.provider{}`. Returns
    /// `null` when the string doesn't match any known serializer.
    fn parseSerializer(s: []const u8) ?llm.Serializer {
        if (std.mem.eql(u8, s, "anthropic")) return .anthropic;
        if (std.mem.eql(u8, s, "openai")) return .openai;
        if (std.mem.eql(u8, s, "chatgpt")) return .chatgpt;
        return null;
    }

    /// Read the `auth = { kind = "...", ... }` subtable from the Lua table at
    /// `table_idx` and produce an `Endpoint.Auth` value.
    ///
    /// The OAuth arm reads every `OAuthSpec` field (issuer, token_url,
    /// client_id, scopes, redirect_port, optional account_id_claim_path,
    /// optional extra_authorize_params, and the nested `inject` subtable) and
    /// returns an `.oauth` variant carrying the spec. All strings / slices on
    /// the spec are freshly allocated on `allocator`; the caller passes
    /// ownership into `Registry.add`, which keeps the heap storage alive for
    /// the endpoint's lifetime and releases it via `Endpoint.free`.
    ///
    /// Requires that the `auth` key be present on the outer table; an absent
    /// or non-table value returns `error.LuaError` so users see a clear
    /// diagnostic at config-load time rather than a mysterious runtime error
    /// at the first turn.
    fn readAuth(
        lua: *Lua,
        table_idx: i32,
        allocator: Allocator,
    ) !llm.Endpoint.Auth {
        _ = lua.getField(table_idx, "auth");
        defer lua.pop(1);
        if (!lua.isTable(-1)) {
            log.warn("zag.provider(): 'auth' must be a table", .{});
            return error.LuaError;
        }

        const auth_idx = lua.absIndex(-1);

        const kind = (try readStringField(lua, auth_idx, "kind", .required, allocator)) orelse unreachable;
        defer allocator.free(kind);

        if (std.mem.eql(u8, kind, "x_api_key")) return .x_api_key;
        if (std.mem.eql(u8, kind, "bearer")) return .bearer;
        if (std.mem.eql(u8, kind, "none")) return .none;
        if (std.mem.eql(u8, kind, "oauth")) return readOAuthSpec(lua, auth_idx, allocator);

        log.warn("zag.provider(): unknown auth.kind '{s}' (expected x_api_key|bearer|oauth|none)", .{kind});
        return error.LuaError;
    }

    /// Materialise an `Endpoint.Auth.oauth` value from the Lua table at
    /// `auth_idx`. Every nested string / slice is owned by `allocator`; on any
    /// failure mid-parse, already-allocated pieces are freed via `errdefer`
    /// chains so the caller never sees a half-built spec.
    fn readOAuthSpec(
        lua: *Lua,
        auth_idx: i32,
        allocator: Allocator,
    ) !llm.Endpoint.Auth {
        const issuer = (try readStringField(lua, auth_idx, "issuer", .required, allocator)) orelse unreachable;
        errdefer allocator.free(issuer);
        const token_url = (try readStringField(lua, auth_idx, "token_url", .required, allocator)) orelse unreachable;
        errdefer allocator.free(token_url);
        const client_id = (try readStringField(lua, auth_idx, "client_id", .required, allocator)) orelse unreachable;
        errdefer allocator.free(client_id);
        const scopes = (try readStringField(lua, auth_idx, "scopes", .required, allocator)) orelse unreachable;
        errdefer allocator.free(scopes);

        // redirect_port: required integer (Lua numbers coerce to int).
        _ = lua.getField(auth_idx, "redirect_port");
        if (lua.isNil(-1)) {
            lua.pop(1);
            log.warn("zag.provider(): auth.redirect_port missing for oauth kind", .{});
            return error.LuaError;
        }
        const port_int = lua.toInteger(-1) catch {
            lua.pop(1);
            log.warn("zag.provider(): auth.redirect_port must be an integer", .{});
            return error.LuaError;
        };
        lua.pop(1);
        const redirect_port: u16 = std.math.cast(u16, port_int) orelse {
            log.warn("zag.provider(): auth.redirect_port {d} does not fit in u16", .{port_int});
            return error.LuaError;
        };

        // Optional: account_id_claim_path.
        const claim_path = try readStringField(lua, auth_idx, "account_id_claim_path", .optional, allocator);
        errdefer if (claim_path) |p| allocator.free(p);

        const extras = try readHeaderList(lua, auth_idx, "extra_authorize_params", allocator);
        errdefer {
            for (extras) |h| {
                allocator.free(h.name);
                allocator.free(h.value);
            }
            allocator.free(extras);
        }

        _ = lua.getField(auth_idx, "inject");
        defer lua.pop(1);
        if (!lua.isTable(-1)) {
            log.warn("zag.provider(): auth.inject must be a table for oauth kind", .{});
            return error.LuaError;
        }
        const inject_idx = lua.absIndex(-1);

        const inject_header = (try readStringField(lua, inject_idx, "header", .required, allocator)) orelse unreachable;
        errdefer allocator.free(inject_header);
        const inject_prefix = (try readStringField(lua, inject_idx, "prefix", .required, allocator)) orelse unreachable;
        errdefer allocator.free(inject_prefix);

        const inject_extras = try readHeaderList(lua, inject_idx, "extra_headers", allocator);
        errdefer {
            for (inject_extras) |h| {
                allocator.free(h.name);
                allocator.free(h.value);
            }
            allocator.free(inject_extras);
        }

        _ = lua.getField(inject_idx, "use_account_id");
        if (lua.typeOf(-1) != .boolean) {
            lua.pop(1);
            log.warn("zag.provider(): auth.inject.use_account_id must be a boolean", .{});
            return error.LuaError;
        }
        const use_account_id = lua.toBoolean(-1);
        lua.pop(1);

        const account_id_header = (try readStringField(lua, inject_idx, "account_id_header", .required, allocator)) orelse unreachable;
        errdefer allocator.free(account_id_header);

        return .{ .oauth = .{
            .issuer = issuer,
            .token_url = token_url,
            .client_id = client_id,
            .scopes = scopes,
            .redirect_port = redirect_port,
            .account_id_claim_path = claim_path,
            .extra_authorize_params = extras,
            .inject = .{
                .header = inject_header,
                .prefix = inject_prefix,
                .extra_headers = inject_extras,
                .use_account_id = use_account_id,
                .account_id_header = account_id_header,
            },
        } };
    }

    /// Read the `models = { ... }` array from the Lua table at `table_idx`.
    /// Absent or nil yields an empty slice. Each entry requires `id`; all
    /// numeric fields default to 0, and the cache rates are nullable
    /// (absent or nil → `null`; number → that value).
    ///
    /// Returns an owned slice of `Endpoint.ModelRate`. Each entry's `id`
    /// string is duped onto `allocator`; caller owns both the outer slice
    /// and each duped string.
    fn readModels(
        lua: *Lua,
        table_idx: i32,
        allocator: Allocator,
    ) ![]llm.Endpoint.ModelRate {
        _ = lua.getField(table_idx, "models");
        defer lua.pop(1);

        if (lua.isNil(-1)) return try allocator.alloc(llm.Endpoint.ModelRate, 0);
        if (!lua.isTable(-1)) {
            log.warn("zag.provider(): 'models' must be an array table", .{});
            return error.LuaError;
        }

        const inner = lua.absIndex(-1);
        const len = lua.rawLen(inner);

        var out: std.ArrayList(llm.Endpoint.ModelRate) = .empty;
        errdefer {
            for (out.items) |m| {
                if (m.label) |l| allocator.free(l);
                allocator.free(m.id);
            }
            out.deinit(allocator);
        }

        for (0..len) |i| {
            _ = lua.rawGetIndex(inner, @intCast(i + 1));
            defer lua.pop(1);
            if (!lua.isTable(-1)) {
                log.warn("zag.provider(): models[{d}] must be a table", .{i + 1});
                return error.LuaError;
            }
            const entry = lua.absIndex(-1);

            const id = (try readStringField(lua, entry, "id", .required, allocator)) orelse unreachable;
            errdefer allocator.free(id);

            const label = try readStringField(lua, entry, "label", .optional, allocator);
            errdefer if (label) |l| allocator.free(l);

            const recommended = (try readOptionalBool(lua, entry, "recommended")) orelse false;

            const context_window = try readOptionalInteger(lua, entry, "context_window", 0);
            const max_output_tokens = try readOptionalInteger(lua, entry, "max_output_tokens", 0);
            const input_per_mtok = try readOptionalFloat(lua, entry, "input_per_mtok", 0);
            const output_per_mtok = try readOptionalFloat(lua, entry, "output_per_mtok", 0);
            const cache_write = try readNullableFloat(lua, entry, "cache_write_per_mtok");
            const cache_read = try readNullableFloat(lua, entry, "cache_read_per_mtok");

            try out.append(allocator, .{
                .id = id,
                .label = label,
                .recommended = recommended,
                .context_window = @intCast(context_window),
                .max_output_tokens = @intCast(max_output_tokens),
                .input_per_mtok = input_per_mtok,
                .output_per_mtok = output_per_mtok,
                .cache_write_per_mtok = cache_write,
                .cache_read_per_mtok = cache_read,
            });
        }

        return try out.toOwnedSlice(allocator);
    }

    /// Read a boolean field with no default. Nil/absent yields `null` so the
    /// caller can distinguish "unset" from "explicitly false". Non-boolean
    /// values log and return `error.LuaError`.
    fn readOptionalBool(lua: *Lua, table_idx: i32, name: [:0]const u8) !?bool {
        _ = lua.getField(table_idx, name);
        defer lua.pop(1);
        if (lua.isNil(-1)) return null;
        if (lua.typeOf(-1) != .boolean) {
            log.warn("zag.provider(): field '{s}' must be a boolean", .{name});
            return error.LuaError;
        }
        return lua.toBoolean(-1);
    }

    /// Read an integer field with a default. Nil/absent → `default`. Non-number
    /// values log and return `error.LuaError`. Leaves the stack untouched.
    fn readOptionalInteger(lua: *Lua, table_idx: i32, name: [:0]const u8, default: i64) !i64 {
        _ = lua.getField(table_idx, name);
        defer lua.pop(1);
        if (lua.isNil(-1)) return default;
        if (lua.typeOf(-1) != .number) {
            log.warn("zag.provider(): field '{s}' must be a number", .{name});
            return error.LuaError;
        }
        return lua.toInteger(-1) catch {
            log.warn("zag.provider(): field '{s}' must be an integer", .{name});
            return error.LuaError;
        };
    }

    /// Read a float field with a default. Nil/absent → `default`. Non-number
    /// values log and return `error.LuaError`.
    fn readOptionalFloat(lua: *Lua, table_idx: i32, name: [:0]const u8, default: f64) !f64 {
        _ = lua.getField(table_idx, name);
        defer lua.pop(1);
        if (lua.isNil(-1)) return default;
        if (lua.typeOf(-1) != .number) {
            log.warn("zag.provider(): field '{s}' must be a number", .{name});
            return error.LuaError;
        }
        return lua.toNumber(-1) catch {
            log.warn("zag.provider(): field '{s}' must be numeric", .{name});
            return error.LuaError;
        };
    }

    /// Validate that `value` matches one of `allowed`. Returns `value` on
    /// success; logs and returns `error.LuaError` on mismatch. Used for the
    /// closed enum-like fields on `ReasoningConfig` so a typo in `config.lua`
    /// surfaces at config-load time rather than after the request fails.
    fn requireOneOf(value: []const u8, allowed: []const []const u8, field: [:0]const u8) ![]const u8 {
        for (allowed) |opt| {
            if (std.mem.eql(u8, value, opt)) return value;
        }
        // Build a comma-joined preview of the allowed set for the warning.
        // Bounded to a small stack buffer because the allowed lists are tiny
        // (3-4 short string literals).
        var preview_buf: [128]u8 = undefined;
        var written: usize = 0;
        for (allowed, 0..) |opt, i| {
            const sep_len: usize = if (i > 0) 1 else 0;
            if (written + sep_len + opt.len > preview_buf.len) break;
            if (sep_len == 1) {
                preview_buf[written] = ',';
                written += 1;
            }
            @memcpy(preview_buf[written..][0..opt.len], opt);
            written += opt.len;
        }
        log.warn("zag.provider(): field '{s}' got '{s}' (allowed: {s})", .{ field, value, preview_buf[0..written] });
        return error.LuaError;
    }

    /// Read the optional `reasoning_effort` / `reasoning_summary` /
    /// `verbosity` fields off the outer `zag.provider{...}` table and
    /// produce a fully-owned `Endpoint.ReasoningConfig`. Each absent
    /// field falls back to its `Endpoint.ReasoningConfig` default; the
    /// returned strings are always heap-allocated on `allocator` so
    /// `Endpoint.free` can release them uniformly regardless of whether
    /// the user customized any single field.
    fn readReasoningConfig(
        lua: *Lua,
        table_idx: i32,
        allocator: Allocator,
    ) !llm.Endpoint.ReasoningConfig {
        const effort_in = try readStringField(lua, table_idx, "reasoning_effort", .optional, allocator);
        errdefer if (effort_in) |s| allocator.free(s);
        if (effort_in) |s| {
            _ = try requireOneOf(s, &[_][]const u8{ "minimal", "low", "medium", "high" }, "reasoning_effort");
        }

        const summary_in = try readStringField(lua, table_idx, "reasoning_summary", .optional, allocator);
        errdefer if (summary_in) |s| allocator.free(s);
        if (summary_in) |s| {
            _ = try requireOneOf(s, &[_][]const u8{ "auto", "concise", "detailed", "none" }, "reasoning_summary");
        }

        const verbosity_in = try readStringField(lua, table_idx, "verbosity", .optional, allocator);
        errdefer if (verbosity_in) |s| allocator.free(s);
        if (verbosity_in) |s| {
            _ = try requireOneOf(s, &[_][]const u8{ "low", "medium", "high" }, "verbosity");
        }

        const defaults: llm.Endpoint.ReasoningConfig = .{};
        const effort = effort_in orelse try allocator.dupe(u8, defaults.effort);
        errdefer if (effort_in == null) allocator.free(effort);
        const summary = summary_in orelse try allocator.dupe(u8, defaults.summary);
        errdefer if (summary_in == null) allocator.free(summary);
        const verbosity = verbosity_in orelse try allocator.dupe(u8, defaults.verbosity);
        errdefer if (verbosity_in == null) allocator.free(verbosity);

        // Chat-completions reasoning round-trip. Both fields default to
        // unset (no response scrape, no echo) so existing endpoints
        // are byte-for-byte unchanged. Order matches the static
        // `defaults` field declaration in `Endpoint.ReasoningConfig`.
        const response_fields = try readStringArray(lua, table_idx, "reasoning_response_fields", allocator);
        errdefer {
            for (response_fields) |s| allocator.free(s);
            allocator.free(response_fields);
        }

        const echo_field = try readStringField(lua, table_idx, "reasoning_echo_field", .optional, allocator);
        errdefer if (echo_field) |s| allocator.free(s);

        const effort_request_field = try readStringField(lua, table_idx, "reasoning_effort_field", .optional, allocator);
        errdefer if (effort_request_field) |s| allocator.free(s);

        return .{
            .effort = effort,
            .summary = summary,
            .verbosity = verbosity,
            .response_fields = response_fields,
            .echo_field = echo_field,
            .effort_request_field = effort_request_field,
        };
    }

    /// Read a nullable float. Nil/absent → `null`. Number → that value.
    fn readNullableFloat(lua: *Lua, table_idx: i32, name: [:0]const u8) !?f64 {
        _ = lua.getField(table_idx, name);
        defer lua.pop(1);
        if (lua.isNil(-1)) return null;
        if (lua.typeOf(-1) != .number) {
            log.warn("zag.provider(): field '{s}' must be a number", .{name});
            return error.LuaError;
        }
        return lua.toNumber(-1) catch {
            log.warn("zag.provider(): field '{s}' must be numeric", .{name});
            return error.LuaError;
        };
    }

    /// Zig function backing `zag.provider{...}`. Reads the full endpoint
    /// schema from the Lua table (name, url, wire, auth, headers,
    /// default_model, models), constructs a fully-owned `Endpoint`, and
    /// upserts it into the engine's `providers_registry`. Lua declarations
    /// always win against builtins; if an entry with the same `name`
    /// already exists (builtin or prior Lua declaration) it is removed and
    /// replaced, so a full-schema declaration effectively overrides the
    /// builtin for that name.
    ///
    /// Any malformed input (missing required field, wrong type, unknown
    /// `wire`, unknown `auth.kind`, ...) logs a descriptive warning and
    /// returns `error.LuaError`, which `zlua.wrap` surfaces to the Lua VM
    /// as a runtime error. `doString` callers see `error.LuaRuntime`.
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
        const allocator = engine.allocator;

        const name = (try readStringField(lua, 1, "name", .required, allocator)) orelse unreachable;
        errdefer allocator.free(name);
        if (name.len == 0) {
            log.warn("zag.provider(): 'name' must not be empty", .{});
            return error.LuaError;
        }

        const url = (try readStringField(lua, 1, "url", .required, allocator)) orelse unreachable;
        errdefer allocator.free(url);

        const wire_str = (try readStringField(lua, 1, "wire", .required, allocator)) orelse unreachable;
        defer allocator.free(wire_str);
        const serializer = parseSerializer(wire_str) orelse {
            log.warn("zag.provider(): unknown wire '{s}' (expected anthropic|openai|chatgpt)", .{wire_str});
            return error.LuaError;
        };

        const default_model = (try readStringField(lua, 1, "default_model", .required, allocator)) orelse unreachable;
        errdefer allocator.free(default_model);

        const auth_val = try readAuth(lua, 1, allocator);
        errdefer switch (auth_val) {
            .oauth => |spec| llm.freeOAuthSpec(spec, allocator),
            else => {},
        };

        const headers = try readHeaderList(lua, 1, "headers", allocator);
        errdefer {
            for (headers) |h| {
                allocator.free(h.name);
                allocator.free(h.value);
            }
            allocator.free(headers);
        }

        const models = try readModels(lua, 1, allocator);
        errdefer {
            for (models) |m| allocator.free(m.id);
            allocator.free(models);
        }

        const reasoning = try readReasoningConfig(lua, 1, allocator);
        errdefer {
            allocator.free(reasoning.effort);
            allocator.free(reasoning.summary);
            allocator.free(reasoning.verbosity);
        }

        const ep: llm.Endpoint = .{
            .name = name,
            .serializer = serializer,
            .url = url,
            .auth = auth_val,
            .headers = headers,
            .default_model = default_model,
            .models = models,
            .reasoning = reasoning,
        };

        // Override-on-conflict: remove any prior entry (builtin or earlier
        // Lua declaration) so a full-schema declaration always wins. The
        // subsequent `add` then cannot trip `DuplicateEndpoint`.
        _ = engine.providers_registry.remove(ep.name);
        engine.providers_registry.add(ep) catch |err| switch (err) {
            error.DuplicateEndpoint => unreachable,
            else => |e| return e,
        };
        return 0;
    }

    /// Zig function backing `zag.subagent.register{name, description,
    /// prompt, model?, tools?}`. Reads the table, validates shapes via
    /// `SubagentRegistry.register`, and surfaces any validation or
    /// allocation failure as a Lua error. On success returns 0 values.
    ///
    /// Strings are read with `toString`, which hands back a borrowed
    /// slice into Lua-owned memory; the registry dupes every string into
    /// its own allocator before returning, so no Lua lifetime leaks past
    /// this frame.
    fn zagSubagentRegisterFn(lua: *Lua) i32 {
        const engine = getEngineFromState(lua);

        if (!lua.isTable(1)) {
            lua.raiseErrorStr("zag.subagent.register: arg 1 must be a table", .{});
        }

        const name = requireSubagentString(lua, 1, "name");
        const description = requireSubagentString(lua, 1, "description");
        const prompt_text = requireSubagentString(lua, 1, "prompt");
        const model = optionalSubagentString(lua, 1, "model");

        // Tools list is optional. Read into a transient slice of borrowed
        // Lua strings; the registry dupes each entry before we return.
        // Cap at 128 entries to keep the stack buffer bounded and the
        // error path simple. In practice subagent tool allowlists are
        // single-digit.
        var tools_buf: [128][]const u8 = undefined;
        var tools_slice: ?[]const []const u8 = null;
        _ = lua.getField(1, "tools");
        defer lua.pop(1);
        if (!lua.isNil(-1)) {
            if (!lua.isTable(-1)) {
                lua.raiseErrorStr("zag.subagent.register: 'tools' must be a table of strings", .{});
            }
            const tools_idx = lua.absIndex(-1);
            const tools_len = lua.rawLen(tools_idx);
            if (tools_len > tools_buf.len) {
                lua.raiseErrorStr("zag.subagent.register: 'tools' array too large (max 128)", .{});
            }
            for (0..tools_len) |i| {
                _ = lua.rawGetIndex(tools_idx, @intCast(i + 1));
                defer lua.pop(1);
                if (lua.typeOf(-1) != .string) {
                    lua.raiseErrorStr("zag.subagent.register: 'tools' entries must be strings", .{});
                }
                const entry = lua.toString(-1) catch {
                    lua.raiseErrorStr("zag.subagent.register: 'tools' entry could not be read", .{});
                };
                tools_buf[i] = entry;
            }
            tools_slice = tools_buf[0..tools_len];
        }

        const sa: subagents_mod.Subagent = .{
            .name = name,
            .description = description,
            .prompt = prompt_text,
            .model = model,
            .tools = tools_slice,
        };

        engine.subagents.register(engine.allocator, sa) catch |err| {
            var buf: [256]u8 = undefined;
            const msg = switch (err) {
                error.InvalidName => std.fmt.bufPrintZ(
                    &buf,
                    "zag.subagent.register: invalid name '{s}' (expected [a-z0-9-]+, 1-64 chars, no leading/trailing/double hyphen)",
                    .{name},
                ) catch "zag.subagent.register: invalid name",
                error.InvalidDescription => std.fmt.bufPrintZ(
                    &buf,
                    "zag.subagent.register: invalid description for '{s}' (must be 1-1024 bytes)",
                    .{name},
                ) catch "zag.subagent.register: invalid description",
                error.DuplicateName => std.fmt.bufPrintZ(
                    &buf,
                    "zag.subagent.register: duplicate name '{s}'",
                    .{name},
                ) catch "zag.subagent.register: duplicate name",
                error.OutOfMemory => std.fmt.bufPrintZ(
                    &buf,
                    "zag.subagent.register: out of memory",
                    .{},
                ) catch "zag.subagent.register: out of memory",
            };
            lua.raiseErrorStr("%s", .{msg.ptr});
        };

        return 0;
    }

    /// Read a required string field off the table at `table_idx`. Raises
    /// a Lua error if the field is missing or of the wrong type. Returns
    /// a borrowed slice into Lua-owned memory; callers must consume it
    /// synchronously (e.g., hand it to `SubagentRegistry.register`, which
    /// dupes immediately).
    fn requireSubagentString(lua: *Lua, table_idx: i32, comptime name: [:0]const u8) []const u8 {
        _ = lua.getField(table_idx, name);
        if (lua.isNil(-1)) {
            lua.raiseErrorStr("zag.subagent.register: required field '" ++ name ++ "' missing", .{});
        }
        if (lua.typeOf(-1) != .string) {
            lua.raiseErrorStr("zag.subagent.register: field '" ++ name ++ "' must be a string", .{});
        }
        const s = lua.toString(-1) catch {
            lua.raiseErrorStr("zag.subagent.register: field '" ++ name ++ "' could not be read", .{});
        };
        // Intentionally keep the string on the stack so the borrowed
        // slice stays valid until the enclosing frame returns. Lua
        // tears the stack down when the C function returns anyway.
        return s;
    }

    /// Read an optional string field off the table at `table_idx`.
    /// Returns null if the field is absent or nil; raises a Lua error
    /// if present but wrong type. Borrowed from Lua memory, same
    /// lifetime rules as `requireSubagentString`.
    fn optionalSubagentString(lua: *Lua, table_idx: i32, comptime name: [:0]const u8) ?[]const u8 {
        _ = lua.getField(table_idx, name);
        if (lua.isNil(-1)) {
            lua.pop(1);
            return null;
        }
        if (lua.typeOf(-1) != .string) {
            lua.raiseErrorStr("zag.subagent.register: field '" ++ name ++ "' must be a string", .{});
        }
        const s = lua.toString(-1) catch {
            lua.raiseErrorStr("zag.subagent.register: field '" ++ name ++ "' could not be read", .{});
        };
        return s;
    }

    // -- zag.prompt ------------------------------------------------------------

    /// Thread-local engine handle consulted by `renderLuaLayer`. Set by
    /// `renderPromptLayers` around `Registry.render` so the thunk can
    /// find the Lua state that owns a layer's `lua_ref`. Thread-local
    /// (rather than a module global) so concurrent tests and subagents
    /// don't step on each other.
    threadlocal var active_render_engine: ?*LuaEngine = null;

    /// Zig function backing `zag.prompt.layer{name, priority, cache_class, render}`.
    ///
    /// Fields:
    /// - `name` (string, required): stable layer identifier.
    /// - `priority` (int, optional, default 500): lower runs first. Built-ins
    ///   sit at 5 / 50 / 100 / 910; pick spaces between them to slot in.
    /// - `cache_class` (string, optional, default "volatile"): either
    ///   "stable" (lands in the cache-prefix half) or "volatile" (lands
    ///   in the churn tail).
    /// - `render` (function, required): called per turn with a context
    ///   table. Return a string to contribute, or nil to opt out.
    ///
    /// The context table exposes the borrowed `LayerContext` fields that
    /// carry plain strings today: `model` (provider/id strings),
    /// `agent_name`, `cwd`, `worktree`, `date_iso`, `is_git_repo`,
    /// `platform`. `tools` is a sequence of `{name, description}` pairs;
    /// `skills` appears as a list of names derived from the live
    /// `SkillRegistry`. Each render call rebuilds the table so layer
    /// code never aliases Zig-side storage past its own return.
    fn zagPromptLayerFn(lua: *Lua) i32 {
        const engine = getEngineFromState(lua);

        if (!lua.isTable(1)) {
            lua.raiseErrorStr("zag.prompt.layer: arg 1 must be a table", .{});
        }

        // name (required string).
        _ = lua.getField(1, "name");
        if (lua.isNil(-1)) {
            lua.raiseErrorStr("zag.prompt.layer: required field 'name' missing", .{});
        }
        if (lua.typeOf(-1) != .string) {
            lua.raiseErrorStr("zag.prompt.layer: field 'name' must be a string", .{});
        }
        const name_raw = lua.toString(-1) catch {
            lua.raiseErrorStr("zag.prompt.layer: field 'name' could not be read", .{});
        };
        lua.pop(1);

        // priority (optional int, default 500).
        var priority: i32 = 500;
        _ = lua.getField(1, "priority");
        if (!lua.isNil(-1)) {
            if (!lua.isInteger(-1)) {
                lua.raiseErrorStr("zag.prompt.layer: field 'priority' must be an integer", .{});
            }
            const p = lua.toInteger(-1) catch {
                lua.raiseErrorStr("zag.prompt.layer: field 'priority' could not be read", .{});
            };
            priority = std.math.cast(i32, p) orelse {
                lua.raiseErrorStr("zag.prompt.layer: field 'priority' out of range", .{});
            };
        }
        lua.pop(1);

        // cache_class (optional string, default "volatile").
        var cache_class: prompt.CacheClass = .@"volatile";
        _ = lua.getField(1, "cache_class");
        if (!lua.isNil(-1)) {
            if (lua.typeOf(-1) != .string) {
                lua.raiseErrorStr("zag.prompt.layer: field 'cache_class' must be a string", .{});
            }
            const cc = lua.toString(-1) catch {
                lua.raiseErrorStr("zag.prompt.layer: field 'cache_class' could not be read", .{});
            };
            if (std.mem.eql(u8, cc, "stable")) {
                cache_class = .stable;
            } else if (std.mem.eql(u8, cc, "volatile")) {
                cache_class = .@"volatile";
            } else {
                lua.raiseErrorStr("zag.prompt.layer: field 'cache_class' must be 'stable' or 'volatile'", .{});
            }
        }
        lua.pop(1);

        // render (required function). Push and ref; on any error after
        // this we must unref the slot.
        _ = lua.getField(1, "render");
        if (lua.isNil(-1)) {
            lua.raiseErrorStr("zag.prompt.layer: required field 'render' missing", .{});
        }
        if (!lua.isFunction(-1)) {
            lua.raiseErrorStr("zag.prompt.layer: field 'render' must be a function", .{});
        }
        const fn_ref = lua.ref(zlua.registry_index) catch {
            lua.raiseErrorStr("zag.prompt.layer: failed to ref render function", .{});
        };

        // Dupe the name so it outlives this Lua frame. Track it on the
        // engine's `prompt_layer_names` for a clean free on deinit.
        const name_owned = engine.allocator.dupe(u8, name_raw) catch {
            lua.unref(zlua.registry_index, fn_ref);
            lua.raiseErrorStr("zag.prompt.layer: out of memory duping name", .{});
        };

        engine.prompt_layer_names.append(engine.allocator, name_owned) catch {
            engine.allocator.free(name_owned);
            lua.unref(zlua.registry_index, fn_ref);
            lua.raiseErrorStr("zag.prompt.layer: out of memory tracking layer name", .{});
        };

        engine.prompt_registry.add(engine.allocator, .{
            .name = name_owned,
            .priority = priority,
            .cache_class = cache_class,
            .source = .lua,
            .render_fn = renderLuaLayer,
            .lua_ref = fn_ref,
        }) catch |err| {
            // Roll back the name tracking and ref before surfacing.
            _ = engine.prompt_layer_names.pop();
            engine.allocator.free(name_owned);
            lua.unref(zlua.registry_index, fn_ref);
            switch (err) {
                error.StableFrozen => lua.raiseErrorStr(
                    "zag.prompt.layer: cannot register a 'stable' layer after the first render. Use cache_class = \"volatile\" instead, or register before the first turn renders.",
                    .{},
                ),
                error.OutOfMemory => lua.raiseErrorStr(
                    "zag.prompt.layer: out of memory appending layer",
                    .{},
                ),
            }
        };

        return 0;
    }

    /// Render thunk used by every Lua-registered layer. Looks up the
    /// engine via the thread-local `active_render_engine` set by
    /// `renderPromptLayers`, pushes a context table onto the Lua stack,
    /// and invokes the ref stored on the layer. Returns an owned slice
    /// allocated with `alloc`, or null when the Lua function returns
    /// nil. Render errors are logged and swallowed (null return) so a
    /// single buggy layer cannot crash the assembled prompt.
    ///
    /// Runs on the main thread. Lua is not safe to call from the agent
    /// worker thread, so `agent.runLoopStreaming` marshals assembly
    /// through a `prompt_assembly_request` event serviced by
    /// `AgentRunner.dispatchHookRequests` (mirroring `lua_tool_request`).
    /// Callers that already hold the main thread (tests, headless
    /// preview, first-run wizard) invoke `renderPromptLayers` directly.
    fn renderLuaLayer(ctx: *const prompt.LayerContext, alloc: Allocator) anyerror!?[]const u8 {
        const engine = active_render_engine orelse {
            log.warn("prompt layer render: no active engine bound", .{});
            return null;
        };
        const layer = active_render_layer orelse {
            log.warn("prompt layer render: no active layer bound", .{});
            return null;
        };
        const fn_ref = layer.lua_ref orelse {
            log.warn("prompt layer render: layer '{s}' missing lua_ref", .{layer.name});
            return null;
        };

        const lua = engine.lua;

        _ = lua.rawGetIndex(zlua.registry_index, fn_ref);
        if (!lua.isFunction(-1)) {
            lua.pop(1);
            log.warn("prompt layer '{s}': registry slot is not a function", .{layer.name});
            return null;
        }
        pushLayerContextTable(lua, ctx);

        lua.protectedCall(.{ .args = 1, .results = 1 }) catch {
            const err_msg = lua.toString(-1) catch "<unprintable>";
            log.warn("prompt layer '{s}' raised: {s}", .{ layer.name, err_msg });
            lua.pop(1);
            return null;
        };
        defer lua.pop(1);

        if (lua.isNil(-1)) return null;
        if (lua.typeOf(-1) != .string) {
            log.warn("prompt layer '{s}' returned non-string (type {s})", .{ layer.name, @tagName(lua.typeOf(-1)) });
            return null;
        }
        const out = lua.toString(-1) catch {
            log.warn("prompt layer '{s}' return value could not be read", .{layer.name});
            return null;
        };
        return try alloc.dupe(u8, out);
    }

    /// Zig function backing `zag.prompt.for_model(pattern, text_or_fn)`.
    ///
    /// Shorthand for a stable-class layer whose render hook checks the
    /// current `ctx.model_id` against `pattern` before emitting anything.
    /// Pattern matching is plain substring when `pattern` contains no
    /// Lua magic characters (detected as the `%` escape), else it is
    /// routed through `string.match` so full Lua pattern syntax works.
    ///
    /// Args:
    /// - arg 1 (string, required): model-id pattern.
    /// - arg 2 (string|function, required): either a literal system-prompt
    ///   snippet or a `function(ctx) -> string|nil` called on a match.
    ///
    /// The layer is registered with `priority = 0` (runs before built-in
    /// identity at 5) and `cache_class = .stable` so matched output lands
    /// in the cache-friendly prefix. Per-match storage lives in a Lua
    /// table ref `{pattern, body, has_pct}`; garbage collection anchors
    /// the `body` function (or string) to the table for us.
    fn zagPromptForModelFn(lua: *Lua) i32 {
        const engine = getEngineFromState(lua);

        // arg 1: pattern string.
        if (lua.typeOf(1) != .string) {
            lua.raiseErrorStr("zag.prompt.for_model: arg 1 must be a string pattern", .{});
        }
        const pattern_raw = lua.toString(1) catch {
            lua.raiseErrorStr("zag.prompt.for_model: arg 1 could not be read", .{});
        };
        if (pattern_raw.len == 0) {
            lua.raiseErrorStr("zag.prompt.for_model: pattern must not be empty", .{});
        }

        // arg 2: string body or function body.
        const body_type = lua.typeOf(2);
        if (body_type != .string and body_type != .function) {
            lua.raiseErrorStr(
                "zag.prompt.for_model: arg 2 must be a string or function",
                .{},
            );
        }

        // Detect Lua pattern magic. Any `%` means the caller wants
        // Lua-pattern semantics; otherwise take the cheap substring
        // path that needs no Lua round-trip per render.
        const has_pct = std.mem.indexOfScalar(u8, pattern_raw, '%') != null;

        // Build the side-table that holds the captured state. The table
        // becomes the layer's `lua_ref`; `renderLuaForModelLayer` unpacks
        // its fields on every render.
        lua.newTable();
        _ = lua.pushString(pattern_raw);
        lua.setField(-2, "pattern");
        lua.pushBoolean(has_pct);
        lua.setField(-2, "has_pct");
        lua.pushValue(2); // duplicate body (string or function) onto top
        lua.setField(-2, "body");

        const table_ref = lua.ref(zlua.registry_index) catch {
            lua.raiseErrorStr("zag.prompt.for_model: failed to ref state table", .{});
        };

        // Synthesize a stable name so diagnostics can tell these apart
        // from plain `zag.prompt.layer` entries. The dupe is tracked by
        // `prompt_layer_names` for deinit symmetry with other Lua layers.
        var name_buf: [512]u8 = undefined;
        const synth_name = std.fmt.bufPrint(
            &name_buf,
            "lua.for_model:{s}",
            .{pattern_raw},
        ) catch blk: {
            // Pattern longer than 512 - name_prefix: fall back to a
            // fixed label rather than raising. Names do not affect
            // rendering, only logs.
            break :blk "lua.for_model:<long-pattern>";
        };
        const name_owned = engine.allocator.dupe(u8, synth_name) catch {
            lua.unref(zlua.registry_index, table_ref);
            lua.raiseErrorStr("zag.prompt.for_model: out of memory duping name", .{});
        };

        engine.prompt_layer_names.append(engine.allocator, name_owned) catch {
            engine.allocator.free(name_owned);
            lua.unref(zlua.registry_index, table_ref);
            lua.raiseErrorStr("zag.prompt.for_model: out of memory tracking layer name", .{});
        };

        engine.prompt_registry.add(engine.allocator, .{
            .name = name_owned,
            .priority = 0,
            .cache_class = .stable,
            .source = .lua,
            .render_fn = renderLuaForModelLayer,
            .lua_ref = table_ref,
        }) catch |err| {
            _ = engine.prompt_layer_names.pop();
            engine.allocator.free(name_owned);
            lua.unref(zlua.registry_index, table_ref);
            switch (err) {
                error.StableFrozen => lua.raiseErrorStr(
                    "zag.prompt.for_model: cannot register after the first render",
                    .{},
                ),
                error.OutOfMemory => lua.raiseErrorStr(
                    "zag.prompt.for_model: out of memory appending layer",
                    .{},
                ),
            }
        };

        return 0;
    }

    /// Render thunk for layers registered via `zag.prompt.for_model`.
    /// Unpacks the side-table ref stashed on the layer, evaluates the
    /// pattern against `ctx.model_id`, and returns the body's text on
    /// a match. A render-time match (not a registration-time one) keeps
    /// packs portable across model switches made via `zag.current_model`.
    fn renderLuaForModelLayer(ctx: *const prompt.LayerContext, alloc: Allocator) anyerror!?[]const u8 {
        const engine = active_render_engine orelse {
            log.warn("prompt for_model render: no active engine bound", .{});
            return null;
        };
        const layer = active_render_layer orelse {
            log.warn("prompt for_model render: no active layer bound", .{});
            return null;
        };
        const table_ref = layer.lua_ref orelse {
            log.warn("prompt for_model render: layer '{s}' missing lua_ref", .{layer.name});
            return null;
        };

        const lua = engine.lua;

        // Fetch the side-table onto the stack once; both pattern and body
        // are reached via getField on this value.
        _ = lua.rawGetIndex(zlua.registry_index, table_ref);
        if (!lua.isTable(-1)) {
            lua.pop(1);
            log.warn("prompt for_model '{s}': ref is not a table", .{layer.name});
            return null;
        }
        defer lua.pop(1);

        // pattern (string).
        _ = lua.getField(-1, "pattern");
        if (lua.typeOf(-1) != .string) {
            lua.pop(1);
            log.warn("prompt for_model '{s}': pattern field missing", .{layer.name});
            return null;
        }
        const pattern = lua.toString(-1) catch {
            lua.pop(1);
            log.warn("prompt for_model '{s}': pattern not readable", .{layer.name});
            return null;
        };
        lua.pop(1);

        // has_pct (bool).
        _ = lua.getField(-1, "has_pct");
        const has_pct = lua.toBoolean(-1);
        lua.pop(1);

        // Match against the concrete model_id (not the joined
        // provider/model_id). Callers pattern on model id because the
        // provider is carried separately in most packs.
        const model_id = ctx.model.model_id;

        const matched = if (has_pct)
            try luaPatternMatch(lua, model_id, pattern)
        else
            std.mem.indexOf(u8, model_id, pattern) != null;

        if (!matched) return null;

        // body (string | function). Each arm owns the pop of the value
        // it pushed onto the stack. `protectedCall` replaces the function
        // slot with its result, so the function arm pops once for both.
        _ = lua.getField(-1, "body");

        switch (lua.typeOf(-1)) {
            .string => {
                defer lua.pop(1);
                const text = lua.toString(-1) catch {
                    log.warn("prompt for_model '{s}': body string not readable", .{layer.name});
                    return null;
                };
                return try alloc.dupe(u8, text);
            },
            .function => {
                pushLayerContextTable(lua, ctx);
                lua.protectedCall(.{ .args = 1, .results = 1 }) catch {
                    const err_msg = lua.toString(-1) catch "<unprintable>";
                    log.warn("prompt for_model '{s}' raised: {s}", .{ layer.name, err_msg });
                    lua.pop(1);
                    return null;
                };
                defer lua.pop(1);

                if (lua.isNil(-1)) return null;
                if (lua.typeOf(-1) != .string) {
                    log.warn(
                        "prompt for_model '{s}' returned non-string (type {s})",
                        .{ layer.name, @tagName(lua.typeOf(-1)) },
                    );
                    return null;
                }
                const out = lua.toString(-1) catch {
                    log.warn("prompt for_model '{s}' return value not readable", .{layer.name});
                    return null;
                };
                return try alloc.dupe(u8, out);
            },
            else => {
                defer lua.pop(1);
                log.warn(
                    "prompt for_model '{s}': body has unexpected type {s}",
                    .{ layer.name, @tagName(lua.typeOf(-1)) },
                );
                return null;
            },
        }
    }

    /// Evaluate `string.match(subject, pattern)` and return whether it
    /// produced at least one non-nil capture. Leaves the stack as it
    /// found it. Any failure (missing stdlib, match error) is logged
    /// and treated as "no match" so a bad pattern cannot take down the
    /// prompt assembly.
    fn luaPatternMatch(lua: *Lua, subject: []const u8, pattern: []const u8) !bool {
        const top = lua.getTop();
        defer lua.setTop(top);

        if (lua.getGlobal("string") catch .nil != .table) return false;
        _ = lua.getField(-1, "match");
        if (!lua.isFunction(-1)) return false;
        _ = lua.pushString(subject);
        _ = lua.pushString(pattern);
        lua.protectedCall(.{ .args = 2, .results = 1 }) catch {
            const err_msg = lua.toString(-1) catch "<unprintable>";
            log.warn("prompt for_model: string.match error: {s}", .{err_msg});
            return false;
        };
        return !lua.isNil(-1);
    }

    // -- zag.context ----------------------------------------------------------

    /// Hard cap on how many filenames a single `find_up` call may probe.
    /// The walk runs once per turn through every Lua prompt layer that
    /// uses it; this guards against a config that accidentally hands in
    /// hundreds of patterns and turns each render into a stat storm.
    const find_up_max_names: usize = 16;

    /// Zig function backing `zag.context.find_up(names, opts)`.
    ///
    /// Args:
    /// - arg 1: filename to probe, or array of filenames in priority order.
    ///   Strings only; numeric or non-string entries trigger a Lua error.
    /// - arg 2: `{ from = "<absolute cwd>", to = "<absolute worktree>" }`.
    ///   Both fields required; the walk stops at `to` (inclusive).
    ///
    /// Returns either `nil` (no match) or `{ path = "...", content = "..." }`.
    /// Mirrors `Instruction.findUpWith` so all walk-up file lookups share
    /// one implementation, including the 64 KiB content cap and the
    /// silent-skip semantics for unreadable or oversized files.
    fn zagContextFindUpFn(lua: *Lua) i32 {
        const engine = getEngineFromState(lua);

        // Collect names. Accept either a single string or a sequence-style
        // table of strings. Build a stack-bounded slice we hand to the
        // Zig walk; everything in `names_buf` borrows Lua-side storage,
        // valid for the duration of this call.
        var names_buf: [find_up_max_names][]const u8 = undefined;
        const names_count = collectFindUpNames(lua, 1, &names_buf);

        // Options table: { from = ..., to = ... }.
        if (!lua.isTable(2)) {
            lua.raiseErrorStr("zag.context.find_up: arg 2 must be a table {from=..., to=...}", .{});
        }

        _ = lua.getField(2, "from");
        if (lua.typeOf(-1) != .string) {
            lua.raiseErrorStr("zag.context.find_up: opts.from must be a string", .{});
        }
        const from = lua.toString(-1) catch {
            lua.raiseErrorStr("zag.context.find_up: opts.from could not be read", .{});
        };
        lua.pop(1);

        _ = lua.getField(2, "to");
        if (lua.typeOf(-1) != .string) {
            lua.raiseErrorStr("zag.context.find_up: opts.to must be a string", .{});
        }
        const to = lua.toString(-1) catch {
            lua.raiseErrorStr("zag.context.find_up: opts.to could not be read", .{});
        };
        lua.pop(1);

        const names = names_buf[0..names_count];
        const result = Instruction.findUpWith(from, to, names, engine.allocator) catch |err| {
            var buf: [128]u8 = undefined;
            const msg = std.fmt.bufPrintZ(
                &buf,
                "zag.context.find_up: walk failed: {s}",
                .{@errorName(err)},
            ) catch "zag.context.find_up: walk failed";
            lua.raiseErrorStr("%s", .{msg.ptr});
        };

        const found = result orelse {
            lua.pushNil();
            return 1;
        };
        defer found.deinit(engine.allocator);

        lua.newTable();
        _ = lua.pushString(found.path);
        lua.setField(-2, "path");
        _ = lua.pushString(found.content);
        lua.setField(-2, "content");
        return 1;
    }

    /// Read the names argument for `zag.context.find_up`. Returns the count
    /// of names written into `out`. Raises a Lua error on bad shape; the
    /// caller never sees a partial fill.
    fn collectFindUpNames(lua: *Lua, arg_index: i32, out: *[find_up_max_names][]const u8) usize {
        const t = lua.typeOf(arg_index);
        if (t == .string) {
            const s = lua.toString(arg_index) catch {
                lua.raiseErrorStr("zag.context.find_up: arg 1 could not be read", .{});
            };
            if (s.len == 0) {
                lua.raiseErrorStr("zag.context.find_up: arg 1 must not be empty", .{});
            }
            out[0] = s;
            return 1;
        }
        if (t != .table) {
            lua.raiseErrorStr("zag.context.find_up: arg 1 must be a string or array of strings", .{});
        }

        const len_i64 = lua.rawLen(arg_index);
        const len: usize = @intCast(len_i64);
        if (len == 0) {
            lua.raiseErrorStr("zag.context.find_up: arg 1 array must not be empty", .{});
        }
        if (len > find_up_max_names) {
            lua.raiseErrorStr("zag.context.find_up: arg 1 has too many entries", .{});
        }

        var i: usize = 0;
        while (i < len) : (i += 1) {
            _ = lua.rawGetIndex(arg_index, @intCast(i + 1));
            if (lua.typeOf(-1) != .string) {
                lua.raiseErrorStr("zag.context.find_up: arg 1 entries must be strings", .{});
            }
            const s = lua.toString(-1) catch {
                lua.raiseErrorStr("zag.context.find_up: arg 1 entry could not be read", .{});
            };
            if (s.len == 0) {
                lua.raiseErrorStr("zag.context.find_up: arg 1 entries must not be empty", .{});
            }
            out[i] = s;
            lua.pop(1);
        }
        return len;
    }

    /// Zig function backing `zag.context.on_tool_result(tool_name, fn)`.
    ///
    /// Registers a Lua handler that the harness invokes after every
    /// completed call to the tool with the matching name. The handler
    /// runs on the main thread (Lua is pinned there); the agent worker
    /// marshals through a `jit_context_request` event so the handler can
    /// see the tool's input/output and return a string to attach under
    /// the result.
    ///
    /// Args:
    /// - arg 1 (string, required, non-empty): tool name to match.
    /// - arg 2 (function, required): handler `fn(ctx) -> string|nil`.
    ///
    /// Re-registering an existing tool name unrefs the previous function
    /// before stashing the new one; the owned name slice is reused so the
    /// hashmap key stays stable.
    fn zagContextOnToolResultFn(lua: *Lua) i32 {
        const engine = getEngineFromState(lua);

        if (lua.typeOf(1) != .string) {
            lua.raiseErrorStr(
                "zag.context.on_tool_result: arg 1 must be a string tool name",
                .{},
            );
        }
        const tool_name = lua.toString(1) catch {
            lua.raiseErrorStr(
                "zag.context.on_tool_result: arg 1 could not be read",
                .{},
            );
        };
        if (tool_name.len == 0) {
            lua.raiseErrorStr(
                "zag.context.on_tool_result: arg 1 must not be empty",
                .{},
            );
        }

        if (!lua.isFunction(2)) {
            lua.raiseErrorStr(
                "zag.context.on_tool_result: arg 2 must be a function",
                .{},
            );
        }

        // ref() pops the value at top-of-stack. Push a copy of arg 2 so
        // the original argument frame stays well-formed.
        lua.pushValue(2);
        const fn_ref = lua.ref(zlua.registry_index) catch {
            lua.raiseErrorStr(
                "zag.context.on_tool_result: failed to ref handler",
                .{},
            );
        };
        errdefer lua.unref(zlua.registry_index, fn_ref);

        // Re-registration: unref the old fn but keep the existing owned
        // name slice (the map key aliases it, so freeing would dangle the
        // bucket key). Just swap the value in place.
        if (engine.jit_context_handlers.getPtr(tool_name)) |existing| {
            lua.unref(zlua.registry_index, existing.fn_ref);
            existing.fn_ref = fn_ref;
            return 0;
        }

        const owned_name = engine.allocator.dupe(u8, tool_name) catch {
            lua.unref(zlua.registry_index, fn_ref);
            lua.raiseErrorStr(
                "zag.context.on_tool_result: out of memory duping tool name",
                .{},
            );
        };
        errdefer engine.allocator.free(owned_name);

        engine.jit_context_handlers.put(engine.allocator, owned_name, .{
            .tool_name = owned_name,
            .fn_ref = fn_ref,
        }) catch {
            lua.unref(zlua.registry_index, fn_ref);
            engine.allocator.free(owned_name);
            lua.raiseErrorStr(
                "zag.context.on_tool_result: out of memory inserting handler",
                .{},
            );
        };

        return 0;
    }

    /// Run the JIT context handler for `req.tool_name` on the main thread.
    /// Builds a Lua-side context table, calls the registered function via
    /// `protectedCall`, and dupes the returned string into `req.allocator`
    /// (success path). When no handler is registered the request returns
    /// with `result = null` and `error_name = null` so the worker proceeds
    /// without an attachment. Lua-side errors set `error_name` and leave
    /// `result` null. Caller is responsible for `req.done.set()`.
    pub fn handleJitContextRequest(
        self: *LuaEngine,
        req: *agent_events.JitContextRequest,
    ) anyerror!void {
        const handler = self.jit_context_handlers.get(req.tool_name) orelse return;

        const lua = self.lua;
        _ = lua.rawGetIndex(zlua.registry_index, handler.fn_ref);
        if (!lua.isFunction(-1)) {
            lua.pop(1);
            log.warn(
                "jit context handler for '{s}': registry slot is not a function",
                .{req.tool_name},
            );
            return;
        }

        // Build the context table the handler sees. Strings are copied
        // into Lua-managed memory by `pushString`, so the borrowed
        // `req.input/output` slices do not need to outlive this call.
        lua.newTable();
        _ = lua.pushString(req.tool_name);
        lua.setField(-2, "tool");
        _ = lua.pushString(req.input);
        lua.setField(-2, "input");
        _ = lua.pushString(req.output);
        lua.setField(-2, "output");
        lua.pushBoolean(req.is_error);
        lua.setField(-2, "is_error");

        lua.protectedCall(.{ .args = 1, .results = 1 }) catch {
            const err_msg = lua.toString(-1) catch "<unprintable>";
            log.warn(
                "jit context handler for '{s}' raised: {s}",
                .{ req.tool_name, err_msg },
            );
            lua.pop(1);
            return error.LuaHandlerError;
        };
        defer lua.pop(1);

        if (lua.isNil(-1)) return;
        if (lua.typeOf(-1) != .string) {
            log.warn(
                "jit context handler for '{s}' returned non-string (type {s})",
                .{ req.tool_name, @tagName(lua.typeOf(-1)) },
            );
            return error.JitContextNotString;
        }
        const out = lua.toString(-1) catch return error.JitContextReadFailed;
        req.result = try req.allocator.dupe(u8, out);
    }

    /// Test-only accessor for the JIT context handler map. Stays public
    /// behind `pub` so inline tests in this file and round-trip tests in
    /// `AgentRunner` can assert handler-count growth without exposing the
    /// raw field through the public API surface.
    pub fn jitContextHandlers(
        self: *LuaEngine,
    ) *std.StringHashMapUnmanaged(JitHandler) {
        return &self.jit_context_handlers;
    }

    /// Zig function backing `zag.tools.transform_output(tool_name, fn)`.
    ///
    /// Registers a Lua handler that the harness invokes after every
    /// completed call to the tool with the matching name. Same lifecycle
    /// as `zag.context.on_tool_result`; the difference is purely how the
    /// agent loop consumes the return value (REPLACE vs append).
    ///
    /// Args:
    /// - arg 1 (string, required, non-empty): tool name to match.
    /// - arg 2 (function, required): handler `fn(ctx) -> string|nil`.
    ///
    /// Re-registering an existing tool name unrefs the previous function
    /// before stashing the new one; the owned name slice is reused so the
    /// hashmap key stays stable.
    fn zagToolTransformOutputFn(lua: *Lua) i32 {
        const engine = getEngineFromState(lua);

        if (lua.typeOf(1) != .string) {
            lua.raiseErrorStr(
                "zag.tools.transform_output: arg 1 must be a string tool name",
                .{},
            );
        }
        const tool_name = lua.toString(1) catch {
            lua.raiseErrorStr(
                "zag.tools.transform_output: arg 1 could not be read",
                .{},
            );
        };
        if (tool_name.len == 0) {
            lua.raiseErrorStr(
                "zag.tools.transform_output: arg 1 must not be empty",
                .{},
            );
        }

        if (!lua.isFunction(2)) {
            lua.raiseErrorStr(
                "zag.tools.transform_output: arg 2 must be a function",
                .{},
            );
        }

        // Push a copy of arg 2 so ref() pops the duplicate and leaves the
        // original argument frame intact.
        lua.pushValue(2);
        const fn_ref = lua.ref(zlua.registry_index) catch {
            lua.raiseErrorStr(
                "zag.tools.transform_output: failed to ref handler",
                .{},
            );
        };
        errdefer lua.unref(zlua.registry_index, fn_ref);

        // Re-registration: unref the old fn but keep the existing owned
        // name slice (the map key aliases it, so freeing would dangle the
        // bucket key). Just swap the value in place.
        if (engine.tool_transform_handlers.getPtr(tool_name)) |existing| {
            lua.unref(zlua.registry_index, existing.fn_ref);
            existing.fn_ref = fn_ref;
            return 0;
        }

        const owned_name = engine.allocator.dupe(u8, tool_name) catch {
            lua.unref(zlua.registry_index, fn_ref);
            lua.raiseErrorStr(
                "zag.tools.transform_output: out of memory duping tool name",
                .{},
            );
        };
        errdefer engine.allocator.free(owned_name);

        engine.tool_transform_handlers.put(engine.allocator, owned_name, .{
            .tool_name = owned_name,
            .fn_ref = fn_ref,
        }) catch {
            lua.unref(zlua.registry_index, fn_ref);
            engine.allocator.free(owned_name);
            lua.raiseErrorStr(
                "zag.tools.transform_output: out of memory inserting handler",
                .{},
            );
        };

        return 0;
    }

    /// Run the tool-output transform handler for `req.tool_name` on the
    /// main thread. Builds a Lua-side context table identical in shape to
    /// the JIT context handler's, calls the registered function via
    /// `protectedCall`, and dupes the returned string into `req.allocator`
    /// (success path). When no handler is registered the request returns
    /// with `result = null` and `error_name = null` so the worker proceeds
    /// with the original output. Lua-side errors set the caller's
    /// `error_name` via the returned error and leave `result` null.
    /// Caller is responsible for `req.done.set()`.
    pub fn handleToolTransformRequest(
        self: *LuaEngine,
        req: *agent_events.ToolTransformRequest,
    ) anyerror!void {
        const handler = self.tool_transform_handlers.get(req.tool_name) orelse return;

        const lua = self.lua;
        _ = lua.rawGetIndex(zlua.registry_index, handler.fn_ref);
        if (!lua.isFunction(-1)) {
            lua.pop(1);
            log.warn(
                "tool transform handler for '{s}': registry slot is not a function",
                .{req.tool_name},
            );
            return;
        }

        // Same context-table shape as the JIT context handler so a plugin
        // can swap between append-semantics and replace-semantics by
        // changing the registration entry point only.
        lua.newTable();
        _ = lua.pushString(req.tool_name);
        lua.setField(-2, "tool");
        _ = lua.pushString(req.input);
        lua.setField(-2, "input");
        _ = lua.pushString(req.output);
        lua.setField(-2, "output");
        lua.pushBoolean(req.is_error);
        lua.setField(-2, "is_error");

        lua.protectedCall(.{ .args = 1, .results = 1 }) catch {
            const err_msg = lua.toString(-1) catch "<unprintable>";
            log.warn(
                "tool transform handler for '{s}' raised: {s}",
                .{ req.tool_name, err_msg },
            );
            lua.pop(1);
            return error.LuaHandlerError;
        };
        defer lua.pop(1);

        if (lua.isNil(-1)) return;
        if (lua.typeOf(-1) != .string) {
            log.warn(
                "tool transform handler for '{s}' returned non-string (type {s})",
                .{ req.tool_name, @tagName(lua.typeOf(-1)) },
            );
            return error.ToolTransformNotString;
        }
        const out = lua.toString(-1) catch return error.ToolTransformReadFailed;
        req.result = try req.allocator.dupe(u8, out);
    }

    /// Test-only accessor for the tool transform handler map. Same
    /// rationale as `jitContextHandlers`.
    pub fn toolTransformHandlers(
        self: *LuaEngine,
    ) *std.StringHashMapUnmanaged(JitHandler) {
        return &self.tool_transform_handlers;
    }

    /// Zig function backing `zag.tools.gate(fn)`.
    ///
    /// Registers the single global gate handler the harness invokes
    /// once per turn (before each `callLlm`). Re-registering replaces
    /// the previous function; the old Lua ref is unrefed so memory
    /// does not bloat across reloads. Pass nil to clear.
    ///
    /// Args:
    /// - arg 1 (function or nil, required): handler `fn(ctx) -> table|nil`.
    fn zagToolsGateFn(lua: *Lua) i32 {
        const engine = getEngineFromState(lua);

        // Allow `zag.tools.gate(nil)` to clear the handler. Anything
        // else that isn't a function is a programmer error.
        if (lua.isNil(1)) {
            if (engine.tool_gate_handler) |old| {
                lua.unref(zlua.registry_index, old);
                engine.tool_gate_handler = null;
            }
            return 0;
        }
        if (!lua.isFunction(1)) {
            lua.raiseErrorStr(
                "zag.tools.gate: arg 1 must be a function or nil",
                .{},
            );
        }

        // Push a copy of arg 1 so ref() pops the duplicate and leaves
        // the original argument frame intact.
        lua.pushValue(1);
        const fn_ref = lua.ref(zlua.registry_index) catch {
            lua.raiseErrorStr(
                "zag.tools.gate: failed to ref handler",
                .{},
            );
        };

        if (engine.tool_gate_handler) |old| {
            lua.unref(zlua.registry_index, old);
        }
        engine.tool_gate_handler = fn_ref;
        return 0;
    }

    /// Run the tool-gate handler on the main thread. Builds a
    /// Lua-side context table `{model = ..., tools = {names...}}`,
    /// calls the registered function via `protectedCall`, and decodes
    /// the returned table back into an owned `[]const []const u8`
    /// duped into `req.allocator`.
    ///
    /// When no handler is registered or the handler returns nil, the
    /// request returns with `result = null` and `error_name = null`
    /// so the worker proceeds with the full registry. A non-table
    /// non-nil return surfaces as `error.ToolGateNotTable`. Caller is
    /// responsible for `req.done.set()`.
    pub fn handleToolGateRequest(
        self: *LuaEngine,
        req: *agent_events.ToolGateRequest,
    ) anyerror!void {
        const fn_ref = self.tool_gate_handler orelse return;

        const lua = self.lua;
        _ = lua.rawGetIndex(zlua.registry_index, fn_ref);
        if (!lua.isFunction(-1)) {
            lua.pop(1);
            log.warn("tool gate handler: registry slot is not a function", .{});
            return;
        }

        // Context table: { model = string, tools = { name1, name2, ... } }.
        // Plain sequence so a Lua handler can iterate with ipairs.
        lua.newTable();
        _ = lua.pushString(req.model);
        lua.setField(-2, "model");
        lua.newTable();
        for (req.available_tools, 0..) |name, i| {
            _ = lua.pushString(name);
            lua.rawSetIndex(-2, @intCast(i + 1));
        }
        lua.setField(-2, "tools");

        lua.protectedCall(.{ .args = 1, .results = 1 }) catch {
            const err_msg = lua.toString(-1) catch "<unprintable>";
            log.warn("tool gate handler raised: {s}", .{err_msg});
            lua.pop(1);
            return error.LuaHandlerError;
        };
        defer lua.pop(1);

        if (lua.isNil(-1)) return;
        if (lua.typeOf(-1) != .table) {
            log.warn(
                "tool gate handler returned non-table (type {s})",
                .{@tagName(lua.typeOf(-1))},
            );
            return error.ToolGateNotTable;
        }

        // Walk the returned sequence as 1..N, stopping at the first
        // hole. `objectLen` is `#t` Lua-side; correct for sequences
        // (we accept any 1-indexed run of strings).
        const len = lua.rawLen(-1);
        if (len == 0) return; // empty table => no subset, fall back
        var collected: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (collected.items) |s| req.allocator.free(s);
            collected.deinit(req.allocator);
        }

        for (0..len) |idx| {
            _ = lua.rawGetIndex(-1, @intCast(idx + 1));
            defer lua.pop(1);
            if (lua.typeOf(-1) != .string) {
                log.warn(
                    "tool gate handler entry {d} is non-string (type {s})",
                    .{ idx + 1, @tagName(lua.typeOf(-1)) },
                );
                return error.ToolGateEntryNotString;
            }
            const name = lua.toString(-1) catch return error.ToolGateReadFailed;
            const owned = try req.allocator.dupe(u8, name);
            errdefer req.allocator.free(owned);
            try collected.append(req.allocator, owned);
        }

        req.result = try collected.toOwnedSlice(req.allocator);
    }

    /// Test-only accessor for the single global tool-gate handler ref.
    pub fn toolGateHandler(self: *const LuaEngine) ?i32 {
        return self.tool_gate_handler;
    }

    /// Zig function backing `zag.loop.detect(fn)`.
    ///
    /// Registers the single global loop-detector handler the harness
    /// invokes after every tool execution. Re-registering replaces
    /// the previous function; the old Lua ref is unrefed so memory
    /// does not bloat across reloads. Pass nil to clear.
    ///
    /// Args:
    /// - arg 1 (function or nil, required): handler `fn(ctx) -> table|nil`.
    fn zagLoopDetectFn(lua: *Lua) i32 {
        const engine = getEngineFromState(lua);

        // Allow `zag.loop.detect(nil)` to clear the handler. Anything
        // else that isn't a function is a programmer error.
        if (lua.isNil(1)) {
            if (engine.loop_detect_handler) |old| {
                lua.unref(zlua.registry_index, old);
                engine.loop_detect_handler = null;
            }
            return 0;
        }
        if (!lua.isFunction(1)) {
            lua.raiseErrorStr(
                "zag.loop.detect: arg 1 must be a function or nil",
                .{},
            );
        }

        // Push a copy of arg 1 so ref() pops the duplicate and leaves
        // the original argument frame intact.
        lua.pushValue(1);
        const fn_ref = lua.ref(zlua.registry_index) catch {
            lua.raiseErrorStr(
                "zag.loop.detect: failed to ref handler",
                .{},
            );
        };

        if (engine.loop_detect_handler) |old| {
            lua.unref(zlua.registry_index, old);
        }
        engine.loop_detect_handler = fn_ref;
        return 0;
    }

    /// Run the loop-detector handler on the main thread. Builds a
    /// Lua-side context table `{tool, input, is_error, identical_streak}`,
    /// calls the registered function via `protectedCall`, and decodes
    /// the returned table into a `LoopAction`.
    ///
    /// When no handler is registered or the handler returns nil, the
    /// request returns with `result = null` and `error_name = null` so
    /// the worker proceeds without intervention. A non-table non-nil
    /// return surfaces as `error.LoopDetectNotTable`. An unknown action
    /// string surfaces as `error.LoopDetectUnknownAction`. Caller is
    /// responsible for `req.done.set()`.
    pub fn handleLoopDetectRequest(
        self: *LuaEngine,
        req: *agent_events.LoopDetectRequest,
    ) anyerror!void {
        const fn_ref = self.loop_detect_handler orelse return;

        const lua = self.lua;
        _ = lua.rawGetIndex(zlua.registry_index, fn_ref);
        if (!lua.isFunction(-1)) {
            lua.pop(1);
            log.warn("loop detect handler: registry slot is not a function", .{});
            return;
        }

        // Context table the handler sees. Same shape as the JIT context
        // and tool-transform handlers (`tool`/`input`/`is_error`) plus a
        // `last_tool_name` alias and the `identical_streak` counter the
        // detector uses to decide when to act.
        lua.newTable();
        _ = lua.pushString(req.last_tool_name);
        lua.setField(-2, "tool");
        _ = lua.pushString(req.last_tool_name);
        lua.setField(-2, "last_tool_name");
        _ = lua.pushString(req.last_tool_input);
        lua.setField(-2, "input");
        _ = lua.pushString(req.last_tool_input);
        lua.setField(-2, "last_tool_input");
        lua.pushBoolean(req.is_error);
        lua.setField(-2, "is_error");
        lua.pushInteger(@intCast(req.identical_streak));
        lua.setField(-2, "identical_streak");

        lua.protectedCall(.{ .args = 1, .results = 1 }) catch {
            const err_msg = lua.toString(-1) catch "<unprintable>";
            log.warn("loop detect handler raised: {s}", .{err_msg});
            lua.pop(1);
            return error.LuaHandlerError;
        };
        defer lua.pop(1);

        if (lua.isNil(-1)) return;
        if (lua.typeOf(-1) != .table) {
            log.warn(
                "loop detect handler returned non-table (type {s})",
                .{@tagName(lua.typeOf(-1))},
            );
            return error.LoopDetectNotTable;
        }

        // Decode `{action = "reminder", text = "..."}` or
        // `{action = "abort"}`. Anything else is an error.
        _ = lua.getField(-1, "action");
        defer lua.pop(1);
        if (lua.typeOf(-1) != .string) {
            log.warn(
                "loop detect handler return missing string `action` (type {s})",
                .{@tagName(lua.typeOf(-1))},
            );
            return error.LoopDetectNotTable;
        }
        const action = lua.toString(-1) catch return error.LoopDetectReadFailed;

        if (std.mem.eql(u8, action, "abort")) {
            req.result = .abort;
            return;
        }
        if (std.mem.eql(u8, action, "reminder")) {
            _ = lua.getField(-2, "text");
            defer lua.pop(1);
            if (lua.typeOf(-1) != .string) {
                log.warn(
                    "loop detect reminder return missing string `text` (type {s})",
                    .{@tagName(lua.typeOf(-1))},
                );
                return error.LoopDetectReminderMissingText;
            }
            const text = lua.toString(-1) catch return error.LoopDetectReadFailed;
            const owned = try req.allocator.dupe(u8, text);
            req.result = .{ .reminder = owned };
            return;
        }
        log.warn("loop detect handler returned unknown action: {s}", .{action});
        return error.LoopDetectUnknownAction;
    }

    /// Test-only accessor for the single global loop-detector handler ref.
    pub fn loopDetectHandler(self: *const LuaEngine) ?i32 {
        return self.loop_detect_handler;
    }

    /// Zig function backing `zag.compact.strategy(fn)`.
    ///
    /// Registers the single global compaction-strategy handler the
    /// harness invokes when the running token estimate crosses the
    /// high-water threshold. Re-registering replaces the previous
    /// function; the old Lua ref is unrefed so memory does not bloat
    /// across reloads. Pass nil to clear.
    ///
    /// Args:
    /// - arg 1 (function or nil, required): handler `fn(ctx) -> table|nil`.
    fn zagCompactStrategyFn(lua: *Lua) i32 {
        const engine = getEngineFromState(lua);

        // Allow `zag.compact.strategy(nil)` to clear the handler.
        // Anything else that isn't a function is a programmer error.
        if (lua.isNil(1)) {
            if (engine.compact_handler) |old| {
                lua.unref(zlua.registry_index, old);
                engine.compact_handler = null;
            }
            return 0;
        }
        if (!lua.isFunction(1)) {
            lua.raiseErrorStr(
                "zag.compact.strategy: arg 1 must be a function or nil",
                .{},
            );
        }

        // Push a copy of arg 1 so ref() pops the duplicate and leaves
        // the original argument frame intact.
        lua.pushValue(1);
        const fn_ref = lua.ref(zlua.registry_index) catch {
            lua.raiseErrorStr(
                "zag.compact.strategy: failed to ref handler",
                .{},
            );
        };

        if (engine.compact_handler) |old| {
            lua.unref(zlua.registry_index, old);
        }
        engine.compact_handler = fn_ref;
        return 0;
    }

    /// Push a Lua-side message snapshot onto the stack for the compact
    /// strategy handler. The snapshot is a sequence (1..N) of
    /// `{role = "user"|"assistant", content = "<concat text>"}` tables
    /// where `content` is the concatenation of every `.text` block in
    /// the original message. Non-text blocks (tool_use, tool_result,
    /// thinking, redacted_thinking) are dropped from the snapshot.
    /// Lossy by design: the strategy decides what stays and emits
    /// replacement summary text rather than mutating block-shaped
    /// history. Returns void; the table is left on top of the stack.
    fn pushCompactMessageSnapshot(
        lua: *Lua,
        messages: []const types.Message,
        scratch: Allocator,
    ) !void {
        lua.newTable();
        for (messages, 0..) |msg, idx| {
            // Per-message subtable. `role` is a fixed string; `content`
            // is the concatenation of every text block in this message.
            lua.newTable();

            const role_str: []const u8 = switch (msg.role) {
                .user => "user",
                .assistant => "assistant",
            };
            _ = lua.pushString(role_str);
            lua.setField(-2, "role");

            var concat: std.ArrayList(u8) = .empty;
            defer concat.deinit(scratch);
            for (msg.content) |block| {
                switch (block) {
                    .text => |t| try concat.appendSlice(scratch, t.text),
                    else => {},
                }
            }
            _ = lua.pushString(concat.items);
            lua.setField(-2, "content");

            // Lua sequences are 1-indexed.
            lua.rawSetIndex(-2, @intCast(idx + 1));
        }
    }

    /// Decode a single `{role, content}` entry off the top of the stack
    /// into an owned `types.Message`. Caller frees on error via
    /// `Message.deinit` if the call returns successfully but the parent
    /// loop later fails. The caller pushes the entry and pops it on the
    /// success path; the `errdefer` here pops the entry on every error
    /// path so the outer loop sees a clean stack regardless of where
    /// decoding fails.
    fn decodeCompactEntry(
        lua: *Lua,
        allocator: Allocator,
    ) !types.Message {
        errdefer lua.pop(1);
        if (lua.typeOf(-1) != .table) {
            log.warn(
                "compact strategy entry is not a table (type {s})",
                .{@tagName(lua.typeOf(-1))},
            );
            return error.CompactEntryNotTable;
        }

        _ = lua.getField(-1, "role");
        defer lua.pop(1);
        if (lua.typeOf(-1) != .string) {
            log.warn(
                "compact strategy entry missing string `role` (type {s})",
                .{@tagName(lua.typeOf(-1))},
            );
            return error.CompactEntryMissingRole;
        }
        const role_str = lua.toString(-1) catch return error.CompactEntryReadFailed;
        const role: types.Role = if (std.mem.eql(u8, role_str, "user"))
            .user
        else if (std.mem.eql(u8, role_str, "assistant"))
            .assistant
        else {
            log.warn("compact strategy entry has unknown role: {s}", .{role_str});
            return error.CompactEntryUnknownRole;
        };

        _ = lua.getField(-2, "content");
        defer lua.pop(1);
        if (lua.typeOf(-1) != .string) {
            log.warn(
                "compact strategy entry missing string `content` (type {s})",
                .{@tagName(lua.typeOf(-1))},
            );
            return error.CompactEntryMissingContent;
        }
        const content = lua.toString(-1) catch return error.CompactEntryReadFailed;

        const owned_text = try allocator.dupe(u8, content);
        errdefer allocator.free(owned_text);
        const blocks = try allocator.alloc(types.ContentBlock, 1);
        errdefer allocator.free(blocks);
        blocks[0] = .{ .text = .{ .text = owned_text } };
        return .{ .role = role, .content = blocks };
    }

    /// Run the compaction strategy on the main thread. Builds a
    /// Lua-side context table `{tokens_used, tokens_max, messages}`,
    /// calls the registered function via `protectedCall`, and decodes
    /// the returned table into a duped `[]Message`.
    ///
    /// When no handler is registered or the handler returns nil, the
    /// request returns with `result = null` and `error_name = null` so
    /// the worker proceeds without compaction. A non-table non-nil
    /// return surfaces as `error.CompactNotTable`. Caller is responsible
    /// for `req.done.set()`.
    pub fn handleCompactRequest(
        self: *LuaEngine,
        req: *agent_events.CompactRequest,
    ) anyerror!void {
        const fn_ref = self.compact_handler orelse return;

        const lua = self.lua;
        _ = lua.rawGetIndex(zlua.registry_index, fn_ref);
        if (!lua.isFunction(-1)) {
            lua.pop(1);
            log.warn("compact strategy handler: registry slot is not a function", .{});
            return;
        }

        // Context table the strategy sees: token usage scalars plus a
        // sequence of `{role, content}` message tables. The text
        // concatenation lives on the engine's allocator for the
        // duration of the call; `pushString` dupes into Lua's string
        // table so the scratch allocations are safe to drop on return.
        lua.newTable();
        lua.pushInteger(@intCast(req.tokens_used));
        lua.setField(-2, "tokens_used");
        lua.pushInteger(@intCast(req.tokens_max));
        lua.setField(-2, "tokens_max");

        try pushCompactMessageSnapshot(lua, req.messages, self.allocator);
        lua.setField(-2, "messages");

        lua.protectedCall(.{ .args = 1, .results = 1 }) catch {
            const err_msg = lua.toString(-1) catch "<unprintable>";
            log.warn("compact strategy handler raised: {s}", .{err_msg});
            lua.pop(1);
            return error.LuaHandlerError;
        };
        defer lua.pop(1);

        if (lua.isNil(-1)) return;
        if (lua.typeOf(-1) != .table) {
            log.warn(
                "compact strategy handler returned non-table (type {s})",
                .{@tagName(lua.typeOf(-1))},
            );
            return error.CompactNotTable;
        }

        const len = lua.rawLen(-1);
        if (len == 0) {
            // Empty replacement is a valid "drop everything" request,
            // but we route it through the standard allocator so the
            // caller's `freeResult` path stays uniform.
            const empty = try req.allocator.alloc(types.Message, 0);
            req.result = empty;
            return;
        }

        var collected: std.ArrayList(types.Message) = .empty;
        errdefer {
            for (collected.items) |m| m.deinit(req.allocator);
            collected.deinit(req.allocator);
        }

        for (0..len) |idx| {
            _ = lua.rawGetIndex(-1, @intCast(idx + 1));
            // decodeCompactEntry pops its own entry off the stack
            // so the outer loop sees a clean top after each iteration.
            const msg = try decodeCompactEntry(lua, req.allocator);
            errdefer msg.deinit(req.allocator);
            try collected.append(req.allocator, msg);
            lua.pop(1);
        }

        req.result = try collected.toOwnedSlice(req.allocator);
    }

    /// Test-only accessor for the single global compact strategy handler ref.
    pub fn compactHandler(self: *const LuaEngine) ?i32 {
        return self.compact_handler;
    }

    /// Paired with `active_render_engine`. `renderPromptLayers` sets both
    /// per layer so the thunk can cheaply identify which registry entry
    /// it is servicing without carrying user-data on the Layer type.
    threadlocal var active_render_layer: ?*const prompt.Layer = null;

    /// Render the engine's prompt registry against `ctx`. Wraps
    /// `Registry.render` with the thread-local plumbing Lua layer
    /// thunks read from. Caller owns the returned `AssembledPrompt`.
    pub fn renderPromptLayers(
        self: *LuaEngine,
        ctx: *const prompt.LayerContext,
        alloc: Allocator,
    ) !prompt.AssembledPrompt {
        const prior_engine = active_render_engine;
        const prior_layer = active_render_layer;
        active_render_engine = self;
        defer {
            active_render_engine = prior_engine;
            active_render_layer = prior_layer;
        }
        return try renderWithPerLayerBinding(&self.prompt_registry, ctx, alloc);
    }

    /// Wrapper around `Registry.render` that updates `active_render_layer`
    /// as the sort loop advances. We can't intercept Registry.render
    /// itself without touching prompt.zig, so the adapter re-implements
    /// the minimal render loop here.
    fn renderWithPerLayerBinding(
        registry: *prompt.Registry,
        ctx: *const prompt.LayerContext,
        alloc: Allocator,
    ) !prompt.AssembledPrompt {
        var arena_state: std.heap.ArenaAllocator = .init(alloc);
        errdefer arena_state.deinit();
        const arena = arena_state.allocator();

        // Stable sort preserves registration order across ties. Match
        // `Registry.render`'s sort-on-scratch-copy so the registry keeps
        // its registration order.
        const sorted = try arena.dupe(prompt.Layer, registry.layers.items);
        std.mem.sort(prompt.Layer, sorted, {}, layerLessThanForLua);

        var stable_buf: std.ArrayList(u8) = .empty;
        var volatile_buf: std.ArrayList(u8) = .empty;

        for (sorted) |*layer| {
            active_render_layer = layer;
            const rendered = try layer.render_fn(ctx, arena);
            active_render_layer = null;
            const text = rendered orelse continue;
            if (text.len == 0) continue;

            const target = switch (layer.cache_class) {
                .stable => &stable_buf,
                .@"volatile" => &volatile_buf,
            };
            if (target.items.len > 0) try target.appendSlice(arena, "\n\n");
            try target.appendSlice(arena, text);
        }

        const stable = try stable_buf.toOwnedSlice(arena);
        const volatile_part = try volatile_buf.toOwnedSlice(arena);

        registry.stable_frozen = true;

        return .{
            .stable = stable,
            .@"volatile" = volatile_part,
            .arena = arena_state,
        };
    }

    fn layerLessThanForLua(_: void, a: prompt.Layer, b: prompt.Layer) bool {
        return a.priority < b.priority;
    }

    /// Push a Lua table describing `ctx` onto `lua`'s stack. Exposes the
    /// borrowed scalar fields plus a `tools` sequence with `{name,
    /// description}` entries and a `skills` sequence of skill names.
    /// Kept narrow on purpose: layer authors generally reach for a few
    /// well-known strings, and anything richer (raw tool schemas, live
    /// skill registries) is better served by Zig-side layers.
    fn pushLayerContextTable(lua: *Lua, ctx: *const prompt.LayerContext) void {
        lua.newTable();

        // Scalar strings borrow Lua's copy semantics: pushString dupes
        // into Lua's internal string table, so the borrowed `ctx` slices
        // don't need to outlive this call.
        _ = lua.pushString(ctx.model.provider_name);
        lua.setField(-2, "provider");
        _ = lua.pushString(ctx.model.model_id);
        lua.setField(-2, "model_id");

        // Convenience alias: "model" as a pre-joined "provider/model_id"
        // string. Saves layers from concatenating the two pieces.
        var model_buf: [256]u8 = undefined;
        const joined = std.fmt.bufPrint(&model_buf, "{s}/{s}", .{ ctx.model.provider_name, ctx.model.model_id }) catch ctx.model.model_id;
        _ = lua.pushString(joined);
        lua.setField(-2, "model");

        _ = lua.pushString(ctx.cwd);
        lua.setField(-2, "cwd");
        _ = lua.pushString(ctx.worktree);
        lua.setField(-2, "worktree");
        _ = lua.pushString(ctx.agent_name);
        lua.setField(-2, "agent_name");
        _ = lua.pushString(ctx.date_iso);
        lua.setField(-2, "date_iso");
        lua.pushBoolean(ctx.is_git_repo);
        lua.setField(-2, "is_git_repo");
        _ = lua.pushString(ctx.platform);
        lua.setField(-2, "platform");

        // tools: sequence of { name = ..., description = ... } tables.
        lua.newTable();
        for (ctx.tools, 0..) |def, i| {
            lua.newTable();
            _ = lua.pushString(def.name);
            lua.setField(-2, "name");
            _ = lua.pushString(def.description);
            lua.setField(-2, "description");
            lua.rawSetIndex(-2, @intCast(i + 1));
        }
        lua.setField(-2, "tools");

        // skills: sequence of skill names. Empty when ctx.skills is null
        // or the registry has no entries; the layer can len-check it.
        lua.newTable();
        if (ctx.skills) |skills_reg| {
            for (skills_reg.skills.items, 0..) |skill, i| {
                _ = lua.pushString(skill.name);
                lua.rawSetIndex(-2, @intCast(i + 1));
            }
        }
        lua.setField(-2, "skills");
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

    /// Invoke a zero-arg Lua callback stored at `ref` in the registry.
    /// Used by `WindowManager.executeAction` to dispatch
    /// `Keymap.Action.lua_callback` bindings. Errors are logged and
    /// swallowed; the keymap layer must not propagate Lua failures into
    /// the terminal event loop.
    pub fn invokeCallback(self: *LuaEngine, ref: i32) void {
        // Obviously-invalid refs never resolve to a callable; short-circuit
        // before the registry lookup to avoid pushing nil and calling it.
        if (ref == zlua.ref_nil or ref == 0) return;
        const lua = self.lua;
        _ = lua.rawGetIndex(zlua.registry_index, ref);
        lua.protectedCall(.{ .args = 0, .results = 0 }) catch |err| {
            const msg = lua.toString(-1) catch "<unprintable>";
            log.warn("lua callback raised: {} ({s})", .{ err, msg });
            lua.pop(1);
        };
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

    /// Install two custom `package.searchers` at the front of Lua's searcher
    /// list so `require()` resolves user files first, embedded stdlib second,
    /// and standard Lua searchers (path/cpath/preload) afterward.
    ///
    /// The searchers look up their context in the `_ZAG_LOADER` global: a
    /// table with `user_dir` (string, may be empty) and `sources` (map of
    /// dotted-module-name -> source bytes). The searcher closures capture a
    /// local reference to this table so they keep working even if the global
    /// is later cleared.
    ///
    /// No-op when the sandbox is enabled: `package` and `require` are
    /// stripped, so adding searchers would panic on the missing globals.
    fn installSearchers(allocator: Allocator, lua: *Lua) !void {
        if (sandbox_enabled) return;

        // Resolve the user Lua directory. Missing HOME is not fatal; the
        // user_searcher closure treats an empty dir as "no user overrides".
        var user_dir_owned: ?[]u8 = null;
        defer if (user_dir_owned) |d| allocator.free(d);
        if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
            defer allocator.free(home);
            user_dir_owned = try std.fmt.allocPrint(allocator, "{s}/.config/zag/lua", .{home});
        } else |_| {
            user_dir_owned = null;
        }
        const user_dir: []const u8 = user_dir_owned orelse "";

        // Build the carrier table: _ZAG_LOADER = { user_dir = "...",
        // sources = { ["zag.providers.anthropic"] = "...source...", ... } }
        lua.newTable(); // [loader]

        _ = lua.pushString(user_dir);
        lua.setField(-2, "user_dir"); // [loader]

        lua.newTable(); // [loader, sources]
        for (embedded.entries) |e| {
            _ = lua.pushString(e.code);
            // setField wants a sentinel-terminated key. Dupe and free.
            const name_z = try allocator.dupeZ(u8, e.name);
            defer allocator.free(name_z);
            lua.setField(-2, name_z);
        }
        lua.setField(-2, "sources"); // [loader]

        lua.setGlobal("_ZAG_LOADER"); // []

        // Install the searcher closures at positions 1 and 2 of
        // package.searchers. Both close over a local `ctx` so they keep
        // working if `_ZAG_LOADER` is ever cleared (we don't clear it today,
        // but the guarantee is cheap and matches user expectations).
        lua.doString(
            \\do
            \\  local ctx = _ZAG_LOADER
            \\  local function user_searcher(module)
            \\    if not ctx.user_dir or ctx.user_dir == "" then return nil end
            \\    local rel = module:gsub("%.", "/")
            \\    local path = ctx.user_dir .. "/" .. rel .. ".lua"
            \\    local f = io.open(path, "rb")
            \\    if not f then
            \\      path = ctx.user_dir .. "/" .. rel .. "/init.lua"
            \\      f = io.open(path, "rb")
            \\      if not f then
            \\        return "\n\tno user file '" .. ctx.user_dir .. "/" .. rel .. ".lua'"
            \\      end
            \\    end
            \\    local chunk = f:read("*a")
            \\    f:close()
            \\    local fn, err = load(chunk, "@" .. path)
            \\    if not fn then return err end
            \\    return fn, path
            \\  end
            \\  local function embedded_searcher(module)
            \\    local src = ctx.sources[module]
            \\    if not src then
            \\      return "\n\tno embedded module '" .. module .. "'"
            \\    end
            \\    local fn, err = load(src, "@<embedded:" .. module .. ">")
            \\    if not fn then return err end
            \\    return fn, "<embedded:" .. module .. ">"
            \\  end
            \\  table.insert(package.searchers, 1, user_searcher)
            \\  table.insert(package.searchers, 2, embedded_searcher)
            \\end
        ) catch |err| {
            log.err("failed to install package.searchers: {}", .{err});
            return err;
        };
    }

    /// Spin up the async runtime: completion queue, I/O worker pool, task map,
    /// and root scope. Must be called after `init()` and before any Lua code
    /// tries to spawn coroutines. Failure rolls back partial state.
    pub fn initAsync(self: *LuaEngine, num_workers: usize, capacity: usize) !void {
        // Init-once cold path: latched at engine startup before any Lua code runs; double-init is a programmer bug, not a runtime condition.
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
        // Init-once latch check: dwarfed by the `lua.newThread` + `Scope.init` allocations that follow on the same path, so no measurable hot-path cost.
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

test "LuaEngine.init starts with an empty providers_registry" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    try std.testing.expectEqual(@as(usize, 0), engine.providers_registry.endpoints.items.len);
    try std.testing.expectEqual(@as(?*const llm.Endpoint, null), engine.providers_registry.find("anthropic"));
    try std.testing.expectEqual(@as(?[]const u8, null), engine.default_model);
}

test "invokeCallback is a no-op on ref_nil and 0" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();

    // Neither call should crash or touch the Lua stack.
    const top_before = engine.lua.getTop();
    engine.invokeCallback(0);
    engine.invokeCallback(zlua.ref_nil);
    try std.testing.expectEqual(top_before, engine.lua.getTop());
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

test "non-draft hooks fire up to depth 7 without tripping the per-kind guard" {
    // The per-event-kind cap exists so a draft hook (cap 1) cannot also
    // throttle unrelated kinds. Simulate a tool_post chain mid-flight by
    // pre-bumping the dispatcher's tool_post depth: the hook must still
    // run at depth 7 (one slot below the 8-cap), and must be skipped at
    // depth 8.
    std.testing.log_level = .err;
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\_G.tool_post_count = 0
        \\zag.hook("ToolPost", function(evt)
        \\  _G.tool_post_count = (_G.tool_post_count or 0) + 1
        \\end)
    );

    var payload: Hooks.HookPayload = .{ .tool_post = .{
        .name = "bash",
        .call_id = "id1",
        .content = "ok",
        .is_error = false,
        .duration_ms = 0,
        .content_rewrite = null,
        .is_error_rewrite = null,
    } };

    // Depth 0: trivially under the cap; baseline fire.
    _ = try engine.fireHook(&payload);

    // Walk depth from 1..=7. Each level is still < 8, so the hook fires.
    var d: u32 = 1;
    while (d <= 7) : (d += 1) {
        engine.hook_dispatcher.firing_depth.set(.tool_post, d);
        _ = try engine.fireHook(&payload);
    }

    _ = try engine.lua.getGlobal("tool_post_count");
    // 1 (baseline) + 7 (d=1..=7) = 8 fires.
    try std.testing.expectEqual(@as(i64, 8), try engine.lua.toInteger(-1));
    engine.lua.pop(1);

    // At depth 8 (the cap), the dispatcher must skip rather than recurse.
    engine.hook_dispatcher.firing_depth.set(.tool_post, 8);
    _ = try engine.fireHook(&payload);

    _ = try engine.lua.getGlobal("tool_post_count");
    try std.testing.expectEqual(@as(i64, 8), try engine.lua.toInteger(-1));
    engine.lua.pop(1);

    // Reset so deinit doesn't trip any leak / state assertion.
    engine.hook_dispatcher.firing_depth.set(.tool_post, 0);
}

test "draft hook still caps at depth 1 even when other kinds have higher budgets" {
    // Companion to the tool_post test: pre-bumping draft to 1 must
    // skip the next draft fire (cap = 1), even though tool_post would
    // happily fire at the same depth.
    std.testing.log_level = .err;
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\_G.draft_count = 0
        \\zag.hook("PaneDraftChange", function(evt)
        \\  _G.draft_count = (_G.draft_count or 0) + 1
        \\end)
    );

    var payload: Hooks.HookPayload = .{ .pane_draft_change = .{
        .pane_handle = "n1",
        .draft_text = "hi",
        .previous_text = "h",
        .draft_rewrite = null,
    } };

    engine.hook_dispatcher.firing_depth.set(.pane_draft_change, 1);
    _ = try engine.fireHook(&payload);

    _ = try engine.lua.getGlobal("draft_count");
    try std.testing.expectEqual(@as(i64, 0), try engine.lua.toInteger(-1));
    engine.lua.pop(1);

    engine.hook_dispatcher.firing_depth.set(.pane_draft_change, 0);
}

test "end-to-end: config file to registry execution" {
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
    try std.testing.expect(
        registry.lookup(.normal, .{ .key = .{ .char = 'w' }, .modifiers = .{} }, null).? == .focus_right,
    );
    try std.testing.expect(
        registry.lookup(.normal, .{
            .key = .{ .char = 'q' },
            .modifiers = .{ .ctrl = true },
        }, null).? == .close_window,
    );
}

test "zag.keymap table form with action = string wires a named action" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.keymap { mode = "normal", key = "w", action = "focus_right" }
    );

    const registry = engine.keymapRegistry();
    try std.testing.expect(
        registry.lookup(.normal, .{ .key = .{ .char = 'w' }, .modifiers = .{} }, null).? == .focus_right,
    );
}

test "zag.keymap table form with fn registers a lua_callback binding" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\_G.fired = false
        \\zag.keymap {
        \\  mode = "normal",
        \\  key = "<CR>",
        \\  fn = function() _G.fired = true end,
        \\}
    );

    const hit = engine.keymapRegistry().lookup(
        .normal,
        .{ .key = .enter, .modifiers = .{} },
        null,
    ) orelse return error.TestExpectedBinding;
    try std.testing.expect(hit == .lua_callback);

    engine.invokeCallback(hit.lua_callback);
    _ = try engine.lua.getGlobal("fired");
    try std.testing.expect(engine.lua.toBoolean(-1));
    engine.lua.pop(1);
}

test "zag.keymap table form with buffer scope only fires for that buffer" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    // The scope binding requires a live `BufferRegistry` so the engine
    // can resolve the handle string into the concrete `Buffer.getId()`
    // that `EventOrchestrator` passes at dispatch time. Stand up a
    // registry locally; no WindowManager is needed for this test.
    var buffer_registry = BufferRegistry.init(alloc);
    defer buffer_registry.deinit();
    engine.buffer_registry = &buffer_registry;

    const handle = try buffer_registry.createScratch("picker");
    const buffer_id = (try buffer_registry.asBuffer(handle)).getId();
    const id = try BufferRegistry.formatId(alloc, handle);
    defer alloc.free(id);

    const script = try std.fmt.allocPrintSentinel(alloc,
        \\zag.keymap {{
        \\  mode = "normal",
        \\  key = "x",
        \\  buffer = "{s}",
        \\  action = "close_window",
        \\}}
    , .{id}, 0);
    defer alloc.free(script);
    try engine.lua.doString(script);

    const registry = engine.keymapRegistry();
    // Matches when the scoped buffer is focused. `buffer_id` is what
    // `EventOrchestrator` would pass through at dispatch time.
    try std.testing.expect(
        registry.lookup(
            .normal,
            .{ .key = .{ .char = 'x' }, .modifiers = .{} },
            buffer_id,
        ).? == .close_window,
    );
    // Another focused buffer does not see the scoped binding, and there
    // is no global `x` in the defaults.
    try std.testing.expect(
        registry.lookup(
            .normal,
            .{ .key = .{ .char = 'x' }, .modifiers = .{} },
            buffer_id +% 1,
        ) == null,
    );
}

test "zag.keymap returns an integer id" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\_G.id_pos = zag.keymap("normal", "w", "focus_right")
        \\_G.id_tbl = zag.keymap { mode = "normal", key = "<C-q>", action = "close_window" }
        \\_G.id_fn  = zag.keymap { mode = "normal", key = "<CR>", fn = function() end }
    );

    _ = try engine.lua.getGlobal("id_pos");
    const id_pos = try engine.lua.toInteger(-1);
    engine.lua.pop(1);
    _ = try engine.lua.getGlobal("id_tbl");
    const id_tbl = try engine.lua.toInteger(-1);
    engine.lua.pop(1);
    _ = try engine.lua.getGlobal("id_fn");
    const id_fn = try engine.lua.toInteger(-1);
    engine.lua.pop(1);

    try std.testing.expect(id_pos > 0);
    try std.testing.expect(id_tbl > id_pos);
    try std.testing.expect(id_fn > id_tbl);
}

test "zag.keymap returns (id, displaced_spec) so callers can restore overrides" {
    // Plugins that overwrite default bindings (e.g. the /model picker
    // routing j/k into a popup) need to put the user's defaults back
    // when they tear down. The wrapper hands them a re-registerable
    // table describing the displaced binding for that purpose.
    //
    // Three shapes are exercised:
    //   1. Fresh insert (no prior binding) -> displaced is nil.
    //   2. Overwrite of a built-in -> displaced is a table the caller
    //      can pass straight back to `zag.keymap{...}`.
    //   3. Overwrite where the new action is a fn (Lua callback) ->
    //      displaced still describes the prior built-in by name.
    //
    // All assertions run inside the Lua script because the Zig-side
    // `getGlobal` helper raises on a nil global (the fresh-insert
    // case), and reading the table with positional `getField` from
    // Zig is noisier than just asserting in Lua. The test only
    // surfaces a string global on failure, which `getGlobal` handles.
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\local function fail(msg) _G.assert_err = msg; error(msg) end
        \\
        \\-- 1. Fresh insert -> displaced is nil.
        \\local id_fresh, disp_fresh = zag.keymap {
        \\  mode = "normal", key = "<F5>", action = "focus_right",
        \\}
        \\if type(id_fresh) ~= "number" then fail("id_fresh not a number") end
        \\if disp_fresh ~= nil then fail("disp_fresh expected nil") end
        \\
        \\-- 2. Overwrite of built-in `j` -> table with action="focus_down".
        \\local id_over, disp_over = zag.keymap {
        \\  mode = "normal", key = "j", action = "split_vertical",
        \\}
        \\if type(disp_over) ~= "table" then fail("disp_over expected table") end
        \\if disp_over.mode ~= "normal" then fail("disp_over.mode wrong: " .. tostring(disp_over.mode)) end
        \\if disp_over.key ~= "j" then fail("disp_over.key wrong: " .. tostring(disp_over.key)) end
        \\if disp_over.action ~= "focus_down" then fail("disp_over.action wrong: " .. tostring(disp_over.action)) end
        \\if disp_over.buffer ~= nil then fail("disp_over.buffer expected nil for global binding") end
        \\
        \\-- 3. Overwrite via fn payload still surfaces the prior built-in.
        \\local id_fn, disp_fn = zag.keymap {
        \\  mode = "normal", key = "k", fn = function() end,
        \\}
        \\if type(disp_fn) ~= "table" then fail("disp_fn expected table") end
        \\if disp_fn.action ~= "focus_up" then fail("disp_fn.action wrong: " .. tostring(disp_fn.action)) end
        \\
        \\_G.assert_ok = "ok"
    );

    _ = try engine.lua.getGlobal("assert_ok");
    try std.testing.expectEqualStrings("ok", try engine.lua.toString(-1));
    engine.lua.pop(1);
}

test "zag.keymap displaced_spec round-trips: passing it back restores the binding" {
    // The picker's contract: capture displaced, then on cleanup call
    // `zag.keymap_remove(id)` followed by `zag.keymap(displaced)`.
    // Verify the spec is shaped so that round-trip lands the original
    // built-in action in the registry (matched by enum tag, since
    // built-in variants are payload-less).
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\local id, displaced = zag.keymap { mode = "normal", key = "j", fn = function() end }
        \\zag.keymap_remove(id)
        \\assert(displaced ~= nil, "expected displaced spec for j override")
        \\zag.keymap(displaced)
    );

    const ev_j: input.KeyEvent = .{ .key = .{ .char = 'j' }, .modifiers = .{} };
    const restored = engine.keymapRegistry().lookup(.normal, ev_j, null) orelse
        return error.TestExpectedKeymap;
    try std.testing.expect(restored == .focus_down);
}

test "zag.keymap_remove unregisters a binding so the key no longer fires" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\_G.fired = 0
        \\_G.id = zag.keymap {
        \\  mode = "normal",
        \\  key = "<F5>",
        \\  fn = function() _G.fired = _G.fired + 1 end,
        \\}
    );

    const ev: input.KeyEvent = .{ .key = .{ .function = 5 }, .modifiers = .{} };
    const hit = engine.keymapRegistry().lookup(.normal, ev, null) orelse
        return error.TestExpectedKeymap;
    engine.invokeCallback(hit.lua_callback);

    _ = try engine.lua.getGlobal("fired");
    try std.testing.expectEqual(@as(i64, 1), try engine.lua.toInteger(-1));
    engine.lua.pop(1);

    try engine.lua.doString("zag.keymap_remove(_G.id)");

    // Lookup returns null after removal. The orchestrator routes through
    // `lookup` on every key, so a null hit means the binding is dead.
    try std.testing.expectEqual(
        @as(?Keymap.Action, null),
        engine.keymapRegistry().lookup(.normal, ev, null),
    );
}

test "zag.keymap rebinding a fn binding unrefs the prior callback" {
    // Reviewer-flagged leak: when the same (mode, spec, buffer_id) is
    // registered twice with `fn = ...`, the FIRST `cb_ref` was never
    // released. Process-lifetime cleanup in `deinit` swept survivors,
    // but a long-running session that rebinds keys (config reload,
    // plugin re-init) accumulated dead refs until exit. The fix
    // surfaces the displaced action through `Registry.RegisterResult`
    // so this wrapper can unref the prior callback inline.
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    // Bind once: the table form stashes `fn1` in the Lua registry as
    // `cb_ref_1` and stores it in a `.lua_callback` action.
    try engine.lua.doString(
        \\zag.keymap {
        \\  mode = "normal",
        \\  key = "<C-x>",
        \\  fn = function() _G.who = "fn1" end,
        \\}
    );

    const ev: input.KeyEvent = .{ .key = .{ .char = 'x' }, .modifiers = .{ .ctrl = true } };
    const first_hit = engine.keymapRegistry().lookup(.normal, ev, null) orelse
        return error.TestExpectedKeymap;
    try std.testing.expect(first_hit == .lua_callback);
    const ref_one = first_hit.lua_callback;

    // Re-bind: previously the old `cb_ref_1` was orphaned because
    // `Registry.register` swallowed the displaced action; now the
    // Lua-side wrapper consumes `RegisterResult.displaced` and unrefs
    // it before the new id is returned.
    try engine.lua.doString(
        \\zag.keymap {
        \\  mode = "normal",
        \\  key = "<C-x>",
        \\  fn = function() _G.who = "fn2" end,
        \\}
    );

    const second_hit = engine.keymapRegistry().lookup(.normal, ev, null) orelse
        return error.TestExpectedKeymap;
    try std.testing.expect(second_hit == .lua_callback);
    // Overwrite path: same id, fresh callback ref.
    try std.testing.expect(second_hit.lua_callback != ref_one);

    // Direct proof the old ref is gone: unref'd slots are recycled by
    // the Lua registry's freelist, so `rawGetIndex(registry, ref_one)`
    // no longer pushes a function. Before the fix it would still hold
    // `fn1`. After the fix it pushes nil or a freelist link integer.
    _ = engine.lua.rawGetIndex(zlua.registry_index, ref_one);
    try std.testing.expect(!engine.lua.isFunction(-1));
    engine.lua.pop(1);

    // Sanity check: invoking the live binding fires the NEW function.
    engine.invokeCallback(second_hit.lua_callback);
    _ = try engine.lua.getGlobal("who");
    const who = try engine.lua.toString(-1);
    try std.testing.expectEqualStrings("fn2", who);
    engine.lua.pop(1);
}

test "zag.keymap_remove on an unknown id raises a Lua error" {
    std.testing.log_level = .err;
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    const result = engine.lua.doString("zag.keymap_remove(99999)");
    try std.testing.expectError(error.LuaRuntime, result);
    engine.lua.pop(1);
}

test "zag.keymap_remove on a non-positive id raises a Lua error" {
    std.testing.log_level = .err;
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    const result = engine.lua.doString("zag.keymap_remove(0)");
    try std.testing.expectError(error.LuaRuntime, result);
    engine.lua.pop(1);
}

test "zag.keymap_remove rejects non-integer numbers instead of truncating" {
    // Regression: `lua.toInteger` silently coerces 3.7 -> 3, which
    // would unbind whatever lives at id 3. Using `lua.checkInteger`
    // makes Lua raise on any value that isn't a true integer, so
    // plugin bugs that pass a float surface immediately rather than
    // corrupting the registry.
    std.testing.log_level = .err;
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    const result = engine.lua.doString("zag.keymap_remove(3.7)");
    try std.testing.expectError(error.LuaRuntime, result);
    engine.lua.pop(1);
}

test "zag.keymap table form rejects both fn and action" {
    std.testing.log_level = .err;
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    const result = engine.lua.doString(
        \\zag.keymap {
        \\  mode = "normal",
        \\  key = "w",
        \\  action = "focus_right",
        \\  fn = function() end,
        \\}
    );
    try std.testing.expectError(error.LuaRuntime, result);
    engine.lua.pop(1);
}

test "zag.keymap table form rejects neither fn nor action" {
    std.testing.log_level = .err;
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    const result = engine.lua.doString(
        \\zag.keymap { mode = "normal", key = "w" }
    );
    try std.testing.expectError(error.LuaRuntime, result);
    engine.lua.pop(1);
}

test "zag.command{} registers a lua-callback command" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\_G.count = 0
        \\zag.command {
        \\  name = "model",
        \\  fn = function() _G.count = _G.count + 1 end,
        \\}
    );

    const hit = engine.command_registry.lookup("/model") orelse
        return error.TestExpectedCommand;
    try std.testing.expect(hit == .lua_callback);

    engine.invokeCallback(hit.lua_callback);
    _ = try engine.lua.getGlobal("count");
    try std.testing.expectEqual(@as(i64, 1), try engine.lua.toInteger(-1));
    engine.lua.pop(1);
}

test "zag.command{} shadow wins over a built-in keyed on the same slash" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    // `LuaEngine.init` already seeds `/quit`. The Lua callback below
    // registers a same-named entry, which the registry treats as a
    // replacement; this test asserts that the callback variant wins.
    try engine.lua.doString(
        \\_G.shadow_fired = false
        \\zag.command {
        \\  name = "quit",
        \\  fn = function() _G.shadow_fired = true end,
        \\}
    );

    const hit = engine.command_registry.lookup("/quit") orelse
        return error.TestExpectedCommand;
    try std.testing.expect(hit == .lua_callback);

    engine.invokeCallback(hit.lua_callback);
    _ = try engine.lua.getGlobal("shadow_fired");
    try std.testing.expect(engine.lua.toBoolean(-1));
    engine.lua.pop(1);
}

test "zag.command{} rejects missing fn" {
    std.testing.log_level = .err;
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    const result = engine.lua.doString(
        \\zag.command { name = "foo" }
    );
    try std.testing.expectError(error.LuaRuntime, result);
    engine.lua.pop(1);
}

test "zag.command{} rejects missing name" {
    std.testing.log_level = .err;
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    const result = engine.lua.doString(
        \\zag.command { fn = function() end }
    );
    try std.testing.expectError(error.LuaRuntime, result);
    engine.lua.pop(1);
}

test "zag.command{} re-registration unrefs the displaced callback" {
    // Probe for a ref-leak by comparing registry growth on two paths:
    //  (a) N distinct slash names => N fresh allocations, registry grows by ~N.
    //  (b) N overwrites of the same slash name => each overwrite MUST
    //      unref the displaced ref so the freelist recycles its slot,
    //      keeping registry growth roughly flat and much smaller than N.
    // If `zagCommandFn` forgets to unref the displaced slot, path (b)
    // grows the same way path (a) does, which this test rejects.
    const N: usize = 16;

    // Path (a): N fresh names, measure how the registry grows per
    // independent Lua callback. Scope to its own engine so the two
    // probes don't cross-contaminate.
    const growth_fresh: u32 = blk: {
        var engine = try LuaEngine.init(std.testing.allocator);
        defer engine.deinit();
        engine.storeSelfPointer();

        try engine.lua.doString("_G.fresh_seed = 0");
        const baseline: u32 = @intCast(engine.lua.rawLen(zlua.registry_index));

        var i: usize = 0;
        while (i < N) : (i += 1) {
            var buf: [128]u8 = undefined;
            const src = try std.fmt.bufPrintZ(
                &buf,
                "zag.command {{ name = \"probe{d}\", fn = function() end }}",
                .{i},
            );
            try engine.lua.doString(src);
        }
        const after: u32 = @intCast(engine.lua.rawLen(zlua.registry_index));
        break :blk after - baseline;
    };

    // Path (b): N overwrites of the same slash name. If unref works the
    // freelist recycles the slot each iteration; registry stays flat
    // (modulo whatever doString itself may park).
    const growth_overwrite: u32 = blk: {
        var engine = try LuaEngine.init(std.testing.allocator);
        defer engine.deinit();
        engine.storeSelfPointer();

        try engine.lua.doString(
            \\zag.command { name = "probe", fn = function() end }
        );
        const baseline: u32 = @intCast(engine.lua.rawLen(zlua.registry_index));

        var i: usize = 0;
        while (i < N) : (i += 1) {
            try engine.lua.doString(
                \\zag.command { name = "probe", fn = function() end }
            );
        }
        const after: u32 = @intCast(engine.lua.rawLen(zlua.registry_index));
        break :blk after - baseline;
    };

    // The overwrite path must recycle slots. We allow a small slack for
    // Lua-VM bookkeeping (compiled chunks interned during doString) but
    // demand it is far below the linear fresh-allocation path.
    try std.testing.expect(growth_fresh >= N);
    try std.testing.expect(growth_overwrite < growth_fresh / 2);
}

test "LuaEngine init populates keymap defaults" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();

    const registry = engine.keymapRegistry();
    try std.testing.expect(
        registry.lookup(.normal, .{ .key = .{ .char = 'h' }, .modifiers = .{} }, null).? == .focus_left,
    );
    try std.testing.expect(
        registry.lookup(.normal, .{ .key = .{ .char = 'i' }, .modifiers = .{} }, null).? == .enter_insert_mode,
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

test "zag.set_thinking_effort stores the runtime level" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString("zag.set_thinking_effort(\"high\")");

    try std.testing.expect(engine.currentThinkingEffort() != null);
    try std.testing.expectEqualStrings("high", engine.currentThinkingEffort().?);
}

test "zag.set_thinking_effort accepts nil to clear the runtime level" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.set_thinking_effort("medium")
        \\zag.set_thinking_effort(nil)
    );
    try std.testing.expect(engine.currentThinkingEffort() == null);
}

test "zag.set_thinking_effort rejects unknown levels" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try std.testing.expectError(
        error.LuaRuntime,
        engine.lua.doString("zag.set_thinking_effort(\"extreme\")"),
    );
}

test "zag.set_thinking_effort replaces prior value without leaking" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.set_thinking_effort("low")
        \\zag.set_thinking_effort("high")
    );
    try std.testing.expectEqualStrings("high", engine.currentThinkingEffort().?);
}

test "zag.provider{}: full x_api_key declaration registers the endpoint" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.provider {
        \\  name = "anthropic",
        \\  url  = "https://api.anthropic.com/v1/messages",
        \\  wire = "anthropic",
        \\  auth = { kind = "x_api_key" },
        \\  headers = { { name = "anthropic-version", value = "2023-06-01" } },
        \\  default_model = "claude-sonnet-4-20250514",
        \\  models = {
        \\    {
        \\      id = "claude-sonnet-4-20250514",
        \\      context_window = 200000, max_output_tokens = 8192,
        \\      input_per_mtok = 3.0, output_per_mtok = 15.0,
        \\      cache_write_per_mtok = 3.75, cache_read_per_mtok = 0.30,
        \\    },
        \\  },
        \\}
    );
    const ep = engine.providers_registry.find("anthropic") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("https://api.anthropic.com/v1/messages", ep.url);
    try std.testing.expectEqual(llm.Serializer.anthropic, ep.serializer);
    try std.testing.expectEqual(llm.Endpoint.Auth.x_api_key, ep.auth);
    try std.testing.expectEqualStrings("claude-sonnet-4-20250514", ep.default_model);
    try std.testing.expectEqual(@as(usize, 1), ep.models.len);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), ep.models[0].input_per_mtok, 0.001);
    try std.testing.expectEqual(@as(u32, 200000), ep.models[0].context_window);
}

test "zag.provider{}: models parse label and recommended" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.provider{
        \\  name = "prov",
        \\  url = "https://example.com",
        \\  wire = "anthropic",
        \\  auth = { kind = "none" },
        \\  default_model = "m1",
        \\  models = {
        \\    { id = "m1", label = "One", recommended = true, context_window = 10, max_output_tokens = 5, input_per_mtok = 1.0, output_per_mtok = 2.0 },
        \\    { id = "m2", context_window = 20, max_output_tokens = 10, input_per_mtok = 0.5, output_per_mtok = 1.5 },
        \\  },
        \\}
    );
    const ep = engine.providers_registry.find("prov") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), ep.models.len);
    try std.testing.expectEqualStrings("One", ep.models[0].label.?);
    try std.testing.expectEqual(true, ep.models[0].recommended);
    try std.testing.expectEqual(@as(?[]const u8, null), ep.models[1].label);
    try std.testing.expectEqual(false, ep.models[1].recommended);
}

test "zag.provider{}: oauth declaration materialises into .oauth variant with full spec" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.provider {
        \\  name = "openai-oauth",
        \\  url = "https://chatgpt.com/backend-api/codex/responses",
        \\  wire = "chatgpt",
        \\  auth = {
        \\    kind = "oauth",
        \\    issuer = "https://auth.openai.com/oauth/authorize",
        \\    token_url = "https://auth.openai.com/oauth/token",
        \\    client_id = "app_EMoamEEZ73f0CkXaXp7hrann",
        \\    scopes = "openid profile email offline_access",
        \\    redirect_port = 1455,
        \\    account_id_claim_path = "https:~1~1api.openai.com~1auth/chatgpt_account_id",
        \\    extra_authorize_params = {
        \\      { name = "codex_cli_simplified_flow", value = "true" },
        \\    },
        \\    inject = {
        \\      header = "Authorization",
        \\      prefix = "Bearer ",
        \\      extra_headers = {},
        \\      use_account_id = true,
        \\      account_id_header = "chatgpt-account-id",
        \\    },
        \\  },
        \\  default_model = "gpt-5-codex",
        \\  models = { { id = "gpt-5-codex" } },
        \\}
    );
    const ep = engine.providers_registry.find("openai-oauth") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(std.meta.Tag(llm.Endpoint.Auth).oauth, std.meta.activeTag(ep.auth));
    const spec = ep.auth.oauth;
    try std.testing.expectEqualStrings("https://auth.openai.com/oauth/authorize", spec.issuer);
    try std.testing.expectEqualStrings("https://auth.openai.com/oauth/token", spec.token_url);
    try std.testing.expectEqualStrings("app_EMoamEEZ73f0CkXaXp7hrann", spec.client_id);
    try std.testing.expectEqualStrings("openid profile email offline_access", spec.scopes);
    try std.testing.expectEqual(@as(u16, 1455), spec.redirect_port);
    try std.testing.expectEqualStrings(
        "https:~1~1api.openai.com~1auth/chatgpt_account_id",
        spec.account_id_claim_path.?,
    );
    try std.testing.expectEqual(@as(usize, 1), spec.extra_authorize_params.len);
    try std.testing.expectEqualStrings("codex_cli_simplified_flow", spec.extra_authorize_params[0].name);
    try std.testing.expectEqualStrings("Authorization", spec.inject.header);
    try std.testing.expectEqualStrings("Bearer ", spec.inject.prefix);
    try std.testing.expect(spec.inject.use_account_id);
    try std.testing.expectEqualStrings("chatgpt-account-id", spec.inject.account_id_header);
}

test "zag.provider{}: custom oauth provider exposes spec fields usable as LoginOptions" {
    // Integration: a fresh Lua-declared OAuth provider (not a builtin)
    // must round-trip every field that `runLoginCommand` / the wizard's
    // OAuth dispatch pull into `oauth.LoginOptions`. No HTTP is exercised;
    // this test pins
    // the data flow (Lua table → Endpoint.auth.oauth → caller's spec view).
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.provider {
        \\  name = "custom-oauth",
        \\  url = "https://api.example.test/chat",
        \\  wire = "openai",
        \\  auth = {
        \\    kind = "oauth",
        \\    issuer = "https://idp.example/authorize",
        \\    token_url = "https://idp.example/token",
        \\    client_id = "client-abc",
        \\    scopes = "openid email offline",
        \\    redirect_port = 8123,
        \\    extra_authorize_params = {
        \\      { name = "audience", value = "example-api" },
        \\    },
        \\    inject = {
        \\      header = "Authorization",
        \\      prefix = "Bearer ",
        \\      extra_headers = { { name = "x-client", value = "zag" } },
        \\      use_account_id = false,
        \\      account_id_header = "",
        \\    },
        \\  },
        \\  default_model = "custom-oauth/m",
        \\  models = {},
        \\}
    );

    const ep = engine.providers_registry.find("custom-oauth") orelse return error.TestUnexpectedResult;
    const spec = switch (ep.auth) {
        .oauth => |s| s,
        else => return error.TestUnexpectedResult,
    };

    // Fields that `oauth.LoginOptions` consumes verbatim.
    try std.testing.expectEqualStrings("https://idp.example/authorize", spec.issuer);
    try std.testing.expectEqualStrings("https://idp.example/token", spec.token_url);
    try std.testing.expectEqualStrings("client-abc", spec.client_id);
    try std.testing.expectEqualStrings("openid email offline", spec.scopes);
    try std.testing.expectEqual(@as(u16, 8123), spec.redirect_port);
    try std.testing.expectEqual(@as(?[]const u8, null), spec.account_id_claim_path);
    try std.testing.expectEqual(@as(usize, 1), spec.extra_authorize_params.len);
    try std.testing.expectEqualStrings("audience", spec.extra_authorize_params[0].name);
    try std.testing.expectEqualStrings("example-api", spec.extra_authorize_params[0].value);

    // Fields that `llm/http.zig buildHeaders` consumes via applyOAuthInjection.
    try std.testing.expectEqualStrings("Authorization", spec.inject.header);
    try std.testing.expectEqualStrings("Bearer ", spec.inject.prefix);
    try std.testing.expectEqual(@as(usize, 1), spec.inject.extra_headers.len);
    try std.testing.expectEqualStrings("x-client", spec.inject.extra_headers[0].name);
    try std.testing.expectEqualStrings("zag", spec.inject.extra_headers[0].value);
    try std.testing.expect(!spec.inject.use_account_id);
    try std.testing.expectEqualStrings("", spec.inject.account_id_header);
}

test "zag.provider{}: missing required url field surfaces LuaRuntime" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try std.testing.expectError(
        error.LuaRuntime,
        engine.lua.doString(
            \\zag.provider { name = "x", wire = "openai", auth = { kind = "bearer" }, default_model = "m" }
        ),
    );
}

test "zag.provider{}: unknown wire surfaces LuaRuntime" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try std.testing.expectError(
        error.LuaRuntime,
        engine.lua.doString(
            \\zag.provider {
            \\  name = "x", url = "https://x", wire = "not-a-wire",
            \\  auth = { kind = "bearer" }, default_model = "m"
            \\}
        ),
    );
}

test "zag.provider{}: unknown auth kind surfaces LuaRuntime" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try std.testing.expectError(
        error.LuaRuntime,
        engine.lua.doString(
            \\zag.provider {
            \\  name = "x", url = "https://x", wire = "openai",
            \\  auth = { kind = "bogus" }, default_model = "m"
            \\}
        ),
    );
}

test "zag.provider{}: overrides existing builtin with same name" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.provider {
        \\  name = "anthropic",
        \\  url = "https://custom",
        \\  wire = "anthropic",
        \\  auth = { kind = "x_api_key" },
        \\  default_model = "my-model",
        \\}
    );
    const ep = engine.providers_registry.find("anthropic").?;
    try std.testing.expectEqualStrings("https://custom", ep.url);
    try std.testing.expectEqualStrings("my-model", ep.default_model);
}

test "zag.provider{}: headers map-form parses both entries" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.provider {
        \\  name = "mapform",
        \\  url = "https://x",
        \\  wire = "openai",
        \\  auth = { kind = "bearer" },
        \\  headers = { ["X-A"] = "a", ["X-B"] = "b" },
        \\  default_model = "m",
        \\}
    );
    const ep = engine.providers_registry.find("mapform").?;
    try std.testing.expectEqual(@as(usize, 2), ep.headers.len);
}

test "zag.provider{}: requires a name field" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try std.testing.expectError(
        error.LuaRuntime,
        engine.lua.doString("zag.provider { }"),
    );
}

test "zag.provider{}: reasoning fields default to medium/auto/medium when omitted" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.provider {
        \\  name = "p-default",
        \\  url = "https://example.com",
        \\  wire = "chatgpt",
        \\  auth = { kind = "none" },
        \\  default_model = "m1",
        \\  models = {},
        \\}
    );
    const ep = engine.providers_registry.find("p-default") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("medium", ep.reasoning.effort);
    try std.testing.expectEqualStrings("auto", ep.reasoning.summary);
    try std.testing.expectEqualStrings("medium", ep.reasoning.verbosity);
}

test "zag.provider{}: reasoning_effort/summary/verbosity round-trip onto the endpoint" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.provider {
        \\  name = "p-tuned",
        \\  url = "https://example.com",
        \\  wire = "chatgpt",
        \\  auth = { kind = "none" },
        \\  default_model = "m1",
        \\  models = {},
        \\  reasoning_effort = "high",
        \\  reasoning_summary = "none",
        \\  verbosity = "low",
        \\}
    );
    const ep = engine.providers_registry.find("p-tuned") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("high", ep.reasoning.effort);
    try std.testing.expectEqualStrings("none", ep.reasoning.summary);
    try std.testing.expectEqualStrings("low", ep.reasoning.verbosity);
}

test "zag.provider{}: invalid reasoning_effort surfaces LuaRuntime" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try std.testing.expectError(
        error.LuaRuntime,
        engine.lua.doString(
            \\zag.provider {
            \\  name = "bad",
            \\  url = "https://example.com",
            \\  wire = "chatgpt",
            \\  auth = { kind = "none" },
            \\  default_model = "m",
            \\  models = {},
            \\  reasoning_effort = "ludicrous",
            \\}
        ),
    );
}

test "zag.provider{}: invalid reasoning_summary surfaces LuaRuntime" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try std.testing.expectError(
        error.LuaRuntime,
        engine.lua.doString(
            \\zag.provider {
            \\  name = "bad",
            \\  url = "https://example.com",
            \\  wire = "chatgpt",
            \\  auth = { kind = "none" },
            \\  default_model = "m",
            \\  models = {},
            \\  reasoning_summary = "verbose",
            \\}
        ),
    );
}

test "zag.provider{}: invalid verbosity surfaces LuaRuntime" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try std.testing.expectError(
        error.LuaRuntime,
        engine.lua.doString(
            \\zag.provider {
            \\  name = "bad",
            \\  url = "https://example.com",
            \\  wire = "chatgpt",
            \\  auth = { kind = "none" },
            \\  default_model = "m",
            \\  models = {},
            \\  verbosity = "extreme",
            \\}
        ),
    );
}

test "zag.provider reads reasoning_response_fields and reasoning_echo_field" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.provider({
        \\  name = "moonshot",
        \\  url = "https://api.moonshot.ai/v1/chat/completions",
        \\  wire = "openai",
        \\  auth = { kind = "bearer" },
        \\  default_model = "kimi-k2.6",
        \\  models = {{ id = "kimi-k2.6" }},
        \\  reasoning_response_fields = { "reasoning_content", "reasoning" },
        \\  reasoning_echo_field = "reasoning_content",
        \\})
    );

    const ep = engine.providers_registry.find("moonshot") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), ep.reasoning.response_fields.len);
    try std.testing.expectEqualStrings("reasoning_content", ep.reasoning.response_fields[0]);
    try std.testing.expectEqualStrings("reasoning", ep.reasoning.response_fields[1]);
    try std.testing.expect(ep.reasoning.echo_field != null);
    try std.testing.expectEqualStrings("reasoning_content", ep.reasoning.echo_field.?);
}

test "zag.provider reads reasoning_effort_field" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.provider({
        \\  name = "moonshot",
        \\  url = "https://api.moonshot.ai/v1/chat/completions",
        \\  wire = "openai",
        \\  auth = { kind = "bearer" },
        \\  default_model = "kimi-k2.6",
        \\  models = {{ id = "kimi-k2.6" }},
        \\  reasoning_effort_field = "reasoning_effort",
        \\})
    );

    const ep = engine.providers_registry.find("moonshot") orelse return error.TestUnexpectedResult;
    try std.testing.expect(ep.reasoning.effort_request_field != null);
    try std.testing.expectEqualStrings("reasoning_effort", ep.reasoning.effort_request_field.?);
}

test "zag.provider defaults reasoning_effort_field to null" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.provider({
        \\  name = "openai-no-effort",
        \\  url = "https://api.openai.com/v1/chat/completions",
        \\  wire = "openai",
        \\  auth = { kind = "bearer" },
        \\  default_model = "gpt-4o",
        \\  models = {{ id = "gpt-4o" }},
        \\})
    );

    const ep = engine.providers_registry.find("openai-no-effort") orelse return error.TestUnexpectedResult;
    try std.testing.expect(ep.reasoning.effort_request_field == null);
}

test "zag.provider defaults reasoning_response_fields to empty and echo_field to null" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.provider({
        \\  name = "openai-default",
        \\  url = "https://api.openai.com/v1/chat/completions",
        \\  wire = "openai",
        \\  auth = { kind = "bearer" },
        \\  default_model = "gpt-4o",
        \\  models = {{ id = "gpt-4o" }},
        \\})
    );

    const ep = engine.providers_registry.find("openai-default") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), ep.reasoning.response_fields.len);
    try std.testing.expect(ep.reasoning.echo_field == null);
}

test "readStringArray parses Lua array of strings" {
    const allocator = std.testing.allocator;

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();

    try engine.lua.doString(
        \\return { "reasoning_content", "reasoning", "reasoning_text" }
    );
    const top = engine.lua.absIndex(-1);
    defer engine.lua.pop(1);

    // Read into a fake outer table by faking the outer field with a
    // direct call into the helper. The helper expects a table_idx
    // pointing at the OUTER table that contains a field of name `name`,
    // so wrap once: outer = { fields = {...} }.
    try engine.lua.doString(
        \\return { fields = { "reasoning_content", "reasoning", "reasoning_text" } }
    );
    defer engine.lua.pop(1);
    const outer = engine.lua.absIndex(-1);

    const result = try LuaEngine.readStringArray(engine.lua, outer, "fields", allocator);
    defer {
        for (result) |s| allocator.free(s);
        allocator.free(result);
    }

    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("reasoning_content", result[0]);
    try std.testing.expectEqualStrings("reasoning", result[1]);
    try std.testing.expectEqualStrings("reasoning_text", result[2]);

    _ = top;
}

test "readStringArray returns empty slice when field absent" {
    const allocator = std.testing.allocator;

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();

    try engine.lua.doString("return { other = 1 }");
    defer engine.lua.pop(1);
    const outer = engine.lua.absIndex(-1);

    const result = try LuaEngine.readStringArray(engine.lua, outer, "fields", allocator);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 0), result.len);
}

test "readStringArray rejects non-string entry" {
    const allocator = std.testing.allocator;

    var engine = try LuaEngine.init(allocator);
    defer engine.deinit();

    try engine.lua.doString("return { fields = { \"ok\", 42 } }");
    defer engine.lua.pop(1);
    const outer = engine.lua.absIndex(-1);

    try std.testing.expectError(error.LuaError, LuaEngine.readStringArray(engine.lua, outer, "fields", allocator));
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

test "readStringField: required string returns duped slice" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString("t = { name = \"hello\" }");
    _ = try engine.lua.getGlobal("t");
    defer engine.lua.pop(1);

    const got = try LuaEngine.readStringField(engine.lua, -1, "name", .required, std.testing.allocator);
    defer std.testing.allocator.free(got.?);
    try std.testing.expectEqualStrings("hello", got.?);
}

test "readStringField: missing field in required mode returns error.LuaError" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString("t = {}");
    _ = try engine.lua.getGlobal("t");
    defer engine.lua.pop(1);

    try std.testing.expectError(
        error.LuaError,
        LuaEngine.readStringField(engine.lua, -1, "name", .required, std.testing.allocator),
    );
}

test "readStringField: missing field in optional mode returns null" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString("t = {}");
    _ = try engine.lua.getGlobal("t");
    defer engine.lua.pop(1);

    const got = try LuaEngine.readStringField(engine.lua, -1, "name", .optional, std.testing.allocator);
    try std.testing.expect(got == null);
}

test "readStringField: non-string field rejected" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString("t = { name = 42 }");
    _ = try engine.lua.getGlobal("t");
    defer engine.lua.pop(1);

    try std.testing.expectError(
        error.LuaError,
        LuaEngine.readStringField(engine.lua, -1, "name", .required, std.testing.allocator),
    );
}

test "readHeaderList: array-of-pairs form preserves order" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\t = { headers = {
        \\    { name = "a", value = "1" },
        \\    { name = "b", value = "2" },
        \\} }
    );
    _ = try engine.lua.getGlobal("t");
    defer engine.lua.pop(1);

    const headers = try LuaEngine.readHeaderList(engine.lua, -1, "headers", std.testing.allocator);
    defer {
        for (headers) |h| {
            std.testing.allocator.free(h.name);
            std.testing.allocator.free(h.value);
        }
        std.testing.allocator.free(headers);
    }
    try std.testing.expectEqual(@as(usize, 2), headers.len);
    try std.testing.expectEqualStrings("a", headers[0].name);
    try std.testing.expectEqualStrings("1", headers[0].value);
    try std.testing.expectEqualStrings("b", headers[1].name);
    try std.testing.expectEqualStrings("2", headers[1].value);
}

test "readHeaderList: map-of-strings form parses both entries" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\t = { headers = {
        \\    ["Header-A"] = "1",
        \\    ["Header-B"] = "2",
        \\} }
    );
    _ = try engine.lua.getGlobal("t");
    defer engine.lua.pop(1);

    const headers = try LuaEngine.readHeaderList(engine.lua, -1, "headers", std.testing.allocator);
    defer {
        for (headers) |h| {
            std.testing.allocator.free(h.name);
            std.testing.allocator.free(h.value);
        }
        std.testing.allocator.free(headers);
    }
    try std.testing.expectEqual(@as(usize, 2), headers.len);

    // Lua 5.4 string-keyed iteration order is implementation-defined.
    var saw_a = false;
    var saw_b = false;
    for (headers) |h| {
        if (std.mem.eql(u8, h.name, "Header-A")) {
            try std.testing.expectEqualStrings("1", h.value);
            saw_a = true;
        }
        if (std.mem.eql(u8, h.name, "Header-B")) {
            try std.testing.expectEqualStrings("2", h.value);
            saw_b = true;
        }
    }
    try std.testing.expect(saw_a and saw_b);
}

test "readHeaderList: absent field returns empty slice" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString("t = {}");
    _ = try engine.lua.getGlobal("t");
    defer engine.lua.pop(1);

    const headers = try LuaEngine.readHeaderList(engine.lua, -1, "headers", std.testing.allocator);
    defer std.testing.allocator.free(headers);
    try std.testing.expectEqual(@as(usize, 0), headers.len);
}

test "require('zag.providers.anthropic') resolves from embedded stdlib" {
    if (sandbox_enabled) return error.SkipZigTest;

    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    // The stdlib file calls `zag.provider{...}` for its side effect and
    // returns nothing. require() should complete without error and the
    // result should be the Lua 5.4 default (boolean true) for modules
    // that don't return anything.
    try engine.lua.doString("ok = require('zag.providers.anthropic')");
    _ = try engine.lua.getGlobal("ok");
    defer engine.lua.pop(1);
    try std.testing.expect(engine.lua.toBoolean(-1));
}

test "user dir file shadows embedded stdlib entry" {
    if (sandbox_enabled) return error.SkipZigTest;

    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    // Build a temp dir with zag/providers/anthropic.lua returning a sentinel.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("zag/providers");
    try tmp.dir.writeFile(.{
        .sub_path = "zag/providers/anthropic.lua",
        .data = "return 'from-user-dir'",
    });

    var rbuf: [std.fs.max_path_bytes]u8 = undefined;
    const base = try tmp.dir.realpath(".", &rbuf);

    // Redirect _ZAG_LOADER.user_dir to the temp dir. The searcher closure
    // reads ctx.user_dir on every call, so this takes effect immediately.
    _ = engine.lua.pushString(base);
    engine.lua.setGlobal("_tmp_user_dir");
    try engine.lua.doString("_ZAG_LOADER.user_dir = _tmp_user_dir");

    try engine.lua.doString("shadow = require('zag.providers.anthropic')");
    _ = try engine.lua.getGlobal("shadow");
    defer engine.lua.pop(1);
    const loaded = try engine.lua.toString(-1);
    try std.testing.expectEqualStrings("from-user-dir", loaded);
}

test "require falls through to embedded when user dir file missing" {
    if (sandbox_enabled) return error.SkipZigTest;

    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    // Point user_dir at an empty tmp; the user searcher finds nothing there
    // and the embedded searcher serves the stdlib entry.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var rbuf: [std.fs.max_path_bytes]u8 = undefined;
    const base = try tmp.dir.realpath(".", &rbuf);
    _ = engine.lua.pushString(base);
    engine.lua.setGlobal("_tmp_user_dir");
    try engine.lua.doString("_ZAG_LOADER.user_dir = _tmp_user_dir");

    try engine.lua.doString("ok = require('zag.providers.openai')");
    _ = try engine.lua.getGlobal("ok");
    defer engine.lua.pop(1);
    try std.testing.expect(engine.lua.toBoolean(-1));
}

test "require raises a clean module-not-found error for unknown names" {
    if (sandbox_enabled) return error.SkipZigTest;

    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    // No embedded entry; user dir empty/absent. require must error.
    const result = engine.lua.doString("require('zag.providers.does_not_exist')");
    try std.testing.expectError(error.LuaRuntime, result);
    // Drain the error message Lua pushed so later tests start with a clean stack.
    engine.lua.pop(1);
}

test "stdlib: require(zag.providers.anthropic) registers anthropic" {
    if (sandbox_enabled) return error.SkipZigTest;

    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString("require('zag.providers.anthropic')");

    const ep = engine.providers_registry.find("anthropic") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("https://api.anthropic.com/v1/messages", ep.url);
    try std.testing.expectEqualStrings("claude-sonnet-4-20250514", ep.default_model);
    try std.testing.expectEqual(llm.Serializer.anthropic, ep.serializer);
    try std.testing.expect(ep.models.len >= 2);
    try std.testing.expectEqual(true, ep.models[0].recommended);
    try std.testing.expect(std.meta.activeTag(ep.auth) == .x_api_key);
    try std.testing.expectEqual(@as(usize, 1), ep.headers.len);
    try std.testing.expectEqualStrings("anthropic-version", ep.headers[0].name);
    try std.testing.expectEqualStrings("2023-06-01", ep.headers[0].value);
}

test "stdlib: require(zag.providers.openai) registers openai" {
    if (sandbox_enabled) return error.SkipZigTest;

    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString("require('zag.providers.openai')");

    const ep = engine.providers_registry.find("openai") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("https://api.openai.com/v1/chat/completions", ep.url);
    try std.testing.expectEqualStrings("gpt-4o", ep.default_model);
    try std.testing.expectEqual(llm.Serializer.openai, ep.serializer);
    try std.testing.expect(ep.models.len >= 2);
    try std.testing.expectEqual(true, ep.models[0].recommended);
    try std.testing.expect(std.meta.activeTag(ep.auth) == .bearer);
    // cache_write_per_mtok is absent in the Lua file: readNullableFloat
    // must leave it null rather than defaulting to 0.
    try std.testing.expect(ep.models[0].cache_write_per_mtok == null);
}

test "stdlib: require(zag.providers.openrouter) registers openrouter" {
    if (sandbox_enabled) return error.SkipZigTest;

    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString("require('zag.providers.openrouter')");

    const ep = engine.providers_registry.find("openrouter") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("https://openrouter.ai/api/v1/chat/completions", ep.url);
    try std.testing.expectEqualStrings("anthropic/claude-sonnet-4", ep.default_model);
    try std.testing.expectEqual(llm.Serializer.openai, ep.serializer);
    try std.testing.expect(ep.models.len >= 1);
    try std.testing.expectEqual(true, ep.models[0].recommended);
    try std.testing.expect(std.meta.activeTag(ep.auth) == .bearer);
    try std.testing.expectEqual(@as(usize, 1), ep.headers.len);
    try std.testing.expectEqualStrings("X-OpenRouter-Title", ep.headers[0].name);
}

test "stdlib: require(zag.providers.groq) registers groq" {
    if (sandbox_enabled) return error.SkipZigTest;

    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString("require('zag.providers.groq')");

    const ep = engine.providers_registry.find("groq") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("https://api.groq.com/openai/v1/chat/completions", ep.url);
    try std.testing.expectEqualStrings("llama-3.3-70b-versatile", ep.default_model);
    try std.testing.expectEqual(llm.Serializer.openai, ep.serializer);
    try std.testing.expect(ep.models.len >= 1);
    try std.testing.expectEqual(true, ep.models[0].recommended);
    try std.testing.expect(std.meta.activeTag(ep.auth) == .bearer);
}

test "stdlib: require(zag.providers.ollama) registers ollama" {
    if (sandbox_enabled) return error.SkipZigTest;

    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString("require('zag.providers.ollama')");

    const ep = engine.providers_registry.find("ollama") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("http://localhost:11434/v1/chat/completions", ep.url);
    try std.testing.expectEqualStrings("llama3", ep.default_model);
    try std.testing.expectEqual(llm.Serializer.openai, ep.serializer);
    try std.testing.expect(ep.models.len >= 1);
    try std.testing.expectEqual(true, ep.models[0].recommended);
    try std.testing.expect(std.meta.activeTag(ep.auth) == .none);
}

test "stdlib: require(zag.providers.openai-oauth) registers openai-oauth with Codex spec" {
    if (sandbox_enabled) return error.SkipZigTest;

    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString("require('zag.providers.openai-oauth')");

    const ep = engine.providers_registry.find("openai-oauth") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("https://chatgpt.com/backend-api/codex/responses", ep.url);
    try std.testing.expectEqual(llm.Serializer.chatgpt, ep.serializer);
    switch (ep.auth) {
        .oauth => |spec| {
            try std.testing.expectEqualStrings("app_EMoamEEZ73f0CkXaXp7hrann", spec.client_id);
            try std.testing.expectEqual(@as(u16, 1455), spec.redirect_port);
            try std.testing.expect(spec.account_id_claim_path != null);
            try std.testing.expectEqualStrings("https:~1~1api.openai.com~1auth/chatgpt_account_id", spec.account_id_claim_path.?);
            try std.testing.expect(spec.inject.use_account_id);
            try std.testing.expectEqualStrings("chatgpt-account-id", spec.inject.account_id_header);
            try std.testing.expectEqual(@as(usize, 2), spec.extra_authorize_params.len);
        },
        else => return error.TestUnexpectedResult,
    }

    try std.testing.expect(ep.models.len >= 5);
    try std.testing.expectEqualStrings("gpt-5.2", ep.models[0].id);
    try std.testing.expectEqual(true, ep.models[0].recommended);

    var found_openai_beta = false;
    var found_originator = false;
    var found_user_agent = false;
    for (ep.headers) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "OpenAI-Beta")) found_openai_beta = true;
        if (std.ascii.eqlIgnoreCase(h.name, "originator")) found_originator = true;
        if (std.ascii.eqlIgnoreCase(h.name, "User-Agent")) found_user_agent = true;
    }
    try std.testing.expect(found_openai_beta);
    try std.testing.expect(found_originator);
    try std.testing.expect(found_user_agent);
}

test "stdlib: require(zag.providers.anthropic-oauth) registers Claude Max spec" {
    if (sandbox_enabled) return error.SkipZigTest;

    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString("require('zag.providers.anthropic-oauth')");

    const ep = engine.providers_registry.find("anthropic-oauth") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("https://api.anthropic.com/v1/messages", ep.url);
    try std.testing.expectEqual(llm.Serializer.anthropic, ep.serializer);
    switch (ep.auth) {
        .oauth => |spec| {
            try std.testing.expectEqual(@as(u16, 53692), spec.redirect_port);
            try std.testing.expect(spec.account_id_claim_path == null);
            try std.testing.expect(!spec.inject.use_account_id);
            try std.testing.expectEqual(@as(usize, 2), spec.inject.extra_headers.len);
            var saw_beta = false;
            for (spec.inject.extra_headers) |h| {
                if (std.mem.eql(u8, h.name, "anthropic-beta")) {
                    try std.testing.expectEqualStrings("oauth-2025-04-20,claude-code-20250219", h.value);
                    saw_beta = true;
                }
            }
            try std.testing.expect(saw_beta);
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(ep.models.len >= 2);
    try std.testing.expectEqual(true, ep.models[0].recommended);
}

test "zag.buffer.create returns a resolvable handle" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    var buffer_registry = BufferRegistry.init(alloc);
    defer buffer_registry.deinit();
    engine.buffer_registry = &buffer_registry;

    try engine.lua.doString(
        \\_G.handle = zag.buffer.create { kind = "scratch", name = "picker" }
    );
    _ = try engine.lua.getGlobal("handle");
    defer engine.lua.pop(1);
    const handle_str = try engine.lua.toString(-1);
    const handle = try BufferRegistry.parseId(handle_str);
    const entry = try buffer_registry.resolve(handle);
    try std.testing.expect(entry == .scratch);
    try std.testing.expectEqualStrings("picker", entry.scratch.name);
}

test "zag.buffer.create rejects unknown kinds" {
    std.testing.log_level = .err;
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    var buffer_registry = BufferRegistry.init(alloc);
    defer buffer_registry.deinit();
    engine.buffer_registry = &buffer_registry;

    const result = engine.lua.doString(
        \\zag.buffer.create { kind = "not-a-real-kind" }
    );
    try std.testing.expectError(error.LuaRuntime, result);
    engine.lua.pop(1);
}

test "zag.buffer.set_lines + get_lines + line_count round trip" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    var buffer_registry = BufferRegistry.init(alloc);
    defer buffer_registry.deinit();
    engine.buffer_registry = &buffer_registry;

    try engine.lua.doString(
        \\local b = zag.buffer.create { kind = "scratch", name = "t" }
        \\zag.buffer.set_lines(b, { "alpha", "beta", "gamma" })
        \\_G.n = zag.buffer.line_count(b)
        \\local lines = zag.buffer.get_lines(b)
        \\_G.second = lines[2]
    );
    _ = try engine.lua.getGlobal("n");
    try std.testing.expectEqual(@as(i64, 3), try engine.lua.toInteger(-1));
    engine.lua.pop(1);
    _ = try engine.lua.getGlobal("second");
    try std.testing.expectEqualStrings("beta", try engine.lua.toString(-1));
    engine.lua.pop(1);
}

test "zag.buffer.cursor_row is 1-indexed and set_cursor_row round trips" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    var buffer_registry = BufferRegistry.init(alloc);
    defer buffer_registry.deinit();
    engine.buffer_registry = &buffer_registry;

    try engine.lua.doString(
        \\local b = zag.buffer.create { kind = "scratch", name = "t" }
        \\zag.buffer.set_lines(b, { "one", "two", "three" })
        \\_G.initial = zag.buffer.cursor_row(b)
        \\zag.buffer.set_cursor_row(b, 2)
        \\_G.after = zag.buffer.cursor_row(b)
        \\_G.line = zag.buffer.current_line(b)
    );
    _ = try engine.lua.getGlobal("initial");
    try std.testing.expectEqual(@as(i64, 1), try engine.lua.toInteger(-1));
    engine.lua.pop(1);
    _ = try engine.lua.getGlobal("after");
    try std.testing.expectEqual(@as(i64, 2), try engine.lua.toInteger(-1));
    engine.lua.pop(1);
    _ = try engine.lua.getGlobal("line");
    try std.testing.expectEqualStrings("two", try engine.lua.toString(-1));
    engine.lua.pop(1);
}

test "zag.buffer.current_line returns nil on empty buffer" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    var buffer_registry = BufferRegistry.init(alloc);
    defer buffer_registry.deinit();
    engine.buffer_registry = &buffer_registry;

    try engine.lua.doString(
        \\local b = zag.buffer.create { kind = "scratch" }
        \\_G.is_nil = zag.buffer.current_line(b) == nil
    );
    _ = try engine.lua.getGlobal("is_nil");
    try std.testing.expect(engine.lua.toBoolean(-1));
    engine.lua.pop(1);
}

test "zag.buffer.delete releases the slot and later lookups fail" {
    std.testing.log_level = .err;
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    var buffer_registry = BufferRegistry.init(alloc);
    defer buffer_registry.deinit();
    engine.buffer_registry = &buffer_registry;

    try engine.lua.doString(
        \\_G.handle = zag.buffer.create { kind = "scratch" }
        \\zag.buffer.delete(_G.handle)
    );
    _ = try engine.lua.getGlobal("handle");
    const handle_str = try engine.lua.toString(-1);
    const handle = try BufferRegistry.parseId(handle_str);
    try std.testing.expectError(BufferRegistry.Error.StaleBuffer, buffer_registry.resolve(handle));
    engine.lua.pop(1);

    // Re-using the same handle on any later zag.buffer.* call surfaces
    // as a Lua error; the registry layer caught the dangling reference.
    const result = engine.lua.doString(
        \\zag.buffer.line_count(_G.handle)
    );
    try std.testing.expectError(error.LuaRuntime, result);
    engine.lua.pop(1);
}

// 1x1 red PNG, 69 bytes. Duplicated from src/png_decode.zig so these
// tests stay self-contained; the fixture there owns the same bytes
// for its own decode round-trip coverage.
const tiny_red_png_fixture = [_]u8{
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xDE, 0x00, 0x00, 0x00,
    0x0C, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
    0x00, 0x03, 0x01, 0x01, 0x00, 0xC9, 0xFE, 0x92, 0xEF, 0x00, 0x00, 0x00,
    0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
};

test "zag.buffer.create kind=\"graphics\" returns a resolvable graphics handle" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    var buffer_registry = BufferRegistry.init(alloc);
    defer buffer_registry.deinit();
    engine.buffer_registry = &buffer_registry;

    try engine.lua.doString(
        \\_G.handle = zag.buffer.create { kind = "graphics", name = "diagram" }
    );
    _ = try engine.lua.getGlobal("handle");
    defer engine.lua.pop(1);
    const handle_str = try engine.lua.toString(-1);
    const handle = try BufferRegistry.parseId(handle_str);
    const entry = try buffer_registry.resolve(handle);
    try std.testing.expect(entry == .graphics);
    try std.testing.expectEqualStrings("diagram", entry.graphics.name);
}

test "zag.buffer.set_png stores decoded image on a graphics handle" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    var buffer_registry = BufferRegistry.init(alloc);
    defer buffer_registry.deinit();
    engine.buffer_registry = &buffer_registry;

    // Push the PNG bytes as a Lua string global. Lua 5.4 strings are
    // binary-safe; pushString copies them out of the supplied slice.
    _ = engine.lua.pushString(&tiny_red_png_fixture);
    engine.lua.setGlobal("png_bytes");

    try engine.lua.doString(
        \\_G.handle = zag.buffer.create { kind = "graphics", name = "diagram" }
        \\zag.buffer.set_png(_G.handle, png_bytes)
    );
    _ = try engine.lua.getGlobal("handle");
    defer engine.lua.pop(1);
    const handle_str = try engine.lua.toString(-1);
    const handle = try BufferRegistry.parseId(handle_str);
    const entry = try buffer_registry.resolve(handle);
    try std.testing.expect(entry == .graphics);
    try std.testing.expect(entry.graphics.image != null);
    try std.testing.expectEqual(@as(u32, 1), entry.graphics.image.?.width);
    try std.testing.expectEqual(@as(u32, 1), entry.graphics.image.?.height);
}

test "zag.buffer.set_png rejects a scratch handle" {
    std.testing.log_level = .err;
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    var buffer_registry = BufferRegistry.init(alloc);
    defer buffer_registry.deinit();
    engine.buffer_registry = &buffer_registry;

    _ = engine.lua.pushString(&tiny_red_png_fixture);
    engine.lua.setGlobal("png_bytes");

    const result = engine.lua.doString(
        \\local b = zag.buffer.create { kind = "scratch" }
        \\zag.buffer.set_png(b, png_bytes)
    );
    try std.testing.expectError(error.LuaRuntime, result);
    engine.lua.pop(1);
}

test "zag.buffer.set_fit parses valid strings and rejects invalid ones" {
    std.testing.log_level = .err;
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    var buffer_registry = BufferRegistry.init(alloc);
    defer buffer_registry.deinit();
    engine.buffer_registry = &buffer_registry;

    try engine.lua.doString(
        \\_G.handle = zag.buffer.create { kind = "graphics", name = "diagram" }
        \\zag.buffer.set_fit(_G.handle, "contain")
        \\zag.buffer.set_fit(_G.handle, "fill")
        \\zag.buffer.set_fit(_G.handle, "actual")
    );
    _ = try engine.lua.getGlobal("handle");
    const handle_str = try engine.lua.toString(-1);
    engine.lua.pop(1);
    const handle = try BufferRegistry.parseId(handle_str);
    const entry = try buffer_registry.resolve(handle);
    try std.testing.expectEqual(GraphicsBuffer.Fit.actual, entry.graphics.fit);

    const result = engine.lua.doString(
        \\zag.buffer.set_fit(_G.handle, "zoom")
    );
    try std.testing.expectError(error.LuaRuntime, result);
    engine.lua.pop(1);
}

test "zag.buffer.set_fit rejects a scratch handle" {
    std.testing.log_level = .err;
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    var buffer_registry = BufferRegistry.init(alloc);
    defer buffer_registry.deinit();
    engine.buffer_registry = &buffer_registry;

    const result = engine.lua.doString(
        \\local b = zag.buffer.create { kind = "scratch" }
        \\zag.buffer.set_fit(b, "contain")
    );
    try std.testing.expectError(error.LuaRuntime, result);
    engine.lua.pop(1);
}

test "zag.buffer.set_row_style happy path stamps row_style on rendered line" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    var buffer_registry = BufferRegistry.init(alloc);
    defer buffer_registry.deinit();
    engine.buffer_registry = &buffer_registry;

    try engine.lua.doString(
        \\_G.handle = zag.buffer.create { kind = "scratch", name = "popup" }
        \\zag.buffer.set_lines(_G.handle, { "alpha", "beta", "gamma" })
        \\zag.buffer.set_row_style(_G.handle, 2, "selection")
    );
    _ = try engine.lua.getGlobal("handle");
    const handle_str = try engine.lua.toString(-1);
    const handle = try BufferRegistry.parseId(handle_str);
    engine.lua.pop(1);
    const entry = try buffer_registry.resolve(handle);
    const sb = entry.scratch;

    const theme = Theme.defaultTheme();
    var lines = try sb.view().getVisibleLines(alloc, alloc, &theme, 0, 10);
    defer Theme.freeStyledLines(&lines, alloc);
    try std.testing.expectEqual(@as(?Theme.HighlightSlot, .selection), lines.items[1].row_style);
    try std.testing.expectEqual(@as(?Theme.HighlightSlot, null), lines.items[0].row_style);
}

test "zag.buffer.set_row_style rejects out-of-range row" {
    std.testing.log_level = .err;
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    var buffer_registry = BufferRegistry.init(alloc);
    defer buffer_registry.deinit();
    engine.buffer_registry = &buffer_registry;

    const result = engine.lua.doString(
        \\local b = zag.buffer.create { kind = "scratch" }
        \\zag.buffer.set_lines(b, { "a", "b" })
        \\zag.buffer.set_row_style(b, 99, "selection")
    );
    try std.testing.expectError(error.LuaRuntime, result);
    engine.lua.pop(1);
}

test "zag.buffer.set_row_style rejects unknown slot" {
    std.testing.log_level = .err;
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    var buffer_registry = BufferRegistry.init(alloc);
    defer buffer_registry.deinit();
    engine.buffer_registry = &buffer_registry;

    const result = engine.lua.doString(
        \\local b = zag.buffer.create { kind = "scratch" }
        \\zag.buffer.set_lines(b, { "a" })
        \\zag.buffer.set_row_style(b, 1, "rainbow")
    );
    try std.testing.expectError(error.LuaRuntime, result);
    engine.lua.pop(1);
}

test "zag.buffer.set_row_style rejects graphics buffer" {
    std.testing.log_level = .err;
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    var buffer_registry = BufferRegistry.init(alloc);
    defer buffer_registry.deinit();
    engine.buffer_registry = &buffer_registry;

    const result = engine.lua.doString(
        \\local b = zag.buffer.create { kind = "graphics" }
        \\zag.buffer.set_row_style(b, 1, "selection")
    );
    try std.testing.expectError(error.LuaRuntime, result);
    engine.lua.pop(1);
}

test "zag.buffer.clear_row_style is a no-op on graphics buffers" {
    // Cleanup is permissive: graphics buffers carry no row-style state,
    // so dropping an override is trivially a no-op rather than a raise.
    // Only set_row_style is strict, since it expresses an intent that
    // cannot take effect.
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    var buffer_registry = BufferRegistry.init(alloc);
    defer buffer_registry.deinit();
    engine.buffer_registry = &buffer_registry;

    try engine.lua.doString(
        \\local b = zag.buffer.create { kind = "graphics" }
        \\zag.buffer.clear_row_style(b, 1)
        \\zag.buffer.clear_row_style(b, 99)
        \\_G.ok = true
    );
    _ = try engine.lua.getGlobal("ok");
    try std.testing.expect(engine.lua.toBoolean(-1));
    engine.lua.pop(1);
}

test "zag.buffer.clear_row_style is a no-op for unset rows" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    var buffer_registry = BufferRegistry.init(alloc);
    defer buffer_registry.deinit();
    engine.buffer_registry = &buffer_registry;

    try engine.lua.doString(
        \\local b = zag.buffer.create { kind = "scratch" }
        \\zag.buffer.set_lines(b, { "a", "b", "c" })
        \\zag.buffer.set_row_style(b, 2, "selection")
        \\zag.buffer.clear_row_style(b, 2)
        \\zag.buffer.clear_row_style(b, 3) -- never set; must not raise
        \\_G.ok = true
    );
    _ = try engine.lua.getGlobal("ok");
    try std.testing.expect(engine.lua.toBoolean(-1));
    engine.lua.pop(1);
}

test "zag.buffer + zag.keymap e2e: bound key resolves through BufferRegistry" {
    // End-to-end invariant check for the buffer_id identity fix.
    // `zag.keymap{buffer = h, ...}` stores `Buffer.getId()` as the scope
    // key; `EventOrchestrator.dispatchKey` passes `focused.conversation.buf().getId()`
    // at lookup time. Both must land on the same u32 or buffer-scoped
    // bindings never fire in production.
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    var buffer_registry = BufferRegistry.init(alloc);
    defer buffer_registry.deinit();
    engine.buffer_registry = &buffer_registry;

    try engine.lua.doString(
        \\_G.fired = 0
        \\local b = zag.buffer.create { kind = "scratch", name = "picker" }
        \\_G.handle = b
        \\zag.keymap {
        \\  mode = "normal",
        \\  key = "x",
        \\  buffer = b,
        \\  fn = function() _G.fired = _G.fired + 1 end,
        \\}
    );

    // Recover the concrete Buffer.getId() the orchestrator would pass.
    _ = try engine.lua.getGlobal("handle");
    const handle_str = try engine.lua.toString(-1);
    const handle = try BufferRegistry.parseId(handle_str);
    engine.lua.pop(1);
    const focused_buffer_id = (try buffer_registry.asBuffer(handle)).getId();

    // Dispatch-path lookup: keyed on the sequential buffer id, not on
    // the packed handle. With Option A wired, these land on the same
    // u32 and the binding resolves.
    const hit = engine.keymapRegistry().lookup(
        .normal,
        .{ .key = .{ .char = 'x' }, .modifiers = .{} },
        focused_buffer_id,
    ) orelse return error.TestExpectedBinding;
    try std.testing.expect(hit == .lua_callback);

    engine.invokeCallback(hit.lua_callback);
    _ = try engine.lua.getGlobal("fired");
    try std.testing.expectEqual(@as(i64, 1), try engine.lua.toInteger(-1));
    engine.lua.pop(1);

    // Another focused buffer id (e.g. a second, independent scratch)
    // does NOT hit the binding: scope is per-buffer, not global.
    const other_id = focused_buffer_id +% 1;
    try std.testing.expect(
        engine.keymapRegistry().lookup(
            .normal,
            .{ .key = .{ .char = 'x' }, .modifiers = .{} },
            other_id,
        ) == null,
    );
}

test "zag.keymap rejects a handle that doesn't live in the registry" {
    std.testing.log_level = .err;
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    var buffer_registry = BufferRegistry.init(alloc);
    defer buffer_registry.deinit();
    engine.buffer_registry = &buffer_registry;

    // Fabricate a parseable-but-unregistered handle.
    const bogus: BufferRegistry.Handle = .{ .index = 99, .generation = 0 };
    const id = try BufferRegistry.formatId(alloc, bogus);
    defer alloc.free(id);
    const script = try std.fmt.allocPrintSentinel(alloc,
        \\zag.keymap {{
        \\  mode = "normal",
        \\  key = "x",
        \\  buffer = "{s}",
        \\  action = "close_window",
        \\}}
    , .{id}, 0);
    defer alloc.free(script);
    const result = engine.lua.doString(script);
    try std.testing.expectError(error.LuaRuntime, result);
    engine.lua.pop(1);
}

test "zag.subagent.register stores entries" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.subagent.register{
        \\  name = "reviewer",
        \\  description = "Review diffs",
        \\  prompt = "You review.",
        \\}
        \\zag.subagent.register{
        \\  name = "scout",
        \\  description = "Scout codebase",
        \\  prompt = "You scout.",
        \\  model = "anthropic/claude-haiku-4-5",
        \\  tools = {"read", "grep"},
        \\}
    );

    const registry = engine.subagentRegistry();
    try std.testing.expectEqual(@as(usize, 2), registry.entries.items.len);

    const reviewer = registry.lookup("reviewer") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("reviewer", reviewer.name);
    try std.testing.expectEqualStrings("Review diffs", reviewer.description);
    try std.testing.expectEqualStrings("You review.", reviewer.prompt);
    try std.testing.expect(reviewer.model == null);
    try std.testing.expect(reviewer.tools == null);

    const scout = registry.lookup("scout") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("scout", scout.name);
    try std.testing.expectEqualStrings("anthropic/claude-haiku-4-5", scout.model.?);
    try std.testing.expectEqual(@as(usize, 2), scout.tools.?.len);
    try std.testing.expectEqualStrings("read", scout.tools.?[0]);
    try std.testing.expectEqualStrings("grep", scout.tools.?[1]);
}

test "zag.subagent.register rejects duplicate" {
    std.testing.log_level = .err;
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.subagent.register{
        \\  name = "foo",
        \\  description = "first",
        \\  prompt = "p",
        \\}
        \\_ok, _err = pcall(function()
        \\  zag.subagent.register{
        \\    name = "foo",
        \\    description = "second",
        \\    prompt = "p",
        \\  }
        \\end)
    );

    _ = try engine.lua.getGlobal("_ok");
    try std.testing.expect(!engine.lua.toBoolean(-1));
    engine.lua.pop(1);

    _ = try engine.lua.getGlobal("_err");
    defer engine.lua.pop(1);
    const err_msg = try engine.lua.toString(-1);
    try std.testing.expect(std.mem.indexOf(u8, err_msg, "duplicate") != null);
    try std.testing.expect(std.mem.indexOf(u8, err_msg, "foo") != null);

    try std.testing.expectEqual(@as(usize, 1), engine.subagentRegistry().entries.items.len);
}

test "zag.subagent.register rejects invalid name" {
    std.testing.log_level = .err;
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\_ok, _err = pcall(function()
        \\  zag.subagent.register{
        \\    name = "Bad_Name",
        \\    description = "nope",
        \\    prompt = "p",
        \\  }
        \\end)
    );

    _ = try engine.lua.getGlobal("_ok");
    try std.testing.expect(!engine.lua.toBoolean(-1));
    engine.lua.pop(1);

    _ = try engine.lua.getGlobal("_err");
    defer engine.lua.pop(1);
    const err_msg = try engine.lua.toString(-1);
    try std.testing.expect(std.mem.indexOf(u8, err_msg, "invalid name") != null);
    try std.testing.expect(std.mem.indexOf(u8, err_msg, "Bad_Name") != null);

    try std.testing.expectEqual(@as(usize, 0), engine.subagentRegistry().entries.items.len);
}

fn fakePromptLayerContext() prompt.LayerContext {
    return .{
        .model = .{ .provider_name = "anthropic", .model_id = "claude-sonnet-4-5" },
        .cwd = "/tmp/zag-test",
        .worktree = "/tmp/zag-test",
        .agent_name = "zag",
        .date_iso = "2026-04-22",
        .is_git_repo = false,
        .platform = "darwin",
        .tools = &.{},
    };
}

test "zag.prompt.layer registers a volatile layer that renders a string" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.prompt.layer{
        \\  name = "lua.env",
        \\  priority = 900,
        \\  cache_class = "volatile",
        \\  render = function(ctx)
        \\    return "Hello from Lua (" .. ctx.agent_name .. ")"
        \\  end,
        \\}
    );

    // Built-in 4 + Lua 1 = 5 layers in the shared registry.
    try std.testing.expectEqual(@as(usize, 5), engine.prompt_registry.layers.items.len);

    const ctx = fakePromptLayerContext();
    var assembled = try engine.renderPromptLayers(&ctx, std.testing.allocator);
    defer assembled.deinit();

    try std.testing.expect(std.mem.indexOf(u8, assembled.@"volatile", "Hello from Lua (zag)") != null);
}

test "zag.prompt.layer cache_class=stable lands in the stable half" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.prompt.layer{
        \\  name = "lua.identity-tail",
        \\  priority = 80,
        \\  cache_class = "stable",
        \\  render = function(_)
        \\    return "STABLE-LUA-LAYER"
        \\  end,
        \\}
    );

    const ctx = fakePromptLayerContext();
    var assembled = try engine.renderPromptLayers(&ctx, std.testing.allocator);
    defer assembled.deinit();

    try std.testing.expect(std.mem.indexOf(u8, assembled.stable, "STABLE-LUA-LAYER") != null);
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, assembled.@"volatile", "STABLE-LUA-LAYER"));
}

test "zag.prompt.layer returning nil is skipped" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.prompt.layer{
        \\  name = "lua.nil-layer",
        \\  priority = 900,
        \\  cache_class = "volatile",
        \\  render = function(_)
        \\    return nil
        \\  end,
        \\}
    );

    const ctx = fakePromptLayerContext();
    var assembled = try engine.renderPromptLayers(&ctx, std.testing.allocator);
    defer assembled.deinit();

    // Volatile half contains the built-in guidelines and nothing extra.
    try std.testing.expect(std.mem.indexOf(u8, assembled.@"volatile", "Guidelines:") != null);
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, assembled.@"volatile", "nil-layer"));
}

test "zag.prompt.layer erroring is logged and skipped" {
    std.testing.log_level = .err;
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.prompt.layer{
        \\  name = "lua.kaboom",
        \\  priority = 900,
        \\  cache_class = "volatile",
        \\  render = function(_)
        \\    error("intentional test failure")
        \\  end,
        \\}
        \\zag.prompt.layer{
        \\  name = "lua.survivor",
        \\  priority = 905,
        \\  cache_class = "volatile",
        \\  render = function(_)
        \\    return "I survived"
        \\  end,
        \\}
    );

    const ctx = fakePromptLayerContext();
    var assembled = try engine.renderPromptLayers(&ctx, std.testing.allocator);
    defer assembled.deinit();

    try std.testing.expect(std.mem.indexOf(u8, assembled.@"volatile", "I survived") != null);
    try std.testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, assembled.@"volatile", "kaboom"));
}

test "zag.prompt.layer exposes ctx fields to Lua" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.prompt.layer{
        \\  name = "lua.ctx-probe",
        \\  priority = 900,
        \\  cache_class = "volatile",
        \\  render = function(ctx)
        \\    return string.format(
        \\      "m=%s p=%s m_id=%s cwd=%s plat=%s git=%s date=%s tools=%d skills=%d",
        \\      ctx.model,
        \\      ctx.provider,
        \\      ctx.model_id,
        \\      ctx.cwd,
        \\      ctx.platform,
        \\      tostring(ctx.is_git_repo),
        \\      ctx.date_iso,
        \\      #ctx.tools,
        \\      #ctx.skills
        \\    )
        \\  end,
        \\}
    );

    var ctx = fakePromptLayerContext();
    const defs = [_]types.ToolDefinition{
        .{ .name = "read", .description = "read files", .input_schema_json = "{}", .prompt_snippet = null },
        .{ .name = "bash", .description = "shell", .input_schema_json = "{}", .prompt_snippet = null },
    };
    ctx.tools = &defs;
    ctx.is_git_repo = true;

    var assembled = try engine.renderPromptLayers(&ctx, std.testing.allocator);
    defer assembled.deinit();

    try std.testing.expect(std.mem.indexOf(u8, assembled.@"volatile", "m=anthropic/claude-sonnet-4-5") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembled.@"volatile", "p=anthropic") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembled.@"volatile", "m_id=claude-sonnet-4-5") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembled.@"volatile", "cwd=/tmp/zag-test") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembled.@"volatile", "plat=darwin") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembled.@"volatile", "git=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembled.@"volatile", "tools=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembled.@"volatile", "skills=0") != null);
}

test "zag.prompt.layer rejects missing fields" {
    std.testing.log_level = .err;
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    // Missing name.
    try engine.lua.doString(
        \\_ok1, _err1 = pcall(function()
        \\  zag.prompt.layer{
        \\    render = function() return "x" end,
        \\  }
        \\end)
    );
    _ = try engine.lua.getGlobal("_ok1");
    try std.testing.expect(!engine.lua.toBoolean(-1));
    engine.lua.pop(1);

    // Missing render.
    try engine.lua.doString(
        \\_ok2, _err2 = pcall(function()
        \\  zag.prompt.layer{
        \\    name = "noop",
        \\  }
        \\end)
    );
    _ = try engine.lua.getGlobal("_ok2");
    try std.testing.expect(!engine.lua.toBoolean(-1));
    engine.lua.pop(1);

    // Built-ins only; no partial Lua layer appended.
    try std.testing.expectEqual(@as(usize, 4), engine.prompt_registry.layers.items.len);
}

test "zag.prompt.layer rejects bad cache_class" {
    std.testing.log_level = .err;
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\_ok, _err = pcall(function()
        \\  zag.prompt.layer{
        \\    name = "bogus",
        \\    cache_class = "super-stable",
        \\    render = function() return "x" end,
        \\  }
        \\end)
    );

    _ = try engine.lua.getGlobal("_ok");
    try std.testing.expect(!engine.lua.toBoolean(-1));
    engine.lua.pop(1);

    _ = try engine.lua.getGlobal("_err");
    defer engine.lua.pop(1);
    const err_msg = try engine.lua.toString(-1);
    try std.testing.expect(std.mem.indexOf(u8, err_msg, "cache_class") != null);

    try std.testing.expectEqual(@as(usize, 4), engine.prompt_registry.layers.items.len);
}

test "zag.prompt.layer rejects a stable layer registered after the first render" {
    // Pre-existing prompt.zig test covers Zig-side `error.StableFrozen`.
    // This test proves the same condition propagates through `protectedCall`
    // as a Lua runtime error so plugin authors see a `pcall`-able failure
    // instead of an opaque crash.
    std.testing.log_level = .err;
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.prompt.layer{
        \\  name = "lua.first-stable",
        \\  priority = 50,
        \\  cache_class = "stable",
        \\  render = function() return "FIRST" end,
        \\}
    );

    // First render trips the freeze.
    const ctx = fakePromptLayerContext();
    var assembled = try engine.renderPromptLayers(&ctx, std.testing.allocator);
    defer assembled.deinit();
    try std.testing.expect(engine.prompt_registry.stable_frozen);

    // Second stable registration must surface as a Lua runtime error.
    const result = engine.lua.doString(
        \\zag.prompt.layer{
        \\  name = "lua.second-stable",
        \\  priority = 60,
        \\  cache_class = "stable",
        \\  render = function() return "SECOND" end,
        \\}
    );
    try std.testing.expectError(error.LuaRuntime, result);

    // Error message includes the corrective hint pointing at "volatile".
    const err_msg = try engine.lua.toString(-1);
    try std.testing.expect(std.mem.indexOf(u8, err_msg, "volatile") != null);
    engine.lua.pop(1);

    // No partial registration: built-ins 4 + first stable = 5.
    try std.testing.expectEqual(@as(usize, 5), engine.prompt_registry.layers.items.len);
}

test "zag.prompt.layer engine deinit frees lua refs and names" {
    // testing.allocator checks for leaks on deinit; a missing unref or
    // free in the engine teardown path would fail this test. Register
    // a handful of Lua layers so the loop actually has work to do.
    var engine = try LuaEngine.init(std.testing.allocator);
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.prompt.layer{
        \\  name = "lua.a",
        \\  cache_class = "volatile",
        \\  render = function() return "a" end,
        \\}
        \\zag.prompt.layer{
        \\  name = "lua.b",
        \\  priority = 200,
        \\  cache_class = "stable",
        \\  render = function() return "b" end,
        \\}
        \\zag.prompt.layer{
        \\  name = "lua.c",
        \\  render = function() return nil end,
        \\}
    );

    // Built-ins 4 + Lua 3 = 7.
    try std.testing.expectEqual(@as(usize, 7), engine.prompt_registry.layers.items.len);

    engine.deinit();
}

test "zag.prompt.for_model substring pattern matches model id" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.prompt.for_model("claude", "You are Claude.")
    );

    var ctx = fakePromptLayerContext();
    // fakePromptLayerContext model_id is "claude-sonnet-4-5"; matches.
    {
        var assembled = try engine.renderPromptLayers(&ctx, std.testing.allocator);
        defer assembled.deinit();
        try std.testing.expect(std.mem.indexOf(u8, assembled.stable, "You are Claude.") != null);
    }

    // Swap to a non-Claude model; the layer must stay silent.
    ctx.model = .{ .provider_name = "openai", .model_id = "gpt-5-codex" };
    {
        var assembled = try engine.renderPromptLayers(&ctx, std.testing.allocator);
        defer assembled.deinit();
        try std.testing.expectEqual(
            @as(?usize, null),
            std.mem.indexOf(u8, assembled.stable, "You are Claude."),
        );
    }
}

test "zag.prompt.for_model function body receives ctx on match" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.prompt.for_model("gpt-5", function(ctx)
        \\  return "codex-pack:" .. ctx.model_id
        \\end)
    );

    var ctx = fakePromptLayerContext();
    ctx.model = .{ .provider_name = "openai", .model_id = "gpt-5-codex" };

    var assembled = try engine.renderPromptLayers(&ctx, std.testing.allocator);
    defer assembled.deinit();

    try std.testing.expect(std.mem.indexOf(u8, assembled.stable, "codex-pack:gpt-5-codex") != null);
}

test "zag.prompt.for_model lua pattern with %% magic engages string.match" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    // `%d+` requires Lua-pattern evaluation; a pure substring match
    // would never fire. A successful match proves the %-branch runs.
    try engine.lua.doString(
        \\zag.prompt.for_model("sonnet%-%d+", "MATCH")
    );

    var ctx = fakePromptLayerContext();
    ctx.model = .{ .provider_name = "anthropic", .model_id = "claude-sonnet-4-5" };
    {
        var assembled = try engine.renderPromptLayers(&ctx, std.testing.allocator);
        defer assembled.deinit();
        try std.testing.expect(std.mem.indexOf(u8, assembled.stable, "MATCH") != null);
    }

    ctx.model = .{ .provider_name = "openai", .model_id = "gpt-5-codex" };
    {
        var assembled = try engine.renderPromptLayers(&ctx, std.testing.allocator);
        defer assembled.deinit();
        try std.testing.expectEqual(
            @as(?usize, null),
            std.mem.indexOf(u8, assembled.stable, "MATCH"),
        );
    }
}

test "zag.prompt.for_model lands body in the stable half" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.prompt.for_model("claude", "PACK-PREFIX")
    );

    const ctx = fakePromptLayerContext();
    var assembled = try engine.renderPromptLayers(&ctx, std.testing.allocator);
    defer assembled.deinit();

    try std.testing.expect(std.mem.indexOf(u8, assembled.stable, "PACK-PREFIX") != null);
    try std.testing.expectEqual(
        @as(?usize, null),
        std.mem.indexOf(u8, assembled.@"volatile", "PACK-PREFIX"),
    );
}

test "zag.prompt.for_model function returning nil contributes nothing" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.prompt.for_model("claude", function(_) return nil end)
    );

    const ctx = fakePromptLayerContext();
    var assembled = try engine.renderPromptLayers(&ctx, std.testing.allocator);
    defer assembled.deinit();

    // Built-ins still present; nothing extra in the stable half beyond
    // the known identity/tool/skills sequence.
    try std.testing.expectEqual(
        @as(?usize, null),
        std.mem.indexOf(u8, assembled.stable, "for_model"),
    );
}

test "zag.prompt.for_model rejects wrong argument types" {
    std.testing.log_level = .err;
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    // Missing body.
    try engine.lua.doString(
        \\_ok1, _err1 = pcall(zag.prompt.for_model, "claude")
    );
    _ = try engine.lua.getGlobal("_ok1");
    try std.testing.expect(!engine.lua.toBoolean(-1));
    engine.lua.pop(1);

    // Non-string pattern.
    try engine.lua.doString(
        \\_ok2, _err2 = pcall(zag.prompt.for_model, 42, "x")
    );
    _ = try engine.lua.getGlobal("_ok2");
    try std.testing.expect(!engine.lua.toBoolean(-1));
    engine.lua.pop(1);

    // Body is neither string nor function.
    try engine.lua.doString(
        \\_ok3, _err3 = pcall(zag.prompt.for_model, "claude", 42)
    );
    _ = try engine.lua.getGlobal("_ok3");
    try std.testing.expect(!engine.lua.toBoolean(-1));
    engine.lua.pop(1);

    // Built-ins only; no partial Lua layer appended.
    try std.testing.expectEqual(@as(usize, 4), engine.prompt_registry.layers.items.len);
}

test "zag.prompt.for_model engine deinit frees table refs and names" {
    // testing.allocator asserts no leaks on deinit; a missing unref
    // or name free in the for_model path would fail here.
    var engine = try LuaEngine.init(std.testing.allocator);
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.prompt.for_model("claude", "text-body")
        \\zag.prompt.for_model("gpt-5", function() return "fn-body" end)
        \\zag.prompt.for_model("%d+", "pattern-body")
    );

    // Built-ins 4 + for_model 3 = 7.
    try std.testing.expectEqual(@as(usize, 7), engine.prompt_registry.layers.items.len);

    engine.deinit();
}

test "zag.layers.env emits environment block from LayerContext" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString("require('zag.layers.env')");

    var ctx = fakePromptLayerContext();
    ctx.cwd = "/home/vlad/zag";
    ctx.worktree = "/home/vlad/zag";
    ctx.date_iso = "2026-04-22";
    ctx.platform = "macos";
    ctx.is_git_repo = true;

    var assembled = try engine.renderPromptLayers(&ctx, std.testing.allocator);
    defer assembled.deinit();

    const expected =
        \\<environment>
        \\cwd: /home/vlad/zag
        \\date: 2026-04-22
        \\platform: macos
        \\git: yes
        \\</environment>
    ;
    try std.testing.expect(std.mem.indexOf(u8, assembled.@"volatile", expected) != null);
}

test "zag.layers.env omits worktree line when equal to cwd" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString("require('zag.layers.env')");

    var ctx = fakePromptLayerContext();
    ctx.cwd = "/a/b";
    ctx.worktree = "/a/b";
    var assembled = try engine.renderPromptLayers(&ctx, std.testing.allocator);
    defer assembled.deinit();

    // `worktree:` would only appear when ctx.worktree differs from ctx.cwd.
    try std.testing.expectEqual(
        @as(?usize, null),
        std.mem.indexOf(u8, assembled.@"volatile", "worktree:"),
    );
}

test "zag.layers.env emits worktree line when distinct from cwd" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString("require('zag.layers.env')");

    var ctx = fakePromptLayerContext();
    ctx.cwd = "/repo/sub/dir";
    ctx.worktree = "/repo";
    var assembled = try engine.renderPromptLayers(&ctx, std.testing.allocator);
    defer assembled.deinit();

    try std.testing.expect(std.mem.indexOf(u8, assembled.@"volatile", "worktree: /repo") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembled.@"volatile", "cwd: /repo/sub/dir") != null);
}

test "zag.layers.env omits git line when is_git_repo is false" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString("require('zag.layers.env')");

    var ctx = fakePromptLayerContext();
    ctx.is_git_repo = false;

    var assembled = try engine.renderPromptLayers(&ctx, std.testing.allocator);
    defer assembled.deinit();

    try std.testing.expectEqual(
        @as(?usize, null),
        std.mem.indexOf(u8, assembled.@"volatile", "git: yes"),
    );
}

test "zag.context.find_up returns nil when no instruction file is present" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &pbuf);

    _ = engine.lua.pushString(root);
    engine.lua.setGlobal("_root");

    try engine.lua.doString(
        \\_found_is_nil = zag.context.find_up({"AGENTS.md", "CLAUDE.md", "CONTEXT.md"}, {
        \\  from = _root,
        \\  to = _root,
        \\}) == nil
    );

    _ = try engine.lua.getGlobal("_found_is_nil");
    try std.testing.expect(engine.lua.toBoolean(-1));
    engine.lua.pop(1);
}

test "zag.context.find_up surfaces AGENTS.md content from cwd" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "AGENTS.md", .data = "project guidance" });
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &pbuf);

    _ = engine.lua.pushString(root);
    engine.lua.setGlobal("_root");

    try engine.lua.doString(
        \\local f = zag.context.find_up({"AGENTS.md", "CLAUDE.md", "CONTEXT.md"}, {
        \\  from = _root,
        \\  to = _root,
        \\})
        \\_path = f.path
        \\_content = f.content
    );

    _ = try engine.lua.getGlobal("_path");
    const path = try engine.lua.toString(-1);
    try std.testing.expect(std.mem.endsWith(u8, path, "AGENTS.md"));
    engine.lua.pop(1);

    _ = try engine.lua.getGlobal("_content");
    try std.testing.expectEqualStrings("project guidance", try engine.lua.toString(-1));
    engine.lua.pop(1);
}

test "zag.context.find_up accepts a single string and walks up" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "AGENTS.md", .data = "ancestor body" });
    try tmp.dir.makePath("nested/leaf");
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &pbuf);
    const leaf = try std.fs.path.join(std.testing.allocator, &.{ root, "nested", "leaf" });
    defer std.testing.allocator.free(leaf);

    _ = engine.lua.pushString(root);
    engine.lua.setGlobal("_root");
    _ = engine.lua.pushString(leaf);
    engine.lua.setGlobal("_leaf");

    try engine.lua.doString(
        \\local f = zag.context.find_up("AGENTS.md", { from = _leaf, to = _root })
        \\_content = f.content
    );

    _ = try engine.lua.getGlobal("_content");
    try std.testing.expectEqualStrings("ancestor body", try engine.lua.toString(-1));
    engine.lua.pop(1);
}

test "zag.layers.agents_md renders nothing when no instruction file exists" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &pbuf);

    try engine.lua.doString("require('zag.layers.agents_md')");

    var ctx = fakePromptLayerContext();
    ctx.cwd = root;
    ctx.worktree = root;

    var assembled = try engine.renderPromptLayers(&ctx, std.testing.allocator);
    defer assembled.deinit();

    try std.testing.expectEqual(
        @as(?usize, null),
        std.mem.indexOf(u8, assembled.@"volatile", "<instructions"),
    );
}

test "zag.layers.agents_md emits AGENTS.md content wrapped in <instructions>" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "AGENTS.md", .data = "Use TDD always." });
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &pbuf);

    try engine.lua.doString("require('zag.layers.agents_md')");

    var ctx = fakePromptLayerContext();
    ctx.cwd = root;
    ctx.worktree = root;

    var assembled = try engine.renderPromptLayers(&ctx, std.testing.allocator);
    defer assembled.deinit();

    const tail = assembled.@"volatile";
    try std.testing.expect(std.mem.indexOf(u8, tail, "<instructions from=\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tail, "AGENTS.md\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, tail, "Use TDD always.") != null);
    try std.testing.expect(std.mem.indexOf(u8, tail, "</instructions>") != null);
}

test "loadBuiltinPlugins eager-loads zag.layers.* entries" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    // Pre-load: the registry holds only the four built-in Zig layers
    // that `LuaEngine.init` seeded.
    try std.testing.expectEqual(@as(usize, 4), engine.prompt_registry.layers.items.len);

    engine.loadBuiltinPlugins();

    // Post-load: env layer should now be registered alongside the
    // four Zig builtins.
    var found_env = false;
    for (engine.prompt_registry.layers.items) |layer| {
        if (std.mem.eql(u8, layer.name, "env")) {
            found_env = true;
            try std.testing.expectEqual(prompt.CacheClass.@"volatile", layer.cache_class);
            try std.testing.expectEqual(@as(i32, 10), layer.priority);
        }
    }
    try std.testing.expect(found_env);
}

test "agents_md integration: eager-loaded layer pulls parent AGENTS.md into assembled prompt" {
    // End-to-end integration for PR 6: real LuaEngine, real eager-load
    // of `zag.layers.*`, real `renderPromptLayers`. Verifies the full
    // chain a turn travels: builtin layers seeded -> Lua layers loaded
    // -> walk-up loader resolves an ancestor AGENTS.md -> assembled
    // volatile half carries the `<instructions>` block.
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "AGENTS.md", .data = "Prefer TDD." });
    try tmp.dir.makePath("nested/leaf");
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &pbuf);
    const leaf = try std.fs.path.join(std.testing.allocator, &.{ root, "nested", "leaf" });
    defer std.testing.allocator.free(leaf);

    // Production path: no manual `require`, just the eager-loader.
    engine.loadBuiltinPlugins();

    var found_layer = false;
    for (engine.prompt_registry.layers.items) |layer| {
        if (std.mem.eql(u8, layer.name, "agents_md")) {
            found_layer = true;
            try std.testing.expectEqual(prompt.CacheClass.@"volatile", layer.cache_class);
            try std.testing.expectEqual(@as(i32, 900), layer.priority);
        }
    }
    try std.testing.expect(found_layer);

    var ctx = fakePromptLayerContext();
    ctx.cwd = leaf;
    ctx.worktree = root;

    var assembled = try engine.renderPromptLayers(&ctx, std.testing.allocator);
    defer assembled.deinit();

    const tail = assembled.@"volatile";
    try std.testing.expect(std.mem.indexOf(u8, tail, "<instructions from=\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tail, "AGENTS.md\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, tail, "Prefer TDD.") != null);
    try std.testing.expect(std.mem.indexOf(u8, tail, "</instructions>") != null);

    // Stable half stays free of project-specific instructions; only the
    // identity / tool_list / guidelines built-ins live there.
    try std.testing.expectEqual(
        @as(?usize, null),
        std.mem.indexOf(u8, assembled.stable, "<instructions"),
    );
}

test "agents_md integration: assembled prompt omits instructions block when no file is found" {
    // Negative half of the integration: same eager-loaded layer set, but
    // the tmp tree has no AGENTS.md / CLAUDE.md / CONTEXT.md anywhere
    // between cwd and worktree. The agents_md layer must contribute
    // nothing so the assembled prompt stays clean.
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("nested/leaf");
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &pbuf);
    const leaf = try std.fs.path.join(std.testing.allocator, &.{ root, "nested", "leaf" });
    defer std.testing.allocator.free(leaf);

    engine.loadBuiltinPlugins();

    var ctx = fakePromptLayerContext();
    ctx.cwd = leaf;
    ctx.worktree = root;

    var assembled = try engine.renderPromptLayers(&ctx, std.testing.allocator);
    defer assembled.deinit();

    try std.testing.expectEqual(
        @as(?usize, null),
        std.mem.indexOf(u8, assembled.@"volatile", "<instructions"),
    );
    try std.testing.expectEqual(
        @as(?usize, null),
        std.mem.indexOf(u8, assembled.stable, "<instructions"),
    );
}

test "zag.parse_frontmatter returns fields and body" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\local parsed = zag.parse_frontmatter("---\nname: reviewer\ntools: [read, grep]\n---\nBody text.\n")
        \\_name = parsed.fields.name
        \\_body = parsed.body
        \\_tool_1 = parsed.fields.tools[1]
        \\_tool_2 = parsed.fields.tools[2]
    );

    _ = try engine.lua.getGlobal("_name");
    try std.testing.expectEqualStrings("reviewer", try engine.lua.toString(-1));
    engine.lua.pop(1);

    _ = try engine.lua.getGlobal("_body");
    try std.testing.expectEqualStrings("Body text.\n", try engine.lua.toString(-1));
    engine.lua.pop(1);

    _ = try engine.lua.getGlobal("_tool_1");
    try std.testing.expectEqualStrings("read", try engine.lua.toString(-1));
    engine.lua.pop(1);

    _ = try engine.lua.getGlobal("_tool_2");
    try std.testing.expectEqualStrings("grep", try engine.lua.toString(-1));
    engine.lua.pop(1);
}

test "zag.fs.read_file_sync and list_dir_sync" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "a.txt", .data = "hello-sync" });
    try tmp.dir.writeFile(.{ .sub_path = "b.md", .data = "# header\n" });

    var rbuf: [std.fs.max_path_bytes]u8 = undefined;
    const base = try tmp.dir.realpath(".", &rbuf);

    _ = engine.lua.pushString(base);
    engine.lua.setGlobal("_base");

    try engine.lua.doString(
        \\local content = zag.fs.read_file_sync(_base .. "/a.txt")
        \\_content = content
        \\local names = zag.fs.list_dir_sync(_base)
        \\table.sort(names)
        \\_count = #names
        \\_first = names[1]
        \\_second = names[2]
        \\_missing = zag.fs.read_file_sync("/nonexistent/zzz") == nil
    );

    _ = try engine.lua.getGlobal("_content");
    try std.testing.expectEqualStrings("hello-sync", try engine.lua.toString(-1));
    engine.lua.pop(1);

    _ = try engine.lua.getGlobal("_count");
    try std.testing.expectEqual(@as(i64, 2), try engine.lua.toInteger(-1));
    engine.lua.pop(1);

    _ = try engine.lua.getGlobal("_first");
    try std.testing.expectEqualStrings("a.txt", try engine.lua.toString(-1));
    engine.lua.pop(1);

    _ = try engine.lua.getGlobal("_second");
    try std.testing.expectEqualStrings("b.md", try engine.lua.toString(-1));
    engine.lua.pop(1);

    _ = try engine.lua.getGlobal("_missing");
    try std.testing.expect(engine.lua.toBoolean(-1));
    engine.lua.pop(1);
}

test "zag.subagents.filesystem loads agents from tmpdir" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const reviewer_md =
        \\---
        \\name: reviewer
        \\description: Review staged diffs.
        \\model: anthropic/claude-haiku-4-5
        \\tools: [read, grep]
        \\---
        \\You are a reviewer. Read the diff and return findings.
    ;
    try tmp.dir.makePath("agents");
    try tmp.dir.writeFile(.{ .sub_path = "agents/reviewer.md", .data = reviewer_md });

    const scout_md =
        \\---
        \\name: scout
        \\description: Scout the codebase.
        \\---
        \\You are a scout.
    ;
    try tmp.dir.writeFile(.{ .sub_path = "agents/scout.md", .data = scout_md });

    // A sibling file without the right extension must be ignored.
    try tmp.dir.writeFile(.{ .sub_path = "agents/README", .data = "ignore me" });

    var rbuf: [std.fs.max_path_bytes]u8 = undefined;
    const base = try tmp.dir.realpath("agents", &rbuf);

    _ = engine.lua.pushString(base);
    engine.lua.setGlobal("_agents_dir");

    try engine.lua.doString(
        \\local fs = require("zag.subagents.filesystem")
        \\fs.load_from(_agents_dir)
    );

    const registry = engine.subagentRegistry();
    try std.testing.expectEqual(@as(usize, 2), registry.entries.items.len);

    const reviewer = registry.lookup("reviewer") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Review staged diffs.", reviewer.description);
    try std.testing.expectEqualStrings(
        "You are a reviewer. Read the diff and return findings.",
        reviewer.prompt,
    );
    try std.testing.expectEqualStrings("anthropic/claude-haiku-4-5", reviewer.model.?);
    try std.testing.expectEqual(@as(usize, 2), reviewer.tools.?.len);
    try std.testing.expectEqualStrings("read", reviewer.tools.?[0]);
    try std.testing.expectEqualStrings("grep", reviewer.tools.?[1]);

    const scout = registry.lookup("scout") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Scout the codebase.", scout.description);
    try std.testing.expectEqualStrings("You are a scout.", scout.prompt);
    try std.testing.expect(scout.model == null);
    try std.testing.expect(scout.tools == null);
}

test "zag.subagents.filesystem skips malformed files with a warning" {
    std.testing.log_level = .err;
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("agents");
    // Missing `name` field; must be skipped.
    try tmp.dir.writeFile(.{
        .sub_path = "agents/broken.md",
        .data = "---\ndescription: no name\n---\nbody\n",
    });
    // Valid; must be loaded even though a sibling was malformed.
    try tmp.dir.writeFile(.{
        .sub_path = "agents/good.md",
        .data = "---\nname: good\ndescription: ok\n---\nhi\n",
    });

    var rbuf: [std.fs.max_path_bytes]u8 = undefined;
    const base = try tmp.dir.realpath("agents", &rbuf);

    _ = engine.lua.pushString(base);
    engine.lua.setGlobal("_agents_dir");

    try engine.lua.doString(
        \\local fs = require("zag.subagents.filesystem")
        \\fs.load_from(_agents_dir)
    );

    const registry = engine.subagentRegistry();
    try std.testing.expectEqual(@as(usize, 1), registry.entries.items.len);
    try std.testing.expect(registry.lookup("good") != null);
}

test "zag.prompt.resolve maps known model ids to the right pack module" {
    if (sandbox_enabled) return error.SkipZigTest;

    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    // Resolve must work without `loadBuiltinPlugins` priming `for_model`
    // because the dispatcher table is the `require` return value, not a
    // side effect of layer registration.
    try engine.lua.doString(
        \\local d = require("zag.prompt")
        \\_claude       = d.resolve("claude-sonnet-4-6")
        \\_codex        = d.resolve("gpt-5-codex")
        \\_qwen_short   = d.resolve("qwen3-coder-30b")
        \\_qwen_instruct = d.resolve("ollama/qwen3-coder-30b-instruct")
        \\_unknown      = d.resolve("groq/llama-3.1-70b")
    );

    _ = try engine.lua.getGlobal("_claude");
    try std.testing.expectEqualStrings("zag.prompt.anthropic", try engine.lua.toString(-1));
    engine.lua.pop(1);

    _ = try engine.lua.getGlobal("_codex");
    try std.testing.expectEqualStrings("zag.prompt.openai-codex", try engine.lua.toString(-1));
    engine.lua.pop(1);

    _ = try engine.lua.getGlobal("_qwen_short");
    try std.testing.expectEqualStrings("zag.prompt.qwen3-coder", try engine.lua.toString(-1));
    engine.lua.pop(1);

    _ = try engine.lua.getGlobal("_qwen_instruct");
    try std.testing.expectEqualStrings("zag.prompt.qwen3-coder", try engine.lua.toString(-1));
    engine.lua.pop(1);

    _ = try engine.lua.getGlobal("_unknown");
    try std.testing.expectEqualStrings("zag.prompt.default", try engine.lua.toString(-1));
    engine.lua.pop(1);
}

test "zag.prompt dispatch routes Claude model id to anthropic pack" {
    if (sandbox_enabled) return error.SkipZigTest;

    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    // Pulls in the dispatcher (`zag.prompt`) and the env layer. The
    // pack modules are intentionally lazy-loaded; the dispatcher's
    // `pack` layer requires them on first match.
    engine.loadBuiltinPlugins();

    var ctx = fakePromptLayerContext();
    ctx.model = .{ .provider_name = "anthropic", .model_id = "claude-sonnet-4-5" };

    var assembled = try engine.renderPromptLayers(&ctx, std.testing.allocator);
    defer assembled.deinit();

    // Identity line unique to the anthropic pack proves the dispatcher
    // resolved through `zag.prompt.anthropic` and rendered its body.
    try std.testing.expect(
        std.mem.indexOf(u8, assembled.stable, "running with Claude") != null,
    );
    try std.testing.expectEqual(
        @as(?usize, null),
        std.mem.indexOf(u8, assembled.stable, "running with GPT-5 Codex"),
    );
}

test "zag.prompt dispatch routes Codex model id to openai-codex pack" {
    if (sandbox_enabled) return error.SkipZigTest;

    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    engine.loadBuiltinPlugins();

    var ctx = fakePromptLayerContext();
    ctx.model = .{ .provider_name = "openai", .model_id = "gpt-5-codex" };

    var assembled = try engine.renderPromptLayers(&ctx, std.testing.allocator);
    defer assembled.deinit();

    try std.testing.expect(
        std.mem.indexOf(u8, assembled.stable, "running with GPT-5 Codex") != null,
    );
    try std.testing.expectEqual(
        @as(?usize, null),
        std.mem.indexOf(u8, assembled.stable, "running with Claude"),
    );
}

test "zag.prompt dispatch routes Qwen3-Coder model id to qwen3-coder pack" {
    if (sandbox_enabled) return error.SkipZigTest;

    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    engine.loadBuiltinPlugins();

    // Ollama is the canonical Qwen3-Coder host; the dispatcher pattern
    // matches the bare model id, so the `ollama/` provider prefix in the
    // route is incidental. Identity line uniquely belongs to the qwen
    // pack and proves the dispatcher resolved through it rather than
    // falling through to the generic default.
    var ctx = fakePromptLayerContext();
    ctx.model = .{ .provider_name = "ollama", .model_id = "qwen3-coder-30b" };

    var assembled = try engine.renderPromptLayers(&ctx, std.testing.allocator);
    defer assembled.deinit();

    try std.testing.expect(
        std.mem.indexOf(u8, assembled.stable, "running with Qwen3-Coder") != null,
    );
    try std.testing.expectEqual(
        @as(?usize, null),
        std.mem.indexOf(u8, assembled.stable, "running with Claude"),
    );
    try std.testing.expectEqual(
        @as(?usize, null),
        std.mem.indexOf(u8, assembled.stable, "running with GPT-5 Codex"),
    );
}

test "qwen3-coder pack require installs loop, gate, and trim transforms globally" {
    if (sandbox_enabled) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    // Pull in the default loop detector first so we can prove the pack
    // overrides it. The pack file is intentionally NOT auto-loaded by
    // `loadBuiltinPlugins` (per-pack files are lazy); requiring it
    // directly mirrors the dispatcher's first-match behavior and is
    // what registers the overrides.
    try engine.lua.doString("require('zag.loop.default')");
    try std.testing.expect(engine.loopDetectHandler() != null);
    try std.testing.expect(engine.toolGateHandler() == null);
    try std.testing.expect(!engine.toolTransformHandlers().contains("grep"));
    try std.testing.expect(!engine.toolTransformHandlers().contains("bash"));

    try engine.lua.doString("require('zag.prompt.qwen3-coder')");

    // Loop detector handler swapped (single global slot, last-write-wins).
    // We can't compare refs directly without snapshotting, but the next
    // test exercises the threshold-2 behavior to confirm the swap.
    try std.testing.expect(engine.loopDetectHandler() != null);
    // Tool gate slot now populated by the pack.
    try std.testing.expect(engine.toolGateHandler() != null);
    // Both trim transforms registered.
    try std.testing.expect(engine.toolTransformHandlers().contains("grep"));
    try std.testing.expect(engine.toolTransformHandlers().contains("bash"));
}

test "qwen3-coder pack loop detector flags at 2 identical calls" {
    if (sandbox_enabled) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString("require('zag.prompt.qwen3-coder')");

    // identical_streak == 1: below the qwen threshold, no action.
    var below = agent_events.LoopDetectRequest.init("bash", "{}", false, 1, alloc);
    defer below.freeResult();
    try engine.handleLoopDetectRequest(&below);
    try std.testing.expect(below.error_name == null);
    try std.testing.expect(below.result == null);

    // identical_streak == 2: hits the qwen threshold (vs default's 5),
    // returns a reminder. Reminder text mentions tool name and count
    // so plugin authors get actionable diagnostic copy.
    var at = agent_events.LoopDetectRequest.init("bash", "{}", false, 2, alloc);
    defer at.freeResult();
    try engine.handleLoopDetectRequest(&at);
    try std.testing.expect(at.error_name == null);
    try std.testing.expect(at.result != null);
    switch (at.result.?) {
        .reminder => |text| {
            try std.testing.expect(std.mem.indexOf(u8, text, "bash") != null);
            try std.testing.expect(std.mem.indexOf(u8, text, "2x") != null);
        },
        .abort => return error.TestUnexpectedAbort,
    }
}

test "qwen3-coder pack tool gate restricts to read/edit/bash/grep/glob" {
    if (sandbox_enabled) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString("require('zag.prompt.qwen3-coder')");

    // The gate returns its own fixed allowlist; the available-tools
    // list passed in is informational (handlers can read `ctx.tools`
    // but the qwen pack does not). We populate it with the agent's
    // realistic set so the test exercises the marshal path the same
    // way `gateToolDefs` will at runtime; intersection with the
    // registered tool registry happens upstream in `agent.zig`.
    const tool_names = [_][]const u8{
        "read", "write", "edit", "bash", "grep",
        "glob", "fetch", "task",
    };
    var req = agent_events.ToolGateRequest.init(
        "ollama/qwen3-coder-30b",
        &tool_names,
        alloc,
    );
    defer req.freeResult();

    try engine.handleToolGateRequest(&req);
    try std.testing.expect(req.error_name == null);
    try std.testing.expect(req.result != null);

    const subset = req.result.?;
    try std.testing.expectEqual(@as(usize, 5), subset.len);
    try std.testing.expectEqualStrings("read", subset[0]);
    try std.testing.expectEqualStrings("edit", subset[1]);
    try std.testing.expectEqualStrings("bash", subset[2]);
    try std.testing.expectEqualStrings("grep", subset[3]);
    try std.testing.expectEqualStrings("glob", subset[4]);
}

test "qwen3-coder dispatch end-to-end installs pack body and overrides via lazy require" {
    if (sandbox_enabled) return error.SkipZigTest;

    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    // The dispatcher is auto-loaded by the `zag.prompt` prefix, the
    // default loop detector by the `zag.loop.*` prefix. The pack file
    // itself is NOT eager-loaded: it must be pulled in by the
    // dispatcher's lazy `require()` on first render with a matching
    // model id. That lazy require is the seam this test exercises.
    engine.loadBuiltinPlugins();

    // Sanity: before any render fires the dispatcher, the qwen pack's
    // top-level statements have not run yet, so the gate slot is empty
    // and trim transforms are absent. The default loop detector is
    // installed (via `zag.loop.default` auto-load), so the pre-render
    // `loopDetectHandler` is non-null even before dispatch.
    try std.testing.expect(engine.loopDetectHandler() != null);
    try std.testing.expect(engine.toolGateHandler() == null);
    try std.testing.expect(!engine.toolTransformHandlers().contains("grep"));
    try std.testing.expect(!engine.toolTransformHandlers().contains("bash"));
    const default_loop_ref = engine.loopDetectHandler().?;

    var ctx = fakePromptLayerContext();
    ctx.model = .{ .provider_name = "ollama", .model_id = "qwen3-coder-30b" };

    var assembled = try engine.renderPromptLayers(&ctx, alloc);
    defer assembled.deinit();

    // 1. Pack body landed in the stable half. The identity line is
    // unique to qwen3-coder.lua.
    try std.testing.expect(
        std.mem.indexOf(u8, assembled.stable, "running with Qwen3-Coder") != null,
    );

    // 2. Loop detector handler was swapped by the pack (single global
    // slot, last-write-wins). The ref id changes when zag.loop.detect
    // re-registers, which is the observable signal the override fired.
    try std.testing.expect(engine.loopDetectHandler() != null);
    try std.testing.expect(engine.loopDetectHandler().? != default_loop_ref);

    // 3. Tool gate now returns the qwen 5-name allowlist. Driving the
    // gate through `handleToolGateRequest` exercises the same marshal
    // path that `gateToolDefs` uses at runtime.
    const tool_names = [_][]const u8{
        "read", "write", "edit", "bash", "grep",
        "glob", "fetch", "task",
    };
    var gate = agent_events.ToolGateRequest.init(
        "ollama/qwen3-coder-30b",
        &tool_names,
        alloc,
    );
    defer gate.freeResult();
    try engine.handleToolGateRequest(&gate);
    try std.testing.expect(gate.error_name == null);
    try std.testing.expect(gate.result != null);
    const subset = gate.result.?;
    try std.testing.expectEqual(@as(usize, 5), subset.len);
    try std.testing.expectEqualStrings("read", subset[0]);
    try std.testing.expectEqualStrings("edit", subset[1]);
    try std.testing.expectEqualStrings("bash", subset[2]);
    try std.testing.expectEqualStrings("grep", subset[3]);
    try std.testing.expectEqualStrings("glob", subset[4]);

    // 4. Both trim transforms registered as a side effect of the lazy
    // require. The transform handler map is keyed by tool name; the
    // rg_trim module registers under "grep" (the harness tool name)
    // and bash_trim under "bash".
    try std.testing.expect(engine.toolTransformHandlers().contains("grep"));
    try std.testing.expect(engine.toolTransformHandlers().contains("bash"));
}

test "zag.prompt dispatch falls through to default pack for exotic providers" {
    if (sandbox_enabled) return error.SkipZigTest;

    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    engine.loadBuiltinPlugins();

    // Groq's llama route matches no provider-specific pattern; the
    // trailing `.*` entry in `M.PACKS` must catch it and the default
    // pack must render. The marker phrase only lives in default.lua.
    var ctx = fakePromptLayerContext();
    ctx.model = .{ .provider_name = "groq", .model_id = "llama-3.1-70b" };

    var assembled = try engine.renderPromptLayers(&ctx, std.testing.allocator);
    defer assembled.deinit();

    try std.testing.expect(
        std.mem.indexOf(u8, assembled.stable, "Call tools when you need information") != null,
    );
    try std.testing.expectEqual(
        @as(?usize, null),
        std.mem.indexOf(u8, assembled.stable, "running with Claude"),
    );
    try std.testing.expectEqual(
        @as(?usize, null),
        std.mem.indexOf(u8, assembled.stable, "running with GPT-5 Codex"),
    );
}

test "zag.prompt dispatch lets user layer named 'pack' shadow the pack body" {
    if (sandbox_enabled) return error.SkipZigTest;

    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    engine.loadBuiltinPlugins();

    // The dispatcher registers a stable layer literally named `pack`.
    // A user that wants to take over the model-specific identity for
    // their config registers their own layer with the same name. The
    // registry is append-only, so both fire; the user's volatile layer
    // is what the agent loop ends up appending after the stable prefix,
    // and the model treats the later text as the operative instruction.
    try engine.lua.doString(
        \\zag.prompt.layer{
        \\  name = "pack",
        \\  priority = 1000,
        \\  cache_class = "volatile",
        \\  render = function(_)
        \\    return "USER-OVERRIDE: ignore the pack identity above."
        \\  end,
        \\}
    );

    var ctx = fakePromptLayerContext();
    ctx.model = .{ .provider_name = "anthropic", .model_id = "claude-sonnet-4-5" };

    var assembled = try engine.renderPromptLayers(&ctx, std.testing.allocator);
    defer assembled.deinit();

    // Pack still renders into the stable half. User layer with the
    // same name lands in the volatile half and "wins" by virtue of
    // appearing later in the concatenated system prompt.
    try std.testing.expect(
        std.mem.indexOf(u8, assembled.stable, "running with Claude") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, assembled.@"volatile", "USER-OVERRIDE") != null,
    );

    // Two layers share the name `pack` after the user's registration.
    var pack_count: usize = 0;
    for (engine.prompt_registry.layers.items) |layer| {
        if (std.mem.eql(u8, layer.name, "pack")) pack_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), pack_count);
}

test "zag.reminders.push pushes a next-turn entry by default" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.reminders.push("hello there")
    );

    const snap = try engine.reminders.snapshot(std.testing.allocator);
    defer Reminder.freeDrained(std.testing.allocator, snap);
    try std.testing.expectEqual(@as(usize, 1), snap.len);
    try std.testing.expectEqualStrings("hello there", snap[0].text);
    try std.testing.expectEqual(Reminder.Scope.next_turn, snap[0].scope);
    try std.testing.expect(snap[0].id == null);
    try std.testing.expectEqual(true, snap[0].once);
}

test "zag.reminders.push honors persistent scope and id" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.reminders.push("plan active", { scope = "persistent", id = "plan", once = false })
    );

    const snap = try engine.reminders.snapshot(std.testing.allocator);
    defer Reminder.freeDrained(std.testing.allocator, snap);
    try std.testing.expectEqual(@as(usize, 1), snap.len);
    try std.testing.expectEqualStrings("plan active", snap[0].text);
    try std.testing.expectEqual(Reminder.Scope.persistent, snap[0].scope);
    try std.testing.expectEqualStrings("plan", snap[0].id.?);
    try std.testing.expectEqual(false, snap[0].once);
}

test "zag.reminders.push rejects unknown scope" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    const result = engine.lua.doString(
        \\zag.reminders.push("nope", { scope = "later" })
    );
    try std.testing.expectError(error.LuaRuntime, result);
    try std.testing.expectEqual(@as(usize, 0), engine.reminders.len());
}

test "zag.reminders.push rejects non-string text" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    const result = engine.lua.doString(
        \\zag.reminders.push(42)
    );
    try std.testing.expectError(error.LuaRuntime, result);
    try std.testing.expectEqual(@as(usize, 0), engine.reminders.len());
}

test "zag.reminders.clear removes matching id" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.reminders.push("keep", { scope = "persistent", id = "keep" })
        \\zag.reminders.push("drop", { scope = "persistent", id = "drop" })
        \\zag.reminders.clear("drop")
    );

    const snap = try engine.reminders.snapshot(std.testing.allocator);
    defer Reminder.freeDrained(std.testing.allocator, snap);
    try std.testing.expectEqual(@as(usize, 1), snap.len);
    try std.testing.expectEqualStrings("keep", snap[0].text);
}

test "zag.reminders.list returns a snapshot of pending entries" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.reminders.push("first")
        \\zag.reminders.push("second", { scope = "persistent", id = "p" })
        \\local snap = zag.reminders.list()
        \\_G.snap_len = #snap
        \\_G.first_text = snap[1].text
        \\_G.first_scope = snap[1].scope
        \\_G.second_text = snap[2].text
        \\_G.second_scope = snap[2].scope
        \\_G.second_id = snap[2].id
    );

    _ = engine.lua.getGlobal("snap_len") catch {};
    try std.testing.expectEqual(@as(i64, 2), try engine.lua.toInteger(-1));
    engine.lua.pop(1);

    _ = engine.lua.getGlobal("first_text") catch {};
    try std.testing.expectEqualStrings("first", try engine.lua.toString(-1));
    engine.lua.pop(1);

    _ = engine.lua.getGlobal("first_scope") catch {};
    try std.testing.expectEqualStrings("next_turn", try engine.lua.toString(-1));
    engine.lua.pop(1);

    _ = engine.lua.getGlobal("second_text") catch {};
    try std.testing.expectEqualStrings("second", try engine.lua.toString(-1));
    engine.lua.pop(1);

    _ = engine.lua.getGlobal("second_scope") catch {};
    try std.testing.expectEqualStrings("persistent", try engine.lua.toString(-1));
    engine.lua.pop(1);

    _ = engine.lua.getGlobal("second_id") catch {};
    try std.testing.expectEqualStrings("p", try engine.lua.toString(-1));
    engine.lua.pop(1);

    // Snapshot must not have drained the queue.
    try std.testing.expectEqual(@as(usize, 2), engine.reminders.len());
}

test "zag.context.on_tool_result registers a handler keyed by tool name" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.context.on_tool_result("read", function(ctx)
        \\  return "stub for: " .. ctx.input
        \\end)
    );
    try std.testing.expectEqual(@as(u32, 1), engine.jitContextHandlers().count());
    try std.testing.expect(engine.jit_context_handlers.contains("read"));
}

test "zag.context.on_tool_result re-registration unrefs old function" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.context.on_tool_result("read", function(ctx) return "v1" end)
    );
    const first_ref = engine.jit_context_handlers.get("read").?.fn_ref;

    try engine.lua.doString(
        \\zag.context.on_tool_result("read", function(ctx) return "v2" end)
    );
    try std.testing.expectEqual(@as(u32, 1), engine.jitContextHandlers().count());
    const second_ref = engine.jit_context_handlers.get("read").?.fn_ref;
    try std.testing.expect(first_ref != second_ref);
    // testing.allocator + Lua deinit catch a leaked old fn_ref. This test
    // body would fail under the leak detector if the old ref was kept.
}

test "handleJitContextRequest invokes registered handler and dupes result" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.context.on_tool_result("read", function(ctx)
        \\  return "ok " .. ctx.tool .. " in=" .. ctx.input .. " out=" .. ctx.output
        \\end)
    );

    var req = agent_events.JitContextRequest.init(
        "read",
        "{\"path\":\"/tmp/x\"}",
        "file body",
        false,
        alloc,
    );
    try engine.handleJitContextRequest(&req);
    try std.testing.expect(req.error_name == null);
    try std.testing.expect(req.result != null);
    defer alloc.free(req.result.?);
    try std.testing.expectEqualStrings(
        "ok read in={\"path\":\"/tmp/x\"} out=file body",
        req.result.?,
    );
}

test "handleJitContextRequest with unknown tool name leaves result null" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    var req = agent_events.JitContextRequest.init("write", "{}", "nope", false, alloc);
    try engine.handleJitContextRequest(&req);
    try std.testing.expect(req.result == null);
    try std.testing.expect(req.error_name == null);
}

test "handleJitContextRequest surfaces Lua handler error via @errorName" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.context.on_tool_result("bash", function(ctx)
        \\  error("boom")
        \\end)
    );

    var req = agent_events.JitContextRequest.init("bash", "{}", "", false, alloc);
    const result = engine.handleJitContextRequest(&req);
    try std.testing.expectError(error.LuaHandlerError, result);
    try std.testing.expect(req.result == null);
}

test "handleJitContextRequest passes is_error through to ctx" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.context.on_tool_result("read", function(ctx)
        \\  if ctx.is_error then return "ERR" else return "OK" end
        \\end)
    );

    var req = agent_events.JitContextRequest.init("read", "{}", "x", true, alloc);
    try engine.handleJitContextRequest(&req);
    defer if (req.result) |s| alloc.free(s);
    try std.testing.expectEqualStrings("ERR", req.result.?);
}

test "handleJitContextRequest rejects handler returning a number" {
    // A handler that returns a non-string non-nil must surface as
    // `error.JitContextNotString` so the worker proceeds without
    // attaching a malformed context blob.
    std.testing.log_level = .err;
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.context.on_tool_result("read", function(_) return 42 end)
    );

    var req = agent_events.JitContextRequest.init("read", "{}", "x", false, alloc);
    const result = engine.handleJitContextRequest(&req);
    try std.testing.expectError(error.JitContextNotString, result);
    try std.testing.expect(req.result == null);
}

test "handleJitContextRequest rejects handler returning a table" {
    std.testing.log_level = .err;
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.context.on_tool_result("read", function(_) return {1,2,3} end)
    );

    var req = agent_events.JitContextRequest.init("read", "{}", "x", false, alloc);
    const result = engine.handleJitContextRequest(&req);
    try std.testing.expectError(error.JitContextNotString, result);
    try std.testing.expect(req.result == null);
}

test "zag.context.on_tool_result rejects non-string tool name" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    const result = engine.lua.doString(
        \\zag.context.on_tool_result(42, function() end)
    );
    try std.testing.expectError(error.LuaRuntime, result);
    try std.testing.expectEqual(@as(u32, 0), engine.jitContextHandlers().count());
}

test "zag.context.on_tool_result rejects non-function handler" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    const result = engine.lua.doString(
        \\zag.context.on_tool_result("read", "not a function")
    );
    try std.testing.expectError(error.LuaRuntime, result);
    try std.testing.expectEqual(@as(u32, 0), engine.jitContextHandlers().count());
}

test "zag.tools.transform_output registers a handler keyed by tool name" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.tools.transform_output("bash", function(ctx)
        \\  return "trimmed: " .. ctx.output
        \\end)
    );
    try std.testing.expectEqual(@as(u32, 1), engine.toolTransformHandlers().count());
    try std.testing.expect(engine.tool_transform_handlers.contains("bash"));
}

test "zag.tools.transform_output re-registration unrefs old function" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.tools.transform_output("bash", function(ctx) return "v1" end)
    );
    const first_ref = engine.tool_transform_handlers.get("bash").?.fn_ref;

    try engine.lua.doString(
        \\zag.tools.transform_output("bash", function(ctx) return "v2" end)
    );
    try std.testing.expectEqual(@as(u32, 1), engine.toolTransformHandlers().count());
    const second_ref = engine.tool_transform_handlers.get("bash").?.fn_ref;
    try std.testing.expect(first_ref != second_ref);
    // testing.allocator + Lua deinit catch a leaked old fn_ref. This test
    // body would fail under the leak detector if the old ref was kept.
}

test "handleToolTransformRequest invokes registered handler and dupes result" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.tools.transform_output("bash", function(ctx)
        \\  return "ok " .. ctx.tool .. " in=" .. ctx.input .. " out=" .. ctx.output
        \\end)
    );

    var req = agent_events.ToolTransformRequest.init(
        "bash",
        "{\"cmd\":\"ls\"}",
        "raw",
        false,
        alloc,
    );
    try engine.handleToolTransformRequest(&req);
    try std.testing.expect(req.error_name == null);
    try std.testing.expect(req.result != null);
    defer alloc.free(req.result.?);
    try std.testing.expectEqualStrings(
        "ok bash in={\"cmd\":\"ls\"} out=raw",
        req.result.?,
    );
}

test "handleToolTransformRequest with unknown tool name leaves result null" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    var req = agent_events.ToolTransformRequest.init("write", "{}", "x", false, alloc);
    try engine.handleToolTransformRequest(&req);
    try std.testing.expect(req.result == null);
    try std.testing.expect(req.error_name == null);
}

test "handleToolTransformRequest surfaces Lua handler error via @errorName" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.tools.transform_output("bash", function(ctx) error("blew up") end)
    );

    var req = agent_events.ToolTransformRequest.init("bash", "{}", "out", false, alloc);
    const result = engine.handleToolTransformRequest(&req);
    try std.testing.expectError(error.LuaHandlerError, result);
    try std.testing.expect(req.result == null);
}

test "handleToolTransformRequest passes is_error through to ctx" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.tools.transform_output("bash", function(ctx)
        \\  if ctx.is_error then return "STAYS-ERR" else return "STAYS-OK" end
        \\end)
    );

    var req = agent_events.ToolTransformRequest.init("bash", "{}", "x", true, alloc);
    try engine.handleToolTransformRequest(&req);
    defer if (req.result) |s| alloc.free(s);
    try std.testing.expectEqualStrings("STAYS-ERR", req.result.?);
}

test "handleToolTransformRequest with nil return leaves result null" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.tools.transform_output("bash", function(ctx) return nil end)
    );

    var req = agent_events.ToolTransformRequest.init("bash", "{}", "x", false, alloc);
    try engine.handleToolTransformRequest(&req);
    try std.testing.expect(req.result == null);
    try std.testing.expect(req.error_name == null);
}

test "handleToolTransformRequest rejects handler returning a number" {
    // Mirror of the JIT test: non-string non-nil returns from a
    // transform handler must surface as `error.ToolTransformNotString`
    // so the worker keeps the original output instead of swapping in
    // garbage.
    std.testing.log_level = .err;
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.tools.transform_output("bash", function(_) return 42 end)
    );

    var req = agent_events.ToolTransformRequest.init("bash", "{}", "out", false, alloc);
    const result = engine.handleToolTransformRequest(&req);
    try std.testing.expectError(error.ToolTransformNotString, result);
    try std.testing.expect(req.result == null);
}

test "handleToolTransformRequest rejects handler returning a table" {
    std.testing.log_level = .err;
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.tools.transform_output("bash", function(_) return {x=1} end)
    );

    var req = agent_events.ToolTransformRequest.init("bash", "{}", "out", false, alloc);
    const result = engine.handleToolTransformRequest(&req);
    try std.testing.expectError(error.ToolTransformNotString, result);
    try std.testing.expect(req.result == null);
}

test "zag.tools.transform_output rejects non-string tool name" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    const result = engine.lua.doString(
        \\zag.tools.transform_output(42, function() end)
    );
    try std.testing.expectError(error.LuaRuntime, result);
    try std.testing.expectEqual(@as(u32, 0), engine.toolTransformHandlers().count());
}

test "zag.tools.transform_output rejects non-function handler" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    const result = engine.lua.doString(
        \\zag.tools.transform_output("bash", "not a function")
    );
    try std.testing.expectError(error.LuaRuntime, result);
    try std.testing.expectEqual(@as(u32, 0), engine.toolTransformHandlers().count());
}

test "zag.tools.gate registers a single global handler" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try std.testing.expect(engine.toolGateHandler() == null);
    try engine.lua.doString(
        \\zag.tools.gate(function(ctx) return { "read" } end)
    );
    try std.testing.expect(engine.toolGateHandler() != null);
}

test "zag.tools.gate re-registration unrefs old function" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.tools.gate(function(ctx) return { "read" } end)
    );
    const first = engine.toolGateHandler().?;

    try engine.lua.doString(
        \\zag.tools.gate(function(ctx) return { "bash" } end)
    );
    const second = engine.toolGateHandler().?;
    try std.testing.expect(first != second);
    // testing.allocator + Lua deinit catch a leaked old fn_ref. This
    // test would fail under the leak detector if the old ref leaked.
}

test "zag.tools.gate(nil) clears the handler" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.tools.gate(function(ctx) return { "read" } end)
    );
    try std.testing.expect(engine.toolGateHandler() != null);
    try engine.lua.doString(
        \\zag.tools.gate(nil)
    );
    try std.testing.expect(engine.toolGateHandler() == null);
}

test "zag.tools.gate rejects non-function non-nil arg" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    const result = engine.lua.doString(
        \\zag.tools.gate("not a function")
    );
    try std.testing.expectError(error.LuaRuntime, result);
    try std.testing.expect(engine.toolGateHandler() == null);
}

test "handleToolGateRequest returns subset of allowed names" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.tools.gate(function(ctx)
        \\  return { "read", "bash" }
        \\end)
    );

    const tool_names = [_][]const u8{ "read", "write", "edit", "bash" };
    var req = agent_events.ToolGateRequest.init(
        "ollama/qwen3-coder",
        &tool_names,
        alloc,
    );
    defer req.freeResult();

    try engine.handleToolGateRequest(&req);
    try std.testing.expect(req.error_name == null);
    try std.testing.expect(req.result != null);
    const subset = req.result.?;
    try std.testing.expectEqual(@as(usize, 2), subset.len);
    try std.testing.expectEqualStrings("read", subset[0]);
    try std.testing.expectEqualStrings("bash", subset[1]);
}

test "handleToolGateRequest receives model and full tool list in ctx" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.tools.gate(function(ctx)
        \\  -- Echo the model id and one tool name so the test can read them back.
        \\  return { ctx.model, ctx.tools[1] }
        \\end)
    );

    const tool_names = [_][]const u8{ "read", "bash" };
    var req = agent_events.ToolGateRequest.init("anthropic/claude-sonnet-4", &tool_names, alloc);
    defer req.freeResult();

    try engine.handleToolGateRequest(&req);
    try std.testing.expect(req.result != null);
    try std.testing.expectEqualStrings("anthropic/claude-sonnet-4", req.result.?[0]);
    try std.testing.expectEqualStrings("read", req.result.?[1]);
}

test "handleToolGateRequest with no handler leaves result null" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    const tool_names = [_][]const u8{"read"};
    var req = agent_events.ToolGateRequest.init("m", &tool_names, alloc);
    try engine.handleToolGateRequest(&req);
    try std.testing.expect(req.result == null);
    try std.testing.expect(req.error_name == null);
}

test "handleToolGateRequest with nil return leaves result null" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.tools.gate(function(ctx) return nil end)
    );

    const tool_names = [_][]const u8{"read"};
    var req = agent_events.ToolGateRequest.init("m", &tool_names, alloc);
    try engine.handleToolGateRequest(&req);
    try std.testing.expect(req.result == null);
    try std.testing.expect(req.error_name == null);
}

test "handleToolGateRequest with empty table leaves result null" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.tools.gate(function(ctx) return {} end)
    );

    const tool_names = [_][]const u8{"read"};
    var req = agent_events.ToolGateRequest.init("m", &tool_names, alloc);
    try engine.handleToolGateRequest(&req);
    try std.testing.expect(req.result == null);
    try std.testing.expect(req.error_name == null);
}

test "handleToolGateRequest surfaces Lua handler error via @errorName" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.tools.gate(function(ctx) error("nope") end)
    );

    const tool_names = [_][]const u8{"read"};
    var req = agent_events.ToolGateRequest.init("m", &tool_names, alloc);
    const result = engine.handleToolGateRequest(&req);
    try std.testing.expectError(error.LuaHandlerError, result);
    try std.testing.expect(req.result == null);
}

test "handleToolGateRequest rejects non-table return" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.tools.gate(function(ctx) return "read" end)
    );

    const tool_names = [_][]const u8{"read"};
    var req = agent_events.ToolGateRequest.init("m", &tool_names, alloc);
    const result = engine.handleToolGateRequest(&req);
    try std.testing.expectError(error.ToolGateNotTable, result);
    try std.testing.expect(req.result == null);
}

test "handleToolGateRequest rejects non-string entry" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.tools.gate(function(ctx) return { "read", 42 } end)
    );

    const tool_names = [_][]const u8{"read"};
    var req = agent_events.ToolGateRequest.init("m", &tool_names, alloc);
    defer req.freeResult();
    const result = engine.handleToolGateRequest(&req);
    try std.testing.expectError(error.ToolGateEntryNotString, result);
}

test "zag.tool callable form still registers Lua tools" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.tool({
        \\  name = "noop",
        \\  description = "does nothing",
        \\  input_schema = { type = "object", properties = {} },
        \\  execute = function(input) return "ok" end,
        \\})
    );
    try std.testing.expectEqual(@as(usize, 1), engine.tools.items.len);
    try std.testing.expectEqualStrings("noop", engine.tools.items[0].name);
}

test "loadBuiltinPlugins eager-loads zag.jit.* entries" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try std.testing.expectEqual(@as(u32, 0), engine.jitContextHandlers().count());

    engine.loadBuiltinPlugins();

    // The agents_md JIT module registers exactly one handler under "read".
    try std.testing.expect(engine.jitContextHandlers().get("read") != null);
}

test "zag.jit.agents_md attaches AGENTS.md from the read file's parent" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "AGENTS.md", .data = "Use TDD always." });
    try tmp.dir.writeFile(.{ .sub_path = "code.go", .data = "package main" });
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &pbuf);

    try engine.lua.doString("require('zag.jit.agents_md')");

    var input_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
    const tool_input = try std.fmt.bufPrint(&input_buf, "{{\"path\": \"{s}/code.go\"}}", .{root});

    var req = agent_events.JitContextRequest.init("read", tool_input, "package main", false, alloc);
    try engine.handleJitContextRequest(&req);
    defer if (req.result) |s| alloc.free(s);

    try std.testing.expect(req.result != null);
    try std.testing.expect(std.mem.startsWith(u8, req.result.?, "Instructions from: "));
    try std.testing.expect(std.mem.indexOf(u8, req.result.?, "AGENTS.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, req.result.?, "Use TDD always.") != null);
}

test "zag.jit.agents_md returns nil when no instruction file exists" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "code.go", .data = "package main" });
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &pbuf);

    try engine.lua.doString("require('zag.jit.agents_md')");

    var input_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
    const tool_input = try std.fmt.bufPrint(&input_buf, "{{\"path\": \"{s}/code.go\"}}", .{root});

    var req = agent_events.JitContextRequest.init("read", tool_input, "package main", false, alloc);
    try engine.handleJitContextRequest(&req);
    try std.testing.expect(req.result == null);
    try std.testing.expect(req.error_name == null);
}

test "zag.jit.agents_md dedups within a turn" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "AGENTS.md", .data = "Use TDD." });
    try tmp.dir.writeFile(.{ .sub_path = "a.go", .data = "package a" });
    try tmp.dir.writeFile(.{ .sub_path = "b.go", .data = "package b" });
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &pbuf);

    try engine.lua.doString("require('zag.jit.agents_md')");

    var input_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
    const input_a = try std.fmt.bufPrint(&input_buf, "{{\"path\": \"{s}/a.go\"}}", .{root});
    var req_a = agent_events.JitContextRequest.init("read", input_a, "package a", false, alloc);
    try engine.handleJitContextRequest(&req_a);
    defer if (req_a.result) |s| alloc.free(s);
    try std.testing.expect(req_a.result != null);

    // Reusing the buffer is fine: handleJitContextRequest only borrows
    // `input` for the duration of the call.
    var input_buf2: [std.fs.max_path_bytes + 32]u8 = undefined;
    const input_b = try std.fmt.bufPrint(&input_buf2, "{{\"path\": \"{s}/b.go\"}}", .{root});
    var req_b = agent_events.JitContextRequest.init("read", input_b, "package b", false, alloc);
    try engine.handleJitContextRequest(&req_b);
    defer if (req_b.result) |s| alloc.free(s);

    // Same parent dir => same AGENTS.md => second hit dedups to nil.
    try std.testing.expect(req_b.result == null);
}

test "zag.jit.agents_md re-attaches across turn boundaries" {
    // Same parent dir read twice in two different turns: dedup must NOT
    // span turns, so the TurnEnd hook clears `seen_this_turn` and the
    // second turn's read sees the instructions again.
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "AGENTS.md", .data = "Use TDD." });
    try tmp.dir.writeFile(.{ .sub_path = "a.go", .data = "package a" });
    try tmp.dir.writeFile(.{ .sub_path = "b.go", .data = "package b" });
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &pbuf);

    try engine.lua.doString("require('zag.jit.agents_md')");

    var input_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
    const input_a = try std.fmt.bufPrint(&input_buf, "{{\"path\": \"{s}/a.go\"}}", .{root});
    var req_a = agent_events.JitContextRequest.init("read", input_a, "package a", false, alloc);
    try engine.handleJitContextRequest(&req_a);
    defer if (req_a.result) |s| alloc.free(s);
    try std.testing.expect(req_a.result != null);

    // Fire TurnEnd: the JIT layer's hook callback runs on the main
    // thread and clears `seen_this_turn`.
    var turn_end: Hooks.HookPayload = .{ .turn_end = .{
        .turn_num = 1,
        .stop_reason = "end_turn",
        .input_tokens = 0,
        .output_tokens = 0,
    } };
    _ = try engine.fireHook(&turn_end);

    var input_buf2: [std.fs.max_path_bytes + 32]u8 = undefined;
    const input_b = try std.fmt.bufPrint(&input_buf2, "{{\"path\": \"{s}/b.go\"}}", .{root});
    var req_b = agent_events.JitContextRequest.init("read", input_b, "package b", false, alloc);
    try engine.handleJitContextRequest(&req_b);
    defer if (req_b.result) |s| alloc.free(s);

    // New turn => dedup table is empty => AGENTS.md re-attaches.
    try std.testing.expect(req_b.result != null);
    try std.testing.expect(std.mem.indexOf(u8, req_b.result.?, "AGENTS.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, req_b.result.?, "Use TDD.") != null);
}

test "zag.jit.agents_md skips when ctx.is_error is true" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "AGENTS.md", .data = "Should be skipped." });
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &pbuf);

    try engine.lua.doString("require('zag.jit.agents_md')");

    var input_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
    const tool_input = try std.fmt.bufPrint(&input_buf, "{{\"path\": \"{s}/missing.go\"}}", .{root});

    var req = agent_events.JitContextRequest.init("read", tool_input, "error: not found", true, alloc);
    try engine.handleJitContextRequest(&req);
    try std.testing.expect(req.result == null);
}

test "zag.jit.agents_md returns nil when input has no path key" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString("require('zag.jit.agents_md')");

    var req = agent_events.JitContextRequest.init("read", "{}", "x", false, alloc);
    try engine.handleJitContextRequest(&req);
    try std.testing.expect(req.result == null);
    try std.testing.expect(req.error_name == null);
}

test "zag.transforms.rg_trim trims grep output past 200 lines" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString("require('zag.transforms.rg_trim')");

    // Build a 300-line input. The trim keeps the first 200 lines verbatim
    // and replaces lines 201-300 with a single "... [100 lines elided]"
    // marker so the agent sees the early hits but not the long tail.
    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(alloc);
    var i: usize = 1;
    while (i <= 300) : (i += 1) {
        try output.writer(alloc).print("line {d}\n", .{i});
    }

    var req = agent_events.ToolTransformRequest.init(
        "grep",
        "{}",
        output.items,
        false,
        alloc,
    );
    try engine.handleToolTransformRequest(&req);
    try std.testing.expect(req.error_name == null);
    try std.testing.expect(req.result != null);
    defer alloc.free(req.result.?);

    // First 200 lines kept verbatim.
    try std.testing.expect(std.mem.indexOf(u8, req.result.?, "line 1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, req.result.?, "line 200\n") != null);
    // Line 201 onward replaced by the elision marker.
    try std.testing.expect(std.mem.indexOf(u8, req.result.?, "line 201") == null);
    try std.testing.expect(std.mem.indexOf(u8, req.result.?, "... [100 lines elided]") != null);
}

test "zag.transforms.rg_trim leaves short grep output untouched" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString("require('zag.transforms.rg_trim')");

    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(alloc);
    var i: usize = 1;
    while (i <= 100) : (i += 1) {
        try output.writer(alloc).print("line {d}\n", .{i});
    }

    var req = agent_events.ToolTransformRequest.init(
        "grep",
        "{}",
        output.items,
        false,
        alloc,
    );
    try engine.handleToolTransformRequest(&req);
    // Handler returns nil for under-cap inputs; the agent reads the
    // original string and the harness skips the dupe.
    try std.testing.expect(req.error_name == null);
    try std.testing.expect(req.result == null);
}

test "zag.transforms.rg_trim passes through error output" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString("require('zag.transforms.rg_trim')");

    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(alloc);
    var i: usize = 1;
    while (i <= 300) : (i += 1) {
        try output.writer(alloc).print("line {d}\n", .{i});
    }

    var req = agent_events.ToolTransformRequest.init(
        "grep",
        "{}",
        output.items,
        true,
        alloc,
    );
    try engine.handleToolTransformRequest(&req);
    try std.testing.expect(req.error_name == null);
    try std.testing.expect(req.result == null);
}

test "zag.transforms.bash_trim trims bash output past 500 lines" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString("require('zag.transforms.bash_trim')");

    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(alloc);
    var i: usize = 1;
    while (i <= 700) : (i += 1) {
        try output.writer(alloc).print("line {d}\n", .{i});
    }

    var req = agent_events.ToolTransformRequest.init(
        "bash",
        "{}",
        output.items,
        false,
        alloc,
    );
    try engine.handleToolTransformRequest(&req);
    try std.testing.expect(req.error_name == null);
    try std.testing.expect(req.result != null);
    defer alloc.free(req.result.?);

    try std.testing.expect(std.mem.indexOf(u8, req.result.?, "line 1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, req.result.?, "line 500\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, req.result.?, "line 501") == null);
    try std.testing.expect(std.mem.indexOf(u8, req.result.?, "... [200 lines elided]") != null);
}

test "zag.transforms.bash_trim leaves short bash output untouched" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString("require('zag.transforms.bash_trim')");

    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(alloc);
    var i: usize = 1;
    while (i <= 100) : (i += 1) {
        try output.writer(alloc).print("line {d}\n", .{i});
    }

    var req = agent_events.ToolTransformRequest.init(
        "bash",
        "{}",
        output.items,
        false,
        alloc,
    );
    try engine.handleToolTransformRequest(&req);
    try std.testing.expect(req.error_name == null);
    try std.testing.expect(req.result == null);
}

test "zag.loop.detect registers a single global handler" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try std.testing.expect(engine.loopDetectHandler() == null);
    try engine.lua.doString(
        \\zag.loop.detect(function(ctx) return nil end)
    );
    try std.testing.expect(engine.loopDetectHandler() != null);
}

test "zag.loop.detect re-registration unrefs old function" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.loop.detect(function(ctx) return nil end)
    );
    const first = engine.loopDetectHandler().?;

    try engine.lua.doString(
        \\zag.loop.detect(function(ctx) return { action = "abort" } end)
    );
    const second = engine.loopDetectHandler().?;
    try std.testing.expect(first != second);
}

test "zag.loop.detect(nil) clears the handler" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.loop.detect(function(ctx) return nil end)
    );
    try std.testing.expect(engine.loopDetectHandler() != null);
    try engine.lua.doString("zag.loop.detect(nil)");
    try std.testing.expect(engine.loopDetectHandler() == null);
}

test "zag.loop.detect rejects non-function non-nil arg" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    const result = engine.lua.doString("zag.loop.detect(\"not a function\")");
    try std.testing.expectError(error.LuaRuntime, result);
    try std.testing.expect(engine.loopDetectHandler() == null);
}

test "handleLoopDetectRequest decodes reminder action" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.loop.detect(function(ctx)
        \\  if ctx.identical_streak >= 3 then
        \\    return { action = "reminder", text = "stop looping " .. ctx.tool }
        \\  end
        \\  return nil
        \\end)
    );

    var req = agent_events.LoopDetectRequest.init("bash", "{}", false, 3, alloc);
    defer req.freeResult();
    try engine.handleLoopDetectRequest(&req);
    try std.testing.expect(req.error_name == null);
    try std.testing.expect(req.result != null);
    switch (req.result.?) {
        .reminder => |text| try std.testing.expectEqualStrings("stop looping bash", text),
        .abort => return error.TestUnexpectedResult,
    }
}

test "handleLoopDetectRequest decodes abort action" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.loop.detect(function(ctx) return { action = "abort" } end)
    );

    var req = agent_events.LoopDetectRequest.init("bash", "{}", false, 5, alloc);
    defer req.freeResult();
    try engine.handleLoopDetectRequest(&req);
    try std.testing.expect(req.error_name == null);
    try std.testing.expect(req.result != null);
    try std.testing.expectEqual(agent_events.LoopAction.abort, req.result.?);
}

test "handleLoopDetectRequest with nil return leaves result null" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.loop.detect(function(ctx) return nil end)
    );

    var req = agent_events.LoopDetectRequest.init("bash", "{}", false, 1, alloc);
    defer req.freeResult();
    try engine.handleLoopDetectRequest(&req);
    try std.testing.expect(req.result == null);
    try std.testing.expect(req.error_name == null);
}

test "handleLoopDetectRequest with no handler leaves result null" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    var req = agent_events.LoopDetectRequest.init("bash", "{}", false, 1, alloc);
    defer req.freeResult();
    try engine.handleLoopDetectRequest(&req);
    try std.testing.expect(req.result == null);
    try std.testing.expect(req.error_name == null);
}

test "handleLoopDetectRequest surfaces Lua handler error via errorName" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.loop.detect(function(ctx) error("nope") end)
    );

    var req = agent_events.LoopDetectRequest.init("bash", "{}", false, 1, alloc);
    defer req.freeResult();
    try std.testing.expectError(error.LuaHandlerError, engine.handleLoopDetectRequest(&req));
    try std.testing.expect(req.result == null);
}

test "handleLoopDetectRequest rejects unknown action string" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.loop.detect(function(ctx) return { action = "explode" } end)
    );

    var req = agent_events.LoopDetectRequest.init("bash", "{}", false, 1, alloc);
    defer req.freeResult();
    try std.testing.expectError(error.LoopDetectUnknownAction, engine.handleLoopDetectRequest(&req));
    try std.testing.expect(req.result == null);
}

test "handleLoopDetectRequest reminder requires string text field" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.loop.detect(function(ctx) return { action = "reminder" } end)
    );

    var req = agent_events.LoopDetectRequest.init("bash", "{}", false, 1, alloc);
    defer req.freeResult();
    try std.testing.expectError(error.LoopDetectReminderMissingText, engine.handleLoopDetectRequest(&req));
    try std.testing.expect(req.result == null);
}

test "handleLoopDetectRequest passes is_error and identical_streak to ctx" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.loop.detect(function(ctx)
        \\  if ctx.is_error and ctx.identical_streak == 7 then
        \\    return { action = "abort" }
        \\  end
        \\  return nil
        \\end)
    );

    var req = agent_events.LoopDetectRequest.init("read", "{\"path\":\"x\"}", true, 7, alloc);
    defer req.freeResult();
    try engine.handleLoopDetectRequest(&req);
    try std.testing.expect(req.result != null);
    try std.testing.expectEqual(agent_events.LoopAction.abort, req.result.?);
}

test "loadBuiltinPlugins eager-loads zag.loop.* entries" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try std.testing.expect(engine.loopDetectHandler() == null);
    engine.loadBuiltinPlugins();
    // The default detector module registers exactly one global handler.
    try std.testing.expect(engine.loopDetectHandler() != null);
}

test "zag.loop.default does not act before the 5-call threshold" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString("require('zag.loop.default')");

    var req = agent_events.LoopDetectRequest.init("bash", "{\"cmd\":\"ls\"}", false, 4, alloc);
    defer req.freeResult();
    try engine.handleLoopDetectRequest(&req);
    try std.testing.expect(req.result == null);
    try std.testing.expect(req.error_name == null);
}

test "zag.loop.default emits reminder at the 5-call threshold" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString("require('zag.loop.default')");

    var req = agent_events.LoopDetectRequest.init("bash", "{\"cmd\":\"ls\"}", false, 5, alloc);
    defer req.freeResult();
    try engine.handleLoopDetectRequest(&req);
    try std.testing.expect(req.error_name == null);
    try std.testing.expect(req.result != null);
    switch (req.result.?) {
        .reminder => |text| {
            // The default text names the offending tool and the streak
            // count so the agent sees the same diagnostic the user would.
            try std.testing.expect(std.mem.indexOf(u8, text, "bash") != null);
            try std.testing.expect(std.mem.indexOf(u8, text, "5x") != null);
            try std.testing.expect(std.mem.indexOf(u8, text, "Try a different approach or stop.") != null);
        },
        .abort => return error.TestUnexpectedResult,
    }
}

// -- Compaction strategy tests ---------------------------------------------

test "zag.compact.strategy registers a single global handler" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try std.testing.expect(engine.compactHandler() == null);
    try engine.lua.doString(
        \\zag.compact.strategy(function(ctx) return nil end)
    );
    try std.testing.expect(engine.compactHandler() != null);
}

test "zag.compact.strategy re-registration unrefs old function" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.compact.strategy(function(ctx) return nil end)
    );
    const first = engine.compactHandler().?;

    try engine.lua.doString(
        \\zag.compact.strategy(function(ctx) return {} end)
    );
    const second = engine.compactHandler().?;
    try std.testing.expect(first != second);
}

test "zag.compact.strategy(nil) clears the handler" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.compact.strategy(function(ctx) return nil end)
    );
    try std.testing.expect(engine.compactHandler() != null);
    try engine.lua.doString("zag.compact.strategy(nil)");
    try std.testing.expect(engine.compactHandler() == null);
}

test "zag.compact.strategy rejects non-function non-nil arg" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    const result = engine.lua.doString("zag.compact.strategy(\"not a function\")");
    try std.testing.expectError(error.LuaRuntime, result);
    try std.testing.expect(engine.compactHandler() == null);
}

test "handleCompactRequest with no handler leaves result null" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    const empty: []const types.Message = &.{};
    var req = agent_events.CompactRequest.init(empty, 100, 200, alloc);
    defer req.freeResult();
    try engine.handleCompactRequest(&req);
    try std.testing.expect(req.result == null);
    try std.testing.expect(req.error_name == null);
}

test "handleCompactRequest returns null when strategy returns nil" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.compact.strategy(function(ctx) return nil end)
    );

    const empty: []const types.Message = &.{};
    var req = agent_events.CompactRequest.init(empty, 100, 200, alloc);
    defer req.freeResult();
    try engine.handleCompactRequest(&req);
    try std.testing.expect(req.result == null);
    try std.testing.expect(req.error_name == null);
}

test "handleCompactRequest decodes returned messages" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.compact.strategy(function(ctx)
        \\  return {
        \\    { role = "user", content = "summary" },
        \\    { role = "assistant", content = "ack" },
        \\  }
        \\end)
    );

    const empty: []const types.Message = &.{};
    var req = agent_events.CompactRequest.init(empty, 1000, 1000, alloc);
    defer req.freeResult();
    try engine.handleCompactRequest(&req);
    try std.testing.expect(req.error_name == null);
    try std.testing.expect(req.result != null);
    try std.testing.expectEqual(@as(usize, 2), req.result.?.len);
    try std.testing.expectEqual(types.Role.user, req.result.?[0].role);
    try std.testing.expectEqualStrings("summary", req.result.?[0].content[0].text.text);
    try std.testing.expectEqual(types.Role.assistant, req.result.?[1].role);
    try std.testing.expectEqualStrings("ack", req.result.?[1].content[0].text.text);
}

test "handleCompactRequest passes tokens_used and tokens_max to ctx" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.compact.strategy(function(ctx)
        \\  if ctx.tokens_used == 850 and ctx.tokens_max == 1000 then
        \\    return { { role = "user", content = "ok" } }
        \\  end
        \\  return nil
        \\end)
    );

    const empty: []const types.Message = &.{};
    var req = agent_events.CompactRequest.init(empty, 850, 1000, alloc);
    defer req.freeResult();
    try engine.handleCompactRequest(&req);
    try std.testing.expect(req.result != null);
    try std.testing.expectEqualStrings("ok", req.result.?[0].content[0].text.text);
}

test "handleCompactRequest snapshots messages as concatenated text" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    // Echo the first message's content back so we can assert on the
    // concatenation. Two text blocks should join end-to-end; non-text
    // blocks should drop entirely.
    try engine.lua.doString(
        \\zag.compact.strategy(function(ctx)
        \\  return { { role = "user", content = ctx.messages[1].content } }
        \\end)
    );

    var blocks_buf = [_]types.ContentBlock{
        .{ .text = .{ .text = "first " } },
        .{ .tool_use = .{ .id = "t1", .name = "bash", .input_raw = "{}" } },
        .{ .text = .{ .text = "second" } },
    };
    const messages = [_]types.Message{
        .{ .role = .user, .content = &blocks_buf },
    };
    var req = agent_events.CompactRequest.init(&messages, 0, 1, alloc);
    defer req.freeResult();
    try engine.handleCompactRequest(&req);
    try std.testing.expect(req.result != null);
    try std.testing.expectEqualStrings("first second", req.result.?[0].content[0].text.text);
}

test "handleCompactRequest surfaces Lua handler error via errorName" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.compact.strategy(function(ctx) error("nope") end)
    );

    const empty: []const types.Message = &.{};
    var req = agent_events.CompactRequest.init(empty, 100, 200, alloc);
    defer req.freeResult();
    try std.testing.expectError(error.LuaHandlerError, engine.handleCompactRequest(&req));
    try std.testing.expect(req.result == null);
}

test "handleCompactRequest rejects malformed entry" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\zag.compact.strategy(function(ctx) return { { content = "missing role" } } end)
    );

    const empty: []const types.Message = &.{};
    var req = agent_events.CompactRequest.init(empty, 100, 200, alloc);
    defer req.freeResult();
    try std.testing.expectError(error.CompactEntryMissingRole, engine.handleCompactRequest(&req));
    try std.testing.expect(req.result == null);
}

test "loadBuiltinPlugins eager-loads zag.compact.* entries" {
    // The default compaction strategy registers a single global
    // handler so the socket is no longer a no-op out of the box.
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try std.testing.expect(engine.compactHandler() == null);
    engine.loadBuiltinPlugins();
    try std.testing.expect(engine.compactHandler() != null);
}

test "zag.compact.default elides older assistant messages" {
    // Five-message conversation:
    //   [1] user      "first ask"      (older turn)
    //   [2] assistant "first answer"   (older turn -> elided)
    //   [3] user      "second ask"     (older turn anchor still in past)
    //   [4] assistant "second answer"  (older turn -> elided)
    //   [5] user      "current ask"    (most recent user; survives)
    // The strategy keeps every user message intact and replaces every
    // assistant message before index 5 with the elision marker.
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString("require('zag.compact.default')");

    var b1 = [_]types.ContentBlock{.{ .text = .{ .text = "first ask" } }};
    var b2 = [_]types.ContentBlock{.{ .text = .{ .text = "first answer" } }};
    var b3 = [_]types.ContentBlock{.{ .text = .{ .text = "second ask" } }};
    var b4 = [_]types.ContentBlock{.{ .text = .{ .text = "second answer" } }};
    var b5 = [_]types.ContentBlock{.{ .text = .{ .text = "current ask" } }};
    const messages = [_]types.Message{
        .{ .role = .user, .content = &b1 },
        .{ .role = .assistant, .content = &b2 },
        .{ .role = .user, .content = &b3 },
        .{ .role = .assistant, .content = &b4 },
        .{ .role = .user, .content = &b5 },
    };
    var req = agent_events.CompactRequest.init(&messages, 850, 1000, alloc);
    defer req.freeResult();
    try engine.handleCompactRequest(&req);
    try std.testing.expect(req.error_name == null);
    try std.testing.expect(req.result != null);

    const out = req.result.?;
    try std.testing.expectEqual(@as(usize, 5), out.len);

    try std.testing.expectEqual(types.Role.user, out[0].role);
    try std.testing.expectEqualStrings("first ask", out[0].content[0].text.text);

    try std.testing.expectEqual(types.Role.assistant, out[1].role);
    try std.testing.expect(std.mem.indexOf(u8, out[1].content[0].text.text, "<elided") != null);

    try std.testing.expectEqual(types.Role.user, out[2].role);
    try std.testing.expectEqualStrings("second ask", out[2].content[0].text.text);

    try std.testing.expectEqual(types.Role.assistant, out[3].role);
    try std.testing.expect(std.mem.indexOf(u8, out[3].content[0].text.text, "<elided") != null);

    try std.testing.expectEqual(types.Role.user, out[4].role);
    try std.testing.expectEqualStrings("current ask", out[4].content[0].text.text);
}

test "zag.compact.default keeps a trailing assistant after the latest user" {
    // When the latest message is a fresh assistant reply to the current
    // user turn, that assistant survives because it sits AFTER the most
    // recent user index. Older assistants are still elided.
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString("require('zag.compact.default')");

    var b1 = [_]types.ContentBlock{.{ .text = .{ .text = "older ask" } }};
    var b2 = [_]types.ContentBlock{.{ .text = .{ .text = "older answer" } }};
    var b3 = [_]types.ContentBlock{.{ .text = .{ .text = "current ask" } }};
    var b4 = [_]types.ContentBlock{.{ .text = .{ .text = "current answer" } }};
    const messages = [_]types.Message{
        .{ .role = .user, .content = &b1 },
        .{ .role = .assistant, .content = &b2 },
        .{ .role = .user, .content = &b3 },
        .{ .role = .assistant, .content = &b4 },
    };
    var req = agent_events.CompactRequest.init(&messages, 850, 1000, alloc);
    defer req.freeResult();
    try engine.handleCompactRequest(&req);
    try std.testing.expect(req.result != null);

    const out = req.result.?;
    try std.testing.expectEqual(@as(usize, 4), out.len);
    try std.testing.expect(std.mem.indexOf(u8, out[1].content[0].text.text, "<elided") != null);
    try std.testing.expectEqualStrings("current answer", out[3].content[0].text.text);
}

test "zag.compact.default passes through when no user message exists" {
    // Without a user anchor the strategy has no notion of "current
    // turn" and refuses to elide. Returning nil keeps the socket
    // semantically equivalent to "no compaction this cycle".
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString("require('zag.compact.default')");

    var b1 = [_]types.ContentBlock{.{ .text = .{ .text = "lonely assistant" } }};
    const messages = [_]types.Message{
        .{ .role = .assistant, .content = &b1 },
    };
    var req = agent_events.CompactRequest.init(&messages, 850, 1000, alloc);
    defer req.freeResult();
    try engine.handleCompactRequest(&req);
    try std.testing.expect(req.result == null);
    try std.testing.expect(req.error_name == null);
}

test "zag.loop.default treats a streak reset as a non-event" {
    // The agent owns streak accounting: a different tool input collapses
    // identical_streak back to 1. The default detector must stay silent
    // for that follow-up call even when the prior streak had already
    // tripped the threshold.
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString("require('zag.loop.default')");

    var tripped = agent_events.LoopDetectRequest.init("bash", "{\"cmd\":\"ls\"}", false, 5, alloc);
    defer tripped.freeResult();
    try engine.handleLoopDetectRequest(&tripped);
    try std.testing.expect(tripped.result != null);

    var reset = agent_events.LoopDetectRequest.init("bash", "{\"cmd\":\"pwd\"}", false, 1, alloc);
    defer reset.freeResult();
    try engine.handleLoopDetectRequest(&reset);
    try std.testing.expect(reset.result == null);
    try std.testing.expect(reset.error_name == null);
}

test "bootstrapStdlibProviders populates an empty engine registry" {
    // First-run scenario: fresh LuaEngine with no config.lua loaded. The
    // bootstrap helper must `require()` every stdlib module and leave the
    // registry carrying every provider the embedded manifest advertises.
    if (sandbox_enabled) return error.SkipZigTest;

    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();

    try std.testing.expectEqual(@as(usize, 0), engine.providers_registry.endpoints.items.len);

    // Count how many embedded entries are provider stdlib modules; the
    // loader skips anything outside the `zag.providers.*` prefix
    // (e.g. the `zag.builtin.*` picker plugins).
    var expected_providers: usize = 0;
    for (embedded.entries) |e| {
        if (std.mem.startsWith(u8, e.name, "zag.providers.")) expected_providers += 1;
    }
    const loaded = engine.bootstrapStdlibProviders();
    try std.testing.expectEqual(expected_providers, loaded);
    try std.testing.expectEqual(expected_providers, engine.providers_registry.endpoints.items.len);

    // Spot-check: anthropic (api-key) and openai-oauth (oauth) both installed.
    try std.testing.expect(engine.providers_registry.find("anthropic") != null);
    const oauth_ep = engine.providers_registry.find("openai-oauth").?;
    try std.testing.expectEqual(std.meta.Tag(llm.Endpoint.Auth).oauth, std.meta.activeTag(oauth_ep.auth));
}

test "bootstrap is a no-op when config.lua already populated the registry" {
    // User with an explicit `require("zag.providers.anthropic")` in their
    // config.lua: the registry is non-empty, so the bootstrap fallback must
    // not fire. Hand-seed one endpoint, then assert the main() guard
    // (`endpoints.items.len == 0`) would leave the registry untouched.
    if (sandbox_enabled) return error.SkipZigTest;

    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();

    const ep: llm.Endpoint = .{
        .name = "anthropic",
        .serializer = .anthropic,
        .url = "https://api.anthropic.com/v1/messages",
        .auth = .x_api_key,
        .headers = &.{},
        .default_model = "claude-sonnet-4-20250514",
        .models = &.{},
    };
    try engine.providers_registry.add(try ep.dupe(std.testing.allocator));
    try std.testing.expectEqual(@as(usize, 1), engine.providers_registry.endpoints.items.len);

    // Mirror the guard in main(): only load stdlib when the registry is
    // empty. A pre-populated registry must stay exactly as the user left it.
    if (engine.providers_registry.endpoints.items.len == 0) {
        _ = engine.bootstrapStdlibProviders();
    }
    try std.testing.expectEqual(@as(usize, 1), engine.providers_registry.endpoints.items.len);
}
