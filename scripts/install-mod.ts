import {
  cpSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { join, resolve, relative, isAbsolute } from "node:path";
import { factorioModDirectory } from "./paths";
import { PROJECT_ROOT } from "../src/config";
import { generate } from "./generate";
import pkg from "../package.json";

generate(true);
const mods = resolve(factorioModDirectory());
mkdirSync(mods, { recursive: true });
const destination = join(mods, "ai-companion");
const backups = join(PROJECT_ROOT, ".local", "mod-backups");
mkdirSync(backups, { recursive: true });
const inside = relative(mods, destination);
if (inside.startsWith("..") || isAbsolute(inside))
  throw new Error("Mod destination escaped the configured directory");
for (const entry of readdirSync(mods)) {
  if (entry !== "ai-companion" && !/^ai-companion_\d+\.\d+\.\d+(?:\.zip)?$/.test(entry)) continue;
  const source = resolve(mods, entry),
    within = relative(mods, source);
  if (!within || within.startsWith("..") || isAbsolute(within))
    throw new Error("Invalid mod backup source");
  const backup = join(backups, `${Date.now()}-${entry}`);
  cpSync(source, backup, { recursive: true });
  // Only the exact, validated companion installation is removed after its backup succeeds.
  rmSync(source, { recursive: true });
}
cpSync(join(PROJECT_ROOT, "factorio-mod"), destination, { recursive: true });
const listPath = join(mods, "mod-list.json");
const list = existsSync(listPath)
  ? (JSON.parse(readFileSync(listPath, "utf8")) as {
      mods: Array<{ name: string; enabled: boolean; version?: string }>;
    })
  : { mods: [{ name: "base", enabled: true }] };
const existing = list.mods.find((mod) => mod.name === "ai-companion");
if (existing) {
  existing.enabled = true;
  delete existing.version;
} else list.mods.push({ name: "ai-companion", enabled: true });
if (existsSync(listPath))
  cpSync(listPath, join(PROJECT_ROOT, ".local/mod-backups", `mod-list-${Date.now()}.json`));
writeFileSync(listPath, JSON.stringify(list, null, 2) + "\n");
console.log(`Installed AI Companion ${pkg.version}: ${destination}`);
console.log(
  "Restart Factorio to load the updated mod. Existing saves and other mods are unchanged.",
);
