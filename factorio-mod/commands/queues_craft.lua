local u = require("commands.init")
local core = require("commands.queues_core")
local capabilities = require("commands.capabilities")

local M = {}

local MIN_ACTION_TICKS = u.settings.queue_tuning.min_action_ticks

function M.start_craft(cid, recipe, count)
  local c = core.valid_companion(cid)
  if not c then return {error = "Invalid companion"} end
  if storage.craft_queues[cid] or c.entity.crafting_queue_size > 0 then
    return {error = "Crafting is already active; wait for item_craft_status before starting another recipe"}
  end
  local error = capabilities.craft_error(c.entity,recipe)
  if error then return {error=error} end
  local proto = prototypes.recipe[recipe]
  local craftable = c.entity.get_craftable_count(recipe)
  if craftable < 1 then return {error = "Missing ingredients"} end
  local actual = math.min(count, craftable)
  local ticks = math.max(MIN_ACTION_TICKS, (proto.energy or 0.5) * 60)
  storage.craft_queues[cid] = {
    recipe = recipe,
    target = actual,
    crafted = 0,
    ticks_per = ticks,
    tick_start = game.tick,
    run_start_tick = game.tick,
  }
  return {started = true, recipe = recipe, target = actual, ticks_per = ticks}
end

function M.tick_craft_queues()
  core.process_queue("craft_queues", function(cid, q, c)
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
  local q = storage.craft_queues[cid] or core.previous("craft_queues", cid)
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
  local c = core.valid_companion(cid)
  local native = c and c.entity.crafting_queue_size > 0
  if c then u.cancel_native_crafting(c.entity) end
  core.cancel_queue("craft_queues", cid)
  return {stopped = q ~= nil or native or false, crafted = q and q.crafted or 0}
end

return M
