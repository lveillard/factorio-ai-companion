local u = require("commands.init")

u.register("research_get", function(args)
  u.safe_command(function()
    local id, c = u.find_companion(args.companionId)
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

u.register("research_progress", function(args)
  u.safe_command(function()
    local id, c = u.find_companion(args.companionId)
    if not id then u.not_found(); return end
    local force = c.entity.force
    local tech_name = args.technology ~= "" and args.technology or (force.current_research and force.current_research.name)
    if not tech_name then u.json_response({id = id, researching = nil}); return end
    local tech = force.technologies[tech_name]
    if not tech then u.json_response({id = id, error = "Not found"}); return end
    if tech.researched then u.json_response({id = id, tech = tech_name, done = true}); return end
    local is_cur = force.current_research and force.current_research.name == tech_name
    local prog = is_cur and force.research_progress or 0
    u.json_response({id = id, tech = tech_name, progress = prog, remaining = math.ceil(tech.research_unit_count * (1 - prog))})
  end)
end)

u.register("research_set", function(args)
  u.safe_command(function()
    local id, c = u.find_companion(args.companionId)
    if not id then u.not_found(); return end
    local force = c.entity.force
    local tech = force.technologies[args.technology]
    if not tech then u.json_response({id = id, error = "Not found"}); return end
    if tech.researched then u.json_response({id = id, error = "Already done"}); return end
    for _, p in pairs(tech.prerequisites) do if not p.researched then u.json_response({id = id, error = "Missing: " .. p.name}); return end end
    if force.add_research(args.technology) then u.json_response({id = id, researching = args.technology})
    else u.json_response({id = id, error = "Failed"}) end
  end)
end)
