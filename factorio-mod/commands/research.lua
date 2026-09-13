-- AI Companion v0.7.0 - Research commands
local u = require("commands.init")

commands.add_command("fac_research_get", nil, function(cmd)
  u.safe_command(function()
    local id, c = u.find_companion(cmd.parameter)
    if not id then u.not_found(); return end
    local force = c.entity.force
    local current = force.current_research and {name = force.current_research.name, progress = force.research_progress} or nil
    local available = {}
    for name, tech in pairs(force.technologies) do
      if not tech.researched and tech.enabled then
        local can = true
        for _, p in pairs(tech.prerequisites) do if not p.researched then can = false; break end end
        if can then
          local ings = {}
          for _, ing in pairs(tech.research_unit_ingredients) do ings[#ings + 1] = ing.name end
          available[#available + 1] = {name = name, units = tech.research_unit_count, ingredients = ings}
        end
      end
    end
    table.sort(available, function(a, b) return a.units < b.units end)
    if #available > 30 then local t = {}; for i = 1, 30 do t[i] = available[i] end; available = t end
    u.json_response({id = id, current = current, available = available, count = #available})
  end)
end)

commands.add_command("fac_research_progress", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)%s*(%S*)$", cmd.parameter)
    local id, c = u.find_companion(args[1])
    if not id then u.not_found(); return end
    local force = c.entity.force
    local tech_name = args[2] ~= "" and args[2] or (force.current_research and force.current_research.name)
    if not tech_name then u.json_response({id = id, researching = nil}); return end
    local tech = force.technologies[tech_name]
    if not tech then u.json_response({id = id, error = "Not found"}); return end
    if tech.researched then u.json_response({id = id, tech = tech_name, done = true}); return end
    local is_cur = force.current_research and force.current_research.name == tech_name
    local prog = is_cur and force.research_progress or 0
    u.json_response({id = id, tech = tech_name, progress = prog, remaining = math.ceil(tech.research_unit_count * (1 - prog))})
  end)
end)

commands.add_command("fac_research_set", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)%s+(%S+)$", cmd.parameter)
    local id, c = u.find_companion(args[1])
    if not id then u.not_found(); return end
    local force = c.entity.force
    local tech = force.technologies[args[2]]
    if not tech then u.json_response({id = id, error = "Not found"}); return end
    if tech.researched then u.json_response({id = id, error = "Already done"}); return end
    for _, p in pairs(tech.prerequisites) do if not p.researched then u.json_response({id = id, error = "Missing: " .. p.name}); return end end
    if force.add_research(args[2]) then u.json_response({id = id, researching = args[2]})
    else u.json_response({id = id, error = "Failed"}) end
  end)
end)
