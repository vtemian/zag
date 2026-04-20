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
const Allocator = std.mem.Allocator;
const Lua = zlua.Lua;
const log = std.log.scoped(.lua);

/// Whether the Lua sandbox strips dangerous globals before user code runs.
/// A shared plugin marketplace should never be one `os.execute("rm -rf ~")`
/// away from disaster. Override with `-Dlua_sandbox=false` for local debugging.
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
    /// Hook registry, populated by `zag.hook()` calls from Lua.
    hook_registry: Hooks.Registry,
    /// Set by `applyHookReturn` when a hook returns `{ cancel = true }`.
    /// Consumed and reset by `takeCancel()` after fireHook returns.
    pending_cancel: bool = false,
    /// Optional reason string allocated via `self.allocator`. Owned by
    /// the caller of `takeCancel()` once handed off.
    pending_cancel_reason: ?[]const u8 = null,
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

        var keymap_registry = Keymap.Registry.init(allocator);
        errdefer keymap_registry.deinit();
        try keymap_registry.loadDefaults();

        return LuaEngine{
            .lua = lua,
            .allocator = allocator,
            .tools = .empty,
            .hook_registry = Hooks.Registry.init(allocator),
            .enabled_providers = .empty,
            .keymap_registry = keymap_registry,
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
        for (self.hook_registry.hooks.items) |h| {
            self.lua.unref(zlua.registry_index, h.lua_ref);
        }
        self.hook_registry.deinit();
        for (self.enabled_providers.items) |name| self.allocator.free(name);
        self.enabled_providers.deinit(self.allocator);
        if (self.default_model) |m| self.allocator.free(m);
        if (self.pending_cancel_reason) |r| self.allocator.free(r);
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
        lua.setGlobal("zag");
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
        const schema_json = luaTableToJson(lua, -1, engine.allocator) catch |err| {
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

        const id = try engine.hook_registry.register(kind, pattern, cb_ref);
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
        for (engine.hook_registry.hooks.items) |h| {
            if (h.id == id) {
                engine.lua.unref(zlua.registry_index, h.lua_ref);
                break;
            }
        }
        _ = engine.hook_registry.unregister(id);
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

    // -- Hook dispatch ---------------------------------------------------------

    /// Fire all hooks matching the payload's event kind.
    /// Called from the main thread (the only thread permitted to touch Lua).
    /// Mutates `payload` in place if a hook returns a rewrite.
    /// A hook that raises is logged and skipped; subsequent hooks still run.
    pub fn fireHook(self: *LuaEngine, payload: *Hooks.HookPayload) !void {
        // Fast path: no hooks registered at all. Avoids any Lua VM
        // interaction on the streaming hot path (e.g. TextDelta firing
        // once per token).
        if (self.hook_registry.hooks.items.len == 0) return;

        const pattern_key = hookPatternKey(payload.*);

        var it = self.hook_registry.iterMatching(payload.kind(), pattern_key);
        while (it.next()) |hook| {
            // Stack: [fn]
            _ = self.lua.rawGetIndex(zlua.registry_index, hook.lua_ref);
            // Stack: [fn, payload_table]
            self.pushPayloadAsTable(payload.*) catch |err| {
                log.warn("hook payload marshalling failed for {s}: {}", .{ @tagName(payload.kind()), err });
                self.lua.pop(1); // pop fn
                continue;
            };
            // Call: 1 arg (payload table), up to 1 return (rewrite table or nil).
            self.lua.protectedCall(.{ .args = 1, .results = 1 }) catch |err| {
                const msg = self.lua.toString(-1) catch "<unprintable>";
                log.warn("hook for {s} raised: {} ({s})", .{ @tagName(payload.kind()), err, msg });
                self.lua.pop(1); // pop error message
                continue;
            };
            // Stack: [return_value]. If it's a table, apply rewrite.
            if (self.lua.isTable(-1)) {
                self.applyHookReturn(payload) catch |err| {
                    log.warn("hook return for {s} failed to apply: {}", .{ @tagName(payload.kind()), err });
                };
            }
            self.lua.pop(1); // pop return value
        }
    }

    /// Key used for pattern matching against a hook's pattern.
    /// ToolPre/ToolPost use the tool name; all other events use "".
    fn hookPatternKey(payload: Hooks.HookPayload) []const u8 {
        return switch (payload) {
            .tool_pre => |p| p.name,
            .tool_post => |p| p.name,
            else => "",
        };
    }

    /// Push the payload as a Lua table onto the stack.
    /// The table is a fresh Lua table; strings are copied into the VM.
    fn pushPayloadAsTable(self: *LuaEngine, payload: Hooks.HookPayload) !void {
        self.lua.newTable();
        switch (payload) {
            .tool_pre => |p| {
                self.setTableString("name", p.name);
                self.setTableString("call_id", p.call_id);
                // args: decode JSON into a Lua table when possible; fall
                // back to empty table so hooks can always index evt.args.
                try self.setTableJsonField("args", p.args_json);
            },
            .tool_post => |p| {
                self.setTableString("name", p.name);
                self.setTableString("call_id", p.call_id);
                self.setTableString("content", p.content);
                self.setTableBool("is_error", p.is_error);
                self.setTableInt("duration_ms", @intCast(p.duration_ms));
            },
            .turn_start => |p| {
                self.setTableInt("turn_num", @intCast(p.turn_num));
                self.setTableInt("message_count", @intCast(p.message_count));
            },
            .turn_end => |p| {
                self.setTableInt("turn_num", @intCast(p.turn_num));
                self.setTableString("stop_reason", p.stop_reason);
                self.setTableInt("input_tokens", @intCast(p.input_tokens));
                self.setTableInt("output_tokens", @intCast(p.output_tokens));
            },
            .user_message_pre => |p| self.setTableString("text", p.text),
            .user_message_post => |p| self.setTableString("text", p.text),
            .text_delta => |p| self.setTableString("text", p.text),
            .agent_done => {},
            .agent_err => |p| self.setTableString("message", p.message),
        }
    }

    /// Push `value` as a Lua string and assign it to `key` on the table
    /// currently at the top of the stack. Stack delta: 0.
    fn setTableString(self: *LuaEngine, comptime key: [:0]const u8, value: []const u8) void {
        _ = self.lua.pushString(value);
        self.lua.setField(-2, key);
    }

    fn setTableBool(self: *LuaEngine, comptime key: [:0]const u8, value: bool) void {
        self.lua.pushBoolean(value);
        self.lua.setField(-2, key);
    }

    fn setTableInt(self: *LuaEngine, comptime key: [:0]const u8, value: i64) void {
        self.lua.pushInteger(value);
        self.lua.setField(-2, key);
    }

    /// Decode `json_text` as JSON and assign the resulting Lua value to
    /// `key` on the table at the top of the stack. If the JSON does not
    /// parse, assign an empty table so hooks never see a nil args field.
    fn setTableJsonField(self: *LuaEngine, comptime key: [:0]const u8, json_text: []const u8) !void {
        const parsed = std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            json_text,
            .{},
        ) catch {
            self.lua.newTable();
            self.lua.setField(-2, key);
            return;
        };
        defer parsed.deinit();
        pushJsonValue(self.lua, parsed.value);
        self.lua.setField(-2, key);
    }

    /// Read the return table (top of stack) from a hook callback and
    /// apply its fields to the payload. The table is NOT popped here;
    /// the caller pops it after this returns.
    ///
    /// Stack discipline: on entry and exit, the return table sits at
    /// the top of the stack. Every `getField` is paired with `pop(1)`.
    fn applyHookReturn(self: *LuaEngine, payload: *Hooks.HookPayload) !void {
        // Stack: [..., ret_table]
        // Check `cancel` first. If set and the payload kind supports veto,
        // short-circuit rewrite handling. For observer-only events we
        // ignore cancel so a stray `{cancel=true}` from a lifecycle or
        // post-hook can't leak into the next veto-capable event.
        _ = self.lua.getField(-1, "cancel");
        const cancel = self.lua.isBoolean(-1) and self.lua.toBoolean(-1);
        self.lua.pop(1);

        if (cancel) {
            const veto_allowed = switch (payload.*) {
                .tool_pre, .user_message_pre => true,
                else => false,
            };
            if (!veto_allowed) {
                log.warn("hook returned cancel=true for observer-only event {s}; ignored", .{@tagName(payload.kind())});
                return;
            }
            self.pending_cancel = true;
            _ = self.lua.getField(-1, "reason");
            if (self.lua.isString(-1)) {
                // Borrowed from Lua VM; must be duped before the pop below.
                if (self.lua.toString(-1)) |reason_text| {
                    // Free any previously stored reason before overwriting.
                    if (self.pending_cancel_reason) |old| self.allocator.free(old);
                    self.pending_cancel_reason = self.allocator.dupe(u8, reason_text) catch null;
                } else |_| {}
            }
            self.lua.pop(1);
            return;
        }

        switch (payload.*) {
            .tool_pre => |*p| {
                _ = self.lua.getField(-1, "args");
                if (self.lua.isTable(-1)) {
                    // luaTableToJson is a static helper on LuaEngine.
                    const rewrite = try luaTableToJson(self.lua, -1, self.allocator);
                    if (p.args_rewrite) |old| self.allocator.free(old);
                    p.args_rewrite = rewrite;
                }
                self.lua.pop(1);
            },
            .user_message_pre => |*p| {
                _ = self.lua.getField(-1, "text");
                if (self.lua.isString(-1)) {
                    if (self.lua.toString(-1)) |t| {
                        const rewrite = try self.allocator.dupe(u8, t);
                        if (p.text_rewrite) |old| self.allocator.free(old);
                        p.text_rewrite = rewrite;
                    } else |_| {}
                }
                self.lua.pop(1);
            },
            .tool_post => |*p| {
                _ = self.lua.getField(-1, "content");
                if (self.lua.isString(-1)) {
                    if (self.lua.toString(-1)) |c| {
                        const rewrite = try self.allocator.dupe(u8, c);
                        if (p.content_rewrite) |old| self.allocator.free(old);
                        p.content_rewrite = rewrite;
                    } else |_| {}
                }
                self.lua.pop(1);
                _ = self.lua.getField(-1, "is_error");
                if (self.lua.isBoolean(-1)) {
                    p.is_error_rewrite = self.lua.toBoolean(-1);
                }
                self.lua.pop(1);
            },
            else => {},
        }
    }

    /// Read-and-reset the pending cancel state set by a veto hook. The
    /// returned slice (if non-null) is allocated via `self.allocator`
    /// and owned by the caller.
    pub fn takeCancel(self: *LuaEngine) ?[]const u8 {
        if (!self.pending_cancel) return null;
        self.pending_cancel = false;
        const reason = self.pending_cancel_reason;
        self.pending_cancel_reason = null;
        return reason;
    }

    // -- JSON serialization from Lua values ------------------------------------

    /// Serialize the Lua value at `index` (must be a table) to a JSON string.
    pub fn luaTableToJson(lua: *Lua, index: i32, allocator: Allocator) ![]const u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        errdefer buf.deinit(allocator);
        try luaValueToJson(lua, index, buf.writer(allocator));
        return buf.toOwnedSlice(allocator);
    }

    /// Write the Lua value at `index` as JSON to `writer`.
    fn luaValueToJson(lua: *Lua, index: i32, writer: anytype) !void {
        // Normalize negative indices to absolute
        const abs_index = if (index < 0) lua.getTop() + 1 + index else index;

        const lua_type = lua.typeOf(abs_index);
        switch (lua_type) {
            .nil => try writer.writeAll("null"),
            .boolean => {
                if (lua.toBoolean(abs_index)) {
                    try writer.writeAll("true");
                } else {
                    try writer.writeAll("false");
                }
            },
            .number => {
                // Try integer first
                const integer = lua.toInteger(abs_index) catch {
                    const number = lua.toNumber(abs_index) catch {
                        try writer.writeAll("null");
                        return;
                    };
                    try writer.print("{d}", .{number});
                    return;
                };
                try writer.print("{d}", .{integer});
            },
            .string => {
                const str = lua.toString(abs_index) catch {
                    try writer.writeAll("null");
                    return;
                };
                try types.writeJsonString(writer, str);
            },
            .table => {
                if (isLuaArray(lua, abs_index)) {
                    try writer.writeByte('[');
                    const length = lua.rawLen(abs_index);
                    for (0..length) |i| {
                        if (i > 0) try writer.writeByte(',');
                        _ = lua.rawGetIndex(abs_index, @as(i64, @intCast(i + 1)));
                        try luaValueToJson(lua, -1, writer);
                        lua.pop(1);
                    }
                    try writer.writeByte(']');
                } else {
                    try writer.writeByte('{');
                    var first = true;
                    lua.pushNil();
                    while (lua.next(abs_index)) {
                        if (!first) try writer.writeByte(',');
                        first = false;

                        // Key must be a string for JSON objects
                        // Copy the key to avoid disturbing lua.next()
                        lua.pushValue(-2);
                        const key = lua.toString(-1) catch {
                            lua.pop(2); // pop copy + value
                            continue;
                        };
                        try types.writeJsonString(writer, key);
                        lua.pop(1); // pop copy of key

                        try writer.writeByte(':');
                        try luaValueToJson(lua, -1, writer);
                        lua.pop(1); // pop value, leave key for next()
                    }
                    try writer.writeByte('}');
                }
            },
            else => try writer.writeAll("null"),
        }
    }

    /// Heuristic: a Lua table is an array if it has consecutive integer keys starting at 1.
    fn isLuaArray(lua: *Lua, index: i32) bool {
        const length = lua.rawLen(index);
        if (length == 0) {
            // Check if the table is truly empty (no keys at all) vs an object
            lua.pushNil();
            if (lua.next(index)) {
                lua.pop(2);
                return false; // has keys, so it's an object
            }
            // truly empty: treat as object {}
            return false;
        }
        // Has integer keys 1..length, consider it an array
        return true;
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
        pushJsonAsTable(self.lua, input_json, self.allocator) catch |err| {
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

        // Check return convention: string OR nil,err_string
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

    // -- JSON to Lua table conversion ------------------------------------------

    /// Parse a JSON string and push it onto the Lua stack as a table.
    fn pushJsonAsTable(lua: *Lua, raw_json: []const u8, allocator: Allocator) !void {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw_json, .{});
        defer parsed.deinit();
        pushJsonValue(lua, parsed.value);
    }

    /// Push a std.json.Value onto the Lua stack.
    fn pushJsonValue(lua: *Lua, value: std.json.Value) void {
        switch (value) {
            .null => lua.pushNil(),
            .bool => |b| lua.pushBoolean(b),
            .integer => |i| lua.pushInteger(@intCast(i)),
            .float => |f| lua.pushNumber(f),
            .string => |s| _ = lua.pushString(s),
            .array => |arr| {
                lua.createTable(@intCast(arr.items.len), 0);
                for (arr.items, 1..) |item, i| {
                    pushJsonValue(lua, item);
                    lua.rawSetIndex(-2, @intCast(i));
                }
            },
            .object => |obj| {
                lua.createTable(0, @intCast(obj.count()));
                var it = obj.iterator();
                while (it.next()) |entry| {
                    // Push key as a null-terminated string via pushString
                    _ = lua.pushString(entry.key_ptr.*);
                    pushJsonValue(lua, entry.value_ptr.*);
                    lua.setTable(-3);
                }
            },
            .number_string => |s| _ = lua.pushString(s),
        }
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

    /// Hook for agent threads to bind this engine as their active Lua context.
    /// Currently a no-op: Lua tool execution round-trips through the main thread
    /// via `tools.lua_request_queue`, so no per-thread engine pointer is
    /// needed. Kept as an extension point for future per-thread Lua states.
    pub fn activate(self: *LuaEngine) void {
        _ = self;
    }

    /// Symmetric counterpart to `activate()`. Currently a no-op; see `activate`.
    pub fn deactivate(self: *LuaEngine) void {
        _ = self;
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
    const json = try LuaEngine.luaTableToJson(engine.lua, -1, std.testing.allocator);
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

    try std.testing.expectEqual(@as(usize, 2), engine.hook_registry.hooks.items.len);
    try std.testing.expectEqualStrings(
        "bash",
        engine.hook_registry.hooks.items[0].pattern.?,
    );
    try std.testing.expect(engine.hook_registry.hooks.items[1].pattern == null);
}

test "zag.hook_del removes a hook" {
    var engine = try LuaEngine.init(std.testing.allocator);
    defer engine.deinit();
    engine.storeSelfPointer();
    try engine.lua.doString(
        \\_G.id = zag.hook("TurnEnd", function() end)
        \\zag.hook_del(_G.id)
    );
    try std.testing.expectEqual(@as(usize, 0), engine.hook_registry.hooks.items.len);
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
    try engine.fireHook(&payload);

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
                AgentRunner.dispatchHookRequests(q, eng);
                std.Thread.sleep(1 * std.time.ns_per_ms);
            }
            // Final drain so any late pushes by the test thread are serviced.
            AgentRunner.dispatchHookRequests(q, eng);
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
    try engine.fireHook(&payload);
    const reason = engine.takeCancel();
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
    try engine.fireHook(&payload);
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
    try engine.fireHook(&payload);
    const reason = engine.takeCancel();
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
    try engine.fireHook(&payload);
    try std.testing.expect(payload.user_message_pre.text_rewrite != null);
    defer std.testing.allocator.free(payload.user_message_pre.text_rewrite.?);
    try std.testing.expectEqualStrings("expanded: hi", payload.user_message_pre.text_rewrite.?);
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
