import { test, expect } from "bun:test";
import { Client } from "@modelcontextprotocol/client";
import { StdioClientTransport } from "@modelcontextprotocol/client/stdio";
import { join } from "node:path";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { PROJECT_ROOT } from "../src/config";
import { COMMANDS } from "../src/mcp/schema";

test("stdio entry point speaks the modern MCP protocol without a running game", async () => {
  const directory = mkdtempSync(join(tmpdir(), "factorio-stdio-"));
  const client = new Client(
    { name: "stdio-test", version: "1" },
    { versionNegotiation: { mode: { pin: "2026-07-28" } } },
  );
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [join(PROJECT_ROOT, "src/index.ts")],
    cwd: PROJECT_ROOT,
    stderr: "pipe",
    env: {
      COMPANION_DATA_DIR: directory,
      FEEDBACK_GITHUB_REPOSITORY: "",
      FEEDBACK_GITHUB_TOKEN: "",
    },
  });
  try {
    await client.connect(transport);
    expect((await client.listTools()).tools.length).toBe(Object.keys(COMMANDS).length);
    const result = await client.callTool({ name: "session_status", arguments: {} });
    expect(result.isError).toBe(false);
    expect((await client.callTool({ name: "feedback_list", arguments: {} })).isError).toBe(false);
  } finally {
    await client.close();
    rmSync(directory, { recursive: true });
  }
}, 15000);
