//! Lua plugin system for Zag.
//!
//! Embeds a Lua 5.4 VM (via ziglua) and exposes a `zag.tool()` registration API
//! so that plugins can define tools in Lua that appear alongside the built-in Zig tools.

const std = @import("std");
const zlua = @import("zlua");
const build_options = @import("build_options");
const types = @import("types.zig");
const tools_mod = @import("tools.zig");
const bash_tool = @import("tools/bash.zig");
const Hooks = @import("Hooks.zig");
const Keymap = @import("Keymap.zig");
const Buffer = @import("Buffer.zig");
const BufferRegistry = @import("BufferRegistry.zig");
const ScratchBuffer = @import("buffers/scratch.zig");
const ImageBuffer = @import("buffers/image.zig");
const Theme = @import("Theme.zig");
const CommandRegistry = @import("CommandRegistry.zig");
const input = @import("input.zig");
const llm = @import("llm.zig");
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
const lua_message = @import("lua/lua_message.zig");
const IoBackend = @import("lua/IoBackend.zig").IoBackend;
const embedded = @import("lua/embedded.zig");
const provider_bindings = @import("lua/bindings/provider.zig");
const prompt_bindings = @import("lua/bindings/prompt.zig");
const sockets_bindings = @import("lua/bindings/sockets.zig");
const layout_bindings = @import("lua/bindings/layout.zig");

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
    async_runtime: ?*IoBackend = null,
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
    /// Borrowed pointer to the bash sandbox config struct. `main.zig`
    /// wires this after init; tests can set it directly. `null` means
    /// bash defaults to strict (the safe path), matching the threat-model
    /// contract documented in `tools/bash.zig`.
    bash_config: ?*bash_tool.Config = null,
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
    /// Single global compaction-strategy handler registered via
    /// `zag.compact.strategy(fn)`. The strategy runs at the top of
    /// each agent iteration when the predictive estimate trips the
    /// room-based threshold. Sees a full-fidelity message snapshot
    /// (every ContentBlock variant preserved) and returns one of:
    /// nil (or `{use_default = true}`) to let the Zig default fallback
    /// run; `{cancel = true}` to opt out of the fallback for this
    /// turn; or `{messages = {...}, summary = "..."}` to install a
    /// custom replacement. Released in `deinit`.
    compact_handler: ?i32 = null,
    /// Reserve budget (tokens) held back from the model's context window
    /// when `fireCompact` decides whether to fire. Mutable via Lua:
    /// `zag.compact.set_reserve_tokens(n)`. Default matches
    /// `agent.DEFAULT_RESERVE_TOKENS` (16384, mirroring pi-mono's
    /// reserveTokens default at compaction.ts:114). A larger value
    /// fires compaction earlier; smaller fires later. Zero disables
    /// the room buffer (estimator still gates the call).
    compact_reserve_tokens: u32 = @import("agent.zig").DEFAULT_RESERVE_TOKENS,
    /// Approximate token budget the Zig default summarizer retains
    /// past the cut point. Larger values keep more recent context;
    /// smaller values shrink the surviving suffix harder. Mutable via
    /// `zag.compact.set_keep_recent_tokens(n)`. Default matches
    /// pi-mono's keepRecentTokens (compaction.ts:115).
    compact_keep_recent_tokens: u32 = @import("agent.zig").DEFAULT_KEEP_RECENT_TOKENS,
    /// Borrowed pointer to the Provider currently driving the agent
    /// loop. `runLoopStreaming` sets this on entry and clears it on
    /// exit (defer); the pointer must outlive any in-flight
    /// `zag.llm.complete` Job (the worker pool joins on shutdown, so
    /// the borrow is safe for the call duration). Null when no agent
    /// loop is attached — `zag.llm.complete` errors in that case
    /// rather than guessing a default.
    current_provider: ?*const @import("llm.zig").Provider = null,
    /// Borrowed `ModelSpec` matching `current_provider`. Used to tag
    /// telemetry and (eventually) to honour per-model overrides in
    /// `zag.llm.complete`. Cleared alongside `current_provider`.
    current_model_spec: ?@import("llm.zig").ModelSpec = null,
    /// Borrowed pointer to the agent loop's event queue. Set by
    /// `runLoopStreaming` at agent-loop entry and cleared at exit,
    /// same lifetime contract as `current_provider`. Consumed by
    /// `zag.llm.complete` when the caller opts in to streaming
    /// progress: the worker uses `callStreaming` and pushes
    /// `compaction_summary_delta` events onto this queue so the UI
    /// can render live progress. Null when no agent loop is attached
    /// (some tests, headless paths) — the streaming option is then
    /// a no-op and the call behaves as the synchronous default.
    current_event_queue: ?*@import("agent_events.zig").EventQueue = null,
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
        /// When non-null, this task is running a compaction strategy.
        /// On final `.ok` resume, the top-of-stack return is decoded
        /// into `req.outcome` via `decodeCompactStrategyReturn`. Same
        /// lifetime contract as `hook_payload`: borrowed pointer,
        /// caller (`handleCompactRequest`) keeps the request alive
        /// across the drain loop. Mutually exclusive with
        /// `hook_payload`; never both set on the same task.
        compact_request: ?*agent_events.CompactRequest = null,
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
        try @import("lua/bindings/cmd.zig").registerHandleMetatable(lua);
        try @import("lua/bindings/http.zig").registerHandleMetatable(lua);

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
    /// `zag.jit.*`, `zag.loop.*`, `zag.compact.*`, the `zag.prompt`
    /// dispatcher, and the `zag.subagents.filesystem` loader so the side
    /// effects (slash command registrations, keymap bindings, prompt
    /// layer registrations, JIT context handlers, loop detector handlers,
    /// compaction strategy handlers, and filesystem-discovered subagents)
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
            const is_subagent_loader = std.mem.eql(u8, entry.name, "zag.subagents.filesystem");
            if (!is_builtin and !is_layer and !is_jit and !is_loop and !is_compact and !is_prompt_dispatcher and !is_subagent_loader) continue;
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
        // zag.keymap and zag.keymap_remove; bound from
        // src/lua/bindings/keymap.zig. Both are siblings on the zag
        // table (no subtable). Stack on entry/exit: [zag_table].
        @import("lua/bindings/keymap.zig").registerOn(lua);
        // zag.command; bound from src/lua/bindings/command.zig. Registers
        // a single cfunction directly on the zag table (no subtable).
        // Stack on entry/exit: [zag_table].
        @import("lua/bindings/command.zig").registerOn(lua);
        // zag.set_*; bound from src/lua/bindings/setters.zig. [zag_table].
        @import("lua/bindings/setters.zig").registerOn(lua);
        // zag.provider; single sibling cfunction bound from
        // src/lua/bindings/provider.zig. Stack on entry/exit: [zag_table].
        provider_bindings.registerProviderFn(lua);
        lua.pushFunction(zlua.wrap(zagSleepFn));
        lua.setField(-2, "sleep");
        lua.pushFunction(zlua.wrap(zagSpawnFn));
        lua.setField(-2, "spawn");
        lua.pushFunction(zlua.wrap(zagDetachFn));
        lua.setField(-2, "detach");
        // zag.reminders; bound from src/lua/bindings/reminders.zig. The
        // module owns the cfunction bodies and the subtable assembly.
        // Stack on entry/exit: [zag_table].
        @import("lua/bindings/reminders.zig").registerOn(lua);

        // zag.cmd; bound from src/lua/bindings/cmd.zig. The module owns
        // the callable-table assembly (__call + spawn + kill) and the
        // CmdHandle userdata metatable. Stack on entry/exit: [zag_table].
        @import("lua/bindings/cmd.zig").registerOn(lua);

        // zag.http; bound from src/lua/bindings/http.zig. The module
        // owns the plain-namespace assembly (get + post + stream) and
        // the HttpStreamHandle userdata metatable. Stack on entry/
        // exit: [zag_table].
        @import("lua/bindings/http.zig").registerOn(lua);

        // zag.fs; plain namespace table for filesystem primitives.
        // All async entries yield the coroutine; `exists` is sync.
        // Cfunction bodies and `registerOn` live in lua/bindings/fs.zig.
        @import("lua/bindings/fs.zig").registerOn(lua);

        // zag.layout; plain namespace table for window-tree inspection
        // and mutation. Requires a live window manager, which main.zig
        // wires via `engine.window_manager`. Headless runs leave the
        // field null and these bindings raise a clean Lua error.
        // Cfunction bodies and `registerLayoutTable` live in
        // lua/bindings/layout.zig.
        layout_bindings.registerLayoutTable(lua);

        // zag.pane; per-pane inspection + mutation primitives. Mirrors
        // the `pane_read` tool for reads, and carries `set_model` /
        // `current_model` so a Lua picker plugin can drive the same
        // swap pathway the built-in `/model` command uses. Cfunction
        // bodies and `registerPaneTable` live in lua/bindings/layout.zig.
        layout_bindings.registerPaneTable(lua);

        // zag.sessions; cross-project session enumeration + mutation.
        // The sessions sidebar plugin (Phase 3) reads from `list` and
        // calls `rename` / `delete`; `current()` reads the focused
        // pane's bound session id, `subagents(id)` lazily parses task
        // entries from a session's JSONL.
        @import("lua/bindings/sessions.zig").registerOn(lua);

        // zag.providers; read-only view of the endpoint registry so a
        // Lua model picker can enumerate providers/models without
        // re-implementing the stdlib bookkeeping. Bound from
        // src/lua/bindings/provider.zig. Stack on entry/exit: [zag_table].
        provider_bindings.registerProvidersTable(lua);

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
        @import("lua/bindings/subagent.zig").registerOn(lua);

        // zag.prompt; system-prompt layer registration. `layer{}` appends
        // to the engine's shared `prompt.Registry`; the agent loop drives
        // render through `renderPromptLayers` each turn. See Task 3.1.
        prompt_bindings.registerPromptTable(lua);

        // zag.context; project-context lookups for prompt layers. The
        // walk-up logic lives in `Instruction.zig`; this binding hands
        // back a ready-to-render `{path, content}` table so a Lua layer
        // can drop in without re-implementing filesystem traversal.
        prompt_bindings.registerContextTable(lua);

        @import("lua/bindings/buffer.zig").registerOn(lua);

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
        sockets_bindings.registerToolsTable(lua);

        // zag.loop; namespace for agent-loop sockets. Today only
        // `detect(fn)` (single global post-tool-result hook). The
        // detector returns either a reminder to inject on the next
        // turn or an abort to stop the loop. Stack: [zag_table].
        sockets_bindings.registerLoopTable(lua);

        // zag.compact; namespace for context-compaction sockets. Today
        // `strategy(fn)` (single global pre-callLlm hook fired when the
        // predictive estimator trips the room-based threshold) and
        // `set_reserve_tokens(n)` (tunes that threshold). Stack:
        // [zag_table].
        sockets_bindings.registerCompactTable(lua);

        // zag.llm; namespace for direct LLM access from plugins. Today
        // only `complete{system, messages, max_tokens}` (one-shot
        // completion via the engine's currently-attached provider).
        // Yields the coroutine; resumes with the response text. Used
        // by the default compaction strategy to produce structured
        // summaries. Stack: [zag_table].
        @import("lua/bindings/llm.zig").registerLlmTable(lua);

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
    /// called from a C-closure registered after `storeSelfPointer` has run.
    /// A missing pointer means the binding ran before the engine stored
    /// itself; raise a Lua error so the misuse is catchable rather than a
    /// process abort. `raiseErrorStr` is noreturn and longjmps out of the
    /// C call frame, which is valid because every caller is a `zlua.wrap`'d
    /// closure invoked under a protected Lua call.
    pub fn getEngineFromState(lua: *Lua) *LuaEngine {
        _ = lua.getField(zlua.registry_index, "_zag_engine");
        const ptr = lua.toPointer(-1) catch {
            lua.pop(1);
            lua.raiseErrorStr("zag binding called before engine was initialized", .{});
        };
        lua.pop(1);
        return @ptrCast(@alignCast(@constCast(ptr)));
    }

    /// Sentinel stored in a coroutine's extraspace when no Task owns it
    /// yet. `lua.ref` never returns this value for a live registry slot, so
    /// it can never collide with a real `thread_ref`.
    const no_task_stash: usize = 0;

    /// Stash `task.thread_ref` (the `self.tasks` key) in `co`'s own
    /// per-thread extraspace so `taskForCoroutine` can recover the Task in
    /// O(1) via a single map lookup. Each coroutine created by
    /// `lua.newThread` carries its own pointer-sized extraspace block
    /// immediately preceding its `lua_State`, so this write is local to
    /// `co` and never aliases another thread's slot. We stash the integer
    /// key rather than the `*Task` pointer so the read path never forms a
    /// pointer from a possibly-garbage extraspace value.
    fn stashTaskOnCoroutine(co: *Lua, task: *Task) void {
        const space = co.getExtraSpace();
        const slot: *usize = @ptrCast(@alignCast(space.ptr));
        slot.* = refToStash(task.thread_ref);
    }

    fn refToStash(thread_ref: i32) usize {
        return @as(usize, @as(u32, @bitCast(thread_ref)));
    }

    /// Find the Task owning `co`. The fast path reads a `thread_ref` stashed
    /// in the coroutine's per-thread extraspace at spawn and looks it up in
    /// `self.tasks`; a hit is trusted only when the recovered Task's `.co`
    /// is `co`, so a stale or uninitialized block can never alias a live
    /// Task. Lua does not zero the main state's extraspace, and `zag.spawn`
    /// from `config.lua` passes that main state with no stashed Task, so the
    /// `t.co == co` check is load-bearing. Because only an integer map key
    /// is stashed (never a pointer), a garbage extraspace value can at worst
    /// miss the map or hit an unrelated live Task whose `.co` rejects it;
    /// the read path never dereferences a value-derived pointer. Falls back
    /// to a linear scan when the fast path misses.
    pub fn taskForCoroutine(self: *LuaEngine, co: *Lua) ?*Task {
        const space = co.getExtraSpace();
        const slot: *const usize = @ptrCast(@alignCast(space.ptr));
        const stashed = slot.*;
        if (stashed != no_task_stash and stashed <= std.math.maxInt(u32)) {
            const thread_ref: i32 = @bitCast(@as(u32, @intCast(stashed)));
            if (self.tasks.get(thread_ref)) |t| {
                if (t.co == co) return t;
            }
        }
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

        const thread_ref = engine.spawnCoroutine(nargs, parent) catch |err| switch (err) {
            error.AsyncRuntimeNotReady => co.raiseErrorStr(
                "zag.spawn: async runtime not ready (use it from a hook or tool, not at config top level)",
                .{},
            ),
            else => {
                var buf: [128]u8 = undefined;
                const msg = std.fmt.bufPrintZ(&buf, "zag.spawn failed: {s}", .{@errorName(err)}) catch "zag.spawn failed";
                co.raiseErrorStr("%s", .{msg.ptr});
            },
        };

        // Push the TaskHandle userdata on `co`'s stack; that's where the
        // caller expects zag.spawn's return value.
        const h = co.newUserdata(TaskHandle, 0);
        h.* = .{ .thread_ref = thread_ref, .engine = engine };
        _ = co.getMetatableRegistry(TaskHandle.METATABLE_NAME);
        co.setMetatable(-2);
        return 1;
    }

    /// `zag.detach(fn, args...)`: fire-and-forget spawn. Returns nothing;
    /// the caller has no handle and cannot cancel or join the child.
    /// The detached coroutine is parented to the root scope so its
    /// lifetime is independent of the caller's scope.
    fn zagDetachFn(co: *Lua) i32 {
        const engine = getEngineFromState(co);
        const nargs = co.getTop() - 1;
        if (nargs < 0) co.raiseErrorStr("zag.detach: missing fn", .{});
        if (!co.isFunction(1)) co.raiseErrorStr("zag.detach: arg 1 must be function", .{});

        if (co != engine.lua) {
            co.xMove(engine.lua, nargs + 1);
        }
        _ = engine.spawnCoroutine(nargs, null) catch |err| switch (err) {
            error.AsyncRuntimeNotReady => co.raiseErrorStr(
                "zag.detach: async runtime not ready (use it from a hook or tool, not at config top level)",
                .{},
            ),
            else => {
                var buf: [128]u8 = undefined;
                const msg = std.fmt.bufPrintZ(&buf, "zag.detach failed: {s}", .{@errorName(err)}) catch "zag.detach failed";
                co.raiseErrorStr("%s", .{msg.ptr});
            },
        };
        return 0;
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
    /// length for invalid UTF-8: the iterator runs over `Utf8View.initUnchecked`,
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

    /// Resolve the `*LuaEngine` stashed in the Lua registry by
    /// `storeSelfPointer`. Centralizes the lookup so binding modules
    /// (e.g. `lua/bindings/reminders.zig`) and any future caller share
    /// one warn-and-return-error path; distinct from
    /// `getEngineFromState`, which panics when the slot is empty.
    pub fn engineFromRegistry(lua: *Lua) !*LuaEngine {
        _ = lua.getField(zlua.registry_index, "_zag_engine");
        defer lua.pop(1);
        const ptr = lua.toPointer(-1) catch {
            log.warn("engine pointer not set (call storeSelfPointer first)", .{});
            return error.LuaError;
        };
        return @ptrCast(@alignCast(@constCast(ptr)));
    }

    /// Read accessor for the runtime reasoning_effort level. Providers
    /// that opted into `effort_request_field` consult this on each call
    /// to decide whether to inject the knob into the outgoing request.
    pub fn currentThinkingEffort(self: *LuaEngine) ?[]const u8 {
        return self.thinking_effort;
    }

    /// Validate that `value` matches one of `allowed`. Returns `value` on
    /// success; logs and returns `error.LuaError` on mismatch. Used for the
    /// closed enum-like fields on `ReasoningConfig` so a typo in `config.lua`
    /// surfaces at config-load time rather than after the request fails.
    pub fn requireOneOf(value: []const u8, allowed: []const []const u8, field: [:0]const u8) ![]const u8 {
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

    // -- zag.prompt ------------------------------------------------------------

    /// Thread-local engine handle consulted by `renderLuaLayer`. Set by
    /// `renderPromptLayers` around `Registry.render` so the thunk can
    /// find the Lua state that owns a layer's `lua_ref`. Thread-local
    /// (rather than a module global) so concurrent tests and subagents
    /// don't step on each other.
    pub threadlocal var active_render_engine: ?*LuaEngine = null;

    /// Build the `{tool, input, output, is_error}` context table the JIT
    /// context and tool-transform handlers both consume, leaving it on the
    /// stack top. Strings are copied into Lua memory by `pushString`, so the
    /// borrowed slices need not outlive this call.
    fn pushToolResultContext(lua: *Lua, tool: []const u8, tool_input: []const u8, output: []const u8, is_error: bool) void {
        lua.newTable();
        _ = lua.pushString(tool);
        lua.setField(-2, "tool");
        _ = lua.pushString(tool_input);
        lua.setField(-2, "input");
        _ = lua.pushString(output);
        lua.setField(-2, "output");
        lua.pushBoolean(is_error);
        lua.setField(-2, "is_error");
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

        // Build the context table the handler sees.
        pushToolResultContext(lua, req.tool_name, req.input, req.output, req.is_error);

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
        pushToolResultContext(lua, req.tool_name, req.input, req.output, req.is_error);

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

    /// Decode the strategy's top-of-stack return value (sitting on
    /// `co`'s stack at index -1) into a `CompactStrategyOutcome`. Used
    /// by `resumeTask`'s `.ok` arm when retiring a compact-strategy
    /// coroutine. Does NOT pop; the caller retires the task, which
    /// pops all return values via `co.pop(num_results)`.
    ///
    /// Three return shapes:
    ///   - nil / non-table / `{use_default = true}` → `.use_default`
    ///   - `{cancel = true}` → `.cancel`
    ///   - `{messages = [...], summary = "..."}` (or a bare numerically-
    ///     indexed array of messages) → `.replace`
    fn decodeCompactStrategyReturn(
        co: *Lua,
        allocator: Allocator,
    ) anyerror!agent_events.CompactStrategyOutcome {
        if (co.isNil(-1)) return .use_default;
        if (co.typeOf(-1) != .table) {
            log.warn(
                "compact strategy returned non-table (type {s}); treating as use_default",
                .{@tagName(co.typeOf(-1))},
            );
            return .use_default;
        }

        // Signal fields take precedence over the messages array.
        _ = co.getField(-1, "cancel");
        const want_cancel = co.toBoolean(-1);
        co.pop(1);
        if (want_cancel) return .cancel;

        _ = co.getField(-1, "use_default");
        const want_default = co.toBoolean(-1);
        co.pop(1);
        if (want_default) return .use_default;

        // Replacement path. Plugin may set `messages = {...}` with an
        // optional `summary = "..."`, OR pass a plain numerically-
        // indexed array of messages.
        _ = co.getField(-1, "messages");
        const has_messages_field = co.typeOf(-1) == .table;
        if (!has_messages_field) co.pop(1);

        const len = co.rawLen(-1);
        var collected: std.ArrayList(types.Message) = .empty;
        errdefer {
            for (collected.items) |m| m.deinit(allocator);
            collected.deinit(allocator);
        }
        for (0..len) |idx| {
            _ = co.rawGetIndex(-1, @intCast(idx + 1));
            const msg = try lua_message.decodeMessage(co, allocator);
            errdefer msg.deinit(allocator);
            try collected.append(allocator, msg);
            co.pop(1);
        }
        if (has_messages_field) co.pop(1); // pop the messages subtable

        // Optional summary string. At this point the return table is
        // at the top of the stack (we popped the messages subtable if
        // we got it via getField).
        var owned_summary: ?[]const u8 = null;
        _ = co.getField(-1, "summary");
        if (co.typeOf(-1) == .string) {
            const raw = co.toString(-1) catch "";
            owned_summary = allocator.dupe(u8, raw) catch null;
        }
        co.pop(1);

        return .{ .replace = .{
            .messages = try collected.toOwnedSlice(allocator),
            .summary = owned_summary,
        } };
    }

    /// Run the compaction strategy on a fresh coroutine so it can call
    /// yielding primitives (`zag.llm.complete`, `zag.fs.read`,
    /// `zag.cmd`, etc.). The strategy sees a full-fidelity message
    /// snapshot and returns one of three structured shapes; the return
    /// is decoded into `req.outcome` during the `.ok` resume in
    /// `resumeTask` via `decodeCompactStrategyReturn`.
    ///
    /// When the engine has no async runtime initialized (some tests,
    /// headless paths), we cannot spawn a coroutine — fall back to a
    /// direct `protectedCall` on the main lua state. Yielding
    /// primitives will fail in that path with a clear Lua error
    /// (`must be called inside zag.async/hook/keymap`); the strategy
    /// has to handle that itself (typically by returning nil so the
    /// Zig fallback chain runs).
    ///
    /// `done` timing contract: `AgentRunner.dispatchHookRequests` calls
    /// `req.done.set()` AFTER this function returns. The drain loop
    /// here completes when the coroutine retires, at which point
    /// `req.outcome` has been written by `resumeTask`. The agent thread
    /// observes the finalized outcome.
    pub fn handleCompactRequest(
        self: *LuaEngine,
        req: *agent_events.CompactRequest,
    ) anyerror!void {
        const fn_ref = self.compact_handler orelse return;

        const lua = self.lua;
        _ = lua.rawGetIndex(zlua.registry_index, fn_ref);
        if (!lua.isFunction(-1)) {
            lua.pop(1);
            log.warn("compact strategy: registry slot is not a function", .{});
            return;
        }

        // Build the context table on the main stack. spawnCoroutineForCompact
        // moves [fn, ctx] to the new thread via xMove.
        lua.newTable();
        lua.pushInteger(@intCast(req.tokens_used));
        lua.setField(-2, "tokens_used");
        lua.pushInteger(@intCast(req.tokens_max));
        lua.setField(-2, "tokens_max");
        try lua_message.pushMessageSnapshot(lua, req.messages);
        lua.setField(-2, "messages");

        if (self.async_runtime == null) {
            // Legacy synchronous path for engines without an async
            // runtime. Calls to zag.llm.complete from inside the
            // strategy will fail; the strategy should handle that and
            // return nil. Mirrors the fireHookSync fallback in fireHook.
            lua.protectedCall(.{ .args = 1, .results = 1 }) catch {
                const err_msg = lua.toString(-1) catch "<unprintable>";
                log.warn("compact strategy raised: {s}", .{err_msg});
                lua.pop(1);
                return error.LuaHandlerError;
            };
            defer lua.pop(1);
            req.outcome = decodeCompactStrategyReturn(lua, req.allocator) catch |err| blk: {
                log.warn("compact strategy decode failed: {s}", .{@errorName(err)});
                break :blk .use_default;
            };
            return;
        }

        const thread_ref = self.spawnCoroutineForCompact(1, null, req) catch |err| {
            log.warn("compact strategy spawn failed: {s}", .{@errorName(err)});
            // spawnCoroutineForCompact cleans up its own allocations on
            // error; the [fn, ctx] pair was already moved off the main
            // stack so nothing to pop here.
            return error.LuaHandlerError;
        };

        // Drain loop: pump completions until the task retires. resumeTask
        // writes req.outcome on `.ok` before retire, so when the task
        // exits self.tasks we know the outcome is final.
        while (self.tasks.contains(thread_ref)) {
            const runtime = self.async_runtime orelse unreachable;
            if (runtime.completions.pop()) |job| {
                try self.resumeFromJob(job);
            } else {
                // No completion available yet. 1ms idle matches fireHook's
                // drain cadence (src/lua/hook_registry.zig:215).
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }
        }
    }

    /// Test-only accessor for the compact strategy handler ref.
    pub fn compactHandler(self: *const LuaEngine) ?i32 {
        return self.compact_handler;
    }

    /// Paired with `active_render_engine`. `renderPromptLayers` sets both
    /// per layer so the thunk can cheaply identify which registry entry
    /// it is servicing without carrying user-data on the Layer type.
    pub threadlocal var active_render_layer: ?*const prompt.Layer = null;

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
    pub fn pushLayerContextTable(lua: *Lua, ctx: *const prompt.LayerContext) void {
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

        const runtime = try IoBackend.init(self.allocator, num_workers, capacity);
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
        return self.spawnCoroutineFull(nargs, parent_scope, hook_payload, null);
    }

    /// Spawn variant that also accepts a `compact_request` pointer. The
    /// strategy's return value is decoded into `req.outcome` during the
    /// final `.ok` resume — see `decodeCompactStrategyReturn`. This is
    /// the entry point `handleCompactRequest` uses; hook callers stay
    /// on `spawnCoroutineTagged` which passes null.
    fn spawnCoroutineForCompact(
        self: *LuaEngine,
        nargs: i32,
        parent_scope: ?*async_scope.Scope,
        req: *agent_events.CompactRequest,
    ) !i32 {
        return self.spawnCoroutineFull(nargs, parent_scope, null, req);
    }

    fn spawnCoroutineFull(
        self: *LuaEngine,
        nargs: i32,
        parent_scope: ?*async_scope.Scope,
        hook_payload: ?*Hooks.HookPayload,
        compact_request: ?*agent_events.CompactRequest,
    ) !i32 {
        // The async runtime must be up before a coroutine can be scheduled.
        // Internal callers (hooks, compaction) only run after `initAsync`,
        // but the Lua-facing `zag.spawn`/`zag.detach` are reachable from
        // config.lua, which `loadUserConfig` runs BEFORE `initAsync`. Surface
        // that as a catchable error (the entry points raise a Lua error,
        // absorbed by loadConfig's protectedCall) instead of asserting and
        // aborting the whole process.
        if (self.async_runtime == null) return error.AsyncRuntimeNotReady;
        std.debug.assert(hook_payload == null or compact_request == null); // mutually exclusive tags

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
            .compact_request = compact_request,
            .started_at_ms = if (hook_payload != null) std.time.milliTimestamp() else 0,
            .budget_ms = if (hook_payload != null) self.hook_dispatcher.hook_budget_ms else null,
        };

        // Stash the Task in the coroutine's extraspace for O(1) lookup in
        // taskForCoroutine. Written here so the slot is valid before the
        // coroutine first resumes; the linear-scan fallback remains the
        // ground truth, so a missed or stale stash is never fatal.
        stashTaskOnCoroutine(co, task);

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
                } else if (task.compact_request) |req| {
                    // Compact-strategy retire path. The strategy's return
                    // value lives at the coroutine's stack top; decode
                    // it into req.outcome before retire pops the slot.
                    // Decode errors fail-soft to `.use_default` so the
                    // agent loop's Zig fallback still runs.
                    if (num_results >= 1) {
                        req.outcome = decodeCompactStrategyReturn(task.co, req.allocator) catch |err| blk: {
                            log.warn("compact strategy return decode failed (task={d}): {}", .{
                                task.thread_ref, err,
                            });
                            break :blk .use_default;
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

        // Re-parent any still-live children to the root scope so that
        // fire-and-forget spawn / detach can outlive their parent without
        // triggering the Scope orphan invariant.
        if (task.scope.children.items.len > 0) {
            const root = self.root_scope.?;
            task.scope.mu.lock();
            defer task.scope.mu.unlock();
            root.mu.lock();
            defer root.mu.unlock();
            for (task.scope.children.items) |child| {
                child.parent = root;
                root.children.append(self.allocator, child) catch {};
            }
            task.scope.children.items.len = 0;
        }

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

test "taskForCoroutine fast path matches the linear scan for a yielding coroutine" {
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    eng.storeSelfPointer();
    try eng.initAsync(2, 16);
    defer eng.deinitAsync();

    try eng.lua.doString(
        \\function test_lookup() zag.sleep(10) end
    );
    _ = try eng.lua.getGlobal("test_lookup");
    _ = try eng.spawnCoroutine(0, null);

    // The coroutine yielded inside zag.sleep, so exactly one task is parked
    // in the map. Recover its coroutine via a manual scan, then assert the
    // extraspace fast path resolves the identical *Task.
    try std.testing.expectEqual(@as(u32, 1), eng.tasks.count());
    var scanned: ?*LuaEngine.Task = null;
    var it = eng.tasks.iterator();
    while (it.next()) |entry| scanned = entry.value_ptr.*;
    const expected = scanned.?;

    const found = eng.taskForCoroutine(expected.co) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(expected, found);

    // Drain to completion so the task retires and nothing leaks.
    const deadline = std.time.milliTimestamp() + 500;
    while (eng.tasks.count() > 0 and std.time.milliTimestamp() < deadline) {
        if (eng.async_runtime.?.completions.pop()) |job| {
            try eng.resumeFromJob(job);
        } else {
            std.Thread.sleep(1 * std.time.ns_per_ms);
        }
    }
    try std.testing.expectEqual(@as(u32, 0), eng.tasks.count());
}

test "taskForCoroutine returns null for the main state with no stashed task" {
    var eng = try LuaEngine.init(std.testing.allocator);
    defer eng.deinit();
    eng.storeSelfPointer();

    // The engine's main lua state is never any task's coroutine, and Lua
    // does not zero its extraspace. The validation in taskForCoroutine must
    // reject whatever garbage sits there rather than alias a live Task.
    try std.testing.expect(eng.taskForCoroutine(eng.lua) == null);
}

test "getEngineFromState raises a catchable Lua error when the pointer is missing" {
    // A bare Lua state with no `_zag_engine` registry entry stands in for a
    // binding invoked before storeSelfPointer ran. getEngineFromState must
    // surface a Lua error (caught here by protectedCall) instead of
    // aborting the process via unreachable.
    const lua = try Lua.init(std.testing.allocator);
    defer lua.deinit();

    const probe = struct {
        fn call(state: *Lua) i32 {
            _ = LuaEngine.getEngineFromState(state);
            return 0;
        }
    };
    lua.pushFunction(zlua.wrap(probe.call));
    try std.testing.expectError(error.LuaRuntime, lua.protectedCall(.{ .args = 0, .results = 0 }));
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
        \\_G.id_fn  = zag.keymap { mode = "normal", key = "<C-x>", fn = function() end }
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

test "bash_tool.Config defaults to permissive" {
    // Regression pin: the bash sandbox is opt-IN since 2026-05-25; the
    // default Config must be permissive so an unconfigured user gets the
    // straightforward no-sandbox behavior.
    const cfg: bash_tool.Config = .{};
    try std.testing.expect(cfg.permissive);
}

test "zag.set_bash_sandbox_level toggles bash_config in both directions" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    var bash_config: bash_tool.Config = .{};
    engine.bash_config = &bash_config;
    // Default is permissive after the 2026-05-25 flip.
    try std.testing.expect(bash_config.permissive);

    try engine.lua.doString("zag.set_bash_sandbox_level('strict')");
    try std.testing.expect(!bash_config.permissive);

    try engine.lua.doString("zag.set_bash_sandbox_level('permissive')");
    try std.testing.expect(bash_config.permissive);
}

test "zag.set_bash_sandbox_level rejects unknown level" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    var bash_config: bash_tool.Config = .{};
    engine.bash_config = &bash_config;

    const result = engine.lua.doString("zag.set_bash_sandbox_level('yolo')");
    try std.testing.expectError(error.LuaRuntime, result);
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
    try std.testing.expectEqual(@as(llm.Factory, llm.anthropic.create), ep.factory);
    try std.testing.expectEqual(false, ep.wire_semantics.cached_overlaps_input);
    try std.testing.expectEqual(llm.Endpoint.Auth.x_api_key, ep.auth);
    try std.testing.expectEqualStrings("claude-sonnet-4-20250514", ep.default_model);
    try std.testing.expectEqual(@as(usize, 1), ep.models.len);
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), ep.models[0].input_per_mtok, 0.001);
    try std.testing.expectEqual(@as(u32, 200000), ep.models[0].context_window);
}

test "zag.provider{}: timeouts table lands on the endpoint" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.provider{
        \\  name = "custom",
        \\  url = "http://example.invalid",
        \\  wire = "anthropic",
        \\  auth = { kind = "none" },
        \\  default_model = "m",
        \\  timeouts = {
        \\    connect_ms = 5000,
        \\    read_ms    = 7000,
        \\    write_ms   = 9000,
        \\  },
        \\}
    );
    const ep = engine.providers_registry.find("custom") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 5000), ep.timeouts.connect_ms);
    try std.testing.expectEqual(@as(u32, 7000), ep.timeouts.read_ms);
    try std.testing.expectEqual(@as(u32, 9000), ep.timeouts.write_ms);
}

test "zag.provider{}: omitted timeouts table keeps registry defaults" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.provider{
        \\  name = "custom2",
        \\  url = "http://example.invalid",
        \\  wire = "anthropic",
        \\  auth = { kind = "none" },
        \\  default_model = "m",
        \\}
    );
    const ep = engine.providers_registry.find("custom2") orelse return error.TestUnexpectedResult;
    const defaults: llm.Endpoint.TimeoutConfig = .{};
    try std.testing.expectEqual(defaults.connect_ms, ep.timeouts.connect_ms);
    try std.testing.expectEqual(defaults.read_ms, ep.timeouts.read_ms);
    try std.testing.expectEqual(defaults.write_ms, ep.timeouts.write_ms);
}

test "zag.provider{}: wire_semantics table overrides the wire-derived default" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    // openai-wire defaults to cached_overlaps_input=true; override to false.
    try engine.lua.doString(
        \\zag.provider{
        \\  name = "openai-anthropic-shaped",
        \\  url = "http://example.invalid",
        \\  wire = "openai",
        \\  auth = { kind = "bearer" },
        \\  default_model = "m",
        \\  wire_semantics = { cached_overlaps_input = false },
        \\}
    );
    const ep_a = engine.providers_registry.find("openai-anthropic-shaped") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(false, ep_a.wire_semantics.cached_overlaps_input);

    // anthropic-wire defaults to cached_overlaps_input=false; override to true.
    try engine.lua.doString(
        \\zag.provider{
        \\  name = "anthropic-openai-shaped",
        \\  url = "http://example.invalid",
        \\  wire = "anthropic",
        \\  auth = { kind = "x_api_key" },
        \\  default_model = "m",
        \\  wire_semantics = { cached_overlaps_input = true },
        \\}
    );
    const ep_b = engine.providers_registry.find("anthropic-openai-shaped") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(true, ep_b.wire_semantics.cached_overlaps_input);
}

test "zag.provider{}: omitted wire_semantics table keeps wire-derived default" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.provider{
        \\  name = "default-openai",
        \\  url = "http://example.invalid",
        \\  wire = "openai",
        \\  auth = { kind = "bearer" },
        \\  default_model = "m",
        \\}
    );
    const ep = engine.providers_registry.find("default-openai") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(true, ep.wire_semantics.cached_overlaps_input);
}

test "zag.provider{}: malformed wire_semantics surfaces LuaRuntime" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    // Non-boolean cached_overlaps_input is a user error, not a fall-back.
    try std.testing.expectError(
        error.LuaRuntime,
        engine.lua.doString(
            \\zag.provider{
            \\  name = "bad-wire-semantics",
            \\  url = "http://example.invalid",
            \\  wire = "openai",
            \\  auth = { kind = "bearer" },
            \\  default_model = "m",
            \\  wire_semantics = { cached_overlaps_input = "yes" },
            \\}
        ),
    );
}

test "zag.providers.list() surfaces timeouts subtable" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.provider{
        \\  name = "listed",
        \\  url = "http://example.invalid",
        \\  wire = "anthropic",
        \\  auth = { kind = "none" },
        \\  default_model = "m",
        \\  timeouts = { connect_ms = 1234, read_ms = 5678, write_ms = 91011 },
        \\}
        \\local snap = zag.providers.list()
        \\local entry = assert(snap.listed, "missing entry")
        \\local t = assert(entry.timeouts, "missing timeouts")
        \\assert(t.connect_ms == 1234, "connect_ms drift: " .. tostring(t.connect_ms))
        \\assert(t.read_ms    == 5678, "read_ms drift: "    .. tostring(t.read_ms))
        \\assert(t.write_ms   == 91011, "write_ms drift: "   .. tostring(t.write_ms))
    );
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

    const result = try provider_bindings.readStringArray(engine.lua, outer, "fields", allocator);
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

    const result = try provider_bindings.readStringArray(engine.lua, outer, "fields", allocator);
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

    try std.testing.expectError(error.LuaError, provider_bindings.readStringArray(engine.lua, outer, "fields", allocator));
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
    // before they return their strings. Use generous gaps so scheduling jitter
    // on slow CI runners cannot accidentally flip the winner.
    try eng.lua.doString(
        \\function test_race()
        \\  local v, err, idx = zag.race({
        \\    function() zag.sleep(300); return "slow" end,
        \\    function() zag.sleep(10); return "fast" end,
        \\    function() zag.sleep(600); return "slower" end,
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

    const got = try provider_bindings.readStringField(engine.lua, -1, "name", .required, std.testing.allocator);
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
        provider_bindings.readStringField(engine.lua, -1, "name", .required, std.testing.allocator),
    );
}

test "readStringField: missing field in optional mode returns null" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString("t = {}");
    _ = try engine.lua.getGlobal("t");
    defer engine.lua.pop(1);

    const got = try provider_bindings.readStringField(engine.lua, -1, "name", .optional, std.testing.allocator);
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
        provider_bindings.readStringField(engine.lua, -1, "name", .required, std.testing.allocator),
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

    const headers = try provider_bindings.readHeaderList(engine.lua, -1, "headers", std.testing.allocator);
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

    const headers = try provider_bindings.readHeaderList(engine.lua, -1, "headers", std.testing.allocator);
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

    const headers = try provider_bindings.readHeaderList(engine.lua, -1, "headers", std.testing.allocator);
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
    try std.testing.expectEqual(@as(llm.Factory, llm.anthropic.create), ep.factory);
    try std.testing.expectEqual(false, ep.wire_semantics.cached_overlaps_input);
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
    try std.testing.expectEqual(@as(llm.Factory, llm.openai.create), ep.factory);
    try std.testing.expectEqual(true, ep.wire_semantics.cached_overlaps_input);
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
    try std.testing.expectEqual(@as(llm.Factory, llm.openai.create), ep.factory);
    try std.testing.expectEqual(true, ep.wire_semantics.cached_overlaps_input);
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
    try std.testing.expectEqual(@as(llm.Factory, llm.openai.create), ep.factory);
    try std.testing.expectEqual(true, ep.wire_semantics.cached_overlaps_input);
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
    try std.testing.expectEqual(@as(llm.Factory, llm.openai.create), ep.factory);
    try std.testing.expectEqual(true, ep.wire_semantics.cached_overlaps_input);
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
    try std.testing.expectEqual(@as(llm.Factory, llm.chatgpt.create), ep.factory);
    try std.testing.expectEqual(true, ep.wire_semantics.cached_overlaps_input);
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
    try std.testing.expectEqual(@as(llm.Factory, llm.anthropic.create), ep.factory);
    try std.testing.expectEqual(false, ep.wire_semantics.cached_overlaps_input);
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
    const handle_value = try engine.lua.toString(-1);
    const handle = try BufferRegistry.parseId(handle_value);
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
    const handle_value = try engine.lua.toString(-1);
    const handle = try BufferRegistry.parseId(handle_value);
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

test "zag.buffer.create kind=\"graphics\" returns a resolvable image handle" {
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
    const handle_value = try engine.lua.toString(-1);
    const handle = try BufferRegistry.parseId(handle_value);
    const entry = try buffer_registry.resolve(handle);
    try std.testing.expect(entry == .image);
    try std.testing.expectEqualStrings("diagram", entry.image.name);
}

test "zag.buffer.set_png stores decoded image on an image handle" {
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
    const handle_value = try engine.lua.toString(-1);
    const handle = try BufferRegistry.parseId(handle_value);
    const entry = try buffer_registry.resolve(handle);
    try std.testing.expect(entry == .image);
    try std.testing.expect(entry.image.image != null);
    try std.testing.expectEqual(@as(u32, 1), entry.image.image.?.width);
    try std.testing.expectEqual(@as(u32, 1), entry.image.image.?.height);
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
    const handle_value = try engine.lua.toString(-1);
    engine.lua.pop(1);
    const handle = try BufferRegistry.parseId(handle_value);
    const entry = try buffer_registry.resolve(handle);
    try std.testing.expectEqual(ImageBuffer.Fit.actual, entry.image.fit);

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
    const handle_value = try engine.lua.toString(-1);
    const handle = try BufferRegistry.parseId(handle_value);
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
    const handle_value = try engine.lua.toString(-1);
    const handle = try BufferRegistry.parseId(handle_value);
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

test "loadBuiltinPlugins registers the default general subagent" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    // Empty before bootstrap; the `task` tool would be gated off here.
    try std.testing.expectEqual(@as(usize, 0), engine.subagentRegistry().entries.items.len);
    engine.loadBuiltinPlugins();
    // The shipped delegate makes delegation work with zero user config:
    // a non-empty registry is what `tools.registerTaskTool` gates on.
    try std.testing.expect(engine.subagentRegistry().lookup("general") != null);
}

test "loadBuiltinPlugins auto-requires the filesystem subagent loader" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    engine.loadBuiltinPlugins();
    // Without auto-load a user would have to `require` it before a dropped
    // agent `.md` is discovered. Proof it ran: package.loaded is populated.
    try engine.lua.doString("_fs_loaded = package.loaded['zag.subagents.filesystem'] ~= nil");
    _ = try engine.lua.getGlobal("_fs_loaded");
    defer engine.lua.pop(1);
    try std.testing.expect(engine.lua.toBoolean(-1));
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

test "zag.compact.strategy registers and unregisters" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try std.testing.expect(engine.compactHandler() == null);
    try engine.lua.doString("zag.compact.strategy(function(ctx) return nil end)");
    try std.testing.expect(engine.compactHandler() != null);

    try engine.lua.doString("zag.compact.strategy(nil)");
    try std.testing.expect(engine.compactHandler() == null);
}

test "handleCompactRequest nil return leaves outcome as use_default" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString("zag.compact.strategy(function(ctx) return nil end)");

    var b1 = [_]types.ContentBlock{.{ .text = .{ .text = "hi" } }};
    const messages = [_]types.Message{.{ .role = .user, .content = &b1 }};
    var req = agent_events.CompactRequest.init(&messages, 100, 1000, alloc);
    defer req.freeOutcome();
    try engine.handleCompactRequest(&req);
    try std.testing.expect(req.outcome == .use_default);
}

test "handleCompactRequest honours {cancel = true}" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString("zag.compact.strategy(function(ctx) return { cancel = true } end)");

    var b1 = [_]types.ContentBlock{.{ .text = .{ .text = "hi" } }};
    const messages = [_]types.Message{.{ .role = .user, .content = &b1 }};
    var req = agent_events.CompactRequest.init(&messages, 100, 1000, alloc);
    defer req.freeOutcome();
    try engine.handleCompactRequest(&req);
    try std.testing.expect(req.outcome == .cancel);
}

test "handleCompactRequest accepts {messages, summary} replacement" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.compact.strategy(function(ctx)
        \\  return {
        \\    messages = {
        \\      { role = "user", content = {{ type = "text", text = "compacted" }} },
        \\    },
        \\    summary = "the prior story in brief",
        \\  }
        \\end)
    );

    var b1 = [_]types.ContentBlock{.{ .text = .{ .text = "long history" } }};
    const messages = [_]types.Message{.{ .role = .user, .content = &b1 }};
    var req = agent_events.CompactRequest.init(&messages, 100, 1000, alloc);
    defer req.freeOutcome();
    try engine.handleCompactRequest(&req);
    switch (req.outcome) {
        .replace => |r| {
            try std.testing.expectEqual(@as(usize, 1), r.messages.len);
            try std.testing.expectEqualStrings("compacted", r.messages[0].content[0].text.text);
            try std.testing.expect(r.summary != null);
            try std.testing.expectEqualStrings("the prior story in brief", r.summary.?);
        },
        else => return error.TestUnexpectedOutcome,
    }
}

test "handleCompactRequest preserves tool_use block fidelity in the snapshot" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    // Strategy echoes back the type tag of the second block from the
    // first message, so a successful round-trip proves the v2 push
    // serialized the tool_use variant rather than dropping it.
    try engine.lua.doString(
        \\zag.compact.strategy(function(ctx)
        \\  local m = ctx.messages[1]
        \\  local tag = m.content[2].type
        \\  return {
        \\    messages = {
        \\      { role = "user", content = {{ type = "text", text = "saw=" .. tag }} },
        \\    },
        \\  }
        \\end)
    );

    const blocks = [_]types.ContentBlock{
        .{ .text = .{ .text = "do it" } },
        .{ .tool_use = .{ .id = "t1", .name = "read", .input_raw = "{}" } },
    };
    const messages = [_]types.Message{.{ .role = .assistant, .content = &blocks }};
    var req = agent_events.CompactRequest.init(&messages, 100, 1000, alloc);
    defer req.freeOutcome();
    try engine.handleCompactRequest(&req);
    switch (req.outcome) {
        .replace => |r| {
            try std.testing.expectEqualStrings("saw=tool_use", r.messages[0].content[0].text.text);
        },
        else => return error.TestUnexpectedOutcome,
    }
}

test "zag.llm.complete is registered as a callable on the zag table" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    // Probe via Lua: the table and the field must exist as a function.
    // Calling it without a coroutine would error at the yieldable
    // check, so we just inspect the type.
    try engine.lua.doString(
        \\assert(type(zag.llm) == "table", "zag.llm table missing")
        \\assert(type(zag.llm.complete) == "function", "zag.llm.complete missing")
    );
}

test "zag.llm.complete rejects calls from outside a coroutine" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    // No coroutine, no agent loop. The yieldable check must trip first
    // and surface as a Lua error.
    try engine.lua.doString(
        \\local ok, err = pcall(function() zag.llm.complete({system="x", messages={{role="user", content="hi"}}}) end)
        \\if ok then error("expected zag.llm.complete to raise outside a coroutine") end
    );
}

test "zag.compact.set_reserve_tokens writes engine.compact_reserve_tokens" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    // Default seeded from agent.DEFAULT_RESERVE_TOKENS.
    const agent = @import("agent.zig");
    try std.testing.expectEqual(agent.DEFAULT_RESERVE_TOKENS, engine.compact_reserve_tokens);

    try engine.lua.doString("zag.compact.set_reserve_tokens(8192)");
    try std.testing.expectEqual(@as(u32, 8192), engine.compact_reserve_tokens);

    // Zero is legal: disables the buffer, estimator still gates the call.
    try engine.lua.doString("zag.compact.set_reserve_tokens(0)");
    try std.testing.expectEqual(@as(u32, 0), engine.compact_reserve_tokens);
}

test "zag.compact.set_reserve_tokens rejects negative integers" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    // Lua's pcall lets us assert the Zig-side error surfaces as a Lua error
    // without crashing the test.
    try engine.lua.doString(
        \\local ok, err = pcall(zag.compact.set_reserve_tokens, -1)
        \\if ok then error("expected set_reserve_tokens(-1) to raise") end
    );
    // Engine value must remain the default after the rejected call.
    const agent = @import("agent.zig");
    try std.testing.expectEqual(agent.DEFAULT_RESERVE_TOKENS, engine.compact_reserve_tokens);
}

test "loadBuiltinPlugins eager-loads zag.compact.* entries" {
    // The default compaction strategy registers a single global
    // handler so the socket is wired up out of the box.
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try std.testing.expect(engine.compactHandler() == null);
    engine.loadBuiltinPlugins();
    try std.testing.expect(engine.compactHandler() != null);
}

test "zag.compact.default produces a structured summary end-to-end" {
    // Full Lua path: real default plugin, real coroutine spawn, real
    // worker pool, stub provider returning the summary text. Asserts
    // the strategy produced a .replace outcome whose summary message
    // wraps the provider's response in the prefix/suffix sentinels
    // (so the next iteration can detect a prior summary).
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);
    defer engine.deinitAsync();
    engine.loadBuiltinPlugins();

    var stub = StubCompactProvider{ .response_text = "## Goal\nport pi-mono" };
    const provider = stub.provider();
    engine.current_provider = &provider;
    engine.current_model_spec = .{ .provider_name = "stub", .model_id = "stub-1" };
    defer {
        engine.current_provider = null;
        engine.current_model_spec = null;
    }

    // Shrink keep_recent so the small fixture trips the cut.
    try engine.lua.doString("zag.compact.set_keep_recent_tokens(1)");

    // Three-message fixture so the cut leaves a non-empty
    // summarize range.
    var b1 = [_]types.ContentBlock{.{ .text = .{ .text = "first question" } }};
    var b2 = [_]types.ContentBlock{.{ .text = .{ .text = "first answer" } }};
    var b3 = [_]types.ContentBlock{.{ .text = .{ .text = "now do the thing" } }};
    const messages = [_]types.Message{
        .{ .role = .user, .content = &b1 },
        .{ .role = .assistant, .content = &b2 },
        .{ .role = .user, .content = &b3 },
    };
    var req = agent_events.CompactRequest.init(&messages, 850, 1000, alloc);
    defer req.freeOutcome();

    try engine.handleCompactRequest(&req);
    switch (req.outcome) {
        .replace => |r| {
            // First message must be the wrapped summary; the prefix
            // is byte-identical between the Lua prompts.lua constant
            // and the Zig COMPACTION_SUMMARY_PREFIX so the next
            // iteration's extractPriorSummary recognises it.
            try std.testing.expect(r.messages.len >= 1);
            const summary_text = r.messages[0].content[0].text.text;
            try std.testing.expect(std.mem.indexOf(u8, summary_text, "<summary>") != null);
            try std.testing.expect(std.mem.indexOf(u8, summary_text, "</summary>") != null);
            try std.testing.expect(std.mem.indexOf(u8, summary_text, "## Goal") != null);
        },
        else => return error.TestUnexpectedOutcome,
    }
}

test "zag.compact.default returns .use_default when no provider is attached" {
    // The Lua default strategy calls zag.llm.complete. Without an
    // async runtime AND without a current_provider attached, the
    // primitive surfaces an error which the strategy catches and
    // returns nil from — outcome becomes .use_default so the Zig
    // fallback chain runs. This is the safe-by-default behaviour
    // when no engine wiring is in place (tests / headless eval).
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString("require('zag.compact.default')");
    try std.testing.expect(engine.compactHandler() != null);

    var b1 = [_]types.ContentBlock{.{ .text = .{ .text = "ask" } }};
    var b2 = [_]types.ContentBlock{.{ .text = .{ .text = "answer" } }};
    const messages = [_]types.Message{
        .{ .role = .user, .content = &b1 },
        .{ .role = .assistant, .content = &b2 },
    };
    var req = agent_events.CompactRequest.init(&messages, 850, 1000, alloc);
    defer req.freeOutcome();
    try engine.handleCompactRequest(&req);
    try std.testing.expect(req.error_name == null);
    try std.testing.expect(req.outcome == .use_default);
}

// Stub provider for the compact-strategy-on-coroutine integration test.
// Mirrors the call vtable that `zag.llm.complete`'s worker
// (src/lua/primitives/llm.zig) invokes. Returns a single text block
// with `response_text`.
const StubCompactProvider = struct {
    response_text: []const u8,

    const vtable: @import("llm.zig").Provider.VTable = .{
        .call = callImpl,
        .call_streaming = callStreamingImpl,
        .name = "stub_compact",
    };

    fn callImpl(
        ptr: *anyopaque,
        req: *const @import("llm.zig").Request,
    ) @import("llm.zig").ProviderError!types.LlmResponse {
        const self: *StubCompactProvider = @ptrCast(@alignCast(ptr));
        const text = try req.allocator.dupe(u8, self.response_text);
        errdefer req.allocator.free(text);
        const blocks = try req.allocator.alloc(types.ContentBlock, 1);
        blocks[0] = .{ .text = .{ .text = text } };
        return .{
            .content = blocks,
            .stop_reason = .end_turn,
            .input_tokens = 1,
            .output_tokens = @intCast(self.response_text.len),
        };
    }

    fn callStreamingImpl(
        ptr: *anyopaque,
        req: *const @import("llm.zig").StreamRequest,
    ) @import("llm.zig").ProviderError!types.LlmResponse {
        // Used by the streaming path of zag.llm.complete. Emits the
        // canned response as a single text_delta, then returns the
        // standard "no content, end_turn" shape — the worker's
        // streamed-accumulator fallback assembles the real text from
        // the emitted delta.
        const self: *StubCompactProvider = @ptrCast(@alignCast(ptr));
        req.callback.on_event(req.callback.ctx, .{ .text_delta = self.response_text });
        return .{
            .content = &.{},
            .stop_reason = .end_turn,
            .input_tokens = 1,
            .output_tokens = 1,
        };
    }

    fn provider(self: *StubCompactProvider) @import("llm.zig").Provider {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

test "handleCompactRequest strategy can yield on zag.llm.complete" {
    // The migration's payoff: a strategy that calls zag.llm.complete
    // suspends its coroutine, the worker pool runs the LLM call, the
    // main thread's drain loop in handleCompactRequest pumps the
    // completion back, the strategy resumes with the response, and
    // its structured return lands in req.outcome.
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);
    defer engine.deinitAsync();

    var stub = StubCompactProvider{ .response_text = "STUB SUMMARY" };
    const provider = stub.provider();
    engine.current_provider = &provider;
    engine.current_model_spec = .{ .provider_name = "stub", .model_id = "stub-1" };
    defer {
        engine.current_provider = null;
        engine.current_model_spec = null;
    }

    try engine.lua.doString(
        \\zag.compact.strategy(function(ctx)
        \\  local resp, err = zag.llm.complete({
        \\    system = "summarize",
        \\    messages = {{ role = "user", content = "history" }},
        \\  })
        \\  if not resp then
        \\    return nil
        \\  end
        \\  return {
        \\    messages = { { role = "user", content = {{ type = "text", text = resp.text }} } },
        \\    summary = resp.text,
        \\  }
        \\end)
    );

    var b1 = [_]types.ContentBlock{.{ .text = .{ .text = "history" } }};
    const messages = [_]types.Message{.{ .role = .user, .content = &b1 }};
    var req = agent_events.CompactRequest.init(&messages, 850, 1000, alloc);
    defer req.freeOutcome();

    try engine.handleCompactRequest(&req);

    switch (req.outcome) {
        .replace => |r| {
            try std.testing.expectEqual(@as(usize, 1), r.messages.len);
            try std.testing.expectEqualStrings(
                "STUB SUMMARY",
                r.messages[0].content[0].text.text,
            );
            try std.testing.expect(r.summary != null);
            try std.testing.expectEqualStrings("STUB SUMMARY", r.summary.?);
        },
        else => return error.TestUnexpectedOutcome,
    }
}

test "handleCompactRequest synchronous strategy still works without async runtime" {
    // Strategies that don't call yielding primitives must still work
    // when the engine has no async runtime (some tests, headless paths).
    // The legacy protectedCall fallback in handleCompactRequest covers
    // this case.
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    // Deliberately NO initAsync — exercise the legacy path.

    try engine.lua.doString(
        \\zag.compact.strategy(function(ctx)
        \\  return {
        \\    messages = { { role = "user", content = {{ type = "text", text = "sync ok" }} } },
        \\  }
        \\end)
    );

    var b1 = [_]types.ContentBlock{.{ .text = .{ .text = "history" } }};
    const messages = [_]types.Message{.{ .role = .user, .content = &b1 }};
    var req = agent_events.CompactRequest.init(&messages, 850, 1000, alloc);
    defer req.freeOutcome();

    try engine.handleCompactRequest(&req);
    switch (req.outcome) {
        .replace => |r| try std.testing.expectEqualStrings("sync ok", r.messages[0].content[0].text.text),
        else => return error.TestUnexpectedOutcome,
    }
}

// -- Phase 5 test backfill -------------------------------------------------
// Three deleted v1 tests are now structurally covered by the existing
// strategy_v2-era tests above (nil-return → use_default,
// replace-returns-shape, tool_use-block-fidelity). The seven gap tests
// below close the holes Agent D identified.

test "handleCompactRequest sync strategy raising Lua error surfaces LuaHandlerError" {
    // Phase 5 backfill (v1 port): the deleted "returns null and warns
    // on strategy error" test, ported onto the strategy_v2 contract
    // along its legacy sync path. The coroutine variant has different
    // error semantics (logged + retired with outcome stay-default);
    // see the next test.
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.compact.strategy(function(ctx) error("boom") end)
    );

    var b1 = [_]types.ContentBlock{.{ .text = .{ .text = "ask" } }};
    const messages = [_]types.Message{.{ .role = .user, .content = &b1 }};
    var req = agent_events.CompactRequest.init(&messages, 850, 1000, alloc);
    defer req.freeOutcome();

    try std.testing.expectError(error.LuaHandlerError, engine.handleCompactRequest(&req));
    // Outcome stays at its initialised default; the agent loop's
    // fallback chain still runs when error_name is set on the request
    // surface by the dispatch wrapper (AgentRunner translates the
    // returned error to req.error_name).
    try std.testing.expect(req.outcome == .use_default);
}

test "handleCompactRequest async strategy raising Lua error does not deadlock" {
    // The coroutine path's retire-on-error keeps the drain loop
    // unblocked: handleCompactRequest returns cleanly with outcome
    // staying at its initialised default. The error is logged but
    // not surfaced as a Zig error because the coroutine retired —
    // there is no protectedCall site to translate. The agent loop's
    // Zig fallback chain takes over when it sees .use_default.
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);
    defer engine.deinitAsync();

    try engine.lua.doString(
        \\zag.compact.strategy(function(ctx) error("boom") end)
    );

    var b1 = [_]types.ContentBlock{.{ .text = .{ .text = "ask" } }};
    const messages = [_]types.Message{.{ .role = .user, .content = &b1 }};
    var req = agent_events.CompactRequest.init(&messages, 850, 1000, alloc);
    defer req.freeOutcome();

    try engine.handleCompactRequest(&req);
    try std.testing.expect(req.outcome == .use_default);
}

test "handleCompactRequest treats malformed return as use_default" {
    // Strategy returns an integer instead of nil / table. Decoder
    // logs a warn and falls back to .use_default so the agent loop's
    // safety chain still runs. This is the "rejects invalid outcome
    // shape" gap.
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString("zag.compact.strategy(function(ctx) return 42 end)");

    var b1 = [_]types.ContentBlock{.{ .text = .{ .text = "ask" } }};
    const messages = [_]types.Message{.{ .role = .user, .content = &b1 }};
    var req = agent_events.CompactRequest.init(&messages, 850, 1000, alloc);
    defer req.freeOutcome();

    try engine.handleCompactRequest(&req);
    try std.testing.expect(req.outcome == .use_default);
}

test "zag.compact.set_keep_recent_tokens reads back through get_keep_recent_tokens" {
    // The default Lua strategy reads the budget through
    // get_keep_recent_tokens to pick a cut point. Verifying the
    // round-trip here proves the knob is observable from Lua and that
    // its value survives whatever encoding the binding does.
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\local before = zag.compact.get_keep_recent_tokens()
        \\zag.compact.set_keep_recent_tokens(4242)
        \\local after = zag.compact.get_keep_recent_tokens()
        \\assert(before > 0, "default should be non-zero")
        \\assert(after == 4242, "set should be observable through get")
    );

    try std.testing.expectEqual(@as(u32, 4242), engine.compact_keep_recent_tokens);
}

test "runDefaultSummarization detects prior summary and switches to UPDATE prompt" {
    // Iterative-update path: when messages[0] is wrapped with the
    // compaction summary sentinels, the Zig fallback should switch
    // from SUMMARIZATION_PROMPT_TEMPLATE to
    // UPDATE_SUMMARIZATION_PROMPT_TEMPLATE and thread the previous
    // summary into the user prompt as a <previous-summary> block.
    //
    // Stub provider captures the StreamRequest's user prompt so the
    // assertion can verify the UPDATE-shape directly.
    const agent_module = @import("agent.zig");
    const PromptCaptureProvider = struct {
        captured_user_prompt: []u8 = &.{},
        allocator: Allocator,

        const vtable: @import("llm.zig").Provider.VTable = .{
            .call = callImpl,
            .call_streaming = callStreamingImpl,
            .name = "prompt_capture",
        };

        fn callImpl(_: *anyopaque, _: *const @import("llm.zig").Request) @import("llm.zig").ProviderError!types.LlmResponse {
            unreachable;
        }

        fn callStreamingImpl(
            ptr: *anyopaque,
            req: *const @import("llm.zig").StreamRequest,
        ) @import("llm.zig").ProviderError!types.LlmResponse {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            if (req.messages.len >= 1) {
                const block = req.messages[0].content[0];
                switch (block) {
                    .text => |t| {
                        self.captured_user_prompt = self.allocator.dupe(u8, t.text) catch &.{};
                    },
                    else => {},
                }
            }
            // Emit one text_delta so the streaming callback path runs;
            // return content empty so the caller falls back to the
            // streamed accumulator.
            req.callback.on_event(req.callback.ctx, .{ .text_delta = "updated summary" });
            return .{
                .content = &.{},
                .stop_reason = .end_turn,
                .input_tokens = 1,
                .output_tokens = 1,
            };
        }

        fn provider(self: *@This()) @import("llm.zig").Provider {
            return .{ .ptr = self, .vtable = &vtable };
        }
    };

    const alloc = std.testing.allocator;
    var capture: PromptCaptureProvider = .{ .allocator = alloc };
    defer alloc.free(capture.captured_user_prompt);
    const provider = capture.provider();

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();
    var cancel = agent_events.CancelFlag.init(false);

    // Build a prior-summary message at the head, plus a few trailing
    // messages so findCutPoint has something to summarize.
    const prefix = "The conversation history before this point was compacted into the following summary:\n\n<summary>\n";
    const suffix = "\n</summary>";
    const inner = "PRIOR FACTS GO HERE";
    const wrapped = try std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ prefix, inner, suffix });
    defer alloc.free(wrapped);

    var b0 = [_]types.ContentBlock{.{ .text = .{ .text = wrapped } }};
    var b1 = [_]types.ContentBlock{.{ .text = .{ .text = "new ask" } }};
    var b2 = [_]types.ContentBlock{.{ .text = .{ .text = "new answer" } }};
    var b3 = [_]types.ContentBlock{.{ .text = .{ .text = "current turn" } }};
    const messages = [_]types.Message{
        .{ .role = .user, .content = &b0 },
        .{ .role = .user, .content = &b1 },
        .{ .role = .assistant, .content = &b2 },
        .{ .role = .user, .content = &b3 },
    };

    const maybe_replacement = try agent_module.runDefaultSummarization(
        &messages,
        provider,
        1, // tiny budget so the cut sits past msg[1]
        alloc,
        &queue,
        &cancel,
    );
    try std.testing.expect(maybe_replacement != null);
    const replacement = maybe_replacement.?;
    defer {
        for (replacement) |m| m.deinit(alloc);
        alloc.free(replacement);
    }

    // The provider's user prompt must include the previous-summary
    // wrapper AND the inner prior facts text.
    try std.testing.expect(std.mem.indexOf(u8, capture.captured_user_prompt, "<previous-summary>") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.captured_user_prompt, "PRIOR FACTS GO HERE") != null);

    // Drain queue so the test allocator doesn't see leaked delta bytes.
    var buf: [16]agent_events.AgentEvent = undefined;
    while (true) {
        const n = queue.drain(&buf);
        if (n == 0) break;
        for (buf[0..n]) |ev| ev.freeOwned();
    }
}

test "zag.llm.complete with stream=true emits compaction_summary_delta to attached queue" {
    // Lua-side streaming opt-in. The default Lua strategy passes
    // stream=true; the worker's callStreaming path pushes one delta
    // per emitted text_delta onto the engine's current_event_queue.
    // The strategy still receives the full assembled text at the end.
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.initAsync(2, 16);
    defer engine.deinitAsync();

    var stub = StubCompactProvider{ .response_text = "STREAM ME" };
    const provider = stub.provider();
    engine.current_provider = &provider;
    defer engine.current_provider = null;

    var queue = try agent_events.EventQueue.initBounded(alloc, 16);
    defer queue.deinit();
    engine.current_event_queue = &queue;
    defer engine.current_event_queue = null;

    // Register a strategy that opts into streaming and returns the
    // received text wrapped as a replacement. Mirrors what the real
    // default Lua strategy does.
    try engine.lua.doString(
        \\zag.compact.strategy(function(ctx)
        \\  local resp = zag.llm.complete({
        \\    system = "x",
        \\    messages = {{ role = "user", content = "history" }},
        \\    stream = true,
        \\  })
        \\  return {
        \\    messages = { { role = "user", content = {{ type = "text", text = resp.text }} } },
        \\  }
        \\end)
    );

    var b1 = [_]types.ContentBlock{.{ .text = .{ .text = "history" } }};
    const messages = [_]types.Message{.{ .role = .user, .content = &b1 }};
    var req = agent_events.CompactRequest.init(&messages, 850, 1000, alloc);
    defer req.freeOutcome();

    try engine.handleCompactRequest(&req);

    // Strategy got the assembled text.
    switch (req.outcome) {
        .replace => |r| try std.testing.expectEqualStrings(
            "STREAM ME",
            r.messages[0].content[0].text.text,
        ),
        else => return error.TestUnexpectedOutcome,
    }

    // The queue saw at least one compaction_summary_delta event with
    // the streamed text. Drain and verify.
    var buf: [16]agent_events.AgentEvent = undefined;
    var found_delta = false;
    while (true) {
        const n = queue.drain(&buf);
        if (n == 0) break;
        for (buf[0..n]) |ev| {
            switch (ev) {
                .compaction_summary_delta => |t| {
                    if (std.mem.indexOf(u8, t.bytes, "STREAM ME") != null) found_delta = true;
                    t.free();
                },
                else => ev.freeOwned(),
            }
        }
    }
    try std.testing.expect(found_delta);
}

test "CompactRequest freeOutcome is idempotent" {
    // Calling freeOutcome twice on a .replace outcome must not
    // double-free. After the first call the outcome is reset to
    // .use_default; the second call sees that sentinel and returns
    // without touching memory.
    const alloc = std.testing.allocator;
    var b1 = [_]types.ContentBlock{.{ .text = .{ .text = "x" } }};
    const messages = [_]types.Message{.{ .role = .user, .content = &b1 }};
    var req = agent_events.CompactRequest.init(&messages, 100, 1000, alloc);

    // Allocate a real .replace payload owned by the request's allocator.
    const replacement = try alloc.alloc(types.Message, 1);
    const text = try alloc.dupe(u8, "summary");
    const blocks = try alloc.alloc(types.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = text } };
    replacement[0] = .{ .role = .user, .content = blocks };
    const summary_owned = try alloc.dupe(u8, "audit");
    req.outcome = .{ .replace = .{ .messages = replacement, .summary = summary_owned } };

    req.freeOutcome();
    try std.testing.expect(req.outcome == .use_default);
    req.freeOutcome(); // must not crash or double-free
    try std.testing.expect(req.outcome == .use_default);
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
        .factory = llm.anthropic.create,
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
