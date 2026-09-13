local u = require("commands.init")

local M = {}
local resources = require("commands.resource_query")
local cleanups = {}
function M.register_cleanup(queue, fn) cleanups[queue]=fn end

function M.previous(queue_name, cid)
  return storage.queue_results[queue_name] and storage.queue_results[queue_name][cid]
end
function M.finish_queue(queue_name, cid, q)
  if cleanups[queue_name] then cleanups[queue_name](q) end
  q._finished = true
  q.finished_tick = game.tick
  q.run_end_tick = q.run_end_tick or game.tick
  q.error = q.error or q.failed
  if q.product and q.start_count then
    local c = u.get_companion(cid)
    q.gathered = c and c.entity.get_main_inventory().get_item_count(q.product) - q.start_count or 0
  end
  if q.state ~= "cancelled" and q.state ~= "failed" then
    local produced = q.gathered or q.harvested or q.crafted
    if q.failed or (type(q.target) == "number" and produced and produced < q.target) then
      q.state = "failed"
      q.error = q.error or "Job ended before the requested amount was produced"
    else q.state = "done" end
  end
  if queue_name ~= "craft_queues" and (q.state == "failed" or q.state == "cancelled") then
    local c = u.get_companion(cid)
    if c then c.entity.walking_state, c.entity.mining_state = {walking=false}, {mining=false} end
    storage.walking_queues[cid] = nil
  end
  storage.queue_results[queue_name] = storage.queue_results[queue_name] or {}
  storage.queue_results[queue_name][cid] = q
  storage[queue_name][cid] = nil
end
function M.cancel_queue(queue_name, cid)
  local q = storage[queue_name] and storage[queue_name][cid]
  if not q then return false end
  q.state, q.error = "cancelled", "Cancelled by a new command or stop request"
  M.finish_queue(queue_name, cid, q)
  return true
end

M.TICK_INTERVAL = u.settings.queue_tuning.tick_interval

M.MINE_ADJACENT_RANGE = u.settings.queue_tuning.mine_adjacent_range

function M.tile_key(pos) return math.floor(pos.x) .. "," .. math.floor(pos.y) end
local UNIVERSAL_STALE_TICKS = u.settings.queue_tuning.universal_stale_ticks

local _respawn_fn = nil
function M.register_respawn_fn(fn)
  _respawn_fn = fn
end
local function try_respawn(cid, c)
  if not _respawn_fn then return false end
  return _respawn_fn(cid, c)
end
function M.valid_companion(id)
  local c = u.get_companion(id)
  return c and c.entity and c.entity.valid and c
end
function M.process_queue(queue_name, processor)
  local queues = storage[queue_name]
  if not queues then return end
  local to_remove = {}
  for cid, q in pairs(queues) do
    local c = M.valid_companion(cid)
    if q.state == "done" or q.state == "failed" then
      to_remove[#to_remove + 1] = cid
    elseif not c then
      q.state, q.error = "failed", "Companion is no longer available"
      to_remove[#to_remove + 1] = cid
    else
      local total = c.entity.get_inventory(defines.inventory.character_main).get_item_count()
      local pos = c.entity.position
      local moved = q._stale_pos and (u.distance(q._stale_pos, pos) > 5)
      if q.manages_timeout or (queue_name == "build_queues" and q.state == "stepping_away") or
        (queue_name == "craft_queues" and q.inflight and c.entity.crafting_queue_size > 0) then
        q._stale_total, q._stale_pos, q._stale_ticks = total, {x = pos.x, y = pos.y}, 0
      elseif q._stale_total == total and q._stale_pos and not moved then
        q._stale_ticks = (q._stale_ticks or 0) + M.TICK_INTERVAL
      else
        q._stale_total = total
        q._stale_pos = {x = pos.x, y = pos.y}
        q._stale_ticks = 0
      end
      if q._stale_ticks > UNIVERSAL_STALE_TICKS and q.state == "done" then
      elseif q._stale_ticks > UNIVERSAL_STALE_TICKS then
        local function fmt_maybe_pos(v)
          if type(v) == "table" and v.x and v.y then
            return string.format("(%.1f,%.1f)", v.x, v.y)
          end
          return tostring(v)
        end
        u.log_error(string.format(
          "%s queue for companion %d force-stopped: neither inventory count nor " ..
          "position changed in %d ticks -- no real progress regardless of queue-" ..
          "specific state -- stuck_at=(%.1f,%.1f) queue_state=%s entity_pos=%s target=%s",
          queue_name, cid, q._stale_ticks, pos.x, pos.y, tostring(q.state),
          fmt_maybe_pos(q.entity_pos), fmt_maybe_pos(q.target)),
          queue_name)
        local recovered_via_respawn = false
        if queue_name == "gather_queues" and q.state == "approach" and q.entity_pos and q.resource then
          if not q._approach_stall_respawned and try_respawn(cid, c) then
            q._approach_stall_respawned = true
            recovered_via_respawn = true
            q.approach_deadline = u.approach_deadline(c.entity.position, q.entity_pos)
            q._stale_total, q._stale_pos, q._stale_ticks = nil, nil, 0
            u.log_error(string.format(
              "gather_queues generic-backstop: approach toward '%s' at (%.1f,%.1f) stalled " ..
              "for companion %d -- respawned its entity and retrying the SAME target once " ..
              "before blacklisting the whole neighborhood", q.resource,
              q.entity_pos.x, q.entity_pos.y, cid), "gather_queue")
          else
            q.blacklist = q.blacklist or {}
            local added = 0
            for _, e in ipairs(resources.within(c.entity.surface, q.entity_pos, q.selector, 15)) do
              local key = math.floor(e.position.x) .. "," .. math.floor(e.position.y)
              if not q.blacklist[key] then added = added + 1 end
              q.blacklist[key] = true
            end
            u.log_error(string.format(
              "gather_queues generic-backstop recovery: blacklisted %d tile(s) of '%s' " ..
              "around entity_pos (%.1f,%.1f) before force-stop -- its own approach_deadline " ..
              "(tick %s) never got a chance to run (this generic backstop fires at " ..
              "%d ticks, always sooner)%s", added, q.resource,
              q.entity_pos.x, q.entity_pos.y, tostring(q.approach_deadline), UNIVERSAL_STALE_TICKS,
              q._approach_stall_respawned and " (after an earlier respawn-retry also stalled)" or ""),
              "gather_queue")
          end
        elseif queue_name == "gather_queues" and q.state == "mine" and q.entity_pos and q.resource then
          q.blacklist = q.blacklist or {}
          local added = 0
          for _, e in ipairs(resources.within(c.entity.surface, q.entity_pos, q.selector, 15)) do
            local key = math.floor(e.position.x) .. "," .. math.floor(e.position.y)
            if not q.blacklist[key] then added = added + 1 end
            q.blacklist[key] = true
          end
          u.log_error(string.format(
            "gather_queues generic-backstop recovery (mine state): blacklisted %d " ..
            "tile(s) of '%s' around entity_pos (%.1f,%.1f) before force-stop -- " ..
            "queues_gather.lua's own MINE_STUCK_TICKS never got a chance to recover " ..
            "this stall (MINE_STUCK_TICKS is a queues_gather.lua-local, not visible " ..
            "here -- this module loads before it, see this file's own Registration " ..
            "indirection comment above)",
            added, q.resource, q.entity_pos.x, q.entity_pos.y),
            "gather_queue")
        elseif queue_name == "fuel_queues" and q.state == "approach" and q.target_key then
          q.blacklist = q.blacklist or {}
          local was_new = not q.blacklist[q.target_key]
          q.blacklist[q.target_key] = true
          u.log_error(string.format(
            "fuel_queues generic-backstop recovery: blacklisted target_key=%s before " ..
            "force-stop%s -- approach_deadline never got a chance to run",
            q.target_key, was_new and "" or " (already blacklisted)"), "fuel_queue")
        end
        if not recovered_via_respawn then
          c.entity.mining_state = {mining = false}
          c.entity.walking_state = {walking = false}
          q.state, q.error = "failed", "No inventory or movement progress before timeout"
          to_remove[#to_remove + 1] = cid
        end
      else
        local ok, should_remove = pcall(processor, cid, q, c)
        if not ok then
          q.state, q.error = "failed", tostring(should_remove)
          c.entity.mining_state, c.entity.walking_state = {mining=false}, {walking=false}
          storage.walking_queues[cid] = nil
          if queue_name == "craft_queues" then u.cancel_native_crafting(c.entity) end
          u.log_error(q.error, queue_name .. " companion " .. cid)
        end
        if not ok or should_remove or q.state == "done" or q.state == "failed" then to_remove[#to_remove + 1] = cid end
      end
    end
  end
  for _, cid in ipairs(to_remove) do if queues[cid] then M.finish_queue(queue_name, cid, queues[cid]) end end
end

return M
