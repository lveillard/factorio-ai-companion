import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { readSettings } from "../config/settings";

export function factorioBinary(): string | null {
  const settings = readSettings();
  const candidates = [
    settings.FACTORIO_BINARY,
    "C:/Program Files (x86)/Steam/steamapps/common/Factorio/bin/x64/factorio.exe",
    "/opt/factorio/bin/x64/factorio",
    join(homedir(), ".steam/steam/steamapps/common/Factorio/bin/x64/factorio"),
    "/Applications/factorio.app/Contents/MacOS/factorio",
  ];
  return candidates.find((path) => path && existsSync(path)) || null;
}
export function factorioModDirectory(): string {
  const explicit = readSettings().FACTORIO_MOD_DIR;
  if (explicit) return explicit;
  if (process.platform === "win32")
    return join(process.env.APPDATA || join(homedir(), "AppData/Roaming"), "Factorio/mods");
  if (process.platform === "darwin")
    return join(homedir(), "Library/Application Support/factorio/mods");
  return join(homedir(), ".factorio/mods");
}
