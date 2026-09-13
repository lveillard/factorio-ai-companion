import { serveStdio } from "@modelcontextprotocol/server/stdio";
import { createMCPServer } from "./mcp/server";
import { RCONClient } from "./rcon/client";
import { getRCONConfig } from "./config";
import { GameBridge } from "./runtime/game";
import { EventLog } from "./runtime/events";

const game = new GameBridge(new RCONClient(getRCONConfig()), new EventLog());
const server = await serveStdio(() => createMCPServer(game), { legacy: "reject" });
const close = async () => {
  await server.close();
  await game.close();
  process.exit(0);
};
process.on("SIGINT", close);
process.on("SIGTERM", close);
process.stdin.on("end", close);
