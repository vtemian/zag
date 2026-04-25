# Skills and subagents design

## Why

zag needs a story for extending the agent loop beyond the four
built-in tools. Two industry patterns dominate:

- **Skills** (Anthropic Agent Skills spec, ~30 adopters including
  Claude Code, Amp, pi-mono, OpenCode): a directory with `SKILL.md`
  advertising a capability via `name` + `description`, the body
  loaded on demand, bundled scripts invoked through the ordinary
  `bash` tool. Skills share the parent conversation's context,
  tools, permissions.
- **Subagents** (Claude Code, OpenCode): a separate runtime entity
  with its own system prompt, optional model, optional tool
  allowlist, spawned by the LLM via a `task` tool. Returns a
  summary.

The two are orthogonal, not competing. Skills package procedural
knowledge; subagents provide context isolation and model selection
per task. zag ships both, kept as separate mechanisms (per pi-mono's
split).

## Scope

1. **Skills loader.** Scan `~/.config/zag/skills/`, `.zag/skills/`,
   `.agents/skills/`. Parse `SKILL.md` YAML frontmatter (`name`,
   `description`, optional `allowed-tools`, `license`, `metadata`).
   Inject catalog (`name` + `description` only) into the system
   prompt as `<available_skills>` XML. LLM loads bodies on demand
   via the existing `read` tool.
2. **Subagent registry, Lua-native.** `zag.subagent.register{...}`
   is the primary authoring surface. Optional stdlib module
   `zag.subagents.filesystem` scans `.zag/agents/`, `.agents/agents/`,
   `~/.config/zag/agents/` for `*.md` files and registers each one,
   mirroring the provider stdlib pattern.
3. **`task` tool.** Single built-in, signature
   `task(agent: string, prompt: string) -> string`. `agent` is a
   JSON Schema `enum` built from the registry. Spawns a hidden child
   Runner with a `Collector` sink, fresh context, frontmatter-derived
   model and tool allowlist. Returns the child's final assistant
   message as the tool result.
4. **JSONL tree persistence.** Every event has a ULID `id` and a
   `parent_id` (null for root). The file is flat; the tree is
   reconstructed by walking parent pointers. Subagent events carry
   `task_*` types and hang under the parent's `tool_use` event.

## Non-scope

- **Visual tree navigation.** Tracked in
  [#1](https://github.com/vtemian/zag/issues/1). The tree-shaped
  JSONL is what makes future replay possible; the UI is deferred.
- **Smart skills filtering and dynamic insertion.** Tracked in
  [#2](https://github.com/vtemian/zag/issues/2). The initial loader
  injects every discovered skill's catalog entry.
- **Dynamic Lua config reloading.** Tracked in
  [#3](https://github.com/vtemian/zag/issues/3). Subagent registry
  and the `task` tool's enum are populated once at config load; live
  reload is a follow-up.
- **Multi-sink fan-out.** Collector is the only subagent sink in v1.
  When visual mode lands, a second sink (Buffer backing a split
  pane) will be added; that requires the deferred fan-out work.
- **Skill marketplace / dependency resolution.** Per spec, skills
  don't declare dependencies and don't call each other.
- **Per-tool permission rules** (Claude Code has these). zag relies
  on the tool allowlist only.

## Architecture

### Skills loader

New module `src/skills.zig` exposes:

```zig
pub const Skill = struct {
    name: []const u8,          // [a-z0-9-]+, matches parent dir
    description: []const u8,   // 1-1024 chars
    path: []const u8,          // absolute path to SKILL.md
    allowed_tools: ?[]const u8 = null,
    license: ?[]const u8 = null,
};

pub const SkillRegistry = struct {
    pub fn discover(allocator, config_home, project_root) !SkillRegistry;
    pub fn catalog(self: *const SkillRegistry, writer) !void;
    pub fn deinit(self: *SkillRegistry) void;
};
```

Discovery walks three roots in precedence order (project beats user):
`<project>/.zag/skills/`, `<project>/.agents/skills/`,
`~/.config/zag/skills/`. For each root, list immediate subdirs; if a
subdir contains `SKILL.md`, parse and register. Name collisions:
project wins, log a `warn` on shadowing.

Catalog output (injected into system prompt):

```
<available_skills>
  <skill name="roll-dice" path="/abs/.../SKILL.md">Roll dice using a random number generator.</skill>
  <skill name="pdf-processing" path="/abs/.../SKILL.md">Extract PDF text, fill forms, merge files.</skill>
</available_skills>
```

~60-100 tokens per skill. Bodies are NOT loaded upfront; the LLM reads
them via the existing `read` tool when a task matches. Scripts inside
skills run through the existing `bash` tool.

### Subagent registry (Lua-native)

Primary API:

```lua
zag.subagent.register{
  name = "reviewer",
  description = "Review staged diffs for quality issues. Use after implementing a change.",
  model = "anthropic/claude-haiku-4-5",   -- optional; nil = inherit parent's default
  tools = {"read", "grep"},               -- optional; nil = inherit ALL parent's tools
  prompt = [[
You are a code reviewer. When invoked, read the staged diff,
analyse each hunk for...
  ]],
}
```

Zig-side storage in `src/subagents.zig`:

```zig
pub const Subagent = struct {
    name: []const u8,          // [a-z0-9-]+, 1-64
    description: []const u8,   // 1-1024; becomes task-tool enum help
    prompt: []const u8,        // subagent's system prompt
    model: ?[]const u8 = null,
    tools: ?[]const []const u8 = null,
};

pub const SubagentRegistry = struct {
    pub fn register(self: *SubagentRegistry, sa: Subagent) !void;
    pub fn lookup(self: *const SubagentRegistry, name: []const u8) ?*const Subagent;
    pub fn taskToolSchema(self: *const SubagentRegistry, writer) !void;
};
```

Registry is populated during `LuaEngine.loadConfig`, before the first
agent turn. `taskToolSchema` emits the enum + per-entry description at
schema-build time.

**Filesystem loader as optional stdlib.** Users who prefer
Claude-Code-style `.md` files opt in via
`require("zag.subagents.filesystem")`. The stdlib module walks the
three agent directories, parses YAML frontmatter + markdown body, and
calls `zag.subagent.register` for each entry.

### The `task` tool

Schema emitted to the LLM:

```json
{
  "name": "task",
  "description": "Delegate work to a subagent. Returns the subagent's final summary.",
  "parameters": {
    "type": "object",
    "properties": {
      "agent":  { "type": "string", "enum": ["reviewer","planner","scout"] },
      "prompt": { "type": "string" }
    },
    "required": ["agent", "prompt"]
  }
}
```

The `enum` is built from `SubagentRegistry` at schema-emit time. Each
entry gets a per-enum-value description from the subagent's
`description` field. The enum is rebuilt when Lua config reloads
([#3](https://github.com/vtemian/zag/issues/3)).

### Runtime lifecycle

When the parent's LLM emits `task(agent, prompt)`, `src/tools/task.zig`
executes synchronously on the parent's runner thread:

1. **Resolve.** `SubagentRegistry.lookup(agent)`. Return
   `error.UnknownSubagent` on miss, with the list of registered names
   in the error message.
2. **Depth check.** Parent's Runner carries `task_depth: u8`. If
   `>= 8`, return `error.MaxRecursionDepth`. Child inherits
   `task_depth + 1`.
3. **Build child Runner.** Fresh `ConversationHistory` (empty).
   `Collector` sink. System prompt = `subagent.prompt`. Model:
   resolve `subagent.model orelse parent.provider.model` (cache
   shared `ProviderResult`s across same-model invocations). Tools:
   `ToolRegistry.subset(subagent.tools orelse parent.tools)`, a
   read-only view that refuses lookups outside the allowlist.
4. **Persistence wiring.** Child's session handle is a thin wrapper
   that writes to the parent's JSONL with `type` values prefixed
   `task_` and with the task's ULID carried as the parent_id root for
   the subtree.
5. **Submit.** Write `task_start` event. Inject `prompt` as the
   child's first user message. Run the child's agent loop to
   termination (final assistant message with no tool_use, hard error,
   or depth cap).
6. **Collect.** `Collector.final_text` holds the last assistant text.
   Write `task_end` with `tokens_in`, `tokens_out`, `duration_ms`.
7. **Tear down.** Deinit child Runner, ConversationHistory, Collector.
   Return the collected text to parent's tool dispatch as the
   `tool_result`.

The parent's turn blocks for the duration. UI shows the parent pane's
normal "tool running" indicator. No pane split, no visual of child
work; that's [#1](https://github.com/vtemian/zag/issues/1).

### The `Collector` sink

New minimal Sink impl in `src/sinks/collector.zig`. Captures only the
child's final assistant-message text. Every other event still lands in
JSONL via the persistence wrapper; Collector is purely an in-memory
result accumulator.

```zig
pub const Collector = struct {
    alloc: std.mem.Allocator,
    final_text: std.ArrayList(u8) = .empty,
    done: bool = false,

    pub fn sink(self: *Collector) Sink;
    pub fn deinit(self: *Collector) void;
};
```

`push(ev)` writes `ev.text` into `final_text` on `.assistant_final`
(overwriting any earlier value) and flips `done = true` on `.run_end`.
All other event variants are dropped.

`task.zig` initialises a Collector on the stack, plugs it in as the
child Runner's sole sink, pumps the Runner until `collector.done`,
then returns `collector.final_text.items` as the tool result.

### JSONL event schema

Every event carries a ULID `id` and a `parent_id` (null for root).
Tool_uses are nested inside their assistant event as an array with
local ULIDs; `tool_result.parent_id` points at the assistant event and
`tool_result.tool_use_id` names the specific call.

```jsonl
{"id":"01HRK...u1","parent_id":null,"type":"user","text":"review my diff"}
{"id":"01HRK...a1","parent_id":"01HRK...u1","type":"assistant","text":"Delegating.","tool_uses":[{"id":"01HRK...tu1","name":"task","input":{"agent":"reviewer","prompt":"Review the staged diff"}}]}
{"id":"01HRK...ts1","parent_id":"01HRK...a1","tool_use_id":"01HRK...tu1","type":"task_start","agent":"reviewer","model":"anthropic/claude-haiku-4-5"}
{"id":"01HRK...tm1","parent_id":"01HRK...ts1","type":"task_message","role":"user","text":"Review the staged diff"}
{"id":"01HRK...tm2","parent_id":"01HRK...tm1","type":"task_message","role":"assistant","text":"Reading...","tool_uses":[{"id":"01HRK...tc1","name":"read","input":{"path":"src/foo.zig"}}]}
{"id":"01HRK...trX","parent_id":"01HRK...tm2","tool_use_id":"01HRK...tc1","type":"tool_result","ok":true,"text":"<contents>"}
{"id":"01HRK...tm3","parent_id":"01HRK...trX","type":"task_message","role":"assistant","text":"Found 3 issues: ..."}
{"id":"01HRK...te1","parent_id":"01HRK...ts1","type":"task_end","tokens_in":1200,"tokens_out":180,"duration_ms":3400}
{"id":"01HRK...tr1","parent_id":"01HRK...a1","tool_use_id":"01HRK...tu1","type":"tool_result","ok":true,"text":"Found 3 issues: ..."}
{"id":"01HRK...a2","parent_id":"01HRK...tr1","type":"assistant","text":"I'll fix these three..."}
```

Parser discipline: unknown `type` values are skipped (forward-compat).
Malformed lines logged and dropped, never halting replay. ULIDs are
26-char Crockford-base32, time-sortable, so replay can also be done by
`sort` on the `id` field when `parent_id` chains are preserved.

## Testing

### Unit

- `SubagentRegistry.register` rejects duplicate names, invalid name
  characters, empty descriptions.
- `SubagentRegistry.taskToolSchema` emits the expected enum plus
  per-entry description.
- `Collector.push` captures the last `.assistant_final`, ignores
  earlier ones, flips `done` on `.run_end`.
- `ToolRegistry.subset(names)` refuses lookups outside the allowlist;
  inherit (null) returns the parent registry intact.
- YAML frontmatter parser: all spec field types round-trip; missing
  required fields error; extra fields warn but don't fail.
- ULID generator: 26 chars, lexicographically sortable within the
  same millisecond.
- JSONL parser: reads events, builds a parent_id tree, drops unknown
  types without error.

### Integration (stub Provider)

- Task returns the stub's final message verbatim to the parent.
- Max-depth cap: 8 nested task calls; the 9th returns
  `error.MaxRecursionDepth`.
- Unknown agent → tool error with the list of registered names in
  the message.
- Tool-allowlist violation: child tries to call a tool not in its
  subset → dispatch-time refusal, error propagates to child's LLM as
  a tool error, child recovers or returns an error summary.
- JSONL persistence: after a task run, the parent JSONL contains a
  well-formed `task_start` / `task_end` pair, every event has a
  unique ULID, every non-root event has a `parent_id` that resolves.

### End-to-end (manual, documented)

- Register a `reviewer` subagent with `model: anthropic/claude-haiku-4-5`.
- Run against a real repo: "review my staged diff".
- Observe: Haiku invoked for the child, the pane's current default
  (Sonnet or equivalent) for the parent.
- `jq '.type' .zag/sessions/<id>/session.jsonl | sort | uniq -c`
  shows `task_start`, `task_end`, and the expected task_message /
  tool_use / tool_result mix.

## Open follow-ups

- Visual-mode tree navigation of subagent runs
  ([#1](https://github.com/vtemian/zag/issues/1)).
- Smart skills catalog filtering + dynamic insertion
  ([#2](https://github.com/vtemian/zag/issues/2)).
- Dynamic Lua config reloading with enum rebuild
  ([#3](https://github.com/vtemian/zag/issues/3)).
- Multi-sink fan-out (Buffer + Collector simultaneously) once visual
  mode ratifies the interaction model.
- Per-skill activation gating / permission rules.
- JSONL migration of the existing session format to ULID `id` +
  `parent_id` (schema change touches Session.zig writers).
