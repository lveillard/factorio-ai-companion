import { McpServer, createMcpHandler, fromJsonSchema } from "@modelcontextprotocol/server";
import { COMMANDS } from "./schema";
import type { GameBridge } from "../runtime/game";
import pkg from "../../package.json";

export function createMCPServer(game: GameBridge): McpServer {
  const server = new McpServer({ name: pkg.name, version: pkg.version });
  for (const [name, definition] of Object.entries(COMMANDS)) {
    server.registerTool(
      name,
      {
        description: definition.description,
        inputSchema: fromJsonSchema(definition.inputSchema),
        annotations: {
          readOnlyHint: definition.effect === "read",
          destructiveHint: definition.effect === "act",
          openWorldHint: false,
        },
      },
      async (args) => {
        const result = await game.execute(name, args, "mcp");
        return {
          isError: !result.success,
          content: [{ type: "text" as const, text: JSON.stringify(result) }],
        };
      },
    );
  }
  return server;
}

export function createMCPHttp(game: GameBridge) {
  return createMcpHandler(() => createMCPServer(game), {
    legacy: "reject",
    responseMode: "auto",
    maxSubscriptions: 16,
  });
}
