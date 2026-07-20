-- AI Companion -- HARVEST queue + orphaned mining safety net (2026-07-19
-- size-refactor split out of queues.lua). Verbatim move.

local u = require("commands.init")
local core = require("commands.queues_core")

local TICK_INTERVAL = core.TICK_INTERVAL
local MINE_ADJACENT_RANGE = core.MINE_ADJACENT_RANGE
local valid_companion = core.valid_companion
local process_queue = core.process_queue

local M = {}

local MINING_RANGE = 5

function M.start_harvest(cid, position, target_count, resource_name)
  local c = valid_companion(cid)
  if not c then return {error = "Invalid companion"} end

  -- Filter by resource name if specified, otherwise get all resources
  local filter = {position = position, radius = 3, type = "resource"}
  if resource_name then filter.name = resource_name end

  local entities = c.entity.surface.find_entities_filtered(filter)
  if #entities == 0 then return {error = "No resource"} end

  table.sort(entities, function(a, b)
    return u.distance(a.position, c.entity.position) < u.distance(b.position, c.entity.position)
  end)

  -- Resolve the actual MINED ITEM name from the resource prototype, same as tick_gather_queues
  -- already does (cubic-dev-ai review, 2026-07-03): the resource entity name (used to find/filter
  -- entities) is NOT reliably the same as the item you receive -- they happen to match for every
  -- vanilla solid ore (iron-ore, copper-ore, coal, stone, uranium-ore) but NOT in general (a fluid
  -- resource like crude-oil has no item at all; modded resources can name the entity and item
  -- differently, or emit >1 product). Using the raw entity name as an inventory item key would
  -- silently track the WRONG (or a nonexistent) item, so q.harvested would never advance despite
  -- real mining happening. Only resolvable when resource_name narrowed the entities to ONE
  -- resource type; a mixed-resource harvest (resource_name=nil) has no single product to track and
  -- keeps the whole-inventory-delta fallback in tick_harvest_queues.
  local product = nil
  if resource_name then
    local mp = entities[1].prototype.mineable_properties
    product = mp and mp.products and mp.products[1] and mp.products[1].name or nil
    if not product then
      u.log_error("harvest: resource '" .. resource_name .. "' has no minable item product " ..
        "-- progress will fall back to whole-inventory tracking", "harvest_queue")
    end
  end

  storage.harvest_queues[cid] = {
    entities = entities,
    position = position,
    target = target_count,
    harvested = 0,
    current = nil,
    resource_name = resource_name,
    product = product
  }

  M.start_mining_next(cid)
  -- Set inv_snapshot immediately after starting mining
  storage.harvest_queues[cid].inv_snapshot = c.entity.get_main_inventory().get_contents()
  return {started = true, entities = #entities, target = target_count, resource = resource_name}
end

function M.start_mining_next(cid)
  local q = storage.harvest_queues[cid]
  if not q then return false end

  local c = valid_companion(cid)
  if not c then
    storage.harvest_queues[cid] = nil
    return false
  end

  -- NATIVE mining, the SAME mechanic a real player uses: setting mining_state lets the GAME
  -- ENGINE run the whole mining cycle itself (real per-resource mining_time, real swinging
  -- animation, real extraction into the inventory) -- we do NOT call entity.mine{} ourselves
  -- at all (Zdendys 2026-07-03: "pouzit proste nativni schopnosti postavy", same as
  -- character.mining_state a player's client sets while holding the mine button). The engine
  -- keeps mining the SAME target automatically, one unit per completed swing, for as long as
  -- mining_state stays true and the target is valid+in range -- tick_harvest_queues just
  -- watches inventory deltas and moves mining_state to the next tile once one depletes.
  --
  -- mining_state.position is ONLY consulted for TILE mining (e.g. landfill/cliffs); per the
  -- Factorio API docs, "when the player isn't mining tiles the player will mine whatever
  -- entity is currently selected" -- so an ore/resource ENTITY must be set via `selected`
  -- first, or mining_state silently does nothing (0 extraction forever, no error) even
  -- though mining=true and the position looks correct. Live-caught 2026-07-03: harvest
  -- queues stuck at "0/N harvested" indefinitely until this was added.
  while #q.entities > 0 do
    local entity = q.entities[1]
    if not (entity and entity.valid and entity.type == "resource") then
      table.remove(q.entities, 1)   -- invalid / non-resource -> skip to next tile
    else
      c.entity.selected = entity
      c.entity.mining_state = {mining = true, position = entity.position}
      q.current = {entity = entity, done = false}
      return true
    end
  end
  return false
end

function M.tick_harvest_queues()
  process_queue("harvest_queues", function(cid, q, c)
    -- Target reached
    if q.harvested >= q.target then
      c.entity.mining_state = {mining = false}
      return true
    end

    -- Too far from mining area
    if u.distance(c.entity.position, q.position) > MINING_RANGE then
      c.entity.mining_state = {mining = false}
      return true
    end

    -- TRUE adjacency check (2026-07-05, Zdendys live-caught: harvest queue froze forever at
    -- "harvested=0, mining=true" on TWO different maps/positions, game.tick advancing normally,
    -- companion stationary, `selected` correctly set to a valid resource entity). Root cause:
    -- the companion was within MINING_RANGE (5) of q.position (the original command's x,y) but
    -- NOT within the ~2-tile MINE_ADJACENT_RANGE of the SPECIFIC entity start_mining_next
    -- selected -- native mining_state silently does nothing at that distance even with
    -- `selected` set (see this file's own MINE_ADJACENT_RANGE comment above). This exact
    -- adjacency check was already added to tick_gather_queues on 2026-07-03 (below, "mine"
    -- state) but never backported to tick_harvest_queues, which is what fac_resource_mine /
    -- Python's mine_and_wait actually uses -- and Python's own go_to() "arrived" tolerance
    -- (MINE_DIST=4.5) is looser than this mod's true ~2-tile requirement, so a caller can
    -- easily "arrive" while still being just out of native mining range. Treat an
    -- out-of-adjacency current entity the same as a depleted one: skip it and try the next
    -- candidate in q.entities, instead of spinning on it forever.
    local cur_entity = q.current and q.current.entity
    if cur_entity and cur_entity.valid and
       u.distance(c.entity.position, cur_entity.position) > MINE_ADJACENT_RANGE then
      if #q.entities > 0 and q.entities[1] == cur_entity then table.remove(q.entities, 1) end
      q.current = nil
      if not M.start_mining_next(cid) then
        c.entity.mining_state = {mining = false}
        u.log_error(string.format(
          "harvest queue for companion %d ended short (%d/%d %s): no candidate entity was ever " ..
          "within true mining adjacency (%d tiles) -- caller likely approached with too loose a " ..
          "tolerance", cid, q.harvested, q.target, q.resource_name or "?", MINE_ADJACENT_RANGE),
          "harvest_queue")
        -- RARE-MINE-01 (2026-07-19/20, save-for-later-review scheme -- see
        -- u.rare_symptom_save's own comment): this specific ending (adjacency
        -- exhausted, not the depleted/inventory-full endings elsewhere in this
        -- same function that share the "harvest_queue" tag) is the stone-harvest
        -- adjacency-exhaustion stall.
        u.rare_symptom_save("RARE-MINE-01")
        return true
      end
      return false   -- fresh candidate selected -- re-check adjacency/progress next tick
    end

    -- Stale-progress backstop (defense in depth, mirrors the bounded-deadline requirement
    -- already enforced for every other queue type in this mod -- walking/gather/fuel/craft/
    -- build/belt/combat): if harvested hasn't moved for a bounded number of ticks despite
    -- passing every check above, terminate rather than hang indefinitely on some future/
    -- unknown stall this adjacency fix doesn't cover.
    q.stale_ticks = (q.last_harvested == q.harvested) and (q.stale_ticks or 0) + TICK_INTERVAL or 0
    q.last_harvested = q.harvested
    if q.stale_ticks > 600 then
      c.entity.mining_state = {mining = false}
      u.log_error(string.format(
        "harvest queue for companion %d ended short (%d/%d %s): no progress for %d ticks despite " ..
        "passing all reachability checks -- unknown stall", cid, q.harvested, q.target,
        q.resource_name or "?", q.stale_ticks), "harvest_queue")
      return true
    end

    -- NATIVE mining (Zdendys 2026-07-03: "pouzit proste nativni schopnosti postavy"): the
    -- engine itself runs the mining cycle once mining_state is set in start_mining_next --
    -- same speed, same animation, same extraction as a real player holding the mine button.
    -- We just watch the inventory for what the engine actually produced.
    --
    -- Track the SPECIFIC mined ITEM (q.product, resolved in start_harvest from the resource
    -- prototype's mineable_properties -- NOT q.resource_name, which is the resource ENTITY name
    -- and only coincidentally matches the item name for vanilla solid ores; a second cubic-dev-ai
    -- review caught that using the entity name directly would silently track the wrong/nonexistent
    -- item for fluids or modded resources with a different entity/item name), not the whole-
    -- inventory total (first cubic-dev-ai review, 2026-07-03): a plain get_item_count() total is
    -- thrown off by ANY concurrent queue on the same companion (fuel top-up removing coal, a craft
    -- consuming ingredients, a build consuming a placed item) -- completely unrelated inventory
    -- changes get misread as mined progress or lost progress. When start_harvest was called
    -- without a resource filter (mines whatever resource is nearby, product unknown up front) or
    -- the product couldn't be resolved, there's no single item to track, so this falls back to the
    -- old whole-inventory delta -- same limitation there, but at least the baseline-staleness bug
    -- below is fixed in both cases.
    local inv = c.entity.get_main_inventory()
    local now_count = q.product and inv.get_item_count(q.product) or inv.get_item_count()
    if q.last_inv_count == nil then q.last_inv_count = now_count end
    local gained = now_count - q.last_inv_count
    if gained > 0 then
      q.harvested = q.harvested + gained
    end
    -- ALWAYS refresh the baseline (not just when gained > 0): otherwise any net inventory
    -- DECREASE (a concurrent queue consuming items) leaves last_inv_count stale/too-high, and
    -- every subsequent tick's mined units get silently swallowed by the still-negative delta
    -- until the total climbs back above the old stale baseline (cubic-dev-ai review).
    q.last_inv_count = now_count

    -- Current target depleted (engine removed it) or never set -> advance to the next tile.
    local cur = q.current and q.current.entity
    if not (cur and cur.valid) then
      if #q.entities > 0 and q.entities[1] == cur then table.remove(q.entities, 1) end
      if not M.start_mining_next(cid) then
        c.entity.mining_state = {mining = false}
        -- A depleted tile normally means its full amount was MINED (game inserts or, if the
        -- inventory is full, spills the item on the ground -- either way the tile empties).
        -- If harvested is still short of target here, every listed entity ran out while
        -- items were spilling instead of landing in inventory -- silently reporting this as
        -- plain "queue done" would hide a real inventory-full condition from the caller.
        if q.harvested < q.target then
          u.log_error(string.format(
            "harvest queue for companion %d ended short (%d/%d %s): entities exhausted, " ..
            "possible full inventory (mined items spilled to ground)",
            cid, q.harvested, q.target, q.resource_name or "?"), "harvest_queue")
        end
        return true
      end
    end

    return q.harvested >= q.target
  end)
end

function M.get_harvest_status(cid)
  local q = storage.harvest_queues[cid]
  if not q then return {active = false} end
  return {
    active = true,
    harvested = q.harvested,
    target = q.target,
    remaining = #q.entities,
    mining = q.current ~= nil
  }
end

function M.stop_harvest(cid)
  local q = storage.harvest_queues[cid]
  if not q then return {stopped = false} end

  local c = valid_companion(cid)
  if c then c.entity.mining_state = {mining = false} end

  local harvested = q.harvested
  storage.harvest_queues[cid] = nil
  return {stopped = true, harvested = harvested}
end

-- ============ ORPHANED MINING SAFETY NET ============
-- Defense in depth (2026-07-06, Zdendys live-caught: a companion mined a single stone
-- tile CONTINUOUSLY for 10+ minutes -- stone climbing from ~144 to 335+ -- while BOTH
-- storage.harvest_queues and storage.gather_queues were confirmed completely EMPTY for
-- every companion id (checked via direct RCON query, no race). Every normal completion
-- path in tick_harvest_queues/tick_gather_queues explicitly sets mining_state=false
-- before returning, but process_queue's own early-exit branch (when valid_companion(cid)
-- returns falsy) removes the queue entry WITHOUT ever calling the processor callback --
-- so if a companion's registry entry ever goes missing while its physical character
-- entity and native mining_state persist (exact trigger not fully pinned down this
-- session), nothing is left to ever stop it; the engine just keeps mining the same tile
-- forever, completely untracked. Regardless of the precise trigger, nothing should ever
-- be able to mine with zero tracking -- this backstop periodically scans every
-- COMPANION (non-player) character actually mining and stops any that isn't accounted
-- for by an in-flight harvest/gather queue, mirroring the stale-progress backstop
-- pattern tick_harvest_queues already uses internally, one level up (whole-mod scan,
-- not per-queue). `not e.player` excludes real human-controlled characters (e.g. Zdendys
-- connected and mining by hand) -- this must NEVER touch a player's own actions.
local ORPHAN_CHECK_INTERVAL = 300  -- ~5s at 60 UPS -- a backstop, not time-critical

function M.tick_orphan_mining_cleanup()
  if (game.tick % ORPHAN_CHECK_INTERVAL) ~= 0 then return end
  local tracked = {}
  for cid in pairs(storage.harvest_queues or {}) do
    local c = valid_companion(cid)
    if c then tracked[c.entity.unit_number] = true end
  end
  for cid in pairs(storage.gather_queues or {}) do
    local c = valid_companion(cid)
    if c then tracked[c.entity.unit_number] = true end
  end
  -- walking_queues[cid].clearing_target (2026-07-17, live-caught: repeated
  -- "orphan mining stopped" for the SAME character at successive positions,
  -- ~300-600 ticks apart -- exactly this check's own interval): control.lua's
  -- process_walking_queues sets mining_state DIRECTLY (via q.clearing_target,
  -- both the reach=1/reach=4 auto-clear-while-stuck paths and the
  -- needs_destroy_to_reach waypoint path) as a THIRD legitimate mining
  -- mechanism, entirely separate from harvest_queues/gather_queues -- this
  -- backstop never knew about it. Consequence: ANY obstacle whose real
  -- mining_time exceeds ORPHAN_CHECK_INTERVAL (300 ticks/5 game-seconds --
  -- true regardless of game.speed, since game.tick counts real ticks) got
  -- forcibly interrupted right before/at completion, every single cycle,
  -- forever -- a tree/rock that takes longer than 5 seconds to mine could
  -- NEVER be successfully cleared this way, permanently stalling whatever
  -- walk was blocked on it. process_walking_queues's own `if not
  -- e.mining_state.mining then e.mining_state = {mining=true,...}` (it only
  -- re-asserts when mining_state.mining reads false) means this bug was
  -- silently self-"healing" one tick later into the SAME broken cycle,
  -- never actually completing -- exactly the repeated-interrupt pattern
  -- observed live.
  for cid in pairs(storage.walking_queues or {}) do
    local q = storage.walking_queues[cid]
    if q and q.clearing_target then
      local c = valid_companion(cid)
      if c then tracked[c.entity.unit_number] = true end
    end
  end
  for _, surface in pairs(game.surfaces) do
    for _, e in ipairs(surface.find_entities_filtered{type = "character"}) do
      if e.valid and not e.player and e.mining_state.mining and not tracked[e.unit_number] then
        e.mining_state = {mining = false}
        u.log_error(string.format(
          "orphan mining stopped: character #%d at (%.0f,%.0f) was mining with no " ..
          "tracking harvest/gather queue (likely a stale companion registry)",
          e.unit_number, e.position.x, e.position.y), "orphan_mining")
      end
    end
  end
end

return M
