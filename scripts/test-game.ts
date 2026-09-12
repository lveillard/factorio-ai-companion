import { spawn } from "node:child_process";
import { cpSync, mkdirSync, writeFileSync } from "node:fs";
import { join, resolve, dirname } from "node:path";
import { strict as assert } from "node:assert";
import { factorioBinary } from "./paths";
import { PROJECT_ROOT, LOCAL_DIR } from "../src/config";
import { RCONClient } from "../src/rcon/client";
import { GameBridge } from "../src/runtime/game";
import { EventLog } from "../src/runtime/events";
import { generate } from "./generate";

generate(true);
const binary = factorioBinary();
if (!binary) throw new Error("Set FACTORIO_BINARY to run the real-game integration test");
const root = join(LOCAL_DIR, "game-test", String(Date.now()));
mkdirSync(root, { recursive: true });
const mods = join(root, "mods");
cpSync(join(PROJECT_ROOT, "factorio-mod"), join(mods, "ai-companion"), { recursive: true });
writeFileSync(
  join(mods, "mod-list.json"),
  JSON.stringify({
    mods: [
      { name: "base", enabled: true },
      { name: "elevated-rails", enabled: false },
      { name: "quality", enabled: false },
      { name: "space-age", enabled: false },
      { name: "ai-companion", enabled: true },
    ],
  }),
);
const config = join(root, "config.ini");
const readData = resolve(dirname(binary), "../../data");
writeFileSync(
  config,
  `[path]\nread-data=${readData.replaceAll("\\", "/")}\nwrite-data=${root.replaceAll("\\", "/")}\n`,
);
const common = ["--config", config, "--mod-directory", mods];
let output = "";
function launch(args: string[]) {
  const child = spawn(binary!, [...common, ...args], {
    windowsHide: true,
    stdio: ["ignore", "pipe", "pipe"],
  });
  const append = (chunk: Buffer) => {
    output = (output + chunk.toString()).slice(-60000);
  };
  child.stdout.on("data", append);
  child.stderr.on("data", append);
  return child;
}
async function createMap() {
  const child = launch(["--create", join(root, "test.zip"), "--map-gen-seed", "424242"]);
  const timer = setTimeout(() => child.kill(), 60000);
  const code = await new Promise<number | null>((resolve, reject) => {
    child.on("exit", resolve);
    child.on("error", reject);
  });
  clearTimeout(timer);
  assert.equal(code, 0, output);
}
console.log("Creating an isolated Factorio test world…");
await createMap();
const password = crypto.randomUUID();
const port = Number(process.env.TEST_RCON_PORT || 34298);
const settings = join(root, "server-settings.json");
writeFileSync(
  settings,
  JSON.stringify({
    name: "AI Companion integration test",
    description: "Isolated local test",
    visibility: { public: false, lan: false },
    require_user_verification: false,
    auto_pause: false,
    autosave_interval: 0,
  }),
);
const child = launch([
  "--start-server",
  join(root, "test.zip"),
  "--server-settings",
  settings,
  "--rcon-port",
  String(port),
  "--rcon-password",
  password,
  "--port",
  "34297",
  "--bind",
  "127.0.0.1",
]);
const rcon = new RCONClient({ host: "127.0.0.1", port, password }, 2000);
const game = new GameBridge(rcon, new EventLog(join(root, "logs")));
async function call(name: string, args = {}) {
  const result = await game.execute(name, args, "test");
  assert.equal(result.success, true, `${name}: ${JSON.stringify(result)}`);
  return result.data as any;
}
try {
  const deadline = Date.now() + 60000;
  while (!rcon.isConnected()) {
    if (child.exitCode !== null || Date.now() > deadline) throw new Error(output);
    try {
      await rcon.connect();
    } catch {
      await Bun.sleep(300);
    }
  }
  console.log("Factorio started; checking the structured RCON contract…");
  const spawn = await call("companion_spawn", { companionId: 1, name: "Prueba Ñ" });
  assert.equal(spawn.id, 1);
  // Test fixtures use Lua only in this disposable world; no such tool is exposed to agents.
  await rcon.sendCommand('/sc rcon.print("enable-test-fixtures")');
  await rcon.sendCommand('/sc rcon.print("enable-test-fixtures")');
  const fixture = await rcon.sendCommand(
    '/sc local s=game.surfaces[1]; local c=s.find_entities_filtered{type="character"}[1]; for _,e in pairs(s.find_entities_filtered{area={{-20,-20},{20,20}}}) do if e~=c then e.destroy() end end; local tiles={}; for x=-20,20 do for y=-20,20 do tiles[#tiles+1]={name="grass-1",position={x,y}} end end; s.set_tiles(tiles); c.teleport({0,0}); c.insert{name="iron-plate",count=30}; c.insert{name="wooden-chest",count=2}; c.insert{name="coal",count=10}; s.create_entity{name="iron-ore",position={2.5,0.5},amount=1000}; game.forces.player.chart(s,{{-32,-32},{32,32}}); rcon.print("fixture-ready")',
  );
  assert.equal(fixture.success, true, JSON.stringify(fixture));
  assert.match(fixture.data, /fixture-ready/);
  await Bun.sleep(150);
  const snapshot = await game.observe(1);
  assert.equal(snapshot.version, (await import("../package.json")).default.version);
  assert.equal(snapshot.companions.length, 1);
  assert.deepEqual(snapshot.errors, [], JSON.stringify(snapshot.errors));
  await call("chat_say", { companionId: 0, message: '¡Hola! «áéíóú» \\ "texto"\nsegunda línea' });
  const chat1 = await call("chat_poll", { afterId: 0 });
  const chat2 = await call("chat_poll", { afterId: 0 });
  assert.deepEqual(chat1.messages, chat2.messages);
  await call("companion_stop", { companionId: 1 });
  await call("building_place", {
    companionId: 1,
    entityName: "wooden-chest",
    x: 0.5,
    y: 3.5,
    direction: 0,
  });
  const machines = await game.observe(1);
  assert.equal(
    machines.entities.some((entity: any) => entity.name === "wooden-chest"),
    true,
    JSON.stringify(machines),
  );
  assert.deepEqual(machines.errors, [], JSON.stringify(machines.errors));
  await call("item_craft_start", { companionId: 1, recipe: "iron-gear-wheel", count: 2 });
  await until(async () => {
    const world = await game.observe(1);
    return (world.companions[0]!.inventory as any[]).some(
      (item) => item.name === "iron-gear-wheel" && item.count >= 2,
    );
  });
  await call("gather", { companionId: 1, resource: "iron-ore", count: 3 });
  await until(async () => {
    const world = await game.observe(1);
    return (world.companions[0]!.inventory as any[]).some(
      (item) => item.name === "iron-ore" && item.count >= 3,
    );
  });
  await until(async () => !(await call("gather_status", { companionId: 1 })).status.active);
  const completed1 = (await call("gather_status", { companionId: 1 })).status;
  const completed2 = (await call("gather_status", { companionId: 1 })).status;
  assert.equal(completed1.gathered, completed2.gathered);
  assert.ok(completed1.gathered >= 3, JSON.stringify(completed1));
  await call("gather", { companionId: 1, resource: "iron-ore", count: 100 });
  await call("companion_stop", { companionId: 1 });
  const stopped = await game.observe(1);
  assert.deepEqual(stopped.companions[0]!.queues, {}, "Stop must clear every queue");
  assert.deepEqual(stopped.errors, [], JSON.stringify(stopped.errors));
  await call("building_remove", { companionId: 1, entityName: "wooden-chest", x: 0.5, y: 3.5 });
  const task = await call("task_submit", {
    companionId: 1,
    steps: [{ type: "ensure_item", item: "iron-gear-wheel", count: 3 }],
  });
  await until(async () => (await call("task_status", { taskId: task.task_id })).status === "done");
  await call("companion_spawn", { companionId: 2, name: "Grace" });
  const a = await call("task_submit", {
    companionId: 1,
    steps: [{ type: "place", entity: "stone-furnace", x: -4, y: 3 }],
  });
  const b = await call("task_submit", {
    companionId: 2,
    steps: [{ type: "place", entity: "stone-furnace", x: 6, y: 3 }],
  });
  assert.deepEqual(a.needs, {}, "First companion can reserve its own furnace");
  assert.deepEqual(b.needs, {}, "Second companion has a separate inventory reservation");
  await call("companion_stop", { companionId: 1 });
  await call("companion_stop", { companionId: 2 });
  assert.equal((await call("task_status", { taskId: a.task_id })).status, "cancelled");
  assert.equal((await call("task_status", { taskId: b.task_id })).status, "cancelled");
  assert.deepEqual((await game.observe(1)).errors, [], "No Lua task failures");
  console.log(
    `Real Factorio ${snapshot.factorio}: spawn, observation, Unicode chat, cursor reads, building, crafting, mining and cancellation passed.`,
  );
} catch (error) {
  writeFileSync(join(root, "process.log"), output);
  throw new Error(
    `${error instanceof Error ? error.stack : String(error)}\nFactorio log: ${join(root, "process.log")}\n${output.slice(-6000)}`,
  );
} finally {
  await game.close();
  child.kill();
  await new Promise<void>((resolve) => {
    if (child.exitCode !== null) resolve();
    else {
      child.once("exit", () => resolve());
      setTimeout(resolve, 3000).unref();
    }
  });
}

async function until(check: () => Promise<boolean>, timeout = 20000) {
  const deadline = Date.now() + timeout;
  while (!(await check())) {
    if (Date.now() > deadline)
      throw new Error(`Game task timed out: ${JSON.stringify(await call("get_errors"))}`);
    await Bun.sleep(200);
  }
}
