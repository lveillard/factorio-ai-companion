import { test } from "bun:test";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { PROJECT_ROOT } from "../src/config";

// Execute production Lua without starting Factorio. Engine APIs are deterministic fakes;
// real engine/pathfinding coverage remains in the explicitly invoked test:game suite.
const { lua, lauxlib, lualib, to_luastring } = require("fengari");
const directory = join(PROJECT_ROOT, "factorio-mod/commands");
const modules = readdirSync(directory)
  .filter((name) => name.endsWith(".lua"))
  .map(
    (name) =>
      `package.preload["commands.${name.slice(0, -4)}"] = function(...)\n${readFileSync(join(directory, name), "utf8")}\nend`,
  )
  .join("\n");
const fixture = readFileSync(join(PROJECT_ROOT, "tests/fixtures/game.lua"), "utf8");
const control = `package.preload["control"] = function(...)\n${readFileSync(join(PROJECT_ROOT, "factorio-mod/control.lua"), "utf8")}\nend`;
function run(source: string) {
  const state = lauxlib.luaL_newstate();
  lualib.luaL_openlibs(state);
  try {
    const status = lauxlib.luaL_dostring(
      state,
      to_luastring(modules + "\n" + control + "\n" + fixture + "\n" + source),
    );
    if (status !== lua.LUA_OK) throw new Error(lua.lua_tojsstring(state, -1));
  } finally {
    lua.lua_close(state);
  }
}

test("Lua: wood resolves to harvestable trees and failed gather validates before queuing", () =>
  run(`
  local resources=require("commands.resource_query")
  local tree={valid=true,type="tree",name="tree-01",position={x=1,y=0},
    prototype={mineable_properties={products={{name="wood",type="item",amount=4}}}}}
  entity.surface.find_entities_filtered=function(args)
    assert(args.name~="wood", "wood is a product, not an entity")
    return args.type=="tree" and {tree} or {}
  end
  entity.surface.count_entities_filtered=function() return 0 end
  entity.surface.find_non_colliding_position=function(_,p) return p end
  entity.get_main_inventory().can_insert=function() return true end
  assert(queues.start_gather(1,"does-not-exist",4).error and not storage.gather_queues[1])
  assert(not queues.start_gather(1,"wood",4).error)
  queues.tick_gather_queues(); queues.tick_gather_queues(); queues.tick_gather_queues()
  assert(entity.selected==tree and entity.mining_state.mining)
  items.wood=4; game.tick=100; queues.tick_gather_queues()
  for _=1,2 do
    local s=queues.get_gather_status(1)
    assert(not s.active and s.state=="done" and s.gathered==4 and s.run_end_tick==100)
  end
  assert(#storage.errors==0)
`));

test("Lua: resource lookup sorts all candidates before limiting and filters by product", () =>
  run(`
  require("commands.resource")
  local ores={}
  for x=120,1,-1 do ores[#ores+1]={valid=true,type="resource",name="ore",amount=100,position={x=x,y=0},prototype=prototypes.entity.ore} end
  entity.surface.find_entities_filtered=function(args)
    assert(not args.limit and args.name=="ore")
    local found={}; for _,ore in ipairs(ores) do if ore.position.x<=args.radius then found[#found+1]=ore end end
    return found
  end
  local result; u.json_response=function(value) result=value end
  u.handlers.resource_nearest{companionId=1,resourceType="ore"}
  assert(result.position.x==1 and result.distance==1)
  u.handlers.resource_list{companionId=1,filter="ore",radius=200}
  assert(result.count==20 and result.resources[1].position.x==1 and result.resources[20].position.x==20)
`));

test("Lua: an exception terminates only the failed companion job and logs once", () =>
  run(`
  local core=require("commands.queues_core")
  storage.companions[2]={entity=entity,name="Grace"}
  storage.gather_queues[1]={state="find"};storage.gather_queues[2]={state="find"}
  local ran=false
  local function process(cid) if cid==1 then error("broken target") end; ran=true; return true end
  core.process_queue("gather_queues",process);core.process_queue("gather_queues",process)
  assert(ran and #storage.errors==1)
  assert(core.previous("gather_queues",1).state=="failed")
  assert(core.previous("gather_queues",2).state=="done")
`));

test("Lua: a chest reports one inventory despite the fuel enum alias and nearby ore", () =>
  run(`
  defines.inventory.chest=1;defines.inventory.fuel=1
  local chest={valid=true,name="wooden-chest",type="container",prototype={items_to_place_this={{name="wooden-chest",count=1}}},position={x=1,y=0},
    get_inventory=function(index) assert(index==1);return {valid=true,get_contents=function() return {{name="iron-plate",count=5,quality="normal"}} end} end,
    get_fuel_inventory=function() return nil end}
  entity.surface.find_entities_filtered=function() return {{valid=true,type="resource",prototype={},position={x=1,y=0}},chest} end
  require("commands.companion")
  local result;u.json_response=function(value) result=value end
  u.handlers.companion_inventory{companionId=1,x=1,y=0}
  assert(result.entity=="wooden-chest" and #result.items==1 and result.items[1].count==5)
`));

test("Lua: hand crafting distinguishes locked recipes, machine categories and missing items", () =>
  run(`
  entity.force.recipes.gear.enabled=false
  assert(queues.start_craft(1,"gear",1).error:find("locked"))
  entity.force.recipes.gear.enabled=true; prototypes.recipe.gear.category="smelting"
  assert(queues.start_craft(1,"gear",1).error:find("not hand%-craftable"))
  prototypes.recipe.gear.category="crafting";items.plate=0
  assert(queues.start_craft(1,"gear",1).error=="Missing ingredients")
  assert(not storage.craft_queues[1] and entity.crafting_queue_size==0)
`));

test("Lua: rotation targets the machine instead of a mod helper at the same position", () =>
  run(`
  local helper={valid=true,name="erm_attackable_entity_beacon",type="beacon",rotatable=true,position={x=1,y=0},prototype={}}
  local drill={valid=true,name="burner-mining-drill",type="mining-drill",rotatable=true,position={x=1,y=0},
    prototype={items_to_place_this={{name="burner-mining-drill",count=1}}},direction=0}
  entity.surface.find_entities_filtered=function() return {helper,drill} end
  local result;u.json_response=function(value) result=value end
  require("commands.building")
  u.handlers.building_rotate{companionId=1,x=1,y=0,direction=2}
  assert(result.rotated=="burner-mining-drill" and drill.direction==defines.direction.south)
  assert(helper.direction==nil)
`));

test("Lua: machine-only resources remain discoverable but cannot start a hand-mining job", () =>
  run(`
  prototypes.entity.oil={type="resource",mineable_properties={products={{name="crude-oil",type="fluid"}}}}
  local query=require("commands.resource_query")
  local selector=query.resolve("oil")
  assert(selector and not selector.hand_mineable)
  local oil={valid=true,name="oil",type="resource",amount=100,position={x=0,y=0},prototype=prototypes.entity.oil}
  assert(query.available(oil,selector))
  assert(queues.start_gather(1,"oil",1).error:find("mining machine"))
  assert(not storage.gather_queues[1])
`));

test("Lua: extraction preserves quality and uses the shared inventory groups", () =>
  run(`
  require("commands.building")
  defines.inventory.chest=1
  local remaining=4
  local inv={valid=true,get_contents=function() return {{name="iron-plate",quality="uncommon",count=remaining}} end,
    remove=function(item) assert(item.quality=="uncommon");remaining=remaining-item.count;return item.count end,
    insert=function(item) assert(item.quality=="uncommon");remaining=remaining+item.count;return item.count end}
  local chest={valid=true,name="wooden-chest",type="container",position={x=1,y=0},
    prototype={items_to_place_this={{name="wooden-chest",count=1}}},get_inventory=function() return inv end,
    get_fuel_inventory=function() return nil end}
  entity.surface.find_entities_filtered=function() return {chest} end
  entity.insert=function(item) assert(item.quality=="uncommon");return 1 end
  local result;u.json_response=function(value) result=value end
  u.handlers.building_empty{companionId=1,x=1,y=0,itemName="iron-plate",count=3}
  assert(result.extracted==1 and remaining==3)
`));

test("Lua: blueprint cancellation removes only its own remaining ghosts", () =>
  run(`
  local removed=0
  local ghost={valid=true,destroy=function() removed=removed+1 end}
  storage.blueprint_queues[1]={name="plan",state="building",targets={{ghost={valid=false},done=true},{ghost=ghost}},built=1}
  local unrelated={valid=true,destroy=function() error("Another companion's ghost must survive") end}
  storage.blueprint_queues[2]={targets={{ghost=unrelated}},state="building"}
  require("commands.lifecycle").stop(1)
  local status=queues.get_blueprint_status(1)
  assert(removed==1 and status.state=="cancelled" and status.built==1 and status.total==2)
  assert(storage.blueprint_queues[2] and items.plate==20)
`));

for (const nativeBuilt of [false, true])
  test(`Lua: blueprint revival error refunds only an unbuilt entity (${nativeBuilt})`, () =>
    run(`
  entity.build_distance=10
  local stock=1
  local inv=entity.get_main_inventory()
  inv.get_item_count=function() return stock end
  inv.remove=function(item) stock=stock-item.count;return item.count end
  inv.insert=function(item) stock=stock+item.count;return item.count end
  local ghost={valid=true,ghost_prototype={items_to_place_this={{name="wooden-chest",count=1}}}}
  ghost.revive=function() ghost.valid=${nativeBuilt ? "false" : "true"};error("Native event failed") end
  ghost.destroy=function() ghost.valid=false end
  storage.blueprint_queues[1]={name="plan",state="building",mode="manual",manages_timeout=true,progress_tick=0,built=0,
    targets={{ghost=ghost,name="wooden-chest",quality="normal",position={x=1,y=0}}}}
  queues.tick_blueprint_queues()
  assert(queues.get_blueprint_status(1).state=="failed")
  assert(stock==${nativeBuilt ? 0 : 1},"A native event must not duplicate or lose construction items")
`));

test("Lua: crafting finishes only when native outputs exist", () =>
  run(`
  assert(not queues.start_craft(1, "gear", 2).error)
  advance(40)
  assert(queues.get_craft_status(1).active)
  assert(queues.get_craft_status(1).crafted == 0)
  advance(200)
  assert(not queues.get_craft_status(1).active)
  assert(queues.get_craft_status(1).crafted == 2)
  assert(items.gear == 2)
`));
for (const stop of ["queues.stop_craft(1)", 'require("commands.lifecycle").stop(1)'])
  test(`Lua: ${stop} cancels native crafting and refunds ingredients`, () =>
    run(`
    queues.start_craft(1, "gear", 5)
    advance(35)
    assert(entity.crafting_queue_size > 0)
    ${stop}
    assert(entity.crafting_queue_size == 0, "native crafting survives stop")
    advance(200)
    assert((items.gear or 0) == 0, "items appeared after cancellation")
    assert(items.plate == 20, "cancel must refund unconsumed ingredients")
  `));
test("Lua: starting a second craft preserves the first job", () =>
  run(`
  queues.start_craft(1, "gear", 2)
  advance(35)
  assert(queues.start_craft(1, "gear", 4).error)
  advance(250)
  assert(items.gear == 2)
`));
test("Lua: a stalled mining job reports failure, never successful completion", () =>
  run(`
  storage.gather_queues[1] = {state="mine", resource="ore", product="ore", start_count=0, target=60,
    _stale_total=20, _stale_pos={x=0,y=0}, _stale_ticks=1000}
  queues.tick_gather_queues()
  queues.tick_gather_queues()
  local result = queues.get_gather_status(1)
  assert(not result.active)
  assert(result.error and result.state == "failed", "stalled mining is reported as done")
`));
test("Lua: stopped mining retains its partial result and reason on repeated reads", () =>
  run(`
  items.ore=33
  storage.gather_queues[1]={state="mine",product="ore",resource="ore",start_count=0,target=60}
  require("commands.lifecycle").stop(1)
  require("commands.lifecycle").stop(1)
  for _=1,2 do
    local result=queues.get_gather_status(1)
    assert(not result.active and result.state=="cancelled")
    assert(result.gathered==33 and result.error)
  end
`));
test("Lua: cancelling one companion preserves another companion's queues and reservations", () =>
  run(`
  local ledger=require("commands.task_pool_ledger")
  storage.companions[2]={entity=entity,name="Grace"}
  storage.next_task_id=1
  local a=ledger.submit_task(1,{{type="fuel",item="plate",count=5}})
  local b=ledger.submit_task(2,{{type="fuel",item="plate",count=5}})
  storage.gather_queues[2]={state="find",resource="ore",target=60}
  require("commands.lifecycle").stop(1)
  assert(ledger.get_task_status(a.task_id).status=="cancelled")
  assert(ledger.get_task_status(b.task_id).status=="active")
  assert(ledger.reservations(1).plate==0 and ledger.reservations(2).plate==5)
  assert(storage.gather_queues[2])
`));
test("Lua: machine inventories return names, quantities and quality without duplicate fuel", () =>
  run(`
  defines.inventory.chest=1; defines.inventory.fuel=1
  defines.inventory.crafter_input=2; defines.inventory.crafter_output=3
  local slots={
    [1]={valid=true,get_contents=function() return {{name="coal",count=5,quality="normal"}} end},
    [2]={valid=true,get_contents=function() return {{name="iron-ore",count=21,quality="normal"}} end},
    [3]={valid=true,get_contents=function() return {{name="iron-plate",count=4,quality="uncommon"}} end},
  }
  local machine={valid=true,type="furnace",name="stone-furnace",prototype={items_to_place_this={{name="stone-furnace",count=1}}},position={x=1,y=0},get_inventory=function(slot) return slots[slot] end, get_fuel_inventory=function() return slots[1] end, get_output_inventory=function() return slots[3] end}
  entity.surface.find_entities_filtered=function() return {machine} end
  local result; u.json_response=function(value) result=value end
  require("commands.companion")
  u.handlers.companion_inventory{companionId=1,x=1,y=0}
  assert(not result.error and #result.items==3)
  assert(result.items[1].name=="iron-ore" and result.items[1].count==21)
  assert(result.items[2].quality=="uncommon" and result.items[3].name=="coal")
`));
test("Lua: belt pathfinding avoids occupied tiles and reports blocked endpoints", () =>
  run(`
  local surf={
    count_entities_filtered=function() return 0 end,
    count_tiles_filtered=function() return 0 end,
    can_place_entity=function(args) return not (args.position[1]==2 and args.position[2]>=-1 and args.position[2]<=1) end,
  }
  local pathfind=require("commands.pathfind")
  local path,err=pathfind.find_path(surf,{x=0,y=0},{x=4,y=0},entity.force)
  assert(path and not err)
  for i,p in ipairs(path) do
    assert(not(p.x==2 and p.y>=-1 and p.y<=1))
    if i>1 then assert(math.abs(p.x-path[i-1].x)+math.abs(p.y-path[i-1].y)==1) end
  end
  local blocked,reason=pathfind.find_path(surf,{x=0,y=0},{x=2,y=0},entity.force)
  assert(not blocked and reason=="dest-blocked")
`));

test("Lua: drill inspection never treats fuel as output or calls crafting-only APIs", () =>
  run(`
  local fuel={valid=true,get_contents=function() return {{name="coal",count=4,quality="normal"}} end}
  local drill={valid=true,type="mining-drill",name="burner-mining-drill",prototype={items_to_place_this={{name="burner-mining-drill",count=1}}},position={x=1,y=0},
    direction=defines.direction.south,force={name="player"},status=defines.entity_status.working,
    get_fuel_inventory=function() return fuel end,
    get_output_inventory=function() error("Fuel inventory alias must not be read as output") end,
    get_inventory=function() error("Drill has no crafting input") end,
    get_recipe=function() error("Entity is not crafting-machine.") end,
    mining_target={valid=true,name="iron-ore",type="resource",position={x=1,y=0}},
    mining_progress=0.5,drop_position={x=0.5,y=1.5},
    drop_target={valid=true,name="stone-furnace",type="furnace",position={x=1,y=2}}}
  entity.surface.find_entities_filtered=function() return {drill} end
  local result; u.json_response=function(value) result=value end
  require("commands.building")
  u.handlers.building_info{companionId=1,x=1,y=0}
  assert(not result.error and result.entity.name=="burner-mining-drill")
  local info=result.entity
  assert(info.output==nil and info.input==nil and info.recipe==nil)
  assert(info.fuel[1].count==4 and info.facing=="south")
  assert(info.drop_target.name=="stone-furnace" and info.mining_target.name=="iron-ore")
  local observed=require("commands.entity_info").describe(drill,true)
  assert(observed.drop_position.y==info.drop_position.y and observed.output==nil)
`));

test("Lua: shared machine inspection exposes real crafting output and production counters", () =>
  run(`
  defines.inventory.crafter_input=2
  local output={valid=true,get_contents=function() return {{name="iron-plate",count=8,quality="uncommon"}} end}
  local machine={name="stone-furnace",type="furnace",position={x=1,y=0},direction=0,
    force={name="player"},status=1,get_fuel_inventory=function() return nil end,
    get_inventory=function(slot) assert(slot==2); return nil end,
    get_output_inventory=function() return output end,get_recipe=function() return {name="iron-plate"} end,
    products_finished=31,crafting_progress=0.25}
  local info=require("commands.entity_info").describe(machine,true)
  assert(info.recipe=="iron-plate" and info.products_finished==31)
  assert(info.output[1].quality=="uncommon" and info.crafting_progress==0.25)
`));

test("Lua: mining with a stuck selection changes tile without reporting completion", () =>
  run(`
  entity.surface.find_non_colliding_position=function() return nil end
  local ore = {name="ore",type="resource",valid=true,amount=100,position={x=1,y=0},prototype=prototypes.entity.ore}
  entity.surface.find_entities_filtered = function(args) return args.name and {ore} or {} end
  entity.get_main_inventory().can_insert = function() return true end
  entity.selected=ore
  entity.mining_state={mining=true}
  storage.gather_queues[1]={state="mine",resource="ore",selector={name="ore",product="ore"},product="ore",start_count=0,target=60,
    entity_pos={x=1,y=0},mine_gathered_at_entry=0,mine_stuck_ticks=u.settings.queue_tuning.mine_stuck_ticks}
  queues.tick_gather_queues()
  local q=storage.gather_queues[1]
  assert(q.state=="find" and q.blacklist["1,0"] and not entity.mining_state.mining)
  assert(queues.get_gather_status(1).active)
`));

test("Lua: gathering skips ore covered by a machine", () =>
  run(`
  local blocked={name="ore",type="resource",valid=true,amount=100,position={x=1,y=0},prototype=prototypes.entity.ore}
  local free={name="ore",type="resource",valid=true,amount=100,position={x=4,y=0},prototype=prototypes.entity.ore}
  entity.surface.find_entities_filtered=function(args)
    if args.name then return {blocked,free} end
    return args.position.x==1 and {{valid=true,type="furnace",prototype={items_to_place_this={{name="stone-furnace",count=1}}}}} or {}
  end
  entity.surface.count_entities_filtered=function() return 0 end
  entity.surface.find_non_colliding_position=function(_,p) return p end
  queues.start_gather(1,"ore",20)
  queues.tick_gather_queues()
  assert(storage.gather_queues[1].entity_pos.x==4)
`));

test("Lua: blocked tasks expire but procurement of future materials keeps running", () =>
  run(`
  local pool=require("commands.task_pool")
  pool.init()
  local blocked=pool.submit_task(1,{{type="place",entity="stone-furnace",x=0,y=0}}).task_id
  pool.tick()
  assert(pool.get_task_status(blocked).active)
  game.tick=u.settings.task_tuning.needs_unmet_giveup_ticks
  pool.tick()
  assert(pool.get_task_status(blocked).status=="failed")
  local preparing=pool.submit_task(1,{{type="ensure_item",item="wood",count=1},{type="place",entity="stone-furnace"}}).task_id
  storage.gather_queues[1]={state="mine"}
  game.tick=game.tick+u.settings.task_tuning.needs_unmet_giveup_ticks*2
  pool.tick()
  assert(pool.get_task_status(preparing).active, "future materials must not expire an active procurement step")
`));

test("Lua: task fuel selects the nearest burner and fails clearly without a target", () =>
  run(`
  local pool=require("commands.task_pool")
  pool.init()
  items.coal=5
  local amounts={0,0}
  local function burner(x,index)
    return {valid=true,position={x=x,y=0},get_fuel_inventory=function()
      return {insert=function(stack) amounts[index]=amounts[index]+stack.count;return stack.count end}
    end}
  end
  entity.remove_item=function(stack) items[stack.name]=items[stack.name]-stack.count;return stack.count end
  entity.surface.find_entities_filtered=function(args)
    assert(args.type[3]=="inserter", "burner-inserter is a name, not an entity type")
    return {burner(2,1),burner(0,2)}
  end
  local task=pool.submit_task(1,{{type="fuel",item="coal",count=3,x=0,y=0}}).task_id
  pool.tick(); pool.tick()
  assert(amounts[1]==0 and amounts[2]==3)
  assert(pool.get_task_status(task).status=="done")
  local invalid=pool.submit_task(1,{{type="fuel",item="coal",count=1}}).task_id
  pool.tick(); pool.tick()
  assert(pool.get_task_status(invalid).error:find("no target position"))
`));

test("Lua: procurement collects matching furnace output beyond an empty nearer machine", () =>
  run(`
  local procurement=require("commands.task_pool_ensure_item")
  prototypes.recipe["iron-plate"]={category="smelting",ingredients={{name="iron-ore",amount=1}},products={{name="iron-plate",amount=1}}}
  local counts={0,2}
  local function furnace(x,index)
    return {valid=true,position={x=x,y=0},get_recipe=function() return prototypes.recipe["iron-plate"] end,
      get_output_inventory=function() return {valid=true,get_contents=function() return {{name="iron-plate",count=counts[index],quality="normal"}} end,
        remove=function(stack) counts[index]=counts[index]-stack.count;return stack.count end,
        insert=function(stack) counts[index]=counts[index]+stack.count;return stack.count end} end}
  end
  entity.insert=function(stack) items[stack.name]=(items[stack.name] or 0)+stack.count;return stack.count end
  entity.surface.find_entities_filtered=function() return {furnace(1,1),furnace(2,2)} end
  local task={ctx={ensure_stack={{item="iron-plate",count=2}}}}
  assert(procurement.start_ensure_item_action(storage.companions[1],1,task)=="satisfied")
  assert(items["iron-plate"]==2 and counts[2]==0)
  items["iron-plate"]=nil
  entity.surface.find_entities_filtered=function() return {} end
  local result,err=procurement.start_ensure_item_action(storage.companions[1],1,task)
  assert(not result and err:find("No nearby machine"))
`));

test("Lua: drill footprints reject mixed or missing resources without creating entities", () =>
  run(`
  local steps=require("commands.task_pool_steps")
  prototypes.entity.drill={type="mining-drill",collision_box={left_top={x=-1,y=-1},right_bottom={x=1,y=1}}}
  entity.surface.can_place_entity=function() return true end
  entity.surface.create_entity=function() error("Read checks must not create entities") end
  entity.surface.get_tile=function() return {name="grass"} end
  local mode="mixed"
  entity.surface.find_entities_filtered=function(args)
    if args.area then
      if mode=="empty" then return {} end
      if mode=="mixed" then return {{valid=true,name="coal"},{valid=true,name="iron-ore"}} end
      return {{valid=true,name="coal"}}
    end
    return {}
  end
  local task={ctx={px=0,py=0},cursor=2,steps={{type="find_patch",resource="coal"}}}
  local step={primary="drill",secondary="drill",offsets={{2,0}}}
  assert(not steps.run_pick_orientation(storage.companions[1],task,step))
  mode="empty"
  assert(not steps.run_pick_orientation(storage.companions[1],task,step))
  mode="coal"
  assert(steps.run_pick_orientation(storage.companions[1],task,step))
`));

test("Lua: a failed recovery clone leaves the companion and its inventory intact", () =>
  run(`
  entity.surface.find_non_colliding_position=function(_,pos) return pos end
  entity.clone=function() return nil end
  entity.destroy=function() error("Original must survive a failed clone") end
  local result=queues.debug_respawn_entity(1)
  assert(not result.respawned and storage.companions[1].entity==entity and items.plate==20)
`));

test("Lua: clearing wrong furnace output preserves quality and rolls back overflow", () =>
  run(`
  require("commands.building")
  local stored=3
  local inv={valid=true,get_contents=function() return {{name="copper-plate",count=stored,quality="uncommon"}} end,
    remove=function(stack) assert(stack.quality=="uncommon");stored=stored-stack.count;return stack.count end,
    insert=function(stack) assert(stack.quality=="uncommon");stored=stored+stack.count;return stack.count end}
  entity.surface.find_entities_filtered=function() return {{valid=true,type="furnace",position={x=1,y=0},get_output_inventory=function() return inv end}} end
  entity.insert=function(stack) assert(stack.quality=="uncommon");return 1 end
  local result
  u.json_response=function(value) result=value end
  u.handlers.building_clear_wrong_output{companionId=1,itemName="iron-plate",x=1,y=0}
  assert(result.cleared and result.count==1 and stored==2)
`));

test("Lua: walking retargets blocked destinations, replans stalled paths and retains arrival", () =>
  run(`
  local init,tick,path_event
  script={active_mods={["ai-companion"]="test"},on_init=function(fn) init=fn end,
    on_configuration_changed=function() end,on_event=function(_,fn) path_event=fn end,
    on_nth_tick=function(_,fn) tick=fn end}
  commands={add_command=function() end}
  defines.events={on_script_path_request_finished=1}
  defines.entity_status={}
  require("control")
  init()
  prototypes.entity.character={collision_box={},collision_mask={}}
  local requests={}
  entity.surface.find_entities_filtered=function() return {} end
  entity.surface.find_non_colliding_position=function(_,pos) return {x=8,y=pos.y} end
  entity.surface.request_path=function(args) requests[#requests+1]=args;return #requests end
  storage.walking_queues[1]={target={x=10,y=0}}
  game.tick=5;tick{tick=5}
  assert(#requests==1 and requests[1].goal.x==8)
  path_event{id=1,path={{position={x=8,y=0}}}}
  local q=storage.walking_queues[1]
  q.last_path_idx=1;q.waypoint_stall_ticks=u.settings.walking.waypoint_stall_repath_ticks
  game.tick=10;tick{tick=10}
  game.tick=15;tick{tick=15}
  for _,error in ipairs(storage.errors) do assert(error.context~="walking",error.error) end
  assert(#requests==2 and q.path_pending, "a stale waypoint must request a new path")
  entity.position={x=8,y=0}
  game.tick=20;tick{tick=20}
  assert(not storage.walking_queues[1] and storage.walk_last_arrived[1].x==8)
  for _,error in ipairs(storage.errors) do assert(error.context~="walking",error.error) end
`));
