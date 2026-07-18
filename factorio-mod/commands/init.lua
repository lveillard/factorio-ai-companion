-- AI Companion v0.9.0
local M = {}

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
  -- Factorio native 16-direction values (aliases)
  [4] = defines.direction.east,  [8] = defines.direction.south, [12] = defines.direction.west,
}

function M.print_color(c) return {color = c} end

function M.get_companion_color(id)
  return M.COMPANION_COLORS[((id - 1) % #M.COMPANION_COLORS) + 1]
end

-- Same idea as the tick=game.tick trick below, one step further (2026-07-05, Zdendys: RCON
-- is request/response only, a mod can never push a message on its own -- but that just means
-- whichever command Python happens to send next can carry the completion status of OTHER
-- in-flight async jobs for free, instead of needing a DEDICATED status poll for each one).
-- Returns nil (not an empty table) when nothing is in flight -- Lua can't tell an empty table
-- apart from an empty array, so helpers.table_to_json could encode `{}` as JSON `[]`, which a
-- Python `.get("queues", {}).get(...)` would then crash on (list has no .get). Only ever
-- attaching a genuinely non-empty table sidesteps that ambiguity entirely.
function M.companion_queue_status(cid)
  if not cid then return nil end
  local out = nil
  local function mark(name, qs)
    if qs and qs[cid] then
      out = out or {}
      out[name] = true
    end
  end
  mark("walking", storage.walking_queues)
  mark("harvest", storage.harvest_queues)
  mark("gather", storage.gather_queues)
  mark("fuel", storage.fuel_queues)
  mark("craft", storage.craft_queues)
  mark("build", storage.build_queues)
  mark("belt", storage.belt_queues)
  mark("combat", storage.combat_queues)
  -- walk_result (2026-07-16, Zdendys's fast-giveup directive): read-AND-CLEAR --
  -- control.lua's process_walking_queues stashes "approx_arrived"/"unreachable"
  -- here the moment it gives up early on a fac_move_to()-driven walk (see that
  -- function's own giveup_enabled block). Consumed exactly ONCE, by whichever
  -- companion_queue_status(cid) call happens first after the stash is set --
  -- Factorio's single-threaded scripting model makes this safe (no concurrent
  -- callers can race on the same cid) -- so a LATER, unrelated poll never sees a
  -- stale outcome from a walk that already ended. companion.py's wait_arrive()
  -- already polls position (which carries this queues dict for free) every ~0.05s
  -- while blocked on a walk, so it will see this on its very next poll, well
  -- before it could possibly have moved on to any other walk.
  local outcome = storage.walk_last_outcome and storage.walk_last_outcome[cid]
  if outcome then
    storage.walk_last_outcome[cid] = nil
    out = out or {}
    out.walk_result = outcome.result
  end
  return out
end

-- tick=game.tick is injected into EVERY response (unless the caller already set
-- one) so Python-side callers get the current tick for free on any command that
-- already returns JSON, instead of needing a SEPARATE RCON round-trip just to
-- read game.tick (2026-07-04, Zdendys: avoid the redundant query the BC recorder
-- was making after every action).
-- Optional `cid` (2026-07-05): when a caller passes the companion id, ANY response also
-- carries `queues` (which async job types are still in flight for that companion), unless
-- the caller already set data.queues itself. `cid` is a NEW, backward-compatible optional
-- 2nd parameter -- every one of the ~120 existing single-arg call sites still works
-- unchanged (Lua gives an unpassed parameter `nil`, not an arity error).
-- Factorio's helpers.table_to_json serializes every float with FULL round-trip binary
-- precision (2026-07-11, Zdendys live-caught: a position of -34.2 came back as
-- "-34.2000000000000028421709430404007434844970703125") -- confirmed this happens for
-- ANY non-power-of-2 fraction regardless of pre-rounding the Lua number first (a rounded
-- value is still an inexact binary double, so the encoder still prints its exact decimal
-- expansion). The underlying VALUE is correct either way (Python's json.loads parses both
-- forms to the identical float), so this is purely a log/RCON-payload verbosity problem,
-- not a data-correctness one -- but tile-grid positions never need more than a few decimal
-- digits, so cleaning this up is a pure readability win. Scans the ENCODED JSON string
-- char-by-char, tracking quoted-string boundaries (handling backslash-escapes) so a
-- number-looking substring INSIDE a string value (e.g. an error message that embeds
-- "best_d=45.6789012345", or a tile-key string like "-75.5,23.5") is never touched --
-- only reformats genuine bare numeric tokens. Live-tested against exactly these cases
-- before shipping (embedded numbers in error strings, escaped quotes, array-of-strings
-- blacklist responses) to confirm no corruption.
local function clean_json_numbers(raw)
  local out = {}
  local i = 1
  local len = #raw
  while i <= len do
    local c = raw:sub(i, i)
    if c == '"' then
      local j = i + 1
      while j <= len do
        local cj = raw:sub(j, j)
        if cj == '\\' then j = j + 2
        elseif cj == '"' then break
        else j = j + 1 end
      end
      out[#out + 1] = raw:sub(i, j)
      i = j + 1
    else
      local numstr = raw:match('^%-?%d+%.%d+', i)
      if numstr then
        out[#out + 1] = string.format('%.4g', tonumber(numstr))
        i = i + #numstr
      else
        out[#out + 1] = c
        i = i + 1
      end
    end
  end
  return table.concat(out)
end

function M.json_response(data, cid)
  if data.tick == nil then data.tick = game.tick end
  if cid and data.queues == nil then
    local qs = M.companion_queue_status(cid)
    if qs then data.queues = qs end
  end
  local ok, result = pcall(helpers.table_to_json, data)
  if not ok then
    rcon.print('{"error":"JSON failed"}')
    return
  end
  local ok2, cleaned = pcall(clean_json_numbers, result)
  rcon.print(ok2 and cleaned or result)
end

-- Tick-safe logging: appends to the storage.errors ring buffer WITHOUT rcon.print (which is
-- only valid inside an active RCON command context, not from a tick handler like queues.lua).
function M.log_error(msg, ctx)
  storage.errors = storage.errors or {}
  table.insert(storage.errors, {context = ctx or "internal", error = tostring(msg), tick = game.tick})
  if #storage.errors > 50 then table.remove(storage.errors, 1) end
end

-- dump_context (2026-07-12, task #46): shared forensic snapshot for on-failure
-- diagnostics -- consolidates the find_entities_filtered{position,radius} + nearby-name
-- list + get_tile name pattern that queues.lua's collision diagnostic and
-- task_pool.lua's pick_orientation per-candidate diagnostic each hand-rolled separately
-- (see those call sites). Returns a plain TABLE, not a pre-formatted string -- callers
-- still compose their own log_error/error_response message text from these fields,
-- exactly like the two hand-rolled diagnostics did before this refactor.
-- opts (optional): {radius = <number, default 1.5>, companion = <LuaEntity to mark
-- specially in `nearby` via unit_number match>}.
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

function M.parse_args(pattern, args)
  return args and {args:match(pattern)} or {}
end

function M.distance(a, b)
  return math.sqrt((a.x - b.x)^2 + (a.y - b.y)^2)
end

-- Distance-scaled approach/walk deadline: 25 ticks/tile (~3.7x the expected walk speed)
-- so a legitimately long walk is never aborted, but a companion genuinely STUCK on an
-- obstacle (standable != path-reachable) bails fast instead of hanging indefinitely.
-- floor(1800) is the minimum grace for a short/adjacent walk. Extracted 2026-07-15
-- (duplicate-code consolidation pass, Zdendys: "Jak v Py, tak v Modu!") -- this exact
-- formula was hand-copied 9 times across queues.lua/task_pool.lua before this; callers
-- just do `q.approach_deadline = u.approach_deadline(c.entity.position, target_pos)`
-- (or assign the return value to whatever deadline field they use, e.g.
-- step_away_deadline) instead of repeating the math.max/math.floor expression.
function M.approach_deadline(from_pos, to_pos)
  return game.tick + math.max(1800, math.floor(M.distance(from_pos, to_pos) * 25))
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
