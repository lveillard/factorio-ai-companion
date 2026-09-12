local u = require("commands.init")
local core = require("commands.queues_core")
local M = {cancel_queue = core.cancel_queue}

for _, queue in ipairs(u.settings.queues) do
  if queue ~= "walking" then
    local queue_name = queue .. "_queues"
    for name, method in pairs(require("commands.queues_" .. queue)) do
      if name:match("^get_.+_status$") then
        M[name] = function(cid)
          local result = method(cid)
          local q = storage[queue_name][cid] or core.previous(queue_name, cid)
          if q then
            result.run_start_tick, result.run_end_tick = q.run_start_tick, q.run_end_tick
          end
          return result
        end
      else M[name] = method end
    end
  end
end

function M.init()
  storage.queue_results = storage.queue_results or {}
  for _, name in ipairs(u.settings.queues) do
    storage[name .. "_queues"] = storage[name .. "_queues"] or {}
  end
  storage.mine_diag = storage.mine_diag or {}
end

return M
