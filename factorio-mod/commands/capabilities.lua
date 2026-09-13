local u = require("commands.init")
local M = {}

function M.craft_error(entity, name)
  local recipe = prototypes.recipe[name]
  if not recipe then return "Unknown recipe: " .. name end
  local unlocked = entity.force.recipes[name]
  if not unlocked or not unlocked.enabled then return "Recipe is locked: " .. name end
  if not (entity.prototype.crafting_categories or {})[recipe.category] then
    return "Recipe is not hand-craftable; needs a machine for category " .. recipe.category
  end
  for _, ingredient in ipairs(recipe.ingredients) do
    if ingredient.type == "fluid" then return "Recipe requires fluids and a machine: " .. name end
  end
end

function M.robots(entity, position)
  local networks = entity.surface.find_logistic_networks_by_construction_area(position or entity.position, entity.force)
  local total, available = 0, 0
  for _, network in ipairs(networks) do
    total = total + network.all_construction_robots
    available = available + network.available_construction_robots
  end
  return {covered=#networks > 0, total=total, available=available}
end

function M.describe(entity)
  local categories = {}
  for name in pairs(entity.prototype.crafting_categories or {}) do categories[#categories+1] = name end
  table.sort(categories)
  return {hand_crafting=categories, build_distance=entity.build_distance, reach_distance=entity.reach_distance,
    construction_robots=M.robots(entity), manual_build=true}
end

u.register("companion_capabilities", function(args)
  u.safe_command(function()
    local id,c = u.find_companion(args.companionId)
    if not id then u.not_found(); return end
    local result = M.describe(c.entity)
    result.id = id
    if args.recipe then
      local recipe = prototypes.recipe[args.recipe]
      if not recipe then u.error_response("Unknown recipe: " .. args.recipe); return end
      local error = M.craft_error(c.entity,args.recipe)
      result.recipe = {name=args.recipe, category=recipe.category, ingredients=recipe.ingredients,
        products=recipe.products, hand_craftable=not error, reason=error,
        craftable=not error and c.entity.get_craftable_count(args.recipe) or 0}
    end
    u.json_response(result)
  end)
end)

return M
