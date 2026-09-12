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
function run(source: string) {
  const state = lauxlib.luaL_newstate();
  lualib.luaL_openlibs(state);
  try {
    const status = lauxlib.luaL_dostring(
      state,
      to_luastring(modules + "\n" + fixture + "\n" + source),
    );
    if (status !== lua.LUA_OK) throw new Error(lua.lua_tojsstring(state, -1));
  } finally {
    lua.lua_close(state);
  }
}

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
  local machine={valid=true,type="furnace",name="stone-furnace",position={x=1,y=0},get_inventory=function(slot) return slots[slot] end}
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
