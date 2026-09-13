import { readdirSync, readFileSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { zipSync } from "fflate";
import pkg from "../package.json";
import mod from "../config/mod.json";
import { PROJECT_ROOT } from "../src/config";
import { generate } from "./generate";

generate(true);
const files: Record<string, Uint8Array> = {};
const prefix = `${mod.name}_${pkg.version}`;
function add(directory: string, relative = "") {
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name),
      name = relative + entry.name;
    if (entry.isDirectory()) add(path, name + "/");
    else files[`${prefix}/${name}`] = readFileSync(path);
  }
}
add(join(PROJECT_ROOT, "factorio-mod"));
mkdirSync(join(PROJECT_ROOT, "dist"), { recursive: true });
const path = join(PROJECT_ROOT, "dist", `${prefix}.zip`);
writeFileSync(path, zipSync(files, { level: 9 }));
console.log(path);
