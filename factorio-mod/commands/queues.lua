local u = require("commands.init")
local pathfind = require("commands.pathfind")

local M = {}

local function previous(queue_name, cid)
  return storage.queue_results[queue_name] and storage.queue_results[queue_name][cid]
end

local function finish_queue(queue_name, cid, q)
  q._finished = true
  q.finished_tick = game.tick
  q.error = q.error or q.failed
  if q.product and q.start_count then
    local c = u.get_companion(cid)
    q.gathered = c and c.entity.get_main_inventory().get_item_count(q.product) - q.start_count or 0
  end
  if q.state ~= "cancelled" and q.state ~= "failed" then
    local produced = q.gathered or q.harvested or q.crafted
    if q.failed or (type(q.target) == "number" and produced and produced < q.target) then
      q.state = "failed"
      q.error = q.error or "Job ended before the requested amount was produced"
    else q.state = "done" end
  end
  storage.queue_results[queue_name] = storage.queue_results[queue_name] or {}
  storage.queue_results[queue_name][cid] = q
  storage[queue_name][cid] = nil
end

function M.cancel_queue(queue_name, cid)
  local q = storage[queue_name] and storage[queue_name][cid]
  if not q then return false end
  q.state, q.error = "cancelled", "Cancelled by a new command or stop request"
  finish_queue(queue_name, cid, q)
  return true
end

-- Constants
local TICK_INTERVAL = u.settings.queue_tuning.tick_interval
local MIN_ACTION_TICKS = u.settings.queue_tuning.min_action_ticks
local BUILD_TICKS = u.settings.queue_tuning.build_ticks
local ATTACK_COOLDOWN = u.settings.queue_tuning.attack_cooldown
local ATTACK_RANGE = u.settings.queue_tuning.attack_range
local MINING_RANGE = u.settings.queue_tuning.mining_range
local MINE_ADJACENT_RANGE = u.settings.queue_tuning.mine_adjacent_range
local SELECT_FAIL_TICKS = u.settings.queue_tuning.select_fail_ticks

local respawn_companion_entity

local MINE_DIAG_CAP = u.settings.queue_tuning.mine_diag_cap
local function _record_mine_diag(cid, sample)
  storage.mine_diag = storage.mine_diag or {}
  local buf = storage.mine_diag[cid]
  if not buf then buf = {}; storage.mine_diag[cid] = buf end
  buf[#buf + 1] = sample
  if #buf > MINE_DIAG_CAP then table.remove(buf, 1) end
end

-- Validate companion exists and is valid
local function valid_companion(id)
  local c = u.get_companion(id)
  return c and c.entity and c.entity.valid and c
end

local UNIVERSAL_STALE_TICKS = u.settings.queue_tuning.universal_stale_ticks

-- Generic queue processor - eliminates repetition across all tick functions
local function process_queue(queue_name, processor)
  local queues = storage[queue_name]
  if not queues then return end

  local to_remove = {}
  for cid, q in pairs(queues) do
    local c = valid_companion(cid)
    if q.state == "done" or q.state == "failed" then
      to_remove[#to_remove + 1] = cid
    elseif not c then
      q.state, q.error = "failed", "Companion is no longer available"
      to_remove[#to_remove + 1] = cid
    else
      local total = c.entity.get_inventory(defines.inventory.character_main).get_item_count()
      local pos = c.entity.position
      local moved = q._stale_pos and (u.distance(q._stale_pos, pos) > 5)
      if (queue_name == "build_queues" and q.state == "stepping_away") or
        (queue_name == "craft_queues" and q.inflight and c.entity.crafting_queue_size > 0) then
        q._stale_total, q._stale_pos, q._stale_ticks = total, {x = pos.x, y = pos.y}, 0
      elseif q._stale_total == total and q._stale_pos and not moved then
        q._stale_ticks = (q._stale_ticks or 0) + TICK_INTERVAL
      else
        q._stale_total = total
        q._stale_pos = {x = pos.x, y = pos.y}
        q._stale_ticks = 0
      end
      if q._stale_ticks > UNIVERSAL_STALE_TICKS and q.state == "done" then
      elseif q._stale_ticks > UNIVERSAL_STALE_TICKS then
        local function fmt_maybe_pos(v)
          if type(v) == "table" and v.x and v.y then
            return string.format("(%.1f,%.1f)", v.x, v.y)
          end
          return tostring(v)
        end
        u.log_error(string.format(
          "%s queue for companion %d force-stopped: neither inventory count nor " ..
          "position changed in %d ticks -- no real progress regardless of queue-" ..
          "specific state -- stuck_at=(%.1f,%.1f) queue_state=%s entity_pos=%s target=%s",
          queue_name, cid, q._stale_ticks, pos.x, pos.y, tostring(q.state),
          fmt_maybe_pos(q.entity_pos), fmt_maybe_pos(q.target)),
          queue_name)
        local recovered_via_respawn = false
        if queue_name == "gather_queues" and q.state == "approach" and q.entity_pos and q.resource then
          if not q._approach_stall_respawned and respawn_companion_entity(cid, c) then
            q._approach_stall_respawned = true
            recovered_via_respawn = true
            q.approach_deadline = u.approach_deadline(c.entity.position, q.entity_pos)
            q._stale_total, q._stale_pos, q._stale_ticks = nil, nil, 0
            u.log_error(string.format(
              "gather_queues generic-backstop: approach toward '%s' at (%.1f,%.1f) stalled " ..
              "for companion %d -- respawned its entity and retrying the SAME target once " ..
              "before blacklisting the whole neighborhood", q.resource,
              q.entity_pos.x, q.entity_pos.y, cid), "gather_queue")
          else
            -- Mirrors the "approach" state's own approach_deadline handler exactly
            -- (radius=15, same "whole patch, not just one tile" reasoning documented there).
            q.blacklist = q.blacklist or {}
            local added = 0
            for _, e in ipairs(c.entity.surface.find_entities_filtered{
              name = q.resource, position = q.entity_pos, radius = 15}) do
              local key = math.floor(e.position.x) .. "," .. math.floor(e.position.y)
              if not q.blacklist[key] then added = added + 1 end
              q.blacklist[key] = true
            end
            u.log_error(string.format(
              "gather_queues generic-backstop recovery: blacklisted %d tile(s) of '%s' " ..
              "around entity_pos (%.1f,%.1f) before force-stop -- its own approach_deadline " ..
              "(tick %s) never got a chance to run (this generic backstop fires at " ..
              "%d ticks, always sooner)%s", added, q.resource,
              q.entity_pos.x, q.entity_pos.y, tostring(q.approach_deadline), UNIVERSAL_STALE_TICKS,
              q._approach_stall_respawned and " (after an earlier respawn-retry also stalled)" or ""),
              "gather_queue")
          end
        elseif queue_name == "fuel_queues" and q.state == "approach" and q.target_key then
          -- fuel_queues' own "approach" handler blacklists only the single target_key
          -- (not a radius sweep): unlike a resource patch, a burner machine is one
          -- isolated entity, not part of a cluster of identical adjacent tiles -- mirror
          -- THAT shape exactly, not gather_queues' radius=15 sweep.
          q.blacklist = q.blacklist or {}
          local was_new = not q.blacklist[q.target_key]
          q.blacklist[q.target_key] = true
          u.log_error(string.format(
            "fuel_queues generic-backstop recovery: blacklisted target_key=%s before " ..
            "force-stop%s -- approach_deadline never got a chance to run",
            q.target_key, was_new and "" or " (already blacklisted)"), "fuel_queue")
        end
        -- APPROACH-STALL-RESPAWN (continued, see comment above): if the gather_queues
        -- branch above chose to respawn+retry instead of condemning the neighborhood,
        -- do NOT touch mining_state/walking_state or freeze/delete the queue this tick --
        -- let it keep running normally with its freshly reset approach_deadline and
        -- staleness counters, exactly as an ordinary in-progress "approach" would.
        if not recovered_via_respawn then
          c.entity.mining_state = {mining = false}
          c.entity.walking_state = {walking = false}
          q.state, q.error = "failed", "No inventory or movement progress before timeout"
          to_remove[#to_remove + 1] = cid
        end
      else
        local should_remove = processor(cid, q, c)
        if should_remove then to_remove[#to_remove + 1] = cid end
      end
    end
  end

  for _, cid in ipairs(to_remove) do if queues[cid] then finish_queue(queue_name, cid, queues[cid]) end end
end

function M.init()
  storage.queue_results = storage.queue_results or {}
  storage.harvest_queues = storage.harvest_queues or {}
  storage.gather_queues = storage.gather_queues or {}
  storage.fuel_queues = storage.fuel_queues or {}
  storage.craft_queues = storage.craft_queues or {}
  storage.build_queues = storage.build_queues or {}
  storage.combat_queues = storage.combat_queues or {}
  storage.belt_queues = storage.belt_queues or {}
  storage.mine_diag = storage.mine_diag or {}   -- diagnostic, see MINE_DIAG_CAP comment above
end

-- Diagnostic accessor (Mode A/B gather-select-fail investigation) -- returns the
-- per-cycle "mine" state trace buffer for `cid` (empty list if none recorded yet, e.g.
-- never entered "mine").
function M.get_mine_diag(cid)
  storage.mine_diag = storage.mine_diag or {}
  return storage.mine_diag[cid] or {}
end

-- ============ HARVEST ============

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
  local q = storage.harvest_queues[cid] or previous("harvest_queues", cid)
  if not q then return {active = false} end
  return {
    active = not q._finished,
    state = q.state, error = q.error,
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
  M.cancel_queue("harvest_queues", cid)
  return {stopped = true, harvested = harvested}
end

local ORPHAN_CHECK_INTERVAL = u.settings.queue_tuning.orphan_check_interval

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

local function _tile_key(pos) return math.floor(pos.x) .. "," .. math.floor(pos.y) end

local function find_reachable_resource(surf, from, resource, blacklist)
  local ores = surf.find_entities_filtered{name = resource, position = from, radius = 400}
  table.sort(ores, function(a, b) return u.distance(a.position, from) < u.distance(b.position, from) end)
  for _, e in ipairs(ores) do
    if e.valid and (e.amount or 0) > 0
       and not (blacklist and blacklist[_tile_key(e.position)])
       and surf.count_entities_filtered{type = "unit-spawner", position = e.position, radius = 20} == 0
       and surf.find_non_colliding_position("character", e.position, 2.5, 0.5) then
      return e
    end
  end
  local total = #ores
  local depleted, blacklisted, near_spawner, no_stand_pos = 0, 0, 0, 0
  for _, e in ipairs(ores) do
    if e.valid then
      if (e.amount or 0) <= 0 then depleted = depleted + 1
      elseif blacklist and blacklist[_tile_key(e.position)] then blacklisted = blacklisted + 1
      elseif surf.count_entities_filtered{type = "unit-spawner", position = e.position, radius = 20} > 0 then
        near_spawner = near_spawner + 1
      elseif not surf.find_non_colliding_position("character", e.position, 2.5, 0.5) then
        no_stand_pos = no_stand_pos + 1
      end
    end
  end
  u.log_error(string.format(
    "find_reachable_resource: no usable %s within 400 tiles of (%.1f,%.1f) -- total=%d "
    .. "depleted=%d blacklisted=%d near_spawner=%d no_stand_pos=%d",
    resource, from.x, from.y, total, depleted, blacklisted, near_spawner, no_stand_pos),
    "gather_queue")
  return nil
end

local SELECT_FAIL_RESPAWN_STREAK = u.settings.queue_tuning.select_fail_respawn_streak

-- Assigns into the `local respawn_companion_entity` forward-declared near the top of this
-- file (NOT `local function` here -- that would shadow the forward declaration with a
-- brand-new local, leaving process_queue's earlier closure permanently pointing at nil).
function respawn_companion_entity(cid, c)
  local old = c.entity
  local pos, surf, force = old.position, old.surface, old.force
  -- Snapshot inventory BEFORE destroying -- old.get_inventory() is unusable the
  -- instant old.destroy() runs.
  local contents = {}
  local inv = old.get_inventory(defines.inventory.character_main)
  if inv then contents = inv.get_contents() end
  if c.label and c.label.valid then c.label.destroy() end
  old.destroy()
  local new_pos = surf.find_non_colliding_position("character", pos, 5, 0.5) or pos
  local e = surf.create_entity{name = "character", position = new_pos, force = force}
  if not e then
    u.log_error(string.format(
      "respawn_companion_entity: failed to create a replacement character for companion " ..
      "%d at (%.1f,%.1f) -- companion is now WITHOUT AN ENTITY, will read as dead",
      cid, new_pos.x, new_pos.y), "gather_queue")
    return false
  end
  e.color = c.color
  local new_inv = e.get_inventory(defines.inventory.character_main)
  if new_inv then
    for _, item in pairs(contents) do
      new_inv.insert{name = item.name, count = item.count, quality = item.quality}
    end
  end
  c.entity = e
  c.label = u.render_label(e, c.name, c.color)
  u.log_error(string.format(
    "respawn_companion_entity: companion %d's character entity replaced at (%.1f,%.1f) " ..
    "after %d consecutive select-fail blacklist events with no successful mine in between " ..
    "(Phase 2 mode-a-select-fail mitigation)", cid, new_pos.x, new_pos.y,
    SELECT_FAIL_RESPAWN_STREAK), "gather_queue")
  game.print("[" .. (c.name or ("#" .. cid)) .. " respawned -- entity was stuck (selection " ..
    "bug), continuing]", u.print_color(u.COLORS.system))
  return true
end

function M.start_gather(cid, resource, count, exclude, from_task_pool)
  local c = valid_companion(cid)
  if not c then return {error = "Invalid companion"} end
  if not from_task_pool and storage.active_step and storage.active_step[cid] then
    return {error = "companion busy with an active task-pool step"}
  end
  local blacklist = {}
  if exclude then
    for _, p in ipairs(exclude) do
      blacklist[_tile_key(p)] = true
    end
  end
  storage.gather_queues[cid] = {resource = resource, target = count, state = "find",
    last_mine_tick = 0, blacklist = blacklist}
  return {started = true, resource = resource, target = count}
end

function M.tick_gather_queues()
  process_queue("gather_queues", function(cid, q, c)
    local surf = c.entity.surface
    local inv = c.entity.get_main_inventory()

    if q.state == "done" then return false end

    if q.state == "find" then
      local e = find_reachable_resource(surf, c.entity.position, q.resource, q.blacklist)
      if not e then
        q.find_retry_deadline = q.find_retry_deadline or (game.tick + 300)
        if game.tick < q.find_retry_deadline then return false end
        q.state, q.error = "failed", "No reachable resource remains before target was reached"
        return false
      end
      local mp = e.prototype.mineable_properties
      if not (mp and mp.products and mp.products[1]) then
        -- Non-standard resource (no item product, e.g. a fluid-only patch) -- blacklist this
        -- tile and retry next tick instead of crashing on a nil index.
        q.blacklist = q.blacklist or {}
        q.blacklist[_tile_key(e.position)] = true
        u.log_error("gather queue: resource '" .. q.resource .. "' at (" ..
          math.floor(e.position.x) .. "," .. math.floor(e.position.y) ..
          ") has no minable item product, skipping", "gather_queue")
        return false
      end
      q.entity_pos = {x = e.position.x, y = e.position.y}
      q.product = mp.products[1].name
      if not q.start_count then q.start_count = inv.get_item_count(q.product) end
      -- distance-scaled deadline: 25 ticks/tile (~3.7x the expected walk) so a legit long walk is
      -- never aborted, but a companion STUCK on an obstacle (standable != path-reachable) bails fast
      -- instead of hanging the whole 180s (the "3 min and 0 coal" bug).
      q.approach_deadline = u.approach_deadline(c.entity.position, e.position)
      storage.walking_queues[cid] = {target = surf.find_non_colliding_position("character", e.position, 1, 0.5) or e.position}
      q.state = "approach"
      storage.mine_diag = storage.mine_diag or {}
      storage.mine_diag[cid] = {}
      return false
    end

    if q.state == "approach" then
      local d_to_target = u.distance(c.entity.position, q.entity_pos)
      _record_mine_diag(cid, {
        t = game.tick, st = "approach", r = _tile_key(q.entity_pos), d = d_to_target,
        pos = {x = c.entity.position.x, y = c.entity.position.y},
        w = c.entity.walking_state and c.entity.walking_state.walking or false,
        dir = c.entity.walking_state and c.entity.walking_state.direction or false,
        sel = c.entity.selected and c.entity.selected.name or false,
        ti = inv.get_item_count(),
        g = q.product and (inv.get_item_count(q.product) - (q.start_count or 0)) or 0})
      if d_to_target <= MINE_ADJACENT_RANGE then
        storage.walking_queues[cid] = nil
        c.entity.walking_state = {walking = false}
        q.state = "mine"
      elseif game.tick >= (q.approach_deadline or 0) then   -- cannot reach this patch -> blacklist + try next
        if not q._approach_stall_respawned and respawn_companion_entity(cid, c) then
          q._approach_stall_respawned = true
          q.approach_deadline = u.approach_deadline(c.entity.position, q.entity_pos)
          u.log_error(string.format(
            "gather_queues approach_deadline: approach toward '%s' at (%.1f,%.1f) stalled " ..
            "for companion %d -- respawned its entity and retrying the SAME target once " ..
            "before blacklisting the whole neighborhood", q.resource,
            q.entity_pos.x, q.entity_pos.y, cid), "gather_queue")
          return false
        end
        q.blacklist = q.blacklist or {}
        for _, e in ipairs(surf.find_entities_filtered{name = q.resource, position = q.entity_pos, radius = 15}) do
          q.blacklist[_tile_key(e.position)] = true
        end
        storage.walking_queues[cid] = nil
        c.entity.walking_state = {walking = false}
        q.state = "find"
      end
      return false
    end

    if q.state == "mine" then
      if inv.get_item_count(q.product) - (q.start_count or 0) >= q.target then
        c.entity.mining_state = {mining = false}
        q.state = "done"; return false   -- target met
      end
      -- DIAGNOSTIC (Mode A/B gather-select-fail investigation, see MINE_DIAG_CAP comment above): fresh
      -- read BEFORE this cycle's own logic touches anything, so a sample can reveal
      -- whether the ENGINE itself flipped mining_state off between our last write and
      -- now (as opposed to only ever seeing what WE last wrote). Also captures the SAME
      -- two inputs process_queue's own generic UNIVERSAL_STALE_TICKS backstop uses
      -- (total inventory count + position) -- tests the hypothesis that some UNRELATED
      -- inventory/position change could be resetting that backstop's own counter while
      -- the gather-specific product count stays stuck at 0 (which would explain how a
      -- Mode-B-shaped stall could run past 600 ticks without the generic backstop
      -- catching it).
      local mine_diag_mining_before = c.entity.mining_state and c.entity.mining_state.mining or false
      local mine_diag_total_inv = inv.get_item_count()   -- same call process_queue's own staleness backstop uses
      local mine_diag_can_insert = inv.can_insert({name = q.product, count = 1})
      local mine_diag_pos = {x = c.entity.position.x, y = c.entity.position.y}
      local candidates = surf.find_entities_filtered{name = q.resource, position = q.entity_pos, radius = 2}
      local res, best_d = nil, 1e18
      for _, e in ipairs(candidates) do
        if e.valid then
          local d = u.distance(c.entity.position, e.position)
          if d < best_d then best_d, res = d, e end
        end
      end
      if not res then
        c.entity.mining_state = {mining = false}
        q.select_fail_ticks = nil   -- leaving "mine" -- don't let a stale count leak into the next tile
        q.state = "find"; return false   -- depleted -> next patch
      end
      if best_d > MINE_ADJACENT_RANGE then
        c.entity.mining_state = {mining = false}
        q.select_fail_ticks = nil
        q.state = "find"; return false
      end
      local res_key = _tile_key(res.position)
      if q.last_res_key and q.last_res_key ~= res_key then
        u.log_error(string.format(
          "gather mine-state: selected entity changed mid-mine %s -> %s (best_d=%.2f, tick=%d)",
          q.last_res_key, res_key, best_d, game.tick), "gather_trace")
      end
      q.last_res_key = res_key
      if c.entity.selected ~= res then
        c.entity.selected = res
      end
      if c.entity.selected ~= res then
        q.select_fail_ticks = (q.select_fail_ticks or 0) + TICK_INTERVAL
        if q.select_fail_ticks > SELECT_FAIL_TICKS then
          local ore_bb = res.bounding_box
          local clear_area = {
            {x = ore_bb.left_top.x - 0.5, y = ore_bb.left_top.y - 0.5},
            {x = ore_bb.right_bottom.x + 0.5, y = ore_bb.right_bottom.y + 0.5}
          }
          local obstacles = surf.find_entities_filtered{
            area = clear_area, type = {"tree", "simple-entity"}}
          local cleared = 0
          for _, obs in ipairs(obstacles) do
            if obs.valid then
              obs.mine{inventory = c.entity.get_main_inventory()}
              cleared = cleared + 1
            end
          end
          if cleared > 0 then
            u.log_error(string.format(
              "gather mine-state: cleared %d tree/rock obstacle(s) near %s at %s -- " ..
              "retrying select instead of blacklisting", cleared, q.resource, res_key),
              "gather_queue")
            q.select_fail_ticks = 0
            return false
          end
          u.log_error(string.format(
            "gather mine-state: %s at %s never became selectable after %d ticks " ..
            "(best_d=%.2f) -- blacklisting, trying next patch",
            q.resource, res_key, q.select_fail_ticks, best_d), "gather_queue")
          q.blacklist = q.blacklist or {}
          local just_blacklisted = {}
          for _, e in ipairs(surf.find_entities_filtered{name = q.resource, position = q.entity_pos, radius = 15}) do
            local key = _tile_key(e.position)
            q.blacklist[key] = true
            just_blacklisted[#just_blacklisted + 1] = key
          end
          q.select_fail_ticks = nil
          q.last_res_key = nil
          q.state = "find"
          q.select_fail_streak = (q.select_fail_streak or 0) + 1
          if q.select_fail_streak >= SELECT_FAIL_RESPAWN_STREAK then
            if respawn_companion_entity(cid, c) then
              -- Only undo THIS sweep's own additions (victims of the broken entity) --
              -- leave any other pre-existing blacklist entries (approach_deadline
              -- exclusions, caller-seeded excludes) untouched, see comment above.
              for _, key in ipairs(just_blacklisted) do
                q.blacklist[key] = nil
              end
              inv = c.entity.get_main_inventory()
            end
            q.select_fail_streak = 0
          end
        end
        _record_mine_diag(cid, {
          t = game.tick, st = "mine", r = res_key, d = best_d,
          mb = mine_diag_mining_before,
          ma = c.entity.mining_state and c.entity.mining_state.mining or false,
          sel = c.entity.selected and c.entity.selected.name or false,
          selm = (c.entity.selected == res), w = c.entity.walking_state and c.entity.walking_state.walking or false,
          g = inv.get_item_count(q.product) - (q.start_count or 0), sft = q.select_fail_ticks or 0,
          ti = mine_diag_total_inv, ci = mine_diag_can_insert, mp = c.entity.mining_progress,
          pos = mine_diag_pos})
        return false
      end
      q.select_fail_ticks = nil
      q.select_fail_streak = 0
      if not c.entity.mining_state.mining then
        c.entity.mining_state = {mining = true, position = res.position}
      end
      _record_mine_diag(cid, {
        t = game.tick, st = "mine", r = res_key, d = best_d,
        mb = mine_diag_mining_before,
        ma = c.entity.mining_state and c.entity.mining_state.mining or false,
        sel = c.entity.selected and c.entity.selected.name or false,
        selm = (c.entity.selected == res), w = c.entity.walking_state and c.entity.walking_state.walking or false,
        g = inv.get_item_count(q.product) - (q.start_count or 0), sft = 0,
        ti = mine_diag_total_inv, ci = mine_diag_can_insert, mp = c.entity.mining_progress,
        pos = mine_diag_pos})
      return false
    end
    return true
  end)
end

function M.debug_respawn_entity(cid)
  local c = valid_companion(cid)
  if not c then return {error = "Invalid companion"} end
  local ok = respawn_companion_entity(cid, c)
  return {respawned = ok}
end

function M.get_gather_status(cid)
  local q = storage.gather_queues[cid] or previous("gather_queues", cid)
  if not q then return {active = false} end
  local c = valid_companion(cid)
  local have = q.gathered or (c and q.product) and c.entity.get_main_inventory().get_item_count(q.product) - (q.start_count or 0) or 0
  local bl = {}
  if q.blacklist then
    for k in pairs(q.blacklist) do bl[#bl + 1] = k end
  end
  local selected_name, mining = nil, nil
  if c then
    selected_name = c.entity.selected and c.entity.selected.name or nil
    mining = c.entity.mining_state and c.entity.mining_state.mining or false
  end
  if q.state == "done" then
    return {active = false, resource = q.resource, target = q.target, gathered = have,
      blacklist = bl, entity_pos = q.entity_pos,
      selected = selected_name, mining_state_mining = mining}
  end
  return {active = not q._finished, resource = q.resource, target = q.target, gathered = have,
    state = q.state, error = q.error, blacklist = bl, entity_pos = q.entity_pos,
    selected = selected_name, mining_state_mining = mining}
end

local FUEL_TYPES = {"furnace", "boiler", "inserter", "mining-drill"}
local APPROACH_TIMEOUT = u.settings.queue_tuning.approach_timeout
-- _tile_key is defined once above (shared with the gather blacklist).

local function find_next_burner(surf, from, radius, per, blacklist, served)
  local es = surf.find_entities_filtered{position = from, radius = radius, type = FUEL_TYPES}
  table.sort(es, function(a, b) return u.distance(a.position, from) < u.distance(b.position, from) end)
  for _, e in ipairs(es) do
    local key = _tile_key(e.position)
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
  if storage.active_step and storage.active_step[cid] then
    return {error = "companion busy with an active task-pool step"}
  end
  storage.fuel_queues[cid] = {per = per or 20, radius = radius or 200, state = "find",
                              blacklist = {}, served = {}, fueled = 0, machines = 0}
  return {started = true, per = per or 20, radius = radius or 200}
end

function M.tick_fuel_queues()
  process_queue("fuel_queues", function(cid, q, c)
    local surf = c.entity.surface
    local inv = c.entity.get_main_inventory()

    if q.state == "done" then return false end

    if inv.get_item_count("coal") <= 0 then q.state = "done"; return false end   -- out of coal -> done

    if q.state == "find" then
      local e = find_next_burner(surf, c.entity.position, q.radius, q.per, q.blacklist, q.served)
      if not e then
        if next(q.served) then q.served = {}; return false end   -- round complete, some still need more -> new round
        q.state = "done"; return false                           -- truly nothing left to fuel -> done
      end
      q.target_pos = {x = e.position.x, y = e.position.y}
      q.target_key = _tile_key(e.position)
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
    q.state = "done"
    return false
  end)
end

function M.get_fuel_status(cid)
  local q = storage.fuel_queues[cid] or previous("fuel_queues", cid)
  if not q then return {active = false} end
  local bl = {}
  if q.blacklist then
    for k in pairs(q.blacklist) do bl[#bl + 1] = k end
  end
  if q.state == "done" then
    return {active = false, fueled = q.fueled, machines = q.machines, blacklist = bl}
  end
  return {active = not q._finished, state = q.state, error = q.error, fueled = q.fueled, machines = q.machines, blacklist = bl}
end

-- ============ CRAFT ============

function M.start_craft(cid, recipe, count)
  local c = valid_companion(cid)
  if not c then return {error = "Invalid companion"} end
  if storage.craft_queues[cid] or c.entity.crafting_queue_size > 0 then
    return {error = "Crafting is already active; wait for item_craft_status before starting another recipe"}
  end

  local proto = prototypes.recipe[recipe]
  if not proto then return {error = "Unknown recipe: " .. recipe} end

  local craftable = c.entity.get_craftable_count(recipe)
  if craftable < 1 then return {error = "Missing ingredients"} end

  local actual = math.min(count, craftable)
  local ticks = math.max(MIN_ACTION_TICKS, (proto.energy or 0.5) * 60)

  storage.craft_queues[cid] = {
    recipe = recipe,
    target = actual,
    crafted = 0,
    ticks_per = ticks,
    tick_start = game.tick
  }

  return {started = true, recipe = recipe, target = actual, ticks_per = ticks}
end

function M.tick_craft_queues()
  process_queue("craft_queues", function(cid, q, c)
    if q.inflight then
      if c.entity.crafting_queue_size > 0 then return false end
      q.crafted = q.crafted + q.inflight
      u.fire_craft_triggers(c.entity.force, q.recipe, q.inflight)
      q.inflight = nil
      if q.crafted >= q.target then return true end
    end
    local elapsed = game.tick - q.tick_start
    if elapsed < q.ticks_per then return false end

    local crafted = c.entity.begin_crafting{recipe = q.recipe, count = 1}
    if crafted < 1 then return true end
    q.inflight = crafted
    q.tick_start = game.tick
    return false
  end)
end

function M.get_craft_status(cid)
  local q = storage.craft_queues[cid] or previous("craft_queues", cid)
  if not q then return {active = false} end
  return {
    active = not q._finished,
    state = q.state, error = q.error,
    recipe = q.recipe,
    crafted = q.crafted,
    target = q.target,
    progress = q.state == "done" and 100 or math.min(99, math.floor((game.tick - q.tick_start) / q.ticks_per * 100))
  }
end

function M.stop_craft(cid)
  local q = storage.craft_queues[cid]
  local c = valid_companion(cid)
  local native = c and c.entity.crafting_queue_size > 0
  if c then u.cancel_native_crafting(c.entity) end
  M.cancel_queue("craft_queues", cid)
  return {stopped = q ~= nil or native or false, crafted = q and q.crafted or 0}
end

-- ============ BUILD ============

-- Entity types that block character movement (used for approach-position search).
-- These MUST be valid Factorio 2.0 prototype TYPE names, not entity names — a
-- single invalid string makes find_entities_filtered{type=...} raise and (without
-- the pcall in control.lua) would crash the whole tick scheduler. Notably:
-- steam-engine's type is "generator"; chests are "container"/"logistic-container".
local SOLID_TYPES = {
  "offshore-pump", "boiler", "generator", "pipe", "pipe-to-ground",
  "mining-drill", "furnace", "assembling-machine", "inserter",
  "transport-belt", "splitter", "underground-belt",
  "lab", "wall", "gate", "electric-pole", "container", "logistic-container",
  "storage-tank", "beacon", "radar", "solar-panel", "accumulator",
  "roboport", "pump", "cliff"
}

local function find_approach_pos(surf, char_pos, build_pos)
  local candidates = {}
  for _, dist in ipairs({5, 4, 6, 7}) do
    for _, angle in ipairs({0, 45, 90, 135, 180, 225, 270, 315}) do
      local rad = math.rad(angle)
      local p = {
        x = math.floor(build_pos.x + dist * math.sin(rad) + 0.5),
        y = math.floor(build_pos.y - dist * math.cos(rad) + 0.5)
      }
      local blocked = surf.find_entities_filtered{position = p, radius = 0.5, type = SOLID_TYPES}
      if #blocked == 0 then
        candidates[#candidates + 1] = {pos = p, dist = u.distance(char_pos, p)}
      end
    end
  end
  if #candidates > 0 then
    table.sort(candidates, function(a, b) return a.dist < b.dist end)
    return candidates[1].pos
  end
  return {x = build_pos.x, y = build_pos.y - 5}
end

local function clear_build_area(surf, entity_name, position, inv)
  local proto = prototypes.entity[entity_name]
  if not proto or not proto.collision_box then return end
  local bb = proto.collision_box
  local area = {
    {x = position.x + bb.left_top.x - 0.5, y = position.y + bb.left_top.y - 0.5},
    {x = position.x + bb.right_bottom.x + 0.5, y = position.y + bb.right_bottom.y + 0.5}
  }
  local obstacles = surf.find_entities_filtered{area = area, type = {"tree", "simple-entity"}}
  for _, obs in ipairs(obstacles) do
    if obs.valid then obs.mine{inventory = inv} end   -- MINE (wood/stone into inventory), not free-destroy
  end
end

local function step_away_distance(entity_name)
  local proto = prototypes.entity[entity_name]
  if not proto or not proto.collision_box then return 3 end
  local bb = proto.collision_box
  local hx = math.max(math.abs(bb.left_top.x), math.abs(bb.right_bottom.x)) + 0.5
  local hy = math.max(math.abs(bb.left_top.y), math.abs(bb.right_bottom.y)) + 0.5
  return math.sqrt(hx * hx + hy * hy) + 2
end

local MAX_SELF_COLLISION_STEP_AWAY = u.settings.queue_tuning.max_self_collision_step_away

-- Start a smart build: auto-approach + auto-clear + place
-- State machine: approaching -> clearing -> building -> done
function M.start_build(cid, entity_name, position, direction, mirror)
  local c = valid_companion(cid)
  if not c then return {error = "Invalid companion"} end

  local dir = direction or defines.direction.north
  local inv = c.entity.get_main_inventory()
  if inv.get_item_count(entity_name) < 1 then
    return {error = "No " .. entity_name .. " in inventory"}
  end

  -- Find safe approach position and start walking there
  local approach = find_approach_pos(c.entity.surface, c.entity.position, position)
  storage.walking_queues[cid] = {target = approach}

  storage.build_queues[cid] = {
    entity = entity_name,
    position = position,
    direction = dir,
    mirror = mirror or nil,
    approach = approach,
    state = "approaching",
    tick_start = game.tick,
    approach_deadline = u.approach_deadline(c.entity.position, approach),
  }

  return {started = true, entity = entity_name, position = position, state = "approaching"}
end

function M.tick_build_queues()
  process_queue("build_queues", function(cid, q, c)
    local surf = c.entity.surface
    local reach = c.entity.build_distance or 10

    if q.state == "done" or q.state == "failed" then return false end

    if q.state == "stepping_away" then
      local arrived = u.distance(c.entity.position, q.step_away_target) <= 1
      if arrived or game.tick >= q.step_away_deadline then
        storage.walking_queues[cid] = nil
        c.entity.walking_state = {walking = false}
        local approach = find_approach_pos(surf, c.entity.position, q.position)
        storage.walking_queues[cid] = {target = approach}
        q.approach = approach
        q.state = "approaching"
        q.approach_deadline = u.approach_deadline(c.entity.position, approach)
      end
      return false
    end

    -- APPROACHING: wait until character is within build reach of target
    if q.state == "approaching" then
      -- Nil-safe heal for a build_queues entry persisted by an OLDER mod version
      -- (before approach_deadline existed): give it a fresh deadline instead of
      -- either failing it instantly (bare "or 0" would make game.tick>=0 true on
      -- the very next check) or leaving it to hang forever (mirrors the identical
      -- fix already applied to belt_connect's own walking-with-deadline entries).
      if not q.approach_deadline then
        q.approach_deadline = u.approach_deadline(c.entity.position, q.position)
      end
      if u.distance(c.entity.position, q.position) <= reach then
        storage.walking_queues[cid] = nil
        c.entity.walking_state = {walking = false}
        q.state = "clearing"
      elseif game.tick >= q.approach_deadline then
        storage.walking_queues[cid] = nil
        c.entity.walking_state = {walking = false}
        q.failed = "cannot reach build target (" .. q.position.x .. "," .. q.position.y .. ")"
        q.state = "failed"
      end
      return false
    end

    -- CLEARING: remove trees/rocks from build footprint
    if q.state == "clearing" then
      clear_build_area(surf, q.entity, q.position, c.entity.get_main_inventory())
      q.state = "building"
      q.tick_start = game.tick
      q.collision_retry_deadline = nil
      return false
    end

    -- BUILDING: wait BUILD_TICKS then place
    if q.state == "building" then
      if game.tick - q.tick_start < BUILD_TICKS then return false end

      -- Re-check reach (companion may have drifted)
      if u.distance(c.entity.position, q.position) > reach then
        local approach = find_approach_pos(surf, c.entity.position, q.position)
        storage.walking_queues[cid] = {target = approach}
        q.approach = approach
        q.state = "approaching"
        return false
      end

      if not surf.can_place_entity{name = q.entity, position = q.position,
                                   direction = q.direction, force = c.entity.force,
                                   mirror = q.mirror} then
        q.collision_retry_deadline = q.collision_retry_deadline or (game.tick + 60)
        if game.tick < q.collision_retry_deadline then
          return false
        end
        local self_pos = {x = c.entity.position.x, y = c.entity.position.y}
        c.entity.teleport({x = self_pos.x + 10000, y = self_pos.y + 10000})
        local clear_without_self = surf.can_place_entity{name = q.entity, position = q.position,
                                     direction = q.direction, force = c.entity.force,
                                     mirror = q.mirror}
        c.entity.teleport(self_pos)
        q.self_collision_step_away_count = q.self_collision_step_away_count or 0
        if clear_without_self and q.self_collision_step_away_count < MAX_SELF_COLLISION_STEP_AWAY then
          q.self_collision_step_away_count = q.self_collision_step_away_count + 1
          local d = step_away_distance(q.entity)
          local step_away = {x = q.position.x + d, y = q.position.y + d}
          storage.walking_queues[cid] = {target = step_away}
          q.step_away_target = step_away
          q.state = "stepping_away"
          q.step_away_deadline = u.approach_deadline(c.entity.position, step_away)
          return false
        end
        local diag = u.dump_context(surf, q.position, {radius = 1.5, companion = c.entity})
        u.log_error(string.format(
          "build queue: Cannot place %s at (%.1f,%.1f) tile=%s after %d retry ticks " ..
          "(self_collision_clear=%s, step_away_attempts=%d) -- nearby: %s",
          q.entity, q.position.x, q.position.y, diag.tile, 60, tostring(clear_without_self),
          q.self_collision_step_away_count, table.concat(diag.nearby, ",")),
          "build_queue")
        q.failed = "Cannot place (collision)"
        q.state = "failed"
        return false
      end

      -- Re-check the item is STILL in inventory right before placing (it may have been consumed
      -- during the walk -- crafted away / dropped). Never create a building for free.
      if c.entity.get_main_inventory().get_item_count(q.entity) < 1 then
        q.failed = "No " .. q.entity .. " in inventory"
        q.state = "failed"
        return false
      end
      local placed = surf.create_entity{
        name = q.entity,
        position = q.position,
        direction = q.direction,
        force = c.entity.force,
        mirror = q.mirror
      }
      -- Only keep the building if a real item was actually consumed; else remove it (no free build).
      local destroyed = false
      if placed and c.entity.remove_item{name = q.entity, count = 1} < 1 then
        placed.destroy()
        destroyed = true
      end
      if not placed then
        q.failed = "create_entity returned nil"
        q.state = "failed"
        return false
      end
      if destroyed then
        q.failed = "item consumed before placement could complete"
        q.state = "failed"
        return false
      end
      q.placed_position = {x = placed.position.x, y = placed.position.y}
      q.state = "done"
      return false
    end

    return true
  end)
end

function M.get_build_status(cid)
  local q = storage.build_queues[cid] or previous("build_queues", cid)
  if not q then return {active = false} end
  if q.state == "done" then
    return {active = false, placed = true, position = q.placed_position}
  end
  if q.state == "failed" then
    return {active = false, placed = false, error = q.error or q.failed}
  end
  local progress = 0
  if q.state == "approaching" then progress = 10
  elseif q.state == "stepping_away" then progress = 55  -- self-collision fix, 2026-07-13
  elseif q.state == "clearing" then progress = 50
  elseif q.state == "building" then
    progress = 60 + math.floor((game.tick - q.tick_start) / BUILD_TICKS * 40)
  end
  return {
    active = not q._finished,
    entity = q.entity,
    position = q.position,
    state = q.state,
    error = q.error,
    progress = progress
  }
end

function M.stop_build(cid)
  if not storage.build_queues[cid] then return {stopped = false} end
  storage.walking_queues[cid] = nil
  storage.build_queues[cid] = nil
  return {stopped = true}
end

local UNDERGROUND_MAX_DISTANCE = u.settings.queue_tuning.underground_max_distance

local function step_dir(a, b)
  if b.x > a.x then return defines.direction.east end
  if b.x < a.x then return defines.direction.west end
  if b.y > a.y then return defines.direction.south end
  return defines.direction.north
end

function M.start_belt_connect(cid, from_pos, to_pos)
  local c = valid_companion(cid)
  if not c then return {error = "Invalid companion"} end
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

  storage.belt_queues[cid] = {path = path, idx = 1, tiles_placed = 0, state = "placing"}
  return {started = true, tiles = #path, need_belt = need_belt, need_underground = need_underground}
end

function M.tick_belt_queues()
  process_queue("belt_queues", function(cid, q, c)
    -- TERMINAL: sit here until get_belt_connect_status consumes+clears this entry (same
    -- fix as tick_build_queues -- otherwise a poll a moment after completion just sees
    -- plain "active:false", indistinguishable from success).
    if q.state == "done" or q.state == "failed" then return false end

    local surf = c.entity.surface
    local reach = c.entity.build_distance or 10
    local node = q.path[q.idx]
    if not node then q.state = "done"; return false end

    if u.distance(c.entity.position, {x = node.x, y = node.y}) > reach then
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
      q.state = "failed"; return false
    end
    -- `type` (input/output) is a create_entity-only field for underground belts, not a
    -- valid can_place_entity param -- keep the collision check's args separate so an
    -- unrecognized key can't make the check itself error or behave unexpectedly.
    if not surf.can_place_entity{name = item, position = pos, direction = node.dir, force = c.entity.force} then
      q.failed = "Cannot place " .. item .. " at (" .. node.x .. "," .. node.y .. ")"
      q.state = "failed"; return false
    end
    local create_args = {name = item, position = pos, direction = node.dir, force = c.entity.force}
    if node.underground then create_args.type = (node.underground == "entrance") and "input" or "output" end
    local placed = surf.create_entity(create_args)
    if not placed then
      q.failed = "create_entity returned nil"
      q.state = "failed"; return false
    end
    -- Never a free build: consume the real item, undo if it somehow isn't there anymore.
    if c.entity.remove_item{name = item, count = 1} < 1 then
      placed.destroy()
      q.failed = "item vanished before consuming"
      q.state = "failed"; return false
    end
    q.tiles_placed = q.tiles_placed + 1
    q.idx = q.idx + 1
    if q.idx > #q.path then q.state = "done" end
    return false
  end)
end

function M.get_belt_connect_status(cid)
  local q = storage.belt_queues[cid] or previous("belt_queues", cid)
  if not q then return {active = false} end
  if q.state == "done" then
    return {active = false, connected = true, tiles = q.tiles_placed}
  end
  if q.state == "failed" then
    return {active = false, connected = false, error = q.error or q.failed, tiles = q.tiles_placed}
  end
  return {active = not q._finished, state = q.state, error = q.error, tiles_placed = q.tiles_placed, tiles_total = #q.path}
end

function M.stop_belt_connect(cid)
  if not storage.belt_queues[cid] then return {stopped = false} end
  storage.walking_queues[cid] = nil
  storage.belt_queues[cid] = nil
  return {stopped = true}
end

-- ============ COMBAT ============

function M.start_combat(cid, target_pos)
  local c = valid_companion(cid)
  if not c then return {error = "Invalid companion"} end
  if storage.active_step and storage.active_step[cid] then
    return {error = "companion busy with an active task-pool step"}
  end

  local enemies = c.entity.surface.find_entities_filtered{
    position = target_pos,
    radius = 10,
    force = "enemy",
    type = {"unit", "unit-spawner"}
  }
  if #enemies == 0 then return {error = "No enemies"} end

  table.sort(enemies, function(a, b)
    return u.distance(a.position, c.entity.position) < u.distance(b.position, c.entity.position)
  end)

  storage.combat_queues[cid] = {
    targets = enemies,
    current = enemies[1],
    cooldown = 0,
    kills = 0
  }

  return {started = true, targets = #enemies}
end

function M.tick_combat_queues()
  process_queue("combat_queues", function(cid, q, c)
    if q.cooldown > 0 then
      q.cooldown = q.cooldown - TICK_INTERVAL
      return false
    end

    if not q.current or not q.current.valid then
      -- Find next valid target (build new list to avoid mutation during iteration)
      local valid_targets = {}
      for _, t in ipairs(q.targets) do
        if t.valid then valid_targets[#valid_targets + 1] = t end
      end
      q.targets = valid_targets

      if #q.targets == 0 then
        c.entity.shooting_state = {state = defines.shooting.not_shooting}
        return true
      end
      q.current = table.remove(q.targets, 1)
    end

    local dist = u.distance(c.entity.position, q.current.position)

    if dist <= ATTACK_RANGE then
      c.entity.shooting_state = {
        state = defines.shooting.shooting_enemies,
        position = q.current.position
      }
      q.cooldown = ATTACK_COOLDOWN
    else
      c.entity.shooting_state = {state = defines.shooting.not_shooting}
      local dir = u.get_direction(c.entity.position, q.current.position)
      if dir then c.entity.walking_state = {walking = true, direction = dir} end
    end
    return false
  end)
end

function M.get_combat_status(cid)
  local q = storage.combat_queues[cid] or previous("combat_queues", cid)
  if not q then return {active = false} end

  local remaining = #q.targets
  if q.current and q.current.valid then remaining = remaining + 1 end

  return {
    active = not q._finished,
    targets_remaining = remaining,
    state = q.state, error = q.error,
    current_target = q.current and q.current.valid and q.current.name or nil
  }
end

function M.stop_combat(cid)
  local q = storage.combat_queues[cid]
  if not q then return {stopped = false} end

  local c = valid_companion(cid)
  if c then
    c.entity.shooting_state = {state = defines.shooting.not_shooting}
    c.entity.walking_state = {walking = false}
  end

  storage.combat_queues[cid] = nil
  return {stopped = true}
end

return M
