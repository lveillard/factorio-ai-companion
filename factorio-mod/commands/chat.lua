-- AI Companion v0.7.0 - Chat commands
local u = require("commands.init")

commands.add_command("fac_chat_get", nil, function(cmd)
  u.safe_command(function()
    local filter = cmd.parameter
    local fid = tonumber(filter)
    local orch = filter == "orchestrator"
    local msgs = {}
    for _, m in ipairs(storage.companion_messages) do
      if not m.read then
        local inc = (not filter or filter == "") or (orch and not m.target_companion) or (fid and m.target_companion == fid)
        if inc then
          local o = {player = m.player, message = m.message, tick = m.tick}
          if m.target_companion then o.target_companion = m.target_companion end
          msgs[#msgs + 1] = o; m.read = true
        end
      end
    end
    u.json_response(msgs)
  end)
end)

commands.add_command("fac_chat_say", nil, function(cmd)
  u.safe_command(function()
    local args = u.parse_args("^(%S+)%s+(.+)$", cmd.parameter)
    local id_str, msg = args[1], args[2]
    if not msg then u.error_response("Usage: fac_chat_say <id|0> <msg>"); return end
    if id_str == "0" then
      game.print("[Claude] " .. msg, u.print_color(u.COLORS.orchestrator))
      u.json_response({id = 0, name = "Claude", said = msg}); return
    end
    local id, c = u.find_companion(id_str)
    if not id then u.not_found(); return end
    game.print("[" .. u.get_companion_display(id) .. "] " .. msg, u.print_color(c.color or u.get_companion_color(id)))
    u.json_response({id = id, name = c.name, said = msg})
  end)
end)
