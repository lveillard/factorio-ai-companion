import { chromium, expect } from "@playwright/test";
import { strict as assert } from "node:assert";
import { join } from "node:path";
import { mkdtempSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { createApplication } from "../src/dashboard/server";
import { readSettings } from "../config/settings";
import { LOCAL_DIR } from "../src/config";
import { EventLog } from "../src/runtime/events";
import { GameBridge } from "../src/runtime/game";
import { CompanionSession } from "../src/runtime/session";
import { CodexClient } from "../src/codex/client";
import type { RCONClient } from "../src/rcon/client";
import pkg from "../package.json";

const directory = mkdtempSync(join(tmpdir(), "factorio-web-"));
const artifacts = join(LOCAL_DIR, "web-test");
mkdirSync(artifacts, { recursive: true });
const events = new EventLog();
const calls: Array<{ tool: string; args: Record<string, unknown> }> = [];
let connected = true;
let rejectSpawn = false;
const rcon = {
  isConnected: () => connected,
  disconnect: async () => {},
  sendCommand: async (command: string) => {
    const request = JSON.parse(command.slice("/fac_api ".length));
    calls.push(request);
    let result: unknown = {};
    const companions = game.snapshot!.companions;
    switch (request.tool) {
      case "companion_list":
        result = { companions };
        break;
      case "companion_spawn":
        if (rejectSpawn)
          return { success: true, data: JSON.stringify({ error: "No spawn position available" }) };
        companions.push({
          id: request.args.companionId,
          name: request.args.name,
          inventory: [],
          queues: {},
        });
        result = { spawned: true };
        break;
      case "gather":
        companions.find((c) => c.id === request.args.companionId)!.queues = {
          gather: { active: true },
        };
        break;
      case "companion_stop":
        companions.find((c) => c.id === request.args.companionId)!.queues = {};
        break;
      case "world_observe":
        result = game.snapshot;
        break;
    }
    events.emit("world", { snapshot: game.snapshot, observedAt: new Date().toISOString() }, false);
    return { success: true, data: JSON.stringify(result) };
  },
} as unknown as RCONClient;
const game = new GameBridge(rcon, events);
game.snapshot = {
  version: pkg.version,
  factorio: "2.0.77",
  session_id: "web-fixture",
  tick: 7200,
  paused: false,
  surface: "nauvis",
  center: { x: 0, y: 0 },
  radius: 48,
  companions: [
    {
      id: 1,
      name: "Ada",
      position: { x: 3, y: 2 },
      inventory: [{ name: "iron-ore", count: 32 }],
      queues: { gather: { active: true, state: "mine" } },
    },
  ],
  players: [{ name: "Player", connected: true, surface: "nauvis", position: { x: 0, y: 0 } }],
  entities: [
    { name: "stone-furnace", type: "furnace", force: "player", position: { x: 5, y: 5 } },
    { name: "iron-ore", type: "resource", position: { x: -10, y: -8 } },
  ],
  errors: [],
  research: { name: "automation", progress: 0.42 },
};
game.lastObservedAt = new Date().toISOString();
const session = new CompanionSession(game, new CodexClient(), events, directory);
// Exercise the browser's resume request without starting a model or using account credentials.
session.account = { type: "chatgpt" };
let resumes = 0;
session.resume = async () => {
  resumes++;
  session.enabled = true;
  events.emit("agent.state", session.status(), false);
};
let app: ReturnType<typeof createApplication>;
const server = Bun.serve({
  hostname: "127.0.0.1",
  port: 0,
  fetch: (request) => app.fetch(request),
});
app = createApplication(
  readSettings({ COMPANION_PORT: String(server.port), COMPANION_DATA_DIR: directory }),
  { game, session, events },
);
const browser = await chromium.launch({
  headless: true,
  ...(process.env.PLAYWRIGHT_CHANNEL
    ? { channel: process.env.PLAYWRIGHT_CHANNEL }
    : process.platform === "win32"
      ? { channel: "chrome" }
      : {}),
});
try {
  const page = await browser.newPage({ viewport: { width: 1440, height: 1080 } });
  const errors: string[] = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.goto(app.url);
  await expect(page.locator("#surface")).toHaveText("nauvis");
  await expect(page.locator("#connection-notice")).toBeHidden();
  await expect(page.locator("#map-empty")).toBeHidden();
  assert.equal(await page.locator("html").getAttribute("lang"), "en");
  await page.getByRole("button", { name: "+ Add companion" }).click();
  await page.getByLabel("Name", { exact: true }).fill("Atlas");
  rejectSpawn = true;
  await page.getByRole("button", { name: "Add", exact: true }).click();
  await expect(page.locator("#spawn-error")).toHaveText("No spawn position available");
  rejectSpawn = false;
  await page.getByRole("button", { name: "Add", exact: true }).click();
  await expect(page.locator("#spawn-dialog")).not.toBeVisible();
  await expect(page.locator("#target")).toHaveValue("2");
  await expect(page.locator("#chat-title")).toHaveText("Chat with Atlas");
  const atlas = page.locator('[data-companion="2"]');
  await atlas.getByRole("button", { name: "Mine", exact: true }).click();
  await page.getByLabel("Resource", { exact: true }).selectOption("coal");
  await page.getByLabel("Amount", { exact: true }).fill("20");
  await page.getByRole("button", { name: "Start mining" }).click();
  await expect(page.locator("#mine-dialog")).not.toBeVisible();
  assert(
    calls.some(
      (c) =>
        c.tool === "gather" &&
        c.args.companionId === 2 &&
        c.args.resource === "coal" &&
        c.args.count === 20,
    ),
  );
  await expect(atlas.getByText("Mining", { exact: true })).toBeVisible();
  await atlas.getByRole("button", { name: "Follow me", exact: true }).click();
  await expect
    .poll(() =>
      calls.some(
        (c) =>
          c.tool === "move_follow" && c.args.companionId === 2 && c.args.playerName === "Player",
      ),
    )
    .toBe(true);
  assert.equal(resumes, 0, "Companion buttons must not invoke the model");
  await page.getByPlaceholder("Give a task or ask a question…").fill("Set up coal mining.");
  await page.getByRole("button", { name: "Send & start", exact: true }).click();
  await page.getByRole("log").getByText("Set up coal mining.").waitFor();
  await expect.poll(() => resumes).toBe(1);
  await expect(page.getByRole("button", { name: "Send", exact: true })).toBeVisible();
  assert.equal(session.status().queued, 1);
  await atlas.getByRole("button", { name: "Stop", exact: true }).click();
  await expect(page.getByRole("log").getByText("Cancelled", { exact: true })).toBeVisible();
  assert.equal(session.status().queued, 0, "Stop must discard queued work for the companion");
  await page.screenshot({ path: join(artifacts, "desktop.png"), fullPage: true });
  await page.locator("#advanced > summary").click();
  await page.getByText("Manual tools", { exact: true }).click();
  await page.locator("#tool-select").selectOption("session_status");
  await page.getByRole("button", { name: "Run tool", exact: true }).click();
  await expect(page.locator("#tool-result")).toContainText('"success": true');
  await page.locator("#advanced > summary").click();
  await page.getByRole("button", { name: "Settings", exact: true }).click();
  await expect(
    page.getByRole("button", { name: "Sign in with a code", exact: true }),
  ).toBeVisible();
  await page.getByRole("button", { name: "Close settings", exact: true }).click();
  await page.getByRole("button", { name: /^Activity/ }).click();
  await expect(page.locator("#logs")).toContainText("gather");
  await page.getByRole("button", { name: "Chat", exact: true }).click();
  await page.setViewportSize({ width: 390, height: 844 });
  assert.equal(
    await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth),
    true,
    "Mobile layout must not overflow horizontally",
  );
  await page.screenshot({ path: join(artifacts, "mobile.png"), fullPage: true });
  connected = false;
  events.emit("game.disconnected", { error: "Game closed" });
  await expect(page.locator("#connection-notice")).toContainText("host a multiplayer game");
  await expect(page.locator("#connection-notice")).toBeVisible();
  await expect(page.locator("#map-empty")).toHaveText("Connection lost · last view");
  await expect(page.locator("#map-empty")).toBeVisible();
  await expect(page.locator("#agent-state")).toHaveText("Waiting for game");
  await expect(page.getByRole("button", { name: "+ Add companion" })).toBeDisabled();
  await expect(atlas.getByRole("button", { name: "Mine", exact: true })).toBeDisabled();
  connected = true;
  events.emit("world", { snapshot: game.snapshot, observedAt: new Date().toISOString() }, false);
  await expect(page.locator("#connection-notice")).toBeHidden();
  await expect(page.locator("#map-empty")).toBeHidden();
  await expect(page.getByRole("button", { name: "+ Add companion" })).toBeEnabled();
  assert.deepEqual(errors, []);
  console.log(
    `Browser smoke passed: companion creation/error recovery, mining, follow, stop, chat resume, manual tools, settings, activity, offline and mobile layout. Screenshots: ${artifacts}`,
  );
} finally {
  await browser.close();
  await app.close();
  await server.stop(true);
}
