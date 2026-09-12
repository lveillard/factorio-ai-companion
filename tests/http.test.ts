import { test, expect } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Client, StreamableHTTPClientTransport } from "@modelcontextprotocol/client";
import { createApplication } from "../src/dashboard/server";
import { readSettings } from "../config/settings";
import { COMMANDS } from "../src/mcp/schema";

test("modern MCP HTTP exposes the canonical tools and rejects unauthenticated/legacy requests", async () => {
  const directory = mkdtempSync(join(tmpdir(), "factorio-http-"));
  const token = "test-token-".padEnd(64, "a");
  const settings = readSettings({
    COMPANION_DATA_DIR: directory,
    COMPANION_ACCESS_TOKEN: token,
    COMPANION_PORT: "3219",
  });
  const app = createApplication(settings);
  const request = (path: string, options: RequestInit = {}) =>
    app.fetch(new Request(`http://localhost:3219${path}`, options));
  const client = new Client(
    { name: "test", version: "1" },
    { versionNegotiation: { mode: { pin: "2026-07-28" } } },
  );
  try {
    expect((await request("/mcp")).status).toBe(401);
    expect((await request("/api/state")).status).toBe(401);
    expect(() =>
      createApplication(
        readSettings({
          COMPANION_DATA_DIR: directory,
          COMPANION_PUBLIC_URL: "https://companion.example",
        }),
      ),
    ).toThrow("COMPANION_ACCESS_TOKEN");
    expect(
      (
        await request("/api/state", {
          headers: { authorization: `Bearer ${token}`, origin: "https://evil.example" },
        })
      ).status,
    ).toBe(403);
    expect(
      (await request("/api/state", { headers: { authorization: `Bearer ${"é".repeat(64)}` } }))
        .status,
    ).toBe(401);
    const transport = new StreamableHTTPClientTransport(new URL("http://localhost:3219/mcp"), {
      requestInit: { headers: { authorization: `Bearer ${token}` } },
      fetch: async (input, init) => app.fetch(new Request(input, init)),
    });
    await client.connect(transport);
    const list = await client.listTools();
    expect(list.tools.map((tool) => tool.name).sort()).toEqual(Object.keys(COMMANDS).sort());
    const status = await client.callTool({ name: "session_status", arguments: {} });
    expect(status.isError).toBe(false);
    const failed = await client.callTool({
      name: "companion_stop",
      arguments: { companionId: -1 },
    });
    expect(failed.isError).toBe(true);
    const legacy = await request("/mcp", {
      method: "POST",
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/json",
        accept: "application/json, text/event-stream",
      },
      body: JSON.stringify({
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: {
          protocolVersion: "2025-11-25",
          clientInfo: { name: "legacy", version: "1" },
          capabilities: {},
        },
      }),
    });
    expect(legacy.status).toBeGreaterThanOrEqual(400);
  } finally {
    await client.close();
    await app.close();
    rmSync(directory, { recursive: true });
  }
}, 15000);
