local u = require("commands.init")
local queues = require("commands.queues")
local ledger = require("commands.task_pool_ledger")
local ensure_item = require("commands.task_pool_ensure_item")
local targeting = require("commands.task_pool_targeting")
local steps = require("commands.task_pool_steps")

local M = {}

local FUEL_REACH = u.settings.task_tuning.fuel_reach
local WALK_REACH = targeting.WALK_REACH
local step_target_pos = targeting.step_target_pos
local task_ready = targeting.task_ready
local run_read_drop_position = steps.run_read_drop_position
local run_find_existing = steps.run_find_existing
local run_set_position = steps.run_set_position
local run_find_patch = steps.run_find_patch
local run_verify_tile = steps.run_verify_tile
local run_pick_orientation = steps.run_pick_orientation

local WOOD_CHOP_REACH = u.settings.task_tuning.wood_chop_reach

function M.init()
  storage.tasks = storage.tasks or {}
  storage.next_task_id = storage.next_task_id or 1
  storage.reserved = storage.reserved or {}
  storage.active_step = storage.active_step or {}
end

M.submit_task = ledger.submit_task
M.get_task_status = ledger.get_task_status
local function pick_next(cid, c)
  local best_task_id, best_dist = nil, math.huge
  for task_id, t in pairs(storage.tasks) do
    if t.cid == cid and t.status == "active" and task_ready(t) and t.cursor <= #t.steps then
      local step = t.steps[t.cursor]
      local pos = step_target_pos(t, step)
      local dist = pos and u.distance(c.entity.position, pos) or 0  -- instant steps: distance 0, always win ties by task_id
      if dist < best_dist or (dist == best_dist and (not best_task_id or task_id < best_task_id)) then
        best_task_id, best_dist = task_id, dist
      end
    end
  end
  return best_task_id
end

local TASK_NEEDS_UNMET_GIVEUP_TICKS = u.settings.task_tuning.needs_unmet_giveup_ticks  -- 100 game-seconds @ 60 ticks/s

local function refresh_needs()
  local ids = {}
  for task_id, task in pairs(storage.tasks) do
    if task.status == "active" then ids[#ids + 1] = task_id end
  end
  table.sort(ids)
  for _, task_id in ipairs(ids) do
    local t = storage.tasks[task_id]
    local c = u.get_companion(t.cid)
    if c then
      local inv, reserved = c.entity.get_main_inventory(), ledger.reservations(t.cid)
      for item, deficit in pairs(t.needs) do
        local take = math.min(math.max(0, inv.get_item_count(item) - (reserved[item] or 0)), deficit)
        if take > 0 then
          reserved[item] = (reserved[item] or 0) + take
          t.reserved[item] = (t.reserved[item] or 0) + take
          if take >= deficit then t.needs[item] = nil else t.needs[item] = deficit - take end
        end
      end
    end
    if task_ready(t) then t.needs_unmet_since = nil
    else
      t.needs_unmet_since = t.needs_unmet_since or game.tick
      if game.tick - t.needs_unmet_since >= TASK_NEEDS_UNMET_GIVEUP_TICKS then
        local missing = {}
        for item, count in pairs(t.needs) do missing[#missing + 1] = item .. "x" .. count end
        ledger.fail_task(task_id, "Missing materials: " .. table.concat(missing, ", "))
      end
    end
  end
end

local function busy_elsewhere(cid)
  return (storage.gather_queues and storage.gather_queues[cid])
      or (storage.fuel_queues and storage.fuel_queues[cid])
      or (storage.build_queues and storage.build_queues[cid])
      or (storage.belt_queues and storage.belt_queues[cid])
end

function M.tick()
  refresh_needs()
  for cid, active in pairs(storage.active_step) do
    local c = u.get_companion(cid)
    if not c then storage.active_step[cid] = nil; goto continue end
    local t = storage.tasks[active.task_id]
    if not t or t.status ~= "active" then storage.active_step[cid] = nil; goto continue end
    local step = t.steps[t.cursor]

    if active.state == "walking" then
      if not storage.walking_queues[cid] then
        active.state = "acting"
      elseif active.approach_deadline and game.tick >= active.approach_deadline then
        storage.walking_queues[cid] = nil
        c.entity.walking_state = {walking = false}
        ledger.fail_task(active.task_id, "could not reach step target (walking timed out)")
        storage.active_step[cid] = nil
        goto continue
      else
        goto continue  -- still walking, check again next tick
      end
    end

    if active.state == "acting" then
      local ok, err = true, nil
      if step.type == "place" then
        local pos = step_target_pos(t, step)
        local place_dir
        if step.dir ~= nil then
          place_dir = u.dir_map[step.dir]
        else
          place_dir = (step.which == "secondary" and t.ctx.dir2) or t.ctx.dir or 0
        end
        if step.candidates then
          local surf = c.entity.surface
          local chosen = nil
          for _, cand in ipairs(step.candidates) do
            local cdir = u.dir_map[cand.dir or 0]
            if surf.can_place_entity{name = step.entity, position = {x = cand.x, y = cand.y}, direction = cdir, force = c.entity.force, mirror = step.mirror} then
              chosen = {x = cand.x, y = cand.y, dir = cdir}
              break
            end
          end
          if not chosen then
            active.candidate_retry_deadline = active.candidate_retry_deadline or (game.tick + 60)
            if game.tick < active.candidate_retry_deadline then
              goto continue
            end
            ledger.fail_task(active.task_id, "no candidate position free for " .. step.entity)
            storage.active_step[cid] = nil
            goto continue
          end
          pos, place_dir = {x = chosen.x, y = chosen.y}, chosen.dir
        end
        local r = queues.start_build(cid, step.entity, pos, place_dir, step.mirror)
        if r.error then
          ledger.fail_task(active.task_id, r.error)
          storage.active_step[cid] = nil
        else
          active.state = "building"
        end
      elseif step.type == "ensure_item" then
        t.ctx.ensure_stack = t.ctx.ensure_stack or {{item = step.item, count = step.count}}
        local kind, err2 = ensure_item.start_ensure_item_action(c, cid, t)
        if kind == "satisfied" then
          table.remove(t.ctx.ensure_stack)
          if #t.ctx.ensure_stack == 0 then
            t.ctx.ensure_stack = nil
            t.ctx.smelt_wait_deadline = nil
            t.step_ticks = t.step_ticks or {}
            t.step_ticks[t.cursor] = {type = step.type, start = active.step_start_tick, done = game.tick}
            t.cursor = t.cursor + 1
            storage.active_step[cid] = nil
            if t.cursor > #t.steps then ledger.complete_task(active.task_id) end
          end
        elseif kind == "push" then
        elseif kind == "wait" then
        elseif kind == "gather" or kind == "craft" then
          active.state = "ensuring"
          active.ensuring_kind = kind
        elseif kind == "chop" then
          if u.distance(c.entity.position, t.ctx.wood_target) <= WOOD_CHOP_REACH then
            active.state = "ensuring"
            active.ensuring_kind = "chop_mine"
          else
            storage.walking_queues[cid] = {target = t.ctx.wood_target}
            active.state = "ensuring"
            active.ensuring_kind = "chop_walk"
            active.chop_deadline = u.approach_deadline(c.entity.position, t.ctx.wood_target)
          end
        else
          ledger.fail_task(active.task_id, err2 or "ensure_item failed")
          storage.active_step[cid] = nil
        end
      elseif step.type == "remove" then
        local pos = step_target_pos(t, step)
        local es = c.entity.surface.find_entities_filtered{
          name = step.entity, position = pos, radius = 1}
        if #es == 0 then
          ok, err = false, "no " .. step.entity .. " found to remove at target"
        else
          local inv = c.entity.get_main_inventory()
          local before = inv.get_item_count()
          es[1].mine{inventory = inv}
          ok = (inv.get_item_count() - before) > 0
          err = ok and nil or "could not mine (inventory full?)"
        end
      elseif step.type == "fuel" then
        local pos = step_target_pos(t, step)
        local inv = c.entity.get_main_inventory()
        local have = inv.get_item_count(step.item)
        if not pos then
          ok, err = false, "fuel: no target position resolved"
        elseif have == 0 then
          ok, err = false, "no " .. step.item .. " in inventory"
        else
          local es = c.entity.surface.find_entities_filtered{
            position = pos, radius = FUEL_REACH,
            type = {"furnace", "boiler", "inserter", "mining-drill"}}
          table.sort(es, function(a, b)
            return u.distance(a.position, pos) < u.distance(b.position, pos)
          end)
          if #es == 0 then
            ok, err = false, "no burner near target"
          else
            local remaining = step.count or 1
            local delivered = 0
            for _, e in ipairs(es) do
              if remaining <= 0 then break end
              local fi = e.get_fuel_inventory()
              if fi then
                local n = math.min(remaining, have)
                local inserted = fi.insert({name = step.item, count = n})
                if inserted > 0 then
                  c.entity.remove_item({name = step.item, count = inserted})
                  remaining = remaining - inserted
                  have = have - inserted
                  delivered = delivered + inserted
                end
              end
            end
            if delivered == 0 then
              ok, err = false, "no burner nearby had room for " .. step.item
            end
          end
        end
      elseif step.type == "find_patch" then
        ok, err = run_find_patch(c, t, step)
      elseif step.type == "find_existing" then
        ok, err = run_find_existing(c, t, step)
      elseif step.type == "set_position" then
        ok, err = run_set_position(c, t, step)
      elseif step.type == "verify_tile" then
        ok, err = run_verify_tile(c, t, step)
      elseif step.type == "pick_orientation" then
        ok, err = run_pick_orientation(c, t, step)
      elseif step.type == "read_drop_position" then
        ok, err = run_read_drop_position(c, t, step)
      else
        ok, err = false, "unknown step type " .. tostring(step.type)
      end
      if step.type ~= "place" and step.type ~= "ensure_item" then
        if ok then
          t.step_ticks = t.step_ticks or {}
          t.step_ticks[t.cursor] = {type = step.type, start = active.step_start_tick, done = game.tick}
          t.cursor = t.cursor + 1
          storage.active_step[cid] = nil
          if t.cursor > #t.steps then ledger.complete_task(active.task_id) end
        else
          ledger.fail_task(active.task_id, err)
          storage.active_step[cid] = nil
        end
      end
    end

    if active.state == "building" then
      local st = queues.get_build_status(cid)
      if st.active then
        goto continue  -- still building, check again next tick
      elseif st.placed then
        if step.which == "primary" and st.position then
          t.ctx.px, t.ctx.py = st.position.x, st.position.y
          if t.ctx.offset_dx then
            t.ctx.sx = t.ctx.px + t.ctx.offset_dx
            t.ctx.sy = t.ctx.py + t.ctx.offset_dy
          end
        elseif step.which == "secondary" and st.position then
          t.ctx.sx, t.ctx.sy = st.position.x, st.position.y
        end
        t.step_ticks = t.step_ticks or {}
        t.step_ticks[t.cursor] = {type = step.type, start = active.step_start_tick, done = game.tick}
        t.cursor = t.cursor + 1
        storage.active_step[cid] = nil
        if t.cursor > #t.steps then ledger.complete_task(active.task_id) end
      else
        ledger.fail_task(active.task_id, st.error or "build failed")
        storage.active_step[cid] = nil
      end
    end

    if active.state == "ensuring" then
      if active.ensuring_kind == "gather" then
        local st = queues.get_gather_status(cid)
        if st.active then goto continue end
        active.state = "acting"
      elseif active.ensuring_kind == "craft" then
        local st = queues.get_craft_status(cid)
        if st.active then goto continue end
        active.state = "acting"
      elseif active.ensuring_kind == "chop_walk" then
        if not storage.walking_queues[cid] then
          active.ensuring_kind = "chop_mine"  -- arrived -> fall through below, same tick
        elseif active.chop_deadline and game.tick >= active.chop_deadline then
          storage.walking_queues[cid] = nil
          c.entity.walking_state = {walking = false}
          local key = math.floor(t.ctx.wood_target.x) .. "," .. math.floor(t.ctx.wood_target.y)
          t.ctx.wood_tried[key] = true
          active.state = "acting"
        else
          goto continue
        end
      end
      if active.state == "ensuring" and active.ensuring_kind == "chop_mine" then
        local trees = c.entity.surface.find_entities_filtered{
          type = "tree", position = t.ctx.wood_target, radius = 1}
        if trees[1] and trees[1].valid then
          local inv = c.entity.get_main_inventory()
          local before = inv.get_item_count("wood")
          trees[1].mine{inventory = inv}
          if inv.get_item_count("wood") > before then
            t.ctx.wood_chop_count = (t.ctx.wood_chop_count or 0) + 1
          else
            local key = math.floor(t.ctx.wood_target.x) .. "," .. math.floor(t.ctx.wood_target.y)
            t.ctx.wood_tried[key] = true
          end
        else
          local key = math.floor(t.ctx.wood_target.x) .. "," .. math.floor(t.ctx.wood_target.y)
          t.ctx.wood_tried[key] = true
        end
        active.state = "acting"
      end
    end
    ::continue::
  end

  for cid, c in pairs(storage.companions or {}) do
    if c.entity and c.entity.valid and not storage.active_step[cid]
       and not storage.walking_queues[cid] and not busy_elsewhere(cid) then
      local task_id = pick_next(cid, c)
      if task_id then
        local t = storage.tasks[task_id]
        local step = t.steps[t.cursor]
        local pos = step_target_pos(t, step)
        if pos and u.distance(c.entity.position, pos) > WALK_REACH then
          storage.walking_queues[cid] = {target = pos}
          local walk_deadline = u.approach_deadline(c.entity.position, pos)
          storage.active_step[cid] = {task_id = task_id, state = "walking",
                                       approach_deadline = walk_deadline,
                                       step_start_tick = game.tick}
        else
          storage.active_step[cid] = {task_id = task_id, state = "acting",
                                       step_start_tick = game.tick}
        end
      end
    end
  end
end

function M.get_diag(cid)
  local active = storage.active_step and storage.active_step[cid]
  local out = {
    active_step = active and {
      task_id = active.task_id, state = active.state,
      approach_deadline = active.approach_deadline,
      ticks_until_deadline = active.approach_deadline and (active.approach_deadline - game.tick) or nil,
      candidate_retry_deadline = active.candidate_retry_deadline,
    } or nil,
    walking_queue = storage.walking_queues and storage.walking_queues[cid] and {
      target = storage.walking_queues[cid].target,
    } or nil,
    busy_gather = (storage.gather_queues and storage.gather_queues[cid]) and true or false,
    busy_fuel = (storage.fuel_queues and storage.fuel_queues[cid]) and true or false,
    busy_build = (storage.build_queues and storage.build_queues[cid]) and true or false,
    busy_belt = (storage.belt_queues and storage.belt_queues[cid]) and true or false,
    busy_harvest = (storage.harvest_queues and storage.harvest_queues[cid]) and true or false,
    busy_craft = (storage.craft_queues and storage.craft_queues[cid]) and true or false,
    busy_combat = (storage.combat_queues and storage.combat_queues[cid]) and true or false,
  }
  if active and active.task_id then
    local t = storage.tasks[active.task_id]
    if t then
      out.task = {status = t.status, cursor = t.cursor, total_steps = #t.steps,
                  needs = t.needs, step_type = t.steps[t.cursor] and t.steps[t.cursor].type}
    end
  end
  if out.busy_gather then
    out.gather = queues.get_gather_status(cid)
  end
  local errs = storage.errors or {}
  local recent = {}
  for i = math.max(1, #errs - 4), #errs do recent[#recent + 1] = errs[i] end
  out.recent_errors = recent
  return out
end

return M
