local u = require("commands.init")
local M = {}
local limits = u.settings.blueprints
local entity_schema = require("commands.contract").blueprint_save.inputSchema.properties.entities

-- Script inventories are temporary. Only the native export string is persisted.
function M.with_stack(encoded, callback)
  local inventory = game.create_inventory(1)
  local ok, result = pcall(function()
    local stack = inventory[1]
    if encoded then
      if stack.import_stack(encoded) ~= 0 then u.reject("Blueprint import failed or contains unavailable prototypes") end
    else stack.set_stack{name="blueprint"} end
    if not stack.is_blueprint then u.reject("Expected a single blueprint, not a blueprint book") end
    return callback(stack)
  end)
  inventory.destroy()
  if not ok then error(result) end
  return result
end

function M.validate(stack)
  local entities, tiles = stack.get_blueprint_entities() or {}, stack.get_blueprint_tiles() or {}
  if #entities + #tiles == 0 then u.reject("Blueprint is empty") end
  if #entities + #tiles > entity_schema.maxItems then u.reject("Blueprint exceeds configured entity/tile limit") end
  for _, e in ipairs(entities) do
    local proto = prototypes.entity[e.name]
    if not proto or not proto.items_to_place_this or not proto.items_to_place_this[1] then
      u.reject("Entity cannot be built from an item: " .. e.name)
    end
    if math.abs(e.position.x) > entity_schema.items.properties.x.maximum or math.abs(e.position.y) > entity_schema.items.properties.x.maximum then
      u.reject("Blueprint exceeds configured extent")
    end
  end
  for _, tile in ipairs(tiles) do
    if math.abs(tile.position.x) > entity_schema.items.properties.x.maximum or math.abs(tile.position.y) > entity_schema.items.properties.x.maximum then u.reject("Blueprint exceeds configured extent") end
  end
  return entities, tiles
end

function M.inspect(stack, entity)
  local entities, tiles = M.validate(stack)
  local materials, manual_supported, blockers = {}, true, {}
  for _, e in ipairs(entities) do
    if e.items and next(e.items) then manual_supported = false end
    if e.recipe and (not entity.force.recipes[e.recipe] or not entity.force.recipes[e.recipe].enabled) then
      blockers[#blockers+1] = "Recipe is locked: " .. e.recipe
    end
  end
  for _, item in ipairs(stack.cost_to_build) do
    local have = entity.get_main_inventory().get_item_count{name=item.name,quality=item.quality}
    materials[#materials+1] = {name=item.name, quality=item.quality, count=item.count, carried=have, missing=math.max(0,item.count-have)}
  end
  table.sort(materials,function(a,b) return a.name..a.quality < b.name..b.quality end)
  return {entities=#entities, tiles=#tiles, materials=materials, manual_supported=manual_supported,
    blockers=blockers, manual_reason=not manual_supported and "Blueprint item requests require construction robots" or nil}
end

function M.load(name, callback)
  local plan = storage.blueprints and storage.blueprints[name]
  if not plan then u.reject("Unknown blueprint: " .. name) end
  return M.with_stack(plan,callback)
end

u.register("blueprint_save", function(args)
  u.safe_command(function()
    if (args.blueprint ~= nil) == (args.entities ~= nil) then u.reject("Provide either a blueprint string or entities") end
    storage.blueprints = storage.blueprints or {}
    local count = 0; for _ in pairs(storage.blueprints) do count=count+1 end
    if not storage.blueprints[args.name] and count >= limits.max_plans then u.reject("Blueprint library is full; reuse a plan name") end
    local encoded = M.with_stack(args.blueprint, function(stack)
      if args.entities then
        local entities = {}
        for i,e in ipairs(args.entities) do
          entities[i] = {entity_number=i,name=e.name,position={x=e.x,y=e.y},direction=u.dir_map[e.direction or 0],
            recipe=e.recipe,quality=e.quality or "normal"}
        end
        stack.set_blueprint_entities(entities)
      end
      M.validate(stack)
      stack.label = args.name
      return stack.export_stack()
    end)
    storage.blueprints[args.name] = encoded
    u.json_response({saved=true,name=args.name})
  end)
end)

u.register("blueprint_inspect", function(args)
  u.safe_command(function()
    local id,c = u.find_companion(args.companionId)
    if not id then u.not_found(); return end
    if not args.name then
      local names = {}; for name in pairs(storage.blueprints or {}) do names[#names+1]=name end
      table.sort(names); u.json_response({blueprints=names}); return
    end
    u.json_response(M.load(args.name,function(stack)
      local result = M.inspect(stack,c.entity)
      result.name=args.name
      if args.export then result.blueprint=stack.export_stack() end
      return result
    end))
  end)
end)

return M
