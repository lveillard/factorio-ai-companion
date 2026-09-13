-- AI Companion v0.9.0 - Resource commands
local u = require("commands.init")
local queues = require("commands.queues")

local normalize = {copper = "copper-ore", iron = "iron-ore", coal = "coal", stone = "stone", uranium = "uranium-ore", oil = "crude-oil"}

commands.add_command("fac_resource_list", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)%s*(%S*)%s*(%d*)$", cmd.parameter)
    local id, c = u.find_companion(args[1])
    if not id then u.not_found(); return end
    local filter = args[2] ~= "" and args[2] or nil
    local radius = tonumber(args[3]) or 50
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

-- Realistic mining using tick-based queue system
-- Usage: /fac_resource_mine <id> <x> <y> [count] [resource_name]
-- resource_name is optional - if provided, only mines that specific resource type
commands.add_command("fac_resource_mine", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)%s+(%-?%d+%.?%d*)%s+(%-?%d+%.?%d*)%s*(%d*)%s*(%S*)$", cmd.parameter)
    local id, c = u.find_companion(args[1])
    if not id then u.not_found(); return end
    local x, y, count = tonumber(args[2]), tonumber(args[3]), tonumber(args[4]) or 1
    local resource_name = args[5] ~= "" and args[5] or nil
    -- Normalize common resource names
    if resource_name then
      resource_name = normalize[resource_name] or resource_name
    end
    if not x or not y then u.error_response("Invalid coordinates"); return end
    local tpos = {x = x, y = y}
    if u.distance(c.entity.position, tpos) > 5 then u.json_response({id = id, error = "Too far"}); return end
    -- Start realistic mining via queue system (with optional resource filter)
    local result = queues.start_harvest(id, tpos, count, resource_name)
    if result then
      u.json_response({id = id, mining = true, target = count, entities = result.entities or 0, resource = resource_name, status = "started"})
    else
      u.json_response({id = id, error = "Failed to start mining"})
    end
  end)
end)

-- Check mining status
commands.add_command("fac_resource_mine_status", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)$", cmd.parameter)
    local id = u.find_companion(args[1])
    if not id then u.not_found(); return end
    local status = queues.get_harvest_status(id)
    -- `id` passed as 2nd arg (2026-07-05): same free-status-attachment as
    -- fac_companion_position -- wait_mine()'s existing poll now also surfaces any OTHER
    -- in-flight job for this companion (e.g. a build queued right after mining started).
    u.json_response({id = id, status = status}, id)
  end)
end)

-- Stop mining
commands.add_command("fac_resource_mine_stop", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)$", cmd.parameter)
    local id = u.find_companion(args[1])
    if not id then u.not_found(); return end
    local result = queues.stop_harvest(id)
    u.json_response({id = id, stopped = result.stopped, harvested = result.harvested or 0})
  end)
end)

-- AUTONOMOUS gather: the mod itself finds the nearest REACHABLE + SAFE patch, walks the companion
-- there, and mines to `count` (native 1-unit mining), moving to the next patch as tiles deplete.
-- Replaces the Python find_nearest + go_to + start_harvest + poll glue -- "what the mod can do itself".
-- Usage: /fac_gather <id> <resource> <count> [exclude]  ; poll /fac_gather_status <id>
-- exclude (2026-07-07, optional 4th arg): "x1:y1,x2:y2,..." -- positions the CALLER already
-- knows are unreachable/exhausted (e.g. spatial_bc.py's persistent per-resource
-- resource_exclude, accumulated across the whole episode) -- skipped from the very first
-- patch search instead of being silently re-discovered.
commands.add_command("fac_gather", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)%s+(%S+)%s+(%d+)%s*(%S*)$", cmd.parameter)
    local id, c = u.find_companion(args[1])
    if not id then u.not_found(); return end
    local resource = args[2] and (normalize[args[2]] or args[2]) or nil
    local count = tonumber(args[3])
    if not resource or not count then u.error_response("Usage: fac_gather <id> <resource> <count> [exclude]"); return end
    local exclude = nil
    if args[4] and args[4] ~= "" then
      exclude = {}
      for pair in args[4]:gmatch("[^,]+") do
        local ex, ey = pair:match("^(%-?%d+):(%-?%d+)$")
        if ex and ey then exclude[#exclude + 1] = {x = tonumber(ex), y = tonumber(ey)} end
      end
    end
    local result = queues.start_gather(id, resource, count, exclude)
    if result.error then u.json_response({id = id, error = result.error})
    else u.json_response({id = id, gathering = true, resource = resource, target = count}) end
  end)
end)

commands.add_command("fac_gather_status", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)$", cmd.parameter)
    local id = u.find_companion(args[1])
    if not id then u.not_found(); return end
    -- id passed as 2nd arg (2026-07-05): free queue-status attachment, see init.lua.
    u.json_response({id = id, status = queues.get_gather_status(id)}, id)
  end)
end)

-- FAC_FUEL_GROUP: autonomous "walk to each burner in range and top up its fuel" composite.
-- Replaces the Python go_to + fuel + poll loop over a hardcoded machine list ("what the mod can do
-- itself"). Consumes REAL coal from the companion inventory (native insert, no cheat).
-- Usage: /fac_fuel_group <id> [per] [radius]  ; poll /fac_fuel_group_status <id>
commands.add_command("fac_fuel_group", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)%s*(%d*)%s*(%d*)$", cmd.parameter)
    local id, c = u.find_companion(args[1])
    if not id then u.not_found(); return end
    local per = tonumber(args[2]) or 20
    local radius = tonumber(args[3]) or 200
    local result = queues.start_fuel_group(id, per, radius)
    if result.error then u.json_response({id = id, error = result.error})
    else u.json_response({id = id, fueling = true, per = per, radius = radius}) end
  end)
end)

commands.add_command("fac_fuel_group_status", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)$", cmd.parameter)
    local id = u.find_companion(args[1])
    if not id then u.not_found(); return end
    -- id passed as 2nd arg (2026-07-05): free queue-status attachment, see init.lua.
    u.json_response({id = id, status = queues.get_fuel_status(id)}, id)
  end)
end)

-- DIAGNOSTIC (2026-07-11, Mode A/B gather-select-fail investigation -- see queues.lua's
-- MINE_DIAG_CAP comment for the full mechanism/scope and current findings). Returns the
-- per-cycle "approach" (walking) + "mine" state trace recorded since the companion last
-- started walking toward a candidate resource tile (extended same day to also cover the
-- walking phase, see queues.lua's EXTENSION comment). Kept deliberately (not removed) --
-- the investigation is still open and will likely need this again; see queues.lua's
-- comment before removing.
commands.add_command("fac_mine_diag", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)$", cmd.parameter)
    local id = u.find_companion(args[1])
    if not id then u.not_found(); return end
    u.json_response({id = id, samples = queues.get_mine_diag(id)})
  end)
end)

commands.add_command("fac_resource_nearest", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)%s+(%S+)$", cmd.parameter)
    local id, c = u.find_companion(args[1])
    if not id then u.not_found(); return end
    local name = normalize[args[2]] or args[2]
    local pos = c.entity.position
    local area = {{pos.x - 200, pos.y - 200}, {pos.x + 200, pos.y + 200}}
    local es = c.entity.surface.find_entities_filtered{area = area, name = name, limit = 100}
    if #es == 0 then u.json_response({id = id, error = "Not found"}); return end
    local closest, min = nil, math.huge
    for _, e in ipairs(es) do local d = u.distance(e.position, pos); if d < min then min, closest = d, e end end
    u.json_response({id = id, resource = closest.name, position = {x = math.floor(closest.position.x), y = math.floor(closest.position.y)}, distance = math.floor(min), amount = closest.amount})
  end)
end)
