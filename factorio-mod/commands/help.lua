-- AI Companion - Help
local u = require("commands.init")
local contract = require("commands.contract")

-- Version command
u.register("version", function(args)
  local version = script.active_mods["ai-companion"] or "unknown"
  u.json_response({version = version, factorio = script.active_mods["base"] or "unknown"})
end)

u.register("get_errors", function(args)
  u.json_response({errors = storage.errors or {}})
end)

u.register("help", function(args)
  local version = script.active_mods["ai-companion"] or "unknown"
  local tools = {}
  for name, definition in pairs(contract) do
    if definition.execution == "game" then tools[#tools + 1] = {name = name, description = definition.description, inputSchema = definition.inputSchema} end
  end
  table.sort(tools, function(a, b) return a.name < b.name end)
  u.json_response({version = version, count = #tools, tools = tools})
end)
