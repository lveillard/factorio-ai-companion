-- AI Companion -- GATHER queue (2026-07-19 size-refactor split out of queues.lua).
-- Verbatim move, with ONE deliberate structural simplification: the original file
-- needed `respawn_companion_entity` forward-declared near its TOP (a bare
-- `local respawn_companion_entity` with the real body assigned later via a
-- non-local `function respawn_companion_entity(...)`) because process_queue's
-- generic stale-progress backstop, defined earlier in that same file, also needed
-- to call it. Now that process_queue lives in queues_core.lua (reached via the
-- register_respawn_fn/try_respawn indirection, see that file's own comment) and
-- every remaining caller of respawn_companion_entity is inside THIS file, the
-- forward-declare trick no longer serves any purpose -- it is declared as a
-- plain `local function` in its normal position instead (still safely BEFORE
-- every call site below, same as the original's real assignment was).

local u = require("commands.init")
local core = require("commands.queues_core")

local _tile_key = core.tile_key
local valid_companion = core.valid_companion
local process_queue = core.process_queue
local TICK_INTERVAL = core.TICK_INTERVAL
local MINE_ADJACENT_RANGE = core.MINE_ADJACENT_RANGE

local M = {}

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

-- Diagnostic accessor (Mode A/B gather-select-fail investigation) -- returns the
-- per-cycle "mine" state trace buffer for `cid` (empty list if none recorded yet, e.g.
-- never entered "mine").
function M.get_mine_diag(cid)
  storage.mine_diag = storage.mine_diag or {}
  return storage.mine_diag[cid] or {}
end

-- ============ GATHER (autonomous: find reachable patch -> walk -> mine to target) ============
-- Self-contained composite: the mod finds the nearest REACHABLE + SAFE patch of `resource`, walks the
-- companion within reach, and mines it NATIVELY via character.mining_state (same speed/animation/
-- extraction as a real player holding the mine button; amount--, game removes depleted tile), moving
-- to the next patch until the inventory holds `count` of the mined product (or no reachable patch
-- remains). Replaces the Python go_to + start_harvest + poll glue.

-- 4-state resource-tile model (2026-07-21, Zdendys's own explicit design): a
-- resource-bearing tile is always in exactly one of: (a) available, (b) a
-- mining-drill already stands on it, (c) it carries a different resource than
-- its neighboring field (only relevant to a DRILL's own 2x2+ footprint, not to
-- hand-mining a single 1x1 entity -- already handled at drill-PLACEMENT time by
-- footprint_is_exclusive_resource in task_pool_steps.lua, not here), (d)
-- already mined out. (a)/(d) were already correctly handled here (amount>0);
-- this closes state (b), previously completely unchecked -- the companion
-- could hand-mine a tile an automated drill was ALREADY covering, competing
-- with its own automation for no reason.
local function drill_already_covers(surf, position)
  return #surf.find_entities_filtered{position = position, radius = 1, type = "mining-drill"} > 0
end

local function find_reachable_resource(surf, from, resource, blacklist)
  local ores = surf.find_entities_filtered{name = resource, position = from, radius = 400}
  table.sort(ores, function(a, b) return u.distance(a.position, from) < u.distance(b.position, from) end)
  for _, e in ipairs(ores) do
    if e.valid and (e.amount or 0) > 0
       and not (blacklist and blacklist[_tile_key(e.position)])
       and not drill_already_covers(surf, e.position)
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
  local depleted, blacklisted, drilled, near_spawner, no_stand_pos = 0, 0, 0, 0, 0
  for _, e in ipairs(ores) do
    if e.valid then
      if (e.amount or 0) <= 0 then depleted = depleted + 1
      elseif blacklist and blacklist[_tile_key(e.position)] then blacklisted = blacklisted + 1
      elseif drill_already_covers(surf, e.position) then drilled = drilled + 1
      elseif surf.count_entities_filtered{type = "unit-spawner", position = e.position, radius = 20} > 0 then
        near_spawner = near_spawner + 1
      elseif not surf.find_non_colliding_position("character", e.position, 2.5, 0.5) then
        no_stand_pos = no_stand_pos + 1
      end
    end
  end
  u.log_error(string.format(
    "find_reachable_resource: no usable %s within 400 tiles of (%.1f,%.1f) -- total=%d "
    .. "depleted=%d blacklisted=%d drilled=%d near_spawner=%d no_stand_pos=%d",
    resource, from.x, from.y, total, depleted, blacklisted, drilled, near_spawner, no_stand_pos),
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

local function respawn_companion_entity(cid, c)
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
        -- NARROWED to the single candidate tile only (2026-07-21, Zdendys's own
        -- explicit decision after discussing the tradeoff live): the original
        -- radius=15 "whole neighborhood" sweep (kept here in history: blacklisting
        -- every tile of `resource` within patch range, on the theory that an
        -- entirely unreachable patch -- e.g. coal across water -- is typically
        -- dozens of adjacent 1-tile entities at nearly identical distance, so
        -- sweeping saved O(patch size) repeated deadline cycles) was the
        -- suspected root cause of the recurring "mass-coal-blacklist" bug
        -- (mass_coal_blacklist_recurs_despite_respawn_retry_fix_2026_07_18.md):
        -- Zdendys's own 4-state resource-tile model treats blacklisting as
        -- something that should never happen based on an ASSUMED regional
        -- property. Accepted tradeoff, explicit and deliberate: a genuinely
        -- unreachable whole patch across water will now need one approach_deadline
        -- cycle PER TILE to exhaust instead of one sweep -- slower in that
        -- specific case, but no longer risks wrongly condemning reachable coal
        -- alongside genuinely-unreachable coal.
        q.blacklist[_tile_key(q.entity_pos)] = true
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
          -- NARROWED to the single tile that actually failed to select (2026-07-21,
          -- Zdendys's own explicit decision, same live discussion as the
          -- approach_deadline sweep above): the original radius=15 sweep here was
          -- built on the theory that select-fail victims cluster regionally, but
          -- this exact function's own comment history already flagged doubt about
          -- that ("in roughly half of live test runs the 'didn't stick' failure
          -- recurs on EVERY candidate tried in the session, not just one bad
          -- tile" -- SESSION-WIDE, not regional) -- sweeping 15 perfectly good
          -- neighboring tiles over a per-entity/per-session engine glitch is a
          -- second, independent suspected contributor to the recurring
          -- "mass-coal-blacklist" bug, alongside the approach_deadline sweep.
          -- Blacklist exactly `res` (the specific entity that just failed to
          -- select), not q.entity_pos (the original approach target, which can
          -- differ once "mine" has re-derived a closer candidate) or a radius
          -- sweep around it. just_blacklisted kept as a single-element list so
          -- the respawn-undo logic below (which iterates it) needs no other
          -- change.
          local just_blacklisted = {_tile_key(res.position)}
          q.blacklist[just_blacklisted[1]] = true
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

return M
