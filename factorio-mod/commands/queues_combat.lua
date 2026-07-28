-- AI Companion -- COMBAT queue (2026-07-19 size-refactor split out of queues.lua).
-- Fully self-contained: owns storage.combat_queues exclusively, no cross-section calls.

local u = require("commands.init")
local core = require("commands.queues_core")

local M = {}

local ATTACK_COOLDOWN = 15
local ATTACK_RANGE = 6

function M.start_combat(cid, target_pos)
  local c = core.valid_companion(cid)
  if not c then return {error = "Invalid companion"} end
  -- Ownership guard (2026-07-11, completing task #42 -- the other 4 async subsystems
  -- got this same guard 2026-07-08 in commit a885b21, "Extend walking_queues[cid]
  -- ownership guard to gather/fuel/build/belt_queues"; combat was missed then, found
  -- 2026-07-11 during an end-of-day stale-task audit. Currently dormant in production
  -- (no Python-side caller exists yet, auto_defend is set but never read), so this
  -- closes a real but not-yet-live gap before anything wires combat up and hits it.
  if storage.active_step and storage.active_step[cid] then
    return {error = "companion busy with an active task-pool step"}
  end

  local enemies = c.entity.surface.find_entities_filtered{
    position = target_pos,
    radius = 10,
    force = "enemy",
    type = {"unit", "unit-spawner"}
  }
  if #enemies == 0 then return {error = "No enemies"} end

  table.sort(enemies, function(a, b)
    return u.distance(a.position, c.entity.position) < u.distance(b.position, c.entity.position)
  end)

  storage.combat_queues[cid] = {
    targets = enemies,
    current = enemies[1],
    cooldown = 0,
    kills = 0,
    -- run_start_tick/run_end_tick (2026-07-28, action-timing instrumentation,
    -- batch 2): NOTE this domain has no "done"-freeze grace period (the
    -- completion return true below deletes the entry the SAME tick), same
    -- caveat as queues_harvest.lua/queues_craft.lua -- recorded anyway for
    -- consistency (this queue type is also currently dormant in production,
    -- no Python-side caller exists yet).
    run_start_tick = game.tick,
  }

  return {started = true, targets = #enemies}
end

function M.tick_combat_queues()
  core.process_queue("combat_queues", function(cid, q, c)
    if q.cooldown > 0 then
      q.cooldown = q.cooldown - core.TICK_INTERVAL
      return false
    end

    if not q.current or not q.current.valid then
      -- Find next valid target (build new list to avoid mutation during iteration)
      local valid_targets = {}
      for _, t in ipairs(q.targets) do
        if t.valid then valid_targets[#valid_targets + 1] = t end
      end
      q.targets = valid_targets

      if #q.targets == 0 then
        c.entity.shooting_state = {state = defines.shooting.not_shooting}
        q.run_end_tick = game.tick
        return true
      end
      q.current = table.remove(q.targets, 1)
    end

    local dist = u.distance(c.entity.position, q.current.position)

    if dist <= ATTACK_RANGE then
      c.entity.shooting_state = {
        state = defines.shooting.shooting_enemies,
        position = q.current.position
      }
      q.cooldown = ATTACK_COOLDOWN
    else
      c.entity.shooting_state = {state = defines.shooting.not_shooting}
      local dir = u.get_direction(c.entity.position, q.current.position)
      if dir then c.entity.walking_state = {walking = true, direction = dir} end
    end
    return false
  end)
end

function M.get_combat_status(cid)
  local q = storage.combat_queues[cid]
  if not q then return {active = false} end

  local remaining = #q.targets
  if q.current and q.current.valid then remaining = remaining + 1 end

  return {
    active = true,
    targets_remaining = remaining,
    current_target = q.current and q.current.valid and q.current.name or nil,
    run_start_tick = q.run_start_tick,
    run_end_tick = q.run_end_tick,
  }
end

function M.stop_combat(cid)
  local q = storage.combat_queues[cid]
  if not q then return {stopped = false} end

  local c = core.valid_companion(cid)
  if c then
    c.entity.shooting_state = {state = defines.shooting.not_shooting}
    c.entity.walking_state = {walking = false}
  end

  storage.combat_queues[cid] = nil
  return {stopped = true}
end

return M
