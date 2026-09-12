local u = require("commands.init")

u.register("move_to", function(args)
  u.safe_command(function()
    local id, c = u.find_companion(args.companionId)
    if not id then u.not_found(); return end
    local x, y = tonumber(args.x), tonumber(args.y)
    if not x or not y then u.error_response("Invalid coordinates"); return end
    local DANGER = 16
    if c.entity.surface.count_entities_filtered{type = "unit-spawner", position = {x = x, y = y}, radius = DANGER} > 0 then
      u.error_response("target too close to enemy base")
      return
    end
    if storage.active_step and storage.active_step[id] then
      u.error_response("companion busy with an active task-pool step")
      return
    end
    if storage.walk_last_outcome then storage.walk_last_outcome[id] = nil end
    storage.walking_queues[id] = {target = {x = x, y = y}, giveup_enabled = true}
    u.json_response({id = id, walking_to = {x = x, y = y}})
  end)
end)

u.register("move_follow", function(args)
  u.safe_command(function()
    local id = u.find_companion(args.companionId)
    if not id then u.not_found(); return end
    local pname = args.playerName
    if not game.get_player(pname) then u.error_response("Player not found"); return end
    storage.walking_queues[id] = {follow_player = pname}
    u.json_response({id = id, following = pname})
  end)
end)

u.register("move_stop", function(args)
  u.safe_command(function()
    local id, c = u.find_companion(args.companionId)
    if not id then u.not_found(); return end
    if storage.active_step and storage.active_step[id] then
      u.error_response("companion busy with an active task-pool step -- not stopping")
      return
    end
    storage.walking_queues[id] = nil
    c.entity.walking_state = {walking = false}
    u.json_response({id = id, stopped = true})
  end)
end)
