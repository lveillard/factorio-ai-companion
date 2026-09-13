import { serveStdio } from "@modelcontextprotocol/server/stdio";
import { createMCPServer } from "./mcp/server";
import { RCONClient } from "./rcon/client";
import { getRCONConfig } from "./config";
import { GameBridge } from "./runtime/game";
import { EventLog } from "./runtime/events";
import { FeedbackStore } from "./runtime/feedback";
import { readSettings } from "../config/settings";

const events = new EventLog();
const game = new GameBridge(
  new RCONClient(getRCONConfig()),
  events,
  new FeedbackStore(readSettings(), events),
);
const server = await serveStdio(() => createMCPServer(game), { legacy: "reject" });
const close = async () => {
  await server.close();
  await game.close();
  process.exit(0);
};
process.on("SIGINT", close);
process.on("SIGTERM", close);
process.stdin.on("end", close);
