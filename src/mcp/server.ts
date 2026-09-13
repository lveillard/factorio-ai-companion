import { McpServer, createMcpHandler, fromJsonSchema } from "@modelcontextprotocol/server";
import { COMMANDS } from "./schema";
import type { GameBridge } from "../runtime/game";
import pkg from "../../package.json";

export function createMCPServer(game: GameBridge): McpServer {
  const server = new McpServer({ name: pkg.name, version: pkg.version });
  for (const tool of game.schemas) {
    const { name } = tool;
    const definition = COMMANDS[name]!;
    server.registerTool(
      name,
      {
        description: tool.description,
        inputSchema: fromJsonSchema(tool.inputSchema),
        annotations: {
          readOnlyHint: definition.effect === "read",
          destructiveHint: definition.effect === "act",
          openWorldHint: definition.effect === "report",
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
