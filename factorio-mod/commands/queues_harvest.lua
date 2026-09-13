local u = require("commands.init")
local core = require("commands.queues_core")

local TICK_INTERVAL = core.TICK_INTERVAL
local MINE_ADJACENT_RANGE = core.MINE_ADJACENT_RANGE
local valid_companion = core.valid_companion
local process_queue = core.process_queue

local M = {}

local MINING_RANGE = u.settings.queue_tuning.mining_range

function M.start_harvest(cid, position, target_count, resource_name)
  local c = valid_companion(cid)
  if not c then return {error = "Invalid companion"} end
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
    product = product,
    run_start_tick = game.tick,
  }

  M.start_mining_next(cid)
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
    if q.harvested >= q.target then
      c.entity.mining_state = {mining = false}
      q.run_end_tick = game.tick
      return true
    end
    if u.distance(c.entity.position, q.position) > MINING_RANGE then
      c.entity.mining_state = {mining = false}
      q.run_end_tick = game.tick
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
        u.rare_symptom_save("RARE-MINE-01")
        q.run_end_tick = game.tick
        return true
      end
      return false   -- fresh candidate selected -- re-check adjacency/progress next tick
    end

    q.stale_ticks = (q.last_harvested == q.harvested) and (q.stale_ticks or 0) + TICK_INTERVAL or 0
    q.last_harvested = q.harvested
    if q.stale_ticks > 600 then
      c.entity.mining_state = {mining = false}
      u.log_error(string.format(
        "harvest queue for companion %d ended short (%d/%d %s): no progress for %d ticks despite " ..
        "passing all reachability checks -- unknown stall", cid, q.harvested, q.target,
        q.resource_name or "?", q.stale_ticks), "harvest_queue")
      q.run_end_tick = game.tick
      return true
    end

    local inv = c.entity.get_main_inventory()
    local now_count = q.product and inv.get_item_count(q.product) or inv.get_item_count()
    if q.last_inv_count == nil then q.last_inv_count = now_count end
    local gained = now_count - q.last_inv_count
    if gained > 0 then
      q.harvested = q.harvested + gained
    end
    q.last_inv_count = now_count
    local cur = q.current and q.current.entity
    if not (cur and cur.valid) then
      if #q.entities > 0 and q.entities[1] == cur then table.remove(q.entities, 1) end
      if not M.start_mining_next(cid) then
        c.entity.mining_state = {mining = false}
        if q.harvested < q.target then
          u.log_error(string.format(
            "harvest queue for companion %d ended short (%d/%d %s): entities exhausted, " ..
            "possible full inventory (mined items spilled to ground)",
            cid, q.harvested, q.target, q.resource_name or "?"), "harvest_queue")
        end
        q.run_end_tick = game.tick
        return true
      end
    end

    local done = q.harvested >= q.target
    if done then q.run_end_tick = game.tick end
    return done
  end)
end

function M.get_harvest_status(cid)
  local q = storage.harvest_queues[cid] or core.previous("harvest_queues", cid)
  if not q then return {active = false} end
  return {
    active = not q._finished,
    state = q.state, error = q.error,
    harvested = q.harvested,
    target = q.target,
    remaining = #q.entities,
    mining = q.current ~= nil,
    run_start_tick = q.run_start_tick,
    run_end_tick = q.run_end_tick,
  }
end

function M.stop_harvest(cid)
  local q = storage.harvest_queues[cid]
  if not q then return {stopped = false} end
  local c = valid_companion(cid)
  if c then c.entity.mining_state = {mining = false} end
  local harvested = q.harvested
  core.cancel_queue("harvest_queues", cid)
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

return M
