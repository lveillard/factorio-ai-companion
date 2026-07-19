-- AI Companion -- queue-processing shared core (2026-07-19 size-refactor split out of
-- queues.lua). Owns the generic process_queue() tick-driver every tick_*_queues function
-- calls, valid_companion(), and the 2 constants genuinely shared across more than one
-- queue-domain file (TICK_INTERVAL: harvest/gather/combat; MINE_ADJACENT_RANGE: harvest/
-- gather). Everything section-specific (HARVEST/GATHER/FUEL GROUP/CRAFT/BUILD/BELT
-- CONNECT/COMBAT) stays in its own file; queues.lua (the thin facade) requires this
-- module and keeps a local alias (`local TICK_INTERVAL = core.TICK_INTERVAL`, etc.) for
-- each name so every existing bare-name call site in the not-yet-split sections keeps
-- working completely unchanged.

local u = require("commands.init")

local M = {}

M.TICK_INTERVAL = 5

-- Real mining requires standing basically ON/adjacent to the resource -- confirmed live
-- 2026-07-03 (Zdendys, watching: "The character is standing right on the coal! Nothing can be mined from a distance."):
-- unlike build/reach_distance (~10) or MINING_RANGE (5, used elsewhere as a generous "still
-- close enough to keep going" bound), native mining_state silently does nothing at a genuine
-- multi-tile distance even with `selected` correctly set -- it only actually starts once the
-- companion is essentially touching the resource tile.
M.MINE_ADJACENT_RANGE = 2

-- Shared tile-key helper (2026-07-19 size-refactor split -- moved here from GATHER's own
-- private _tile_key, which several OTHER queue types also need for their own blacklists,
-- e.g. FUEL GROUP's find_next_burner/q.blacklist below). queues.lua keeps its own alias
-- (`local _tile_key = core.tile_key`) so GATHER's own not-yet-split call sites keep
-- working unchanged; process_queue's APPROACH-STALL-RESPAWN recovery above still inlines
-- the same expression itself (see its own comment) rather than calling this, to avoid
-- touching that already-verified code for an unrelated batch.
function M.tile_key(pos) return math.floor(pos.x) .. "," .. math.floor(pos.y) end

-- Universal stale-progress backstop threshold (2026-07-06, Zdendys: "we could do
-- that as a generic fallback for all actions" -- then: "if there's already 600
-- ticks somewhere, let's use 600 too!", matching tick_harvest_queues's own existing stale-progress
-- constant below, for one consistent number project-wide).
local UNIVERSAL_STALE_TICKS = 600

-- Registration indirection (2026-07-19, size-refactor fix): process_queue's own
-- APPROACH-STALL-RESPAWN recovery (see below) needs to call GATHER's own
-- respawn_companion_entity, which stays defined in queues.lua (not yet split out to its
-- own file -- see this repo's own refactor plan) -- and even once it does move to its
-- own file, this module is loaded BEFORE it. A bare forward-declared local (the
-- original single-file pattern) cannot cross a file boundary like that. Instead,
-- whichever file defines the real respawn_companion_entity calls
-- M.register_respawn_fn(respawn_companion_entity) once at its own module load time (a
-- single added line, right after that function's own definition); process_queue below
-- calls through try_respawn(...), which is nil-safe (returns false if nothing has
-- registered yet) -- behaviorally identical to the original single-file forward-
-- declaration, since nothing could call it before its own definition ran there either.
local _respawn_fn = nil
function M.register_respawn_fn(fn)
  _respawn_fn = fn
end
local function try_respawn(cid, c)
  if not _respawn_fn then return false end
  return _respawn_fn(cid, c)
end

-- Validate companion exists and is valid
function M.valid_companion(id)
  local c = u.get_companion(id)
  return c and c.entity and c.entity.valid and c
end

-- Generic queue processor - eliminates repetition across all tick functions
function M.process_queue(queue_name, processor)
  local queues = storage[queue_name]
  if not queues then return end

  local to_remove = {}
  for cid, q in pairs(queues) do
    local c = M.valid_companion(cid)
    if not c then
      to_remove[#to_remove + 1] = cid
    else
      -- UNIVERSAL stale-progress backstop, ONE level above every queue type's own
      -- specific checks (2026-07-06, Zdendys: "a generic fallback for all actions" -- if
      -- NEITHER the companion's total inventory item count NOR its position has changed
      -- in UNIVERSAL_STALE_TICKS ticks, whatever this queue is doing isn't making real
      -- progress, regardless of queue type or the specific reason -- including cases
      -- where the queue-specific logic never even runs, or a bug like the orphaned-
      -- mining one found earlier tonight where a queue got silently dropped elsewhere
      -- without ever reaching this check). Position is checked TOGETHER with item count
      -- (not item count alone) so a long, genuinely-in-progress walk toward a distant
      -- target -- which changes position but not inventory -- is correctly NOT flagged
      -- as stuck; only a companion that is BOTH stationary AND not gaining/losing items
      -- counts as truly stuck. Tracked ON the queue entry itself (q._stale_*), so
      -- concurrent queues on the same companion (e.g. walking + harvesting) don't
      -- interfere with each other's own staleness tracking.
      -- moved threshold raised 0.1 -> 5 tiles (2026-07-06, Zdendys live-caught: "zmena
      -- pozice znamena alespon o 5" -- control.lua's own perpendicular-bypass mechanism
      -- shuffles the companion sideways in small steps while stuck against a large
      -- obstacle, which satisfied the old near-zero threshold on almost every check,
      -- continuously resetting _stale_pos to the CURRENT position and defeating this
      -- entire backstop (confirmed live: stuck against the big wreck's collision for 3+
      -- minutes, this check never fired). At 5 tiles, small shuffle movements stay
      -- within range of the ORIGINAL reference point (so _stale_pos does NOT get
      -- updated and stale_ticks keeps accumulating correctly); only cumulative movement
      -- that actually clears 5 tiles counts as real progress and resets the counter.
      local total = c.entity.get_inventory(defines.inventory.character_main).get_item_count()
      local pos = c.entity.position
      local moved = q._stale_pos and (u.distance(q._stale_pos, pos) > 5)
      -- STEPPING_AWAY EXEMPTION (2026-07-13, closing the approach_deadline_vs_universal_
      -- stale_gap bug class for build_queues specifically -- live-caught: real tick
      -- 618490, stuck_at=(197.6,-37.4) queue_state=stepping_away, force-killed via THIS
      -- generic backstop's own to_remove path below (not q.state='failed'), so
      -- get_build_status then returned a bare {active=false} with NO error key --
      -- place_smart's _on_done, trusting any error-less status as success, incorrectly
      -- reported {'placed': True} for a build that never happened). ROOT CAUSE:
      -- "stepping_away"'s own step_away_deadline floors at 1800 ticks (same
      -- math.max(1800, distance*25) formula as every other bounded-approach deadline in
      -- this file) -- comfortably ABOVE this generic backstop's UNIVERSAL_STALE_TICKS=600
      -- -- and for a SMALL building, step_away_distance() can compute an actual step-away
      -- displacement UNDER the 5-tile "moved" threshold above, so the round trip never
      -- resets _stale_pos/_stale_ticks even though she IS genuinely walking -- meaning this
      -- backstop always wins the race and fires before "stepping_away"'s own deadline ever
      -- gets a chance to. Unlike gather_queues'/fuel_queues' "approach" state (which has no
      -- graceful continuation once force-stopped elsewhere, hence THEIR fix instead runs a
      -- recovery sweep before freezing to "done"), build_queues' "stepping_away" handler
      -- already does the right thing once given the chance to keep running (arrives ->
      -- re-approach normally; own deadline expires -> ALSO re-approaches normally, see
      -- tick_build_queues' own "stepping_away" block) -- so the correct fix is simply to
      -- PAUSE the staleness clock (not merely skip the force-stop check) for the duration of
      -- this one state: q._stale_ticks is kept at 0 the whole time she is in it, and the
      -- clock resumes counting fresh (from a live position/inventory snapshot) the very
      -- first tick after she leaves it -- no separate reset needed at the
      -- stepping_away->approaching transition, and this state's OWN bounded deadline
      -- (mirrored above, capped at MAX_SELF_COLLISION_STEP_AWAY cycles) is what actually
      -- bounds total time spent here, exactly as intended.
      if queue_name == "build_queues" and q.state == "stepping_away" then
        q._stale_total, q._stale_pos, q._stale_ticks = total, {x = pos.x, y = pos.y}, 0
      elseif q._stale_total == total and q._stale_pos and not moved then
        q._stale_ticks = (q._stale_ticks or 0) + M.TICK_INTERVAL
      else
        q._stale_total = total
        q._stale_pos = {x = pos.x, y = pos.y}
        q._stale_ticks = 0
      end
      if q._stale_ticks > UNIVERSAL_STALE_TICKS and q.state == "done" then
        -- TERMINAL re-entry guard (2026-07-12, closing the follow-up flagged in
        -- 6d00d54): gather_queues/fuel_queues can now sit HERE, frozen in q.state=
        -- "done", waiting for get_gather_status/get_fuel_status to consume+clear them
        -- (see the branch below that sets this). A companion that stopped moving is --
        -- by definition -- still motionless afterward too, so _stale_ticks keeps
        -- climbing past the threshold on every later tick; without this guard the
        -- whole branch below would re-run FOREVER (re-logging every TICK_INTERVAL,
        -- redundantly re-scanning for blacklist candidates) until a status poll
        -- finally arrives. Mirrors the exact no-op every OTHER terminal state already
        -- relies on (e.g. tick_gather_queues' own "if q.state == 'done' then return
        -- false end" a bit further down this file) -- once frozen, sit quietly.
      elseif q._stale_ticks > UNIVERSAL_STALE_TICKS then
        -- Diagnostic (2026-07-09, live-caught: gather("iron-ore") force-stopped this
        -- way intermittently with NO further clue why -- this generic backstop is
        -- shared across every queue type, so it never recorded WHERE the companion
        -- actually got stuck or what she was walking toward. q.state/q.entity_pos/
        -- q.target are nil-safe reads: present on SOME queue types, absent (and
        -- harmlessly omitted) on others -- but their TYPE also varies by queue type
        -- (e.g. gather_queues' own q.target is the target ITEM COUNT, a plain number,
        -- NOT a position -- unlike walking-style queues where target IS a position
        -- table). Live-caught the FIRST time this fired: an unguarded string.format
        -- assuming q.target.x/.y crashed with "attempt to index field 'target' (a
        -- number value)", silently swallowed by guard_tick's own pcall every tick
        -- thereafter -- which ALSO meant the mining_state/walking_state reset and
        -- to_remove cleanup below NEVER RAN, since the crash happened before reaching
        -- them, leaving the stuck queue entry (and the crash) recurring every tick
        -- indefinitely instead of actually force-stopping anything. fmt_maybe_pos
        -- checks the real type before formatting, so this can never crash regardless
        -- of what shape a given queue type's field happens to be.
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
        -- APPROACH-DEADLINE-VS-UNIVERSAL-STALE GAP (2026-07-12, live-caught: a gather
        -- queue got force-stopped by THIS generic backstop while stuck ~2.1 tiles from
        -- an ore tile only 0.71 tiles from an iron_furnace_solo the companion had JUST
        -- built -- q.state=="approach", q.entity_pos set, blacklist still empty
        -- afterward). Root cause: "approach" states compute their OWN specific
        -- reachability timeout (gather_queues' approach_deadline = max(1800,
        -- distance*25); fuel_queues' APPROACH_TIMEOUT=900) -- both floors sit ABOVE
        -- UNIVERSAL_STALE_TICKS=600, so for any real, genuinely-motionless companion
        -- this generic backstop ALWAYS wins the race first, meaning the specific,
        -- blacklist-aware recovery below (the actual "approach" state handler for each
        -- queue type) never gets a chance to run -- this generic path used to just
        -- delete the queue with NOTHING blacklisted, so a later attempt could walk
        -- right back into the exact same obstruction. See
        -- approach_deadline_vs_universal_stale_gap.md for the full analysis. Deliberately
        -- NOT touching either timeout constant (that tuning may have other reasons not
        -- fully understood) -- only mirroring each queue type's OWN existing blacklist
        -- sweep here, before the queue is deleted below. _tile_key() is defined further
        -- down this file (after this function), so its expression is inlined rather than
        -- called, to avoid a forward-reference to a not-yet-declared local.
        local recovered_via_respawn = false
        if queue_name == "gather_queues" and q.state == "approach" and q.entity_pos and q.resource then
          -- APPROACH-STALL-RESPAWN (2026-07-13, live-caught: a FRESH episode's very first
          -- gather("coal",5) call hit "no usable coal within 400 tiles -- blacklisted=667"
          -- almost immediately, tick ~19510 -- ALL 667 reachable coal tiles condemned via
          -- this exact radius=15 sweep, repeated over and over across many gather() calls
          -- this same episode, each one folded into Python's PERSISTENT per-episode
          -- exclude list by resource_search.fold_gather_blacklist). Root cause: this sweep
          -- unconditionally condemns an entire ~radius-15 neighborhood (dozens to 100+
          -- tiles of one contiguous patch) the VERY FIRST time a companion fails to make
          -- real progress for UNIVERSAL_STALE_TICKS -- with NO distinction between "this
          -- neighborhood really is unreachable" and "this ONE companion session currently
          -- can't progress for an unrelated reason". The mode-A/B select-fail
          -- investigation elsewhere in this file already documents a near-identical,
          -- still-not-fully-understood per-entity engine defect that can make EVERY
          -- candidate fail identically for a whole session, walking-triggered specifically
          -- (see the STATUS comment above MINE_DIAG_CAP) -- and the "mine"-state sibling of
          -- this exact bug (SELECT_FAIL_RESPAWN_STREAK below) was already fixed by
          -- respawning the companion's entity BEFORE condemning anything, confirmed live to
          -- resolve the identical symptom. Apply the SAME already-validated mitigation
          -- here: the FIRST time this specific approach attempt stalls, respawn the
          -- companion entity and give it ONE more shot at the SAME target (no blacklist,
          -- no freeze) instead of immediately condemning the whole neighborhood -- q.
          -- _approach_stall_respawned (scoped to this one queue/target, not persisted
          -- across separate gather() calls) guarantees this fires at most once per target,
          -- so a genuinely permanent obstruction still gets the full radius=15 blacklist +
          -- freeze exactly as before if the SAME target stalls again after the respawn --
          -- preserving the original fix's intent in full.
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
            -- Mirrors the "approach" state's own approach_deadline handler exactly
            -- (radius=15, same "whole patch, not just one tile" reasoning documented there).
            q.blacklist = q.blacklist or {}
            local added = 0
            for _, e in ipairs(c.entity.surface.find_entities_filtered{
              name = q.resource, position = q.entity_pos, radius = 15}) do
              local key = math.floor(e.position.x) .. "," .. math.floor(e.position.y)
              if not q.blacklist[key] then added = added + 1 end
              q.blacklist[key] = true
            end
            -- Logged (2026-07-12, per this project's "log every silent failure" standing
            -- principle): this recovery sweep would otherwise be entirely invisible --
            -- the queue is deleted in this SAME tick right after, so no status poll
            -- ever observe q.blacklist growing here the normal way.
            u.log_error(string.format(
              "gather_queues generic-backstop recovery: blacklisted %d tile(s) of '%s' " ..
              "around entity_pos (%.1f,%.1f) before force-stop -- its own approach_deadline " ..
              "(tick %s) never got a chance to run (this generic backstop fires at " ..
              "%d ticks, always sooner)%s", added, q.resource,
              q.entity_pos.x, q.entity_pos.y, tostring(q.approach_deadline), UNIVERSAL_STALE_TICKS,
              q._approach_stall_respawned and " (after an earlier respawn-retry also stalled)" or ""),
              "gather_queue")
          end
        elseif queue_name == "fuel_queues" and q.state == "approach" and q.target_key then
          -- fuel_queues' own "approach" handler blacklists only the single target_key
          -- (not a radius sweep): unlike a resource patch, a burner machine is one
          -- isolated entity, not part of a cluster of identical adjacent tiles -- mirror
          -- THAT shape exactly, not gather_queues' radius=15 sweep.
          q.blacklist = q.blacklist or {}
          local was_new = not q.blacklist[q.target_key]
          q.blacklist[q.target_key] = true
          u.log_error(string.format(
            "fuel_queues generic-backstop recovery: blacklisted target_key=%s before " ..
            "force-stop%s -- approach_deadline never got a chance to run",
            q.target_key, was_new and "" or " (already blacklisted)"), "fuel_queue")
        end
        -- APPROACH-STALL-RESPAWN (continued, see comment above): if the gather_queues
        -- branch above chose to respawn+retry instead of condemning the neighborhood,
        -- do NOT touch mining_state/walking_state or freeze/delete the queue this tick --
        -- let it keep running normally with its freshly reset approach_deadline and
        -- staleness counters, exactly as an ordinary in-progress "approach" would.
        if not recovered_via_respawn then
          c.entity.mining_state = {mining = false}
          c.entity.walking_state = {walking = false}
          -- TERMINAL (2026-07-12): freeze gather_queues/fuel_queues in q.state="done" for
          -- one more poll cycle instead of deleting the entry immediately here -- mirrors
          -- the IDENTICAL pattern tick_gather_queues/tick_fuel_queues/tick_build_queues/
          -- tick_belt_queues already use for their OWN normal-completion/failure paths
          -- (see each one's own "TERMINAL" comment). Closes the follow-up flagged (not
          -- fixed) in 6d00d54: without this, get_gather_status/get_fuel_status never got
          -- a chance to read the blacklist this SAME backstop just populated above,
          -- since the entry was deleted in the exact same tick it was populated --
          -- confirmed live (gather() returned blacklist:[] despite the mod's own log
          -- showing real tiles blacklisted). Every OTHER queue type routed through this
          -- generic backstop has no status getter that consumes a "done" state written
          -- from HERE, so they keep the original immediate-delete behavior.
          if queue_name == "gather_queues" or queue_name == "fuel_queues" then
            q.state = "done"
          else
            to_remove[#to_remove + 1] = cid
          end
        end
      else
        local should_remove = processor(cid, q, c)
        if should_remove then to_remove[#to_remove + 1] = cid end
      end
    end
  end

  for _, cid in ipairs(to_remove) do queues[cid] = nil end
end

return M
