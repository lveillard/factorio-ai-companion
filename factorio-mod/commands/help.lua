-- AI Companion - Help
local u = require("commands.init")

-- Version command
commands.add_command("fac_version", nil, function()
  local version = script.active_mods["ai-companion"] or "unknown"
  u.json_response({version = version, factorio = script.active_mods["base"] or "unknown"})
  game.print("[AI Companion] v" .. version, u.print_color(u.COLORS.system))
end)

-- Surfaces the storage.errors ring buffer (populated by u.error_response on every
-- pcall-caught command failure, capped at 50 entries) so a Python caller can inspect
-- what silently failed instead of it just accumulating unread ([[feedback_log_every_silent_failure]]).
commands.add_command("fac_get_errors", nil, function()
  u.json_response({errors = storage.errors or {}})
end)

commands.add_command("fac_help", nil, function()
  local version = script.active_mods["ai-companion"] or "unknown"
  u.json_response({
    version = version,
    commands = 50,
    categories = {"action", "building", "chat", "companion", "context", "item", "move", "research", "resource", "world"},
    action = {"attack", "flee", "patrol", "wololo"},
    building = {"can_place", "empty", "fill", "fuel", "info", "place", "recipe", "remove", "rotate"},
    chat = {"get", "say"},
    companion = {"disappear", "health", "inventory", "position", "spawn"},
    context = {"clear", "check"},
    item = {"craft", "pick", "recipes"},
    move = {"follow", "stop", "to"},
    research = {"get", "progress", "set"},
    resource = {"list", "mine", "nearest"},
    world = {"nearest", "scan"},
    player = {"/fac <msg>", "/fac <id> <msg>", "/fac spawn", "/fac list", "/fac kill", "/fac clear", "/fac name"}
  })
end)
