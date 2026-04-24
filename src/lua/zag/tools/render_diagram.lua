-- zag.tools.render_diagram: built in tool for rendering diagrams.
-- Usage in config.lua: require("zag.tools.render_diagram")

local diagrams = require("zag.diagrams")

zag.tool {
  name = "render_diagram",
  description = "Render a small diagram (graphviz or d2) and show it in a new pane.",
  input_schema = {
    type = "object",
    properties = {
      engine = {
        type = "string",
        enum = { "graphviz", "d2" },
        description = "Rendering engine. Prefer d2 for richer diagrams; graphviz is universal.",
      },
      source = { type = "string", description = "Diagram source code in the engine's DSL." },
      title = { type = "string" },
      direction = { type = "string", enum = { "horizontal", "vertical" } },
    },
    required = { "source" },
  },
  execute = function(input)
    local engine = input.engine or "graphviz"
    local pane_id, err = diagrams.show(engine, input.source, {
      title = input.title,
      direction = input.direction,
    })
    if not pane_id then return nil, err end
    return "rendered diagram in pane " .. pane_id
  end,
}
