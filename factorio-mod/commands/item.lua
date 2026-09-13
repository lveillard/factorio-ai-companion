-- AI Companion v0.9.0 - Item commands
local u = require("commands.init")
local queues = require("commands.queues")

commands.add_command("fac_item_craft", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)%s+(%S+)%s*(%d*)$", cmd.parameter)
    local id, c = u.find_companion(args[1])
    if not id then u.not_found(); return end
    local item, count = args[2], tonumber(args[3]) or 1
    local recipe = c.entity.force.recipes[item]
    if not recipe then u.json_response({id = id, error = "Recipe not found"}); return end
    if not recipe.enabled then u.json_response({id = id, error = "Not unlocked"}); return end
    if c.entity.get_craftable_count(recipe) < count then
      local missing = {}
      local inv = c.entity.get_inventory(defines.inventory.character_main)
      for _, ing in ipairs(recipe.ingredients) do
        local have, need = inv.get_item_count(ing.name), ing.amount * count
        if have < need then missing[#missing + 1] = {name = ing.name, have = have, need = need} end
      end
      u.json_response({id = id, error = "Missing", missing = missing}); return
    end
    local crafted = c.entity.begin_crafting{recipe = item, count = count}
    -- headless: the companion's craft does not fire craft-item research triggers ->
    -- compensate (e.g. crafting a lab unlocks the automation-science-pack recipe).
    u.fire_craft_triggers(c.entity.force, item, crafted)
    u.json_response({id = id, crafted = crafted, item = item})
  end)
end)

commands.add_command("fac_item_pick", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)%s*(%S*)%s*(%d*)$", cmd.parameter)
    local id, c = u.find_companion(args[1])
    if not id then u.not_found(); return end
    local filter = args[2] ~= "" and args[2] or nil
    local radius = tonumber(args[3]) or 5
    local items = c.entity.surface.find_entities_filtered{type = "item-entity", position = c.entity.position, radius = radius}
    local picked = {}
    for _, item in ipairs(items) do
      if item.valid and (not filter or item.stack.name == filter) then
        local ins = c.entity.insert(item.stack)
        if ins > 0 then
          picked[#picked + 1] = {name = item.stack.name, count = ins}
          if ins >= item.stack.count then item.destroy() else item.stack.count = item.stack.count - ins end
        end
      end
    end
    u.json_response({id = id, picked = picked})
  end)
end)

commands.add_command("fac_item_recipes", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)%s*(%S*)$", cmd.parameter)
    local id, c = u.find_companion(args[1])
    if not id then u.not_found(); return end
    local filter = args[2]
    local result = {}
    for name, recipe in pairs(c.entity.force.recipes) do
      if recipe.enabled then
        local inc = true
        if filter == "active" then inc = c.entity.get_craftable_count(recipe) >= 1
        elseif filter and filter ~= "" then inc = name:find(filter, 1, true) end
        if inc then
          local ings = {}
          for _, ing in ipairs(recipe.ingredients) do ings[#ings + 1] = {name = ing.name, amount = ing.amount} end
          result[#result + 1] = {name = name, ingredients = ings, can_craft = c.entity.get_craftable_count(recipe) >= 1}
        end
      end
    end
    if #result > 50 then local t = {}; for i = 1, 50 do t[i] = result[i] end; result = t end
    u.json_response({id = id, recipes = result, count = #result})
  end)
end)

-- Realistic tick-based crafting
commands.add_command("fac_item_craft_start", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)%s+(%S+)%s*(%d*)$", cmd.parameter)
    local id, c = u.find_companion(args[1])
    if not id then u.not_found(); return end
    local recipe = args[2]
    local count = tonumber(args[3]) or 1
    local result = queues.start_craft(id, recipe, count)
    result.id = id
    u.json_response(result)
  end)
end)

commands.add_command("fac_item_craft_status", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)$", cmd.parameter)
    local id = u.find_companion(args[1])
    if not id then u.not_found(); return end
    local status = queues.get_craft_status(id)
    -- id passed as 2nd arg (2026-07-05): free queue-status attachment, see init.lua.
    u.json_response({id = id, status = status}, id)
  end)
end)

commands.add_command("fac_item_craft_stop", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)$", cmd.parameter)
    local id = u.find_companion(args[1])
    if not id then u.not_found(); return end
    local result = queues.stop_craft(id)
    u.json_response({id = id, stopped = result.stopped, crafted = result.crafted or 0})
  end)
end)
