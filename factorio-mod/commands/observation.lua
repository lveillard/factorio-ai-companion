local u = require("commands.init")
local entity_info = require("commands.entity_info")
local M = {}
local limits = u.settings.observation

local function position(p) return {x = p.x, y = p.y} end
local contents = u.inventory_contents

function M.session_id()
  if not storage.bridge_session_id then
    storage.bridge_session_id = tostring(game.tick) .. ":" .. tostring(math.random(1, 2147483647))
  end
  return storage.bridge_session_id
end

local function queues(cid)
  local result = {}
  for _, name in ipairs(u.settings.queues) do
    local q = storage[name .. "_queues"] and storage[name .. "_queues"][cid]
    if q then
      result[name] = {active = q.state ~= "done" and not q.done and not q.failed,
        state = q.state, target = type(q.target) == "number" and q.target or nil,
        harvested = q.harvested, gathered = q.gathered, crafted = q.crafted,
        recipe = q.recipe, resource = q.resource, error = q.error, failed = q.failed}
    end
  end
  return result
end

local function last_jobs(cid)
  local result = {}
  for _, name in ipairs(u.settings.queues) do
    local q = storage.queue_results and storage.queue_results[name .. "_queues"] and storage.queue_results[name .. "_queues"][cid]
    if q then result[name] = {state=q.state, error=q.error, finished_tick=q.finished_tick, run_start_tick=q.run_start_tick, run_end_tick=q.run_end_tick,
      gathered=q.gathered, crafted=q.crafted, harvested=q.harvested, resource=q.resource, recipe=q.recipe} end
  end
  return result
end

u.register("world_observe", function(args)
  u.safe_command(function()
    local cid, radius = tonumber(args.companionId) or 0, tonumber(args.radius) or 48
    radius = math.min(96, math.max(8, radius))
    local companion = cid > 0 and u.get_companion(cid) or nil
    if cid > 0 and not companion then u.not_found(cid); return end
    local player = game.connected_players[1] or game.players[1]
    local surface = companion and companion.entity.surface or (player and player.surface) or game.surfaces[1]
    local force = companion and companion.entity.force or (player and player.force) or game.forces.player
    local center = companion and companion.entity.position or (player and player.position) or force.get_spawn_position(surface)
    local result = {version = script.active_mods["ai-companion"], factorio = script.active_mods.base,
      session_id = M.session_id(), tick = game.tick, paused = game.tick_paused,
      surface = surface.name, center = position(center), radius = radius,
      daylight = 1 - surface.darkness, pollution = surface.get_pollution(center),
      players = {}, companions = {}, entities = {}, water = {}, errors = {}, tasks = {},
      limits = {entities = limits.entities, detailed_machines = limits.detailed_machines, water = limits.water, vision_radius = limits.vision_radius, charted_or_nearby = true}}
    for _, p in pairs(game.players) do
      if p.valid then result.players[#result.players + 1] = {name = p.name, connected = p.connected,
        position = position(p.position), surface = p.surface.name, health = p.character and p.character.health} end
    end
    for id, c in pairs(storage.companions or {}) do
      if c.entity and c.entity.valid then
        result.companions[#result.companions + 1] = {id = id, name = c.name, surface = c.entity.surface.name,
          position = position(c.entity.position), health = c.entity.health, max_health = c.entity.max_health,
          inventory = contents(c.entity.get_main_inventory()), queues = queues(id), last_jobs = last_jobs(id)}
      else result.companions[#result.companions + 1] = {id = id, name = c.name, dead = true} end
    end
    table.sort(result.companions, function(a, b) return a.id < b.id end)
    for id, task in pairs(storage.tasks or {}) do
      if task.status == "active" and #result.tasks < limits.tasks then
        result.tasks[#result.tasks + 1] = {id = id, companionId = task.cid, status = task.status,
          step = task.cursor, total = #task.steps, needs = task.needs}
      end
    end
    local research = force.current_research
    result.research = research and {name = research.name, progress = force.research_progress} or nil
    local entities = surface.find_entities_filtered{position = center, radius = radius}
    local visible = {}
    local function charted(pos)
      return ((companion or player) and u.distance(pos, center) <= limits.vision_radius) or force.is_chunk_charted(surface, {x = math.floor(pos.x / 32), y = math.floor(pos.y / 32)})
    end
    for _, e in ipairs(entities) do
      if e.valid and charted(e.position) and e.type ~= "particle" and e.type ~= "corpse" then visible[#visible + 1] = e end
    end
    -- Show machines/enemies before dense ore tiles so a resource patch cannot hide the factory.
    local function priority(e) return e.type == "resource" and 2 or e.type == "tree" and 3 or 1 end
    table.sort(visible, function(a, b)
      if priority(a) ~= priority(b) then return priority(a) < priority(b) end
      return u.distance(a.position, center) < u.distance(b.position, center)
    end)
    local detail = 0
    for i = 1, math.min(limits.entities, #visible) do
      local e = visible[i]
      local detailed = e.force == force and e.type ~= "character" and detail < limits.detailed_machines
      local ok, data = pcall(entity_info.describe, e, detailed)
      if ok then result.entities[#result.entities + 1] = data; if detailed then detail = detail + 1 end
      else result.errors[#result.errors + 1] = {context = "observation:" .. e.name, error = tostring(data), tick = game.tick} end
    end
    result.entities_total = #visible
    result.entities_truncated = #visible > limits.entities
    for _, tile in ipairs(surface.find_tiles_filtered{position = center, radius = radius, collision_mask = "water_tile", limit = limits.water + 1}) do
      if charted(tile.position) and #result.water < limits.water then result.water[#result.water + 1] = position(tile.position) end
    end
    result.water_truncated = #result.water >= limits.water
    for i = math.max(1, #(storage.errors or {}) - limits.errors + 1), #(storage.errors or {}) do result.errors[#result.errors + 1] = storage.errors[i] end
    u.json_response(result)
  end)
end)

u.register("chat_poll", function(args)
  u.safe_command(function()
    local after = tonumber(args.afterId) or 0
    storage.bridge_message_id = storage.bridge_message_id or 0
    local messages = {}
    for _, message in ipairs(storage.companion_messages or {}) do
      if not message.bridge_id then
        storage.bridge_message_id = storage.bridge_message_id + 1
        message.bridge_id = storage.bridge_message_id
      end
      if message.bridge_id > after then
        messages[#messages + 1] = {id = message.bridge_id, player = message.player, message = message.message,
          tick = message.tick, companionId = message.target_companion or 0, spawn_request = message.spawn_request}
      end
    end
    u.json_response({session_id = M.session_id(), cursor = storage.bridge_message_id, messages = messages})
  end)
end)

return M
