import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import luaparse from "luaparse";
import { COMMANDS } from "../src/mcp/schema";
import { generate } from "./generate";
import { PROJECT_ROOT } from "../src/config";

generate(true);
const directory = join(PROJECT_ROOT, "factorio-mod/commands");
const handlers = new Set<string>();
for (const file of readdirSync(directory).filter((file) => file.endsWith(".lua"))) {
  const source = readFileSync(join(directory, file), "utf8");
  luaparse.parse(source, { luaVersion: "5.2" });
  for (const match of source.matchAll(/u\.register\("([^"]+)"/g)) {
    if (handlers.has(match[1]!)) throw new Error(`Duplicate handler: ${match[1]}`);
    handlers.add(match[1]!);
  }
}
luaparse.parse(readFileSync(join(PROJECT_ROOT, "factorio-mod/control.lua"), "utf8"), {
  luaVersion: "5.2",
});
for (const [name, definition] of Object.entries(COMMANDS)) {
  if ((definition.execution === "game") !== handlers.has(name))
    throw new Error(`Handler mismatch: ${name}`);
  for (const before of definition.before || [])
    if (!Object.hasOwn(COMMANDS, before)) throw new Error(`Unknown precondition ${before}`);
}
for (const handler of handlers)
  if (!Object.hasOwn(COMMANDS, handler)) throw new Error(`Undocumented handler ${handler}`);
console.log(
  `${Object.keys(COMMANDS).length} commands: generated contract, Lua syntax and handlers verified.`,
);
