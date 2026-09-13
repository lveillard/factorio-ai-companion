local u = require("commands.init")
local M = {}
local statuses, directions = {}, {}
for name, value in pairs(defines.entity_status) do statuses[value] = name end
for name, value in pairs(defines.direction) do directions[value] = name end
local function position(p) return p and {x=p.x, y=p.y} or nil end
local function target(e)
  return e and e.valid and {name=e.name, type=e.type, position=position(e.position)} or nil
end

-- Shared by world_observe and building_info. LuaEntity exposes methods even when the
-- entity's native class cannot use them; inventory indices also alias across classes.
function M.describe(e, detailed)
  local result = {name=e.name, type=e.type, position=position(e.position), direction=e.direction,
    facing=directions[e.direction], force=e.force.name, health=e.health, max_health=e.max_health,
    status=statuses[e.status]}
  if e.type == "resource" then result.amount = e.amount end
  if not detailed or e.force.name == "neutral" then return result end
  local capabilities = u.settings.entity_capabilities[e.type] or {}
  result.fuel = u.inventory_contents(e.get_fuel_inventory())
  result.energy = e.energy
  if capabilities.crafting then
    result.input = u.inventory_contents(e.get_inventory(defines.inventory.crafter_input))
    result.output = u.inventory_contents(e.get_output_inventory())
    local recipe = e.get_recipe()
    result.recipe = recipe and recipe.name
    result.crafting_progress = e.crafting_progress
    result.products_finished = e.products_finished
  end
  if capabilities.inventory then
    result.inventory = u.inventory_contents(e.get_inventory(defines.inventory[capabilities.inventory]))
  end
  if capabilities.mining then
    result.mining_target = target(e.mining_target)
    result.mining_progress = e.mining_progress
  end
  if capabilities.drop then
    result.drop_position = position(e.drop_position)
    result.drop_target = target(e.drop_target)
  end
  if capabilities.inserter then
    result.pickup_position = position(e.pickup_position)
    local stack = e.held_stack
    if stack and stack.valid_for_read then
      result.held_stack = {name=stack.name, count=stack.count, quality=stack.quality.name}
    end
  end
  return result
end

return M
