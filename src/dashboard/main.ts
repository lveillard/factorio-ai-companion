import { createApplication } from "./server";
import { readSettings } from "../../config/settings";

const settings = readSettings();
const app = createApplication(settings);
const server = Bun.serve({
  hostname: settings.COMPANION_HOST,
  port: settings.COMPANION_PORT,
  idleTimeout: 60,
  maxRequestBodySize: 128 * 1024,
  fetch: app.fetch,
});
console.log(`Factorio AI Companion: ${app.url}`);
console.log(`MCP Streamable HTTP: ${app.url}/mcp (Bearer authentication)`);
void app.session.start();
let closing = false;
const close = async () => {
  if (closing) return;
  closing = true;
  await app.close();
  await server.stop(true);
  process.exit(0);
};
process.on("SIGINT", close);
process.on("SIGTERM", close);
