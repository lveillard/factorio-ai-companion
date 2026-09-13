local lifecycle = require("commands.lifecycle")
local u = require("commands.init")
local contract = require("commands.contract")
local M = {}

local function validate(value, schema, path)
  if schema.oneOf then
    local matches = 0
    local selected
    for _, branch in ipairs(schema.oneOf) do
      local candidate = helpers.json_to_table(helpers.table_to_json(value))
      if pcall(validate, candidate, branch, path) then matches = matches + 1; selected = candidate end
    end
    if matches ~= 1 then error(path .. " must match one supported task step; inspect its schema") end
    for key in pairs(value) do value[key] = nil end
    for key, item in pairs(selected) do value[key] = item end
    return
  end
  local kind = schema.type
  if kind == "object" then
    if type(value) ~= "table" then error(path .. " must be an object") end
    for _, key in ipairs(schema.required or {}) do
      if value[key] == nil then error(path .. "." .. key .. " is required") end
    end
    for key in pairs(value) do
      if schema.additionalProperties == false and not (schema.properties or {})[key] then error("Unknown parameter: " .. tostring(key)) end
    end
    for key, field in pairs(schema.properties or {}) do
      if value[key] == nil and field.default ~= nil then value[key] = field.default end
      if value[key] ~= nil then validate(value[key], field, path .. "." .. key) end
    end
  elseif kind == "array" then
    if type(value) ~= "table" then error(path .. " must be an array") end
    if schema.minItems and #value < schema.minItems then error(path .. " is too short") end
    if schema.maxItems and #value > schema.maxItems then error(path .. " is too long") end
    for key, item in pairs(value) do
      if type(key) ~= "number" or key < 1 or key > #value then error(path .. " must be an array") end
      if schema.items then validate(item, schema.items, path .. "[]") end
    end
  elseif kind == "number" or kind == "integer" then
    if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then error(path .. " must be finite") end
    if kind == "integer" and value % 1 ~= 0 then error(path .. " must be an integer") end
    if schema.minimum and value < schema.minimum then error(path .. " below minimum") end
    if schema.maximum and value > schema.maximum then error(path .. " above maximum") end
  elseif kind == "string" then
    if type(value) ~= "string" then error(path .. " must be text") end
    if schema.minLength and #value < schema.minLength then error(path .. " is too short") end
    if schema.maxLength and #value > schema.maxLength then error(path .. " is too long") end
  elseif kind == "boolean" and type(value) ~= "boolean" then error(path .. " must be boolean") end
  if schema.enum then
    local found = false
    for _, option in ipairs(schema.enum) do if value == option then found = true end end
    if not found then error(path .. " has an unsupported value") end
  end
end

function M.call(tool, args, player)
  return u.capture_response(function()
    u.safe_command(function()
      local definition, handler = contract[tool], u.handlers[tool]
      if not definition or definition.execution ~= "game" or not handler then error("Unknown tool: " .. tostring(tool)) end
      args = args or {}
      validate(args, definition.inputSchema, tool)
      for _, before in ipairs(definition.before or {}) do
        if before == "companion_stop" then lifecycle.stop(args.companionId) end
      end
      handler(args, player)
    end)
  end)
end

commands.add_command("fac_api", "AI Companion structured API", function(cmd)
  u.safe_command(function()
    local request = helpers.json_to_table(cmd.parameter or "")
    if type(request) ~= "table" or type(request.tool) ~= "string" then error("Expected {tool,args}") end
    u.json_response(M.call(request.tool, request.args))
  end)
end)

for name, definition in pairs(contract) do
  if definition.execution == "game" and not u.handlers[name] then error("Missing command handler: " .. name) end
end

return M
