local u = require("commands.init")
local core = require("commands.queues_core")

local valid_companion = core.valid_companion
local process_queue = core.process_queue

local M = {}

local BUILD_TICKS = u.settings.queue_tuning.build_ticks

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
  for _, it in ipairs(surf.find_entities_filtered{area = area, type = "item-entity"}) do
    if it.valid and it.stack and it.stack.valid_for_read then
      local moved = inv.insert(it.stack)
      if moved >= it.stack.count then it.destroy() end
    end
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
function M.start_build(cid, entity_name, position, direction, mirror)
  local c = valid_companion(cid)
  if not c then return {error = "Invalid companion"} end

  local dir = direction or defines.direction.north
  local inv = c.entity.get_main_inventory()
  if inv.get_item_count(entity_name) < 1 then
    return {error = "No " .. entity_name .. " in inventory"}
  end
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
    run_start_tick = game.tick,
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
    if q.state == "approaching" then
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
        q.run_end_tick = game.tick
        q.state = "failed"
      end
      return false
    end
    if q.state == "clearing" then
      clear_build_area(surf, q.entity, q.position, c.entity.get_main_inventory())
      q.state = "building"
      q.tick_start = game.tick
      q.collision_retry_deadline = nil
      return false
    end
    if q.state == "building" then
      if game.tick - q.tick_start < BUILD_TICKS then return false end
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
          clear_build_area(surf, q.entity, q.position, c.entity.get_main_inventory())
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
        q.run_end_tick = game.tick
        q.state = "failed"
        return false
      end
      if c.entity.get_main_inventory().get_item_count(q.entity) < 1 then
        q.failed = "No " .. q.entity .. " in inventory"
        q.run_end_tick = game.tick
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
      local destroyed = false
      if placed and c.entity.remove_item{name = q.entity, count = 1} < 1 then
        placed.destroy()
        destroyed = true
      end
      if not placed then
        q.failed = "create_entity returned nil"
        q.run_end_tick = game.tick
        q.state = "failed"
        return false
      end
      if destroyed then
        q.failed = "item consumed before placement could complete"
        q.run_end_tick = game.tick
        q.state = "failed"
        return false
      end
      q.placed_position = {x = placed.position.x, y = placed.position.y}
      q.run_end_tick = game.tick
      q.state = "done"
      return false
    end

    q.run_end_tick = game.tick
    return true
  end)
end

function M.get_build_status(cid)
  local q = storage.build_queues[cid] or core.previous("build_queues", cid)
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

return M
