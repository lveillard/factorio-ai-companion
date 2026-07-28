-- AI Companion -- BELT CONNECT queue (Stage 0.2, 2026-07-04; 2026-07-19 size-refactor
-- split out of queues.lua). Fully self-contained: owns storage.belt_queues exclusively,
-- no cross-section calls beyond queues_core.lua. Uses commands.pathfind, its only user
-- in the whole original queues.lua (confirmed by grep before this split).
--
-- Model=WHAT/mod=HOW split (belt/inserter automation plan): the model/Python side already
-- knows the exact relative geometry of what it just built (furnace, drill, assembler --
-- same proven pattern as _build_ore_drill_furnace) and places any INSERTERS itself via the
-- existing fac_building_place/_rotate/fac_inserter_set_filter primitives. This command
-- handles ONLY the one genuinely-new problem: routing a transport-belt corridor between two
-- already-chosen points, avoiding ore patches/water/buildings (pathfind.lua's A*), with an
-- underground-belt straight-line fallback (max 4 tiles, yellow tier) for a gap no walkable
-- route crosses. No `material`/inserter-type param -- narrower than the original plan
-- sketch (which had this command also place+type both end inserters); simplified during
-- implementation per the plan's own flagged Open Question #3 ("exact algorithm needs its
-- own design pass"). Async like fac_building_place_start/_status: the companion really
-- walks the path (no teleporting) and consumes real transport-belt/underground-belt items,
-- one tile per queue tick.
-- Confirmed straight from the engine's own prototype data (not the ambiguous/contradictory
-- wiki wording -- cubic dev ai bot flagged this as an off-by-one, 2026-07-04):
-- /base/prototypes/entity/transport-belts.lua's "underground-belt" (yellow tier) entry has
-- max_distance = 5 -- entrance and exit tiles can be up to 5 tiles apart (4 tiles of actual
-- underground gap in between), NOT 4 tiles apart. Named to match the engine field exactly
-- so this stays unambiguous.

local u = require("commands.init")
local pathfind = require("commands.pathfind")
local core = require("commands.queues_core")

local M = {}

local UNDERGROUND_MAX_DISTANCE = 5   -- yellow-tier underground-belt (entrance-to-exit span)

local function step_dir(a, b)
  if b.x > a.x then return defines.direction.east end
  if b.x < a.x then return defines.direction.west end
  if b.y > a.y then return defines.direction.south end
  return defines.direction.north
end

function M.start_belt_connect(cid, from_pos, to_pos)
  local c = core.valid_companion(cid)
  if not c then return {error = "Invalid companion"} end
  -- Same task-pool-ownership guard as start_gather/start_fuel_group (2026-07-08, task
  -- #42) -- safe here (unlike start_build) since task_pool.lua never calls
  -- start_belt_connect internally, only the direct fac_belt_connect command does.
  if storage.active_step and storage.active_step[cid] then
    return {error = "companion busy with an active task-pool step"}
  end
  local surf = c.entity.surface
  local force = c.entity.force

  local path, reason = pathfind.find_path(surf, from_pos, to_pos, force)
  if not path then
    -- No walkable route at all within the search budget -- try a direct underground-belt
    -- pair across the gap (only when it's a straight axis-aligned hop within the yellow
    -- tier's max distance; A* already tried routing AROUND anything shorter/bypassable).
    local fx, fy = math.floor(from_pos.x), math.floor(from_pos.y)
    local tx, ty = math.floor(to_pos.x), math.floor(to_pos.y)
    local same_row = (fx == tx) or (fy == ty)
    local dist = math.abs(tx - fx) + math.abs(ty - fy)
    if same_row and dist >= 1 and dist <= UNDERGROUND_MAX_DISTANCE then
      path = {
        {x = fx, y = fy, dir = step_dir({x = fx, y = fy}, {x = tx, y = ty}), underground = "entrance"},
        {x = tx, y = ty, dir = step_dir({x = fx, y = fy}, {x = tx, y = ty}), underground = "exit"},
      }
    else
      -- `reason` distinguishes WHY find_path failed (task #43 diagnostic follow-up,
      -- 2026-07-10): "start-blocked" / "dest-blocked" / "budget-exhausted". Additive
      -- only -- `error` stays exactly "no path" so every existing caller checking
      -- `.get("error")` for truthiness is unaffected.
      return {error = "no path", reason = reason or "budget-exhausted"}
    end
  else
    -- Recompute each tile's direction as OUTGOING (toward the next tile), not the A*
    -- search's internal "arrived from" bookkeeping -- a Factorio belt's direction is the
    -- way it moves items (matches the tile-to-tile step it feeds INTO), so tile i's belt
    -- must face tile i+1, not tile i-1. The last tile has no next -- continue straight.
    for i = 1, #path do
      if path[i + 1] then
        path[i].dir = step_dir(path[i], path[i + 1])
      else
        path[i].dir = (path[i - 1] and path[i - 1].dir) or defines.direction.north
      end
    end
  end

  local need_belt, need_underground = 0, 0
  for _, node in ipairs(path) do
    if node.underground then need_underground = need_underground + 1
    else need_belt = need_belt + 1 end
  end

  local inv = c.entity.get_main_inventory()
  local have_belt = inv.get_item_count("transport-belt")
  local have_underground = inv.get_item_count("underground-belt")
  if have_belt < need_belt or have_underground < need_underground then
    return {
      error = "Insufficient belt items", need_belt = need_belt, need_underground = need_underground,
      have_belt = have_belt, have_underground = have_underground
    }
  end

  storage.belt_queues[cid] = {path = path, idx = 1, tiles_placed = 0, state = "placing",
    -- run_start_tick/run_end_tick (2026-07-28, action-timing instrumentation,
    -- batch 2): this domain already has a "done"/"failed" freeze grace period
    -- (get_belt_connect_status consumes it exactly once before deleting), so
    -- run_end_tick (set at each terminal transition in tick_belt_queues) is
    -- reliably readable by the next poll.
    run_start_tick = game.tick}
  return {started = true, tiles = #path, need_belt = need_belt, need_underground = need_underground}
end

function M.tick_belt_queues()
  core.process_queue("belt_queues", function(cid, q, c)
    -- TERMINAL: sit here until get_belt_connect_status consumes+clears this entry (same
    -- fix as tick_build_queues -- otherwise a poll a moment after completion just sees
    -- plain "active:false", indistinguishable from success).
    if q.state == "done" or q.state == "failed" then return false end

    local surf = c.entity.surface
    local reach = c.entity.build_distance or 10
    local node = q.path[q.idx]
    if not node then q.run_end_tick = game.tick; q.state = "done"; return false end

    if u.distance(c.entity.position, {x = node.x, y = node.y}) > reach then
      -- APPROACH DEADLINE (cubic dev ai bot, 2026-07-04): unlike tick_gather_queues/
      -- tick_fuel_queues, this had NO elapsed-time guard at all -- a permanently blocked
      -- tile (water/cliff/train in the way) left q.walking=true and this branch returning
      -- `false` (still active) forever, hanging get_belt_connect_status indefinitely with
      -- no way for a caller to ever learn it failed. Same distance-scaled deadline formula
      -- as tick_gather_queues (25 ticks/tile, floor 1800) so a legitimately long walk isn't
      -- cut short but a genuinely stuck one bails instead of hanging.
      -- Also (re)seed the deadline if it's simply MISSING, not just on the first tick of
      -- walking: `storage` is Factorio's persistent save-game state, so a belt_queues entry
      -- written by an OLDER mod version (before approach_deadline existed) could still have
      -- q.walking=true with no deadline after a save/reload -- `(q.approach_deadline or 0)`
      -- would then make `game.tick >= 0` true on the very next tick and kill a build that's
      -- still genuinely walking (cubic dev ai bot, 2026-07-04). Healing it here (instead of
      -- just nil-guarding the comparison) gives that legacy entry a fresh, bounded deadline
      -- rather than either failing it instantly OR leaving it to hang forever again.
      if not q.walking or not q.approach_deadline then
        q.approach_deadline = u.approach_deadline(c.entity.position, {x = node.x, y = node.y})
        if not q.walking then
          storage.walking_queues[cid] = {
            target = surf.find_non_colliding_position("character", {x = node.x, y = node.y}, 3, 0.5)
                     or {x = node.x, y = node.y}
          }
          q.walking = true
        end
      elseif game.tick >= q.approach_deadline then
        storage.walking_queues[cid] = nil
        c.entity.walking_state = {walking = false}
        q.failed = "cannot reach belt tile (" .. node.x .. "," .. node.y .. ") -- " ..
                   (q.idx) .. "/" .. #q.path .. " placed before giving up"
        q.run_end_tick = game.tick
        q.state = "failed"
      end
      return false
    end
    if q.walking then
      storage.walking_queues[cid] = nil
      c.entity.walking_state = {walking = false}
      q.walking = false
    end

    local item = node.underground and "underground-belt" or "transport-belt"
    local pos = {x = node.x, y = node.y}
    if c.entity.get_main_inventory().get_item_count(item) < 1 then
      q.failed = "Out of " .. item .. " mid-build (" .. q.idx .. "/" .. #q.path .. " placed)"
      q.run_end_tick = game.tick
      q.state = "failed"; return false
    end
    -- `type` (input/output) is a create_entity-only field for underground belts, not a
    -- valid can_place_entity param -- keep the collision check's args separate so an
    -- unrecognized key can't make the check itself error or behave unexpectedly.
    if not surf.can_place_entity{name = item, position = pos, direction = node.dir, force = c.entity.force} then
      q.failed = "Cannot place " .. item .. " at (" .. node.x .. "," .. node.y .. ")"
      q.run_end_tick = game.tick
      q.state = "failed"; return false
    end
    local create_args = {name = item, position = pos, direction = node.dir, force = c.entity.force}
    if node.underground then create_args.type = (node.underground == "entrance") and "input" or "output" end
    local placed = surf.create_entity(create_args)
    if not placed then
      q.failed = "create_entity returned nil"
      q.run_end_tick = game.tick
      q.state = "failed"; return false
    end
    -- Never a free build: consume the real item, undo if it somehow isn't there anymore.
    if c.entity.remove_item{name = item, count = 1} < 1 then
      placed.destroy()
      q.failed = "item vanished before consuming"
      q.run_end_tick = game.tick
      q.state = "failed"; return false
    end
    q.tiles_placed = q.tiles_placed + 1
    q.idx = q.idx + 1
    if q.idx > #q.path then
      q.run_end_tick = game.tick
      q.state = "done"
    end
    return false
  end)
end

function M.get_belt_connect_status(cid)
  local q = storage.belt_queues[cid]
  if not q then return {active = false} end
  if q.state == "done" then
    storage.belt_queues[cid] = nil
    return {active = false, connected = true, tiles = q.tiles_placed,
      run_start_tick = q.run_start_tick, run_end_tick = q.run_end_tick}
  end
  if q.state == "failed" then
    storage.belt_queues[cid] = nil
    return {active = false, connected = false, error = q.failed, tiles = q.tiles_placed,
      run_start_tick = q.run_start_tick, run_end_tick = q.run_end_tick}
  end
  return {active = true, tiles_placed = q.tiles_placed, tiles_total = #q.path}
end

function M.stop_belt_connect(cid)
  if not storage.belt_queues[cid] then return {stopped = false} end
  storage.walking_queues[cid] = nil
  storage.belt_queues[cid] = nil
  return {stopped = true}
end

return M
