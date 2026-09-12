local u = require("commands.init")
local queues = require("commands.queues")

u.register("building_can_place", function(args)
  u.safe_command(function()
    local id, c = u.find_companion(args.companionId)
    if not id then u.not_found(); return end
    local name, x, y = args.entityName, tonumber(args.x), tonumber(args.y)
    local dir = u.dir_map[tonumber(args.direction) or 0] or defines.direction.north
    if not x or not y then u.error_response("Invalid coordinates"); return end
    local dist = u.distance(c.entity.position, {x=x, y=y})
    if dist > (c.entity.reach_distance or 10) then u.json_response({id = id, can_place = false, reason = "Too far"}); return end
    local inv = c.entity.get_inventory(defines.inventory.character_main)
    if inv.get_item_count(name) == 0 then u.json_response({id = id, can_place = false, reason = "Not in inventory"}); return end
    local can = c.entity.surface.can_place_entity{name = name, position = {x=x, y=y}, direction = dir, force = c.entity.force}
    u.json_response({id = id, can_place = can, entity = name})
  end)
end)

u.register("building_place", function(args)
  u.safe_command(function()
    local id, c = u.find_companion(args.companionId)
    if not id then u.not_found(); return end
    local name, x, y = args.entityName, tonumber(args.x), tonumber(args.y)
    local dir = u.dir_map[tonumber(args.direction) or 0] or defines.direction.north
    if not x or not y then u.error_response("Invalid coordinates"); return end
    local dist = u.distance(c.entity.position, {x=x, y=y})
    if dist > (c.entity.reach_distance or 10) then u.json_response({id = id, error = "Too far"}); return end
    local inv = c.entity.get_inventory(defines.inventory.character_main)
    if inv.get_item_count(name) == 0 then u.json_response({id = id, error = "Not in inventory"}); return end
    local surf = c.entity.surface
    -- Mod autonomously prepares the build site: step the companion off the footprint if it
    -- blocks, then CLEAR obstacles (trees, rocks, lying items) ONLY IF placement is still
    -- blocked -- so terrain isn't destroyed when placement would fail anyway (e.g. on water).
    local function can_here()
      return surf.can_place_entity{name = name, position = {x=x, y=y}, direction = dir, force = c.entity.force}
    end
    local proto = prototypes.entity[name]
    if proto and proto.collision_box then
      local bb = proto.collision_box
      local area = {
        {x = x + bb.left_top.x - 0.5, y = y + bb.left_top.y - 0.5},
        {x = x + bb.right_bottom.x + 0.5, y = y + bb.right_bottom.y + 0.5}
      }
      -- companion must not block its own build. A character cannot teleport, so REFUSE rather than
      -- warp aside: the caller (which walked here) must stand OFF the footprint before placing. The
      -- async build path already walks the companion clear via walking_state before placing.
      if c.entity.position.x >= area[1].x and c.entity.position.x <= area[2].x
         and c.entity.position.y >= area[1].y and c.entity.position.y <= area[2].y then
        u.json_response({id = id, error = "companion on build site -- move off first"}); return
      end
      for _clear_attempt = 1, 3 do
        if can_here() then break end   -- only clear when something actually blocks placement
        -- lying items: pick up the ACTUAL stack (preserves quality/count); keep if inv full
        for _, it in ipairs(surf.find_entities_filtered{area = area, type = "item-entity"}) do
          if it.valid and it.stack and it.stack.valid_for_read then
            local moved = c.entity.insert(it.stack)
            if moved >= it.stack.count then it.destroy() end
          end
        end
        -- trees / rocks (simple-entity) blocking the footprint: MINE them (wood/stone into the
        -- companion inventory), never free-destroy. If the inventory is full, mine{} leaves the
        -- obstacle intact -- placement then fails cleanly instead of magically clearing the map.
        for _, o in ipairs(surf.find_entities_filtered{area = area, type = {"tree", "simple-entity"}}) do
          if o.valid then o.mine{inventory = c.entity.get_main_inventory()} end
        end
      end
    end
    if not surf.can_place_entity{name = name, position = {x=x, y=y}, direction = dir, force = c.entity.force} then
      u.json_response({id = id, error = "Cannot place"}); return
    end
    local e = surf.create_entity{name = name, position = {x=x, y=y}, direction = dir, force = c.entity.force}
    if e then inv.remove{name = name, count = 1}; u.json_response({id = id, placed = true, entity = name})
    else u.json_response({id = id, error = "Failed"}) end
  end)
end)

u.register("building_remove", function(args)
  u.safe_command(function()
    local id, c = u.find_companion(args.companionId)
    if not id then u.not_found(); return end
    local name, x, y = args.entityName, tonumber(args.x), tonumber(args.y)
    if not x or not y then u.error_response("Invalid coordinates"); return end
    local es = c.entity.surface.find_entities_filtered{name = name, position = {x=x, y=y}, radius = 1, force = c.entity.force}
    if #es == 0 then u.json_response({id = id, error = "Not found"}); return end
    local t = es[1]
    if u.distance(c.entity.position, t.position) > 10 then u.json_response({id = id, error = "Too far"}); return end
    -- MINE the building (native): its real item + contents go into the companion inventory and the
    -- game removes it. Never fabricate the item + free-destroy (that minted an item from nothing and
    -- discarded the building's contents). If the inventory is full, mine{} leaves the building intact.
    local inv = c.entity.get_main_inventory()
    local before = inv.get_item_count()
    t.mine{inventory = inv}
    if t.valid and inv.get_item_count() == before then
      u.json_response({id = id, error = "Cannot remove (inventory full?)"})
    else
      u.json_response({id = id, removed = true, entity = name})
    end
  end)
end)

u.register("building_rotate", function(args)
  u.safe_command(function()
    local id, c = u.find_companion(args.companionId)
    if not id then u.not_found(); return end
    local x, y, dir = tonumber(args.x), tonumber(args.y), tonumber(args.direction)
    if not x or not y then u.error_response("Invalid coordinates"); return end
    local es = c.entity.surface.find_entities_filtered{position = {x=x, y=y}, radius = 1}
    local t, bd = nil, 1e18
    for _, e in ipairs(es) do
      if e.valid and e ~= c.entity and e.type ~= "character" and e.rotatable then
        local dx, dy = e.position.x - x, e.position.y - y
        local d = dx * dx + dy * dy
        if d < bd then bd, t = d, e end
      end
    end
    if not t then u.json_response({id = id, error = "No rotatable entity"}); return end
    if u.distance(c.entity.position, t.position) > (c.entity.reach_distance or 10) then
      u.json_response({id = id, error = "Too far"}); return   -- must be in reach to rotate (no action-at-a-distance)
    end
    if dir then
      t.direction = u.dir_map[dir] or defines.direction.north
    else
      t.rotate()
    end
    u.json_response({id = id, rotated = t.name, direction = t.direction})
  end)
end)

u.register("building_info", function(args)
  u.safe_command(function()
    local id, c = u.find_companion(args.companionId)
    if not id then u.not_found(); return end
    local x, y = tonumber(args.x), tonumber(args.y)
    if not x or not y then u.error_response("Invalid coordinates"); return end
    local es = c.entity.surface.find_entities_filtered{position = {x=x, y=y}, radius = 2}
    if #es == 0 then u.json_response({id = id, error = "Not found"}); return end
    local t, min = nil, math.huge
    for _, e in ipairs(es) do
      if e.valid and e ~= c.entity and e.type ~= "character" and e.type ~= "resource" and e.type ~= "item-entity" then
        local d = u.distance(e.position, {x=x, y=y}); if d < min then min, t = d, e end
      end
    end
    if not t then u.json_response({id = id, error = "Not found"}); return end
    local info = {name = t.name, type = t.type, position = {x = t.position.x, y = t.position.y}, direction = t.direction}
    if t.health then info.health = t.health end
    if t.energy then info.energy = t.energy end
    if t.get_recipe then local r = t.get_recipe(); if r then info.recipe = r.name end end
    u.json_response({id = id, entity = info})
  end)
end)

u.register("building_recipe", function(args)
  u.safe_command(function()
    local id, c = u.find_companion(args.companionId)
    if not id then u.not_found(); return end
    local recipe, x, y = args.recipe, tonumber(args.x), tonumber(args.y)
    if not x or not y then u.error_response("Invalid coordinates"); return end
    if u.distance(c.entity.position, {x=x, y=y}) > (c.entity.reach_distance or 10) then
      u.json_response({id = id, error = "Too far"}); return   -- must be in reach to set a recipe
    end
    local es = c.entity.surface.find_entities_filtered{position = {x=x, y=y}, radius = 1, type = "assembling-machine"}
    if #es == 0 then u.json_response({id = id, error = "No machine"}); return end
    if not c.entity.force.recipes[recipe] then u.json_response({id = id, error = "Recipe not found"}); return end
    es[1].set_recipe(recipe)
    u.json_response({id = id, set_recipe = true, recipe = recipe})
  end)
end)

u.register("building_fuel", function(args)
  u.safe_command(function()
    local id, c = u.find_companion(args.companionId)
    if not id then u.not_found(); return end
    local fuel, amount = args.fuelName, tonumber(args.count) or 5
    local inv = c.entity.get_inventory(defines.inventory.character_main)
    local have = inv.get_item_count(fuel)
    if have == 0 then u.json_response({id = id, error = "No " .. fuel}); return end
    local es = c.entity.surface.find_entities_filtered{position = c.entity.position, radius = u.settings.task_tuning.fuel_reach, type = {"furnace", "boiler", "inserter", "car", "locomotive", "mining-drill"}}
    if #es == 0 then u.json_response({id = id, error = "No burner nearby"}); return end
    -- Fuel EVERY nearby burner (not just es[1], whose order is arbitrary): in a tight
    -- furnace row, fueling only the first leaves the others starved -> they stop smelting
    -- and their input fills up (observed: copper furnace unfueled -> copper-ore stuck).
    local ins = 0
    for _, e in ipairs(es) do
      if have - ins <= 0 then break end
      local fi = e.get_fuel_inventory()
      if fi then
        local r = fi.insert{name = fuel, count = math.min(amount, have - ins)}
        if r > 0 then ins = ins + r end
      end
    end
    if ins > 0 then inv.remove{name = fuel, count = ins}; u.json_response({id = id, inserted = ins, fuel = fuel})
    else u.json_response({id = id, error = "Full"}) end
  end)
end)

u.register("building_empty", function(args)
  u.safe_command(function()
    local id, c = u.find_companion(args.companionId)
    if not id then u.not_found(); return end
    local item, count = args.itemName, tonumber(args.count) or 10
    local pos = (tonumber(args.x) and tonumber(args.y)) and {x = tonumber(args.x), y = tonumber(args.y)} or c.entity.position
    if u.distance(c.entity.position, pos) > (c.entity.reach_distance or 10) then
      u.json_response({id = id, error = "Too far"}); return   -- must be in reach to extract (no action-at-a-distance)
    end
    local es = c.entity.surface.find_entities_filtered{position = pos, radius = 5}
    local target, bd = nil, 1e18
    for _, e in ipairs(es) do
      if e.valid and e ~= c.entity and e.type ~= "resource" then
        local dx, dy = e.position.x - pos.x, e.position.y - pos.y
        local d = dx * dx + dy * dy
        if d < bd then bd, target = d, e end
      end
    end
    local ext = 0
    if target then
      for _, it in ipairs({defines.inventory.chest, defines.inventory.crafter_output,
                           defines.inventory.fuel}) do
        local inv = target.get_inventory(it)
        if inv then
          local av = inv.get_item_count(item)
          if av > 0 then
            local rm = inv.remove{name = item, count = math.min(count - ext, av)}
            if rm > 0 then
              local ins = c.entity.insert{name = item, count = rm}
              if ins < rm then inv.insert{name = item, count = rm - ins} end
              ext = ext + ins
            end
          end
        end
        if ext >= count then break end
      end
    end
    u.json_response({id = id, extracted = ext, item = item})
  end)
end)

u.register("building_clear_wrong_output", function(args)
  u.safe_command(function()
    local id, c = u.find_companion(args.companionId)
    if not id then u.not_found(); return end
    local expected_item, x, y = args.itemName, tonumber(args.x), tonumber(args.y)
    if not x or not y then u.error_response("Invalid coordinates"); return end
    local pos = {x = x, y = y}
    if u.distance(c.entity.position, pos) > (c.entity.reach_distance or 10) then
      u.json_response({id = id, error = "Too far"}); return
    end
    local es = c.entity.surface.find_entities_filtered{position = pos, radius = 1, type = {"furnace", "assembling-machine"}}
    local target, bd = nil, 1e18
    for _, e in ipairs(es) do
      if e.valid and e ~= c.entity and e.type ~= "resource" then
        local dx, dy = e.position.x - pos.x, e.position.y - pos.y
        local d = dx * dx + dy * dy
        if d < bd then bd, target = d, e end
      end
    end
    if not target then u.json_response({id = id, cleared = false, error = "Not found"}); return end
    local inv = target.get_output_inventory()
    if not inv then u.json_response({id = id, cleared = false, error = "No output inventory"}); return end
    local contents = u.inventory_contents(inv)
    for _, stack in ipairs(contents) do
      if stack.name ~= expected_item then
        local rm = inv.remove{name = stack.name, count = stack.count, quality = stack.quality}
        if rm > 0 then
          local ins = c.entity.insert{name = stack.name, count = rm, quality = stack.quality}
          if ins < rm then inv.insert{name = stack.name, count = rm - ins, quality = stack.quality} end
          if ins > 0 then
            u.json_response({id = id, cleared = true, item = stack.name, count = ins})
            return
          end
        end
      end
    end
    u.json_response({id = id, cleared = false})
  end)
end)

u.register("building_fill", function(args)
  u.safe_command(function()
    local id, c = u.find_companion(args.companionId)
    if not id then u.not_found(); return end
    local item, count = args.itemName, tonumber(args.count) or 10
    local pos = (tonumber(args.x) and tonumber(args.y)) and {x = tonumber(args.x), y = tonumber(args.y)} or c.entity.position
    if u.distance(c.entity.position, pos) > (c.entity.reach_distance or 10) then
      u.json_response({id = id, error = "Too far"}); return   -- must be in reach to load a machine
    end
    local inv = c.entity.get_inventory(defines.inventory.character_main)
    local have = inv.get_item_count(item)
    if have == 0 then u.json_response({id = id, error = "No " .. item}); return end
    local es = c.entity.surface.find_entities_filtered{position = pos, radius = 3}
    local target, bd = nil, 1e18
    for _, e in ipairs(es) do
      if e.valid and e ~= c.entity and e.type ~= "resource" then
        local dx, dy = e.position.x - pos.x, e.position.y - pos.y
        local d = dx * dx + dy * dy
        if d < bd then bd, target = d, e end
      end
    end
    local ins = 0
    if target then
      local r = target.insert{name = item, count = math.min(count, have)}
      if r > 0 then inv.remove{name = item, count = r}; ins = r end
    end
    if ins > 0 then u.json_response({id = id, inserted = ins, item = item, into = target and target.name})
    else u.json_response({id = id, error = "Could not insert"}) end
  end)
end)

-- Realistic tick-based building placement
-- Mine (destroy) any entity at position - works on crash site wrecks, decoratives, etc.
u.register("building_mine", function(args)
  u.safe_command(function()
    local id, c = u.find_companion(args.companionId)
    if not id then u.not_found(); return end
    local x, y = tonumber(args.x), tonumber(args.y)
    if not x or not y then u.error_response("Invalid coordinates"); return end
    local es = c.entity.surface.find_entities_filtered{position = {x=x, y=y}, radius = 3}
    local target, tmin = nil, math.huge   -- mine the NEAREST entity, not the first arbitrary one
    for _, e in ipairs(es) do
      if e.valid and e ~= c.entity and e.type ~= "character" and e.type ~= "resource" then
        local d = u.distance({x=x, y=y}, e.position)
        if d < tmin then tmin, target = d, e end
      end
    end
    if not target then u.json_response({id = id, error = "No entity found"}); return end
    if u.distance(c.entity.position, target.position) > 15 then u.json_response({id = id, error = "Too far"}); return end
    local entity_name = target.name
    local inv = c.entity.get_main_inventory()
    local before = inv.get_item_count()
    -- NATIVE mining: tree->wood, rock->stone, building->its item + contents, all into the inventory,
    -- then the game removes the entity. If the inventory can't hold the result, mine{} leaves the
    -- entity INTACT (no item loss, no destroy-without-return). The character MINES, never "destroys".
    target.mine{inventory = inv}
    local gained = inv.get_item_count() - before
    if target.valid and gained == 0 then
      u.json_response({id = id, error = "Could not mine (inventory full?)", entity = entity_name})
      return
    end
    u.json_response({id = id, mined = true, entity = entity_name, items_gained = gained})
  end)
end)

u.register("building_place_start", function(args)
  u.safe_command(function()
    local id, c = u.find_companion(args.companionId)
    if not id then u.not_found(); return end
    if storage.active_step and storage.active_step[id] then
      u.error_response("companion busy with an active task-pool step")
      return
    end
    local entity = args.entityName
    local x, y = tonumber(args.x), tonumber(args.y)
    local dir = args.direction ~= "" and defines.direction[args.direction] or defines.direction.north
    local result = queues.start_build(id, entity, {x = x, y = y}, dir)
    result.id = id
    u.json_response(result)
  end)
end)

u.register("building_place_status", function(args)
  u.safe_command(function()
    local id = u.find_companion(args.companionId)
    if not id then u.not_found(); return end
    local status = queues.get_build_status(id)
    u.json_response({id = id, status = status}, id)
  end)
end)

u.register("inserter_set_filter", function(args)
  u.safe_command(function()
    local id, c = u.find_companion(args.companionId)
    if not id then u.not_found(); return end
    local x, y, item = tonumber(args.x), tonumber(args.y), args.item
    if not x or not y then u.error_response("Invalid coordinates"); return end
    local es = c.entity.surface.find_entities_filtered{position = {x=x, y=y}, radius = 1, type = "inserter"}
    local t, bd = nil, 1e18
    for _, e in ipairs(es) do
      if e.valid then
        local dx, dy = e.position.x - x, e.position.y - y
        local d = dx * dx + dy * dy
        if d < bd then bd, t = d, e end
      end
    end
    if not t then u.json_response({id = id, error = "No inserter"}); return end
    if u.distance(c.entity.position, t.position) > (c.entity.reach_distance or 10) then
      u.json_response({id = id, error = "Too far"}); return
    end
    if (t.filter_slot_count or 0) < 1 then
      u.json_response({id = id, error = t.name .. " has no filter slots"}); return
    end
    local ok, err = pcall(function() t.set_filter(1, item) end)
    if not ok then u.json_response({id = id, error = "set_filter failed: " .. tostring(err)}); return end
    local f = t.get_filter(1)
    u.json_response({id = id, filtered = (f ~= nil and f.name == item), entity = t.name,
                      item = item, got = f and f.name or nil})
  end)
end)

u.register("belt_connect_start", function(args)
  u.safe_command(function()
    local id, c = u.find_companion(args.companionId)
    if not id then u.not_found(); return end
    local fx, fy, tx, ty = tonumber(args.fromX), tonumber(args.fromY), tonumber(args.toX), tonumber(args.toY)
    if not (fx and fy and tx and ty) then u.error_response("Invalid coordinates"); return end
    local result = queues.start_belt_connect(id, {x = fx, y = fy}, {x = tx, y = ty})
    result.id = id
    u.json_response(result)
  end)
end)

u.register("belt_connect_status", function(args)
  u.safe_command(function()
    local id = u.find_companion(args.companionId)
    if not id then u.not_found(); return end
    local status = queues.get_belt_connect_status(id)
    status.id = id
    u.json_response(status, id)
  end)
end)
