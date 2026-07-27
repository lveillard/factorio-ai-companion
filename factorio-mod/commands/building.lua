-- AI Companion v0.9.0 - Building commands
local u = require("commands.init")
local queues = require("commands.queues")

commands.add_command("fac_building_can_place", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)%s+(%S+)%s+([%d.-]+)%s+([%d.-]+)%s*(%d*)$", cmd.parameter)
    local id, c = u.find_companion(args[1])
    if not id then u.not_found(); return end
    local name, x, y = args[2], tonumber(args[3]), tonumber(args[4])
    local dir = u.dir_map[tonumber(args[5]) or 0] or defines.direction.north
    if not x or not y then u.error_response("Invalid coordinates"); return end
    local dist = u.distance(c.entity.position, {x=x, y=y})
    if dist > (c.entity.reach_distance or 10) then u.json_response({id = id, can_place = false, reason = "Too far"}); return end
    local inv = c.entity.get_inventory(defines.inventory.character_main)
    if inv.get_item_count(name) == 0 then u.json_response({id = id, can_place = false, reason = "Not in inventory"}); return end
    local can = c.entity.surface.can_place_entity{name = name, position = {x=x, y=y}, direction = dir, force = c.entity.force}
    u.json_response({id = id, can_place = can, entity = name})
  end)
end)

commands.add_command("fac_building_place", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)%s+(%S+)%s+([%d.-]+)%s+([%d.-]+)%s*(%d*)$", cmd.parameter)
    local id, c = u.find_companion(args[1])
    if not id then u.not_found(); return end
    local name, x, y = args[2], tonumber(args[3]), tonumber(args[4])
    local dir = u.dir_map[tonumber(args[5]) or 0] or defines.direction.north
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
      -- CLEAR RETRY LOOP (2026-07-27, live-caught via a discard-investigation-pause:
      -- an iron output-inserter's own chest kept failing "Cannot place" at candidates
      -- immediately next to the SAME furnace this task is trying to give an output tap
      -- to -- confirmed live via RCON that a lying item-entity (iron-plate x1) sat
      -- almost exactly on the target tile every time. Root cause: this furnace's
      -- OWN output has nowhere to go yet (that IS the output-inserter this task is
      -- building) and has been overflowing/spilling loose plates onto the ground
      -- around itself for a while -- a single clear-then-check pass can lose a race
      -- against continued spillage (a new item can land in the exact same spot again
      -- between the pick-up loop and the final can_place_entity check, since the
      -- furnace keeps overflowing every tick it isn't collected). Retrying the whole
      -- clear+check cycle a few times (bounded, cheap -- no sleep, just repeated
      -- server-tick-instant checks) rides out a few ticks of continued overflow
      -- instead of giving up after the very first attempt.
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

commands.add_command("fac_building_remove", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)%s+(%S+)%s+([%d.-]+)%s+([%d.-]+)$", cmd.parameter)
    local id, c = u.find_companion(args[1])
    if not id then u.not_found(); return end
    local name, x, y = args[2], tonumber(args[3]), tonumber(args[4])
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

commands.add_command("fac_building_rotate", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)%s+([%d.-]+)%s+([%d.-]+)%s*(%d*)$", cmd.parameter)
    local id, c = u.find_companion(args[1])
    if not id then u.not_found(); return end
    local x, y, dir = tonumber(args[2]), tonumber(args[3]), tonumber(args[4])
    if not x or not y then u.error_response("Invalid coordinates"); return end
    -- Same nearest-not-first tie-break fix as fac_inserter_set_filter below (found while
    -- fixing that one, 2026-07-04): a bare [1]/first-match pick over a radius=1 query can
    -- land on the wrong entity when several rotatable things are packed tightly together.
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

commands.add_command("fac_building_info", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)%s+([%d.-]+)%s+([%d.-]+)$", cmd.parameter)
    local id, c = u.find_companion(args[1])
    if not id then u.not_found(); return end
    local x, y = tonumber(args[2]), tonumber(args[3])
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

commands.add_command("fac_building_recipe", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)%s+(%S+)%s+([%d.-]+)%s+([%d.-]+)$", cmd.parameter)
    local id, c = u.find_companion(args[1])
    if not id then u.not_found(); return end
    local recipe, x, y = args[2], tonumber(args[3]), tonumber(args[4])
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

commands.add_command("fac_building_fuel", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)%s+(%S+)%s*(%d*)$", cmd.parameter)
    local id, c = u.find_companion(args[1])
    if not id then u.not_found(); return end
    local fuel, amount = args[2], tonumber(args[3]) or 5
    local inv = c.entity.get_inventory(defines.inventory.character_main)
    local have = inv.get_item_count(fuel)
    if have == 0 then u.json_response({id = id, error = "No " .. fuel}); return end
    -- radius 3->6 (2026-07-27, Zdendys: "oprav to hlaseni!" after "drill fuel failed
    -- (No burner nearby)" kept recurring even right after a successful go_to() to the
    -- drill): this search is centered on the COMPANION's position, but go_to()'s own
    -- "arrived" is looser than that -- WALK_TARGET_WALKABLE_RADIUS (control.lua) can
    -- retarget the walk target up to 3 tiles away from an unwalkable drill-center
    -- position (which every drill's own build position always is), and normal arrival
    -- itself only requires dist<2 from that (possibly already-corrected) target. So the
    -- companion can legitimately end up ~5 tiles from the drill entity it just
    -- "successfully" walked to, well past the old radius=3. Widened to 6 to cover that
    -- common case; fueling any other genuinely-nearby burner this catches is harmless
    -- by design (see the "fuel EVERY nearby burner" comment below).
    local es = c.entity.surface.find_entities_filtered{position = c.entity.position, radius = 6, type = {"furnace", "boiler", "burner-inserter", "car", "locomotive", "mining-drill"}}
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

commands.add_command("fac_building_empty", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)%s+(%S+)%s*(%d*)%s*([%d.-]*)%s*([%d.-]*)$", cmd.parameter)
    local id, c = u.find_companion(args[1])
    if not id then u.not_found(); return end
    local item, count = args[2], tonumber(args[3]) or 10
    local pos = (tonumber(args[4]) and tonumber(args[5])) and {x = tonumber(args[4]), y = tonumber(args[5])} or c.entity.position
    if u.distance(c.entity.position, pos) > (c.entity.reach_distance or 10) then
      u.json_response({id = id, error = "Too far"}); return   -- must be in reach to extract (no action-at-a-distance)
    end
    -- Extract ONLY from the entity CLOSEST to the target tile (not any in radius): in a
    -- tight furnace row, collecting from the wrong furnace mismatches the fed one.
    -- e.type ~= "resource" excludes raw ore/stone/coal patches -- live-caught 2026-07-04:
    -- a chest/furnace placed adjacent to its own ore patch sits EXACTLY as close to `pos`
    -- as the underlying resource tile (both d2=0.5 on integer-aligned placement), and the
    -- resource entity (no inventory, always extracted=0) would silently win the tie
    -- whenever Factorio's entity enumeration order happened to list it first --
    -- non-deterministic flaky "extracted=0" despite the target container being full.
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
      -- defines.inventory.fuel added so surplus can be collected from a self-fueling burner
      -- (e.g. a coal-drill pair, [[coal_drill_self_fueling]]) -- caller is responsible for
      -- requesting less than the full amount so the burner keeps a running buffer.
      -- NOTE: defines.inventory.furnace_result/furnace_source are STALE 1.x names, removed
      -- in Factorio 2.0's inventory unification -- they are nil here, and indexing
      -- get_inventory(nil) THROWS (not returns nil), which used to abort this whole loop
      -- before ever reaching `fuel` unless chest/crafter_output alone already satisfied the
      -- request. crafter_output already covers furnace output in 2.0+, so no replacement
      -- entry is needed for the removed furnace_result.
      for _, it in ipairs({defines.inventory.chest, defines.inventory.crafter_output,
                           defines.inventory.fuel}) do
        local inv = target.get_inventory(it)
        if inv then
          local av = inv.get_item_count(item)
          if av > 0 then
            local rm = inv.remove{name = item, count = math.min(count - ext, av)}
            if rm > 0 then
              -- insert()'s own return value MUST be used, not assumed to equal
              -- `rm` (2026-07-18, same finding independently confirmed for
              -- task_pool.lua's pull_from_nearby_container, which mirrors this
              -- function's own idiom): a full companion inventory would
              -- otherwise silently lose the un-placed remainder (already
              -- removed here, never actually held) and over-report `extracted`
              -- to the caller. Put back whatever didn't fit.
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

-- ORE-MIXUP FOLLOW-UP FIX (2026-07-19, approved-fixes item 2 -- Zdendys): a furnace's
-- output slot can end up holding a DIFFERENT item than what it's currently smelting --
-- e.g. a drill mining the wrong ore for a while (the now-separately-fixed straddling-
-- footprint bug), or the companion hand-feeding it the wrong raw material -- and once
-- that happens, the furnace can't produce anything further (its single output slot is
-- occupied) no matter what correct ore arrives afterward. fac_building_empty above
-- only ever extracts a SPECIFIC named item, so a caller that only ever asks for the
-- EXPECTED plate type has no way to notice or clear a wrong-item jam. This command is
-- the dedicated "make this furnace work again" action: whatever is actually sitting in
-- crafter_output, if it ISN'T the expected item, evacuate it into the companion's
-- inventory regardless of what it is -- Zdendys: in this game phase an occasional
-- "wrong" plate landing in inventory is fine (gets used soon), the only goal is getting
-- it OUT of the furnace so smelting can resume.
commands.add_command("fac_building_clear_wrong_output", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)%s+(%S+)%s+([%d.-]+)%s+([%d.-]+)$", cmd.parameter)
    local id, c = u.find_companion(args[1])
    if not id then u.not_found(); return end
    local expected_item, x, y = args[2], tonumber(args[3]), tonumber(args[4])
    if not x or not y then u.error_response("Invalid coordinates"); return end
    local pos = {x = x, y = y}
    if u.distance(c.entity.position, pos) > (c.entity.reach_distance or 10) then
      u.json_response({id = id, error = "Too far"}); return
    end
    -- Same closest-entity-to-target-tile lookup as fac_building_empty above (same
    -- resource-tile tie-break rationale -- see that command's own comment).
    local es = c.entity.surface.find_entities_filtered{position = pos, radius = 5}
    local target, bd = nil, 1e18
    for _, e in ipairs(es) do
      if e.valid and e ~= c.entity and e.type ~= "resource" then
        local dx, dy = e.position.x - pos.x, e.position.y - pos.y
        local d = dx * dx + dy * dy
        if d < bd then bd, target = d, e end
      end
    end
    if not target then u.json_response({id = id, cleared = false, error = "Not found"}); return end
    local inv = target.get_inventory(defines.inventory.crafter_output)
    if not inv then u.json_response({id = id, cleared = false, error = "No output inventory"}); return end
    local contents = inv.get_contents()
    for _, stack in ipairs(contents) do
      if stack.name ~= expected_item then
        local rm = inv.remove{name = stack.name, count = stack.count, quality = stack.quality}
        if rm > 0 then
          -- insert()'s own return value MUST be used, not assumed to equal `rm` --
          -- same fix class as fac_building_empty above (2026-07-18 finding).
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

commands.add_command("fac_building_fill", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)%s+(%S+)%s*(%d*)%s*([%d.-]*)%s*([%d.-]*)$", cmd.parameter)
    local id, c = u.find_companion(args[1])
    if not id then u.not_found(); return end
    local item, count = args[2], tonumber(args[3]) or 10
    local pos = (tonumber(args[4]) and tonumber(args[5])) and {x = tonumber(args[4]), y = tonumber(args[5])} or c.entity.position
    if u.distance(c.entity.position, pos) > (c.entity.reach_distance or 10) then
      u.json_response({id = id, error = "Too far"}); return   -- must be in reach to load a machine
    end
    local inv = c.entity.get_inventory(defines.inventory.character_main)
    local have = inv.get_item_count(item)
    if have == 0 then u.json_response({id = id, error = "No " .. item}); return end
    -- Insert ONLY into the entity CLOSEST to the target tile, not the first in radius:
    -- in a tight furnace row several furnaces are within radius, and feeding the wrong
    -- one breaks parallel smelting (observed: copper-ore fed an iron furnace -> 0 copper).
    -- e.type ~= "resource" excludes raw ore/stone/coal patches -- same tie-break bug as
    -- fac_building_empty above (a resource tile can be exactly as close to `pos` as the
    -- real target, and would win the tie non-deterministically otherwise).
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
commands.add_command("fac_mine_entity", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)%s+([%d.-]+)%s+([%d.-]+)$", cmd.parameter)
    local id, c = u.find_companion(args[1])
    if not id then u.not_found(); return end
    local x, y = tonumber(args[2]), tonumber(args[3])
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
    -- NATIVE mining (real game mechanic): mine{} yields the entity's products (tree->wood,
    -- rock->stone, building->its item) AND its inventory contents into the companion inventory, then
    -- removes the entity -- exactly like hand-mining. If the companion inventory can't hold the
    -- result, mine{} returns false and the entity is LEFT INTACT: no silent item loss, no
    -- destroy-without-return, no fabricating items. (Never bypass game mechanics -- no cheating.)
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

commands.add_command("fac_building_place_start", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)%s+(%S+)%s+(%-?%d+%.?%d*)%s+(%-?%d+%.?%d*)%s*(%S*)$", cmd.parameter)
    local id, c = u.find_companion(args[1])
    if not id then u.not_found(); return end
    -- Task-pool-ownership guard at the DIRECT command entry point (2026-07-08, task
    -- #42) -- NOT inside queues.start_build itself, which task_pool.lua's own "place"
    -- step also calls internally WHILE active_step[id] is legitimately set for that
    -- very call; guarding inside start_build would reject the task pool's own use.
    -- This only blocks an EXTERNAL (direct Python) build request from hijacking a
    -- companion the task pool currently owns, mirroring fac_move_to's guard.
    if storage.active_step and storage.active_step[id] then
      u.error_response("companion busy with an active task-pool step")
      return
    end
    local entity = args[2]
    local x, y = tonumber(args[3]), tonumber(args[4])
    local dir = args[5] ~= "" and defines.direction[args[5]] or defines.direction.north
    local result = queues.start_build(id, entity, {x = x, y = y}, dir)
    result.id = id
    u.json_response(result)
  end)
end)

commands.add_command("fac_building_place_status", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)$", cmd.parameter)
    local id = u.find_companion(args[1])
    if not id then u.not_found(); return end
    local status = queues.get_build_status(id)
    -- id passed as 2nd arg (2026-07-05): free queue-status attachment, see init.lua.
    u.json_response({id = id, status = status}, id)
  end)
end)

-- fac_inserter_set_filter <cid> <x> <y> <item_name> -- 2026-07-04, belt/inserter
-- automation plan Stage 0.1. Wraps LuaEntity.set_filter/get_filter (generalized in
-- 2.1 to a table-valued {name=, quality=, comparator=} ItemFilter, not a bare string --
-- confirmed live via scripts/probe_inserter_filter_capability.py, PASS: burner-inserter
-- reports filter_slot_count=5 and accepts set_filter(1, item_name) with a plain string).
-- Read back via get_filter to confirm the filter actually stuck (mirrors
-- fac_building_rotate's read-back style), not just that the pcall didn't error.
commands.add_command("fac_inserter_set_filter", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)%s+([%d.-]+)%s+([%d.-]+)%s+(%S+)$", cmd.parameter)
    local id, c = u.find_companion(args[1])
    if not id then u.not_found(); return end
    local x, y, item = tonumber(args[2]), tonumber(args[3]), args[4]
    if not x or not y then u.error_response("Invalid coordinates"); return end
    -- Pick the NEAREST inserter to (x,y), not just find_entities_filtered's [1] (engine
    -- result order is not guaranteed nearest-first) -- a radius=1 query can overlap several
    -- 1x1 inserters packed in a tight row, silently configuring the wrong one (cubic dev ai
    -- bot, 2026-07-04: same tie-break class already fixed in fac_building_empty/_fill below).
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

-- fac_belt_connect_start/<...>_status <cid> <from_x> <from_y> <to_x> <to_y> -- 2026-07-04,
-- belt/inserter automation plan Stage 0.2. See queues.lua's belt-connect section for the
-- full design rationale (model=WHAT, mod=HOW routing; narrower than the original plan
-- sketch -- no material/inserter placement here, see that comment block). Async like
-- fac_building_place_start/_status: mirrors that exact start+poll pattern.
commands.add_command("fac_belt_connect_start", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)%s+([%d.-]+)%s+([%d.-]+)%s+([%d.-]+)%s+([%d.-]+)$", cmd.parameter)
    local id, c = u.find_companion(args[1])
    if not id then u.not_found(); return end
    local fx, fy, tx, ty = tonumber(args[2]), tonumber(args[3]), tonumber(args[4]), tonumber(args[5])
    if not (fx and fy and tx and ty) then u.error_response("Invalid coordinates"); return end
    local result = queues.start_belt_connect(id, {x = fx, y = fy}, {x = tx, y = ty})
    result.id = id
    u.json_response(result)
  end)
end)

commands.add_command("fac_belt_connect_status", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)$", cmd.parameter)
    local id = u.find_companion(args[1])
    if not id then u.not_found(); return end
    local status = queues.get_belt_connect_status(id)
    status.id = id
    -- id passed as 2nd arg (2026-07-05): free queue-status attachment, see init.lua.
    u.json_response(status, id)
  end)
end)
