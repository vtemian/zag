# Harness Engineering

## Problem

Zag's current "context setup" is one static prefix, a tool list interpolated from the registry, and one static suffix. That is the entire harness. The model gets no cwd, no worktree, no git state, no date, no model self-identification, no `AGENTS.md`, no per-model tuning, no turn-scoped reminders, no thinking/reasoning content handling, and no way for plugins to shape any of this.

Today this is tolerable because frontier models paper over a weak harness. Tomorrow, when zag's positioning is *"the one coding agent where a local small model on your M3/M4 feels almost as good as Claude"*, the harness becomes ~40% of the product. You cannot retrofit harness quality after shipping. The sockets have to be designed in from the start.

Two concrete failure modes today, both user-visible:

1. **Reasoning models are half-plumbed.** `providers/chatgpt.zig:163` hardcodes `effort:medium` and round-trips `reasoning.encrypted_content`. But `providers/chatgpt.zig:360` drops `response.reasoning_summary_text.delta` at debug-log. Anthropic extended thinking has zero support. Opus-thinking and Sonnet-thinking, the models users actually run today, render as silent pauses in zag.
2. **No project context.** No `AGENTS.md` / `CLAUDE.md` loading. Every session starts context-naïve; the user retypes conventions every turn.

## Positioning

> *Zag is the first coding agent that treats reasoning models correctly on the frontier today and small open-source models seriously tomorrow. Built on a Lua-extensible harness. Windowed TUI. Yours to fork.*

**Day-1 hero model:** Claude Sonnet-4-thinking (Opus-thinking comes for free; same wire).
**Day-∞ hero model:** Qwen3-Coder-30B-A3B (Q6_K via llama.cpp on M3 Max).

The Day-∞ model does not ship Day 1. It exists to calibrate the *primitives* so the frontier defaults leave room for small-model-aware overrides.

## Design

### Three-layer architecture

1. **Zig primitives.** Pipeline slots exposed to Lua: layer registry, reminder queue, JIT context resolver, tool-output transform, tool gate, loop detector, compaction strategy.
2. **Lua stdlib.** Opinionated defaults shipped in the binary via `@embedFile`, loaded through existing `require("zag.*")` resolution. Per-model prompt packs, env layer, `AGENTS.md` loader, default loop detector, default compaction.
3. **User config / community packs.** Same `require` path, overrideable file-by-file under `~/.config/zag/lua/zag/`.

This matches the existing provider pattern: `require("zag.providers.anthropic")` is stdlib; users drop their own to override. Generalize to prompts, layers, JIT, loop, compact.

### The cache-boundary discipline

Anthropic extended thinking and prompt caching both key off *system-message boundaries*. The assembled system is modeled as two strings, not one:

- **`stable`**: identity + model-family pack. Written once per session. Changing it invalidates every cached turn downstream. **Plugins cannot append to stable after first turn render.** Enforced at the Lua binding layer.
- **`volatile`**: env block, `AGENTS.md`, skills, per-turn overrides, reminders. Changes freely per turn.

On Anthropic, the provider emits two system blocks with `cache_control: {type: "ephemeral"}` on `stable`. On OpenAI, it concatenates `stable + "\n" + volatile` (their cache is prefix-based, order-stable).

Layers register a `cache_class` and a `priority`. Rendering groups by class, sorts by priority ascending, joins.

```
priority <1000  → stable
priority ≥1000  → volatile
```

### Reasoning content as a first-class type

New content-block variants in `types.zig`:

```zig
pub const ContentBlock = union(enum) {
    text: []const u8,
    thinking: Thinking,
    redacted_thinking: RedactedThinking,
    tool_use: ToolUse,
    tool_result: ToolResult,
    // existing variants...
};

pub const Thinking = struct {
    text: []const u8,
    /// Anthropic: opaque signature; must round-trip verbatim within a turn.
    /// OpenAI Responses: the `reasoning.encrypted_content` blob lands here.
    signature: ?[]const u8,
    provider: enum { anthropic, openai_responses, openai_chat, none },
};

pub const RedactedThinking = struct {
    /// Anthropic: opaque bytes. Preserve verbatim within turn, drop across turns.
    data: []const u8,
};
```

Two load-bearing rules:

- **Within a turn**, thinking blocks (including redacted) must round-trip unchanged between the model's assistant response and its follow-up call after tool execution. Anthropic rejects the turn otherwise.
- **Across turns**, thinking from prior assistant messages must be stripped before the next LLM call. `Harness.stripThinkingAcrossTurns` walks history and drops thinking blocks from messages older than the current turn.

Session log preservation is separate from send-time stripping. The JSONL log keeps thinking parts forever (for replay and UI); the send path strips them. Do not conflate these.

### Pipeline shape

```
USER PRESSES ENTER
   │
   ▼
┌─ PromptPipeline ────────────────────────────┐
│  · expand slash commands                    │
│  · resolve @file attachments                │
│  · experimental.chat.prompt.transform hook  │
└─────────────────────────────────────────────┘
   │
   ▼
┌─ SystemPromptAssembly ──────────────────────┐
│  · pick model-family pack (cache=stable)    │
│  · run layer chain, grouped by cache class  │
│  · output: AssembledPrompt{stable,volatile} │
└─────────────────────────────────────────────┘
   │
   ▼
┌─ TurnContext ───────────────────────────────┐
│  · drain reminder queue → <system-reminder> │
│  · wrap mid-loop user messages              │
│  · tool gate → visible tool subset          │
│  · strip thinking from prior-turn history   │
└─────────────────────────────────────────────┘
   │
   ▼
┌─ Compaction (if used > threshold) ──────────┐
│  · compaction strategy (Lua-overridable)    │
└─────────────────────────────────────────────┘
   │
   ▼
┌─ Provider call ─────────────────────────────┐
│  · 2 system messages for Anthropic          │
│    (cache_control on stable)                │
│  · concat for OpenAI                        │
│  · stream: text / thinking / tool-use       │
└─────────────────────────────────────────────┘
   │
   ▼ (per tool call)
┌─ Tool Execution ────────────────────────────┐
│  · ToolPre hook                             │
│  · run tool                                 │
│  · ToolPost hook                            │
│  · on_tool_result chain → JIT context       │
│  · transform_output chain → rewrite         │
└─────────────────────────────────────────────┘
   │
   ▼
┌─ LoopDetector.turnEnd ──────────────────────┐
│  · reminder | remove_tool | hard_stop | nil │
└─────────────────────────────────────────────┘
   │
   ▼
 back to SystemPromptAssembly, or done
```

### Zig surface

New `src/prompt.zig` (multi-export utility per the file-naming rule):

```zig
pub const CacheClass = enum { stable, volatile };
pub const Source = enum { builtin, lua };

pub const Layer = struct {
    name: []const u8,
    priority: i32,
    cache_class: CacheClass,
    render_fn: *const fn (ctx: *const LayerContext, alloc: Allocator) anyerror!?[]const u8,
    source: Source,
    lua_ref: ?i32 = null,
};

pub const LayerContext = struct {
    model: llm.Model,
    cwd: []const u8,
    worktree: []const u8,
    agent: []const u8,
    date_iso: []const u8,
    is_git_repo: bool,
    platform: []const u8,
};

pub const AssembledPrompt = struct {
    stable: []const u8,
    @"volatile": []const u8,
    allocator: Allocator,

    pub fn deinit(self: *AssembledPrompt) void { ... }
};

pub const Registry = struct {
    layers: std.ArrayList(Layer),
    stable_frozen: bool = false,

    pub fn init() Registry { return .{ .layers = .empty }; }
    pub fn deinit(self: *Registry, alloc: Allocator) void { ... }
    pub fn add(self: *Registry, alloc: Allocator, layer: Layer) !void { ... }
    pub fn render(self: *Registry, ctx: *const LayerContext, alloc: Allocator) !AssembledPrompt { ... }
};
```

`render` sets `stable_frozen = true` after first call. Subsequent `add` with `cache_class = .stable` returns `error.StableFrozen`. The Lua binding surfaces this as a Lua error with a clear message.

New `src/Harness.zig` (PascalCase, single struct-typed owner):

```zig
pub const Harness = struct {
    allocator: Allocator,
    prompt_registry: prompt.Registry,
    reminder_queue: Reminder.Queue,
    resolvers: std.ArrayList(ContextResolver),
    output_transforms: std.ArrayList(ToolOutputTransform),
    tool_gates: std.ArrayList(ToolGate),
    loop_detectors: std.ArrayList(LoopDetector),
    compaction: ?CompactionStrategy,
    hooks: *Hooks,
    lua: *LuaEngine,

    pub fn init(alloc: Allocator, hooks: *Hooks, lua: *LuaEngine) !Harness { ... }
    pub fn deinit(self: *Harness) void { ... }

    pub fn assembleSystem(self: *Harness, ctx: *const prompt.LayerContext) !prompt.AssembledPrompt { ... }
    pub fn injectReminders(self: *Harness, msgs: *std.ArrayList(types.Message)) !void { ... }
    pub fn visibleTools(self: *Harness, agent: []const u8, alloc: Allocator) ![]const []const u8 { ... }
    pub fn onToolResult(self: *Harness, tool: []const u8, result: types.ToolResult, alloc: Allocator) !?[]const u8 { ... }
    pub fn transformToolOutput(self: *Harness, tool: []const u8, result: *types.ToolResult) !void { ... }
    pub fn detectLoop(self: *Harness, ctx: *const LoopContext) !?Intervention { ... }
    pub fn compact(self: *Harness, msgs: *std.ArrayList(types.Message), ctx: *const CompactContext) !void { ... }
    pub fn stripThinkingAcrossTurns(self: *Harness, msgs: []types.Message) void { ... }
};

pub const Intervention = union(enum) {
    reminder: []const u8,
    remove_tool: []const u8,
    hard_stop: []const u8,
};
```

The agent loop in `src/agent.zig` changes from `buildSystemPrompt(registry)` returning one string to calling `harness.assembleSystem(&ctx)` and threading both strings plus the visible tool subset through `Provider.streamTurn`.

### Lua surface

```lua
zag.prompt.layer(name, { priority = 100, cache = "volatile" }, function(ctx)
  return "..."  -- or nil to skip
end)

zag.prompt.for_model(pattern, prompt_text_or_fn)
  -- pattern: substring or Lua pattern; matched against model.id
  -- registers a cache="stable", priority=0 layer

zag.reminders.push(text, { scope = "next_turn", id = "plan-active", once = true })
zag.reminders.clear("plan-active")

zag.context.on_tool_result("read", function(result)
  -- result = { tool, input, output, metadata }
  return "..."  -- appended under the tool result, or nil
end)

zag.tools.transform_output("bash", function(result)
  return rewritten  -- or nil for passthrough
end)

zag.tools.gate(function(ctx)
  return { "read", "edit", "bash" }  -- visible tool names this turn
end)

zag.loop.detect(function(ctx)
  if ctx.identical_streak >= 3 then
    return { action = "reminder", text = "You called the same tool 3x; try a different approach." }
  end
end)

zag.compact.strategy(function(ctx, messages)
  -- mutate `messages` in place
end)

zag.context.find_up(pattern, { from = cwd, to = worktree })
zag.context.ancestors(cwd, root)
```

### Return conventions

| API | Return | Meaning |
|---|---|---|
| `zag.prompt.layer` fn | `string` | Append to the layer's cache class |
| `zag.prompt.layer` fn | `nil` | Skip this layer this turn |
| `zag.context.on_tool_result` fn | `string` | Append as JIT context under the tool result |
| `zag.tools.transform_output` fn | `string` | Replace the tool output |
| `zag.tools.transform_output` fn | `nil` | Passthrough |
| `zag.tools.gate` fn | `string[]` | Visible tool name set for this turn |
| `zag.loop.detect` fn | `{ action, text? }` or `nil` | Intervention or none |

### Stdlib layout

```
src/lua/zag/
  prompt/
    init.lua              -- picks pack from model id
    anthropic.lua         -- Sonnet/Opus, reasoning-aware
    openai-codex.lua      -- GPT-5-Codex, ASCII, apply_patch
    openai-gpt.lua        -- GPT-5/4o general
    default.lua           -- fallback
  layers/
    init.lua              -- registers all default layers
    identity.lua          -- priority 5,    cache=stable
    env.lua               -- priority 10,   cache=volatile (date changes)
    agents_md.lua         -- priority 900,  cache=volatile
    skills.lua            -- priority 950,  cache=volatile (when skills ship)
  jit/
    agents_md.lua         -- on_tool_result("read") walk-up
  loop/
    default.lua           -- lenient: flag at 5 identical calls
  compact/
    default.lua           -- compact at 80%, summarize old tool results
  init.lua                -- requires everything above
```

Users override any module by dropping the same path under `~/.config/zag/lua/`. Community packs ship as `require("zag-pack-qwen3-coder")` once the external loader is exposed.

### AGENTS.md policy

**First-hit wins, not stacked.** Walk from `cwd` up to `worktree` looking for `AGENTS.md`, then `CLAUDE.md`, then deprecated `CONTEXT.md`. Stop at the first match. Attach `~/.claude/CLAUDE.md` and `~/.config/zag/AGENTS.md` as globals, separately.

Reasoning: stacking works for frontier models, hurts small models, and inflates the cache-invalidating volatile section on all models. If a user wants stacking, they can `require()` the parent from the child.

**JIT walk on read.** When the `read` tool returns, walk up from the read path looking for `AGENTS.md`. Attach the content under the tool result with `Instructions from: <path>\n<content>`. Dedup per message ID; the same file is only attached once per turn, not once per read of that file.

## Out of scope for v1

- Tool-call shimming for non-native-tool-calling models (Goose-style "emit text, parse back"). Qwen3-Coder has native tool calling; defer until a target needs it.
- Remote URL instructions. Add when someone asks.
- Per-pane model overrides with different harness instances. Single harness per session for v1.
- Plan mode. The reminder queue is the primitive plan mode will be built on, but plan mode itself is its own design doc.
- Skills. The skills layer is a placeholder; skills are a separate design.

## Risks and gotchas

- **Stable-frozen enforcement is the critical invariant.** Every time `stable` mutates mid-session, every downstream turn cache-misses. Users will try to write plugins that append to stable "just once more." Return a Lua error loudly with guidance to use `volatile` instead.
- **Thinking round-trip vs. cross-turn strip is easy to confuse.** Within-turn: preserve verbatim, including signatures and redacted blocks. Cross-turn: drop. Session log: keep forever. Three different operations on the same data.
- **OpenAI Responses `reasoning.encrypted_content` is provider-specific.** The `signature` field on `Thinking` is a union semantically: Anthropic signature vs. OpenAI encrypted blob. Keep them distinct in wire serialization; the struct layout is just a convenience.
- **Reasoning effort as a first-class knob.** Hardcoded `effort:medium` in `providers/chatgpt.zig:163` ships as a regression risk; it needs to come from the model/agent config, surfaced through `zag.provider{...}` with sensible defaults.
- **Parallel tool calls fight reasoning models.** Opus-thinking degrades materially with parallel fan-out. Tool gate should support disabling parallelism as part of its context. Not a v1 API concern but worth noting in the gate design.
- **Layer ordering is load-bearing.** Priority numbers in the stdlib must be stable across versions. Reserve bands: `0-99` identity/pack, `100-899` context, `900-999` pre-volatile, `1000+` volatile. Document.

## Sequencing

Each PR ships user-visible value and unblocks the next.

**PR 1: thinking content plumbing** (P0; unblocks reasoning-first launch).
Thinking + RedactedThinking in `types.zig`. Anthropic extended thinking serialize + deserialize with signature preservation. Codex: stop dropping reasoning deltas; emit as `thinking_delta` events. ConversationBuffer renders thinking as a collapsed block with Ctrl-R toggle. `stripThinkingAcrossTurns` runs before every LLM send. Tests: round-trip thinking through a turn with tool calls; verify prior-turn stripping does not leak into send payload.

**PR 2: prompt layer registry (Zig-only default).**
`src/prompt.zig` with Registry, AssembledPrompt, stable-frozen enforcement. Builtin env layer as a placeholder. `agent.zig` calls `harness.assembleSystem` instead of `buildSystemPrompt`. Backward compat: tool snippets stay hardcoded for one PR.

**PR 3: Lua prompt layer API.**
Bind `zag.prompt.layer` via LuaEngine. Rewrite the env layer as `lua/zag/layers/env.lua` to dogfood.

**PR 4: per-model prompt packs.**
`zag.prompt.for_model` + `prompt/init.lua` dispatch. Ship three packs: `anthropic.lua`, `openai-codex.lua`, `default.lua`. Packs are lifted and tuned from opencode's `anthropic.txt` / `codex.txt` with attribution.

**PR 5: Anthropic two-part cache.**
Provider sends `system_stable` with `cache_control: ephemeral`, `system_volatile` without. Test: `usage.cache_read_input_tokens` across repeated turns confirms cache hit.

**PR 6: AGENTS.md first-hit loader.**
`src/Instruction.zig` (PascalCase) with `systemPaths()` + walk-up. Registered as a default Lua layer. Globals at `~/.claude/CLAUDE.md`, `~/.config/zag/AGENTS.md`.

**PR 7: reminder queue.**
`src/Reminder.zig`, `zag.reminders.push` Lua API, `<system-reminder>` wrapping, injection at user-message boundary. First concrete use: mid-loop user-message wrap.

**PR 8: JIT context on tool results.**
`zag.context.on_tool_result` API. Default `lua/zag/jit/agents_md.lua`: walk up from read paths, dedup per-message.

**PR 9: tool output transform + tool gate sockets.**
APIs land as no-ops on frontier. Example Lua: trim `rg` output past 200 lines.

**PR 10: loop detector + compaction sockets.**
Lenient default detector (5 identical streak). Token-threshold default compaction (summarize tool results older than N turns when >80% window).

**PR 11: first small-model pack (Qwen3-Coder).**
`lua/zag/prompt/qwen3-coder.lua`. Override loop detector threshold to 2. Gate to `read/edit/bash/grep/glob`. Aggressive tool-output transforms on `bash` and `grep`. Benchmark harness: Terminal-Bench or harbor runs on local Qwen vs. Cline + LM Studio baseline. The "almost as good as Claude" claim gets tested here.

## Open questions

1. **Reasoning effort surface.** Per-agent config? Per-turn override via `/reasoning high`? Both? Probably: provider-default in `zag.provider{...}`, agent-level override, per-turn escape hatch. Defer concrete API to PR 1.
2. **Session log schema for thinking.** Do we log the full thinking text verbatim, or only a hash + signature? Full text is simpler and the log is local-only. Go simple; add redaction later if anyone asks.
3. **Layer priority registration as data vs. code.** Are priorities declared in a central Zig constants file, or in each layer? Central makes collisions visible; decentralized is more Neovim-like. Lean central for v1.
4. **Cross-turn thinking strip granularity.** Strip *all* prior-turn thinking, or only thinking from messages older than the current user turn? The latter preserves the ability for a single user turn to span multiple assistant responses with thinking in each. Anthropic's docs suggest the latter is valid; start strict (strip all), loosen if tests force it.
5. **When does PR 11 actually land?** Depends on Qwen3-Coder-Next availability and M3 Max tooling maturity. Do not gate PRs 1–10 on this.

## Inspiration

- Opencode's layered system assembly, two-part cache discipline, JIT `Instruction.resolve`, per-model prompt files, and `<system-reminder>` pattern.
- Pi-mono's conditional-guidelines-by-tool-set and slash-command template loader.
- Neovim's `vim.*` stdlib-on-top-of-primitives shape.
- Aider's per-model settings files: a reminder that per-model tuning earns its keep.
