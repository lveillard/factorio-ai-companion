-- AI Companion -- FUEL GROUP queue (2026-07-19 size-refactor split out of
-- queues.lua). Verbatim move -- see queues_core.lua's own tile_key comment for
-- why that one shared helper moved there instead of duplicating it here.

local u = require("commands.init")
local core = require("commands.queues_core")

local valid_companion = core.valid_companion
local process_queue = core.process_queue
local tile_key = core.tile_key

local M = {}

-- ============ FUEL GROUP (autonomous: walk to each burner in range -> top up fuel) ============
-- Self-contained composite: the mod finds every burner machine (one with a fuel inventory) of the
-- FUEL_TYPES within `radius` of the companion, walks to each (nearest-first), and tops it up FROM
-- THE COMPANION'S OWN INVENTORY (native insert -> consumes real coal, no cheat). Replaces the Python
-- go_to + fuel + poll loop over a hardcoded machine list.
-- ROUND-ROBIN, not greedy: with scarce coal, filling burner #1 to `per` in one visit can exhaust the
-- WHOLE supply before burner #2 is ever tried (the top-of-tick "out of coal -> done" check fires
-- first) -- observed live as "only the first furnace gets fed". Each burner is visited AT MOST ONCE
-- per round (tracked in `served`, reset when a round completes); a burner still short after being
-- served waits for the NEXT round, so every reachable burner gets a turn before any one is topped off
-- twice, spreading a limited supply evenly instead of draining it on whichever is nearest.
-- Valid entity TYPES (not names): burner-inserter's type is "inserter"; electric inserters/drills
-- return nil get_fuel_inventory() and are skipped, so filtering by type + fuel-inv is exact.
local FUEL_TYPES = {"furnace", "boiler", "inserter", "mining-drill"}
local APPROACH_TIMEOUT = 900   -- ticks (~15s@60ups): give up on an unreachable burner, skip it

local function find_next_burner(surf, from, radius, per, blacklist, served)
  local es = surf.find_entities_filtered{position = from, radius = radius, type = FUEL_TYPES}
  table.sort(es, function(a, b) return u.distance(a.position, from) < u.distance(b.position, from) end)
  for _, e in ipairs(es) do
    local key = tile_key(e.position)
    if e.valid and not blacklist[key] and not served[key] then
      local fi = e.get_fuel_inventory()
      if fi and fi.get_item_count("coal") < per then return e end   -- burner (electric = nil fi) that needs topping up
    end
  end
  return nil
end

function M.start_fuel_group(cid, per, radius)
  local c = valid_companion(cid)
  if not c then return {error = "Invalid companion"} end
  -- Same task-pool-ownership guard as start_gather above (2026-07-08, task #42).
  if storage.active_step and storage.active_step[cid] then
    return {error = "companion busy with an active task-pool step"}
  end
  storage.fuel_queues[cid] = {per = per or 20, radius = radius or 200, state = "find",
                              blacklist = {}, served = {}, fueled = 0, machines = 0,
                              -- run_start_tick/run_end_tick (2026-07-28, action-timing
                              -- instrumentation, batch 2): this domain already has a
                              -- "done"-freeze grace period (get_fuel_status consumes
                              -- it exactly once before deleting), so run_end_tick set
                              -- at each q.state="done" transition below is reliably
                              -- readable.
                              run_start_tick = game.tick}
  return {started = true, per = per or 20, radius = radius or 200}
end

function M.tick_fuel_queues()
  process_queue("fuel_queues", function(cid, q, c)
    local surf = c.entity.surface
    local inv = c.entity.get_main_inventory()

    -- TERMINAL: freeze here until get_fuel_status consumes+clears this entry -- same fix as the
    -- build queue: deleting the entry the instant it's done meant a Python poll a moment later saw
    -- plain "active:false" with NO fueled/machines counts (observed live: real coal WAS split across
    -- both furnaces, but the reported result said "fueled:0, machines:0" because the run finished
    -- inside the first 2s poll interval, before Python ever saw an in-progress snapshot).
    if q.state == "done" then return false end

    if inv.get_item_count("coal") <= 0 then
      q.run_end_tick = game.tick
      q.state = "done"; return false   -- out of coal -> done
    end

    if q.state == "find" then
      local e = find_next_burner(surf, c.entity.position, q.radius, q.per, q.blacklist, q.served)
      if not e then
        if next(q.served) then q.served = {}; return false end   -- round complete, some still need more -> new round
        q.run_end_tick = game.tick
        q.state = "done"; return false                           -- truly nothing left to fuel -> done
      end
      q.target_pos = {x = e.position.x, y = e.position.y}
      q.target_key = tile_key(e.position)
      q.approach_deadline = game.tick + APPROACH_TIMEOUT
      storage.walking_queues[cid] = {target = surf.find_non_colliding_position("character", e.position, 2, 0.5) or e.position}
      q.state = "approach"
      return false
    end

    if q.state == "approach" then
      if u.distance(c.entity.position, q.target_pos) <= (c.entity.reach_distance or 10) then
        storage.walking_queues[cid] = nil
        c.entity.walking_state = {walking = false}
        q.state = "fuel"
      elseif game.tick >= (q.approach_deadline or 0) then    -- unreachable -> skip PERMANENTLY (every round)
        storage.walking_queues[cid] = nil
        c.entity.walking_state = {walking = false}
        q.blacklist[q.target_key] = true
        q.state = "find"
      end
      return false
    end

    if q.state == "fuel" then
      q.served[q.target_key] = true                           -- mark BEFORE fueling: at-most-once per ROUND
      local e = surf.find_entities_filtered{position = q.target_pos, radius = 1, type = FUEL_TYPES}[1]
      if e and e.valid then
        local fi = e.get_fuel_inventory()
        local have = inv.get_item_count("coal")
        if fi and have > 0 then
          local want = q.per - fi.get_item_count("coal")
          if want > 0 then
            local r = fi.insert{name = "coal", count = math.min(want, have)}
            if r > 0 then inv.remove{name = "coal", count = r}; q.fueled = q.fueled + r; q.machines = q.machines + 1 end
          end
        end
      end
      q.state = "find"
      return false
    end
    q.run_end_tick = game.tick
    q.state = "done"
    return false
  end)
end

function M.get_fuel_status(cid)
  local q = storage.fuel_queues[cid]
  if not q then return {active = false} end
  -- blacklist tile-keys (2026-07-12, closing the follow-up flagged in 6d00d54): mirrors
  -- get_gather_status's identical `bl` construction below. Previously this getter never
  -- exposed q.blacklist at all -- so even now that the generic backstop defers deletion
  -- (TERMINAL freeze, see process_queue above) instead of deleting the entry in the
  -- same tick it blacklists, a Python-side fuel_group() caller still had no field to
  -- read the newly-blacklisted target_key back from.
  local bl = {}
  if q.blacklist then
    for k in pairs(q.blacklist) do bl[#bl + 1] = k end
  end
  if q.state == "done" then
    storage.fuel_queues[cid] = nil
    return {active = false, fueled = q.fueled, machines = q.machines, blacklist = bl,
      run_start_tick = q.run_start_tick, run_end_tick = q.run_end_tick}
  end
  return {active = true, state = q.state, fueled = q.fueled, machines = q.machines, blacklist = bl,
    run_start_tick = q.run_start_tick, run_end_tick = q.run_end_tick}
end

return M
