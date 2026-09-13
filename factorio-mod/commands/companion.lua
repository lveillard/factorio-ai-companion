local lifecycle = require("commands.lifecycle")
local u = require("commands.init")
local queues = require("commands.queues")
local entity_info = require("commands.entity_info")

u.register("companion_list", function(args)
  u.safe_command(function()
    local list = {}
    for id, c in pairs(storage.companions) do
      if c.entity and c.entity.valid then
        local pos = c.entity.position
        list[#list + 1] = {
          id = id,
          position = {x = math.floor(pos.x * 10) / 10, y = math.floor(pos.y * 10) / 10},
          health = math.floor(c.entity.health / c.entity.max_health * 100),
          name = c.name
        }
      end
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    u.json_response({companions = list, count = #list})
  end)
end)

local STARTING_ITEMS = u.settings.starting_items

u.register("companion_spawn", function(args)
  u.safe_command(function()

    local req_id = args.companionId
    local req_name = args.name ~= "" and args.name or nil
    if req_id and storage.companions[req_id] then
      local c = storage.companions[req_id]
      if c.entity and c.entity.valid then u.json_response({status = "exists", id = req_id}); return end
    end
    local id = req_id or storage.companion_next_id
    if not req_id then storage.companion_next_id = storage.companion_next_id + 1
    elseif req_id >= storage.companion_next_id then storage.companion_next_id = req_id + 1 end
    -- Spawn near a player if one exists, else at the map spawn / origin so the
    -- companion works on a HEADLESS server with no connected player.
    local p = game.players[1]
    local surface = (p and p.valid) and p.surface or game.surfaces[1]
    local force = (p and p.valid) and p.force or game.forces.player
    -- headless (no player): use the force's actual spawn position, not a hardcoded origin
    local base = (p and p.valid) and p.position or force.get_spawn_position(surface)
    local want = {x = base.x + id * 2, y = base.y}
    local pos = surface.find_non_colliding_position("character", want, 64, 0.5) or want
    local e = surface.create_entity{name = "character", position = pos, force = force}
    if e then
      local color = u.get_companion_color(id)
      e.color = color
      local name = req_name or ("#" .. id)
      -- Standard new-player starting kit (real, not a cheat -- exactly what a fresh
      -- freeplay game grants any player character; this companion just never went
      -- through that normal on_player_created flow to receive it automatically).
      local inv = e.get_inventory(defines.inventory.character_main)
      if inv then
        for item, count in pairs(STARTING_ITEMS) do
          inv.insert{name = item, count = count}
        end
      end
      storage.companions[id] = {entity = e, color = color, name = name,
                                label = u.render_label(e, name, color), spawned_tick = game.tick}
      if storage.dead_companions then storage.dead_companions[id] = nil end  -- (re)spawned -> no longer dead
      game.print("[" .. name .. " spawned]", u.print_color(color))
      u.json_response({spawned = true, id = id, name = name})
    else
      local diag = u.dump_context(surface, pos)
      u.error_response(string.format(
        "Failed to spawn at (%.1f,%.1f) tile=%s -- nearby: %s",
        pos.x, pos.y, diag.tile, table.concat(diag.nearby, ",")))
    end
  end)
end)

u.register("companion_disappear", function(args)
  u.safe_command(function()
    local id, c = u.find_companion(args.companionId)
    if not id then u.not_found(); return end
    lifecycle.stop(id)
    local pos, surf = c.entity.position, c.entity.surface
    local dropped = {}
    local inv = c.entity.get_inventory(defines.inventory.character_main)
    if inv then
      for _, item in pairs(inv.get_contents()) do
        surf.spill_item_stack{position = pos, stack = {name = item.name, count = item.count,
                               quality = item.quality}, enable_looted = true, allow_belts = false}
        dropped[#dropped + 1] = {name = item.name, count = item.count}
      end
    end
    if c.label and c.label.valid then c.label.destroy() end
    if storage.companion_markers and storage.companion_markers[id] then
      if storage.companion_markers[id].valid then storage.companion_markers[id].destroy() end
      storage.companion_markers[id] = nil
    end
    c.entity.destroy()
    storage.companions[id] = nil
    storage.walking_queues[id] = nil
    game.print("[#" .. id .. " gone]", u.print_color(u.COLORS.system))
    u.json_response({id = id, disappeared = true, dropped = dropped})
  end)
end)

u.register("companion_respawn", function(args)
  u.safe_command(function()
    local id = u.find_companion(args.companionId)
    if not id then u.not_found(); return end
    local result = queues.debug_respawn_entity(id)
    if result.error then u.json_response({id = id, error = result.error})
    else u.json_response({id = id, respawned = result.respawned}) end
  end)
end)

u.register("companion_position", function(args)
  u.safe_command(function()
    local id, c = u.find_companion(args.companionId)
    if not id then u.not_found(); return end
    local pos, surf = c.entity.position, c.entity.surface
    local nearby = surf.find_entities_filtered{position = pos, radius = 20, limit = 30}
    local summary = {}
    for _, e in ipairs(nearby) do if e.valid and e ~= c.entity then summary[e.name] = (summary[e.name] or 0) + 1 end end
    local players = {}
    for _, p in pairs(game.players) do
      if p.valid and p.surface == surf then
        local d = u.distance(p.position, pos)
        if d < 100 then players[#players + 1] = {name = p.name, distance = math.floor(d)} end
      end
    end
    local walk = storage.walking_queues[id]
    local arrived = storage.walk_last_arrived and storage.walk_last_arrived[id]
    local walk_target = (walk and walk.target) or arrived
    u.json_response({id = id, position = {x = math.floor(pos.x * 10) / 10, y = math.floor(pos.y * 10) / 10}, nearby = summary, players = players, walk_target = walk_target}, id)
  end)
end)

u.register("companion_health", function(args)
  u.safe_command(function()
    local id, c = u.find_companion(args.companionId)
    if not id then u.not_found(); return end
    local e = c.entity
    local r = {id = id, self = {health = e.health, max = e.max_health, pct = math.floor(e.health / e.max_health * 100)}}
    local tgt = args.target ~= "" and args.target or nil
    if tgt then
      local p = game.get_player(tgt)
      if p and p.valid and p.character then
        local ch = p.character
        r.target = {type = "player", name = p.name, health = ch.health, max = ch.max_health, pct = math.floor(ch.health / ch.max_health * 100)}
      else
        local tid, tc = u.find_companion(tgt)
        if tid then
          local te = tc.entity
          r.target = {type = "companion", id = tid, health = te.health, max = te.max_health, pct = math.floor(te.health / te.max_health * 100)}
        else r.target = {error = "Not found"} end
      end
    end
    u.json_response(r)
  end)
end)

u.register("companion_inventory", function(args)
  u.safe_command(function()
    local id, c = u.find_companion(args.companionId)
    if not id then u.not_found(); return end
    local x, y = tonumber(args.x), tonumber(args.y)
    if x and y then
      local t = entity_info.nearest(c.entity.surface,{x=x,y=y},2)
      if not t then u.json_response({id = id, error = "No entity"}); return end
      local items = {}
      for _, group in ipairs(entity_info.inventories(t)) do
        for _, item in ipairs(u.inventory_contents(group.inventory)) do
          items[#items + 1] = {name = item.name, count = item.count, quality = item.quality, slot = group.slot}
        end
      end
      u.json_response({id = id, entity = t.name, items = items})
    else
      local inv = c.entity.get_inventory(defines.inventory.character_main)
      local items = {}
      -- Factorio 2.0: get_contents() returns {name, quality, count} items
      for _, item in pairs(inv.get_contents()) do
        items[#items + 1] = {name = item.name, count = item.count, quality = item.quality}
      end
      table.sort(items, function(a, b) return a.count > b.count end)
      u.json_response({id = id, items = items, slots = #inv, used = #items,
                        empty_stacks = inv.count_empty_stacks()})
    end
  end)
end)

u.register("companion_stop", function(args)
  u.safe_command(function()
    local id = tonumber(args.companionId)
    if not id then u.error_response("Invalid companion ID"); return end
    local stopped = lifecycle.stop(id)
    u.json_response({id = id, stopped = stopped})
  end)
end)
