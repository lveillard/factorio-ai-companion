local u = require("commands.init")
local ledger = require("commands.task_pool_ledger")
local queues = require("commands.queues")
local M = {}

function M.stop(cid)
  local stopped = {}
  for _, name in ipairs(u.settings.queues) do
    if queues.cancel_queue(name .. "_queues", cid) then stopped[#stopped + 1] = name end
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
    u.cancel_native_crafting(c.entity)
    c.entity.walking_state = {walking = false}
    c.entity.mining_state = {mining = false}
    c.entity.shooting_state = {state = defines.shooting.not_shooting}
  end
  return stopped
end

-- A pre-fix dead record has no readable entity context. Recover it only when
-- the world has one surface and one non-enemy/non-neutral force. Never infer
-- its home from the operator's current position, surface or selected companion.
local function legacy_context()
  local surface, force
  for _, candidate in pairs(game.surfaces) do
    if candidate.valid then
      if surface and surface ~= candidate then return nil end
      surface = candidate
    end
  end
  for _, candidate in pairs(game.forces) do
    if candidate.valid and candidate.name ~= "enemy" and candidate.name ~= "neutral" then
      if force and force ~= candidate then return nil end
      force = candidate
    end
  end
  return surface, force
end

function M.respawn(identifier)
  local id = tonumber(identifier)
  local c = id and storage.companions[id]
  if not c then return {error = "Existing companion ID required"} end
  if c.entity and c.entity.valid then return {id = id, error = "Companion is alive; respawn refused"} end
  storage.dead_companions = storage.dead_companions or {}
  storage.dead_companions[id] = storage.dead_companions[id] or game.tick
  -- Cancel before creating: no stale queue can craft/refund/move the new body.
  M.stop(id)
  if storage.walk_last_arrived then storage.walk_last_arrived[id] = nil end
  local surface, force
  if c.surface_index or c.force_index then
    surface = c.surface_index and game.surfaces[c.surface_index]
    force = c.force_index and game.forces[c.force_index]
  else
    surface, force = legacy_context()
  end
  if not surface or not surface.valid or not force or not force.valid then
    return {id = id, error = "Respawn surface/force unavailable or ambiguous; dead record retained"}
  end
  -- Persist legacy inference even on failure so later retries cannot switch homes.
  c.surface_index, c.force_index = surface.index, force.index
  local pos = surface.find_non_colliding_position("character", force.get_spawn_position(surface), 64, 0.5)
  if not pos then return {id = id, error = "No valid location near force spawn; dead record retained"} end
  local e = surface.create_entity{name = "character", position = pos, force = force}
  if not e or not e.valid then return {id = id, error = "Failed to create character at force spawn; dead record retained"} end
  -- Commit the new body before cosmetic work: even a render error must never
  -- leave an untracked character that a retry could duplicate. No kit/restoration.
  c.entity = e
  storage.dead_companions[id] = nil
  local ok, err = pcall(function()
    e.color = c.color or u.get_companion_color(id)
    if c.label and c.label.valid then c.label.destroy() end
    c.label = u.render_label(e, c.name or ("#" .. id), e.color)
  end)
  if not ok then u.log_error(err, "respawn_label") end
  return {id = id, respawned = true}
end

return M
