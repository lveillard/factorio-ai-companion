-- AI Companion v0.9.0 - Tick-based queue system
local u = require("commands.init")
local core = require("commands.queues_core")
local craft = require("commands.queues_craft")
local combat = require("commands.queues_combat")
local belt = require("commands.queues_belt")
local harvest = require("commands.queues_harvest")
local fuel = require("commands.queues_fuel")

local M = {}

-- FUEL GROUP (2026-07-19 size-refactor split -- see queues_fuel.lua) -- re-exported so
-- every existing external caller (control.lua) keeps working unchanged.
M.start_fuel_group = fuel.start_fuel_group
M.tick_fuel_queues = fuel.tick_fuel_queues
M.get_fuel_status = fuel.get_fuel_status

-- HARVEST + ORPHANED MINING SAFETY NET (2026-07-19 size-refactor split -- see
-- queues_harvest.lua) -- re-exported so every existing external caller
-- (control.lua, commands/resource.lua) keeps working unchanged.
M.start_harvest = harvest.start_harvest
M.start_mining_next = harvest.start_mining_next
M.tick_harvest_queues = harvest.tick_harvest_queues
M.get_harvest_status = harvest.get_harvest_status
M.stop_harvest = harvest.stop_harvest
M.tick_orphan_mining_cleanup = harvest.tick_orphan_mining_cleanup

-- BELT CONNECT (2026-07-19 size-refactor split -- see queues_belt.lua) -- re-exported
-- so every existing external caller (commands/building.lua) keeps working unchanged.
M.start_belt_connect = belt.start_belt_connect
M.tick_belt_queues = belt.tick_belt_queues
M.get_belt_connect_status = belt.get_belt_connect_status
M.stop_belt_connect = belt.stop_belt_connect

-- CRAFT (2026-07-19 size-refactor split -- see queues_craft.lua) -- re-exported so
-- every existing external caller (commands/item.lua) keeps working unchanged.
M.start_craft = craft.start_craft
M.tick_craft_queues = craft.tick_craft_queues
M.get_craft_status = craft.get_craft_status
M.stop_craft = craft.stop_craft

-- COMBAT (2026-07-19 size-refactor split -- see queues_combat.lua) -- re-exported so
-- every existing external caller (commands/combat.lua) keeps working unchanged.
M.start_combat = combat.start_combat
M.tick_combat_queues = combat.tick_combat_queues
M.get_combat_status = combat.get_combat_status
M.stop_combat = combat.stop_combat

-- Constants
-- TICK_INTERVAL/MINE_ADJACENT_RANGE now live in queues_core.lua (2026-07-19 size-refactor
-- split, shared across harvest/gather/combat -- see that file's own comments for the
-- "why" behind each value); aliased here so every existing bare-name call site below
-- (harvest/gather/fuel/craft/build/belt/combat, not yet split into their own files)
-- keeps working completely unchanged.
local TICK_INTERVAL = core.TICK_INTERVAL
local BUILD_TICKS = 60
local MINE_ADJACENT_RANGE = core.MINE_ADJACENT_RANGE
-- SELECT_FAIL_TICKS (2026-07-11, live-reproduced iron-ore-gather-returns-0 bootstrap
-- stall, scripts/test_gather_select_fail.py -- see that test + queues.lua's "mine" state
-- comment below for the full mechanism): `character.selected = <entity>` is documented
-- (Factorio runtime API, LuaControl::selected) to SILENTLY CLEAR the selection instead of
-- erroring when the target isn't currently selectable -- confirmed live to happen
-- INTERMITTENTLY for an otherwise perfectly valid, in-range (well under both
-- MINE_ADJACENT_RANGE and the character's own 2.7-tile reach_resource_distance),
-- amount>0 resource tile, with no code-visible cause pinned down (same distance/tile
-- shape succeeds most of the time). A short, tick-count-based (not distance-scaled)
-- retry budget before giving up on THIS tile and trying the next candidate -- small
-- enough to recover fast (a few real seconds even at normal game speed), bounded so it
-- can never itself hang.
-- KNOWN LIMITATION (live-verified 2026-07-11, scripts/test_gather_select_fail.py,
-- select_fail_verify.log): this only self-heals the "selected didn't stick for THIS
-- one tile" shape. A live repro (scratchpad/r8a.log) also caught a SECOND, structurally
-- different failure where `selected` sticks correctly and mining_state.mining stays
-- true continuously for 2500+ ticks at a fine distance, yet gathered stays 0 the whole
-- time -- this guard does nothing there (selected == res, so the branch below never
-- fires). Also, in roughly half of live test runs the "didn't stick" failure recurs on
-- EVERY candidate tried in the session, not just one bad tile -- the blacklist-and-
-- retry below then burns through the entire reachable field before giving up (fast,
-- loud failure instead of a silent hang -- real but modest value), which suggests the
-- true defect may be session-wide rather than per-tile. Root cause of both NOT yet
-- pinned down; see scripts/test_gather_select_fail.py's docstring for the full status.
local SELECT_FAIL_TICKS = 120

-- Forward declaration (2026-07-13, closing the "667 coal tiles blacklisted within one
-- fresh episode" incident -- see the APPROACH-STALL-RESPAWN comment inside process_queue
-- below for the full root-cause analysis): respawn_companion_entity is defined further
-- down this file (after find_reachable_resource), but process_queue's generic
-- UNIVERSAL_STALE_TICKS backstop -- defined further UP, well before either of those --
-- also needs to call it. Declaring the local here (and assigning the real function body
-- to it later, without its own `local`) lets process_queue's closure capture this SAME
-- variable slot; Lua only resolves the call at RUN time, by which point the real
-- assignment below has long since executed (module load order is linear, but all
-- functions in this file are only ever CALLED from later dispatch, never at load time).
local respawn_companion_entity

-- DIAGNOSTIC (2026-07-11, Mode A/B gather-select-fail investigation -- see
-- scripts/live_investigate_mode_b.py, scripts/live_investigate_selected_distance.py,
-- scripts/live_investigate_mode_a_preposition.py, scripts/live_investigate_mode_a_
-- nearby_obstacles.py). Records a per-cycle (every TICK_INTERVAL=5 ticks -- finer than
-- any Python-side poll can afford over RCON) sample of mining_state.mining/selected/
-- walking_state/total-inventory/position while in the "mine" state, fetchable via the
-- new /fac_mine_diag <cid> command.
--
-- EXTENSION (2026-07-11, same day, follow-up round): the sampling window now ALSO
-- covers the preceding "approach" (walking) state, not only "mine" -- previously the
-- buffer was reset (wiped) only once "mine" began, so every walking-phase tick was
-- silently discarded before it could ever be observed. This was the completeness
-- critic's own concrete recommendation from the prior round, aimed specifically at the
-- still-open question of what differs between a WALKED arrival and a TELEPORTED one
-- (see the "remains OPEN" paragraph below) -- that transition boundary was entirely
-- unobserved until now. Samples are tagged `st = "approach"` or `st = "mine"` so a
-- consumer can split or filter the two phases of one continuous attempt; the buffer
-- now resets at the START of "approach" (not at the "approach"->"mine" handoff), so one
-- reset covers one whole continuous walk-then-mine attempt at a single candidate tile.
-- Purely additive/observational -- no change to any actual mine-state decision logic.
-- This round did NOT use the extended data to chase the mystery further (by design --
-- see game_progress.md's 2026-07-11 entry for why); that is left to a dedicated future
-- session with fresh capacity.
--
-- STATUS as of 2026-07-11 (KEPT DELIBERATELY, not temporary -- the investigation below
-- used this instrumentation to make real progress and will likely need it again):
-- a 20-attempt live batch found best_d<~1.0 tile reliably fails `selected` (0% stick)
-- while best_d in [1.3,2.0] reliably succeeds (~100% stick) -- but a SURGICAL follow-up
-- (raw teleport+assign, no queue machinery) showed `selected` sticks fine at EVERY
-- distance 0.2-2.2 in isolation, and a PRE-TELEPORT follow-up (teleport to the SAME
-- close distances 0.5-1.9, THEN start the real gather() queue) recorded `selm`=true on
-- 100% of sampled cycles in all 5 attempts (scripts/live_investigate_mode_a_
-- preposition.py, /tmp/preposition.log) -- a clean contrast with the near-0% stick rate
-- typical of a genuine walking-triggered failure -- supporting that the failure is NOT
-- caused by final distance itself, only by arriving there via the natural multi-tick
-- WALKING approach. HONEST CAVEAT (adversarial review caught this before commit): all 5
-- of those attempts nonetheless gathered exactly 14 of the requested 15 (never 15,
-- across 5 independent random maps) -- a separate, oddly consistent off-by-one
-- discrepancy, NOT yet investigated, that is almost certainly unrelated to the
-- selection-stick mechanism (selm stayed 100% throughout) but should not be quietly
-- read as "5/5 clean passes". A nearby-clearable-obstacle (tree/rock) check
-- also found NO correlation (fails with 0 obstacles nearby, passes with 0 or 1). Root
-- cause of what specifically differs between "walked there" and "teleported there"
-- remains OPEN -- one live-confirmed contributing detail: tick_gather_queues runs
-- BEFORE process_walking_queues in the same on_nth_tick(5) dispatch (control.lua),
-- and walking_state is only re-evaluated every TICK_INTERVAL=5 ticks while the ENGINE
-- keeps applying the last-set walking_state continuously in between -- so natural
-- arrival can overshoot the intended stopping point by up to ~1 tile of travel per
-- cycle, which explains the VARIABLE landing distances but not yet the selection
-- failure mechanism itself. Do not remove this instrumentation without re-reading this
-- comment; it is cheap (bounded 4000-entry ring buffer, reset every new mine attempt).
local MINE_DIAG_CAP = 4000
local function _record_mine_diag(cid, sample)
  storage.mine_diag = storage.mine_diag or {}
  local buf = storage.mine_diag[cid]
  if not buf then buf = {}; storage.mine_diag[cid] = buf end
  buf[#buf + 1] = sample
  if #buf > MINE_DIAG_CAP then table.remove(buf, 1) end
end

-- valid_companion/process_queue/UNIVERSAL_STALE_TICKS now live in queues_core.lua
-- (2026-07-19 size-refactor split -- see that file's own copy for the full body/
-- comments, byte-identical). Aliased here so every existing bare-name call site
-- below (harvest/gather/fuel/craft/build/belt/combat, not yet split into their own
-- files) keeps working completely unchanged.
local valid_companion = core.valid_companion
local process_queue = core.process_queue

function M.init()
  storage.harvest_queues = storage.harvest_queues or {}
  storage.gather_queues = storage.gather_queues or {}
  storage.fuel_queues = storage.fuel_queues or {}
  storage.craft_queues = storage.craft_queues or {}
  storage.build_queues = storage.build_queues or {}
  storage.combat_queues = storage.combat_queues or {}
  storage.belt_queues = storage.belt_queues or {}
  storage.mine_diag = storage.mine_diag or {}   -- diagnostic, see MINE_DIAG_CAP comment above
end

-- Diagnostic accessor (Mode A/B gather-select-fail investigation) -- returns the
-- per-cycle "mine" state trace buffer for `cid` (empty list if none recorded yet, e.g.
-- never entered "mine").
function M.get_mine_diag(cid)
  storage.mine_diag = storage.mine_diag or {}
  return storage.mine_diag[cid] or {}
end

-- HARVEST + ORPHANED MINING SAFETY NET moved to queues_harvest.lua (2026-07-19
-- size-refactor split) -- see re-exports above.

-- ============ GATHER (autonomous: find reachable patch -> walk -> mine to target) ============
-- Self-contained composite: the mod finds the nearest REACHABLE + SAFE patch of `resource`, walks the
-- companion within reach, and mines it NATIVELY via character.mining_state (same speed/animation/
-- extraction as a real player holding the mine button; amount--, game removes depleted tile), moving
-- to the next patch until the inventory holds `count` of the mined product (or no reachable patch
-- remains). Replaces the Python go_to + start_harvest + poll glue.
-- shared tile-key helper (gather blacklist of unreachable patches + fuel-group visited set)
-- -- now lives in queues_core.lua (2026-07-19 size-refactor split, see that file's own
-- comment) since FUEL GROUP moved to its own file and needs it too; aliased here so every
-- GATHER call site below (not yet split, batch 11) keeps working unchanged.
local _tile_key = core.tile_key

local function find_reachable_resource(surf, from, resource, blacklist)
  local ores = surf.find_entities_filtered{name = resource, position = from, radius = 400}
  table.sort(ores, function(a, b) return u.distance(a.position, from) < u.distance(b.position, from) end)
  for _, e in ipairs(ores) do
    if e.valid and (e.amount or 0) > 0
       and not (blacklist and blacklist[_tile_key(e.position)])
       and surf.count_entities_filtered{type = "unit-spawner", position = e.position, radius = 20} == 0
       and surf.find_non_colliding_position("character", e.position, 2.5, 0.5) then
      return e
    end
  end
  -- Diagnostic (2026-07-08, live-caught: gather("coal",5) stalled ~42 real seconds with
  -- 0 gathered on one live run, despite an isolated repro of the identical call
  -- completing in ~2s -- no code difference found between the two paths, so the
  -- CAUSE must be map/entity-state-specific to that one run. This logs exactly WHY
  -- the search came up empty (zero candidates at all vs. every candidate rejected by
  -- a specific filter), so the next occurrence shows the real reason instead of just
  -- "gathered 0" with no further clue. Zdendys: "If something is 'unreachable' it is a
  -- bug! NEVER the map's fault!" -- this is a diagnostic-only addition, no behavior change.
  local total = #ores
  local depleted, blacklisted, near_spawner, no_stand_pos = 0, 0, 0, 0
  for _, e in ipairs(ores) do
    if e.valid then
      if (e.amount or 0) <= 0 then depleted = depleted + 1
      elseif blacklist and blacklist[_tile_key(e.position)] then blacklisted = blacklisted + 1
      elseif surf.count_entities_filtered{type = "unit-spawner", position = e.position, radius = 20} > 0 then
        near_spawner = near_spawner + 1
      elseif not surf.find_non_colliding_position("character", e.position, 2.5, 0.5) then
        no_stand_pos = no_stand_pos + 1
      end
    end
  end
  u.log_error(string.format(
    "find_reachable_resource: no usable %s within 400 tiles of (%.1f,%.1f) -- total=%d "
    .. "depleted=%d blacklisted=%d near_spawner=%d no_stand_pos=%d",
    resource, from.x, from.y, total, depleted, blacklisted, near_spawner, no_stand_pos),
    "gather_queue")
  return nil
end

-- SELECT-FAIL ENTITY RESPAWN (2026-07-11, Phase 3 of the mode-a-select-fail
-- investigation -- see memory/mode_a_select_fail_investigation_2026_07_11.md,
-- "Phase 2" section, for the full live-tested chain of evidence this is built on).
-- Phase 2 disambiguated (destroy-old-entity + respawn-same-id) that the "selected
-- never sticks" failure is NOT caused by any mod tick handler, queue type, or
-- companion id/registration state -- identical code/id/storage record worked
-- perfectly the instant the underlying entity was replaced. There is therefore no
-- "handler clobbering .selected" for THIS fix to stop -- the targeted recovery is
-- to destroy the entity currently exhibiting the failure and respawn a fresh one
-- under the same companion id, preserving position/inventory/name/color.
--
-- STREAK THRESHOLD REVISED SAME DAY, based on live regression evidence this fix's
-- OWN first test run produced (see scripts run 2026-07-11 late night, Phase 3):
-- an initial version required SELECT_FAIL_RESPAWN_STREAK=3 DIFFERENT candidate
-- tiles to fail in a row before respawning, on the (Phase 2-derived) theory that
-- one broken entity fails many different tiles identically. Live testing
-- immediately falsified the THRESHOLD choice (not the mechanism): a real
-- gather("stone",5) lockout reproduced (25/25 "mine" samples selm=false, entire
-- reachable stone field blacklisted, gathered=0) on a companion whose entity was
-- only ~1 real minute old (freshly spawned that same test run, and it had JUST
-- gathered coal perfectly moments before) -- directly contradicting Phase 2's
-- "long-lived entity" framing as the ONLY trigger. Worse, the streak=3 threshold
-- never even fired here: this map's reachable stone was apparently confined to
-- one patch neighborhood, so find_reachable_resource exhausted to "done" (no
-- candidates left) after just ONE blacklist episode -- never reaching a 2nd or
-- 3rd distinct failing tile to accumulate the streak. Across all 6 regression
-- trials run that night (2 each of coal/stone/iron-ore), the failure signature was
-- STRICTLY bimodal -- either 0 select-fail samples the whole attempt, or 100% of
-- samples failing until the SELECT_FAIL_TICKS budget ran out -- never a partial/
-- occasional miss. That bimodal shape means a single full lockout episode is
-- already a reliable signal (not noise), so waiting for repeats before recovering
-- only lets small reachable fields get wiped out first. Lowered to 1: respawn
-- immediately after the FIRST time SELECT_FAIL_TICKS's own retry budget is
-- exhausted for any one candidate. This is still an honest MITIGATION for the
-- observed symptom, not a fix for the underlying engine mystery (WHY selection
-- becomes unassignable, and why it is not strictly tied to entity age as Phase 2
-- believed, is still not understood -- see this file's own live-test log for the
-- falsifying data point).
local SELECT_FAIL_RESPAWN_STREAK = 1

-- Assigns into the `local respawn_companion_entity` forward-declared near the top of this
-- file (NOT `local function` here -- that would shadow the forward declaration with a
-- brand-new local, leaving process_queue's earlier closure permanently pointing at nil).
function respawn_companion_entity(cid, c)
  local old = c.entity
  local pos, surf, force = old.position, old.surface, old.force
  -- Snapshot inventory BEFORE destroying -- old.get_inventory() is unusable the
  -- instant old.destroy() runs.
  local contents = {}
  local inv = old.get_inventory(defines.inventory.character_main)
  if inv then contents = inv.get_contents() end
  if c.label and c.label.valid then c.label.destroy() end
  old.destroy()
  local new_pos = surf.find_non_colliding_position("character", pos, 5, 0.5) or pos
  local e = surf.create_entity{name = "character", position = new_pos, force = force}
  if not e then
    u.log_error(string.format(
      "respawn_companion_entity: failed to create a replacement character for companion " ..
      "%d at (%.1f,%.1f) -- companion is now WITHOUT AN ENTITY, will read as dead",
      cid, new_pos.x, new_pos.y), "gather_queue")
    return false
  end
  e.color = c.color
  local new_inv = e.get_inventory(defines.inventory.character_main)
  if new_inv then
    for _, item in pairs(contents) do
      new_inv.insert{name = item.name, count = item.count, quality = item.quality}
    end
  end
  c.entity = e
  c.label = u.render_label(e, c.name, c.color)
  u.log_error(string.format(
    "respawn_companion_entity: companion %d's character entity replaced at (%.1f,%.1f) " ..
    "after %d consecutive select-fail blacklist events with no successful mine in between " ..
    "(Phase 2 mode-a-select-fail mitigation)", cid, new_pos.x, new_pos.y,
    SELECT_FAIL_RESPAWN_STREAK), "gather_queue")
  game.print("[" .. (c.name or ("#" .. cid)) .. " respawned -- entity was stuck (selection " ..
    "bug), continuing]", u.print_color(u.COLORS.system))
  return true
end
-- Registers the real function above with queues_core.lua's own indirection (2026-07-19
-- size-refactor split) so process_queue (now in that separate file) can still reach it --
-- see queues_core.lua's own comment on register_respawn_fn for the full "why".
core.register_respawn_fn(respawn_companion_entity)

function M.start_gather(cid, resource, count, exclude, from_task_pool)
  local c = valid_companion(cid)
  if not c then return {error = "Invalid companion"} end
  -- Don't steal this companion from an ACTIVE task-pool step (2026-07-08, task #42,
  -- generalizing move.lua's fac_move_to guard from earlier tonight to the other
  -- storage.walking_queues[cid] writers): task_pool.lua's tick() drives a companion
  -- toward its own step targets independently of whatever Python is doing right now:
  -- an unguarded gather() call here would silently overwrite that in-progress walk the
  -- same way direct move_to() used to. Reject instead -- Python callers already retry
  -- on their own next cycle when a dispatch is refused.
  --
  -- from_task_pool (2026-07-17, "ensure_item" step type): task_pool.lua's OWN
  -- "acting"/"ensuring" state machine calls this function AS THE IMPLEMENTATION of
  -- an ensure_item step, while storage.active_step[cid] is necessarily already set
  -- (that's how tick() got here in the first place) -- the guard above would
  -- otherwise reject task_pool.lua's own internal call with the exact error message
  -- meant for a DIFFERENT, external caller trying to steal the companion. This flag
  -- is set ONLY by task_pool.lua's own internal call site; every other caller
  -- (Python's /fac_resource_mine, the opening's own gather() helpers) omits it and
  -- keeps the original guard, byte-identical to before this fix.
  if not from_task_pool and storage.active_step and storage.active_step[cid] then
    return {error = "companion busy with an active task-pool step"}
  end
  -- exclude (2026-07-07, Zdendys/Claude: replacing the Python-side manual
  -- goto_resource()+mine_and_wait() flow, which needed its OWN distance-vs-
  -- MINE_DIST guessing purely to know "did I arrive" -- a guessed threshold
  -- that kept landing on the wrong side of the mod's real MINE_ADJACENT_RANGE
  -- boundary across 3 separate live-caught bugs today. gather() already does
  -- the whole walk+adjacency+mine cycle server-side with no Python distance
  -- math at all; the ONE thing it was missing to fully replace goto_resource
  -- was a way for the CALLER to say "skip these positions, already proven
  -- unreachable/exhausted this episode" -- goto_resource's own persistent
  -- per-resource exclude list (spatial_bc.py's resource_exclude). Optional
  -- list of {x=,y=} tables, seeded into q.blacklist UPFRONT using the SAME
  -- tile-key format find_reachable_resource/tick_gather_queues already use
  -- internally for patches THIS queue discovers unreachable on its own.
  local blacklist = {}
  if exclude then
    for _, p in ipairs(exclude) do
      blacklist[_tile_key(p)] = true
    end
  end
  storage.gather_queues[cid] = {resource = resource, target = count, state = "find",
    last_mine_tick = 0, blacklist = blacklist}
  return {started = true, resource = resource, target = count}
end

function M.tick_gather_queues()
  process_queue("gather_queues", function(cid, q, c)
    local surf = c.entity.surface
    local inv = c.entity.get_main_inventory()

    -- TERMINAL: freeze here until get_gather_status consumes+clears this entry -- same fix
    -- already applied to build_queues/fuel_queues (see those functions' own "TERMINAL"
    -- comments above). Returning true immediately on completion used to delete the queue
    -- in the SAME tick completion was detected, so a Python status poll a moment later saw
    -- plain "active:false" with NO "gathered" field at all -- gather()'s on_poll callback
    -- in companion.py then kept reporting whatever "gathered" value it had last observed
    -- WHILE still active, which is systematically short of the real total whenever the
    -- final unit(s) are credited to inventory by the engine between one process_queue tick
    -- and the next, and this very completion sweep removes the queue before any poll can
    -- ever observe "active:true, gathered:target". Root-caused 2026-07-11 from a
    -- reproducibly exact target-1 result (never target) across 5 independent live attempts,
    -- scripts/live_investigate_mode_a_preposition.py, /tmp/preposition.log -- see
    -- game_progress.md's "gather()-returns-(target-1)" entry for the full trace.
    if q.state == "done" then return false end

    if q.state == "find" then
      local e = find_reachable_resource(surf, c.entity.position, q.resource, q.blacklist)
      if not e then
        -- Bounded retry (2026-07-08, live-caught: gather("coal") returned {gathered=0,
        -- done=true, blacklist=[]} on the VERY FIRST check on one fresh map -- 5
        -- follow-up trials with the same map-gen settings all found 400-600+ reachable
        -- coal patches, ruling out "genuinely no coal nearby" as the norm. A transient
        -- miss here (e.g. this companion's own position not yet settled right after
        -- spawn, or some other momentary condition) previously gave up PERMANENTLY on
        -- the very first empty result with no second look at all -- same class of fix
        -- as the collision-retry above, just for "found nothing" instead of "found
        -- something blocked".
        q.find_retry_deadline = q.find_retry_deadline or (game.tick + 300)
        if game.tick < q.find_retry_deadline then return false end
        q.state = "done"; return false   -- no reachable patch left after retrying -> done, return what we have
      end
      local mp = e.prototype.mineable_properties
      if not (mp and mp.products and mp.products[1]) then
        -- Non-standard resource (no item product, e.g. a fluid-only patch) -- blacklist this
        -- tile and retry next tick instead of crashing on a nil index.
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
      -- distance-scaled deadline: 25 ticks/tile (~3.7x the expected walk) so a legit long walk is
      -- never aborted, but a companion STUCK on an obstacle (standable != path-reachable) bails fast
      -- instead of hanging the whole 180s (the "3 min and 0 coal" bug).
      q.approach_deadline = u.approach_deadline(c.entity.position, e.position)
      -- radius=1 (not 3): walk essentially ONTO the resource tile, not just "in the
      -- neighborhood" -- see MINE_ADJACENT_RANGE comment above (native mining needs real
      -- adjacency, confirmed live 2026-07-03).
      storage.walking_queues[cid] = {target = surf.find_non_colliding_position("character", e.position, 1, 0.5) or e.position}
      q.state = "approach"
      -- DIAGNOSTIC (2026-07-11 extension -- see MINE_DIAG_CAP/STATUS comment above):
      -- the fresh per-attempt mine_diag buffer now starts HERE, at the very beginning
      -- of the WALKING approach, instead of only once "mine" begins. The open Mode A/B
      -- investigation's own next concrete step was to observe the walking-to-mine
      -- transition boundary itself (previously entirely unrecorded, since the old
      -- reset point discarded every approach-phase tick before any sample of it could
      -- ever be taken).
      storage.mine_diag = storage.mine_diag or {}
      storage.mine_diag[cid] = {}
      return false
    end

    if q.state == "approach" then
      local d_to_target = u.distance(c.entity.position, q.entity_pos)
      -- DIAGNOSTIC (2026-07-11 extension, see comment at the "find"->"approach"
      -- transition above): per-cycle sample of the WALKING phase, same cadence
      -- (every TICK_INTERVAL=5 ticks) and buffer as the "mine" phase's own samples
      -- below, tagged st="approach" so a consumer can split/filter the two phases of
      -- one continuous attempt. Reuses q.entity_pos's tile key as `r` (same identity
      -- format the "mine" phase's `res_key` uses) so the whole trace for one candidate
      -- -- approach AND mine -- shares one consistent target identifier.
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
        -- (mine_diag buffer already started at the "find"->"approach" transition
        -- above -- 2026-07-11 extension -- so it is deliberately NOT reset again here;
        -- this keeps the walking-phase trace attached to the mine-phase trace that
        -- follows, for the SAME candidate, in one continuous buffer.)
      elseif game.tick >= (q.approach_deadline or 0) then   -- cannot reach this patch -> blacklist + try next
        -- APPROACH-STALL-RESPAWN (2026-07-13): mirrors the identical guard added to
        -- process_queue's generic UNIVERSAL_STALE_TICKS backstop above (see its own much
        -- longer comment for the full root-cause analysis -- the "667 coal tiles
        -- blacklisted within one fresh episode" incident). In practice the generic
        -- backstop's 600-tick threshold sits below this deadline's own >=1800-tick floor
        -- and usually fires first, but a companion that keeps moving (resetting the
        -- generic backstop's staleness clock) without ever actually reaching q.entity_pos
        -- can still land here -- give it the SAME one respawn-and-retry chance before
        -- condemning the whole neighborhood, for consistency and defense in depth.
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
        -- Blacklist every tile of `resource` within patch range (not just q.entity_pos):
        -- an entirely unreachable patch (e.g. coal across water from a far-flung shore) is
        -- typically dozens of adjacent 1-tile entities at nearly identical distance, so
        -- blacklisting only the one candidate tile let "find" immediately re-pick the NEXT
        -- tile of the SAME dead patch -- exhausting a large patch needed O(patch size)
        -- deadline cycles, each costing real time, and could burn through the entire 180s
        -- Python-side gather() timeout with zero gathered (live-caught 2026-07-04,
        -- scripts/test_phase_b_asm.py: coal gather near a far shore stuck in "approach"
        -- for the full 180s, 0 coal). radius=15 mirrors the same "same patch" radius
        -- already used by spatial_demo.py's nearest(exclude_r=15.0).
        for _, e in ipairs(surf.find_entities_filtered{name = q.resource, position = q.entity_pos, radius = 15}) do
          q.blacklist[_tile_key(e.position)] = true
        end
        storage.walking_queues[cid] = nil
        c.entity.walking_state = {walking = false}
        q.state = "find"
      end
      return false
    end

    if q.state == "mine" then
      if inv.get_item_count(q.product) - (q.start_count or 0) >= q.target then
        c.entity.mining_state = {mining = false}
        q.state = "done"; return false   -- target met
      end
      -- DIAGNOSTIC (Mode A/B gather-select-fail investigation, see MINE_DIAG_CAP comment above): fresh
      -- read BEFORE this cycle's own logic touches anything, so a sample can reveal
      -- whether the ENGINE itself flipped mining_state off between our last write and
      -- now (as opposed to only ever seeing what WE last wrote). Also captures the SAME
      -- two inputs process_queue's own generic UNIVERSAL_STALE_TICKS backstop uses
      -- (total inventory count + position) -- tests the hypothesis that some UNRELATED
      -- inventory/position change could be resetting that backstop's own counter while
      -- the gather-specific product count stays stuck at 0 (which would explain how a
      -- Mode-B-shaped stall could run past 600 ticks without the generic backstop
      -- catching it).
      local mine_diag_mining_before = c.entity.mining_state and c.entity.mining_state.mining or false
      local mine_diag_total_inv = inv.get_item_count()   -- same call process_queue's own staleness backstop uses
      -- 2026-07-11 Mode A/B research pass: `ti` above sums ALL item types, so it can't answer
      -- "is there room for THIS product" -- can_insert() is the direct engine answer, needed to
      -- confirm/rule out the 2.0.67 "full inventory silently discards mined output" engine change
      -- as a Mode B cause. `mining_progress` is the authoritative countdown value itself -- strictly
      -- better than inferring real accrual from mining_state.mining==true, which only proves the
      -- engine is ATTEMPTING to mine, not that progress is actually advancing.
      local mine_diag_can_insert = inv.can_insert({name = q.product, count = 1})
      local mine_diag_pos = {x = c.entity.position.x, y = c.entity.position.y}
      -- Pick the NEAREST resource entity to the companion's ACTUAL position, not just any
      -- entity within radius=1 of the originally-recorded q.entity_pos: a resource patch is
      -- many individually-tiled entities ~1 tile apart, so a radius=1 query around q.entity_pos
      -- can catch 2+ neighboring tiles, and an unsorted [1] pick can be the WRONG (slightly
      -- farther) one -- close enough to have satisfied the "approach" exit check against
      -- q.entity_pos, yet just over MINE_ADJACENT_RANGE from where the companion is actually
      -- standing. Live-caught 2026-07-03: state flipped mine->find within one tick, mining_state
      -- never even attempted (selected stayed nil), even though the companion visibly reached
      -- and stopped right next to the coal.
      local candidates = surf.find_entities_filtered{name = q.resource, position = q.entity_pos, radius = 2}
      local res, best_d = nil, 1e18
      for _, e in ipairs(candidates) do
        if e.valid then
          local d = u.distance(c.entity.position, e.position)
          if d < best_d then best_d, res = d, e end
        end
      end
      if not res then
        c.entity.mining_state = {mining = false}
        q.select_fail_ticks = nil   -- leaving "mine" -- don't let a stale count leak into the next tile
        q.state = "find"; return false   -- depleted -> next patch
      end
      if best_d > MINE_ADJACENT_RANGE then
        c.entity.mining_state = {mining = false}
        q.select_fail_ticks = nil
        q.state = "find"; return false
      end
      -- DIAGNOSTIC TRACE (2026-07-09, task #41 investigation -- purely additive, NOT a
      -- behavior change): tests the hypothesis that `res` (re-derived from scratch every
      -- tick, see the loop above) could flip between near-tied candidates on consecutive
      -- ticks, re-triggering the `selected` reassignment below in a way that might
      -- interrupt the engine's mining swing -- the same failure SHAPE as the already-fixed
      -- "re-setting mining_state every tick" bug documented below, but for `selected`
      -- instead. Logs ONLY on the tick `res` actually changes identity while still mining
      -- the same patch (not the first tick, not real patch-exhaustion/find transitions
      -- above, which already returned) -- should stay rare/bounded even if the hypothesis
      -- is correct, safe to leave in for live investigation of the #41 stall.
      local res_key = _tile_key(res.position)
      if q.last_res_key and q.last_res_key ~= res_key then
        u.log_error(string.format(
          "gather mine-state: selected entity changed mid-mine %s -> %s (best_d=%.2f, tick=%d)",
          q.last_res_key, res_key, best_d, game.tick), "gather_trace")
      end
      q.last_res_key = res_key
      -- NATIVE mining (Zdendys 2026-07-03: "pouzit proste nativni schopnosti postavy"):
      -- setting mining_state lets the GAME ENGINE run the whole cycle -- same speed,
      -- animation, and extraction as a real player holding the mine button. No more manual
      -- res.mine{} timer call; just let the engine run its own mining_time countdown.
      -- `selected` must be set too: mining_state.position only applies to TILE mining
      -- (landfill/cliffs) -- an ore ENTITY is only mined via the currently `selected` entity,
      -- else mining_state=true silently mines nothing (live-caught 2026-07-03: "0/N harvested"
      -- forever, no error).
      --
      -- CRITICAL: do NOT reassign mining_state every tick once it's already active. Live-caught
      -- 2026-07-03 (test_gather_diag.py): re-setting mining_state = {mining=true,...} on EVERY
      -- tick (as the old comment here claimed was "harmless") restarts the engine's per-resource
      -- mining_time countdown each time, so the swing NEVER completes -- state sat at "mine" with
      -- gathered=0 for 36s+ straight, companion stationary the whole time. A real player only
      -- sends the mine-button-down event ONCE and holds it; we now do the same -- only assign
      -- when the engine reports it isn't already mining (a fresh read of mining_state.mining
      -- each tick, not a cached value, so this correctly resumes if the engine ever stops it,
      -- e.g. after the target changes).
      if c.entity.selected ~= res then
        c.entity.selected = res
      end
      -- SELECTION-DID-NOT-STICK GUARD (2026-07-11, live-reproduced via
      -- scripts/test_gather_select_fail.py -- root cause of the "gather(iron-ore,N)
      -- got only 0 (done, ...)" 12x-in-a-row bootstrap-stall bug, live-caught in
      -- test_stage_b_wiring_recheck1.log): Factorio's own docs (LuaControl::selected)
      -- say assigning an entity "will select it if it is selectable, otherwise the
      -- selection is cleared" -- confirmed live that an entirely valid, in-range,
      -- amount>0 resource tile can INTERMITTENTLY fail to become selected (reads back
      -- nil) for reasons not pinned down at the script level (the SAME tile/distance
      -- succeeds most of the time). The OLD code below set mining_state=true
      -- UNCONDITIONALLY whenever the engine wasn't already mining, regardless of
      -- whether `selected` actually took -- creating an inert "mining_state.mining=true
      -- + selected=nil" zombie that silently mines NOTHING (game.speed=8: ~1.2s) until
      -- process_queue's generic UNIVERSAL_STALE_TICKS=600 backstop finally force-stops
      -- the WHOLE queue with zero resource-specific diagnostic, reporting
      -- {gathered=0, done=true} indistinguishable from "nothing left to mine". Gate
      -- mining_state=true on selection having ACTUALLY stuck, and self-heal exactly
      -- like the approach_deadline reachability failure above: a short, tick-count
      -- retry budget (not distance-scaled -- this isn't a walking failure), then
      -- blacklist this tile's whole neighborhood and try the next candidate.
      if c.entity.selected ~= res then
        q.select_fail_ticks = (q.select_fail_ticks or 0) + TICK_INTERVAL
        if q.select_fail_ticks > SELECT_FAIL_TICKS then
          -- OBSTRUCTION-CLEAR (2026-07-17, Zdendys's own direct instruction: "a
          -- big-rock entity should be automatically eliminated -- mined -- when
          -- within the companion's reach, it's the same method as with trees!" -- mirrors
          -- clear_build_area's own tree/simple-entity clearing exactly (same
          -- type filter, same instant obs.mine{inventory=...}), applied here to the
          -- MINING-select-fail case instead of building placement. Live-caught: a
          -- big-rock sitting almost directly on top of an iron-ore tile (~0.3 tiles
          -- away) made it permanently unselectable for EVERY character entity that
          -- tried, including a freshly-respawned one -- proving the blocker is
          -- per-TARGET (the rock itself), not per-entity, so the respawn mitigation
          -- below (built for a genuine per-entity engine glitch) can never fix this
          -- specific shape. Try clearing FIRST, before ever blacklisting/respawning --
          -- self-limiting: if nothing is actually there to clear, this is a no-op and
          -- falls straight through to the existing escalation unchanged.
          --
          -- FOOTPRINT-SCOPED (2026-07-18, cubic-dev-ai review finding on the original
          -- radius=2 circular sweep): a plain radius search around res.position could
          -- mine a tree/rock up to 2 tiles from the ore tile (up to ~4 tiles from the
          -- companion, since she must be within her own reach of res.position to be
          -- attempting selection at all) even when that entity does not overlap the
          -- ore tile and has nothing to do with the select-fail. Mirrors
          -- clear_build_area's own established pattern below (same type filter, same
          -- +-0.5 tile padding) instead of a raw radius: build a tight `area` from the
          -- ore entity's OWN real bounding_box, so only something actually occupying/
          -- overlapping the ore tile gets cleared.
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
          -- Track exactly which keys THIS sweep adds (2026-07-11, post-commit review
          -- finding): q.blacklist is a single shared table that ALSO accumulates
          -- entries from the unrelated approach_deadline branch above (genuinely
          -- unreachable patches, e.g. across water) and from any caller-seeded
          -- `exclude` list (start_gather). The respawn trigger below used to wipe
          -- q.blacklist wholesale on the theory that "the tiles just blacklisted were
          -- victims of the broken entity" -- true for THIS sweep's own keys, but it
          -- silently un-blacklisted every OTHER entry too, letting "find" immediately
          -- re-attempt a patch already proven genuinely unreachable earlier in this
          -- same gather() call (exactly the wasted-approach_deadline-cycle scenario
          -- that mechanism exists to prevent). Recording just_blacklisted here lets the
          -- respawn branch undo ONLY its own additions.
          local just_blacklisted = {}
          for _, e in ipairs(surf.find_entities_filtered{name = q.resource, position = q.entity_pos, radius = 15}) do
            local key = _tile_key(e.position)
            q.blacklist[key] = true
            just_blacklisted[#just_blacklisted + 1] = key
          end
          q.select_fail_ticks = nil
          q.last_res_key = nil
          q.state = "find"
          -- ENTITY RESPAWN TRIGGER (2026-07-11, see respawn_companion_entity's own
          -- comment above for the full evidence chain, including the same-day
          -- streak=3 -> streak=1 revision): count consecutive blacklist events with
          -- NO successful select in between -- reset to 0 the instant a select
          -- actually sticks below. Live regression testing found this failure is
          -- strictly bimodal (a candidate either selects every time or fails every
          -- time for the whole SELECT_FAIL_TICKS budget, never partially), so even
          -- ONE full lockout episode (SELECT_FAIL_RESPAWN_STREAK=1) is already a
          -- reliable signal, not noise worth waiting out.
          q.select_fail_streak = (q.select_fail_streak or 0) + 1
          if q.select_fail_streak >= SELECT_FAIL_RESPAWN_STREAK then
            if respawn_companion_entity(cid, c) then
              -- Only undo THIS sweep's own additions (victims of the broken entity) --
              -- leave any other pre-existing blacklist entries (approach_deadline
              -- exclusions, caller-seeded excludes) untouched, see comment above.
              for _, key in ipairs(just_blacklisted) do
                q.blacklist[key] = nil
              end
              -- STALE INVENTORY FIX (2026-07-17, live-caught: "LuaInventory API call
              -- when LuaInventory was invalid" logged with context "gather" in the SAME
              -- tick as this respawn): `inv` (captured at the top of this whole
              -- tick_gather_queues callback, line ~880, BEFORE this respawn could ever
              -- run) still references the OLD character's now-destroyed inventory --
              -- respawn_companion_entity() calls old.destroy() and reassigns
              -- `c.entity` to the NEW character, but does nothing about THIS function's
              -- own local `inv` variable. The very next use of `inv` below
              -- (_record_mine_diag's `g = inv.get_item_count(...)`) then crashed on the
              -- invalid LuaInventory object. Refresh it here so every later use in this
              -- same tick sees the new character's real inventory.
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

-- Manual/test-triggerable entry point for the SAME respawn mechanism the automatic
-- SELECT_FAIL_RESPAWN_STREAK trigger above uses (2026-07-11). Exposed as its own command
-- (commands/companion.lua's /fac_respawn_entity) both as a genuine manual escape hatch --
-- Phase 2 of the mode-a-select-fail investigation recommended exactly this ("destroying and
-- respawning the affected companion onto a fresh entity... is a verified, working recovery")
-- as an operator action for a companion that looks permanently stuck for any reason -- and so
-- this exact code path (entity destroy+recreate+inventory transfer) can be exercised directly
-- in a live test without waiting for the rare, real select-fail trigger to occur naturally.
function M.debug_respawn_entity(cid)
  local c = valid_companion(cid)
  if not c then return {error = "Invalid companion"} end
  local ok = respawn_companion_entity(cid, c)
  return {respawned = ok}
end

function M.get_gather_status(cid, peek)
  local q = storage.gather_queues[cid]
  if not q then return {active = false} end
  local c = valid_companion(cid)
  local have = (c and q.product) and c.entity.get_main_inventory().get_item_count(q.product) - (q.start_count or 0) or 0
  -- blacklist tile-keys (2026-07-07): lets the Python caller fold any patch THIS
  -- run discovered unreachable into its OWN persistent exclude list, so a LATER
  -- gather() call (this queue is per-call, not per-episode) doesn't waste an
  -- approach_deadline cycle re-discovering the same dead patch.
  local bl = {}
  if q.blacklist then
    for k in pairs(q.blacklist) do bl[#bl + 1] = k end
  end
  -- ENGINE-level mining diagnostics (2026-07-09, iron-ore gather-stall investigation):
  -- q.state="mine" alone doesn't reveal whether the ENGINE actually has a valid
  -- selected/mining_state -- exposing the real character.selected/mining_state lets a
  -- live poll catch the exact tick things diverge (e.g. selected pointing at something
  -- other than the intended resource, or mining_state.mining reading false/true
  -- unexpectedly) instead of only learning about a stall after the fact via the
  -- generic force-stop backstop.
  local selected_name, mining = nil, nil
  if c then
    selected_name = c.entity.selected and c.entity.selected.name or nil
    mining = c.entity.mining_state and c.entity.mining_state.mining or false
  end
  -- Terminal state consumed HERE (not by tick_gather_queues) -- same fix as
  -- get_build_status/get_fuel_status: the final "gathered" count (computed live above from
  -- the still-intact q.product/q.start_count) must survive at least until a Python poll
  -- actually reads it, instead of being deleted the same tick completion was detected and
  -- forcing the caller to fall back on a stale pre-completion value (see the "TERMINAL"
  -- comment in tick_gather_queues for the full root-cause trace).
  --
  -- peek (2026-07-11): task_pool.lua's get_diag() merges this call's result into its own
  -- explicitly-documented "read-only, no side effects" diagnostic snapshot -- calling this
  -- in normal (consuming) mode from there would let a mere DIAGNOSTIC read silently clear a
  -- gather queue's one-and-only terminal "done" read, discarding the final gathered count
  -- before /fac_gather_status ever got a chance to see it -- the exact same class of bug
  -- this whole TERMINAL mechanism exists to prevent, just via a different call path. When
  -- peek is truthy, report the terminal state without consuming it, leaving the real
  -- /fac_gather_status poll (companion.py's gather()) as the only consumer.
  if q.state == "done" then
    if not peek then storage.gather_queues[cid] = nil end
    return {active = false, resource = q.resource, target = q.target, gathered = have,
      blacklist = bl, entity_pos = q.entity_pos,
      selected = selected_name, mining_state_mining = mining}
  end
  return {active = true, resource = q.resource, target = q.target, gathered = have,
    state = q.state, blacklist = bl, entity_pos = q.entity_pos,
    selected = selected_name, mining_state_mining = mining}
end

-- FUEL GROUP moved to queues_fuel.lua (2026-07-19 size-refactor split) -- see
-- re-exports above.

-- CRAFT moved to queues_craft.lua (2026-07-19 size-refactor split) -- see
-- M.start_craft/tick_craft_queues/get_craft_status/stop_craft re-exports above.

-- ============ BUILD ============

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

-- Remove trees and small rocks from the entity's collision footprint
--
-- NOTE (2026-07-17, investigated then REVERTED): a live discard-investigation-pause
-- showed _build_iron_output_inserter's (belt_connect_ops.py) wooden-chest placement
-- stuck at (29,0) with "nearby: iron-ore,iron-ore,item-on-ground,burner-inserter,..."
-- and self_collision_clear=false. Hypothesized the lying item ("item-entity") was
-- the uncleared blocker (belt_connect_ops.py's _tile_has_clearable_debris pre-check
-- assumes it counts as clearable) -- but a live RCON test (surface.create_entity
-- name="item-on-ground" at a clear tile, then can_place_entity{name="wooden-chest"})
-- proved can_place_entity returns TRUE with a lying item present regardless: it is
-- NOT a collision blocker in this engine version. Reverted the item-entity handling
-- added here on that now-disproven premise (per this project's own "live
-- verification beats static review" lesson) -- the real blocker at (29,0) remains a
-- separate, still-open investigation.
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
    if obs.valid then obs.mine{inventory = inv} end   -- MINE (wood/stone into inventory), not free-destroy
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
        q.state = "failed"
        return false
      end

      -- Re-check the item is STILL in inventory right before placing (it may have been consumed
      -- during the walk -- crafted away / dropped). Never create a building for free.
      if c.entity.get_main_inventory().get_item_count(q.entity) < 1 then
        q.failed = "No " .. q.entity .. " in inventory"
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
        q.state = "failed"
        return false
      end
      if destroyed then
        q.failed = "item consumed before placement could complete"
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
      q.state = "done"
      return false
    end

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
    return {active = false, placed = true, position = q.placed_position}
  end
  if q.state == "failed" then
    storage.build_queues[cid] = nil
    return {active = false, placed = false, error = q.failed}
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

-- BELT CONNECT moved to queues_belt.lua (2026-07-19 size-refactor split) -- see
-- M.start_belt_connect/tick_belt_queues/get_belt_connect_status/stop_belt_connect
-- re-exports above.

-- COMBAT moved to queues_combat.lua (2026-07-19 size-refactor split) -- see
-- M.start_combat/tick_combat_queues/get_combat_status/stop_combat re-exports above.

return M
