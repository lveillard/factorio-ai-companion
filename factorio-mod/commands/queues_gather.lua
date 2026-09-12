local u = require("commands.init")
local core = require("commands.queues_core")

local _tile_key = core.tile_key
local valid_companion = core.valid_companion
local process_queue = core.process_queue
local TICK_INTERVAL = core.TICK_INTERVAL
local MINE_ADJACENT_RANGE = core.MINE_ADJACENT_RANGE

local M = {}

local SELECT_FAIL_TICKS = u.settings.queue_tuning.select_fail_ticks

local MINE_STUCK_TICKS = u.settings.queue_tuning.mine_stuck_ticks

local MINE_DIAG_CAP = u.settings.queue_tuning.mine_diag_cap
local function _record_mine_diag(cid, sample)
  storage.mine_diag = storage.mine_diag or {}
  local buf = storage.mine_diag[cid]
  if not buf then buf = {}; storage.mine_diag[cid] = buf end
  buf[#buf + 1] = sample
  if #buf > MINE_DIAG_CAP then table.remove(buf, 1) end
end
function M.get_mine_diag(cid)
  storage.mine_diag = storage.mine_diag or {}
  return storage.mine_diag[cid] or {}
end

local NON_BUILDING_TYPES = {
  resource = true, character = true, tree = true, ["simple-entity"] = true,
  cliff = true, ["item-entity"] = true, ["item-request-proxy"] = true,
  unit = true, ["unit-spawner"] = true,
}
local function building_covers_tile(surf, position)
  for _, e in ipairs(surf.find_entities_filtered{position = position, radius = 1}) do
    if e.valid and not NON_BUILDING_TYPES[e.type] then return true end
  end
  return false
end

local function find_reachable_resource(surf, from, resource, blacklist)
  local ores = surf.find_entities_filtered{name = resource, position = from, radius = 400}
  table.sort(ores, function(a, b) return u.distance(a.position, from) < u.distance(b.position, from) end)
  for _, e in ipairs(ores) do
    if e.valid and (e.amount or 0) > 0
       and not (blacklist and blacklist[_tile_key(e.position)])
       and not building_covers_tile(surf, e.position)
       and surf.count_entities_filtered{type = "unit-spawner", position = e.position, radius = 20} == 0
       and surf.find_non_colliding_position("character", e.position, 2.5, 0.5) then
      return e
    end
  end
  local total = #ores
  local depleted, blacklisted, built_on, near_spawner, no_stand_pos = 0, 0, 0, 0, 0
  for _, e in ipairs(ores) do
    if e.valid then
      if (e.amount or 0) <= 0 then depleted = depleted + 1
      elseif blacklist and blacklist[_tile_key(e.position)] then blacklisted = blacklisted + 1
      elseif building_covers_tile(surf, e.position) then built_on = built_on + 1
      elseif surf.count_entities_filtered{type = "unit-spawner", position = e.position, radius = 20} > 0 then
        near_spawner = near_spawner + 1
      elseif not surf.find_non_colliding_position("character", e.position, 2.5, 0.5) then
        no_stand_pos = no_stand_pos + 1
      end
    end
  end
  u.log_error(string.format(
    "find_reachable_resource: no usable %s within 400 tiles of (%.1f,%.1f) -- total=%d "
    .. "depleted=%d blacklisted=%d built_on=%d near_spawner=%d no_stand_pos=%d",
    resource, from.x, from.y, total, depleted, blacklisted, built_on, near_spawner, no_stand_pos),
    "gather_queue")
  return nil
end

local SELECT_FAIL_RESPAWN_STREAK = u.settings.queue_tuning.select_fail_respawn_streak

local function respawn_companion_entity(cid, c)
  local old = c.entity
  if old.crafting_queue_size > 0 then return false end
  local new_pos = old.surface.find_non_colliding_position("character", old.position, 5, 0.5)
  if not new_pos then return false end
  -- Clone first to preserve every inventory, equipment grid and health; failure leaves the original intact.
  local replacement = old.clone{position=new_pos, create_build_effect_smoke=false}
  if not replacement then
    u.log_error("Could not replace stuck companion " .. cid, "gather_queue")
    return false
  end
  if c.label and c.label.valid then c.label.destroy() end
  old.destroy()
  c.entity = replacement
  replacement.mining_state, replacement.walking_state = {mining=false}, {walking=false}
  c.label = u.render_label(replacement, c.name, c.color)
  u.log_error("Replaced stuck companion " .. cid, "gather_queue")
  return true
end
core.register_respawn_fn(respawn_companion_entity)

function M.start_gather(cid, resource, count, exclude, from_task_pool)
  local c = valid_companion(cid)
  if not c then return {error = "Invalid companion"} end
  if not from_task_pool and storage.active_step and storage.active_step[cid] then
    return {error = "companion busy with an active task-pool step"}
  end
  local blacklist = {}
  if exclude then
    for _, p in ipairs(exclude) do
      blacklist[_tile_key(p)] = true
    end
  end
  storage.gather_queues[cid] = {resource = resource, target = count, state = "find",
    last_mine_tick = 0, blacklist = blacklist,
    run_start_tick = game.tick}
  return {started = true, resource = resource, target = count}
end

function M.tick_gather_queues()
  process_queue("gather_queues", function(cid, q, c)
    local surf = c.entity.surface
    local inv = c.entity.get_main_inventory()
    if q.state == "done" then return false end
    if q.state == "find" then
      local e = find_reachable_resource(surf, c.entity.position, q.resource, q.blacklist)
      if not e then
        q.find_retry_deadline = q.find_retry_deadline or (game.tick + 300)
        if game.tick < q.find_retry_deadline then return false end
        q.state, q.error = "failed", "No reachable resource remains before target was reached"
        return false
      end
      local mp = e.prototype.mineable_properties
      if not (mp and mp.products and mp.products[1]) then
        q.blacklist = q.blacklist or {}
        q.blacklist[_tile_key(e.position)] = true
        u.log_error("gather queue: resource '" .. q.resource .. "' at (" ..
          math.floor(e.position.x) .. "," .. math.floor(e.position.y) ..
          ") has no minable item product, skipping", "gather_queue")
        return false
      end
      q.entity_pos = {x = e.position.x, y = e.position.y}
      q.product = mp.products[1].name
      if not q.start_count then q.start_count = inv.get_item_count(q.product) end
      q.approach_deadline = u.approach_deadline(c.entity.position, e.position)
      storage.walking_queues[cid] = {target = surf.find_non_colliding_position("character", e.position, 1, 0.5) or e.position}
      q.state = "approach"
      storage.mine_diag = storage.mine_diag or {}
      storage.mine_diag[cid] = {}
      return false
    end
    if q.state == "approach" then
      local d_to_target = u.distance(c.entity.position, q.entity_pos)
      _record_mine_diag(cid, {
        t = game.tick, st = "approach", r = _tile_key(q.entity_pos), d = d_to_target,
        pos = {x = c.entity.position.x, y = c.entity.position.y},
        w = c.entity.walking_state and c.entity.walking_state.walking or false,
        dir = c.entity.walking_state and c.entity.walking_state.direction or false,
        sel = c.entity.selected and c.entity.selected.name or false,
        ti = inv.get_item_count(),
        g = q.product and (inv.get_item_count(q.product) - (q.start_count or 0)) or 0})
      if d_to_target <= MINE_ADJACENT_RANGE then
        storage.walking_queues[cid] = nil
        c.entity.walking_state = {walking = false}
        q.state = "mine"
      elseif game.tick >= (q.approach_deadline or 0) then   -- cannot reach this patch -> blacklist + try next
        if not q._approach_stall_respawned and respawn_companion_entity(cid, c) then
          q._approach_stall_respawned = true
          q.approach_deadline = u.approach_deadline(c.entity.position, q.entity_pos)
          u.log_error(string.format(
            "gather_queues approach_deadline: approach toward '%s' at (%.1f,%.1f) stalled " ..
            "for companion %d -- respawned its entity and retrying the SAME target once " ..
            "before blacklisting the whole neighborhood", q.resource,
            q.entity_pos.x, q.entity_pos.y, cid), "gather_queue")
          return false
        end
        q.blacklist = q.blacklist or {}
        q.blacklist[_tile_key(q.entity_pos)] = true
        storage.walking_queues[cid] = nil
        c.entity.walking_state = {walking = false}
        q.state = "find"
      end
      return false
    end
    if q.state == "mine" then
      local gathered = inv.get_item_count(q.product) - (q.start_count or 0)
      if gathered >= q.target then
        c.entity.mining_state = {mining = false}
        q.run_end_tick = game.tick
        q.state = "done"; return false   -- target met
      end
      if q.mine_gathered_at_entry == nil or gathered ~= q.mine_gathered_at_entry then
        q.mine_gathered_at_entry = gathered
        q.mine_stuck_ticks = 0
        q.mine_stuck_streak = 0   -- real progress -- any prior stuck-escalation streak no longer matters
      else
        q.mine_stuck_ticks = (q.mine_stuck_ticks or 0) + TICK_INTERVAL
      end
      local mine_diag_mining_before = c.entity.mining_state and c.entity.mining_state.mining or false
      local mine_diag_total_inv = inv.get_item_count()   -- same call process_queue's own staleness backstop uses
      local mine_diag_can_insert = inv.can_insert({name = q.product, count = 1})
      local mine_diag_pos = {x = c.entity.position.x, y = c.entity.position.y}
      local res, best_d
      local kept = q.last_res
      if kept and kept.valid and (kept.amount or 0) > 0
         and not building_covers_tile(surf, kept.position) then
        local d = u.distance(c.entity.position, kept.position)
        if d <= MINE_ADJACENT_RANGE then res, best_d = kept, d end
      end
      if not res then
        local candidates = surf.find_entities_filtered{name = q.resource, position = q.entity_pos, radius = 2}
        best_d = 1e18
        for _, e in ipairs(candidates) do
          if e.valid and (e.amount or 0) > 0 and not building_covers_tile(surf, e.position) then
            local d = u.distance(c.entity.position, e.position)
            if d < best_d then best_d, res = d, e end
          end
        end
      end
      if not res then
        c.entity.mining_state = {mining = false}
        q.select_fail_ticks = nil   -- leaving "mine" -- don't let a stale count leak into the next tile
        q.last_res = nil; q.last_res_key = nil
        q.state = "find"; return false   -- depleted -> next patch
      end
      if best_d > MINE_ADJACENT_RANGE then
        c.entity.mining_state = {mining = false}
        q.select_fail_ticks = nil
        q.last_res = nil; q.last_res_key = nil
        q.state = "find"; return false
      end
      local res_key = _tile_key(res.position)
      if q.last_res_key and q.last_res_key ~= res_key then
        u.log_error(string.format(
          "gather mine-state: selected entity changed mid-mine %s -> %s (best_d=%.2f, tick=%d)",
          q.last_res_key, res_key, best_d, game.tick), "gather_trace")
      end
      q.last_res_key = res_key
      q.last_res = res   -- hysteresis anchor for next tick, see the HYSTERESIS comment above
      if c.entity.selected ~= res then
        c.entity.selected = res
      end
      if c.entity.selected ~= res then
        q.select_fail_ticks = (q.select_fail_ticks or 0) + TICK_INTERVAL
        if q.select_fail_ticks > SELECT_FAIL_TICKS then
          local ore_bb = res.bounding_box
          local clear_area = {
            {x = ore_bb.left_top.x - 0.5, y = ore_bb.left_top.y - 0.5},
            {x = ore_bb.right_bottom.x + 0.5, y = ore_bb.right_bottom.y + 0.5}
          }
          local obstacles = surf.find_entities_filtered{
            area = clear_area, type = {"tree", "simple-entity"}}
          local cleared = 0
          for _, obs in ipairs(obstacles) do
            if obs.valid then
              obs.mine{inventory = c.entity.get_main_inventory()}
              cleared = cleared + 1
            end
          end
          if cleared > 0 then
            u.log_error(string.format(
              "gather mine-state: cleared %d tree/rock obstacle(s) near %s at %s -- " ..
              "retrying select instead of blacklisting", cleared, q.resource, res_key),
              "gather_queue")
            q.select_fail_ticks = 0
            return false
          end
          u.log_error(string.format(
            "gather mine-state: %s at %s never became selectable after %d ticks " ..
            "(best_d=%.2f) -- blacklisting, trying next patch",
            q.resource, res_key, q.select_fail_ticks, best_d), "gather_queue")
          q.blacklist = q.blacklist or {}
          local just_blacklisted = {_tile_key(res.position)}
          q.blacklist[just_blacklisted[1]] = true
          q.select_fail_ticks = nil
          q.last_res = nil; q.last_res_key = nil
          q.state = "find"
          q.select_fail_streak = (q.select_fail_streak or 0) + 1
          if q.select_fail_streak >= SELECT_FAIL_RESPAWN_STREAK then
            if respawn_companion_entity(cid, c) then
              for _, key in ipairs(just_blacklisted) do
                q.blacklist[key] = nil
              end
              inv = c.entity.get_main_inventory()
            end
            q.select_fail_streak = 0
          end
        end
        _record_mine_diag(cid, {
          t = game.tick, st = "mine", r = res_key, d = best_d,
          mb = mine_diag_mining_before,
          ma = c.entity.mining_state and c.entity.mining_state.mining or false,
          sel = c.entity.selected and c.entity.selected.name or false,
          selm = (c.entity.selected == res), w = c.entity.walking_state and c.entity.walking_state.walking or false,
          g = inv.get_item_count(q.product) - (q.start_count or 0), sft = q.select_fail_ticks or 0,
          ti = mine_diag_total_inv, ci = mine_diag_can_insert, mp = c.entity.mining_progress,
          pos = mine_diag_pos})
        return false
      end
      q.select_fail_ticks = nil
      q.select_fail_streak = 0
      if not c.entity.mining_state.mining then
        c.entity.mining_state = {mining = true, position = res.position}
      end
      if q.mine_stuck_ticks > MINE_STUCK_TICKS then
        u.log_error(string.format(
          "gather mine-state: %s at %s selected+mining but gathered=%d for %d ticks " ..
          "(target=%d, best_d=%.2f) -- blacklisting, trying next patch (MINE_STUCK_TICKS)",
          q.resource, res_key, gathered, q.mine_stuck_ticks, q.target, best_d), "gather_queue")
        c.entity.mining_state = {mining = false}
        q.blacklist = q.blacklist or {}
        local just_blacklisted = {_tile_key(res.position)}
        q.blacklist[just_blacklisted[1]] = true
        q.mine_stuck_ticks = 0
        q.mine_gathered_at_entry = nil
        q.last_res = nil; q.last_res_key = nil
        q.state = "find"
        q.mine_stuck_streak = (q.mine_stuck_streak or 0) + 1
        if q.mine_stuck_streak >= SELECT_FAIL_RESPAWN_STREAK then
          if respawn_companion_entity(cid, c) then
            for _, key in ipairs(just_blacklisted) do
              q.blacklist[key] = nil
            end
            inv = c.entity.get_main_inventory()
          end
          q.mine_stuck_streak = 0
        end
        return false
      end
      _record_mine_diag(cid, {
        t = game.tick, st = "mine", r = res_key, d = best_d,
        mb = mine_diag_mining_before,
        ma = c.entity.mining_state and c.entity.mining_state.mining or false,
        sel = c.entity.selected and c.entity.selected.name or false,
        selm = (c.entity.selected == res), w = c.entity.walking_state and c.entity.walking_state.walking or false,
        g = inv.get_item_count(q.product) - (q.start_count or 0), sft = 0,
        ti = mine_diag_total_inv, ci = mine_diag_can_insert, mp = c.entity.mining_progress,
        pos = mine_diag_pos})
      return false
    end
    return true
  end)
end

function M.debug_respawn_entity(cid)
  local c = valid_companion(cid)
  if not c then return {error = "Invalid companion"} end
  local ok = respawn_companion_entity(cid, c)
  return {respawned = ok}
end

function M.get_gather_status(cid)
  local q = storage.gather_queues[cid] or core.previous("gather_queues", cid)
  if not q then return {active = false} end
  local c = valid_companion(cid)
  local have = q.gathered or (c and q.product) and c.entity.get_main_inventory().get_item_count(q.product) - (q.start_count or 0) or 0
  local bl = {}
  if q.blacklist then
    for k in pairs(q.blacklist) do bl[#bl + 1] = k end
  end
  local selected_name, mining = nil, nil
  if c then
    selected_name = c.entity.selected and c.entity.selected.name or nil
    mining = c.entity.mining_state and c.entity.mining_state.mining or false
  end
  if q.state == "done" then
    return {active = false, resource = q.resource, target = q.target, gathered = have,
      blacklist = bl, entity_pos = q.entity_pos,
      selected = selected_name, mining_state_mining = mining,
      run_start_tick = q.run_start_tick, run_end_tick = q.run_end_tick}
  end
  return {active = not q._finished, resource = q.resource, target = q.target, gathered = have,
    state = q.state, error = q.error, blacklist = bl, entity_pos = q.entity_pos,
    selected = selected_name, mining_state_mining = mining}
end

return M
