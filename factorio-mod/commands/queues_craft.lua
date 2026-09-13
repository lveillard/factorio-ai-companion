-- AI Companion -- CRAFT queue (2026-07-19 size-refactor split out of queues.lua).
-- Fully self-contained: owns storage.craft_queues exclusively, no cross-section calls.

local u = require("commands.init")
local core = require("commands.queues_core")

local M = {}

local MIN_ACTION_TICKS = 30

function M.start_craft(cid, recipe, count)
  local c = core.valid_companion(cid)
  if not c then return {error = "Invalid companion"} end

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
    tick_start = game.tick,
    -- run_start_tick (2026-07-28, action-timing instrumentation, batch 2): a
    -- SEPARATE field from tick_start, which this domain already reuses/resets
    -- on every individual craft repetition to drive get_craft_status's own
    -- 0-100% progress bar -- unusable as a stable whole-run marker, hence the
    -- new name. NOTE: this domain has no "done"-freeze grace period (both
    -- return-true sites in tick_craft_queues below delete the entry the SAME
    -- tick), so run_end_tick (set right before each) is only externally
    -- observable if a status poll happens to land in that exact tick --
    -- essentially never via a real RCON poll loop, same caveat as
    -- queues_harvest.lua. Recorded anyway for consistency; Python's own
    -- end-of-call wall-clock capture (batch 4) covers the real completion
    -- moment regardless.
    run_start_tick = game.tick,
  }

  return {started = true, recipe = recipe, target = actual, ticks_per = ticks}
end

function M.tick_craft_queues()
  core.process_queue("craft_queues", function(cid, q, c)
    local elapsed = game.tick - q.tick_start
    if elapsed < q.ticks_per then return false end

    local crafted = c.entity.begin_crafting{recipe = q.recipe, count = 1}
    if crafted < 1 then
      q.run_end_tick = game.tick
      return true
    end
    -- headless: fire craft-item research triggers the scripted craft would otherwise miss
    u.fire_craft_triggers(c.entity.force, q.recipe, crafted)

    q.crafted = q.crafted + 1
    q.tick_start = game.tick
    local done = q.crafted >= q.target
    if done then q.run_end_tick = game.tick end
    return done
  end)
end

function M.get_craft_status(cid)
  local q = storage.craft_queues[cid]
  if not q then return {active = false} end
  return {
    active = true,
    recipe = q.recipe,
    crafted = q.crafted,
    target = q.target,
    progress = math.floor((game.tick - q.tick_start) / q.ticks_per * 100),
    run_start_tick = q.run_start_tick,
    run_end_tick = q.run_end_tick,
  }
end

function M.stop_craft(cid)
  local q = storage.craft_queues[cid]
  if not q then return {stopped = false} end
  local crafted = q.crafted
  storage.craft_queues[cid] = nil
  return {stopped = true, crafted = crafted}
end

return M
