import { chromium } from "@playwright/test";
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
const rcon = {
  isConnected: () => true,
  disconnect: async () => {},
  sendCommand: async () => ({ success: true, data: '{"companions":[]}' }),
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
  players: [],
  entities: [
    { name: "stone-furnace", type: "furnace", force: "player", position: { x: 5, y: 5 } },
    { name: "iron-ore", type: "resource", position: { x: -10, y: -8 } },
  ],
  errors: [],
  research: { name: "automation", progress: 0.42 },
};
game.lastObservedAt = new Date().toISOString();
const session = new CompanionSession(game, new CodexClient(), events, directory);
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
  await page.locator("#surface").filter({ hasText: "nauvis" }).waitFor();
  await page
    .getByPlaceholder("Dale una tarea, pregúntale algo o cambia el plan…")
    .fill("Observa el hierro, por favor.");
  await page.getByRole("button", { name: "Enviar" }).click();
  await page.getByRole("log").getByText("Observa el hierro, por favor.").waitFor();
  assert.equal(session.status().queued, 1);
  await page.screenshot({ path: join(artifacts, "desktop.png"), fullPage: true });
  await page.getByRole("button", { name: "Comandos", exact: true }).click();
  await page.locator("#tool-select").selectOption("session_status");
  await page.getByRole("button", { name: "Ejecutar comando" }).click();
  await page.locator("#tool-result").filter({ hasText: '"success": true' }).waitFor();
  await page.getByRole("button", { name: "Conectar Codex", exact: true }).click();
  await page.locator("#auth-dialog").waitFor({ state: "visible" });
  assert.equal(
    await page.getByRole("button", { name: "Usar código de dispositivo" }).isVisible(),
    true,
  );
  await page.getByRole("button", { name: "Cerrar", exact: true }).click();
  await page.getByRole("button", { name: "Conversación", exact: true }).click();
  await page.setViewportSize({ width: 390, height: 844 });
  assert.equal(
    await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth),
    true,
    "Mobile layout must not overflow horizontally",
  );
  await page.screenshot({ path: join(artifacts, "mobile.png"), fullPage: true });
  assert.deepEqual(errors, []);
  console.log(
    `Browser smoke passed: chat, tool form, login dialog and mobile layout. Screenshots: ${artifacts}`,
  );
} finally {
  await browser.close();
  await app.close();
  await server.stop(true);
}
