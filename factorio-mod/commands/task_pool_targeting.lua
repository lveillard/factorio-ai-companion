local u = require("commands.init")

local ledger = require("commands.task_pool_ledger")

local M = {}

M.WALK_REACH = u.settings.task_tuning.walk_reach

function M.step_target_pos(t, step)
  if step.x and step.y then return {x = step.x, y = step.y} end
  if step.candidates and step.candidates[1] then
    return {x = step.candidates[1].x, y = step.candidates[1].y}
  end
  if step.ref and t.ctx.saved and t.ctx.saved[step.ref] then return t.ctx.saved[step.ref] end
  if step.type == "place" or step.type == "fuel" or step.type == "remove"
     or step.type == "read_drop_position" then
    if step.which == "primary" and t.ctx.px then return {x = t.ctx.px, y = t.ctx.py} end
    if step.which == "secondary" and t.ctx.sx then return {x = t.ctx.sx, y = t.ctx.sy} end
  end
  return nil
end

function M.task_ready(t)
  local needed_so_far = ledger.derive_needs(t.steps, t.cursor)
  for item, count in pairs(needed_so_far) do
    if (t.reserved[item] or 0) < count then
      return false
    end
  end
  return true
end

return M
