import { spawn, spawnSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { readSettings } from "../config/settings";
import { LOCAL_DIR } from "../src/config";
import { factorioBinary, factorioModDirectory } from "./paths";
import { configureLocalGame } from "./game-config";

const settings = readSettings(),
  binary = factorioBinary();
if (!binary) throw new Error("Factorio not found; set FACTORIO_BINARY");
if (!["127.0.0.1", "localhost"].includes(settings.FACTORIO_HOST))
  throw new Error("game:launch configures a local game; launch remote servers on their own host");
// Factorio saves its in-memory configuration on exit and can overwrite external edits.
const windows = process.platform === "win32";
const processes = spawnSync(
  windows ? "tasklist.exe" : "pgrep",
  windows
    ? ["/FI", `IMAGENAME eq ${basename(binary)}`, "/FO", "CSV", "/NH"]
    : ["-x", basename(binary)],
  { encoding: "utf8", windowsHide: true },
);
if (processes.error || processes.status === null || processes.status > (windows ? 0 : 1))
  throw new Error("Could not check whether Factorio is running; configuration was not changed");
const running = windows
  ? processes.stdout
      .toLowerCase()
      .split(/\r?\n/)
      .some((line) => line.startsWith(`"${basename(binary).toLowerCase()}",`))
  : processes.status === 0;
if (running)
  throw new Error(
    "Save your game and close Factorio completely, then run bun run game:launch again. Configuration was not changed.",
  );
const data = dirname(factorioModDirectory());
const source = join(data, "config", "config.ini");
if (!existsSync(source)) throw new Error(`Open Factorio once to create ${source}`);
// Keep the launch profile outside Steam's synced config.ini. Game data and mods stay shared.
const directory = join(LOCAL_DIR, "game");
mkdirSync(directory, { recursive: true });
const config = join(directory, "config.ini");
const backups = join(LOCAL_DIR, "game-config-backups");
mkdirSync(backups, { recursive: true });
const input = existsSync(config) ? config : source;
const original = readFileSync(input, "utf8");
const text = configureLocalGame(original, settings, {
  readData: resolve(dirname(binary), "../../data"),
  writeData: data,
});
if (text !== original || !existsSync(config)) {
  cpSync(input, join(backups, `config-${Date.now()}.ini`));
  writeFileSync(config, text, { mode: 0o600 });
}
const child = spawn(binary, ["--config", config, "--mod-directory", factorioModDirectory()], {
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
