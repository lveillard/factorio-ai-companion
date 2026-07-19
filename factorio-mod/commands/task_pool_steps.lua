-- AI Companion -- task pool synchronous (non-walking) step handlers (2026-07-19
-- size-refactor split out of task_pool.lua). Verbatim move -- see task_pool.lua's
-- own header comment block for the full step-vocabulary background these
-- handlers implement; M.tick (the scheduler, which dispatches to these) stays in
-- task_pool.lua.

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

-- find_existing (2026-07-07, furnace-upgrade task): see step vocabulary note
-- above -- locates an already-placed entity (not a resource patch) nearest the
-- companion, for a task that adds to something already built.
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

-- set_position (2026-07-07, coal_pair upgrade variant A -- reusing an EXISTING
-- pair's own drills): sets ctx.px/py directly from caller-supplied coordinates,
-- e.g. a task_id's OWN drill1 position (known from an EARLIER task's completed
-- ctx, read back via fac_task_status) as the anchor for a fresh pick_orientation
-- pass AFTER removing both original drills -- there is nothing left to
-- find_existing on once they're gone, and re-running find_patch could land on
-- a DIFFERENT ore tile than the one this pair was already built on.
function M.run_set_position(c, t, step)
  if not (step.x and step.y) then return false, "set_position: x/y required" end
  t.ctx.px, t.ctx.py = step.x, step.y
  return true
end

-- ORE-MIXUP FIX (2026-07-19, approved-fixes item 1 -- Zdendys, live-confirmed 4x,
-- see memory drill_wrong_ore_type_overlapping_patches_2026_07_18.md): a
-- burner-mining-drill's real mining footprint is its whole collision box (2x2),
-- not just the single tile find_patch/pick_orientation happened to check -- on a
-- map where two resource patches sit close enough to overlap, a drill placed
-- there can straddle BOTH, and its native mining_target then locks onto or
-- fluctuates toward the WRONG one, starving the paired furnace. Zdendys's own
-- explicit fix direction: "dokud neumis 'rozdelovace - vyzkum: logisticka sit'
-- nedavej vrtacku na pomezi mezi 2 loziska!" (until splitters/logistics-network
-- research is available, never place a drill straddling 2 deposits) -- reject any
-- candidate whose FULL footprint isn't 100% one exclusive resource type, rather
-- than only checking the single anchor tile as before.
--
-- SNAP-AWARE (2026-07-19, live-caught during this fix's OWN first verification
-- attempt -- a naive version computing the footprint from collision_box +
-- REQUESTED position FAILED to reject a genuinely-straddling live test case):
-- Factorio snaps a placed entity's REAL position away from what was requested --
-- confirmed live via RCON, e.g. a burner-mining-drill requested at a coal tile's
-- own (100.5,100.5) landed at (101,101), a 0.5-tile shift on BOTH axes -- this
-- matches queues_build.lua's own already-documented create_entity snap-shift
-- finding for the "place" step, and explains the original bug's own real
-- example (drill centered at an INTEGER position straddling several
-- half-tile-offset resource entities, not centered ON any one of them). Checking
-- the footprint at the requested (pre-snap) position therefore misses exactly
-- the cases this fix exists to catch. Instead, actually test-place the entity
-- (LuaSurface.create_entity does NOT raise on_built_entity events unless
-- raise_built=true is explicitly passed, so this has no visible side effect),
-- read its REAL, engine-computed bounding_box (already accounts for snap AND
-- rotation, so no need to reimplement either), then destroy it immediately --
-- same synchronous create-then-destroy shape as the teleport-and-restore
-- technique already used elsewhere in this file for self-collision checks, so
-- there is no tick where the drill is genuinely present, no player-visible
-- flicker, and no persisted state change.
--
-- Returns true (exclusive / don't block) when the entity can't even be
-- test-placed here (some OTHER obstruction) -- the caller's own separate
-- can_place_entity check already handles rejecting that candidate for its own
-- reason; this check's only job is the resource-exclusivity question.
local function footprint_is_exclusive_resource(surf, entity_name, position, resource_name, force)
  local test = surf.create_entity{name = entity_name, position = position, force = force}
  if not test or not test.valid then return true end
  local bb = test.bounding_box
  local exclusive = true
  for _, r in ipairs(surf.find_entities_filtered{area = bb, type = "resource"}) do
    if r.valid and r.name ~= resource_name then
      exclusive = false
      break
    end
  end
  test.destroy()
  return exclusive
end

-- A find_patch step never itself names the entity that will be BUILT on the tile
-- it picks -- that only shows up in a LATER pick_orientation step, e.g.
-- {"type":"find_patch","resource":"coal"} followed by {"type":"pick_orientation",
-- "primary":"burner-mining-drill",...} (COAL_PAIR_STEPS/IRON_DRILL_STEPS/
-- STONE_DRILL_STEPS' own established pattern -- every existing find_patch caller
-- follows it). Peek forward in the SAME task's already-fully-known step list (not
-- yet executed, just data) to find that entity name, so find_patch can apply the
-- SAME footprint-exclusivity standard the actual drill placement will need.
local function find_upcoming_primary_entity(t)
  for i = t.cursor + 1, #t.steps do
    if t.steps[i].type == "pick_orientation" then return t.steps[i].primary end
  end
  return nil
end

-- Sibling lookup for the SECONDARY-side exclusivity check below: when a
-- coal_pair-class task's secondary is also a mining-drill, "what resource is
-- the primary (at ctx.px/py) actually mining" needs an authoritative answer,
-- not a guess. The find_patch step that originally set ctx.px/py already
-- carries that answer in its own step.resource -- look BACKWARD from the
-- current step for the most recent one, instead of an ambiguous
-- find_entities_filtered{...}[1] scan around ctx.px/py (2026-07-19,
-- cubic-dev-ai-class review finding on this fix's own first draft: an
-- unsorted [1] pick right next to a genuinely straddling tile could itself
-- pick the WRONG resource, defeating the point of this whole check).
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
            or footprint_is_exclusive_resource(surf, primary_entity, e.position, step.resource, c.entity.force)) then
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

-- Forward-declared (defined below run_pick_orientation) so both stay `local` --
-- Lua resolves the call inside run_pick_orientation at CALL time, by which point
-- this upvalue has been assigned, same pattern as the rest of this module.
local run_pick_orientation_checks

function M.run_pick_orientation(c, t, step)
  local surf = c.entity.surface
  -- ignore_entities_at (2026-07-07, coal_pair v1->v2 upgrade safety fix, Zdendys:
  -- "nejdriv oprav bezpecnost, nez se upgrade zapoji do produkce"): the coal_pair
  -- upgrade's step order is remove-both-old-drills THEN pick_orientation+place-wider.
  -- If pick_orientation found no valid wider spot, the old drills would ALREADY be
  -- gone by the time it fails -- turning a working self-fed pair into a broken one
  -- (live-observed collision-fail rate ~2/5 on this exact geometry, task #35).
  -- Reordering pick_orientation BEFORE remove isn't enough on its own: a wider
  -- candidate's collision box can overlap where the STILL-PRESENT old drill sits
  -- (e.g. gap=2 old secondary at distance 2 overlaps a gap=4 new secondary's
  -- footprint at the boundary), causing a FALSE rejection of a spot that would
  -- actually be fine once the old drill is gone.
  --
  -- Fix: temporarily teleport the named entities at these known positions far away,
  -- run the REAL can_place_entity checks (reusing the engine's own authoritative
  -- collision/tile logic instead of reimplementing it), then teleport them back to
  -- their exact original position -- all within this single synchronous call, so
  -- there is no player-visible flicker and no tick where they're actually gone.
  -- This lets the caller verify a rebuild position BEFORE issuing any "remove" step,
  -- eliminating the regression risk entirely (verify-before-destroy, not just
  -- reordered-but-still-racy).
  local moved = {}
  if step.ignore_entities_at then
    for _, p in ipairs(step.ignore_entities_at) do
      local es = surf.find_entities_filtered{position = {x = p.x, y = p.y}, radius = 0.5}
      for _, e in ipairs(es) do
        if e.valid then
          moved[#moved + 1] = {entity = e, pos = {x = e.position.x, y = e.position.y}}
          e.teleport({x = e.position.x + 10000, y = e.position.y + 10000})
        end
      end
    end
  end
  -- Self-collision fix (2026-07-13, universal own-body-blocks-own-build fix, Zdendys:
  -- "the companion must never block her own construction, whatever the building
  -- is"): every
  -- can_place_entity probe inside run_pick_orientation_checks (both the primary and the
  -- secondary candidate, every offset) sees the companion's OWN character body as an
  -- ordinary collision entity -- if she is currently standing on/near the candidate area
  -- (the common case: she just walked to the patch/anchor before pick_orientation ever
  -- runs), EVERY orientation can spuriously fail with "all sides blocked" even though the
  -- area would genuinely be free the instant she steps aside. Exactly the same class of
  -- false rejection ignore_entities_at/clear_natural_obstacles above already fix for OTHER
  -- entities -- extend the SAME teleport-and-restore technique to her own body: teleport
  -- her far away for the duration of the checks only, then restore her EXACT original
  -- position afterward regardless of outcome (success or failure), so there is no
  -- player-visible flicker and no tick where she is actually gone.
  local self_pos = {x = c.entity.position.x, y = c.entity.position.y}
  c.entity.teleport({x = self_pos.x + 10000, y = self_pos.y + 10000})
  local ok, err = run_pick_orientation_checks(c, t, step, surf)
  c.entity.teleport(self_pos)
  for _, m in ipairs(moved) do
    if m.entity.valid then m.entity.teleport(m.pos) end
  end
  return ok, err
end

-- Temporarily remove tree/simple-entity (rock) obstacles from an entity's footprint
-- so a can_place_entity check reflects what queues.lua's clear_build_area will ACTUALLY
-- leave behind at build time, not raw ground-truth right now (2026-07-08, task #47,
-- Zdendys: "During construction nothing may be surrounded by trees, the MOD's job is to
-- clear the area before construction!" -- pick_orientation was rejecting candidates over trees/rocks that
-- the build step removes anyway, live-caught: "no free orientation (all sides
-- blocked)" on an ore patch with a single nearby tree). Mirrors clear_build_area's OWN
-- area computation (queues.lua) exactly, and the existing ignore_entities_at
-- teleport-and-restore pattern above -- reusing the engine's real collision check
-- instead of reimplementing "is this a removable obstacle" logic separately.
local function clear_natural_obstacles(surf, entity_name, position)
  local proto = prototypes.entity[entity_name]
  if not proto or not proto.collision_box then return {} end
  local bb = proto.collision_box
  local area = {
    {x = position.x + bb.left_top.x - 0.5, y = position.y + bb.left_top.y - 0.5},
    {x = position.x + bb.right_bottom.x + 0.5, y = position.y + bb.right_bottom.y + 0.5}
  }
  local moved = {}
  local obstacles = surf.find_entities_filtered{area = area, type = {"tree", "simple-entity"}}
  for _, obs in ipairs(obstacles) do
    if obs.valid then
      moved[#moved + 1] = {entity = obs, pos = {x = obs.position.x, y = obs.position.y}}
      obs.teleport({x = obs.position.x + 10000, y = obs.position.y + 10000})
    end
  end
  return moved
end

local function restore_moved(moved)
  for _, m in ipairs(moved) do
    if m.entity.valid then m.entity.teleport(m.pos) end
  end
end

run_pick_orientation_checks = function(c, t, step, surf)
  -- Per-candidate diagnostic (2026-07-08, task #47, live-caught: "no free orientation
  -- (all sides blocked)" on an ore patch that LOOKED like it had room -- the only
  -- diagnostic available was a dump of entities near the PRIMARY position, not each
  -- of the actual secondary candidates, so it was impossible to tell whether all 4
  -- were genuinely blocked or something else was wrong). Collected regardless of
  -- outcome; only logged if every candidate ultimately fails.
  local candidate_diag = {}
  for _, off in ipairs(step.offsets) do
    local sx, sy = t.ctx.px + off[1], t.ctx.py + off[2]
    -- Compute the REAL defines.direction value BEFORE checking can_place_entity
    -- (2026-07-07, live-caught collision bug): this mod uses TWO different
    -- direction numbering systems -- u.dir_map's "simple" 0-3 (matches the MCP
    -- tools API convention) vs. Factorio's own raw defines.direction enum
    -- (north=0, east=4, south=8, west=12, 16-direction system). The check here
    -- was using NO direction (defaulting to north's footprint), while the actual
    -- placement later passed the SIMPLE 0-3 value straight into queues.start_build
    -- (which expects a raw defines.direction value) -- e.g. simple "2" (meant as
    -- south) was literally interpreted as raw direction 2 (northeast), a
    -- completely different rotation than what was just verified as fitting.
    -- Checking and placing with the SAME correctly-translated direction fixes
    -- both the wrong rotation AND the check/placement mismatch in one go.
    local simple_dir
    if off[1] == 0 and off[2] > 0 then simple_dir = 2
    elseif off[1] == 0 and off[2] < 0 then simple_dir = 0
    elseif off[1] > 0 then simple_dir = 1
    else simple_dir = 3 end
    local real_dir = u.dir_map[simple_dir]
    -- opposite_direction (2026-07-07, coal_pair): two SAME-type entities (e.g. two
    -- burner-mining-drills) facing EACH OTHER so each one's mined output auto-feeds
    -- the other's fuel inventory (real vanilla mechanic, no cheat -- matches the
    -- already-live-verified geometry in spatial_bc.py's _build_coal_drill_pair).
    -- Without this the secondary would default to facing north regardless of which
    -- side it's on, which is wrong for a drill (though harmless for a directionless
    -- chest/furnace) and would also make its OWN can_place_entity check below use
    -- the wrong footprint if that entity's collision box isn't rotation-symmetric.
    local secondary_dir = real_dir
    if step.opposite_direction then
      secondary_dir = u.dir_map[(simple_dir + 2) % 4]
    end
    -- primary_exists (2026-07-07, furnace-upgrade task): the primary is an
    -- ALREADY-PLACED entity (e.g. from find_existing) -- it's not being placed
    -- by this task, so it must NOT be can_place_entity-checked (it already
    -- occupies that spot; checking would always fail against itself).
    local primary_moved = not step.primary_exists and
      clear_natural_obstacles(surf, step.primary, {x = t.ctx.px, y = t.ctx.py}) or {}
    local primary_ok = step.primary_exists or
      surf.can_place_entity{name = step.primary, position = {x = t.ctx.px, y = t.ctx.py}, direction = real_dir, force = c.entity.force}
    restore_moved(primary_moved)
    -- secondary_resource (2026-07-07, furnace-upgrade task): the secondary's
    -- candidate tile must ALSO have this resource underneath (e.g. a new drill
    -- next to an existing furnace still needs REAL ore there) -- otherwise a
    -- tile that merely passes can_place_entity but sits on bare ground would be
    -- silently accepted, matching the same real-ore requirement run_verify_tile
    -- already enforces for a find_patch-derived primary.
    local secondary_resource_ok = true
    if step.secondary_resource then
      local ore = surf.find_entities_filtered{name = step.secondary_resource, position = {x = sx, y = sy}, radius = 1}
      secondary_resource_ok = #ore > 0
    end
    local secondary_moved = clear_natural_obstacles(surf, step.secondary, {x = sx, y = sy})
    local secondary_ok = surf.can_place_entity{name = step.secondary, position = {x = sx, y = sy}, direction = secondary_dir, force = c.entity.force}
    restore_moved(secondary_moved)
    -- ORE-MIXUP FIX, secondary side (2026-07-19, approved-fixes item 1 -- see
    -- footprint_is_exclusive_resource's own comment above for the full mechanism/
    -- Zdendys quote): applies whenever the SECONDARY being placed is itself a
    -- mining-drill (e.g. coal_pair's two facing drills) -- the primary-side check
    -- in run_find_patch only ever covers the PRIMARY's own footprint, so a
    -- straddling SECONDARY drill was still possible without this. Expected
    -- resource: step.secondary_resource when the caller explicitly named one
    -- (furnace-upgrade task -- primary_exists, ctx.px/py is an EXISTING furnace,
    -- not a resource tile, so there's nothing to read off it), else the resource
    -- named by the find_governing_resource lookup above (coal_pair-class tasks --
    -- primary IS a resource tile there, its OWN find_patch step is the
    -- authoritative source, not a nearby-entity guess).
    local secondary_exclusive_ok = true
    if prototypes.entity[step.secondary] and prototypes.entity[step.secondary].type == "mining-drill" then
      local expected_resource = step.secondary_resource or find_governing_resource(t)
      if expected_resource then
        secondary_exclusive_ok = footprint_is_exclusive_resource(surf, step.secondary, {x = sx, y = sy}, expected_resource, c.entity.force)
      end
    end
    if primary_ok and secondary_resource_ok and secondary_ok and secondary_exclusive_ok then
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
    -- Diagnostic: WHY this specific candidate failed, plus what's actually there.
    -- 2026-07-12 (task #46): uses the shared u.dump_context() helper instead of a
    -- hand-rolled find_entities_filtered loop (see queues.lua's collision diagnostic
    -- for the OTHER caller) -- picks up a tile-name check for free, which this
    -- candidate diagnostic never had before (a strict improvement, not a behavior
    -- change to the entity-name part).
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
