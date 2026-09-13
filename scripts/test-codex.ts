import { join } from "node:path";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { CodexClient, textInput } from "../src/codex/client";
import { strict as assert } from "node:assert";
import { generateToolSchemas } from "../src/mcp/schema";
import { LOCAL_DIR } from "../src/config";
import harnesses from "../config/harnesses.json";
import { createMCPHttp } from "../src/mcp/server";
import { GameBridge } from "../src/runtime/game";
import { RCONClient } from "../src/rcon/client";
import { EventLog } from "../src/runtime/events";

mkdirSync(LOCAL_DIR, { recursive: true });
const home = mkdtempSync(join(LOCAL_DIR, "codex-smoke-"));
// Discovery and the session tool do not connect to a game.
const game = new GameBridge(
  new RCONClient({ host: "127.0.0.1", port: 1, password: "unused" }),
  new EventLog(),
);
const mcp = createMCPHttp(game);
const token = crypto.randomUUID();
const http = Bun.serve({
  hostname: "127.0.0.1",
  port: 0,
  fetch: (request) =>
    request.headers.get("authorization") === `Bearer ${token}`
      ? mcp.fetch(request)
      : new Response("Unauthorized", { status: 401 }),
});
writeFileSync(
  join(home, "config.toml"),
  [
    "[features]",
    ...Object.entries(harnesses.codex.features).map(([key, value]) => `${key} = ${value}`),
    "[mcp_servers.factorio]",
    `url = "http://127.0.0.1:${http.port}/mcp"`,
    "required = true",
    "[mcp_servers.factorio.http_headers]",
    `Authorization = "Bearer ${token}"`,
    "",
  ].join("\n"),
  { mode: 0o600 },
);
const client = new CodexClient({
  home,
  workspace: join(home, "workspace"),
});
try {
  await client.start();
  const account = await client.request<{ account: { type: string } | null }>("account/read", {
    refreshToken: false,
  });
  const models = await client.request<{ data: unknown[] }>("model/list", {});
  const result = await client.request<{ thread: { id: string } }>("thread/start", {
    ephemeral: true,
    cwd: client.workspace,
    sandbox: "read-only",
    approvalPolicy: "never",
    baseInstructions: "Protocol smoke test. Do not run a turn.",
    dynamicTools: [
      {
        type: "namespace",
        name: "factorio",
        description: "Factorio tools",
        tools: generateToolSchemas().map((tool) => ({ type: "function", ...tool })),
      },
    ],
  });
  console.log(
    `Codex handshake, account/read (${account.account?.type || "signed out"}), model/list (${models.data.length}) and dynamic tools accepted.`,
  );
  if (!result.thread.id) throw new Error("No thread ID returned");
  const servers = await client.request<{
    data: Array<{ name: string; tools: Record<string, unknown>; toolsError: string | null }>;
  }>("mcpServerStatus/list", { threadId: result.thread.id, detail: "toolsAndAuthOnly" });
  const factorio = servers.data.find((server) => server.name === "factorio");
  assert.ok(factorio, "Codex must discover the HTTP MCP server");
  assert.equal(factorio.toolsError, null);
  assert.equal(Object.keys(factorio.tools).length, generateToolSchemas().length);
  console.log(
    `Codex discovered all ${Object.keys(factorio.tools).length} tools over modern HTTP MCP.`,
  );
  // An unknown thread validates the turn payload without starting inference.
  await assert.rejects(
    client.request("turn/start", {
      threadId: crypto.randomUUID(),
      input: [textInput("Protocol validation only")],
    }),
    /thread.*not found|not found.*thread/i,
  );
  console.log("Turn input deserialization verified without inference.");
} finally {
  await client.close();
  await mcp.close();
  await game.close();
  await http.stop(true);
}
