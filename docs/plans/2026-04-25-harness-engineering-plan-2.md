# Harness Engineering Implementation Plan: Post-Foundation (PRs 8-11)

> **For Claude:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task.

**Goal:** Build the four post-foundation PRs that take Zag from "frontier-model harness" to "small-model viable." JIT context on tool results, tool output transforms + tool gate, loop detector + compaction sockets, and the first concrete small-model pack (Qwen3-Coder).

**Architecture:** Every new API in this plan is a **socket**: a Lua-registerable hook the harness consults at a specific lifecycle point. Sockets are no-ops by default on frontier models. Each socket gets a Zig-side dispatch path that routes through the existing main-thread marshalling pattern (mirrors `PromptAssemblyRequest` from PR 3). The socket handlers attach via `zag.context.on_tool_result`, `zag.tool.transform_output`, `zag.tools.gate`, `zag.loop.detect`, `zag.compact.strategy`. The Qwen3-Coder pack composes those primitives.

**Tech stack:** Zig 0.15, ziglua, the foundation already shipped: `prompt.Registry`, `Reminder.Queue`, `Instruction.findUp`, `PromptAssemblyRequest` event pattern, `Sink` vtable, `BufferSink`, `Hooks`.

**Foundation references (mainline tip 16e34a6):**
- Sockets must follow the `prompt_assembly_request` thread-marshal pattern: `src/agent_events.zig:351` (PromptAssemblyRequest), `src/AgentRunner.zig:dispatchHookRequests`.
- `Reminder.Queue` already supports per-turn injection; loop detector reuses this.
- `Hooks.EventKind` enumerates lifecycle points; new sockets either reuse existing kinds or get new ones.
- `LayerContext` is the carrier for env data (cwd, worktree, date_iso, is_git_repo, platform); JIT context handlers receive a richer ToolResultContext.
- Tool registry: `src/tools.zig` `Registry`, `Subset` (added by Vlad's subagent work; gate composes on top of this).

**Design doc:** `docs/plans/2026-04-23-harness-engineering-design.md` (sections "Lua surface" lines 227-266, "Sequencing" lines 332-368).

---

## Working conventions

Identical to the foundation plan:
- No em dashes or hyphens-as-dashes anywhere in code, comments, tests, or commit messages.
- Tests live inline in the same file.
- `testing.allocator`, `.empty` for ArrayList, `errdefer` on every allocation in init chains.
- After every task: `zig build test`, `zig fmt --check .`, `zig build` must all exit 0 before committing.
- Commit subjects follow `<subsystem>: <description>` with the standard Co-Authored-By trailer via HEREDOC.
- Fully qualified absolute paths for every Edit/Write call.
- Run `zig build test` AFTER any rebase BEFORE fast-forwarding to main. (Lesson burned in from PR 3.)

---

## PR sequence

| PR | Scope | P | Depends |
|----|-------|---|---------|
| 8  | JIT context on tool results | P1 | PR 6 (Instruction loader), PR 3 (main-thread marshal pattern) |
| 9  | Tool output transform + tool gate | P1 | PR 3, ToolRegistry.subset |
| 10 | Loop detector + compaction | P1 | PR 7 (Reminder queue feeds detector interventions) |
| 11 | Qwen3-Coder small-model pack | P2 | PRs 8, 9, 10 |

PRs 8, 9, 10 are independent and can land in any order. PR 11 needs all three.

---

## PR 8: JIT context on tool results

**Goal:** When a `read` tool returns, walk up from the read path looking for `AGENTS.md` / `CLAUDE.md`. Attach the content under the tool result as `Instructions from: <path>\n<content>`. Dedup per message: same file attached at most once per turn even if read multiple times.

**Why:** Frontier models can ingest project-wide AGENTS.md once at session start. Small models lose context fast. JIT attachment puts the relevant local conventions directly next to the tool result that surfaced them.

### Task 8.1: Add `zag.context.on_tool_result` socket

**Files:**
- Create: `src/agent_events.zig` add `JitContextRequest` struct + AgentEvent variant.
- Modify: `src/LuaEngine.zig` add `zag.context.on_tool_result(tool_name, fn)` binding.
- Modify: `src/AgentRunner.zig` dispatch `jit_context_request` from `dispatchHookRequests`.

**Step 1: Failing test (LuaEngine.zig).**

```zig
test "zag.context.on_tool_result registers a handler keyed by tool name" {
    const alloc = std.testing.allocator;
    var engine = try LuaEngine.init(alloc);
    defer engine.deinit();
    engine.storeSelfPointer();

    try engine.lua.doString(
        \\zag.context.on_tool_result("read", function(result)
        \\  return "stub for: " .. result.input
        \\end)
    );
    try std.testing.expect(engine.jitContextHandlers().count() >= 1);
}
```

Run: `zig build test --filter on_tool_result`: expect FAIL.

**Step 2: Add JitContextRequest to agent_events.zig.**

```zig
pub const JitContextRequest = struct {
    tool_name: []const u8,
    input: []const u8,
    output: []const u8,
    is_error: bool,
    metadata: ?[]const u8 = null,
    allocator: Allocator,
    done: std.Thread.ResetEvent = .{},
    /// Returned content to attach under the tool result. Owned by the
    /// allocator. Null = no append.
    result: ?[]u8 = null,
    error_name: ?[]const u8 = null,

    pub fn init(
        tool_name: []const u8,
        input: []const u8,
        output: []const u8,
        is_error: bool,
        allocator: Allocator,
    ) JitContextRequest { ... }
};
```

Add to AgentEvent union: `jit_context_request: *JitContextRequest`.

**Step 3: LuaEngine handler registry.**

```zig
// In LuaEngine struct:
jit_context_handlers: std.StringHashMap(JitHandler) = .{},

const JitHandler = struct {
    tool_name: []u8,        // owned
    fn_ref: i32,            // Lua registry ref
};
```

`zagContextOnToolResultFn` parses `(string, function)`, stashes the function via `lua.ref(registry_index)`, stores the entry in `jit_context_handlers`.

`engine.deinit` walks the map, unrefs each fn, frees owned tool_name strings.

**Step 4: AgentRunner dispatch.**

In the existing `dispatchHookRequests` (the main-thread drain), add a new arm:

```zig
.jit_context_request => |req| {
    self.handleJitContextRequest(req) catch |e| {
        req.error_name = @errorName(e);
    };
    req.done.set();
},
```

`handleJitContextRequest` looks up the handler by `tool_name`, calls it via `lua.protectedCall` with the result table built from `req.input/output/is_error/metadata`, captures the returned string (dupe into `req.allocator`).

**Step 5: Inline tests.**

- Register handler, push request, drain → assert result populated.
- Unknown tool name → result null, no error.
- Lua handler that errors → error_name populated, request still completes.
- Engine deinit unrefs all handlers (testing.allocator leak check).

Run: `zig build test --filter on_tool_result`: PASS.

**Step 6: Commit.**

```bash
git add src/agent_events.zig src/LuaEngine.zig src/AgentRunner.zig
git commit -m "harness: zag.context.on_tool_result JIT context socket
..."
```

### Task 8.2: Wire JIT context into tool dispatch

**Files:**
- Modify: `src/agent.zig`: after a tool result is built, before it's pushed to messages, fire `jit_context_request` and append the returned string to the tool_result content.

**Step 1: Failing test.**

Inline test in `src/agent.zig`:

```zig
test "jit context handler appends content to tool result" {
    // Build a minimal agent loop fixture:
    // - Register a Lua handler for "read" that returns "Instructions: foo".
    // - Inject a fake tool_result for read.
    // - Run one tool-result-attach iteration.
    // - Assert messages[].content contains "Instructions: foo".
}
```

**Step 2: Wire dispatch.**

In `runLoopStreaming`, find where `ToolResult` blocks are appended to the message history (search for `tool_result_block` or `addToolResult`). After the result is built, before push:

```zig
if (lua_engine) |engine| {
    if (engine.jit_context_handlers.get(tool_name)) |_| {
        var req = JitContextRequest.init(tool_name, tool_input, tool_output, is_error, alloc);
        try queue.push(.{ .jit_context_request = &req });
        req.done.wait();
        if (req.result) |attached| {
            // Append to the tool_result content.
            tool_output = try std.fmt.allocPrint(alloc, "{s}\n\n{s}", .{ tool_output, attached });
            alloc.free(attached);
        }
    }
}
```

Watch for ownership: the original tool_output may live in arena memory; the new combined string needs to be stable until the message is consumed.

**Step 3: Run tests, commit.**

### Task 8.3: Default `agents_md` JIT layer

**Files:**
- Create: `src/lua/zag/jit/agents_md.lua`: the default JIT handler. Walks up from `result.input` (the file path the user read) looking for `AGENTS.md`. Dedups per turn via a per-message marker.
- Modify: `src/lua/embedded.zig`: add the entry, bump count.

**Step 1: Lua module.**

```lua
-- zag.jit.agents_md
-- On read tool results, walk up from the read path looking for AGENTS.md
-- and append its content under the result. Dedups per turn.

local seen_this_turn = {}

zag.context.on_tool_result("read", function(result)
  -- result.input is the JSON string the agent passed; extract the path.
  local input_obj = vim.json.decode(result.input) -- TODO: use zag.json once exposed
  local path = input_obj.path or input_obj.file_path
  if not path then return nil end

  local found = zag.context.find_up({"AGENTS.md", "CLAUDE.md", "CONTEXT.md"}, {
    from = path,
    to = nil,  -- walk to filesystem root
  })
  if not found then return nil end
  if seen_this_turn[found.path] then return nil end
  seen_this_turn[found.path] = true

  return string.format("Instructions from: %s\n%s", found.path, found.content)
end)

-- Reset dedup on turn boundary. Hook to be added in 8.4 if not already wired.
```

**Step 2: Embed + register.**

Add `.{ .name = "zag.jit.agents_md", .code = @embedFile("zag/jit/agents_md.lua") }`. Bump count.

**Step 3: Eager-load.**

Extend `loadBuiltinPlugins` to also auto-load `zag.jit.*` (mirrors `zag.layers.*` pattern).

**Step 4: Commit.**

### Task 8.4: Per-turn dedup state

**Files:**
- Modify: `src/agent.zig`: emit a `turn_end` Lua hook that the agents_md JIT module hooks into to clear `seen_this_turn`.

**Step 1: Confirm `Hooks.EventKind.turn_end` exists.** If not, add it. (Foundation may already have it.)

**Step 2: Hook from agents_md.lua.**

```lua
zag.hook("turn_end", function() seen_this_turn = {} end)
```

**Step 3: Test.**

- Two reads of the same parent dir within one turn → AGENTS.md attached once.
- Two reads across two turns → AGENTS.md attached on each.

**Step 4: Commit.**

### Task 8.5: Integration test

End-to-end: spawn an engine, drop AGENTS.md in tmpDir, register the default jit handler, fire a fake `read` tool result with input pointing at a child of tmpDir, drain the request, assert the assembled tool_output contains `Instructions from:` followed by the AGENTS.md content.

---

## PR 9: Tool output transform + tool gate

**Goal:** Two sockets that don't intervene by default but let plugins reshape what tools see and emit. `zag.tool.transform_output(name, fn)` rewrites the tool result text after execution. `zag.tools.gate(fn)` returns the visible tool subset per turn.

**Why:** Small models choke on large tool outputs (`rg` of a big repo) and on deep tool menus. Transforms trim noise; gates narrow the menu per turn.

### Task 9.1: `zag.tool.transform_output` socket

**Files:**
- Create: AgentEvent variant `ToolTransformRequest` in `src/agent_events.zig`.
- Modify: `src/LuaEngine.zig` add `zag.tool.transform_output(name, fn)` binding + handler registry.
- Modify: `src/agent.zig` fire the transform after tool execution, before the result is pushed.

Mirrors PR 8 Task 8.1 + 8.2 structure exactly. Same dispatch pattern, same allocator hygiene. Diff: the result REPLACES tool_output (not appends).

Tests:
- Register transform for `bash`, returns `"trimmed"`, assert tool_output becomes `"trimmed"`.
- Returns nil → passthrough.
- Multiple transforms registered for same tool name → last-write-wins (or chain; pick one, document).

### Task 9.2: `zag.tools.gate` socket

**Files:**
- Modify: `src/agent_events.zig` add `ToolGateRequest`.
- Modify: `src/LuaEngine.zig` `zag.tools.gate(fn)` binding (single global handler; re-registering replaces).
- Modify: `src/agent.zig` fire the gate before each `callLlm`, populate the LLM request's tool list with the subset.

The gate runs once per turn (at request build time), not per tool call. Returns a `[]const u8` of tool names; agent.zig calls `tools.Registry.subset(allowed_names)` (the helper Vlad added) and threads the result into the request.

If gate returns nil or empty → fall back to the full registry.

Tests:
- Gate returns `{"read", "bash"}` → request tool list excludes everything else.
- Gate errors → log warn, fall back to full registry.
- No gate registered → existing behavior (full registry).

### Task 9.3: Stdlib transform examples

**Files:**
- Create: `src/lua/zag/transforms/rg_trim.lua`: example transform for grep results, trims past 200 lines. Opt-in via `require("zag.transforms.rg_trim")`.
- Create: `src/lua/zag/transforms/bash_trim.lua`: same shape for bash, trims past 500 lines.

Not auto-loaded. Documented as opt-in in `docs/scripting-prompt-layers.md` (extend that doc).

Tests:
- `rg_trim` on a 300-line input keeps the first 200 + a `... [N lines elided]` marker.
- `bash_trim` on a 100-line input passes through unchanged.

### Task 9.4: Documentation

Extend `docs/scripting-prompt-layers.md` with sections for `zag.tool.transform_output`, `zag.tools.gate`, and the opt-in transform stdlib. One example per socket.

---

## PR 10: Loop detector + compaction

**Goal:** Two more sockets. `zag.loop.detect(fn)` runs after each tool execution; can return `{action = "reminder", text = ...}` to inject a reminder, or `{action = "abort"}` to stop the loop. `zag.compact.strategy(fn)` runs when the agent decides to compact (token budget threshold).

**Why:** Frontier models rarely loop forever, but they do occasionally. Small models loop more. Compaction lets long sessions survive past the context window.

### Task 10.1: Loop detector socket

**Files:**
- `src/agent_events.zig`: `LoopDetectRequest` with input fields `identical_streak: u32, last_tool_name, last_tool_input`, returns `?LoopAction { reminder | abort | none }`.
- `src/LuaEngine.zig`: `zag.loop.detect(fn)` binding (single global handler).
- `src/agent.zig`: track `identical_streak` across turn iterations, fire the detector after each tool result, act on the response (push reminder via `Reminder.Queue`, or set a cancel flag).

The detector reuses PR 7's `Reminder.Queue`: when the action is `reminder`, push a `next_turn` reminder with the returned text. The reminder injection at the next user message boundary picks it up.

Tests:
- 3 identical bash calls → handler returns reminder → next turn's user message contains `<system-reminder>` with the text.
- 5 identical reads, handler returns abort → loop terminates with a clear error.
- No handler registered → loop runs unimpeded.

### Task 10.2: Default lenient detector

**Files:**
- Create: `src/lua/zag/loop/default.lua`: flags at 5 identical calls. Emits a reminder, never aborts. Auto-loaded.

```lua
zag.loop.detect(function(ctx)
  if ctx.identical_streak >= 5 then
    return { action = "reminder", text = "You've called " .. ctx.last_tool_name .. " " .. ctx.identical_streak .. "x with the same input. Try a different approach or stop." }
  end
end)
```

Embed + auto-load via the `zag.loop.*` prefix in `loadBuiltinPlugins`.

### Task 10.3: Compaction socket

**Files:**
- `src/agent_events.zig`: `CompactRequest` carrying `messages: []types.Message` (mutable), `tokens_used`, `tokens_max`.
- `src/LuaEngine.zig`: `zag.compact.strategy(fn)` binding.
- `src/agent.zig`: fire the request when `tokens_used > 0.80 * tokens_max`. Strategy mutates `messages` in place; agent reads back the result.

The marshalling is heavier here because `messages` is a complex object. Two options:
- (a) Snapshot to a Lua table before calling, replace the entire history from the returned table.
- (b) Pass an opaque handle and expose `zag.history.*` accessors that the strategy uses.

Option (a) is simpler and matches the design doc's prose. Option (b) is more efficient. Pick (a) for v1; document the inefficiency.

Tests:
- Strategy that drops oldest tool_result blocks → assert messages shrunk.
- Strategy that returns unchanged → assert messages identical.
- No strategy registered → compaction is a no-op.

### Task 10.4: Default compaction

**Files:**
- Create: `src/lua/zag/compact/default.lua`: when triggered, summarize tool_result blocks older than the most recent user turn, replacing each with a one-line `<elided tool_result>` marker.

Auto-loaded via `zag.compact.*` prefix.

### Task 10.5: Integration test

End-to-end: build a 90% full context, fire compaction, assert old tool_results are elided. Loop detector: fire 5 identical reads, assert reminder pushed.

---

## PR 11: Qwen3-Coder small-model pack

**Goal:** First concrete proof that the harness primitives compose into a usable small-model experience. Ship a pack tuned for Qwen3-Coder running on M3 Max.

**Why:** Frontier models forgive a weak harness. Small models do not. PR 11 is where the foundation pays off or where we discover what's still missing.

### Task 11.1: Detect Qwen3-Coder model id

**Files:**
- Modify: `src/lua/zag/prompt/init.lua`: extend `M.PACKS` to route Qwen3-Coder ids to `zag.prompt.qwen3-coder`.

Pattern matches `qwen3-coder*` and `qwen3-coder-*-instruct*`.

Tests:
- `M.resolve("ollama/qwen3-coder-30b-instruct")` → `"zag.prompt.qwen3-coder"`.

### Task 11.2: `zag.prompt.qwen3-coder` pack

**Files:**
- Create: `src/lua/zag/prompt/qwen3-coder.lua`.

Contents (sketch):
```lua
local M = {}

function M.render(ctx)
  return [[
You are zag, a coding assistant running with Qwen3-Coder.

# Tool use
- Call tools with valid JSON arguments. Most failures here come from missing required fields.
- One tool per turn unless the previous result was empty.
- Read before edit.

# Style
- Terse. No filler.
- Code blocks for code; plain text for explanation.
]]
end

return M
```

Embed + count bump.

### Task 11.3: Qwen-specific overrides

In `qwen3-coder.lua` (or a sibling module), wire:

```lua
-- Override loop detector to flag at 2 identical calls (vs 5 for default)
zag.loop.detect(function(ctx)
  if ctx.identical_streak >= 2 then
    return { action = "reminder", text = "..." }
  end
end)

-- Gate to read/edit/bash/grep/glob only
zag.tools.gate(function(ctx)
  return { "read", "edit", "bash", "grep", "glob" }
end)

-- Aggressive transforms
require("zag.transforms.rg_trim")  -- 200-line cap
require("zag.transforms.bash_trim") -- 500-line cap
```

Auto-applied when the pack is the active dispatch target. Sandbox question: does loading the pack register hooks GLOBALLY, or scoped to "while this model is active"? Plan dictates. Conservative: global registration on first dispatch, no automatic deregistration when the user swaps models. Document clearly.

### Task 11.4: Benchmark harness (out of plan scope, listed for tracking)

This is the "almost as good as Claude" claim from the design doc. Real benchmarking against Terminal-Bench or harbor runs needs:
- A separate eval harness setup
- Compute (M3 Max + LM Studio + Cline baseline)
- Time

NOT a code task. Capture as a separate follow-up issue/note.

### Task 11.5: Integration test

Mock-based test: register the qwen3-coder pack, set ctx.model_id to `qwen3-coder-30b`, render the prompt, assert pack identity line + tool gate restricting to 5 names + loop detector at threshold 2.

---

## Testing strategy

### Unit tests
Every new module + binding ships with inline tests targeting both happy path and edge cases (handler errors, no-engine, ownership).

### Integration tests
- `Reminder.Queue` interaction with loop detector reminders.
- JIT context dedup across reads in the same turn.
- Tool gate restriction visible in outgoing request payload.

### Manual smoke (deferred to user)
- Run with sonnet-4-5 and verify nothing regresses (sockets are no-ops on default).
- Run with qwen3-coder via Ollama, ask it to read+edit a file, verify the tool gate applies and the loop detector fires when expected.

---

## Cross-cutting concerns

### Main-thread discipline
Every new socket follows the `PromptAssemblyRequest` pattern: agent worker pushes a request event, main thread services from `dispatchHookRequests`, worker waits on `done`. No new threading mechanisms.

### Allocator hygiene
Strategy/transform/gate handlers return strings or tables that get duped into the request's allocator. Caller is responsible for freeing the result after use. Document at each binding.

### Layer priority bands
Per design line 330: `0-99` identity/pack, `100-899` context, `900-999` pre-volatile, `1000+` volatile. The new sockets do NOT register layers (they're orthogonal); but if the qwen3-coder pack registers a stable layer, it lands in the 0-99 band.

### Backward compatibility
All sockets default to no-op when no handler is registered. Existing user prompts and request shapes are byte-identical when no PR-8/9/10/11 plugin is loaded.

---

## Risks and gotchas

1. **Compaction marshalling cost.** Snapshotting full message history into Lua and back per compaction is O(N) where N is message count + content size. Acceptable for now; revisit if profiling shows pain.
2. **Per-turn dedup state lifetime.** PR 8.4's `seen_this_turn` table lives in module scope. Engine teardown should call the turn_end hook one last time to release. Test it.
3. **Tool gate race with parallel tool calls.** The gate decides at request-build time. If a turn produces parallel tool calls, the gate has already run; mid-turn gate changes don't apply. Document explicitly.
4. **Loop detector + reminder injection timing.** Detector fires after a tool result. The reminder is pushed `scope = next_turn`. So the reminder appears at the NEXT user message, not the current iteration's next tool call. This matches the design doc but may surprise plugin authors.
5. **Qwen3-Coder pack pulls in transforms via `require()`.** If the user's config.lua loads multiple packs, the transforms compete. Last-require-wins. Document.

---

## Verification checklist

- [ ] `zig build` passes.
- [ ] `zig build test` passes (~30 new inline tests across PRs 8-11).
- [ ] `zig fmt --check .` passes.
- [ ] Sockets default to no-op when no handler registered (regression-tested via existing agent loop tests).
- [ ] Reminder.Queue still works after PR 10 wires the loop detector through it.
- [ ] Each PR's stdlib module is registered in embedded.zig with the count bumped.
- [ ] `loadBuiltinPlugins` extended for any new auto-load prefix.
- [ ] No pushes to origin without `zig build test` green AFTER the rebase.

---

## Execution handoff

After saving the plan, two execution options:

**1. Subagent-driven (this session).** I dispatch a fresh subagent per task, review between tasks, fast iteration. Same flow as PRs 1-7.

**2. Parallel session (separate).** New session with `superpowers:executing-plans`, batch execution with checkpoints.

PRs 8-11 are an estimated 18-22 subagent dispatches across 4 worktrees. Same rebase risk pattern as the foundation: expect Vlad's parallel commits to require rebase between each PR's worktree merge.

**Which approach?**
