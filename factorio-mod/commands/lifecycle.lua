local u = require("commands.init")
local ledger = require("commands.task_pool_ledger")
local M = {}

function M.stop(cid)
  local stopped = {}
  for _, name in ipairs(u.settings.queues) do
    local queue = storage[name .. "_queues"]
    if queue and queue[cid] then queue[cid] = nil; stopped[#stopped + 1] = name end
    if storage.queue_results and storage.queue_results[name .. "_queues"] then storage.queue_results[name .. "_queues"][cid] = nil end
  end
  for task_id, task in pairs(storage.tasks or {}) do
    if task.cid == cid and task.status == "active" then
      ledger.cancel_task(task_id)
      stopped[#stopped + 1] = "task:" .. task_id
    end
  end
  if storage.active_step then storage.active_step[cid] = nil end
  if storage.walk_last_outcome then storage.walk_last_outcome[cid] = nil end
  for request_id, owner in pairs(storage.path_requests or {}) do
    if owner == cid then storage.path_requests[request_id] = nil end
  end
  local c = u.get_companion(cid)
  if c then
    c.entity.walking_state = {walking = false}
    c.entity.mining_state = {mining = false}
    c.entity.shooting_state = {state = defines.shooting.not_shooting}
  end
  return stopped
end

return M
