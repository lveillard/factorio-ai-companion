local u = require("commands.init")
local core = require("commands.queues_core")
local plans = require("commands.blueprint_plan")
local capabilities = require("commands.capabilities")
local M = {}
local limits = u.settings.blueprints

local function cleanup(q)
  for _, target in ipairs(q.targets or {}) do
    if target.ghost and target.ghost.valid then target.ghost.destroy() end
  end
end
core.register_cleanup("blueprint_queues",cleanup)

local function built(target, entity)
  if target.tile then return entity.surface.get_tile(target.position).name == target.name end
  for _, e in ipairs(entity.surface.find_entities_filtered{name=target.name,position=target.position,radius=0.1,force=entity.force}) do
    if e.valid and e.quality.name==target.quality then
      local proxies=entity.surface.find_entities_filtered{type="item-request-proxy",position=target.position,radius=0.1,force=entity.force}
      if #proxies > 0 then return false end
      return true
    end
  end
  return false
end

function M.get_blueprint_status(cid)
  local q=storage.blueprint_queues[cid] or core.previous("blueprint_queues",cid)
  if not q then return {active=false} end
  return {active=not q._finished,name=q.name,state=q.state,error=q.error,mode=q.mode,
    built=q.built,total=#q.targets,waiting=q.waiting,run_start_tick=q.run_start_tick,run_end_tick=q.run_end_tick}
end

u.register("blueprint_status",function(args)
  u.safe_command(function() u.json_response({status=M.get_blueprint_status(args.companionId)}) end)
end)

u.register("blueprint_build",function(args)
  u.safe_command(function()
    local id,c=u.find_companion(args.companionId)
    if not id then u.not_found();return end
    local q=plans.load(args.name,function(stack)
      local info=plans.inspect(stack,c.entity)
      if #info.blockers>0 then u.reject(table.concat(info.blockers,"; ")) end
      local targets={}
      local job={name=args.name,targets=targets,state="building",built=0,mode=args.mode,
        manages_timeout=true,run_start_tick=game.tick,progress_tick=game.tick}
      local ok,err=pcall(function()
        -- Never take ownership of ghosts belonging to another construction job.
        local entities,tiles=plans.validate(stack)
        local radius=4
        for _,e in ipairs(entities) do radius=math.max(radius,math.abs(e.position.x)+4,math.abs(e.position.y)+4) end
        for _,e in ipairs(tiles) do radius=math.max(radius,math.abs(e.position.x)+4,math.abs(e.position.y)+4) end
        if c.entity.surface.count_entities_filtered{type={"entity-ghost","tile-ghost"},position={args.x,args.y},radius=radius*2}>0 then
          u.reject("Existing ghosts overlap the blueprint area; finish or clear them first")
        end
        local ghosts=stack.build_blueprint{surface=c.entity.surface,force=c.entity.force,
          position={args.x,args.y},direction=u.dir_map[args.direction],build_mode=defines.build_mode.normal,skip_fog_of_war=false}
        local robots=true
        for _,ghost in ipairs(ghosts) do
          if ghost.valid then
            local target={ghost=ghost,name=ghost.ghost_name,quality=ghost.quality.name,
              position={x=ghost.position.x,y=ghost.position.y},tile=ghost.type=="tile-ghost"}
            targets[#targets+1]=target
            if capabilities.robots(c.entity,target.position).total==0 then robots=false end
          end
        end
        if #targets ~= info.entities+info.tiles then u.reject("Blueprint placement is obstructed or overlaps existing entities; choose a clear site") end
        if job.mode=="auto" then job.mode=robots and "robots" or "manual" end
        if job.mode=="robots" and not robots then u.reject("Construction robots do not cover every blueprint position") end
        if job.mode=="manual" then
          if not info.manual_supported then u.reject(info.manual_reason) end
          for _,item in ipairs(info.materials) do
            if item.missing>0 then u.reject("Missing " .. item.missing .. " " .. item.quality .. " " .. item.name) end
          end
        end
      end)
      if not ok then cleanup(job); error(err) end
      return job
    end)
    storage.blueprint_queues[id]=q
    u.json_response({started=true,status=M.get_blueprint_status(id)})
  end)
end)

function M.tick_blueprint_queues()
  core.process_queue("blueprint_queues",function(cid,q,c)
    local entity=c.entity
    q.waiting=nil
    local pending
    local completed=0
    for _,target in ipairs(q.targets) do
      if target.done then completed=completed+1
      elseif not target.ghost.valid then
        if built(target,entity) then target.done=true;completed=completed+1
        else pending=pending or target end
      else pending=pending or target end
    end
    if completed>q.built then q.progress_tick=game.tick end
    q.built=completed
    if not pending then return true end
    if game.tick-q.progress_tick>limits.progress_timeout_ticks then
      q.state,q.error="failed",q.waiting or "Blueprint made no construction progress before timeout"; return true
    end
    if not pending.ghost.valid then q.waiting="Waiting for blueprint item requests or a missing entity";return false end
    if q.mode=="robots" then
      q.waiting="Waiting for construction robots and network materials"
      return false
    end
    if q.stepping_away then
      if storage.walking_queues[cid] then q.waiting="Clearing construction space";return false end
      q.stepping_away=nil
    end
    local ghost=pending.ghost
    local choices=ghost.ghost_prototype.items_to_place_this or {}
    local inv=entity.get_main_inventory()
    local item
    for _,choice in ipairs(choices) do
      local candidate={name=choice.name,count=choice.count,quality=pending.quality}
      if inv.get_item_count{name=candidate.name,quality=candidate.quality}>=candidate.count then item=candidate;break end
    end
    if not item then q.state,q.error="failed","Missing carried item for " .. pending.name;return true end
    local distance=u.distance(entity.position,pending.position)
    if distance>entity.build_distance then
      if not storage.walking_queues[cid] then
        storage.walking_queues[cid]={target=pending.position}
      end
      q.waiting="Walking to construction site";return false
    end
    storage.walking_queues[cid]=nil;entity.walking_state={walking=false}
    local removed=inv.remove(item)
    if removed~=item.count then
      if removed>0 then inv.insert{name=item.name,count=removed,quality=item.quality} end
      q.state,q.error="failed","Construction item is no longer available";return true
    end
    local ok,collisions=pcall(function() return ghost.revive{raise_revive=true,overflow=inv} end)
    if not ok or collisions==nil then
      -- A mod event may throw after native construction has already consumed the ghost.
      if ghost.valid then inv.insert(item) end
      if not ok then error(collisions) end
      q.waiting="Placement blocked"
      -- Walk around a self-collision without teleporting the character.
      if entity.surface.find_entities_filtered{type="character",position=pending.position,radius=2}[1]==entity
        and not storage.walking_queues[cid] then
        local away=entity.surface.find_non_colliding_position("character",{x=pending.position.x+4,y=pending.position.y},4,0.5)
        if away then storage.walking_queues[cid]={target=away};q.stepping_away=true end
      end
      return false
    end
    for _,stack in ipairs(collisions) do
      local inserted=inv.insert(stack)
      if inserted<stack.count then
        entity.surface.spill_item_stack{position=entity.position,stack={name=stack.name,count=stack.count-inserted,quality=stack.quality},enable_looted=true,allow_belts=false}
      end
    end
    return false
  end)
end

return M
