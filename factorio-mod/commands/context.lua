-- AI Companion v0.7.0 - Context commands
local u = require("commands.init")

commands.add_command("fac_context_clear", nil, function(cmd)
  u.safe_command(function()
    local param = cmd.parameter or "all"
    storage.context_clear_requests = storage.context_clear_requests or {}
    if param == "all" then
      local count = #storage.companion_messages
      storage.companion_messages = {}
      local cleared = {}
      for cid in pairs(storage.companions) do
        storage.context_clear_requests[cid] = game.tick
        cleared[#cleared + 1] = cid
      end
      u.json_response({cleared = "all", messages = count, companions = cleared})
    else
      local id, c = u.find_companion(param)
      if not id then u.not_found(); return end
      local new, count = {}, 0
      for _, m in ipairs(storage.companion_messages) do
        if m.target_companion ~= id then new[#new + 1] = m else count = count + 1 end
      end
      storage.companion_messages = new
      storage.context_clear_requests[id] = game.tick
      u.json_response({cleared = id, messages = count})
    end
  end)
end)

commands.add_command("fac_context_check", nil, function(cmd)
  u.safe_command(function()
    storage.context_clear_requests = storage.context_clear_requests or {}
    local pending = {}
    for id, tick in pairs(storage.context_clear_requests) do pending[#pending + 1] = {id = id, tick = tick} end
    storage.context_clear_requests = {}
    u.json_response({pending = pending, count = #pending})
  end)
end)
