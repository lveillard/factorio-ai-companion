local u = require("commands.init")
local queues = require("commands.queues")


u.register("resource_list", function(args)
  u.safe_command(function()
    local id, c = u.find_companion(args.companionId)
    if not id then u.not_found(); return end
    local filter = args.filter ~= "" and args.filter ~= "-" and args.filter or nil
    local radius = tonumber(args.radius) or 50
    local pos = c.entity.position
    local res = c.entity.surface.find_entities_filtered{type = "resource", position = pos, radius = radius, limit = 20}
    local found = {}
    for _, r in ipairs(res) do
      if not filter or r.name == filter then
        found[#found + 1] = {name = r.name, position = {x = math.floor(r.position.x), y = math.floor(r.position.y)}, amount = r.amount, distance = math.floor(u.distance(pos, r.position))}
      end
    end
    table.sort(found, function(a, b) return a.distance < b.distance end)
    u.json_response({id = id, resources = found, count = #found})
  end)
end)

u.register("resource_mine", function(args)
  u.safe_command(function()
    local id, c = u.find_companion(args.companionId)
    if not id then u.not_found(); return end
    local x, y, count = tonumber(args.x), tonumber(args.y), tonumber(args.count) or 1
    local resource_name = args.resourceName ~= "" and args.resourceName or nil
    if not x or not y then u.error_response("Invalid coordinates"); return end
    local tpos = {x = x, y = y}
    if u.distance(c.entity.position, tpos) > 5 then u.json_response({id = id, error = "Too far"}); return end
    -- Start realistic mining via queue system (with optional resource filter)
    local result = queues.start_harvest(id, tpos, count, resource_name)
    if result and not result.error then
      u.json_response({id = id, mining = true, target = count, entities = result.entities or 0, resource = resource_name, status = "started"})
    else
      u.json_response({id = id, error = result and result.error or "Failed to start mining"})
    end
  end)
end)

-- Check mining status
u.register("resource_mine_status", function(args)
  u.safe_command(function()
    local id = u.find_companion(args.companionId)
    if not id then u.not_found(); return end
    local status = queues.get_harvest_status(id)
    u.json_response({id = id, status = status}, id)
  end)
end)

-- Stop mining
u.register("resource_mine_stop", function(args)
  u.safe_command(function()
    local id = u.find_companion(args.companionId)
    if not id then u.not_found(); return end
    local result = queues.stop_harvest(id)
    u.json_response({id = id, stopped = result.stopped, harvested = result.harvested or 0})
  end)
end)

u.register("gather", function(args)
  u.safe_command(function()
    local id, c = u.find_companion(args.companionId)
    if not id then u.not_found(); return end
    local resource, count = args.resource, args.count
    local result = queues.start_gather(id, resource, count, args.exclude)
    if result.error then u.json_response({id = id, error = result.error})
    else u.json_response({id = id, gathering = true, resource = resource, target = count}) end
  end)
end)

u.register("gather_status", function(args)
  u.safe_command(function()
    local id = u.find_companion(args.companionId)
    if not id then u.not_found(); return end
    u.json_response({id = id, status = queues.get_gather_status(id)}, id)
  end)
end)

u.register("fuel_group", function(args)
  u.safe_command(function()
    local id, c = u.find_companion(args.companionId)
    if not id then u.not_found(); return end
    local per = tonumber(args.per) or 20
    local radius = tonumber(args.radius) or 200
    local result = queues.start_fuel_group(id, per, radius)
    if result.error then u.json_response({id = id, error = result.error})
    else u.json_response({id = id, fueling = true, per = per, radius = radius}) end
  end)
end)

u.register("fuel_group_status", function(args)
  u.safe_command(function()
    local id = u.find_companion(args.companionId)
    if not id then u.not_found(); return end
    u.json_response({id = id, status = queues.get_fuel_status(id)}, id)
  end)
end)

u.register("mine_diag", function(args)
  u.safe_command(function()
    local id = u.find_companion(args.companionId)
    if not id then u.not_found(); return end
    u.json_response({id = id, samples = queues.get_mine_diag(id)})
  end)
end)

u.register("resource_nearest", function(args)
  u.safe_command(function()
    local id, c = u.find_companion(args.companionId)
    if not id then u.not_found(); return end
    local name = args.resourceType
    local pos = c.entity.position
    local area = {{pos.x - 200, pos.y - 200}, {pos.x + 200, pos.y + 200}}
    local es = c.entity.surface.find_entities_filtered{area = area, name = name, limit = 100}
    if #es == 0 then u.json_response({id = id, error = "Not found"}); return end
    local closest, min = nil, math.huge
    for _, e in ipairs(es) do local d = u.distance(e.position, pos); if d < min then min, closest = d, e end end
    u.json_response({id = id, resource = closest.name, position = {x = math.floor(closest.position.x), y = math.floor(closest.position.y)}, distance = math.floor(min), amount = closest.amount})
  end)
end)
