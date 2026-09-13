-- AI Companion -- BUILD queue (2026-07-19 size-refactor split out of
-- queues.lua). Verbatim move.

local u = require("commands.init")
local core = require("commands.queues_core")

local valid_companion = core.valid_companion
local process_queue = core.process_queue

local M = {}

local BUILD_TICKS = 60

-- Entity types that block character movement (used for approach-position search).
-- These MUST be valid Factorio 2.0 prototype TYPE names, not entity names — a
-- single invalid string makes find_entities_filtered{type=...} raise and (without
-- the pcall in control.lua) would crash the whole tick scheduler. Notably:
-- steam-engine's type is "generator"; chests are "container"/"logistic-container".
local SOLID_TYPES = {
  "offshore-pump", "boiler", "generator", "pipe", "pipe-to-ground",
  "mining-drill", "furnace", "assembling-machine", "inserter",
  "transport-belt", "splitter", "underground-belt",
  "lab", "wall", "gate", "electric-pole", "container", "logistic-container",
  "storage-tank", "beacon", "radar", "solar-panel", "accumulator",
  "roboport", "pump", "cliff"
}

-- Find a walkable tile near build_pos from which the character can reach it
--
-- Minimum distance raised 3->4 (2026-07-16, Zdendys: "aby companion pri stavbe byl
-- alespon 4 ctverce daleko od plochy, kterou bude budova zabirat... aby ho snap
-- nezachytil" -- a placed entity can land up to ~0.5 tile from its requested position
-- due to Factorio's own snap_to_grid behavior on grid-aligned entity types, already
-- root-caused for the bridge-pipe case, see task_pool.lua's own "sub-tile snap
-- variance" comments; margin against her own body ending up inside the final
-- footprint). Flat distance from `build_pos` (not per-entity footprint-aware) --
-- Zdendys explicitly asked for the simple version, flagging a valid concern first
-- (checked directly against this Factorio install's own prototype data, not assumed):
-- `position` is the collision_box CENTER for every entity type this project places
-- EXCEPT offshore-pump (asymmetric collision_box, position offset ~0.375 tiles from
-- its true center) -- a full 1-tile margin increase here comfortably covers that one
-- outlier too (4 - 0.375 = 3.625, still well above the old 3-tile floor). 3 dropped
-- from the candidate list entirely (not just de-prioritized) so it can never be
-- chosen even as a last resort among these candidates; only the very last, all-
-- candidates-blocked fallback below still needs its own check.
local function find_approach_pos(surf, char_pos, build_pos)
  local candidates = {}
  for _, dist in ipairs({5, 4, 6, 7}) do
    for _, angle in ipairs({0, 45, 90, 135, 180, 225, 270, 315}) do
      local rad = math.rad(angle)
      local p = {
        x = math.floor(build_pos.x + dist * math.sin(rad) + 0.5),
        y = math.floor(build_pos.y - dist * math.cos(rad) + 0.5)
      }
      local blocked = surf.find_entities_filtered{position = p, radius = 0.5, type = SOLID_TYPES}
      if #blocked == 0 then
        candidates[#candidates + 1] = {pos = p, dist = u.distance(char_pos, p)}
      end
    end
  end
  if #candidates > 0 then
    table.sort(candidates, function(a, b) return a.dist < b.dist end)
    return candidates[1].pos
  end
  return {x = build_pos.x, y = build_pos.y - 5}
end

-- Remove trees, small rocks, and loose items from the entity's collision footprint
--
-- CORRECTION (2026-07-27, discard-investigation-pause, coal-row seed extension):
-- the 2026-07-17 note below (now removed) concluded a lying item-entity does NOT
-- block placement, based on a single live test with a freshly create_entity'd item
-- at an otherwise-clear tile. That conclusion was directly DISPROVEN this pause by
-- a live A/B test at an actual failing coordinate ((-60,25), burner-mining-drill,
-- "Cannot place (collision)"): `can_place_entity` returned false with a real
-- item-on-ground present, then TRUE after teleporting that exact item away (and,
-- separately, teleporting the companion's own body away made no difference --
-- ruling out self-collision). Matches this same session's independent
-- collision_mask finding (item-entity shares the "item"/"is_lower_object" layers
-- with a normal solid entity) already applied to fac_building_place (building.lua,
-- commit c2c47db) and to _build_iron_output_inserter's proactive furnace-output
-- drain (belt_connect_ops.py, commit 5c73768) -- this was the third, still-unfixed
-- code path for the identical bug class: task_pool.lua's "place" step routes
-- through queues.start_build, whose clearing state only cleared trees/rocks.
local function clear_build_area(surf, entity_name, position, inv)
  local proto = prototypes.entity[entity_name]
  if not proto or not proto.collision_box then return end
  local bb = proto.collision_box
  local area = {
    {x = position.x + bb.left_top.x - 0.5, y = position.y + bb.left_top.y - 0.5},
    {x = position.x + bb.right_bottom.x + 0.5, y = position.y + bb.right_bottom.y + 0.5}
  }
  local obstacles = surf.find_entities_filtered{area = area, type = {"tree", "simple-entity"}}
  for _, obs in ipairs(obstacles) do
    -- REVERTED (2026-08-02, task #82 course-correction -- Zdendys, direct: "Companion
    -- nemuze prestat sbirat drevo! To by nam prekazelo pri stavbach pasu budov a
    -- cestovani!" -- the companion must NEVER refuse to collect wood, since clearing
    -- obstacles is required for construction/movement to work at all. The 2026-08-01
    -- WOOD_STOCK_CAP "discard via bare mine{}" attempt (this same function, since
    -- reverted) solved the SYMPTOM (uncapped inventory growth) by discarding material
    -- outright -- wrong fix. The real design: wood is ALWAYS collected here exactly
    -- like before any of today's fixes; managing a wood SURPLUS happens entirely on
    -- the Python side instead -- burning it preferentially as fuel once abundant, and
    -- (a separate, larger follow-up) depositing overflow into a per-building fuel
    -- chest+inserter once truly excessive. See [[project_wood_surplus_management_
    -- 2026_08_02]] (Claude memory) for the full redesign.
    if obs.valid then obs.mine{inventory = inv} end   -- MINE (wood/stone into inventory), not free-destroy
  end
  for _, it in ipairs(surf.find_entities_filtered{area = area, type = "item-entity"}) do
    if it.valid and it.stack and it.stack.valid_for_read then
      local moved = inv.insert(it.stack)
      if moved >= it.stack.count then it.destroy() end
    end
  end
end

-- Self-collision step-away distance (2026-07-13, universal own-body-blocks-own-build
-- fix): how far to physically walk the companion away from a build target whose
-- collision check keeps failing because HER OWN body overlaps the footprint. Derived
-- from the ENTITY'S OWN collision_box (same prototypes.entity lookup already used by
-- clear_build_area above) rather than a fixed guess -- this is now the SHARED path for
-- EVERY building type placed through start_build/place_smart/task-pool "place" steps,
-- and a fixed offset proven fine for a small building (burner-mining-drill,
-- stone-furnace) can be too SHORT for a much larger one. Confirmed live for
-- steam-engine (collision_box {{-1.25,-2.35},{1.25,2.35}}): demonstrator_power.py's own
-- place_dir had to widen its step-away from (x+3,y+3) to (x+5,y+5) after the smaller
-- offset still left her inside the ~3.34-tile padded danger radius (see that file's own
-- place_dir docstring for the exact math) -- computing the real per-entity corner
-- distance here avoids guessing at all. Matches building.lua's own self-collision
-- padding (+-0.5 tile each side, per that same analysis) plus a flat +2 tile safety
-- margin beyond the padded corner.
local function step_away_distance(entity_name)
  local proto = prototypes.entity[entity_name]
  if not proto or not proto.collision_box then return 3 end
  local bb = proto.collision_box
  local hx = math.max(math.abs(bb.left_top.x), math.abs(bb.right_bottom.x)) + 0.5
  local hy = math.max(math.abs(bb.left_top.y), math.abs(bb.right_bottom.y)) + 0.5
  return math.sqrt(hx * hx + hy * hy) + 2
end

-- Bounded retry count (2026-07-13): a genuinely-blocked tile (occupied by something
-- OTHER than the companion herself) must still fail normally rather than looping
-- forever stepping away pointlessly -- this caps how many step-away-and-retry cycles
-- the BUILDING state below will attempt before falling through to the existing failure
-- path, same order of magnitude as this file's other bounded retries (place_verified's
-- tries=3, direction_achieved's tries=5).
local MAX_SELF_COLLISION_STEP_AWAY = 2

-- Start a smart build: auto-approach + auto-clear + place
-- State machine: approaching -> clearing -> building -> done
function M.start_build(cid, entity_name, position, direction, mirror)
  local c = valid_companion(cid)
  if not c then return {error = "Invalid companion"} end

  local dir = direction or defines.direction.north
  local inv = c.entity.get_main_inventory()
  if inv.get_item_count(entity_name) < 1 then
    return {error = "No " .. entity_name .. " in inventory"}
  end

  -- Find safe approach position and start walking there
  local approach = find_approach_pos(c.entity.surface, c.entity.position, position)
  storage.walking_queues[cid] = {target = approach}

  storage.build_queues[cid] = {
    entity = entity_name,
    position = position,
    direction = dir,
    -- mirror (2026-07-18, coal-mining-row task): horizontal mirroring for
    -- directional entities that support it (live-verified: burner-mining-
    -- drill's own drop_position flips to the opposite side of its footprint
    -- when mirror=true, same direction otherwise -- needed so a drill tapping
    -- a shared belt from the OPPOSITE side still ejects onto the same
    -- absolute side as one tapping from the near side, instead of the plain
    -- 180-degree rotation's mirrored-through-center result). nil for every
    -- OTHER existing caller (never set) -- Factorio's own create_entity/
    -- can_place_entity treat a nil mirror field identically to omitting it,
    -- so this is a no-op for all pre-existing build_queues use.
    mirror = mirror or nil,
    approach = approach,
    state = "approaching",
    tick_start = game.tick,
    -- run_start_tick (2026-07-28, action-timing instrumentation, batch 2): a
    -- SEPARATE field from tick_start, which this domain reuses/resets at
    -- several state transitions (clearing->building, approaching-retry) to
    -- drive get_build_status's own progress percentage -- unusable as a
    -- stable whole-run marker. This domain already has a "done"/"failed"
    -- freeze grace period (get_build_status consumes it exactly once before
    -- deleting), so run_end_tick (set at each terminal transition below) is
    -- reliably readable by the next poll.
    run_start_tick = game.tick,
    -- Bounded deadline for the approach walk (2026-07-07, live-caught via
    -- task_pool.lua: a companion that couldn't physically reach the build target
    -- left this queue stuck in "approaching" forever -- CLAUDE.md checklist item
    -- #3, this was the ONE async queue in this file missing the deadline every
    -- other one (tick_gather_queues/tick_fuel_queues/belt_connect) already has).
    -- Same distance-scaled formula as those: 25 ticks/tile, floor 1800.
    approach_deadline = u.approach_deadline(c.entity.position, approach),
  }

  return {started = true, entity = entity_name, position = position, state = "approaching"}
end

function M.tick_build_queues()
  process_queue("build_queues", function(cid, q, c)
    local surf = c.entity.surface
    local reach = c.entity.build_distance or 10

    -- TERMINAL: sit here (do nothing more) until get_build_status consumes+clears this entry.
    -- Returning true immediately on failure used to delete the queue in the SAME tick it was set,
    -- so a Python poll a moment later saw plain "active:false" -- indistinguishable from success
    -- (place_smart then reported {"placed": true} for a build that never happened; the entity was
    -- never created, e.g. collision or item consumed mid-walk). Now the failure reason survives
    -- until it is actually read.
    if q.state == "done" or q.state == "failed" then return false end

    -- STEPPING_AWAY (2026-07-13, self-collision fix): walk a short distance away from
    -- the build target so the companion's own body clears the footprint, then hand off
    -- to the existing "approaching" state to walk back within reach for a fresh
    -- collision-check retry window. Bounded deadline (mirrors every other movement-
    -- waiting state in this file, CLAUDE.md checklist item 3) so a companion that
    -- somehow can't even reach the nearby step-away point doesn't hang here forever --
    -- either way (arrived or timed out) falls through to "approaching" and from there a
    -- normal build attempt, since ANY distance away from where she was already helps.
    if q.state == "stepping_away" then
      local arrived = u.distance(c.entity.position, q.step_away_target) <= 1
      if arrived or game.tick >= q.step_away_deadline then
        storage.walking_queues[cid] = nil
        c.entity.walking_state = {walking = false}
        local approach = find_approach_pos(surf, c.entity.position, q.position)
        storage.walking_queues[cid] = {target = approach}
        q.approach = approach
        q.state = "approaching"
        q.approach_deadline = u.approach_deadline(c.entity.position, approach)
      end
      return false
    end

    -- APPROACHING: wait until character is within build reach of target
    if q.state == "approaching" then
      -- Nil-safe heal for a build_queues entry persisted by an OLDER mod version
      -- (before approach_deadline existed): give it a fresh deadline instead of
      -- either failing it instantly (bare "or 0" would make game.tick>=0 true on
      -- the very next check) or leaving it to hang forever (mirrors the identical
      -- fix already applied to belt_connect's own walking-with-deadline entries).
      if not q.approach_deadline then
        q.approach_deadline = u.approach_deadline(c.entity.position, q.position)
      end
      if u.distance(c.entity.position, q.position) <= reach then
        storage.walking_queues[cid] = nil
        c.entity.walking_state = {walking = false}
        q.state = "clearing"
      elseif game.tick >= q.approach_deadline then
        storage.walking_queues[cid] = nil
        c.entity.walking_state = {walking = false}
        q.failed = "cannot reach build target (" .. q.position.x .. "," .. q.position.y .. ")"
        q.run_end_tick = game.tick
        q.state = "failed"
      end
      return false
    end

    -- CLEARING: remove trees/rocks from build footprint
    if q.state == "clearing" then
      clear_build_area(surf, q.entity, q.position, c.entity.get_main_inventory())
      q.state = "building"
      q.tick_start = game.tick
      -- Fresh collision-retry window for THIS building attempt (2026-07-13): without
      -- this reset, a stale collision_retry_deadline left over from an EARLIER failed
      -- attempt (e.g. the one that just triggered a self-collision step-away and
      -- re-approach below) would already be in the past the moment we re-enter
      -- BUILDING, making the very next can_place_entity check think its 60-tick
      -- retry budget is already exhausted -- defeating the step-away fix entirely
      -- (it would immediately re-evaluate self-collision/fail again with zero actual
      -- retry ticks elapsed).
      q.collision_retry_deadline = nil
      return false
    end

    -- BUILDING: wait BUILD_TICKS then place
    if q.state == "building" then
      if game.tick - q.tick_start < BUILD_TICKS then return false end

      -- Re-check reach (companion may have drifted)
      if u.distance(c.entity.position, q.position) > reach then
        local approach = find_approach_pos(surf, c.entity.position, q.position)
        storage.walking_queues[cid] = {target = approach}
        q.approach = approach
        q.state = "approaching"
        return false
      end

      -- COLLISION CHECK (same guard the game applies to a player): create_entity does
      -- NOT reject overlaps, so without this the async build could stack a building on
      -- top of another (observed: output furnace overlapping the drill by one row).
      -- Refuse instead of force-overlapping; the caller verifies via entity presence.
      -- This check already runs IMMEDIATELY before create_entity below (same tick, same
      -- function call, zero movement in between) -- the gap task #35 actually needed
      -- closed was never "check happens too early", it was "check fails once -> give up
      -- immediately, no retry at all" (unlike task_pool.lua's OWN candidates check,
      -- which already retries for 60 ticks -- see that fix, commit 464185f -- this was
      -- the one remaining unprotected collision check task #35's own investigation
      -- found). 2026-07-08, Zdendys: "let the check be immediately before the build,
      -- without any movement" (the check IS already right before the build with no movement -- what
      -- was missing was giving a TRANSIENT collision a chance to clear before failing
      -- the whole task over it). Bounded retry IN PLACE first (same 60-tick budget as
      -- the task_pool.lua candidates fix) -- if STILL blocked once that expires, a
      -- SELF-collision (her own body overlapping the footprint) additionally gets a
      -- bounded step-away-and-retry below (2026-07-13 fix, see step_away_distance's own
      -- docstring) -- superseding the older "no re-approach, no step-away, she's already
      -- within reach and isn't moved here" design, which assumed the collision was
      -- always something else and could never be cleared by an in-place wait alone. A
      -- genuinely permanent OTHER-cause collision still correctly fails, just after a
      -- few retries instead of the very first check, exactly as before.
      if not surf.can_place_entity{name = q.entity, position = q.position,
                                   direction = q.direction, force = c.entity.force,
                                   mirror = q.mirror} then
        q.collision_retry_deadline = q.collision_retry_deadline or (game.tick + 60)
        if game.tick < q.collision_retry_deadline then
          -- Re-sweep the footprint on every retry tick (2026-07-27), not just once
          -- during the earlier CLEARING state -- a dropped item can reappear on the
          -- same tile between retries (e.g. a full-inventory mine dropping the
          -- excess right back where it was picked up), and a passive wait alone
          -- would never clear it before the 60-tick budget runs out.
          clear_build_area(surf, q.entity, q.position, c.entity.get_main_inventory())
          return false
        end
        -- SELF-COLLISION STEP-AWAY (2026-07-13, universal own-body-blocks-own-build
        -- fix, Zdendys: "the companion must never block her own construction,
        -- whatever the building is"): determine whether her own body is (one of) the actual
        -- blocker(s) by temporarily teleporting her far away (same teleport-and-
        -- restore technique already proven for ignore_entities_at/
        -- clear_natural_obstacles in task_pool.lua) and re-running the SAME
        -- can_place_entity check with her excluded:
        --   * still blocked even without her -> some OTHER obstruction (occupied tile,
        --     unbuildable terrain) -- fail normally below; stepping away would never
        --     help and would just loop pointlessly on a genuinely-blocked tile.
        --   * now placeable -> her own body WAS (one of) the blocker(s) -- physically
        --     walk her away and back (mirrors the already-proven place_verified/
        --     place_dir/place_pipe step-away pattern) and give the collision check a
        --     fresh retry window, bounded to MAX_SELF_COLLISION_STEP_AWAY attempts so
        --     a persistent OTHER obstruction that happens to also overlap her current
        --     position still eventually fails instead of looping forever.
        local self_pos = {x = c.entity.position.x, y = c.entity.position.y}
        c.entity.teleport({x = self_pos.x + 10000, y = self_pos.y + 10000})
        local clear_without_self = surf.can_place_entity{name = q.entity, position = q.position,
                                     direction = q.direction, force = c.entity.force,
                                     mirror = q.mirror}
        c.entity.teleport(self_pos)
        q.self_collision_step_away_count = q.self_collision_step_away_count or 0
        if clear_without_self and q.self_collision_step_away_count < MAX_SELF_COLLISION_STEP_AWAY then
          q.self_collision_step_away_count = q.self_collision_step_away_count + 1
          local d = step_away_distance(q.entity)
          local step_away = {x = q.position.x + d, y = q.position.y + d}
          storage.walking_queues[cid] = {target = step_away}
          q.step_away_target = step_away
          q.state = "stepping_away"
          q.step_away_deadline = u.approach_deadline(c.entity.position, step_away)
          return false
        end
        -- Diagnostic (2026-07-08, task #35): a bare "Cannot place (collision)" carried
        -- zero forensic info in every prior occurrence -- log what's ACTUALLY at the
        -- target once retries are exhausted, including whether the companion's own
        -- body (collision_box {{-0.2,-0.2},{0.2,0.2}}, verified in base game prototype
        -- data) is the culprit, same "log every retry" lesson as place_pipe()'s own
        -- diagnostic in demonstrator.py. Tile check (2026-07-08, live-caught same
        -- night as this fix): a first live occurrence showed NO entity/companion
        -- overlap at all (AABB boxes computed by hand, 0.44-tile gap) --
        -- can_place_entity also rejects unbuildable TILES (water, out-of-map), which
        -- find_entities_filtered can never reveal since tiles aren't entities.
        -- Logging the tile name closes that blind spot.
        -- 2026-07-12 (task #46): both the nearby-name dump and the tile check now come
        -- from the shared u.dump_context() helper instead of duplicating this same
        -- find_entities_filtered+get_tile logic inline (see task_pool.lua's
        -- run_pick_orientation_checks for the OTHER caller of this same helper).
        local diag = u.dump_context(surf, q.position, {radius = 1.5, companion = c.entity})
        u.log_error(string.format(
          "build queue: Cannot place %s at (%.1f,%.1f) tile=%s after %d retry ticks " ..
          "(self_collision_clear=%s, step_away_attempts=%d) -- nearby: %s",
          q.entity, q.position.x, q.position.y, diag.tile, 60, tostring(clear_without_self),
          q.self_collision_step_away_count, table.concat(diag.nearby, ",")),
          "build_queue")
        q.failed = "Cannot place (collision)"
        q.run_end_tick = game.tick
        q.state = "failed"
        return false
      end

      -- Re-check the item is STILL in inventory right before placing (it may have been consumed
      -- during the walk -- crafted away / dropped). Never create a building for free.
      if c.entity.get_main_inventory().get_item_count(q.entity) < 1 then
        q.failed = "No " .. q.entity .. " in inventory"
        q.run_end_tick = game.tick
        q.state = "failed"
        return false
      end
      local placed = surf.create_entity{
        name = q.entity,
        position = q.position,
        direction = q.direction,
        force = c.entity.force,
        mirror = q.mirror
      }
      -- Only keep the building if a real item was actually consumed; else remove it (no free build).
      local destroyed = false
      if placed and c.entity.remove_item{name = q.entity, count = 1} < 1 then
        placed.destroy()
        destroyed = true
      end
      if not placed then
        q.failed = "create_entity returned nil"
        q.run_end_tick = game.tick
        q.state = "failed"
        return false
      end
      if destroyed then
        q.failed = "item consumed before placement could complete"
        q.run_end_tick = game.tick
        q.state = "failed"
        return false
      end
      -- Capture the REAL post-snap position (2026-07-07, live-caught via task_pool.lua):
      -- create_entity does NOT always place at the exact requested q.position -- Factorio
      -- snaps an entity to its own valid grid alignment (e.g. a 2x2 drill requested at a
      -- 1x1 ore tile's half-tile-centered position (46.5,-185.5) actually landed at
      -- (47,-185), a 0.5-tile shift in both axes). A caller that computes a SECOND
      -- entity's position as an offset from the ORIGINAL requested q.position (not the
      -- real one) can end up overlapping the first entity's real footprint. (placed is
      -- guaranteed valid here -- the destroyed case returned above already.)
      q.placed_position = {x = placed.position.x, y = placed.position.y}
      q.run_end_tick = game.tick
      q.state = "done"
      return false
    end

    q.run_end_tick = game.tick
    return true
  end)
end

function M.get_build_status(cid)
  local q = storage.build_queues[cid]
  if not q then return {active = false} end
  -- Terminal states are consumed HERE (not by tick_build_queues) so the result -- success OR the
  -- failure reason -- survives long enough for a Python poll to actually read it. Previously the
  -- queue was deleted the same tick a failure was detected, so the NEXT poll just saw plain
  -- "active:false" (indistinguishable from success) and place_smart reported a build that never
  -- happened as {"placed": true}.
  if q.state == "done" then
    storage.build_queues[cid] = nil
    return {active = false, placed = true, position = q.placed_position,
      run_start_tick = q.run_start_tick, run_end_tick = q.run_end_tick}
  end
  if q.state == "failed" then
    storage.build_queues[cid] = nil
    return {active = false, placed = false, error = q.failed,
      run_start_tick = q.run_start_tick, run_end_tick = q.run_end_tick}
  end
  local progress = 0
  if q.state == "approaching" then progress = 10
  elseif q.state == "stepping_away" then progress = 55  -- self-collision fix, 2026-07-13
  elseif q.state == "clearing" then progress = 50
  elseif q.state == "building" then
    progress = 60 + math.floor((game.tick - q.tick_start) / BUILD_TICKS * 40)
  end
  return {
    active = true,
    entity = q.entity,
    position = q.position,
    state = q.state,
    progress = progress
  }
end

function M.stop_build(cid)
  if not storage.build_queues[cid] then return {stopped = false} end
  storage.walking_queues[cid] = nil
  storage.build_queues[cid] = nil
  return {stopped = true}
end

return M
