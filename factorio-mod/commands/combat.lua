local u = require("commands.init")
local queues = require("commands.queues")

-- Detect nearby enemies
u.register("world_enemies", function(args)
  u.safe_command(function()
    local id, c = u.find_companion(args.companionId)
    if not id then u.not_found(); return end
    local radius = tonumber(args.radius) or 30

    local enemies = c.entity.surface.find_entities_filtered{
      position = c.entity.position,
      radius = radius,
      force = "enemy",
      type = {"unit", "unit-spawner", "turret"}
    }

    local result = {}
    for _, e in ipairs(enemies) do
      if e.valid then
        result[#result + 1] = {
          name = e.name,
          type = e.type,
          position = {x = math.floor(e.position.x), y = math.floor(e.position.y)},
          health = e.health,
          max_health = e.max_health,
          distance = math.floor(u.distance(c.entity.position, e.position))
        }
      end
    end

    table.sort(result, function(a, b) return a.distance < b.distance end)
    while #result > 20 do table.remove(result) end

    local threat = "safe"
    if #result > 5 then threat = "danger"
    elseif #result > 0 then threat = "caution" end

    u.json_response({id = id, enemies = result, count = #result, threat_level = threat})
  end)
end)

-- Start attacking enemies at position
u.register("action_attack_start", function(args)
  u.safe_command(function()
    local id, c = u.find_companion(args.companionId)
    if not id then u.not_found(); return end
    local x, y = tonumber(args.x), tonumber(args.y)
    local result = queues.start_combat(id, {x = x, y = y})
    result.id = id
    u.json_response(result)
  end)
end)

-- Check combat status
u.register("action_attack_status", function(args)
  u.safe_command(function()
    local id = u.find_companion(args.companionId)
    if not id then u.not_found(); return end
    local status = queues.get_combat_status(id)
    u.json_response({id = id, status = status}, id)
  end)
end)

-- Stop attacking
u.register("action_attack_stop", function(args)
  u.safe_command(function()
    local id = u.find_companion(args.companionId)
    if not id then u.not_found(); return end
    local result = queues.stop_combat(id)
    u.json_response({id = id, stopped = result.stopped, kills = result.kills or 0})
  end)
end)

-- Toggle auto-defend mode
u.register("action_defend", function(args)
  u.safe_command(function()
    local id, c = u.find_companion(args.companionId)
    if not id then u.not_found(); return end
    local mode = args.radius:lower()
    if mode == "on" or mode == "true" or mode == "1" then
      c.auto_defend = true
      u.json_response({id = id, auto_defend = true})
    else
      c.auto_defend = false
      u.json_response({id = id, auto_defend = false})
    end
  end)
end)
