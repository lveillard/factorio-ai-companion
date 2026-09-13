import assert from "node:assert/strict";
import { deflateSync, inflateSync } from "node:zlib";
import type { GameBridge } from "../src/runtime/game";
import type { RCONClient } from "../src/rcon/client";

export async function testBlueprints(game: GameBridge, rcon: RCONClient) {
  const call = async (name: string, args: Record<string, unknown>) => {
    const result = await game.execute(name, args);
    assert.ok(result.success, JSON.stringify(result));
    return result.data as any;
  };
  const until = async (check: () => Promise<boolean>) => {
    const end = Date.now() + 60000;
    while (!(await check())) {
      assert.ok(
        Date.now() < end,
        JSON.stringify(await call("blueprint_status", { companionId: 1 })),
      );
      await Bun.sleep(200);
    }
  };
  const inventory = async () =>
    (await call("companion_inventory", { companionId: 1 })).items as any[];
  const chests = async () =>
    (await inventory()).filter((i) => i.name === "wooden-chest").reduce((n, i) => n + i.count, 0);
  await call("blueprint_save", {
    name: "Two chests",
    entities: [
      { name: "wooden-chest", x: 0.5, y: 0.5 },
      { name: "wooden-chest", x: 2.5, y: 0.5 },
    ],
  });
  const plan = await call("blueprint_inspect", {
    companionId: 1,
    name: "Two chests",
    export: true,
  });
  assert.equal(plan.entities, 2);
  assert.equal(plan.materials[0].count, 2);
  assert.equal(plan.materials[0].missing, 0);
  assert.equal(plan.manual_supported, true);
  await call("blueprint_save", { name: "Imported chests", blueprint: plan.blueprint });
  const imported = await call("blueprint_inspect", { companionId: 1, name: "Imported chests" });
  assert.deepEqual(imported.materials, plan.materials);
  const before = await chests();
  const start = await call("blueprint_build", {
    companionId: 1,
    name: "Two chests",
    x: -12,
    y: 8,
    mode: "auto",
  });
  assert.equal(start.status.mode, "manual");
  await until(async () => !(await call("blueprint_status", { companionId: 1 })).status.active);
  const finished = (await call("blueprint_status", { companionId: 1 })).status;
  assert.equal(finished.state, "done", JSON.stringify(finished));
  assert.equal(finished.built, 2);
  assert.equal(await chests(), before - 2, "Manual blueprints must consume real carried items");
  const world = await game.observe(1);
  assert.equal(world.entities.filter((e: any) => e.name === "wooden-chest").length, 2);
  assert.equal(world.entities.filter((e: any) => e.type === "entity-ghost").length, 0);
  const missing = await game.execute("blueprint_build", {
    companionId: 1,
    name: "Two chests",
    x: -12,
    y: -8,
    mode: "manual",
  });
  assert.equal(missing.success, false);
  assert.match(missing.error!, /Missing/);
  const noRobots = await game.execute("blueprint_build", {
    companionId: 1,
    name: "Two chests",
    x: -12,
    y: -8,
    mode: "robots",
  });
  assert.equal(noRobots.success, false);
  assert.match(noRobots.error!, /Construction robots/);
  const ghostCount = async () => {
    const r = await rcon.sendCommand(
      '/sc rcon.print(game.surfaces[1].count_entities_filtered{type={"entity-ghost","tile-ghost"}})',
    );
    assert.ok(r.success);
    return Number(r.data.trim());
  };
  assert.equal(await ghostCount(), 0, "Rejected builds leave no ghosts");
  const fixture = await rcon.sendCommand(
    '/sc local s=game.surfaces[1]; local p=s.create_entity{name="roboport",position={10,-12},force="player"}; p.energy=100000000; p.get_inventory(defines.inventory.roboport_robot).insert{name="construction-robot",count=5}; s.create_entity{name="electric-energy-interface",position={10,-7},force="player",power_production=1000000000}; s.create_entity{name="substation",position={13,-8},force="player"}; local chest=s.create_entity{name="passive-provider-chest",position={14,-12},force="player"}; chest.insert{name="wooden-chest",count=8}; rcon.print("robots-ready")',
  );
  assert.match(fixture.data, /robots-ready/);
  await Bun.sleep(300);
  const botStart = await call("blueprint_build", {
    companionId: 1,
    name: "Two chests",
    x: 4,
    y: -12,
    mode: "auto",
  });
  assert.equal(botStart.status.mode, "robots");
  assert.equal(botStart.status.built, 0, "Ghost placement is not construction completion");
  await until(async () => !(await call("blueprint_status", { companionId: 1 })).status.active);
  const botEnd = (await call("blueprint_status", { companionId: 1 })).status;
  assert.equal(botEnd.state, "done", JSON.stringify(botEnd));
  assert.equal(botEnd.built, 2);
  assert.equal(await chests(), before - 2, "Robots consume network items, not companion inventory");
  await call("blueprint_build", {
    companionId: 1,
    name: "Two chests",
    x: 3,
    y: -17,
    mode: "robots",
  });
  await call("companion_stop", { companionId: 1 });
  assert.equal((await call("blueprint_status", { companionId: 1 })).status.state, "cancelled");
  assert.equal(await ghostCount(), 0, "Cancel removes only pending blueprint ghosts");
  await rcon.sendCommand(
    '/sc local c=game.surfaces[1].find_entities_filtered{type="character"}[1];c.insert{name="assembling-machine-1",count=1};rcon.print("assembler-ready")',
  );
  await call("blueprint_save", {
    name: "Gears",
    entities: [{ name: "assembling-machine-1", x: 0, y: 0, recipe: "iron-gear-wheel" }],
  });
  await call("blueprint_build", { companionId: 1, name: "Gears", x: -12, y: -12, mode: "manual" });
  await until(async () => !(await call("blueprint_status", { companionId: 1 })).status.active);
  assert.equal((await call("blueprint_status", { companionId: 1 })).status.state, "done");
  const assembler = (await game.observe(1)).entities.find(
    (e: any) => e.name === "assembling-machine-1",
  ) as any;
  assert.equal(assembler?.recipe, "iron-gear-wheel", "Native blueprints preserve recipe settings");
  const tilePlan = JSON.parse(
    inflateSync(Buffer.from(plan.blueprint.slice(1), "base64")).toString(),
  );
  delete tilePlan.blueprint.entities;
  tilePlan.blueprint.tiles = [{ name: "stone-path", position: { x: 0, y: 0 } }];
  const encodedTile = "0" + deflateSync(Buffer.from(JSON.stringify(tilePlan))).toString("base64");
  await call("blueprint_save", { name: "Paving", blueprint: encodedTile });
  await rcon.sendCommand(
    '/sc local c=game.surfaces[1].find_entities_filtered{type="character"}[1];c.insert{name="stone-brick",count=2};rcon.print("paving-ready")',
  );
  await call("blueprint_build", { companionId: 1, name: "Paving", x: -7, y: 10, mode: "manual" });
  await until(async () => !(await call("blueprint_status", { companionId: 1 })).status.active);
  const paved = (await call("blueprint_status", { companionId: 1 })).status;
  assert.equal(paved.state, "done", JSON.stringify(paved));
  assert.equal(paved.built, 1);
  const bricks = (await inventory()).find((i) => i.name === "stone-brick");
  assert.equal(bricks?.count, 1, "Tile blueprints consume paving materials");
  assert.deepEqual(
    (await game.observe(1)).errors,
    [],
    "Blueprint jobs must not emit native Lua errors",
  );
  console.log(
    "Native blueprints: import/export, material checks, walking/manual construction, robot construction and cancellation passed.",
  );
}
