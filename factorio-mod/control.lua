-- AI Companion - Factorio 2.x
local u = require("commands.init")
local queues = require("commands.queues")
local spectate = require("commands.spectate")
local task_pool = require("commands.task_pool")

-- Get version dynamically from mod info
local MOD_VERSION = script.active_mods["ai-companion"] or "unknown"

-- Decorative rocks worth opportunistically clearing (2026-07-05, Zdendys's exhaustive
-- list: "All the rock types being searched for are: Big rock, big sandy rock: 120
-- tick / Huge rock: 180tick"). Named explicitly rather than matching the broader type='simple-entity'
-- prototype category: that type ALSO covers a lot of other-planet Space Age content
-- (Vulcanus volcanic-rock/stromatolite/demolisher-corpse, Fulgora rock/ruins,
-- lithium-iceberg, etc. -- confirmed live via prototypes.entity, 2026-07-05) that must
-- NOT be swept up by a home-planet obstacle-clearing rule if the companion ever operates
-- elsewhere. Trees, by contrast, ARE matched by the generic type='tree' prototype
-- category everywhere below -- confirmed live that this correctly covers every variant
-- Zdendys listed (tree-01/02/07/08/09 and color variants, dry-tree, dead-grey-trunk,
-- dead-tree-desert, dead-dry-hairy-tree, dry-hairy-tree), so no equivalent name list is
-- needed for trees.
local CLEARABLE_ROCK_NAMES = {"big-rock", "big-sand-rock", "huge-rock"}

local function init_storage()
  storage.companion_messages = storage.companion_messages or {}
  storage.companions = storage.companions or {}
  storage.dead_companions = storage.dead_companions or {}
  storage.companion_next_id = storage.companion_next_id or 1
  storage.walking_queues = storage.walking_queues or {}
  storage.context_clear_requests = storage.context_clear_requests or {}
  storage.errors = storage.errors or {}
  storage.companion_markers = storage.companion_markers or {}
  storage.path_requests = storage.path_requests or {}
  -- walk_last_outcome (2026-07-16, Zdendys's fast-giveup directive): one-shot,
  -- consume-once stash of how a fac_move_to()-driven walk ended when
  -- process_walking_queues gives up on it early (see that function's own
  -- giveup_enabled block) -- "approx_arrived" (close enough, <4 tiles, good enough
  -- for most construction per Zdendys) or "unreachable" (still >=4 tiles away).
  -- Read-and-cleared by fac_companion_position's handler (commands/companion.lua)
  -- the same way companion_queue_status already surfaces other async state, so
  -- companion.py's wait_arrive() sees this for FREE on its own already-happening
  -- position poll -- no new RCON round-trip.
  storage.walk_last_outcome = storage.walk_last_outcome or {}
  queues.init()
  task_pool.init()
end

local function cleanup_messages()
  local new_msgs, now = {}, game.tick
  for _, m in ipairs(storage.companion_messages) do
    if not m.read or (now - m.tick) < 18000 then new_msgs[#new_msgs + 1] = m end
  end
  if #new_msgs > 100 then
    local trimmed = {}
    for i = #new_msgs - 99, #new_msgs do trimmed[#trimmed + 1] = new_msgs[i] end
    new_msgs = trimmed
  end
  storage.companion_messages = new_msgs
end

script.on_init(function()
  init_storage()
  game.print("[AI Companion] v" .. MOD_VERSION .. " ready. /fac for help", u.print_color(u.COLORS.system))
end)

script.on_configuration_changed(function()
  init_storage()
  game.print("[AI Companion] Updated to v" .. MOD_VERSION, u.print_color(u.COLORS.system))
end)

local subcommands = {}

subcommands.spawn = function(player, args)
  local count = math.min(tonumber(args) or 1, 10)
  table.insert(storage.companion_messages, {player = player.name, message = "spawn " .. count, tick = game.tick, read = false, spawn_request = count})
  game.print("[" .. player.name .. "] Spawn " .. count .. " companion(s)...", u.print_color(u.COLORS.player))
end

subcommands.list = function(player)
  local count = 0
  for id, c in pairs(storage.companions) do
    if c.entity and c.entity.valid then
      local p = c.entity.position
      game.print(string.format("[#%d] (%.1f, %.1f)", id, p.x, p.y), u.print_color(c.color or u.get_companion_color(id)))
      count = count + 1
    else storage.companions[id] = nil end
  end
  if count == 0 then game.print("[AI Companion] No companions. /fac spawn", u.print_color(u.COLORS.system)) end
end

subcommands.kill = function(player, args)
  local id, killed = tonumber(args), 0
  local function kill_one(cid)
    local c = storage.companions[cid]
    if c then
      if c.label and c.label.valid then c.label.destroy() end
      -- Remove map marker
      if storage.companion_markers and storage.companion_markers[cid] then
        if storage.companion_markers[cid].valid then storage.companion_markers[cid].destroy() end
        storage.companion_markers[cid] = nil
      end
      if c.entity and c.entity.valid then c.entity.destroy(); killed = killed + 1 end
      storage.companions[cid] = nil
    end
  end
  if id then kill_one(id) else for cid in pairs(storage.companions) do kill_one(cid) end end
  game.print("[AI Companion] Killed " .. killed, u.print_color(u.COLORS.system))
end

subcommands.clear = function()
  local count = #storage.companion_messages
  storage.companion_messages = {}
  game.print("[AI Companion] Cleared " .. count .. " msg(s)", u.print_color(u.COLORS.system))
end

subcommands.name = function(player, args)
  local id_str, name = args:match("^(%d+)%s+(.+)$")
  local id = tonumber(id_str)
  if not id or not name then player.print("/fac name <id> <name>", u.print_color(u.COLORS.system)); return end
  local c = u.get_companion(id)
  if not c then player.print("#" .. id .. " not found", u.print_color(u.COLORS.error)); return end
  c.name = name
  if c.label and c.label.valid then c.label.destroy() end
  local color = c.color or u.get_companion_color(id)
  c.label = u.render_label(c.entity, name .. "(#" .. id .. ")", color)
  game.print("#" .. id .. " -> " .. name, u.print_color(color))
end

local function handle_fac(cmd)
  local ok, err = pcall(function()
    local player = cmd.player_index and game.players[cmd.player_index]
    if cmd.player_index and (not player or not player.valid) then return end
    local param = cmd.parameter
    if not param or param == "" then
      if player then player.print("/fac <msg> | <id> <msg> | spawn | list | kill | clear | name", u.print_color(u.COLORS.system)) end
      return
    end
    local first, rest = param:match("^(%S+)%s+(.+)$")
    if first and rest and not subcommands[first] then
      local id, comp = u.find_companion(first)
      if id then
        table.insert(storage.companion_messages, {player = player.name, message = rest, tick = game.tick, read = false, target_companion = id})
        game.print("[" .. player.name .. " -> " .. u.get_companion_display(id) .. "] " .. rest, u.print_color(comp.color or u.get_companion_color(id)))
        return
      end
    end
    local sub, args = param:match("^(%S+)%s*(.*)")
    if subcommands[sub] then subcommands[sub](player, args)
    else
      table.insert(storage.companion_messages, {player = player and player.name or "server", message = param, tick = game.tick, read = false})
      game.print("[" .. (player and player.name or "server") .. "] " .. param, u.print_color(u.COLORS.player))
    end
  end)
  if not ok then u.error_response(err, "fac"); game.print("Error: " .. tostring(err), u.print_color(u.COLORS.error)) end
end

commands.add_command("fac", "AI Companion", handle_fac)

require("commands.action")
require("commands.building")
require("commands.chat")
require("commands.companion")
require("commands.context")
require("commands.item")
require("commands.mapgen")
require("commands.move")
require("commands.research")
require("commands.resource")
require("commands.task")
require("commands.world")
require("commands.combat")
require("commands.help")

-- Update companion map markers
local function update_companion_markers()
  if not storage.companion_markers then storage.companion_markers = {} end
  for cid, c in pairs(storage.companions) do
    if c.entity and c.entity.valid then
      local marker = storage.companion_markers[cid]
      local display = u.get_companion_display(cid)
      -- Create marker if doesn't exist
      if not marker or not marker.valid then
        local force = c.entity.force
        local surf = c.entity.surface
        marker = force.add_chart_tag(surf, {
          position = c.entity.position,
          text = display
        })
        storage.companion_markers[cid] = marker
      else
        -- Update marker position
        marker.position = c.entity.position
      end
    else
      -- Companion died/invalid, remove marker
      local marker = storage.companion_markers[cid]
      if marker and marker.valid then marker.destroy() end
      storage.companion_markers[cid] = nil
    end
  end
end

-- Run one tick subsystem defensively: a runtime error (e.g. an invalid
-- prototype-type filter) must NEVER propagate out of on_nth_tick, or it would
-- crash the whole scheduler / the game. Errors are recorded and printed
-- throttled (once per ~5s) instead.
local function guard_tick(name, fn, tick)
  local ok, err = pcall(fn)
  if not ok then
    -- 2026-07-11: was storage.errors[name] = {...} -- a STRING key into the SAME table
    -- init.lua's u.log_error appends to via table.insert (numeric/array keys). Mixing
    -- string and numeric keys in one Lua table makes helpers.table_to_json emit a JSON
    -- OBJECT instead of an array, so /fac_get_errors could come back as a dict (keys like
    -- "1", "harvest") instead of the list every caller expects, crashing any code that
    -- calls .get() on an entry expecting {context,error,tick}. Also silently overwrote
    -- the previous error for the same handler name instead of accumulating history.
    -- Route through the shared u.log_error so this uses the SAME array-style ring buffer
    -- (with its own 50-entry cap) as every other error site in the mod.
    u.log_error(tostring(err), name)
    if tick % 300 == 0 then
      game.print("[AI Companion] " .. name .. " tick error: " .. tostring(err),
        u.print_color(u.COLORS.error))
    end
  end
end

-- Trees matched by the generic type='tree' prototype category (covers every variant,
-- confirmed live 2026-07-05 -- see CLEARABLE_ROCK_NAMES comment above for why rocks are
-- NOT matched this same broad way) + the exact named rocks worth clearing. Two separate
-- find_entities_filtered calls (Factorio's filter ANDs type/name together within one
-- call, it can't OR a type against a name list) merged into one result list.
local function find_clearable_obstacles(surf, pos, radius)
  local trees = surf.find_entities_filtered{position = pos, radius = radius, type = "tree"}
  local rocks = surf.find_entities_filtered{position = pos, radius = radius, name = CLEARABLE_ROCK_NAMES}
  local out = {}
  for _, e in ipairs(trees) do out[#out + 1] = e end
  for _, e in ipairs(rocks) do out[#out + 1] = e end
  return out
end

-- Ask the game pathfinder for a route to q.target that goes AROUND large obstacles
-- (water, cliffs) -- the straight-line + perpendicular bypass only clears small
-- stuff (trees/rocks) and cannot navigate around a lake. Result arrives async via
-- on_script_path_request_finished and is stored as q.path (list of waypoints).
local function request_walk_path(cid, q, e)
  local proto = prototypes.entity["character"]
  local ok, id = pcall(function()
    return e.surface.request_path{
      bounding_box = proto.collision_box,
      collision_mask = proto.collision_mask,
      start = e.position,
      goal = q.target,
      force = e.force,
      radius = 2,
      can_open_gates = true,
      -- CRITICAL: ignore the companion itself, otherwise its own collision box makes
      -- the START position collide -> pathfinder returns nil (no path) every time.
      entity_to_ignore = e,
      pathfind_flags = {cache = false, low_priority = false},
    }
  end)
  if ok and id then
    storage.path_requests[id] = cid
    q.path_pending = true
    q.path_req_tick = game.tick
  else
    -- API/call failed -> fall back to straight-line; retry later
    q.path_failed_tick = game.tick
  end
end

script.on_event(defines.events.on_script_path_request_finished, function(ev)
  local cid = storage.path_requests and storage.path_requests[ev.id]
  if not cid then return end
  storage.path_requests[ev.id] = nil
  local q = storage.walking_queues and storage.walking_queues[cid]
  if not q then return end
  q.path_pending = false
  if ev.path and #ev.path > 0 then
    q.path = ev.path           -- array of {position=, needs_destroy_to_reach=}
    q.path_idx = 1
    -- DIAGNOSTIC (task #49, 2026-07-09): needs_destroy_to_reach is stored above but was
    -- NEVER consulted anywhere in process_walking_queues -- if the pathfinder's route
    -- requires destroying something (a rock too big for the generic radius=2/4
    -- tree/rock scan, or a cliff, which needs explosives rather than mining_state) at a
    -- waypoint, the mod would just aim at that waypoint's position forever with no code
    -- path to act on it. Logging (not yet fixing) to confirm/refute this live before
    -- writing a fix, per this project's own mandatory live-verify-before-fixing rule.
    for _, wp in ipairs(ev.path) do
      if wp.needs_destroy_to_reach then
        u.log_error(string.format(
          "walking path for companion %d needs_destroy_to_reach near (%.1f,%.1f) -- "
          .. "NOT currently acted on, character will likely get stuck here", cid,
          wp.position.x, wp.position.y), "walk_path_needs_destroy")
        break
      end
    end
  else
    q.path = nil               -- no route found / try later -> straight-line fallback
    q.path_failed_tick = game.tick
    -- DIAGNOSTIC (task #49, 2026-07-09): distinguishes "pathfinder genuinely found no
    -- route" (this branch) from "needs to destroy something" (above) and from "still
    -- pending" -- the three collapse into identical straight-line+bypass behavior today,
    -- but have very different real causes/fixes.
    u.log_error(string.format(
      "walking path request for companion %d returned NO PATH (target=(%.1f,%.1f))",
      cid, q.target and q.target.x or -1, q.target and q.target.y or -1),
      "walk_path_no_path")
  end
end)

-- Walking queues: follow a pathfinder route around obstacles when available, with
-- straight-line + perpendicular bypass as the fallback for small obstacles.
local function process_walking_queues()
  if not storage.walking_queues then return end
  for cid, q in pairs(storage.walking_queues) do
    local c = u.get_companion(cid)
    if not c then storage.walking_queues[cid] = nil; goto skip end
    if q.follow_player then
      local p = game.players[q.follow_player]
      if p and p.valid then q.target = {x = p.position.x, y = p.position.y}
      else storage.walking_queues[cid] = nil; goto skip end
    end
    if not q.target then storage.walking_queues[cid] = nil; goto skip end
    local e = c.entity
    local dist = u.distance(e.position, q.target)

    -- Proactive reach=1 clearing (2026-07-05, Zdendys): "whenever the companion
    -- encounters a decorative rock (an entity, not an ore deposit), or any tree
    -- (within reach 1 of the character), it mines it" -- ANY tree or decorative rock within reach=1 gets mined on
    -- sight, regardless of whether the companion is stuck, still approaching, or has
    -- just arrived. MUST run unconditionally BEFORE the dist<2 arrival check below, not
    -- inside the still-approaching `else` branch: live-testing found the two states race
    -- -- a target whose collision box keeps the companion within [1, 2) tiles (e.g. a
    -- big-rock placed as the destination itself) satisfies "arrived" (dist<2) on the very
    -- tick it FIRST comes within reach=1, so a check placed only in the "still walking"
    -- branch never runs at all for that tick (arrival short-circuits into the `if` branch
    -- and removes the queue entry before the `else`'s clearing logic is ever reached).
    --
    -- NATIVE sustained mining (2026-07-05, Zdendys: "to je zakladni pozadavek jakehokoli
    -- mininguu, to mod nevi?" -- correctly called out): a big-rock's mining_time is real
    -- (tens of ticks or more, same as a player holding the mine button) -- a single
    -- scripted `entity.mine{}` call does NOT model that gradual progress and simply fails
    -- silently on anything with non-trivial mining_time. Reusing the EXACT pattern already
    -- proven for ore/resource harvesting elsewhere in this mod (queues.lua's
    -- start_mining_next/tick_harvest_queues): set `selected` + `mining_state={mining=true,
    -- position=...}` and let the GAME ENGINE run the real mining cycle -- same speed,
    -- animation, extraction as a real player. `q.clearing_target` tracks which entity is
    -- currently being sustained-mined so mining_state is only ever ASSIGNED once per
    -- target: re-assigning it every cycle (every 5 ticks here) would restart the engine's
    -- mining_time countdown from zero every time and it would NEVER complete (the exact
    -- "re-setting mining_state every tick" bug already caught and fixed in
    -- tick_gather_queues, 2026-07-03).
    if q.clearing_target and not q.clearing_target.valid then
      q.clearing_target = nil  -- previous target is gone (fully mined, or otherwise removed)
    end
    -- Stale-but-still-valid target guard (cubic-dev-ai bot, 2026-07-05): a target only
    -- ever got cleared above when the ENTITY itself became invalid -- not when the
    -- companion simply walked away from it (e.g. redirected to a new q.target, or
    -- follow_player moved elsewhere). Factorio's engine auto-cancels mining_state.mining
    -- once the selected entity is out of reach, but q.clearing_target itself stayed set
    -- (still a valid entity, just distant) -- and since ALL new-target acquisition below
    -- is gated by `if not q.clearing_target`, a stale distant target would silently block
    -- the reach=2 AND the radius=4 stuck-fallback scans from EVER picking a new, genuinely
    -- nearby obstacle again, for as long as this walking_queue entry lives (which can be
    -- indefinitely in follow_player mode). 6 tiles = a bit more than the widest radius
    -- (4) either scan below can acquire a target from, so this only fires once the
    -- companion has clearly moved on, not from ordinary approach jitter at the boundary.
    if q.clearing_target and u.distance(e.position, q.clearing_target.position) > 6 then
      q.clearing_target = nil
    end
    if not q.clearing_target then
      -- radius=2, not a literal 1 (2026-07-05, live-tested): collision keeps the
      -- companion's CENTER measurably farther than 1 tile from a big/huge-rock's
      -- CENTER (their collision box extends to ~1-1.5 tiles from center, confirmed via
      -- prototypes.entity[...].collision_box) -- the companion stably parks at ~1.6
      -- tiles away, which IS "right next to it" in any visual/practical sense, just not
      -- within a literal radius=1 sample from center-to-center. radius=2 matches the
      -- SAME threshold this function already uses elsewhere for "arrived" (dist<2), and
      -- still only ever catches things genuinely adjacent (trees have a much smaller
      -- ~0.4-tile collision box and stop even closer).
      local adjacent = find_clearable_obstacles(e.surface, e.position, 2)
      if adjacent[1] then
        q.clearing_target = adjacent[1]
      end
    end
    if q.clearing_target then
      if e.selected ~= q.clearing_target then
        e.selected = q.clearing_target
      end
      if not e.mining_state.mining then
        e.mining_state = {mining = true, position = q.clearing_target.position}
      end
    end

    if dist < 2 then
      e.walking_state = {walking = false}
      if not q.follow_player then storage.walking_queues[cid] = nil end
      q.stuck_ticks = 0
      q.bypass_ticks = 0
    else
      -- Fast giveup (2026-07-16, Zdendys's directive): ONLY for fac_move_to()-driven
      -- walks (q.giveup_enabled, set in commands/move.lua -- every OTHER caller of
      -- this same walking-queue mechanism, e.g. queues.start_build's own approach
      -- walk or task_pool.lua's step-driven movement, is completely untouched by
      -- this block, byte-identical to before). Tracks NET WORLD-SPACE displacement
      -- over rolling ~60-ACTIVE-tick windows (ACTIVE = excludes ticks spent waiting
      -- on a pending pathfind request, per Zdendys's own explicit "nepocitat dobu
      -- vypoctu trasy" requirement) rather than the EXISTING per-sample q.stuck_ticks
      -- check just below (which resets on ANY physical movement, including a
      -- perpendicular bypass step that doesn't actually unstick her at all -- an
      -- oscillating companion that bypasses left-right-left forever would never trip
      -- q.stuck_ticks, since each individual bypass tick genuinely moves her).
      -- Deliberately NET POSITION, not distance-to-target (Zdendys's own correction):
      -- distance-to-target would misfire on a legitimate pathfinder detour that goes
      -- AWAY from the target first ("sometimes it's necessary to go back by 180
      -- degrees"); net position change is immune to that -- see the check itself, below.
      --
      -- Threshold: 600 active ticks (Zdendys's own explicit number, 2026-07-16: "I'd
      -- give it 600! In real speed that's 10s, that should get the companion closer
      -- to the target on the starting map" -- 10 real seconds at game.speed=1, comfortably
      -- above a single bypass cycle (50 ticks) and the now-capped 4 bypass attempts
      -- (see q.bypass_attempts just below, also 2026-07-16) -- this must NOT
      -- reintroduce the 2026-07-06 regression (an earlier, too-aggressive stuck
      -- check gave up on a target that WAS reachable, confirmed live). Still a
      -- MASSIVE improvement over companion.py's own current real-wall-clock-based
      -- give-up (observed live: ~8640 ticks, i.e. up to 36 real seconds at typical
      -- FACTORIO_GAME_SPEED), and measured in game ticks so it behaves identically
      -- regardless of game.speed, unlike that Python-side mechanism. 10 windows of
      -- 60 active ticks each = 600.
      --
      -- Outcome (Zdendys: "the mod tells Py that the target is unreachable", not a raw counter
      -- -- and if <4 tiles from target, report 'approx_arrived' instead of a hard
      -- failure, since that's "plenty sufficient" for most construction): stashed
      -- in storage.walk_last_outcome[cid], consumed once by fac_companion_position's
      -- handler (commands/companion.lua) the next time companion.py polls position
      -- -- no new RCON round-trip needed on either side.
      if q.giveup_enabled then
        if not q.path_pending then
          q.active_ticks = (q.active_ticks or 0) + 5
        end
        if not q.checkpoint_active_ticks then
          q.checkpoint_active_ticks = q.active_ticks or 0
          q.checkpoint_pos = {x = e.position.x, y = e.position.y}
        elseif (q.active_ticks or 0) - q.checkpoint_active_ticks >= 60 then
          -- NET WORLD-SPACE displacement since the last checkpoint (2026-07-16,
          -- Zdendys's own correction: comparing DISTANCE-TO-TARGET here instead, as
          -- an earlier draft of this did, would misfire on a legitimate pathfinder
          -- detour that goes AWAY from the target first -- "sometimes it's necessary
          -- to go back (by 180 degrees) and try a different direction at a greater
          -- distance" --
          -- that raises distance-to-target even while making completely genuine
          -- progress along a real route. Net position change is immune to this: a
          -- companion actually walking a detour (even backward) covers REAL ground
          -- every window; only genuine in-place stalling/oscillating (e.g. repeated
          -- bypass attempts that cancel out) shows near-zero net displacement.
          local net_moved = u.distance(q.checkpoint_pos, e.position)
          if net_moved < 0.3 then
            q.stall_windows = (q.stall_windows or 0) + 1
          else
            q.stall_windows = 0
          end
          q.checkpoint_active_ticks = q.active_ticks
          q.checkpoint_pos = {x = e.position.x, y = e.position.y}
          if q.stall_windows >= 10 then
            storage.walk_last_outcome[cid] = {
              result = (dist < 4) and "approx_arrived" or "unreachable",
              tick = game.tick,
            }
            storage.walking_queues[cid] = nil
            e.walking_state = {walking = false}
            goto skip
          end
        end
      end

      -- Pathfind around big obstacles (water/cliffs): request a route once per
      -- target, then steer toward the current WAYPOINT instead of straight at the
      -- final goal. Falls back to straight-line below while no route is available.
      -- timeout a stuck pending request: if the finished-event never arrives (e.g. the
      -- request id was lost across save/load), reset so pathfinding isn't disabled forever.
      if q.path_pending and q.path_req_tick and (game.tick - q.path_req_tick) > 600 then
        q.path_pending = false
        q.path_failed_tick = game.tick
      end
      if not q.follow_player and not q.path and not q.path_pending then
        local cooling = q.path_failed_tick and (game.tick - q.path_failed_tick) < 180
        if not cooling then request_walk_path(cid, q, e) end
      end
      -- Wait for the FIRST pathfind result before moving at all (2026-07-16, Zdendys:
      -- "mel by pockat na dorazeni trasy od pathfinderu" -- a small-peninsula/dead-end
      -- scenario: straight-line steering toward q.target while the smarter route is
      -- STILL being computed could walk the companion onto a dead-end peninsula
      -- jutting into water BEFORE the real detour around it is even known, since
      -- q.path is nil the whole time a request is pending -- goal would otherwise
      -- fall through to the plain q.target below and steer straight at it). Only
      -- gates the FIRST-ever pathfind for this target (path_pending true AND no path
      -- decided EITHER way yet) -- once path_pending resolves (a real route, OR a
      -- confirmed "no path found" -- see on_script_path_request_finished), normal
      -- waypoint-following/straight-line-fallback logic below runs exactly as
      -- before, unchanged. Applies to EVERY walk (task-pool steps, start_build's own
      -- approach walk, follow_player is naturally excluded since it never sets
      -- path_pending at all), not just fac_move_to's giveup_enabled ones -- this is
      -- a general correctness fix, not scoped to the fast-giveup feature above.
      -- (Zdendys separately asked whether the NEXT target's path could be
      -- precomputed while still finishing the CURRENT one, hiding this wait
      -- entirely -- not implemented here: this project's Python side has no
      -- forward-looking queue of upcoming movement targets today, each go_to() is
      -- issued one at a time and Python doesn't know/decide its next destination
      -- until the current call returns, so there is no "next target" to precompute
      -- against yet. A real architectural change, not part of this fix.)
      if q.path_pending and not q.path then
        e.walking_state = {walking = false}
        goto skip
      end
      local goal = q.target
      if q.path and q.path_idx then
        while q.path[q.path_idx] and u.distance(e.position, q.path[q.path_idx].position) < 2 do
          q.path_idx = q.path_idx + 1
        end
        if q.path[q.path_idx] then
          goal = q.path[q.path_idx].position
          -- Proactively clear a FLAGGED waypoint's obstacle (task #49, 2026-07-09):
          -- needs_destroy_to_reach was stored on q.path entries since this was written
          -- but never consulted anywhere -- confirmed live (test_walk_stuck_diag.py)
          -- that the pathfinder DOES set this flag in real play. The generic reach=2/4
          -- stuck-clearing above only searches near the CHARACTER's current position,
          -- which may never trigger if the flagged waypoint is still several tiles
          -- ahead and the character isn't yet "stuck" by the moved<0.3 measure -- search
          -- right at the WAYPOINT instead, so a mineable tree/rock blocking it gets
          -- targeted before the character ever walks into it.
          if q.path[q.path_idx].needs_destroy_to_reach and not q.clearing_target then
            local blockers = find_clearable_obstacles(e.surface, goal, 2)
            if blockers[1] then
              q.clearing_target = blockers[1]
              e.selected = blockers[1]
              e.mining_state = {mining = true, position = blockers[1].position}
              -- Positive-path diagnostic (task #49, 2026-07-09): without this, a run
              -- where the flag fires AND gets successfully cleared looks IDENTICAL to a
              -- run where it never fired at all (both show 0 walk_path_* log entries) --
              -- logged so live verification can actually distinguish "never triggered"
              -- from "triggered and this fix handled it".
              u.log_error(string.format(
                "walking path for companion %d needs_destroy_to_reach at (%.1f,%.1f) -- "
                .. "found %s, clearing it now", cid, goal.x, goal.y, blockers[1].name),
                "walk_path_clearing")
            else
              -- Flagged but no mineable tree/rock found there -- most likely a cliff,
              -- which needs cliff-explosives (a separate mechanic, not handled here).
              -- Logged distinctly so this stays a visible, trackable case instead of
              -- silently stalling with no diagnostic trail.
              u.log_error(string.format(
                "walking path for companion %d needs_destroy_to_reach at (%.1f,%.1f) but "
                .. "no mineable tree/rock found there -- likely a cliff (needs explosives, "
                .. "not yet handled)", cid, goal.x, goal.y), "walk_path_unclearable")
            end
          end
        else
          q.path = nil  -- consumed all waypoints; head straight to final target
        end
      end

      -- Stuck detection: compare position to previous call
      local prev = q.prev_pos
      local moved = prev and u.distance(prev, e.position) or 1
      q.prev_pos = {x = e.position.x, y = e.position.y}

      -- Stuck AND nothing within reach=1 to sustained-mine (the block above already
      -- covers the common case): the actual blocker may be slightly farther away than
      -- reach=1 (a wider obstacle's collision edge, or simply not centered under the
      -- reach=1 sample point) -- widen the search to radius=4 and target it via the SAME
      -- q.clearing_target + mining_state mechanism (not a separate one-shot entity.mine{}
      -- -- same reasoning as above: mining_time is real, one-shot calls fail silently).
      if moved < 0.3 and not q.clearing_target then
        local nearby = find_clearable_obstacles(e.surface, e.position, 4)
        if nearby[1] then
          q.clearing_target = nearby[1]
          e.selected = nearby[1]
          e.mining_state = {mining = true, position = nearby[1].position}
        end
      end

      if moved < 0.3 then
        q.stuck_ticks = (q.stuck_ticks or 0) + 1
      elseif (q.bypass_ticks or 0) == 0 and not q.bypass_just_ended then
        -- Only clear stuck/bypass state on CONFIRMED genuine resumed movement --
        -- NOT merely "moved at all this tick" (2026-07-17 live-caught: "Zaseknuti o
        -- trubku, meni smer, leva prava asi 1000x, bez uspechu" -- a companion
        -- trapped between two symmetric dead ends, e.g. a just-placed pipe row on
        -- one side and water on the other). Root cause: this branch used to fire
        -- UNCONDITIONALLY whenever moved>=0.3, including on every tick the bypass
        -- ITSELF was actively walking her perpendicular (genuine displacement, but
        -- not evidence she's actually unstuck) -- wiping bypass_ticks/bypass_side/
        -- bypass_attempts before the bypass's own intended 10-tick duration ever
        -- completed, AND before bypass_attempts could ever accumulate past 1 toward
        -- its documented 4-attempt cap (see the elseif below: "2 rounds of
        -- left+right"). The result: every stuck cycle restarted from scratch
        -- (bypass_side always re-derives to the SAME first side from nil, never
        -- truly alternating; bypass_attempts never reaches the cap), so the 4-cap
        -- never engaged and she oscillated indefinitely within the outer
        -- approach_deadline window instead of giving up on both directions after 4
        -- tries. Two guards now gate the reset: (a) q.bypass_ticks==0 -- don't
        -- interrupt an in-progress bypass sequence just because ITS OWN motion
        -- counts as displacement; (b) q.bypass_just_ended (set for exactly one tick
        -- right after a bypass sequence's last tick, below) -- the tick immediately
        -- following bypass completion still reflects the bypass's OWN tail motion,
        -- not yet a confirmed return to genuine forward progress; only a LATER tick
        -- (a full cycle of the ordinary "walk toward target" branch actually
        -- producing displacement) can honestly confirm she's moving again.
        q.stuck_ticks = 0
        q.bypass_side = nil
        q.bypass_attempts = nil
      end
      q.bypass_just_ended = false

      local dir_to_target = u.get_direction(e.position, goal)

      if (q.bypass_ticks or 0) > 0 then
        -- Continue bypass: walk perpendicular to unblock
        if q.bypass_dir then
          e.walking_state = {walking = true, direction = q.bypass_dir}
        end
        q.bypass_ticks = q.bypass_ticks - 1
        if q.bypass_ticks == 0 then
          -- Flags the NEXT tick's stuck-check (above) to skip the reset once --
          -- see that check's own comment for why (this bypass's own last tick of
          -- perpendicular motion isn't yet confirmed genuine forward progress).
          q.bypass_just_ended = true
        end
      elseif (q.stuck_ticks or 0) >= 4 and (q.bypass_attempts or 0) < 4 then
        -- Stuck for ~0.3s: try perpendicular bypass, alternating left/right. Capped
        -- at 4 attempts total (2026-07-16, Zdendys: "it's enough to try each
        -- direction once, at most 2x, to find out it doesn't work" -- 2 rounds of left+right) -- once
        -- neither direction has unstuck her after 2 full rounds, repeating the SAME
        -- two directions indefinitely is pure wasted cycles; the pathfinder's own
        -- separate periodic retry (request_walk_path's 180-tick cooldown, below)
        -- is a genuinely DIFFERENT recovery strategy and keeps running regardless
        -- of this cap. Reset to 0 (not nil) the moment real movement resumes
        -- (the `else` branch just above), giving a fresh set of attempts for the
        -- NEXT time she gets stuck, rather than a one-shot lifetime budget.
        q.stuck_ticks = 0
        q.bypass_attempts = (q.bypass_attempts or 0) + 1
        q.bypass_side = ((q.bypass_side or 0) + 1) % 2
        local perp_dirs = {
          [defines.direction.north] = {defines.direction.west, defines.direction.east},
          [defines.direction.south] = {defines.direction.east, defines.direction.west},
          [defines.direction.east]  = {defines.direction.north, defines.direction.south},
          [defines.direction.west]  = {defines.direction.south, defines.direction.north},
          [defines.direction.northeast] = {defines.direction.northwest, defines.direction.southeast},
          [defines.direction.southeast] = {defines.direction.northeast, defines.direction.southwest},
          [defines.direction.southwest] = {defines.direction.southeast, defines.direction.northwest},
          [defines.direction.northwest] = {defines.direction.southwest, defines.direction.northeast},
        }
        local choices = dir_to_target and perp_dirs[dir_to_target]
        if choices then
          q.bypass_dir = choices[(q.bypass_side % 2) + 1]
          q.bypass_ticks = 10  -- bypass for 10 calls (~0.5s)
          e.walking_state = {walking = true, direction = q.bypass_dir}
        end
      else
        -- Normal movement toward target
        if dir_to_target then e.walking_state = {walking = true, direction = dir_to_target} end
      end
    end
    ::skip::
  end
end

script.on_nth_tick(5, function(ev)
  if ev.tick % 1800 == 0 then cleanup_messages() end
  -- Update map markers every 30 ticks (0.5 sec)
  if ev.tick % 30 == 0 then update_companion_markers() end
  -- Process all tick-based queues (each guarded so one failure can't kill the rest)
  guard_tick("harvest", queues.tick_harvest_queues, ev.tick)
  guard_tick("gather",  queues.tick_gather_queues,  ev.tick)
  guard_tick("fuel",    queues.tick_fuel_queues,    ev.tick)
  guard_tick("craft",   queues.tick_craft_queues,   ev.tick)
  guard_tick("build",   queues.tick_build_queues,   ev.tick)
  guard_tick("belt",    queues.tick_belt_queues,    ev.tick)
  guard_tick("combat",  queues.tick_combat_queues,  ev.tick)
  guard_tick("walking", process_walking_queues,     ev.tick)
  guard_tick("spectate", spectate.tick_spectators,  ev.tick)
  guard_tick("orphan_mining", queues.tick_orphan_mining_cleanup, ev.tick)
  guard_tick("task_pool", task_pool.tick, ev.tick)
end)
