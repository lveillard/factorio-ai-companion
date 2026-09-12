local u = require("commands.init")
local task_pool = require("commands.task_pool")

u.register("task_submit", function(args)
  u.safe_command(function()
    local id, c = u.find_companion(args.companionId)
    if not id then u.not_found(); return end
    local result = task_pool.submit_task(id, args.steps)
    result.id = id
    u.json_response(result)
  end)
end)

u.register("task_status", function(args)
  u.safe_command(function()
    u.json_response(task_pool.get_task_status(args.taskId))
  end)
end)

u.register("task_pool_diag", function(args)
  u.safe_command(function()
    local id = u.find_companion(args.companionId)
    if not id then u.not_found(); return end
    u.json_response(task_pool.get_diag(id))
  end)
end)
