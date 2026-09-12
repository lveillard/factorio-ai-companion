local u = require("commands.init")
local targeting = require("commands.task_pool_targeting")

local step_target_pos = targeting.step_target_pos
local WALK_REACH = targeting.WALK_REACH

local M = {}

function M.run_read_drop_position(c, t, step)
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
function M.run_find_existing(c, t, step)
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

function M.run_set_position(c, t, step)
  if not (step.x and step.y) then return false, "set_position: x/y required" end
  t.ctx.px, t.ctx.py = step.x, step.y
  return true
end

local function footprint_matches_resource(surf, entity_name, position, resource_name)
  local proto = prototypes.entity[entity_name]
  local box = proto and proto.collision_box
  if not box then return false end
  local area = {
    {x = position.x + box.left_top.x, y = position.y + box.left_top.y},
    {x = position.x + box.right_bottom.x, y = position.y + box.right_bottom.y}
  }
  local found = false
  for _, resource in ipairs(surf.find_entities_filtered{area=area, type="resource"}) do
    if resource.valid then
      if resource.name ~= resource_name then return false end
      found = true
    end
  end
  return found
end

local function find_upcoming_primary_entity(t)
  for i = t.cursor + 1, #t.steps do
    if t.steps[i].type == "pick_orientation" then return t.steps[i].primary end
  end
  return nil
end

local function find_governing_resource(t)
  for i = t.cursor - 1, 1, -1 do
    if t.steps[i].type == "find_patch" then return t.steps[i].resource end
  end
  return nil
end

function M.run_find_patch(c, t, step)
  local surf = c.entity.surface
  local es = surf.find_entities_filtered{name = step.resource, position = c.entity.position, radius = 400}
  table.sort(es, function(a, b)
    return u.distance(a.position, c.entity.position) < u.distance(b.position, c.entity.position)
  end)
  local primary_entity = find_upcoming_primary_entity(t)
  local primary_is_drill = primary_entity and prototypes.entity[primary_entity]
    and prototypes.entity[primary_entity].type == "mining-drill"
  for _, e in ipairs(es) do
    if e.valid and (e.amount or 1) > 0
       and surf.find_non_colliding_position("character", e.position, WALK_REACH, 0.5)
       and (not primary_is_drill
            or footprint_matches_resource(surf, primary_entity, e.position, step.resource)) then
      t.ctx.px, t.ctx.py = e.position.x, e.position.y
      return true
    end
  end
  return false, "no reachable " .. step.resource .. " patch found"
end

function M.run_verify_tile(c, t, step)
  local surf = c.entity.surface
  local es = surf.find_entities_filtered{name = step.resource, position = {x = t.ctx.px, y = t.ctx.py}, radius = 1}
  if #es == 0 then return false, "patch tile no longer present" end
  return true
end

function M.run_pick_orientation(c, t, step)
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
    local secondary_exclusive_ok = true
    if prototypes.entity[step.secondary] and prototypes.entity[step.secondary].type == "mining-drill" then
      local expected_resource = step.secondary_resource or find_governing_resource(t)
      if expected_resource then
        secondary_exclusive_ok = footprint_matches_resource(surf, step.secondary, {x = sx, y = sy}, expected_resource)
      end
    end
    if primary_ok and secondary_resource_ok and secondary_ok and secondary_exclusive_ok then
      t.ctx.sx, t.ctx.sy = sx, sy
      t.ctx.dir = real_dir
      t.ctx.dir2 = secondary_dir
      t.ctx.offset_dx, t.ctx.offset_dy = off[1], off[2]
      return true
    end
    local diag = u.dump_context(surf, {x = sx, y = sy}, {radius = 1.5})
    candidate_diag[#candidate_diag + 1] = string.format(
      "off(%d,%d)@(%.1f,%.1f) primary_ok=%s secondary_resource_ok=%s secondary_ok=%s " ..
      "secondary_exclusive_ok=%s tile=%s nearby=[%s]",
      off[1], off[2], sx, sy, tostring(primary_ok), tostring(secondary_resource_ok),
      tostring(secondary_ok), tostring(secondary_exclusive_ok), diag.tile, table.concat(diag.nearby, ","))
  end
  u.log_error("pick_orientation: no free orientation for " .. step.secondary ..
    " around (" .. t.ctx.px .. "," .. t.ctx.py .. ") -- " .. table.concat(candidate_diag, " | "),
    "pick_orientation")
  return false, "no free orientation (all sides blocked)"
end

return M
