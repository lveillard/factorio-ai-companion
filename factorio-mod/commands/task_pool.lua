-- AI Companion -- generic task pool (2026-07-07, Zdendys's redesign)
--
-- Replaces Python-orchestrated monolithic macros (which block on ONE goal's whole
-- step sequence at a time, and restart every step from scratch after any failure)
-- with a mod-side pool: Python submits an ORDERED list of generic atomic STEPS
-- under a task_id. The mod derives item NEEDS from those steps, reserves whatever
-- is already on hand, and works through the remaining steps of ALL currently-
-- submitted tasks together -- each time the companion goes idle, the NEXT step
-- executed is whichever ready task's next step is CLOSEST to the companion right
-- now (task_id order as the tiebreak), not necessarily the same task as last time.
-- This is what lets an unrelated-but-nearby task's step get done WHILE a slow/
-- distant task is still working out its own next move, instead of the whole
-- companion sitting idle-but-blocked on one goal (Zdendys: "coal_pair @259k je
-- naprosto nepredstavitelne pomalu").
--
-- Procurement (mining raw ore, crafting intermediate items) is NOT reimplemented
-- here -- a task with unmet needs just stays blocked until enough of the needed
-- item exists in the main inventory; something ELSE (the existing gather_queues/
-- craft_queues macros, or a future task that supplies coal/plates as a side
-- effect) is expected to top that up. This keeps this first version's scope to
-- the mechanism Zdendys actually described tonight (pool/reservation/priority),
-- not a from-scratch reimplementation of every existing procurement macro.
--
-- Step vocabulary (v1 -- exactly what iron_drill/stone_drill/coal_pair/coal_pair
-- upgrade/furnace-upgrade need, not yet a fully general DSL):
--   {type="find_patch", resource=NAME}                 -> ctx.px, ctx.py
--   {type="find_existing", entity=NAME, radius=N}       -> ctx.px, ctx.py
--   {type="set_position", x=, y=}                       -> ctx.px, ctx.py
--   {type="verify_tile", resource=NAME}                -> aborts task if patch gone
--   {type="pick_orientation", primary=ENTITY, secondary=ENTITY, offsets={{dx,dy},...},
--                             opposite_direction=true|nil, primary_exists=true|nil,
--                             secondary_resource=NAME|nil,
--                             ignore_entities_at={{x=,y=},...}|nil}
--                                                       -> ctx.sx, ctx.sy, ctx.dir, ctx.dir2
--   {type="place", which=/x,y/ref/candidates={{x=,y=,dir=},...}, entity=NAME, dir=N,
--                  mirror=true|nil}                       -> horizontal mirror (live-
--                                                             verified: burner-mining-drill's
--                                                             own drop_position flips side)
--   {type="remove", which=/x,y/ref=, entity=NAME}
--   {type="fuel", which=/x,y/ref=, item=NAME, count=N}
--   {type="read_drop_position", which=/x,y/ref=, entity=NAME, save_as=NAME}
--                                                       -> ctx.saved[save_as]
--   {type="ensure_item", item=NAME, count=N}            -> gathers/crafts NAME
--                                                          up to N in inventory
--                                                          BEFORE the next step
--
-- ensure_item (2026-07-17, Zdendys's own architecture correction: procurement was
-- kept OUT of this module by the ORIGINAL v1 design above, back when neither
-- recipe resolution nor a hand-craftable check existed anywhere in this repo --
-- both now do (resolve_recipe/HAND_CRAFTABLE_CATEGORIES below, mirroring
-- companion.py's get_recipe_ingredients; queues.start_gather/start_craft), so
-- there is no longer a reason to keep this Python's job). Recursively resolves
-- missing INGREDIENTS first (bottom-up, exactly like ColdStartOpening.ensure_item,
-- spatial_demo.py) via an explicit stack in ctx.ensure_stack, bounded to depth
-- ENSURE_ITEM_MAX_DEPTH -- a raw/minable resource (no recipe) is gathered via the
-- existing gather_queues machinery, a non-hand-craftable recipe (smelting) fails
-- fast instead of wasting a doomed start_craft attempt, and wood (no
-- gather()-compatible resource-tile path -- trees are type="tree", not
-- type="resource") is chopped via its own small bounded walk+mine sub-state.
-- Should normally be the FIRST step of a task whose later place/fuel steps
-- consume the same item, so the whole task is self-sufficient once submitted.
--
-- find_existing (2026-07-07, furnace-upgrade task): locates an ALREADY-PLACED
-- entity by name nearest the companion's CURRENT position (radius search, no
-- ore/resource patch involved) and sets ctx.px/py to it -- for a task that
-- upgrades something already built (e.g. adding a drill next to a lone
-- bootstrap furnace, Zdendys: "it's the same as building a new pair, but the
-- furnace is already there, just add a drill to it") rather than starting from a raw
-- resource tile like find_patch does.
--
-- pick_orientation's primary_exists (2026-07-07, furnace-upgrade task): when
-- true, the primary (at ctx.px/py, e.g. an EXISTING furnace from find_existing)
-- is NOT can_place_entity-checked or re-placed -- it's already there. Only the
-- secondary's (e.g. a NEW drill's) candidate offset is checked/placed. Pairs
-- with secondary_resource=NAME to ALSO require that offset tile actually have
-- that resource underneath (a drill next to an existing furnace still needs
-- REAL ore there, same as run_verify_tile checks for the primary elsewhere) --
-- without this a candidate could pass can_place_entity yet sit on bare ground.
--
-- pick_orientation's ignore_entities_at (2026-07-07, coal_pair v1->v2 upgrade safety
-- fix): for an UPGRADE task that will "remove" existing entities and rebuild wider at
-- the SAME anchor, checking the wider candidates BEFORE removing anything can suffer
-- FALSE rejections (the still-present old entities' collision boxes can overlap a
-- wider candidate's footprint). Pass the old entities' known {x=,y=} positions here --
-- they get teleported far away, checked, and teleported back, all within this single
-- call (no player-visible flicker, no tick where they're actually gone) -- letting the
-- caller verify a rebuild position is valid BEFORE ever issuing a "remove" step, so a
-- failed pick_orientation never leaves a working setup mid-demolished.
--
-- Every place/fuel/remove/read_drop_position step resolves ITS OWN target
-- position the SAME way (step_target_pos), trying in order: explicit {x=,y=}
-- (caller precomputed it) > candidates[1] (nominal walking target only -- see
-- "place"'s own candidates note for actual placement resolution) > {ref=NAME}
-- (a position an earlier read_drop_position step in THIS task saved under that
-- name) > which="primary"|"secondary" (ctx.px/py or ctx.sx/sy, from find_patch/
-- pick_orientation earlier in this task).
--
-- "place"'s candidates (2026-07-07, live-caught TWICE across separate runs: a
-- single precomputed position -- e.g. an inserter placed exactly 1 tile from a
-- chest's read_drop_position -- can intermittently fail with "Cannot place
-- (collision)" from sub-tile snap variance at that specific spot, even though
-- the SAME code succeeds on a different map). An optional list of {x=,y=,dir=}
-- alternatives lets the caller offer a few nearby fallback spots; the FIRST one
-- that passes can_place_entity at "acting" time is used -- mirrors
-- pick_orientation's own try-candidates-in-order robustness, applied to a
-- single free-standing placement instead of a primary/secondary pair.
--
-- read_drop_position (2026-07-07, coal_pair upgrade task) reads an entity's LIVE
-- LuaEntity.drop_position -- the engine's own already-rotated absolute output
-- position -- rather than reimplementing vector_to_place_result rotation math on
-- the Python side (a real, verified-via-doc field; deliberately not guessed).
-- Lets a task place a chest/container exactly where an EXISTING drill's mined
-- output actually lands, whatever direction that drill happens to face.
--
-- "place" also accepts an explicit simple-0-3 `dir` (bypassing ctx.dir/dir2,
-- which only exist when a pick_orientation step ran earlier in this task) --
-- needed when the caller precomputed the whole layout itself with no
-- pick_orientation step at all.

local u = require("commands.init")
local queues = require("commands.queues")
local ledger = require("commands.task_pool_ledger")
local ensure_item = require("commands.task_pool_ensure_item")
local targeting = require("commands.task_pool_targeting")
local steps = require("commands.task_pool_steps")

local M = {}

local FUEL_REACH = 3      -- mirrors fac_building_fuel's own radius (building.lua)
local WALK_REACH = targeting.WALK_REACH
local step_target_pos = targeting.step_target_pos
local task_ready = targeting.task_ready
local run_read_drop_position = steps.run_read_drop_position
local run_find_existing = steps.run_find_existing
local run_set_position = steps.run_set_position
local run_find_patch = steps.run_find_patch
local run_verify_tile = steps.run_verify_tile
local run_pick_orientation = steps.run_pick_orientation

-- ensure_item step (2026-07-17, Zdendys's own architecture correction -- see
-- task_pool_ensure_item.lua's own header for the full design/history): the
-- {type="ensure_item", item=NAME, count=N} step's actual recipe-resolution/
-- gather/craft/chop engine moved there in the 2026-07-19 size-refactor split
-- (this file only dispatches to ensure_item.start_ensure_item_action below and
-- handles the resulting "gather"/"craft"/"chop" async polling itself, since that
-- polling is scheduler state, not procurement logic).
local WOOD_CHOP_REACH = 3           -- mirrors fac_mine_entity's own distance<=15 check loosely; close enough to swing
                                     -- (sole remaining use: the "chop" dispatch below, in M.tick)

function M.init()
  storage.tasks = storage.tasks or {}
  storage.next_task_id = storage.next_task_id or 1
  storage.reserved = storage.reserved or {}
  -- storage.active_step[cid] = {task_id=, state="walking"|"acting"} -- at most ONE step
  -- in flight per companion at a time (single physical entity, can only do one thing).
  storage.active_step = storage.active_step or {}
end

-- ---- needs derivation + reservation ledger ----
-- Moved to task_pool_ledger.lua (2026-07-12 size-refactor split): derive_needs,
-- fail_task, complete_task, M.submit_task, M.get_task_status now live there --
-- see that file for the full historical-rationale comments attached to each.
-- Thin re-exports below so external callers (require("commands.task_pool").
-- submit_task/.get_task_status) keep working unchanged.
M.submit_task = ledger.submit_task
M.get_task_status = ledger.get_task_status

-- step_target_pos/task_ready moved to task_pool_targeting.lua (2026-07-19
-- size-refactor split) -- see local aliases above (targeting.step_target_pos/
-- task_ready/WALK_REACH).

-- The 6 run_* synchronous step handlers (read_drop_position/find_existing/
-- set_position/find_patch/verify_tile/pick_orientation) + their private
-- clear_natural_obstacles/restore_moved/run_pick_orientation_checks helpers
-- moved to task_pool_steps.lua (2026-07-19 size-refactor split) -- see local
-- aliases above.

-- ---- main scheduler tick ----

-- Picks the single best (task, step) to advance right now: among all ACTIVE, READY
-- tasks whose companion is currently IDLE, prefer the one whose current step's
-- target is CLOSEST to the companion; ties broken by task_id (older task wins --
-- Zdendys: "stari kroku odpovida cca poradi taskID").
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

-- Re-check every active task's outstanding `needs` against CURRENT inventory
-- (2026-07-07, live-caught in scripts/test_task_pool.py: a task submitted before
-- its coal arrived stayed stuck on cursor 1 forever -- `needs` was computed ONCE
-- at submit_task time and nothing ever refreshed it afterward, even though the
-- whole point of submitting ahead of having materials is that something else
-- -- gather_queues, another task's own by-product, a later delivery -- can supply
-- them in the meantime). Iterates tasks in task_id order (oldest first) so an
-- older task claims newly-available stock before a younger one, consistent with
-- the pool's own task_id tiebreak elsewhere.
--
-- ONLY does this work for companions whose inventory actually CHANGED since the
-- last tick (2026-07-07, Zdendys: "Ono neni jakym jinym zpusobem, bez zasahu
-- companiona samotneho, by doslo ke zmene stavu jeho inventare!" -- correct,
-- inventory only ever changes as a result of the companion's OWN actions
-- (mining/crafting/fueling/collecting), so polling get_item_count for every
-- outstanding need on EVERY tick regardless was wasted work on every tick where
-- nothing could possibly have changed. storage.inv_count_cache[cid] tracks the
-- last-seen total item count per companion; a plain sum is enough to detect ANY
-- change cheaply without needing to hook into every individual queue type's own
-- completion point (harvest/gather/craft/fuel/build each add or remove items in
-- their own way -- comparing the total sidesteps enumerating all of them).
local function refresh_needs()
  local ids = {}
  for task_id, t in pairs(storage.tasks) do
    if t.status == "active" and next(t.needs) ~= nil then ids[#ids + 1] = task_id end
  end
  if #ids == 0 then return end
  table.sort(ids)
  storage.inv_count_cache = storage.inv_count_cache or {}
  -- reservation_epoch check (2026-07-09, see release_reservations' own comment for the
  -- full live-caught symptom): a task's needs must be re-evaluated not just when ITS
  -- OWN companion's inventory total changes, but also whenever ANY task anywhere
  -- released a reservation -- that release alone can be exactly what makes previously
  -- unavailable stock available now, with zero accompanying inventory-total change
  -- for THIS companion. epoch_changed is true at most once per actual release (cheap),
  -- and forces the full inv-count-mismatch bypass below for every pending task this
  -- call, exactly once.
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
          local already_reserved = storage.reserved[item] or 0
          local available = math.max(0, have - already_reserved)
          local take = math.min(available, deficit)
          if take > 0 then
            storage.reserved[item] = already_reserved + take
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

-- 2026-07-08, task #42: true if cid is busy in gather/fuel/build/belt_queues (see the
-- "Extended" comment at this function's call site below for the full rationale).
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
        -- Bounded give-up (2026-07-08/09, task-pool's OWN walking phase previously had
        -- NO deadline at all -- see the dispatch site's own comment for the live
        -- symptom this caused). Mirrors queues.lua's identical "cannot reach -> fail
        -- and let the caller retry/relocate" pattern instead of spinning forever.
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
        -- Explicit step.dir (simple 0-3, 2026-07-07 coal_pair upgrade) overrides
        -- ctx.dir/dir2 when the caller precomputed the whole layout itself (no
        -- pick_orientation step at all for this task) -- translated the SAME way
        -- pick_orientation does, so callers use the identical simple convention.
        local place_dir
        if step.dir ~= nil then
          place_dir = u.dir_map[step.dir]
        else
          place_dir = (step.which == "secondary" and t.ctx.dir2) or t.ctx.dir or 0
        end
        -- candidates (2026-07-07, live-caught): a SINGLE precomputed {x,y,dir}
        -- position (e.g. an inserter placed 1 tile from a chest read via
        -- read_drop_position) can intermittently collide -- observed twice
        -- across separate live runs with the EXACT same code on different maps
        -- (sub-tile snap variance at that specific spot, not a logic bug). An
        -- optional list of {x=,y=,dir=} alternatives lets the caller offer a
        -- few nearby fallback spots; the FIRST one that passes can_place_entity
        -- is used, mirroring pick_orientation's own try-candidates-in-order
        -- robustness instead of committing to one fixed spot with no recourse.
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
            -- Bounded retry across ticks (2026-07-08, task #35) instead of failing on
            -- the FIRST check: live-observed "no candidate position free" 3x across
            -- separate runs with the exact same code on different maps, leading
            -- hypothesis being a transient/settling-timing collision (sub-tile snap
            -- variance, or a moment where something else briefly occupies the tile)
            -- rather than a genuine permanent block. can_place_entity is re-evaluated
            -- fresh every tick (no caching here), so simply trying again on a LATER
            -- tick gives a transient blocker a real chance to clear before giving up
            -- -- same "bounded deadline, not instant give-up" pattern already used for
            -- approach_deadline elsewhere in this file. 60 ticks is deliberately short
            -- (this is meant to catch a passing moment, not wait out a real block) --
            -- a genuinely permanent collision still correctly fails, just after a
            -- few retries instead of zero.
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
        local kind, err2 = ensure_item.start_ensure_item_action(c, cid, t)
        if kind == "satisfied" then
          table.remove(t.ctx.ensure_stack)
          if #t.ctx.ensure_stack == 0 then
            -- Reset to nil, not just an empty table (2026-07-17, live-caught crash:
            -- "attempt to index local 'need' (a nil value)" at start_ensure_item_action's
            -- own `local need = stack[#stack]`). t.ctx is shared across ALL steps of
            -- this task, and a task can have MULTIPLE ensure_item steps in a row (e.g.
            -- build_ore_drill_row_unit_steps' burner-mining-drill THEN stone-furnace,
            -- coal_pair.py). Leaving ensure_stack as `{}` here made line 866's own
            -- `t.ctx.ensure_stack or {...}` initializer a no-op for the NEXT ensure_item
            -- step -- an empty table is truthy in Lua -- so that step ran
            -- start_ensure_item_action against a permanently empty stack instead of
            -- pushing its own need, crashing every tick forever (active_step never
            -- cleared -> companion deadlocked for the rest of the episode).
            t.ctx.ensure_stack = nil
            -- Clear alongside ensure_stack (2026-07-27, same "shared across ALL
            -- steps of this task" reasoning as the comment above): without this,
            -- a stale expired deadline from an EARLIER ensure_item step could make
            -- a LATER step needing the SAME item name skip its own fresh 30s wait
            -- window entirely (see task_pool_ensure_item.lua's own SMELT_WAIT_TICKS
            -- docstring).
            t.ctx.smelt_wait_deadline = nil
            -- step_ticks (2026-07-28, action-timing instrumentation): recorded at
            -- every cursor advance, keyed by the PRE-increment cursor (the step
            -- that just finished) -- active.step_start_tick was stamped once when
            -- this step first entered active_step (see the 2 creation sites below),
            -- and survives the walking->acting sub-state transition untouched, so
            -- this captures the full wall-to-wall duration, not just the final
            -- sub-phase.
            t.step_ticks = t.step_ticks or {}
            t.step_ticks[t.cursor] = {type = step.type, start = active.step_start_tick, done = game.tick}
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
        elseif kind == "wait" then
          -- Waiting on an already-running furnace to top up a smelted ingredient
          -- (2026-07-27, see task_pool_ensure_item.lua's own SMELT_WAIT_TICKS
          -- docstring) -- no state change, same as "push": reassess next tick
          -- until either the stock arrives (kind flips to "satisfied") or the
          -- bounded wait deadline passes (kind flips to a genuine failure).
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
        -- Pick up an existing entity (2026-07-07, coal_pair upgrade task: reuses
        -- the 2 ALREADY-BUILT coal_pair drills rather than crafting new ones --
        -- Zdendys: "zvedne obe vrtacky, nemusi je vyrabet"). Uses the SAME
        -- native-mine pattern already proven in commands/building.lua's
        -- fac_mine_entity (target.mine{inventory=...}, success measured by
        -- inventory count actually increasing -- mine{} leaves the entity INTACT
        -- if the inventory can't hold the result, no silent item loss/no cheat).
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
            type = {"furnace", "boiler", "burner-inserter", "mining-drill"}}
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
          -- step_ticks: see the "ensure_item" cursor-advance site above for the
          -- full rationale (same capture, same pre-increment cursor key).
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
        -- Sync ctx to the REAL placed position (2026-07-07, live-caught): create_entity
        -- can snap a 2x2 entity to a different grid alignment than the 1x1 ore tile
        -- position find_patch recorded (observed: requested (46.5,-185.5), actually
        -- landed at (47,-185)). If this was the PRIMARY and a secondary offset was
        -- already chosen (pick_orientation ran before this), recompute sx/sy from the
        -- REAL px/py so the secondary's own place step doesn't overlap the primary's
        -- true footprint -- fuel steps use step_target_pos too, so this must happen
        -- before either later step's target position is read.
        if step.which == "primary" and st.position then
          t.ctx.px, t.ctx.py = st.position.x, st.position.y
          if t.ctx.offset_dx then
            t.ctx.sx = t.ctx.px + t.ctx.offset_dx
            t.ctx.sy = t.ctx.py + t.ctx.offset_dy
          end
        elseif step.which == "secondary" and st.position then
          t.ctx.sx, t.ctx.sy = st.position.x, st.position.y
        end
        -- step_ticks: see the "ensure_item" cursor-advance site (near line 404) for
        -- the full rationale. This is the "place" step's own completion point.
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
      -- Polls whichever underlying queue/walk start_ensure_item_action started,
      -- to completion, then falls back to "acting" so the NEXT "acting" pass
      -- reassesses t.ctx.ensure_stack fresh (real inventory counts, not a
      -- remembered target) -- exactly like ensure_item's own Python recursion,
      -- one incremental step of progress per round trip through this state.
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

  -- Companion(s) currently idle -> pick the next (task, step) to start.
  -- MUST also check storage.walking_queues[cid] is empty, not just active_step[cid]
  -- (2026-07-08, Zdendys live-caught via a movement/distance statistics review: "could
  -- not reach furnace" firing even at trivial distances like 12-18 tiles, proving this
  -- was never about map layout). active_step[cid] only tracks whether the TASK POOL
  -- itself is driving this companion -- it says nothing about an UNRELATED walk Python
  -- may have just started via /fac_move_to (e.g. spatial_bc.py's go_to() for furnace
  -- servicing, iron_drill upgrade, etc.), which sets storage.walking_queues[cid]
  -- directly without ever touching active_step[cid]. Without this guard, THIS loop
  -- runs every tick and, the moment a task-pool task is ready to walk somewhere, freely
  -- overwrites storage.walking_queues[cid] mid-flight -- silently discarding whatever
  -- unrelated destination Python had just set, so the companion walks toward the
  -- task-pool's target instead while Python's wait_arrive() keeps blocking on a
  -- destination she was never actually walking to anymore. Confirmed live: coal_pair's
  -- task-pool build was active in the SAME window as a failed "could not reach furnace"
  -- iron_drill-upgrade go_to(), at a distance (12-18 tiles) trivially walkable otherwise.
  -- Extended (2026-07-08, task #42, same session as the walking_queues fix above):
  -- walking_queues[cid] alone only protects the WALKING phase of gather/fuel/build/
  -- belt_queues -- once one of those arrives and moves on to its own "acting" phase
  -- (mining, fueling, placing), walking_queues[cid] clears (arrival) while the
  -- companion is STILL busy for that subsystem's purposes. Without also checking
  -- these, the task pool could grab a companion mid-mine/mid-fuel/mid-build from a
  -- direct (non-task-pool) command and redirect her walking_queues[cid] to its own
  -- target, corrupting that other queue's in-progress state. None of these are set
  -- by the task pool itself (task_pool.lua never calls start_gather/start_fuel_group/
  -- start_belt_connect, and start_build's task-pool-internal use is guarded
  -- separately at the fac_building_place_start command level, not here), so this
  -- check is one-directional and safe: it only ever holds off task_pool for a
  -- companion genuinely busy elsewhere.
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
          -- approach_deadline (2026-07-08/09, live-caught: run_reactive's own new
          -- async-pending stale-exemption -- added specifically to stop penalizing
          -- LEGITIMATE in-flight task-pool work -- immediately started firing its
          -- "task-pool work pending for 40 actions with no resolution" backstop
          -- repeatedly, live, meaning this "walking" state genuinely never resolves
          -- on its own sometimes). Root cause: unlike EVERY OTHER queue type in this
          -- codebase (queues.lua's tick_gather_queues/tick_fuel_queues/
          -- tick_build_queues, pathfind.lua's belt_connect walk), this generic
          -- task-pool "walking" state (tick()'s own handler right above) had NO
          -- deadline at all -- if storage.walking_queues[cid] never clears (a
          -- persistently blocked approach, or some other queue silently claiming the
          -- companion mid-walk), active.state just sits at "walking" forever, the
          -- task never transitions to done/failed, and Python's own task_status()
          -- poll waits indefinitely. Distance-scaled exactly like
          -- tick_gather_queues' own q.approach_deadline (25 ticks/tile, floor 1800)
          -- for consistency with the rest of the codebase's convention.
          local walk_deadline = u.approach_deadline(c.entity.position, pos)
          -- step_start_tick (2026-07-28, action-timing instrumentation): stamped
          -- once here, when the step FIRST enters active_step -- covers the
          -- walking phase too, so the eventual step_ticks entry (see M.tick's own
          -- cursor-advance sites) reflects the full wall-to-wall duration, not
          -- just the "acting" sub-phase. Never reset by the later
          -- walking->acting transition (M.tick just flips active.state in place).
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

-- Diagnostic (2026-07-09, task pool investigation): dumps everything relevant to WHY a
-- companion's task-pool work might be stuck -- active_step state/deadline, the task's
-- own status/cursor/needs, walking_queues entry, and the busy_elsewhere flags -- in one
-- call, so a live stall can be root-caused without guessing from static code reading.
-- Read-only, no side effects.
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
    -- 3 queue types added 2026-07-09 (task #46, "faster error diagnosis"): get_diag
    -- otherwise silently omitted these 3 of the 7 async queue types that
    -- companion_queue_status (init.lua) already knows about, so a companion stuck
    -- specifically on a harvest/craft/combat queue looked indistinguishable from
    -- "not busy at all" through this diagnostic.
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
  -- Merge in gather's own richer engine-level diagnostics (state/selected/
  -- mining_state_mining/entity_pos, added 2026-07-09 for the #41 stall investigation)
  -- so a stuck-on-gather companion doesn't need a SEPARATE /fac_gather_status round
  -- trip on top of this call (task #46). peek=true (2026-07-11): this function is
  -- explicitly documented as read-only/no-side-effects -- must NOT consume+clear a
  -- gather queue's terminal "done" state (see get_gather_status's own "peek" comment
  -- for why that would silently discard the final gathered count).
  if out.busy_gather then
    out.gather = queues.get_gather_status(cid, true)
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
