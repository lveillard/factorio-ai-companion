local u = require("commands.init")
local queues = require("commands.queues")
local capabilities = require("commands.capabilities")

local M = {}

local ENSURE_ITEM_MAX_DEPTH = u.settings.task_tuning.ensure_item_max_depth
local ENSURE_ITEM_GATHER_MAX_ATTEMPTS = u.settings.task_tuning.ensure_item_gather_max_attempts
local ENSURE_ITEM_CONTAINER_SEARCH_RADIUS = u.settings.task_tuning.ensure_item_container_search_radius
local SMELT_WAIT_TICKS = u.settings.task_tuning.smelt_wait_ticks
local ENSURE_ITEM_FURNACE_SEARCH_RADIUS = u.settings.task_tuning.ensure_item_furnace_search_radius

local function resolve_recipe(entity, item)
  local r = prototypes.recipe[item]
  local name = item
  if not r then
    local names = {}
    for recipe_name, recipe in pairs(entity.force.recipes) do
      if recipe.enabled then
        for _, product in ipairs(recipe.products) do
          if product.type == "item" and product.name == item then names[#names+1] = recipe_name; break end
        end
      end
    end
    table.sort(names)
    name = names[1]
    r = name and prototypes.recipe[name]
  end
  if not r then return nil end
  local ingredients = {}
  for _, x in ipairs(r.ingredients) do
    ingredients[#ingredients + 1] = {name = x.name, amount = x.amount}
  end
  local yield = 1
  for _, p in ipairs(r.products) do
    if p.name == item then yield = p.amount or p.amount_min or 1; break end
  end
  return {name=name, ingredients = ingredients, yield = yield, hand_craftable = not capabilities.craft_error(entity,name)}
end

local function pull_nearby(c, item, deficit, output)
  local types = output and {"furnace", "assembling-machine"} or {"container", "logistic-container"}
  local radius = output and ENSURE_ITEM_FURNACE_SEARCH_RADIUS or ENSURE_ITEM_CONTAINER_SEARCH_RADIUS
  local candidates = c.entity.surface.find_entities_filtered{position=c.entity.position, radius=radius, type=types}
  table.sort(candidates, function(a,b) return u.distance(a.position,c.entity.position) < u.distance(b.position,c.entity.position) end)
  local collected, producing = 0, false
  for _, target in ipairs(candidates) do
    if target.valid then
      local inv = output and target.get_output_inventory() or target.get_inventory(defines.inventory.chest)
      if inv then
        for _, stack in ipairs(u.inventory_contents(inv)) do
          if stack.name == item and collected < deficit then
            local removed = inv.remove{name=item, count=math.min(deficit-collected,stack.count), quality=stack.quality}
            local inserted = c.entity.insert{name=item, count=removed, quality=stack.quality}
            if inserted < removed then inv.insert{name=item, count=removed-inserted, quality=stack.quality} end
            collected = collected + inserted
          end
        end
      end
      if output then
        local recipe = target.get_recipe()
        for _, product in ipairs(recipe and recipe.products or {}) do
          if product.name == item then producing = true end
        end
      end
    end
  end
  return collected, producing
end

function M.start_ensure_item_action(c, cid, t)
  local stack = t.ctx.ensure_stack
  local need = stack[#stack]
  if type(need.item) ~= "string" or type(need.count) ~= "number" then
    return nil, "ensure_item: step.item (string) and step.count (number) required"
  end
  local inv = c.entity.get_main_inventory()
  if inv.get_item_count(need.item) >= need.count then
    return "satisfied"
  end
  if #stack > ENSURE_ITEM_MAX_DEPTH then
    return nil, "ensure_item recursion depth exceeded for " .. need.item ..
      " (likely a recipe-chain or naming problem, not a normal case)"
  end
  local recipe = resolve_recipe(c.entity, need.item)
  if not recipe then
    local deficit = need.count - inv.get_item_count(need.item)
    local pulled = pull_nearby(c, need.item, deficit, false)
    if pulled > 0 then
      deficit = deficit - pulled
    end
    if deficit <= 0 then
      return "satisfied"
    end
    t.ctx.gather_attempts = t.ctx.gather_attempts or {}
    t.ctx.gather_attempts[need.item] = (t.ctx.gather_attempts[need.item] or 0) + 1
    if t.ctx.gather_attempts[need.item] > ENSURE_ITEM_GATHER_MAX_ATTEMPTS then
      return nil, "could not gather enough " .. need.item .. " after " ..
        ENSURE_ITEM_GATHER_MAX_ATTEMPTS .. " attempts (likely scarce/unreachable)"
    end
    local r = queues.start_gather(cid, need.item, deficit, nil, true)
    if r.error then return nil, r.error end
    return "gather"
  end
  if not recipe.hand_craftable then
    local pulled, producing = pull_nearby(c, need.item,
      need.count - inv.get_item_count(need.item), true)
    if pulled > 0 and inv.get_item_count(need.item) >= need.count then
      return "satisfied"
    end
    if not producing then return nil, "No nearby machine producing " .. need.item end
    t.ctx.smelt_wait_deadline = t.ctx.smelt_wait_deadline or {}
    local deadline = t.ctx.smelt_wait_deadline[need.item]
    if not deadline then
      deadline = game.tick + SMELT_WAIT_TICKS
      t.ctx.smelt_wait_deadline[need.item] = deadline
    end
    if game.tick < deadline then
      return "wait"
    end
    return nil, need.item .. " recipe is not hand-craftable and no furnace produced " ..
      "enough within " .. SMELT_WAIT_TICKS .. " ticks (needs a real machine, e.g. smelting)"
  end
  for _, ing in ipairs(recipe.ingredients) do
    local needed_amount = math.ceil((need.count - inv.get_item_count(need.item)) / recipe.yield) * ing.amount
    if inv.get_item_count(ing.name) < needed_amount then
      stack[#stack + 1] = {item = ing.name, count = needed_amount}
      return "push"
    end
  end
  local craft_count = math.ceil((need.count - inv.get_item_count(need.item)) / recipe.yield)
  local r = queues.start_craft(cid, recipe.name, craft_count)
  if r.error then return nil, r.error end
  return "craft"
end

return M
