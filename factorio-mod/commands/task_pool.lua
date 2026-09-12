
local u = require("commands.init")
local queues = require("commands.queues")
local ledger = require("commands.task_pool_ledger")

local M = {}

local FUEL_REACH = u.settings.task_tuning.fuel_reach
local WALK_REACH = u.settings.task_tuning.walk_reach

local HAND_CRAFTABLE_CATEGORIES = {["crafting"] = true, ["hand-crafting"] = true}
local ENSURE_ITEM_MAX_DEPTH = u.settings.task_tuning.ensure_item_max_depth
local WOOD_CHOP_REACH = u.settings.task_tuning.wood_chop_reach
local WOOD_CHOP_MAX_TREES = u.settings.task_tuning.wood_chop_max_trees
local ENSURE_ITEM_GATHER_MAX_ATTEMPTS = u.settings.task_tuning.ensure_item_gather_max_attempts
local ENSURE_ITEM_CONTAINER_SEARCH_RADIUS = u.settings.task_tuning.ensure_item_container_search_radius

local function resolve_recipe(item)
  local r = prototypes.recipe[item]
  if not r then return nil end
  local ingredients = {}
  for _, x in ipairs(r.ingredients) do
    ingredients[#ingredients + 1] = {name = x.name, amount = x.amount}
  end
  local yield = 1
  for _, p in ipairs(r.products) do
    if p.name == item then yield = p.amount; break end
  end
  local hand_craftable = HAND_CRAFTABLE_CATEGORIES[r.category] or false
  return {ingredients = ingredients, yield = yield, hand_craftable = hand_craftable}
end

local function pull_from_nearby_container(c, item, deficit)
  if deficit <= 0 then return 0 end
  local candidates = c.entity.surface.find_entities_filtered{
    position = c.entity.position, radius = ENSURE_ITEM_CONTAINER_SEARCH_RADIUS,
    type = {"container", "logistic-container"}}
  local target, bd = nil, math.huge
  for _, e in ipairs(candidates) do
    if e.valid then
      local dx, dy = e.position.x - c.entity.position.x, e.position.y - c.entity.position.y
      local d = dx * dx + dy * dy
      if d < bd then bd, target = d, e end
    end
  end
  if not target then return 0 end
  local inv = target.get_inventory(defines.inventory.chest)
  if not inv then return 0 end
  local av = inv.get_item_count(item)
  if av <= 0 then return 0 end
  local rm = inv.remove{name = item, count = math.min(deficit, av)}
  if rm <= 0 then return 0 end
  local ins = c.entity.insert{name = item, count = rm}
  if ins < rm then
    inv.insert{name = item, count = rm - ins}
  end
  return ins
end

-- Starts exactly ONE concrete action toward satisfying the need at the TOP of
-- t.ctx.ensure_stack (item=, count=) for companion c/cid. Returns a `kind`
-- string describing what was started ("gather"|"craft"|"chop"|"push"|"satisfied")
-- plus an error string on genuine failure (kind=nil). "push" means a NEW, deeper
-- need (a short ingredient) was pushed onto the stack -- no queue was started
-- this cycle, the caller should look at the stack again next "acting" pass.
-- "satisfied" means the top-of-stack need is ALREADY met (checked fresh here,
-- not assumed) -- pop it and reassess without starting anything.
local function start_ensure_item_action(c, cid, t)
  local stack = t.ctx.ensure_stack
  local need = stack[#stack]
  if type(need.item) ~= "string" or type(need.count) ~= "number" then
    return nil, "ensure_item: step.item (string) and step.count (number) required"
  end
  local inv = c.entity.get_main_inventory()
  if inv.get_item_count(need.item) >= need.count then
    return "satisfied"
  end
  if #stack > ENSURE_ITEM_MAX_DEPTH then
    return nil, "ensure_item recursion depth exceeded for " .. need.item ..
      " (likely a recipe-chain or naming problem, not a normal case)"
  end
  if need.item == "wood" then
    t.ctx.wood_tried = t.ctx.wood_tried or {}
    t.ctx.wood_chop_count = t.ctx.wood_chop_count or 0
    if t.ctx.wood_chop_count >= WOOD_CHOP_MAX_TREES then
      return nil, "could not chop enough wood after " .. WOOD_CHOP_MAX_TREES .. " trees"
    end
    local WOOD_SEARCH_RADII = {20, 50, 100, 200}
    local best, best_d = nil, math.huge
    for _, radius in ipairs(WOOD_SEARCH_RADII) do
      local trees = c.entity.surface.find_entities_filtered{
        type = "tree", position = c.entity.position, radius = radius}
      for _, tr in ipairs(trees) do
        local key = math.floor(tr.position.x) .. "," .. math.floor(tr.position.y)
        if tr.valid and not t.ctx.wood_tried[key] then
          local d = u.distance(c.entity.position, tr.position)
          if d < best_d then best, best_d = tr, d end
        end
      end
      if best then break end
    end
    if not best then return nil, "no reachable tree found for wood" end
    t.ctx.wood_target = {x = best.position.x, y = best.position.y}
    return "chop"
  end
  local recipe = resolve_recipe(need.item)
  if not recipe then
    local deficit = need.count - inv.get_item_count(need.item)
    local pulled = pull_from_nearby_container(c, need.item, deficit)
    if pulled > 0 then
      deficit = deficit - pulled
    end
    if deficit <= 0 then
      return "satisfied"
    end
    t.ctx.gather_attempts = t.ctx.gather_attempts or {}
    t.ctx.gather_attempts[need.item] = (t.ctx.gather_attempts[need.item] or 0) + 1
    if t.ctx.gather_attempts[need.item] > ENSURE_ITEM_GATHER_MAX_ATTEMPTS then
      return nil, "could not gather enough " .. need.item .. " after " ..
        ENSURE_ITEM_GATHER_MAX_ATTEMPTS .. " attempts (likely scarce/unreachable)"
    end
    local r = queues.start_gather(cid, need.item, deficit, nil, true)
    if r.error then return nil, r.error end
    return "gather"
  end
  if not recipe.hand_craftable then
    return nil, need.item .. " recipe is not hand-craftable (needs a real machine, e.g. smelting)"
  end
  for _, ing in ipairs(recipe.ingredients) do
    local needed_amount = math.ceil(need.count / recipe.yield) * ing.amount
    if inv.get_item_count(ing.name) < needed_amount then
      stack[#stack + 1] = {item = ing.name, count = needed_amount}
      return "push"
    end
  end
  local craft_count = math.ceil(need.count / recipe.yield)
  local r = queues.start_craft(cid, need.item, craft_count)
  if r.error then return nil, r.error end
  return "craft"
end

function M.init()
  storage.tasks = storage.tasks or {}
  storage.next_task_id = storage.next_task_id or 1
  storage.reserved = storage.reserved or {}
  -- storage.active_step[cid] = {task_id=, state="walking"|"acting"} -- at most ONE step
  -- in flight per companion at a time (single physical entity, can only do one thing).
  storage.active_step = storage.active_step or {}
end

M.submit_task = ledger.submit_task
M.get_task_status = ledger.get_task_status

-- ---- step readiness + target position (for distance-priority scheduling) ----

local function step_target_pos(t, step)
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

local function task_ready(t)
  local needed_so_far = ledger.derive_needs(t.steps, t.cursor)
  for item, count in pairs(needed_so_far) do
    if (t.reserved[item] or 0) < count then
      return false
    end
  end
  return true
end

-- ---- synchronous (non-walking) step execution ----

local function run_read_drop_position(c, t, step)
  local pos = step_target_pos(t, step)
  if not pos then return false, "read_drop_position: no source position resolved" end
  local es = c.entity.surface.find_entities_filtered{
    name = step.entity, position = pos, radius = 1}
  if #es == 0 then return false, "read_drop_position: no " .. tostring(step.entity) .. " found at source" end
  local dp = es[1].drop_position
  if not dp then return false, "read_drop_position: entity has no drop_position" end
  t.ctx.saved = t.ctx.saved or {}
  t.ctx.saved[step.save_as] = {x = dp.x, y = dp.y}
  return true
end

local function run_find_existing(c, t, step)
  local surf = c.entity.surface
  local es = surf.find_entities_filtered{
    name = step.entity, position = c.entity.position, radius = step.radius or 400}
  local best, best_d = nil, math.huge
  for _, e in ipairs(es) do
    if e.valid then
      local d = u.distance(e.position, c.entity.position)
      if d < best_d then best, best_d = e, d end
    end
  end
  if not best then return false, "no existing " .. step.entity .. " found" end
  t.ctx.px, t.ctx.py = best.position.x, best.position.y
  return true
end

local function run_set_position(c, t, step)
  if not (step.x and step.y) then return false, "set_position: x/y required" end
  t.ctx.px, t.ctx.py = step.x, step.y
  return true
end

local function run_find_patch(c, t, step)
  local surf = c.entity.surface
  local es = surf.find_entities_filtered{name = step.resource, position = c.entity.position, radius = 400}
  table.sort(es, function(a, b)
    return u.distance(a.position, c.entity.position) < u.distance(b.position, c.entity.position)
  end)
  for _, e in ipairs(es) do
    if e.valid and (e.amount or 1) > 0
       and surf.find_non_colliding_position("character", e.position, WALK_REACH, 0.5) then
      t.ctx.px, t.ctx.py = e.position.x, e.position.y
      return true
    end
  end
  return false, "no reachable " .. step.resource .. " patch found"
end

local function run_verify_tile(c, t, step)
  local surf = c.entity.surface
  local es = surf.find_entities_filtered{name = step.resource, position = {x = t.ctx.px, y = t.ctx.py}, radius = 1}
  if #es == 0 then return false, "patch tile no longer present" end
  return true
end

local function run_pick_orientation(c, t, step)
  local surf = c.entity.surface
  local candidate_diag = {}
  for _, off in ipairs(step.offsets) do
    local sx, sy = t.ctx.px + off[1], t.ctx.py + off[2]
    local simple_dir
    if off[1] == 0 and off[2] > 0 then simple_dir = 2
    elseif off[1] == 0 and off[2] < 0 then simple_dir = 0
    elseif off[1] > 0 then simple_dir = 1
    else simple_dir = 3 end
    local real_dir = u.dir_map[simple_dir]
    local secondary_dir = real_dir
    if step.opposite_direction then
      secondary_dir = u.dir_map[(simple_dir + 2) % 4]
    end
    local primary_ok = step.primary_exists or
      surf.can_place_entity{name = step.primary, position = {x = t.ctx.px, y = t.ctx.py}, direction = real_dir, force = c.entity.force}
    local secondary_resource_ok = true
    if step.secondary_resource then
      local ore = surf.find_entities_filtered{name = step.secondary_resource, position = {x = sx, y = sy}, radius = 1}
      secondary_resource_ok = #ore > 0
    end
    local secondary_ok = surf.can_place_entity{name = step.secondary, position = {x = sx, y = sy}, direction = secondary_dir, force = c.entity.force}
    if primary_ok and secondary_resource_ok and secondary_ok then
      t.ctx.sx, t.ctx.sy = sx, sy
      t.ctx.dir = real_dir
      t.ctx.dir2 = secondary_dir
      -- Kept alongside sx/sy so the primary's "place" step can RECOMPUTE the
      -- secondary's position once the primary's REAL (possibly snapped) placed
      -- position is known -- see the note where offset_dx/dy is consumed below.
      -- (Not relevant when primary_exists -- there is no primary "place" step
      -- to recompute anything from, the furnace's position never changes.)
      t.ctx.offset_dx, t.ctx.offset_dy = off[1], off[2]
      return true
    end
    local diag = u.dump_context(surf, {x = sx, y = sy}, {radius = 1.5})
    candidate_diag[#candidate_diag + 1] = string.format(
      "off(%d,%d)@(%.1f,%.1f) primary_ok=%s secondary_resource_ok=%s secondary_ok=%s tile=%s nearby=[%s]",
      off[1], off[2], sx, sy, tostring(primary_ok), tostring(secondary_resource_ok),
      tostring(secondary_ok), diag.tile, table.concat(diag.nearby, ","))
  end
  u.log_error("pick_orientation: no free orientation for " .. step.secondary ..
    " around (" .. t.ctx.px .. "," .. t.ctx.py .. ") -- " .. table.concat(candidate_diag, " | "),
    "pick_orientation")
  return false, "no free orientation (all sides blocked)"
end

-- ---- main scheduler tick ----

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

local function refresh_needs()
  local ids = {}
  for task_id, t in pairs(storage.tasks) do
    if t.status == "active" and next(t.needs) ~= nil then ids[#ids + 1] = task_id end
  end
  if #ids == 0 then return end
  table.sort(ids)
  storage.inv_count_cache = storage.inv_count_cache or {}
  local epoch = storage.reservation_epoch or 0
  local epoch_changed = (storage.last_seen_reservation_epoch or -1) ~= epoch
  storage.last_seen_reservation_epoch = epoch
  for _, task_id in ipairs(ids) do
    local t = storage.tasks[task_id]
    local c = u.get_companion(t.cid)
    if c then
      local inv = c.entity.get_main_inventory()
      local total = inv.get_item_count()
      if storage.inv_count_cache[t.cid] ~= total or epoch_changed then
        storage.inv_count_cache[t.cid] = total
        for item, deficit in pairs(t.needs) do
          local have = inv.get_item_count(item)
          local reserved = ledger.reservations(t.cid)
          local already_reserved = reserved[item] or 0
          local available = math.max(0, have - already_reserved)
          local take = math.min(available, deficit)
          if take > 0 then
            reserved[item] = already_reserved + take
            t.reserved[item] = (t.reserved[item] or 0) + take
            if take >= deficit then
              t.needs[item] = nil
            else
              t.needs[item] = deficit - take
            end
          end
        end
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
        -- Arrived (or walking_queue was never set for a non-walk step) -> act.
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
        -- Handled entirely inline (not via the generic ok/err fall-through below,
        -- see the bug note there): start_build's OWN failure is reported
        -- immediately (queues.start_build never queues anything in that case, so
        -- there is no later "building" state to catch it) -- fail_task here or the
        -- task would sit stuck in "acting" forever with active_step never cleared.
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
          -- Poll build_queues to completion via the SEPARATE "building" state
          -- below (own stale-progress backstop, same as every other queue type).
          active.state = "building"
        end
      elseif step.type == "ensure_item" then
        -- Handled entirely inline, like "place" above (see this step type's own
        -- header comment, near WOOD_CHOP_REACH, for the full design). Genuinely
        -- async (gather/craft/chop can each take many ticks) -- excluded from the
        -- generic ok/err fall-through below the same way "place" is.
        t.ctx.ensure_stack = t.ctx.ensure_stack or {{item = step.item, count = step.count}}
        local kind, err2 = start_ensure_item_action(c, cid, t)
        if kind == "satisfied" then
          table.remove(t.ctx.ensure_stack)
          if #t.ctx.ensure_stack == 0 then
            t.ctx.ensure_stack = nil
            t.cursor = t.cursor + 1
            storage.active_step[cid] = nil
            if t.cursor > #t.steps then ledger.complete_task(active.task_id) end
          end
          -- else: stay in "acting" this same tick's next pass (goto continue below
          -- falls through to end-of-loop; re-entering "acting" next tick reassesses
          -- the now-shorter stack) -- no state change needed, active.state is
          -- already "acting".
        elseif kind == "push" then
          -- A deeper ingredient need was pushed -- reassess next tick against the
          -- new top of stack, same as "satisfied"'s implicit re-entry above.
        elseif kind == "gather" or kind == "craft" then
          active.state = "ensuring"
          active.ensuring_kind = kind
        elseif kind == "chop" then
          -- Skip the walk entirely if already close enough (mirrors "place"'s own
          -- distance check in the idle-dispatch loop below) -- go straight to
          -- chop_mine so a tree that happens to be right next to the companion
          -- doesn't pay for a pointless 1-tick walking_queue round trip.
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
        if have == 0 then
          ok, err = false, "no " .. step.item .. " in inventory"
        else
          local es = c.entity.surface.find_entities_filtered{
            position = pos, radius = FUEL_REACH,
            type = {"furnace", "boiler", "inserter", "mining-drill"}}
          if #es == 0 then
            ok, err = false, "no burner near target"
          else
            local remaining = step.count or 1
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
                end
              end
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

      -- "place"/"ensure_item" are fully handled above (either resolved inline, or
      -- transitioned to their own separate polling state) -- every OTHER step
      -- type completes synchronously within this same tick, so their ok/err is
      -- resolved here.
      if step.type ~= "place" and step.type ~= "ensure_item" then
        if ok then
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
          -- Bounded give-up (mirrors every other approach_deadline in this file):
          -- blacklist this SPECIFIC tree so the next "acting" pass picks a
          -- DIFFERENT one instead of re-selecting the identical unreachable tree
          -- forever (the exact "no exclude" bug class already fixed once for
          -- _chop_wood itself, spatial_demo.py -- applied here from the start).
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
            -- Mined but yielded nothing new (inventory full?) -- blacklist so this
            -- exact tree isn't retried forever; a genuinely full inventory will
            -- surface via the NEXT tree's identical failure, not silently loop.
            local key = math.floor(t.ctx.wood_target.x) .. "," .. math.floor(t.ctx.wood_target.y)
            t.ctx.wood_tried[key] = true
          end
        else
          -- Tree gone (another companion/process claimed it between selection and
          -- arrival) -- blacklist and retry with a fresh selection, don't fail the
          -- whole task over a single vanished tree.
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
                                       approach_deadline = walk_deadline}
        else
          storage.active_step[cid] = {task_id = task_id, state = "acting"}
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
  -- Last few entries of the errors ring buffer (task #46): surfaces recent silent
  -- pcall failures (u.error_response/u.log_error, storage.errors, capped 50 total)
  -- right alongside the queue/task state that was active when they happened, instead
  -- of needing a separate /fac_get_errors call and manually correlating timestamps.
  -- Capped at 5 here (not all 50) to keep this diagnostic response focused on what's
  -- actionable RIGHT NOW rather than dumping the whole history every time.
  local errs = storage.errors or {}
  local recent = {}
  for i = math.max(1, #errs - 4), #errs do recent[#recent + 1] = errs[i] end
  out.recent_errors = recent
  return out
end

return M
