local lifecycle = require("commands.lifecycle")
-- AI Companion - Factorio 2.x
local u = require("commands.init")
local queues = require("commands.queues")
local task_pool = require("commands.task_pool")
local player_input = require("commands.player_input")
local gui = require("commands.gui")

-- Get version dynamically from mod info
local MOD_VERSION = script.active_mods["ai-companion"] or "unknown"

local resources = require("commands.resource_query")
local WALK = u.settings.walking
local WALK_TARGET_WALKABLE_RADIUS = u.settings.walking.target_walkable_radius

local WAYPOINT_STALL_REPATH_TICKS = u.settings.walking.waypoint_stall_repath_ticks

local function init_storage()
  storage.companion_messages = storage.companion_messages or {}
  storage.companions = storage.companions or {}
  storage.dead_companions = storage.dead_companions or {}
  storage.companion_next_id = storage.companion_next_id or 1
  storage.walking_queues = storage.walking_queues or {}
  storage.errors = storage.errors or {}
  storage.companion_markers = storage.companion_markers or {}
  storage.path_requests = storage.path_requests or {}
  storage.walk_last_outcome = storage.walk_last_outcome or {}
  storage.walk_last_arrived = storage.walk_last_arrived or {}
  queues.init()
  task_pool.init()
  gui.rebuild()
end

local function cleanup_messages()
  local limit = u.settings.retention.chat_messages
  while #storage.companion_messages > limit do table.remove(storage.companion_messages, 1) end
  local completed = {}
  for id, task in pairs(storage.tasks) do if task.status ~= "active" then completed[#completed + 1] = id end end
  table.sort(completed)
  for i = 1, #completed - u.settings.retention.completed_tasks do storage.tasks[completed[i]] = nil end
end

script.on_init(function()
  init_storage()
  game.print("[AI Companion] v" .. MOD_VERSION .. " ready. /fac for help", u.print_color(u.COLORS.system))
end)

script.on_configuration_changed(function()
  init_storage()
  for id in pairs(storage.companions) do lifecycle.stop(id) end
  game.print("[AI Companion] Updated to v" .. MOD_VERSION, u.print_color(u.COLORS.system))
end)

local subcommands = {}

subcommands.gui = function(player, args)
  local target = player or (args ~= "" and game.get_player(args))
  if not target then error("Specify a player to open companion controls") end
  gui.open(target)
end

subcommands.spawn = function(player, args)
  local count = math.min(tonumber(args) or 1, 10)
  table.insert(storage.companion_messages, {player = player and player.name or "server", message = "spawn " .. count, tick = game.tick, spawn_request = count})
  game.print("[" .. (player and player.name or "server") .. "] Spawn " .. count .. " companion(s)...", u.print_color(u.COLORS.player))
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
    lifecycle.stop(cid)
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
      if player then gui.open(player) end
      return
    end
    local first, rest = param:match("^(%S+)%s+(.+)$")
    if first and rest and not subcommands[first] then
      local id, comp = u.find_companion(first)
      if id then
        local _, err = player_input.send(player, rest, id)
        if err then error(err) end
        return
      end
    end
    local sub, args = param:match("^(%S+)%s*(.*)")
    if subcommands[sub] then subcommands[sub](player, args)
    else
      local _, err = player_input.send(player, param, 0)
      if err then error(err) end
    end
  end)
  if not ok then u.log_error(err, "fac"); game.print("Error: " .. tostring(err), u.print_color(u.COLORS.error)) end
end

commands.add_command("fac", "AI Companion", handle_fac)

require("commands.action")
require("commands.building")
require("commands.chat")
require("commands.companion")
require("commands.item")
require("commands.observation")
require("commands.move")
require("commands.research")
require("commands.resource")
require("commands.task")
require("commands.world")
require("commands.combat")
require("commands.help")
require("commands.dispatch")

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
    u.log_error(tostring(err), name)
    if tick % 300 == 0 then
      game.print("[AI Companion] " .. name .. " tick error: " .. tostring(err),
        u.print_color(u.COLORS.error))
    end
  end
end

local function find_clearable_obstacles(surf, pos, radius)
  return resources.within(surf, pos, {type=WALK.obstacle_types,hand_only=true}, radius)
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
    q.path_request_id = id
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
  if not q or q.path_request_id ~= ev.id then return end
  q.path_pending = false
  if ev.path and #ev.path > 0 then
    q.path = ev.path           -- array of {position=, needs_destroy_to_reach=}
    q.path_idx = 1
    q.progress_distance = nil
    q.unclearable_path_idx = nil
  else
    q.path = nil               -- no route found / try later -> straight-line fallback
    q.path_failed_tick = game.tick
    u.log_error(string.format(
      "walking path request for companion %d returned NO PATH (target=(%.1f,%.1f))",
      cid, q.target and q.target.x or -1, q.target and q.target.y or -1),
      "walk_path_no_path")
    -- RARE-WALK-01 (2026-07-19/20, Zdendys's save-for-later-review scheme -- see
    -- STATUS.md and u.rare_symptom_save's own comment for the full mechanism):
    -- captures the exact moment/state of a no-path failure for later visual
    -- inspection, debounced per-code so a repeat within the cooldown doesn't spam.
    u.rare_symptom_save("RARE-WALK-01")
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
    if not q.follow_player and not q.target_checked then
      q.target_checked = true
      local ok, corrected = pcall(function()
        return e.surface.find_non_colliding_position(
          "character", q.target, WALK_TARGET_WALKABLE_RADIUS, 0.5)
      end)
      if ok and corrected and u.distance(corrected, q.target) > 0.1 then
        u.log_error(string.format(
          "walk target (%.1f,%.1f) for companion %d was not walkable -- retargeting to "
          .. "nearest walkable position (%.1f,%.1f)",
          q.target.x, q.target.y, cid, corrected.x, corrected.y), "walk_target_retargeted")
        q.target = {x = corrected.x, y = corrected.y}
      end
    end
    local dist = u.distance(e.position, q.target)

    if q.clearing_target and (not q.clearing_target.valid
        or u.distance(e.position, q.clearing_target.position) > u.settings.queue_tuning.mining_range) then
      q.clearing_target = nil
      e.mining_state = {mining=false}
      q.last_progress_tick = game.tick
    end
    if q.clearing_target then
      if e.selected ~= q.clearing_target then
        e.selected = q.clearing_target
        e.mining_state = {mining = true, position = q.clearing_target.position}
      elseif not e.mining_state.mining then
        e.mining_state = {mining = true, position = q.clearing_target.position}
      end
    end

    if dist < 2 then
      e.walking_state = {walking = false}
      if q.clearing_target then e.mining_state = {mining=false}; q.clearing_target = nil end
      if not q.follow_player then
        storage.walk_last_arrived[cid] = {x = q.target.x, y = q.target.y, tick = game.tick}
        storage.walking_queues[cid] = nil
      end
      q.stuck_ticks = 0
      q.bypass_ticks = 0
    else
      if q.giveup_enabled then
        if not q.path_pending then
          q.active_ticks = (q.active_ticks or 0) + 5
        end
        if not q.checkpoint_active_ticks then
          q.checkpoint_active_ticks = q.active_ticks or 0
          q.checkpoint_pos = {x = e.position.x, y = e.position.y}
        elseif (q.active_ticks or 0) - q.checkpoint_active_ticks >= 60 then
          local net_moved = u.distance(q.checkpoint_pos, e.position)
          if net_moved < 0.3 and not (q.last_progress_tick and game.tick-q.last_progress_tick < 60) then
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
            if q.clearing_target then e.mining_state = {mining=false} end
            goto skip
          end
        end
      end

      if q.path_pending and q.path_req_tick and (game.tick - q.path_req_tick) > 600 then
        q.path_pending = false
        q.path_failed_tick = game.tick
      end
      if not q.follow_player and not q.path and not q.path_pending then
        local cooling = q.path_failed_tick and (game.tick - q.path_failed_tick) < 180
        if not cooling then request_walk_path(cid, q, e) end
      end
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
          if q.path[q.path_idx].needs_destroy_to_reach and not q.clearing_target then
            local blockers = find_clearable_obstacles(e.surface, goal, WALK.obstacle_search_radius)
            if blockers[1] then
              q.clearing_target = blockers[1]
              e.selected = blockers[1]
              e.mining_state = {mining = true, position = blockers[1].position}
            elseif q.unclearable_path_idx ~= q.path_idx then
              q.unclearable_path_idx = q.path_idx
              u.log_error(string.format(
                "Companion %d cannot hand-mine the path obstacle at (%.1f,%.1f)",
                cid, goal.x, goal.y), "walk_path_unclearable")
              u.rare_symptom_save("RARE-WALK-02")
            end
          end
        else
          q.path = nil  -- consumed all waypoints; head straight to final target
        end
      end

      local goal_distance = u.distance(e.position, goal)
      local mining_progress = e.mining_progress or 0
      local waypoint_changed = q.last_path_idx ~= q.path_idx
      local progressing = (q.clearing_target and mining_progress ~= (q.mining_progress or 0))
        or (q.progress_distance and not waypoint_changed and q.progress_distance - goal_distance >= WALK.progress_distance)
        or (waypoint_changed and q.prev_pos and u.distance(q.prev_pos,e.position) >= WALK.progress_distance)
      q.mining_progress = mining_progress
      q.last_path_idx = q.path_idx
      if progressing then q.last_progress_tick = game.tick end
      if progressing or q.progress_distance == nil or waypoint_changed then
        q.progress_distance = goal_distance
        q.waypoint_stall_ticks = 0
      else
        q.waypoint_stall_ticks = (q.waypoint_stall_ticks or 0) + u.settings.queue_tuning.tick_interval
      end

      -- Stuck detection: compare position to previous call
      local prev = q.prev_pos
      local moved = prev and u.distance(prev, e.position) or 1
      q.prev_pos = {x = e.position.x, y = e.position.y}

      if q.clearing_target and progressing then
        q.stuck_ticks = 0
        q.bypass_ticks = 0
      elseif moved < 0.3 then
        q.stuck_ticks = (q.stuck_ticks or 0) + 1
      elseif (q.bypass_ticks or 0) == 0 and not q.bypass_just_ended then
        q.stuck_ticks = 0
        q.bypass_side = nil
        q.bypass_attempts = nil
      end
      q.bypass_just_ended = false

      -- Clear natural obstacles only after movement actually stalls, not every nearby tree.
      if (q.stuck_ticks or 0) >= 4 and not q.clearing_target then
        for _, obstacle in ipairs(find_clearable_obstacles(e.surface, e.position, WALK.obstacle_search_radius)) do
          local dx, dy = obstacle.position.x-e.position.x, obstacle.position.y-e.position.y
          if dx*(goal.x-e.position.x)+dy*(goal.y-e.position.y) >= 0 then
            q.clearing_target = obstacle
            e.selected = obstacle
            e.mining_state = {mining=true,position=obstacle.position}
            break
          end
        end
      end

      local dir_to_target = u.get_direction(e.position, goal)

      if (q.waypoint_stall_ticks or 0) >= WAYPOINT_STALL_REPATH_TICKS and q.path then
        u.log_error(string.format(
          "walking path for companion %d stalled on the same waypoint for %d "
          .. "ticks -- requesting a fresh path around the current obstacle "
          .. "instead of repeating the same blocked step", cid,
          q.waypoint_stall_ticks), "walk_path_repath_after_stuck")
        q.path = nil
        q.path_idx = nil
        q.last_path_idx = nil
        q.progress_distance = nil
        q.waypoint_stall_ticks = 0
        q.stuck_ticks = 0
        q.bypass_attempts = nil
        q.bypass_side = nil
        q.bypass_ticks = 0
        e.walking_state = {walking = false}
        if q.clearing_target then e.mining_state = {mining=false}; q.clearing_target = nil end
      elseif not q.clearing_target and (q.bypass_ticks or 0) > 0 then
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
      elseif not q.clearing_target and (q.stuck_ticks or 0) >= 4 and (q.bypass_attempts or 0) < 4 then
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

script.on_nth_tick(u.settings.queue_tuning.tick_interval, function(ev)
  if ev.tick % 1800 == 0 then cleanup_messages() end
  -- Update map markers every 30 ticks (0.5 sec)
  if ev.tick % 30 == 0 then update_companion_markers() end
  if ev.tick % u.settings.overlay.refresh_ticks == 0 then guard_tick("gui", gui.tick, ev.tick) end
  -- Process all tick-based queues (each guarded so one failure can't kill the rest)
  for _, name in ipairs(u.settings.queues) do
    if name ~= "walking" then guard_tick(name, queues["tick_" .. name .. "_queues"], ev.tick) end
  end
  guard_tick("walking", process_walking_queues,     ev.tick)
  guard_tick("orphan_mining", queues.tick_orphan_mining_cleanup, ev.tick)
  guard_tick("task_pool", task_pool.tick, ev.tick)
end)
