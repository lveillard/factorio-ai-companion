local u = require("commands.init")

u.register("action_attack", function(args)
  u.safe_command(function()
    local id, c = u.find_companion(args.companionId)
    if not id then u.not_found(); return end
    local x, y = tonumber(args.x), tonumber(args.y)
    if not x or not y then u.error_response("Invalid coordinates"); return end

    -- STOP WALKING - Clear walking queue so attack can take priority
    storage.walking_queues[id] = nil
    c.entity.walking_state = {walking = false}

    local target_pos = {x = x, y = y}
    local targets = c.entity.surface.find_entities_filtered{position = target_pos, radius = 2, limit = 1}
    local t = targets[1]
    if t and t.valid and t ~= c.entity and t.health then
      c.entity.shooting_state = {state = defines.shooting.shooting_enemies, position = t.position}
      u.json_response({id = id, attacking = true, target = t.name, position = {x = t.position.x, y = t.position.y}})
    else
      c.entity.shooting_state = {state = defines.shooting.shooting_enemies, position = target_pos}
      u.json_response({id = id, attacking = true, target = "ground", position = target_pos})
    end
  end)
end)

u.register("action_flee", function(args)
  u.safe_command(function()
    local id, c = u.find_companion(args.companionId)
    if not id then u.not_found(); return end
    local dist = tonumber(args.distance) or 30
    local pos = c.entity.position
    local enemies = c.entity.surface.find_entities_filtered{type = {"unit", "unit-spawner", "turret"}, position = pos, radius = 50, force = "enemy", limit = 5}
    if #enemies == 0 then u.json_response({id = id, fleeing = false, message = "No enemies"}); return end
    local ax, ay = 0, 0
    for _, e in ipairs(enemies) do ax, ay = ax + e.position.x, ay + e.position.y end
    ax, ay = ax / #enemies, ay / #enemies
    local dx, dy = pos.x - ax, pos.y - ay
    local len = math.sqrt(dx*dx + dy*dy)
    if len > 0 then dx, dy = dx / len * dist, dy / len * dist else dx = dist end
    local flee_pos = {x = pos.x + dx, y = pos.y + dy}
    storage.walking_queues[id] = {target = flee_pos}
    u.json_response({id = id, fleeing = true, enemies = #enemies, to = flee_pos})
  end)
end)
