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

-- Manual/test-triggerable entry point for the rare-symptom save-for-later-review
-- mechanism (2026-07-19/20, see u.rare_symptom_save's own comment in init.lua for
-- the full design) -- mirrors fac_respawn_entity's own dual purpose immediately
-- above: a genuine manual escape hatch (Zdendys can force a save+code manually for
-- anything HE wants captured, not just the 4 automatic trigger points) AND a live
-- test entry point for the debounce mechanism, since require() (and therefore the
-- shared `u` module) isn't reachable from a bare RCON /c command outside
-- control.lua's own load.
commands.add_command("fac_debug_rare_symptom_save", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)$", cmd.parameter)
    local code = args[1]
    if not code then u.error_response("Usage: fac_debug_rare_symptom_save <CODE>"); return end
    local saved = u.rare_symptom_save(code)
    u.json_response({code = code, saved = saved})
  end)
end)

-- fac_debug_walk_state (2026-07-25, walking-obstacle re-path fix, live verification):
-- storage.walking_queues[id] is NOT readable from a bare RCON /c command (that runs
-- in the LEVEL's own separate script context, not this mod's real per-mod storage --
-- live-caught while testing the target-walkability fix a few commits ago) -- this is
-- the same "genuine test/debug entry point, require()'d module needed" pattern as
-- fac_debug_rare_symptom_save immediately above. Dumps exactly the fields the
-- stuck/bypass/re-path state machine (process_walking_queues, control.lua) actually
-- tracks, for live-diagnosing exactly this class of issue without guessing.
commands.add_command("fac_debug_walk_state", nil, function(cmd)
  u.safe_command(function()
    local id = tonumber(cmd.parameter)
    if not id then u.error_response("Usage: fac_debug_walk_state <id>"); return end
    local q = storage.walking_queues and storage.walking_queues[id]
    if not q then u.json_response({id = id, active = false}); return end
    u.json_response({
      id = id, active = true,
      target = q.target, has_path = q.path ~= nil,
      path_idx = q.path_idx, path_len = q.path and #q.path or nil,
      path_pending = q.path_pending or false,
      stuck_ticks = q.stuck_ticks or 0,
      bypass_ticks = q.bypass_ticks or 0,
      bypass_attempts = q.bypass_attempts or 0,
      bypass_side = q.bypass_side,
      waypoint_stall_ticks = q.waypoint_stall_ticks or 0,
      active_ticks = q.active_ticks,
    })
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
    --
    -- walk_target (2026-07-25, Zdendys's own "stop server, work through everything"
    -- directive -- found live via the discard-pause investigation mechanism during a
    -- recording run): control.lua's TARGET-WALKABILITY fix (2026-07-24,
    -- WALK_TARGET_WALKABLE_RADIUS) silently CORRECTS an unwalkable q.target (e.g. a
    -- servicing call's own go_to(dx,dy,dist=2.2) where (dx,dy) is a drill/furnace's
    -- own exact placed position -- always "inside a building's footprint" by
    -- definition) to the nearest walkable tile, up to 3 tiles away. wait_arrive()
    -- (companion.py) polls distance against the ORIGINAL (dx,dy) with the CALLER's
    -- own `dist` (often 2.2) -- it has no idea the mod silently walked her to a
    -- DIFFERENT point instead. Live-confirmed: this produced repeated, intermittent
    -- "could not reach X -- skipping this visit" failures across EVERY servicing
    -- dispatch in one recording episode (stone/iron/copper drill+furnace, all
    -- retargeted 0.7-1.4 tiles from their own exact position) -- sometimes still
    -- landing within the caller's dist by chance, sometimes not, matching the
    -- "sometimes works, sometimes doesn't" pattern observed live. Exposing the
    -- CURRENT (possibly-corrected) walk target here lets wait_arrive() also accept
    -- arrival relative to what the mod is ACTUALLY walking her to, not just the
    -- stale original -- see companion.py's wait_arrive() for the consuming side.
    local wq = storage.walking_queues[id]
    local walk_target = (wq and wq.target) and {x = wq.target.x, y = wq.target.y} or nil
    -- walk_last_arrived fallback (2026-07-26, see control.lua's init_storage
    -- comment on storage.walk_last_arrived for the full race this closes): the
    -- live queue can be gone (walk_target nil above) NOT because no walk ever
    -- happened, but because process_walking_queues' own dist<2 arrival check
    -- already cleared it moments ago -- still expose that corrected point so
    -- wait_arrive() (companion.py) can accept arrival relative to it, closing
    -- the exact race a live mid-wait diagnostic (companion.py, same session)
    -- proved was happening (active:false from the very first poll of an
    -- affected wait).
    if not walk_target and storage.walk_last_arrived[id] then
      local la = storage.walk_last_arrived[id]
      walk_target = {x = la.x, y = la.y}
    end
    u.json_response({id = id, position = {x = math.floor(pos.x * 10) / 10, y = math.floor(pos.y * 10) / 10}, nearby = summary, players = players, walk_target = walk_target}, id)
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
