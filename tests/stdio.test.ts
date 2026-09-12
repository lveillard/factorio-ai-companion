import { test, expect } from "bun:test";
import { Client } from "@modelcontextprotocol/client";
import { StdioClientTransport } from "@modelcontextprotocol/client/stdio";
import { join } from "node:path";
import { PROJECT_ROOT } from "../src/config";
import { COMMANDS } from "../src/mcp/schema";

test("stdio entry point speaks the modern MCP protocol without a running game", async () => {
  const client = new Client(
    { name: "stdio-test", version: "1" },
    { versionNegotiation: { mode: { pin: "2026-07-28" } } },
  );
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [join(PROJECT_ROOT, "src/index.ts")],
    cwd: PROJECT_ROOT,
    stderr: "pipe",
  });
  try {
    await client.connect(transport);
    expect((await client.listTools()).tools.length).toBe(Object.keys(COMMANDS).length);
    const result = await client.callTool({ name: "session_status", arguments: {} });
    expect(result.isError).toBe(false);
  } finally {
    await client.close();
  }
}, 15000);
