import { spawn } from "node:child_process";
import { cpSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { readSettings } from "../config/settings";
import { LOCAL_DIR } from "../src/config";
import { factorioBinary, factorioModDirectory } from "./paths";

const settings = readSettings(),
  binary = factorioBinary();
if (!binary) throw new Error("Factorio not found; set FACTORIO_BINARY");
if (!["127.0.0.1", "localhost"].includes(settings.FACTORIO_HOST))
  throw new Error("game:launch configures a local game; launch remote servers on their own host");
const config = join(dirname(factorioModDirectory()), "config", "config.ini");
if (!existsSync(config)) throw new Error(`Open Factorio once to create ${config}`);
const backups = join(LOCAL_DIR, "game-config-backups");
mkdirSync(backups, { recursive: true });
let text = readFileSync(config, "utf8");
const original = text;
for (const [key, value] of Object.entries({
  "local-rcon-socket": `127.0.0.1:${settings.FACTORIO_RCON_PORT}`,
  "local-rcon-password": settings.FACTORIO_RCON_PASSWORD,
})) {
  if (/[\r\n]/.test(value)) throw new Error("Factorio config values cannot contain newlines");
  const pattern = new RegExp(`^;?\\s*${key}=.*$`, "m");
  if (pattern.test(text)) text = text.replace(pattern, () => `${key}=${value}`);
  else text = text.replace(/^\[other\]\r?\n/m, (match) => `${match}${key}=${value}\n`);
}
if (text !== original) {
  cpSync(config, join(backups, `config-${Date.now()}.ini`));
  writeFileSync(config, text);
}
const child = spawn(binary, ["--config", config], {
  detached: true,
  windowsHide: false,
  stdio: "ignore",
});
await new Promise<void>((resolve, reject) => {
  child.once("spawn", resolve);
  child.once("error", reject);
});
child.unref();
console.log(
  `Factorio launch requested; accept Steam's prompt if shown. Host a multiplayer game; RCON is configured on 127.0.0.1:${settings.FACTORIO_RCON_PORT}.`,
);
