defines = {direction={north=0,east=4,south=8,west=12}, inventory={character_main=1}, shooting={not_shooting=0}}
-- Fengari's Lua 5.3 atan(y, x) supplies Factorio's Lua 5.2 atan2.
math.atan2 = math.atan
storage = {companions={}, walking_queues={}, tasks={}, reserved={}, active_step={}, path_requests={}, errors={}}
game = {tick=0, print=function() end, forces={}, surfaces={}}
prototypes = {recipe={gear={energy=0.5}}, entity={}}
items = {plate=20}
local inventory = {valid=true}
inventory.get_item_count = function(name)
  if name then return items[name] or 0 end
  local total=0; for _, count in pairs(items) do total=total+count end; return total
end
inventory.get_contents = function()
  local result={}; for name,count in pairs(items) do result[#result+1]={name=name,count=count,quality="normal"} end; return result
end
entity = {valid=true, position={x=0,y=0}, crafting_queue={}, crafting_queue_size=0,
  crafting_queue_progress=0, mining_state={mining=false}, walking_state={walking=false},
  force={recipes={}, technologies={}}, surface={}}
entity.get_main_inventory = function() return inventory end
entity.get_inventory = function() return inventory end
entity.get_craftable_count = function() return math.floor(items.plate/2) end
entity.begin_crafting = function(args)
  local count=math.min(args.count, entity.get_craftable_count())
  items.plate=items.plate-count*2
  if count>0 then
    entity.crafting_queue[#entity.crafting_queue+1]={recipe=args.recipe,count=count,index=#entity.crafting_queue+1}
    entity.crafting_queue_size=#entity.crafting_queue
  end
  return count
end
entity.cancel_crafting = function(args)
  local job=entity.crafting_queue[args.index]
  local count=math.min(args.count,job.count)
  items.plate=items.plate+count*2; job.count=job.count-count
  if job.count==0 then table.remove(entity.crafting_queue,args.index) end
  entity.crafting_queue_size=#entity.crafting_queue
  entity.crafting_queue_progress=0
end
storage.companions[1]={entity=entity,name="Atlas"}
u = require("commands.init")
u.fire_craft_triggers = function() end
queues = require("commands.queues")
queues.init()
function advance(ticks)
  for _=1,ticks do
    game.tick=game.tick+1
    local native=entity.crafting_queue[1]
    if native then
      entity.crafting_queue_progress=entity.crafting_queue_progress+1/60
      if entity.crafting_queue_progress>=0.9999 then
        items.gear=(items.gear or 0)+1
        native.count=native.count-1
        if native.count==0 then table.remove(entity.crafting_queue,1) end
        entity.crafting_queue_size=#entity.crafting_queue
        entity.crafting_queue_progress=0
      end
    end
    if game.tick%5==0 then queues.tick_craft_queues() end
  end
end
