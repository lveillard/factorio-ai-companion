-- AI Companion v0.7.0 - Move commands
local u = require("commands.init")

commands.add_command("fac_move_to", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)%s+([%d.-]+)%s+([%d.-]+)$", cmd.parameter)
    local id, c = u.find_companion(args[1])
    if not id then u.not_found(); return end
    local x, y = tonumber(args[2]), tonumber(args[3])
    if not x or not y then u.error_response("Invalid coordinates"); return end
    -- Enemy-base protection (Zdendys): never walk the companion to a tile next to a biter
    -- nest, so it can't provoke enemies. The opening never needs to -- a single starting
    -- patch can't be depleted, so every legit target stays near the safe spawn.
    local DANGER = 16
    if c.entity.surface.count_entities_filtered{type = "unit-spawner", position = {x = x, y = y}, radius = DANGER} > 0 then
      u.error_response("target too close to enemy base")
      return
    end
    -- Don't steal the walking queue from an ACTIVE task-pool step (2026-07-08, the
    -- other half of task_pool.lua's own idle-companion guard fix -- see that commit's
    -- comment for the full race description). storage.active_step[id] means the task
    -- pool is CURRENTLY driving this companion toward one of its own step targets;
    -- silently overwriting storage.walking_queues[id] here would leave that task-pool
    -- step's state stuck in "walking" forever (it polls for walking_queues[id] to
    -- clear on arrival, which will never happen at ITS target once redirected here) or
    -- have the companion "arrive" somewhere unrelated and get treated as if she'd
    -- reached the task-pool step's own destination. Reject instead -- Python's go_to()
    -- callers already retry on their own next decide() cycle when a move is refused.
    if storage.active_step and storage.active_step[id] then
      u.error_response("companion busy with an active task-pool step")
      return
    end
    -- giveup_enabled (2026-07-16, Zdendys's fast-giveup directive): ONLY fac_move_to's
    -- OWN walks opt into process_walking_queues' new fast-giveup check (control.lua) --
    -- every OTHER walking_queues[cid] writer in this mod (queues.start_build's approach
    -- walk, task_pool.lua's step-driven movement) omits this field entirely and is
    -- completely unaffected, byte-identical to before this feature existed.
    --
    -- Clear any stale walk_last_outcome (2026-07-16, independent-review finding):
    -- without this, staleness protection relied only on Python's OWN giveup timeout
    -- (~8640 ticks) being much larger than the mod's new one (600 active ticks) --
    -- an implicit numeric coincidence across two files, not a structural guarantee.
    -- Explicitly clearing here means a NEW walk can never see a leftover outcome
    -- from a PREVIOUS one for this same companion, regardless of either constant's
    -- future value.
    if storage.walk_last_outcome then storage.walk_last_outcome[id] = nil end
    storage.walking_queues[id] = {target = {x = x, y = y}, giveup_enabled = true}
    u.json_response({id = id, walking_to = {x = x, y = y}})
  end)
end)

commands.add_command("fac_move_follow", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)%s+(.+)$", cmd.parameter)
    local id = u.find_companion(args[1])
    if not id then u.not_found(); return end
    local pname = args[2]
    if not game.get_player(pname) then u.error_response("Player not found"); return end
    storage.walking_queues[id] = {follow_player = pname}
    u.json_response({id = id, following = pname})
  end)
end)

commands.add_command("fac_move_stop", nil, function(cmd)
  u.safe_command(function()
    local id, c = u.find_companion(cmd.parameter)
    if not id then u.not_found(); return end
    -- Same guard as fac_move_to above (2026-07-08, independent review caught this
    -- gap in the first half of the fix): companion.py's wait_arrive() calls this on
    -- give-up to clean up ITS OWN abandoned walking_queues[id] entry -- but if
    -- fac_move_to's guard above REFUSED an earlier move_to() (task pool owns this
    -- companion), Python never actually claimed the queue in the first place, and
    -- this unconditional clear+halt would instead cut off the task pool's OWN
    -- in-progress walk (storage.walking_queues[id]=nil looks like "arrived" to
    -- task_pool.lua's "walking"->"acting" check, and c.entity.walking_state=false
    -- physically stops her mid-route) -- silently breaking the very thing this
    -- guard was meant to protect. Only clear/halt if the task pool doesn't own her.
    if storage.active_step and storage.active_step[id] then
      u.error_response("companion busy with an active task-pool step -- not stopping")
      return
    end
    storage.walking_queues[id] = nil
    c.entity.walking_state = {walking = false}
    u.json_response({id = id, stopped = true})
  end)
end)
