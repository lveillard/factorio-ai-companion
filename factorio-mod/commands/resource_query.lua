local u = require("commands.init")
local M = {}

-- A requested product may come from several entity prototypes (wood from trees).
function M.resolve(name)
  local alias = u.settings.resources.aliases[name]
  if alias then return {type=alias.type,product=alias.product,hand_mineable=true} end
  local proto = prototypes.entity[name]
  if not proto or (proto.type ~= "resource" and proto.type ~= "tree") then
    return nil, "Unknown gatherable resource: " .. tostring(name)
  end
  local mp = proto.mineable_properties
  for _, product in ipairs(mp and mp.products or {}) do
    return {name=name,type=proto.type,product=product.name,hand_mineable=product.type=="item" and not mp.required_fluid}
  end
  return nil, "Resource has no hand-mineable item product: " .. name
end

function M.available(entity, selector)
  if not entity.valid or entity.minable == false or (entity.type == "resource" and entity.amount <= 0) then return false end
  local mp = entity.prototype.mineable_properties
  if not mp or (selector.hand_only and mp.required_fluid) then return false end
  for _, product in ipairs(mp.products or {}) do
    if (not selector.hand_only or product.type=="item") and (not selector.product or product.name == selector.product) then return true end
  end
  return false
end

function M.within(surface, origin, selector, radius, accept)
  local found = {}
  for _, entity in ipairs(surface.find_entities_filtered{
    name=selector.name, type=selector.type, position=origin, radius=radius}) do
    if M.available(entity, selector) and (not accept or accept(entity)) then found[#found+1] = entity end
  end
  table.sort(found, function(a,b)
    local da, db = u.distance(origin,a.position), u.distance(origin,b.position)
    if da ~= db then return da < db end
    if a.position.x ~= b.position.x then return a.position.x < b.position.x end
    return a.position.y < b.position.y
  end)
  return found
end

-- Expand the search only when needed. Never truncate before sorting/filtering.
function M.nearest(surface, origin, selector, maximum, accept)
  local radius = math.min(u.settings.resources.initial_radius, maximum)
  while true do
    local found = M.within(surface, origin, selector, radius, accept)
    if found[1] then return found[1] end
    if radius >= maximum then return nil end
    radius = math.min(radius * 2, maximum)
  end
end

function M.describe(entity, origin, product)
  local selector = M.resolve(entity.name)
  return {name=entity.name, resource=product or entity.name, position={x=entity.position.x,y=entity.position.y},
    amount=entity.type == "resource" and entity.amount or nil, distance=u.distance(origin,entity.position),
    hand_mineable=selector and selector.hand_mineable or false}
end

return M
