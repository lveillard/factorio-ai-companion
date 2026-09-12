local u = require("commands.init")

u.register("chat_say", function(args)
  u.safe_command(function()
    local id_str, msg = args.companionId, args.message
    if not msg then u.error_response("Usage: fac_chat_say <id|0> <msg>"); return end
    if id_str == 0 then
      game.print("[Codex] " .. msg, u.print_color(u.COLORS.orchestrator))
      u.json_response({id = 0, name = "Codex", said = msg}); return
    end
    local id, c = u.find_companion(id_str)
    if not id then u.not_found(); return end
    game.print("[" .. u.get_companion_display(id) .. "] " .. msg, u.print_color(c.color or u.get_companion_color(id)))
    u.json_response({id = id, name = c.name, said = msg})
  end)
end)
