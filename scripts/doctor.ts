import { existsSync } from "node:fs";
import { join, resolve } from "node:path";
import { readSettings } from "../config/settings";
import { factorioBinary, factorioModDirectory } from "./paths";
import { PROJECT_ROOT } from "../src/config";
import pkg from "../package.json";

const settings = readSettings();
const binary = factorioBinary();
console.log(`Factorio AI Companion ${pkg.version}`);
console.log(`Bun ${Bun.version}`);
console.log(`Factorio: ${binary || "not found; set FACTORIO_BINARY"}`);
if (binary) {
  const proc = Bun.spawn([binary, "--version"], {
    stdout: "pipe",
    stderr: "pipe",
    windowsHide: true,
  });
  console.log((await new Response(proc.stdout).text()).split("\n")[0]);
  await proc.exited;
}
console.log(`Mod directory: ${factorioModDirectory()}`);
console.log(`RCON: ${settings.FACTORIO_HOST}:${settings.FACTORIO_RCON_PORT} (password configured)`);
console.log(`HTTP: ${settings.COMPANION_HOST}:${settings.COMPANION_PORT}`);
console.log(`Data: ${resolve(PROJECT_ROOT, settings.COMPANION_DATA_DIR)}`);
console.log(
  `Codex runtime: ${existsSync(join(PROJECT_ROOT, "node_modules/@openai/codex/bin/codex.js")) ? "installed" : "missing; run bun install"}`,
);
console.log(
  `Frontend: ${existsSync(join(PROJECT_ROOT, "dist/web/index.html")) ? "built" : "missing; run bun run build"}`,
);
