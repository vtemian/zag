# Skills + subagents implementation plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ship filesystem-based skills (agentskills.io spec) and Lua-registered subagents, invoked by the LLM through a single `task(agent, prompt)` tool. Subagent output is hidden (Collector sink); subagent events persist inline in the parent JSONL with `task_*` types. Visual tree navigation is deferred to issue #1, smart skill filtering to #2, dynamic Lua reload to #3.

**Execution order:** Third of three plans.

1. `2026-04-24-buffer-pane-runner-decoupling-plan.md` — prerequisite.
2. `2026-04-24-jsonl-tree-migration-plan.md` — prerequisite.
3. **[this plan] Skills + subagents**

**Source design:** `docs/plans/2026-04-24-skills-and-subagents-design.md`.

**Tech Stack:** Zig 0.15 std, `ziglua` (for subagent Lua registration), existing YAML parsing helpers or a narrow custom frontmatter parser, existing `ToolRegistry` and `AgentRunner` infrastructure (post-plan 1), ULID module from plan 2.

**Non-scope**

- Visual tree navigation of subagent runs (#1).
- Smart skill catalog filtering (#2).
- Dynamic Lua config reload (#3).
- Multi-sink fan-out.
- Skill permission rules beyond `allowed-tools` frontmatter.

---

## Working conventions

- **No em dashes or hyphens as dashes** anywhere.
- Tests live inline.
- `testing.allocator`, `.empty` ArrayList init, `errdefer` on every allocation.
- After every task: `zig build test`, `zig fmt --check .`, `zig build` must all exit 0 before committing.
- Commit subjects follow `<subsystem>: <description>` with the standard `Co-Authored-By` trailer.
- Fully qualified absolute paths for every Edit / Write.
- Each task = one commit. Do not batch tasks.

---

## Task 1: YAML frontmatter parser

**Files:**
- Create: `/Users/whitemonk/projects/ai/zag/src/frontmatter.zig`

**Design**

```zig
pub const Frontmatter = struct {
    fields: std.StringHashMapUnmanaged(Value),
    body_start: usize,  // byte offset where markdown body begins
};

pub const Value = union(enum) {
    string: []const u8,
    list: []const []const u8,
};

pub fn parse(alloc: Allocator, src: []const u8) !Frontmatter;
```

Narrow YAML subset: `---\n<key>: <scalar-or-list>\n---\n<body>`. Scalars can be plain or quoted; lists can be inline (`[a, b, c]`) or block (`- a\n- b\n`). Unknown keys accepted; parser is permissive (warn-only) on unknown types.

**Tests:** Five cases minimum — minimal skill frontmatter, quoted strings with special chars, inline list, block list, unknown field accepted as string.

**Commit:** `frontmatter: add narrow YAML frontmatter parser`

---

## Task 2: `SkillRegistry` with filesystem discovery

**Files:**
- Create: `/Users/whitemonk/projects/ai/zag/src/skills.zig`

**Design**

```zig
pub const Skill = struct {
    name: []const u8,
    description: []const u8,
    path: []const u8,             // absolute SKILL.md path
    allowed_tools: ?[]const u8 = null,
    license: ?[]const u8 = null,
};

pub const SkillRegistry = struct {
    skills: std.ArrayListUnmanaged(Skill) = .empty,

    pub fn discover(alloc: Allocator, config_home: []const u8, project_root: ?[]const u8) !SkillRegistry;
    pub fn catalog(self: *const SkillRegistry, writer: anytype) !void;
    pub fn deinit(self: *SkillRegistry, alloc: Allocator) void;
};
```

Walk three roots in precedence order:
1. `<project>/.zag/skills/`
2. `<project>/.agents/skills/`
3. `<config_home>/skills/` (e.g., `~/.config/zag/skills/`)

For each root: list immediate subdirs; if a subdir contains `SKILL.md`, parse its frontmatter and append. On name collision, project entries shadow user entries; emit a `warn` with both paths.

Name validation: `[a-z0-9-]+`, 1–64 chars, no leading/trailing hyphen, no double hyphen. Invalid names are rejected with an `err` log and the skill skipped.

Catalog format:

```
<available_skills>
  <skill name="roll-dice" path="/abs/.../SKILL.md">Roll dice using a random number generator.</skill>
</available_skills>
```

**Tests:**
- `discover` finds skills across all three roots.
- Project shadows user.
- Invalid names rejected.
- `catalog` produces well-formed XML with proper escaping.

**Commit:** `skills: add SkillRegistry with filesystem discovery and catalog`

---

## Task 3: Wire skills catalog into the system prompt

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/src/AgentRunner.zig` (or wherever the system prompt is assembled)

**Design**

At Runner init, the caller passes the `SkillRegistry` (or nil). System-prompt assembly appends `<available_skills>...` to the existing base prompt when the registry has entries. Skill bodies are NOT preloaded; the LLM reads them via the existing `read` tool against the absolute path from the catalog.

**Tests:** Integration test constructs a Runner with a two-skill registry, asserts the outgoing request to a stub provider contains `<available_skills>` with both entries.

**Commit:** `agent: inject skills catalog into system prompt`

---

## Task 4: `SubagentRegistry` Zig-side

**Files:**
- Create: `/Users/whitemonk/projects/ai/zag/src/subagents.zig`

**Design**

```zig
pub const Subagent = struct {
    name: []const u8,
    description: []const u8,
    prompt: []const u8,
    model: ?[]const u8 = null,
    tools: ?[]const []const u8 = null,
};

pub const SubagentRegistry = struct {
    pub fn register(self: *SubagentRegistry, alloc: Allocator, sa: Subagent) !void;
    pub fn lookup(self: *const SubagentRegistry, name: []const u8) ?*const Subagent;
    pub fn taskToolSchema(self: *const SubagentRegistry, writer: anytype) !void;
    pub fn deinit(self: *SubagentRegistry, alloc: Allocator) void;
};
```

Storage owns copies of every string (allocator-backed). `register` rejects duplicate names, invalid name chars, empty description. `taskToolSchema` emits the JSON Schema with the `agent` enum and per-entry description built from each subagent's `description`.

**Tests:** Register three agents, look up by name, emit the schema, assert the enum lists all three and descriptions are present.

**Commit:** `subagents: add Zig-side SubagentRegistry`

---

## Task 5: Lua `zag.subagent.register` binding

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/src/LuaEngine.zig`

**Design**

Add a `zag.subagent` table with `register` function. Signature:

```lua
zag.subagent.register{
  name = "...",
  description = "...",
  prompt = [[...]],
  model = "...",    -- optional
  tools = {...},    -- optional
}
```

Binding validates the table, copies strings into allocator-owned memory via the registry, returns nil on success, raises a Lua error on validation failure.

**Tests:** Inline `LuaEngine` test registers two subagents from a Lua snippet, asserts the registry has both.

**Commit:** `lua: bind zag.subagent.register to SubagentRegistry`

---

## Task 6: Filesystem loader stdlib module

**Files:**
- Create: `/Users/whitemonk/projects/ai/zag/lua/zag/subagents/filesystem.lua` (embedded stdlib)

**Design**

Pure Lua module users opt into via `require("zag.subagents.filesystem")`. Walks `.zag/agents/`, `.agents/agents/`, `~/.config/zag/agents/` for `*.md` files; for each file, parses YAML frontmatter (call into the Zig frontmatter parser via a Lua binding, OR reimplement a tiny parser in Lua — prefer the Zig binding via `zag.parse_frontmatter(body)` which we expose in this task) and calls `zag.subagent.register` for each entry.

Expose one new Lua helper: `zag.parse_frontmatter(src) -> { fields = {...}, body = "..." }`.

**Tests:** End-to-end: drop two `.md` files under a tmpdir's `.zag/agents/`, run the stdlib module pointing at that dir, assert the subagent registry has both entries.

**Commit:** `lua: add zag.subagents.filesystem stdlib loader`

---

## Task 7: `ToolRegistry.subset(names)`

**Files:**
- Modify: `/Users/whitemonk/projects/ai/zag/src/tools.zig`

**Design**

```zig
pub fn subset(self: *const ToolRegistry, names: []const []const u8) ToolRegistry;
```

Returns a read-only view backed by the same tool implementations; `lookup` refuses names outside the subset with `error.ToolNotAllowed`. If `names` is `null` (the inherit case), `subset` returns `self` unchanged.

**Tests:** Subset to two tools; look up an allowed name returns ok; look up a denied name returns `error.ToolNotAllowed`; `subset(null)` round-trips.

**Commit:** `tools: add ToolRegistry.subset for subagent tool filtering`

---

## Task 8: The `task` tool

**Files:**
- Create: `/Users/whitemonk/projects/ai/zag/src/tools/task.zig`
- Modify: `/Users/whitemonk/projects/ai/zag/src/tools.zig` (registration)

**Design**

`task` is a built-in tool registered iff the `SubagentRegistry` is non-empty. Its schema is rebuilt from the registry at tool-emit time.

Execution:

1. `SubagentRegistry.lookup(args.agent)` — `error.UnknownSubagent` on miss.
2. Parent Runner's `task_depth >= 8` → `error.MaxRecursionDepth`.
3. Build a child `AgentRunner`:
   - Fresh `ConversationHistory` (empty; no attached session file, writes route to parent's file via wrapper).
   - `Collector` sink.
   - Model: `subagent.model orelse parent.provider.model`. Cache `ProviderResult`s per-model-id across task invocations in the same process.
   - Tools: `parent.tools.subset(subagent.tools)` (`null` inherits all).
   - Depth: `parent.task_depth + 1`.
4. Write `task_start` event via parent's persistence, capturing its ULID as `task_id`; the child's wrapper session handle stamps `parent_id = task_id` on every event it writes (with `type` prefixed `task_`).
5. Inject `args.prompt` as the child's first user message. Run the child loop to termination.
6. After child completes: write `task_end` with metrics. Return `collector.final_text.items` as the tool result.
7. Tear down child Runner, Collector, ConversationHistory, cached-provider (if not shared).

**Tests:**
- Unknown agent → error message includes the list of registered names.
- Max depth → the 9th nested call returns `error.MaxRecursionDepth`.
- Collector captures only the final assistant message, not intermediate deltas.
- JSONL after run: `task_start` and `task_end` pair with matching `parent_id` chain, all `task_*` events have correct `parent_id`.

**Commit:** `tools: add task tool for subagent delegation`

---

## Task 9: End-to-end integration

**Files:** none (smoke + docs)

Manual smoke:

```
# config.lua:
#   require("zag.providers.anthropic")
#   zag.subagent.register{
#     name = "reviewer",
#     description = "Review staged diffs",
#     model = "anthropic/claude-haiku-4-5",
#     prompt = "You are a reviewer. Read the staged diff and return findings.",
#   }
zig build run
# In the TUI: "review my staged diff"
# Expect: parent Sonnet runs, emits task(agent="reviewer", ...); Haiku runs the subagent;
# parent receives the review as tool_result; parent summarises to user.

jq -r '.type' .zag/sessions/<id>/session.jsonl | sort | uniq -c
# Expect: task_start, task_end, task_message, tool_use, tool_result, user, assistant.

jq '.parent_id' .zag/sessions/<id>/session.jsonl | grep -c null
# Expect: 1 (only the root user message has null parent).
```

Skills smoke:

```
mkdir -p .zag/skills/roll-dice
cat > .zag/skills/roll-dice/SKILL.md <<'EOF'
---
name: roll-dice
description: Roll a die. Use when asked to roll N-sided dice.
---
Run `echo $((RANDOM % <sides> + 1))` via bash.
EOF
zig build run
# In the TUI: "roll a d20"
# Expect: LLM sees roll-dice in <available_skills>, reads SKILL.md, runs bash, returns a number.
```

**Commit:** `docs: manual smoke notes for skills and subagents` (update this plan file with the smoke results)

---

## Rollback

If `task` tool execution corrupts parent JSONL (wrong parent_id chain, missing task_end), revert tasks 8 and 4 in that order. Skills-only functionality (tasks 1-3) stands alone and is safe to keep.

If Lua registration (task 5) misbehaves, the filesystem loader (task 6) depends on it and must be reverted together.
