local u = require("commands.init")

local M = {}
function M.reservations(cid)
  storage.reserved[cid] = storage.reserved[cid] or {}
  return storage.reserved[cid]
end

local function derive_needs(steps, upto)
  local needs = {}
  for i = 1, math.min(upto or #steps, #steps) do
    local s = steps[i]
    if s.type == "place" then
      needs[s.entity] = (needs[s.entity] or 0) + 1
    elseif s.type == "fuel" then
      needs[s.item] = (needs[s.item] or 0) + (s.count or 1)
    elseif s.type == "remove" then
      needs[s.entity] = (needs[s.entity] or 0) - 1
    end
  end
  for item, count in pairs(needs) do
    if count <= 0 then needs[item] = nil end
  end
  return needs
end

local function release_reservations(t)
  local reserved = M.reservations(t.cid)
  for item, count in pairs(t.reserved or {}) do
    reserved[item] = math.max(0, (reserved[item] or 0) - count)
  end
  t.reserved = {}
end

function M.cancel_task(task_id)
  local t = storage.tasks[task_id]
  if not t or t.status ~= "active" then return end
  release_reservations(t)
  t.status = "cancelled"
  t.done_tick = game.tick
end

local function fail_task(task_id, reason)
  local t = storage.tasks[task_id]
  if not t or t.status ~= "active" then return end
  release_reservations(t)
  t.status = "failed"
  t.error = reason
  t.done_tick = game.tick
  u.log_error(string.format("task %d failed: %s", task_id, tostring(reason)), "task_pool")
end

local function complete_task(task_id)
  local t = storage.tasks[task_id]
  if not t or t.status ~= "active" then return end
  release_reservations(t)
  t.status = "done"
  t.done_tick = game.tick
end

function M.submit_task(cid, steps)
  local c = u.get_companion(cid)
  if not c then return {error = "Invalid companion"} end
  if not steps or #steps == 0 then return {error = "Empty step list"} end

  local needs = derive_needs(steps)
  local inv = c.entity.get_main_inventory()
  local task_reserved = {}
  local reserved = M.reservations(cid)
  local remaining_needs = {}
  for item, count in pairs(needs) do
    local have = inv.get_item_count(item)
    local already_reserved = reserved[item] or 0
    local available = math.max(0, have - already_reserved)
    local take = math.min(available, count)
    if take > 0 then
      reserved[item] = already_reserved + take
      task_reserved[item] = take
    end
    if take < count then
      remaining_needs[item] = count - take
    end
  end

  local task_id = storage.next_task_id
  storage.next_task_id = task_id + 1
  storage.tasks[task_id] = {
    cid = cid,
    steps = steps,
    cursor = 1,
    ctx = {},
    reserved = task_reserved,
    needs = remaining_needs,
    status = "active",
    created_tick = game.tick,
    step_ticks = {},
  }
  return {task_id = task_id, needs = remaining_needs}
end

function M.get_task_status(task_id)
  local t = storage.tasks[task_id]
  if not t then return {active = false} end
  return {
    active = t.status == "active",
    status = t.status,
    error = t.error,
    cursor = t.cursor,
    total_steps = #t.steps,
    needs = t.needs,
    ctx = t.ctx,  -- px/py/sx/sy/dir: useful for diagnosing placement failures externally
    created_tick = t.created_tick,
    done_tick = t.done_tick,
    step_ticks = t.step_ticks,
  }
end

M.derive_needs = derive_needs
M.fail_task = fail_task
M.complete_task = complete_task

return M
