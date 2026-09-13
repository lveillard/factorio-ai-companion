import { strict as assert } from "node:assert";
import type { GameBridge } from "../src/runtime/game";
import type { RCONClient } from "../src/rcon/client";

export async function testWalking(game: GameBridge, rcon: RCONClient) {
  const prepared = await rcon.sendCommand(
    '/sc local s=game.surfaces[1]; s.request_to_generate_chunks({1000,0},2); s.force_generate_chunk_requests(); local c=s.find_entities_filtered{type="character"}[1]; for _,e in pairs(s.find_entities_filtered{area={{995,-5},{1060,5}}}) do if e~=c then e.destroy() end end; local tiles={}; for x=995,1060 do for y=-5,5 do tiles[#tiles+1]={name="grass-1",position={x,y}} end end; s.set_tiles(tiles); c.teleport({1000,0}); s.create_entity{name="tree-01",position={1000,1.5}}; rcon.print("walking-fixture-ready")',
  );
  assert.match(prepared.data, /walking-fixture-ready/);
  const before = await game.observe(1);
  const wood = (world: typeof before) =>
    (world.companions[0]!.inventory as any[]).find((item) => item.name === "wood")?.count || 0;
  const move = await game.execute("move_to", { companionId: 1, x: 1050, y: 0 }, "test");
  assert.equal(move.success, true, JSON.stringify(move));
  const deadline = Date.now() + 30000;
  let after = before;
  while (
    Math.hypot(after.companions[0]!.position!.x - 1050, after.companions[0]!.position!.y) > 2
  ) {
    assert.ok(Date.now() < deadline, JSON.stringify(after.errors));
    await Bun.sleep(200);
    after = await game.observe(1);
  }
  assert.equal(wood(after), wood(before), "Walking past a tree must not harvest it");
  assert.equal(
    after.errors.some(
      (error: any) =>
        error.tick > before.tick &&
        ["walking", "walk_path_repath_after_stuck"].includes(error.context),
    ),
    false,
    JSON.stringify(after.errors),
  );
  const tree = await rcon.sendCommand(
    '/sc assert(game.surfaces[1].count_entities_filtered{type="tree",position={1000,1.5},radius=1}==1); rcon.print("tree-preserved")',
  );
  assert.match(tree.data, /tree-preserved/);
  console.log("Native walking: 50-tile path, no false replanning and neighboring tree preserved.");
}
