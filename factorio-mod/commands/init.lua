local settings = require("commands.settings")
local M = {handlers = {}, settings = settings}
function M.register(name, handler)
  if M.handlers[name] then error("Duplicate handler: " .. name) end
  M.handlers[name] = handler
end

M.COLORS = {
  player = {r=0.4, g=0.8, b=1},
  orchestrator = {r=0.3, g=1, b=0.3},
  system = {r=1, g=0.5, b=0},
  error = {r=1, g=0, b=0}
}

M.COMPANION_COLORS = {
  {r=1, g=0.6, b=0.2}, {r=0.8, g=0.4, b=1}, {r=1, g=1, b=0.3}, {r=0.4, g=1, b=0.8},
  {r=1, g=0.4, b=0.6}, {r=0.6, g=0.8, b=1}, {r=1, g=0.8, b=0.4}, {r=0.7, g=1, b=0.5}
}

M.dir_map = {
  -- Simple 0-3 convention (MCP tools API)
  [0] = defines.direction.north, [1] = defines.direction.east,
  [2] = defines.direction.south, [3] = defines.direction.west,
}

function M.print_color(c) return {color = c} end

function M.inventory_contents(inv)
  if not inv or not inv.valid then return {} end
  local result = inv.get_contents()
  table.sort(result, function(a, b) return a.name < b.name end)
  return result
end

function M.cancel_native_crafting(entity)
  -- Cancelling an earlier craft can remove later dependent crafts too.
  local crafts = entity.crafting_queue or {}
  for index = #crafts, 1, -1 do
    entity.cancel_crafting{index=index, count=crafts[index].count}
  end
end

function M.get_companion_color(id)
  return M.COMPANION_COLORS[((id - 1) % #M.COMPANION_COLORS) + 1]
end

function M.companion_queue_status(cid)
  if not cid then return nil end
  local out = nil
  local function mark(name, qs)
    if qs and qs[cid] then
      out = out or {}
      out[name] = true
    end
  end
  for _, name in ipairs(settings.queues) do mark(name, storage[name .. "_queues"]) end
  local outcome = storage.walk_last_outcome and storage.walk_last_outcome[cid]
  if outcome then
    out = out or {}
    out.walk_result = outcome.result
  end
  return out
end

function M.json_response(data, cid, is_array)
  if not is_array and data.tick == nil then data.tick = game.tick end
  if cid and data.queues == nil then data.queues = M.companion_queue_status(cid) end
  if is_array and next(data) == nil then rcon.print("[]"); return end
  local ok, result = pcall(helpers.table_to_json, data)
  rcon.print(ok and result or '{"error":"JSON failed"}')
end

-- Tick-safe logging: appends to the storage.errors ring buffer WITHOUT rcon.print (which is
-- only valid inside an active RCON command context, not from a tick handler like queues.lua).
function M.log_error(msg, ctx)
  storage.errors = storage.errors or {}
  table.insert(storage.errors, {context = ctx or "internal", error = tostring(msg), tick = game.tick})
  if #storage.errors > settings.retention.errors then table.remove(storage.errors, 1) end
end

function M.dump_context(surf, position, opts)
  opts = opts or {}
  local radius = opts.radius or 1.5
  local near = surf.find_entities_filtered{position = position, radius = radius}
  local nearby = {}
  for _, e in ipairs(near) do
    local mark = (opts.companion and e.unit_number == opts.companion.unit_number) and "(COMPANION)" or ""
    nearby[#nearby + 1] = e.name .. mark
  end
  local tile = surf.get_tile(math.floor(position.x), math.floor(position.y))
  return {
    tile = tile and tile.name or "?",
    nearby = nearby,
    companion_pos = opts.companion and opts.companion.position or nil,
  }
end

function M.error_response(msg, ctx)
  M.log_error(msg, ctx)
  -- Routed through json_response (not a hand-built string) so error replies ALSO
  -- get tick=game.tick for free, AND so a quote/backslash inside msg gets properly
  -- JSON-escaped instead of producing invalid JSON that json.loads() would choke on.
  M.json_response({error = tostring(msg)})
end

function M.safe_command(callback)
  local ok, err = pcall(callback)
  if not ok then
    M.error_response(err)
  end
end

function M.get_companion(id)
  local c = storage.companions[id]
  if c and c.entity and c.entity.valid then return c end
  -- Record exists but the character entity is gone => the companion DIED (e.g. biters).
  -- Remember that so EVERY subsequent request can report it as dead instead of a vague
  -- "not found", letting the orchestrator/recorder react (discard/respawn) immediately.
  if c then
    storage.dead_companions = storage.dead_companions or {}
    storage.dead_companions[id] = game.tick
  end
  return nil
end

-- Death-aware failure response: if the requested (or any known) companion has died, say so
-- explicitly on EVERY request; otherwise fall back to the generic not-found message.
function M.not_found(identifier)
  local dc = storage.dead_companions or {}
  local id = tonumber(identifier)
  if id and dc[id] then
    M.error_response("companion #" .. id .. " is dead", "dead")
  elseif next(dc) then
    local ids = {}
    for k in pairs(dc) do ids[#ids + 1] = "#" .. k end
    M.error_response("companion " .. table.concat(ids, ",") .. " is dead", "dead")
  else
    M.error_response("Companion not found")
  end
end

function M.find_companion(identifier)
  if identifier == nil then return nil, nil end
  identifier = tostring(identifier)
  local id = tonumber(identifier)
  if id then
    local c = M.get_companion(id)
    if c then return id, c end
  end
  for cid, c in pairs(storage.companions) do
    if c.name and c.name:lower() == identifier:lower() and c.entity and c.entity.valid then
      return cid, c
    end
  end
  return nil, nil
end

function M.get_companion_display(id)
  local c = storage.companions[id]
  return c and c.name and (c.name .. "(#" .. id .. ")") or ("#" .. id)
end

function M.distance(a, b)
  return math.sqrt((a.x - b.x)^2 + (a.y - b.y)^2)
end

function M.approach_deadline(from_pos, to_pos)
  return game.tick + math.max(settings.walking.min_deadline_ticks, math.floor(M.distance(from_pos, to_pos) * settings.walking.deadline_ticks_per_tile))
end

function M.get_direction(from, to)
  local dx, dy = to.x - from.x, to.y - from.y
  if math.abs(dx) < 0.5 and math.abs(dy) < 0.5 then return nil end
  local deg = math.atan2(dy, dx) * 180 / math.pi
  if deg < 0 then deg = deg + 360 end
  local dirs = {
    {337.5, 22.5, defines.direction.east}, {22.5, 67.5, defines.direction.southeast},
    {67.5, 112.5, defines.direction.south}, {112.5, 157.5, defines.direction.southwest},
    {157.5, 202.5, defines.direction.west}, {202.5, 247.5, defines.direction.northwest},
    {247.5, 292.5, defines.direction.north}, {292.5, 337.5, defines.direction.northeast}
  }
  for _, d in ipairs(dirs) do
    if d[1] > d[2] then
      if deg >= d[1] or deg < d[2] then return d[3] end
    elseif deg >= d[1] and deg < d[2] then return d[3] end
  end
  return defines.direction.east
end

function M.render_label(entity, text, color)
  if not rendering then return nil end
  return rendering.draw_text{
    text = text, surface = entity.surface, target = entity,
    target_offset = {0, -2.5}, color = color, scale = 1.5, alignment = "center", use_rich_text = false
  }
end

-- Factorio 2.0 "craft-item" research triggers fire only when a PLAYER completes a
-- craft; a headless scripted companion's begin_crafting does NOT fire them, so a
-- crafted item that should unlock a technology (e.g. crafting a lab unlocks the
-- automation-science-pack recipe) leaves the tech enabled-but-unresearched. This
-- compensates: after the companion REALLY crafts an item (ingredients consumed via
-- begin_crafting), research any matching craft-item trigger tech whose prereqs are
-- met. NOT a cheat -- the item was genuinely produced through game mechanics; this
-- only replicates the craft event a connected player would have generated. Items
-- producible by machines (plates from furnaces) already fire their triggers normally.
function M.fire_craft_triggers(force, item_name, crafted)
  if not item_name or (crafted or 0) < 1 then return end
  for _, tech in pairs(force.technologies) do
    if tech.enabled and not tech.researched then
      local rt = tech.prototype.research_trigger
      if rt and rt.type == "craft-item" then
        local rname = type(rt.item) == "table" and (rt.item.name or rt.item[1]) or rt.item
        if rname == item_name then
          -- Only THIS hand-craft counts. Do NOT read item_production_statistics: that is CUMULATIVE
          -- MACHINE output (plates from furnaces, etc.) and would complete a craft-item trigger from
          -- production the player never hand-crafted = a cheat. Machine-produced trigger items already
          -- fire their triggers via the engine; this path only replicates the on_player_crafted_item
          -- trigger the engine skips for a SCRIPTED companion craft.
          if (crafted or 0) >= (rt.count or 1) then
            tech.researched = true
            game.print("[companion] crafted " .. item_name ..
              " -> trigger tech researched: " .. tech.name, M.print_color(M.COLORS.system))
          end
        end
      end
    end
  end
end

return M
