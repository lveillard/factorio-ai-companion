local u = require("commands.init")
local pathfind = require("commands.pathfind")
local core = require("commands.queues_core")

local M = {}

local UNDERGROUND_MAX_DISTANCE = u.settings.queue_tuning.underground_max_distance

local function step_dir(a, b)
  if b.x > a.x then return defines.direction.east end
  if b.x < a.x then return defines.direction.west end
  if b.y > a.y then return defines.direction.south end
  return defines.direction.north
end

function M.start_belt_connect(cid, from_pos, to_pos)
  local c = core.valid_companion(cid)
  if not c then return {error = "Invalid companion"} end
  if storage.active_step and storage.active_step[cid] then
    return {error = "companion busy with an active task-pool step"}
  end
  local surf = c.entity.surface
  local force = c.entity.force

  local path, reason = pathfind.find_path(surf, from_pos, to_pos, force)
  if not path then
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
    run_start_tick = game.tick}
  return {started = true, tiles = #path, need_belt = need_belt, need_underground = need_underground}
end

function M.tick_belt_queues()
  core.process_queue("belt_queues", function(cid, q, c)
    if q.state == "done" or q.state == "failed" then return false end

    local surf = c.entity.surface
    local reach = c.entity.build_distance or 10
    local node = q.path[q.idx]
    if not node then q.run_end_tick = game.tick; q.state = "done"; return false end

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
  local q = storage.belt_queues[cid] or core.previous("belt_queues", cid)
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

return M
