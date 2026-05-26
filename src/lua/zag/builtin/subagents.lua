-- Builtin subagents: zag's default delegate, registered on every startup.
--
-- Registering at least one subagent is what makes the `task` tool visible
-- to the model (see `tools.registerTaskTool`, gated on registry size). This
-- module ships a single general-purpose agent so delegation works with zero
-- user config. User-defined subagents, whether inline via
-- `zag.subagent.register{...}` or discovered by `zag.subagents.filesystem`,
-- register alongside it.
--
-- The default inherits the parent's tool set (no `tools` field), so it can
-- read, edit, and run commands; nested delegation stays bounded by the task
-- depth cap in `tools/task.zig`.

zag.subagent.register {
  name = "general",
  description = "General-purpose agent for researching questions, searching the codebase, and carrying out self-contained multi-step tasks. Delegate exploratory or well-scoped work to it and build on the summary it returns.",
  prompt = [[
You are a focused, autonomous subagent spawned to handle one self-contained task.

Investigate thoroughly with your tools, do the work, and finish with a concise, factual summary of what you found or changed. You run in a single delegated loop and cannot ask the user questions, so make reasonable decisions and state any assumptions you relied on. Prefer evidence over speculation, and cite file paths and line numbers when they matter. Keep the final summary tight and actionable.
]],
}
