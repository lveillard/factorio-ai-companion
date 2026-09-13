import { existsSync, readFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { applicationUrl, readSettings } from "../config/settings";
import harnesses from "../config/harnesses.json";
import { PROJECT_ROOT } from "../src/config";

const settings = readSettings();
const binary = Bun.which(process.platform === "win32" ? "claude.exe" : "claude");
if (!binary) throw new Error("Install Claude Code before running bun run claude");
const tokenPath = join(resolve(PROJECT_ROOT, settings.COMPANION_DATA_DIR), "server-token");
const token =
  settings.COMPANION_ACCESS_TOKEN ||
  (existsSync(tokenPath) ? readFileSync(tokenPath, "utf8").trim() : "");
if (!token) throw new Error("Run bun run start first, or set COMPANION_ACCESS_TOKEN");
const config = {
  mcpServers: {
    factorio: {
      type: "http",
      url: `${applicationUrl(settings).origin}/mcp`,
      headers: { Authorization: "Bearer ${COMPANION_ACCESS_TOKEN}" },
    },
  },
};
const child = Bun.spawn([binary, "--mcp-config", JSON.stringify(config), ...Bun.argv.slice(2)], {
  cwd: PROJECT_ROOT,
  env: { ...process.env, ...harnesses.claude.env, COMPANION_ACCESS_TOKEN: token },
  stdin: "inherit",
  stdout: "inherit",
  stderr: "inherit",
});
process.exit(await child.exited);
