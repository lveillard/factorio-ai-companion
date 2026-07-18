-- AI Companion v0.7.0 - Companion commands
local u = require("commands.init")
local queues = require("commands.queues")

commands.add_command("fac_companion_list", nil, function(cmd)
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

-- Standard new-player starting kit (2026-07-06, Zdendys live-checked his own actual
-- Space Age crash-landing start and gave the exact, authoritative list: "at start
-- the character only has: wood=1, pistol=1, firearm-magazine=2, burner-mining-drill=1,
-- stone-furnace=1" -- base game's own freeplay.lua created_items() has DIFFERENT counts
-- (iron-plate=8, firearm-magazine=10) and includes iron-plate at all, but that script is
-- not what Space Age's crash-landing scenario actually uses -- this exact list is
-- Zdendys's direct, live observation, not a file read, and takes priority over it).
-- A companion spawned via surface.create_entity bypasses the normal on_player_created
-- flow entirely, so nothing else ever grants even this much.
local STARTING_ITEMS = {
  ["wood"] = 1,
  ["pistol"] = 1,
  ["firearm-magazine"] = 2,
  ["burner-mining-drill"] = 1,
  ["stone-furnace"] = 1,
}

commands.add_command("fac_companion_spawn", nil, function(cmd)
  u.safe_command(function()
    local param = cmd.parameter or ""
    local req_id = tonumber(param:match("id=(%d+)"))
    local req_name = param:match("name=(%S+)")
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
      -- Diagnostic (2026-07-12, task #46): "Failed to spawn" carried zero forensic info --
      -- surface.create_entity can fail on an unbuildable tile/collision at `pos` even after
      -- find_non_colliding_position, so log what's actually there via the shared dump_context
      -- helper (same pattern as queues.lua's build-collision diagnostic).
      local diag = u.dump_context(surface, pos)
      u.error_response(string.format(
        "Failed to spawn at (%.1f,%.1f) tile=%s -- nearby: %s",
        pos.x, pos.y, diag.tile, table.concat(diag.nearby, ",")))
    end
  end)
end)

commands.add_command("fac_companion_disappear", nil, function(cmd)
  u.safe_command(function()
    local id, c = u.find_companion(cmd.parameter)
    if not id then u.not_found(); return end
    local pos, surf = c.entity.position, c.entity.surface
    local dropped = {}
    local inv = c.entity.get_inventory(defines.inventory.character_main)
    if inv then
      -- 2026-07-11: two bugs fixed together, found live while investigating a separate
      -- issue (see factorio-ai's memory/mode_a_select_fail_investigation_2026_07_11.md,
      -- Phase 2). Both were masked by the first one throwing before the second could ever
      -- surface as its own distinct symptom:
      -- (1) inv.get_contents() returns an ARRAY of {name=,count=,quality=} in current
      --     Factorio, not a name->count dict -- the old `for name, count in pairs(...)`
      --     bound `name` to the array INDEX and `count` to the whole item table.
      -- (2) spill_item_stack's signature is a single table of named fields in current
      --     Factorio (confirmed against lua-api.factorio.com), not 5 positional args --
      --     the old call threw "Expected 1 argument but 5 were given" live, aborting this
      --     command before it ever reached c.entity.destroy() or cleared
      --     storage.companions[id], so a companion with ANY inventory could never be
      --     cleanly disappeared via this command at all.
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
    storage.context_clear_requests[id] = game.tick
    storage.companions[id] = nil
    storage.walking_queues[id] = nil
    game.print("[#" .. id .. " gone]", u.print_color(u.COLORS.system))
    u.json_response({id = id, disappeared = true, dropped = dropped})
  end)
end)

-- Manual escape hatch (2026-07-11, Phase 3 of the mode-a-select-fail investigation --
-- see queues.lua's SELECT_FAIL_RESPAWN_STREAK/respawn_companion_entity comment for the
-- full Phase 2 evidence chain this is built on). Destroys the companion's current
-- character entity and respawns a fresh one under the SAME id, preserving position,
-- inventory, name and color -- the exact recovery Phase 2 live-verified works when a
-- companion's entity gets stuck in the "selected never sticks" state. Also usable as a
-- generic "this companion looks wedged, give it a fresh entity" operator command,
-- independent of the automatic gather()-side trigger.
commands.add_command("fac_respawn_entity", nil, function(cmd)
  u.safe_command(function()
    local id = u.find_companion(cmd.parameter)
    if not id then u.not_found(); return end
    local result = queues.debug_respawn_entity(id)
    if result.error then u.json_response({id = id, error = result.error})
    else u.json_response({id = id, respawned = result.respawned}) end
  end)
end)

commands.add_command("fac_companion_position", nil, function(cmd)
  u.safe_command(function()
    local id, c = u.find_companion(cmd.parameter)
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
    -- `id` passed as 2nd arg (2026-07-05): the companion's OWN position poll -- which
    -- Python's wait_arrive() already calls every ~1-2s while blocking on movement -- now
    -- also surfaces whatever OTHER async jobs (mine/build/craft/...) are still in flight
    -- for this same companion, for free, no extra RCON round-trip needed to discover it.
    u.json_response({id = id, position = {x = math.floor(pos.x * 10) / 10, y = math.floor(pos.y * 10) / 10}, nearby = summary, players = players}, id)
  end)
end)

commands.add_command("fac_companion_health", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)%s*(%S*)$", cmd.parameter)
    local id, c = u.find_companion(args[1])
    if not id then u.not_found(); return end
    local e = c.entity
    local r = {id = id, self = {health = e.health, max = e.max_health, pct = math.floor(e.health / e.max_health * 100)}}
    local tgt = args[2] ~= "" and args[2] or nil
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

commands.add_command("fac_companion_inventory", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)%s*([%d.-]*)%s*([%d.-]*)$", cmd.parameter)
    local id, c = u.find_companion(args[1])
    if not id then u.not_found(); return end
    local x, y = tonumber(args[2]), tonumber(args[3])
    if x and y then
      local es = c.entity.surface.find_entities_filtered{position = {x=x, y=y}, radius = 2}
      local t
      for _, e in ipairs(es) do if e.valid and e ~= c.entity then t = e; break end end
      if not t then u.json_response({id = id, error = "No entity"}); return end
      local items = {}
      -- furnace_source/furnace_result are stale 1.x defines removed in Factorio 2.0's
      -- inventory unification (nil here; get_inventory(nil) throws) -- crafter_input/
      -- crafter_output are the correct 2.0+ names for both furnaces and assemblers.
      for _, it in ipairs({{defines.inventory.chest, "chest"}, {defines.inventory.crafter_input, "in"}, {defines.inventory.crafter_output, "out"}, {defines.inventory.fuel, "fuel"}}) do
        local inv = t.get_inventory(it[1])
        if inv then for name, count in pairs(inv.get_contents()) do items[#items + 1] = {name = name, count = count, slot = it[2]} end end
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
      u.json_response({id = id, items = items, slots = #inv, used = #items})
    end
  end)
end)

commands.add_command("fac_companion_stop_all", nil, function(cmd)
  u.safe_command(function()
    local id, c = u.find_companion(cmd.parameter)
    if not id then u.not_found(); return end
    local stopped = {}
    if storage.harvest_queues and storage.harvest_queues[id] then
      storage.harvest_queues[id] = nil
      stopped[#stopped + 1] = "harvest"
    end
    if storage.craft_queues and storage.craft_queues[id] then
      storage.craft_queues[id] = nil
      stopped[#stopped + 1] = "craft"
    end
    if storage.build_queues and storage.build_queues[id] then
      storage.build_queues[id] = nil
      stopped[#stopped + 1] = "build"
    end
    if storage.combat_queues and storage.combat_queues[id] then
      storage.combat_queues[id] = nil
      stopped[#stopped + 1] = "combat"
    end
    if storage.walking_queues and storage.walking_queues[id] then
      storage.walking_queues[id] = nil
      stopped[#stopped + 1] = "walk"
    end
    c.entity.walking_state = {walking = false}
    u.json_response({id = id, stopped = stopped})
  end)
end)
