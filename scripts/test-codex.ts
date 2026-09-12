import { join } from "node:path";
import { CodexClient, textInput } from "../src/codex/client";
import { strict as assert } from "node:assert";
import { generateToolSchemas } from "../src/mcp/schema";
import { LOCAL_DIR } from "../src/config";

const client = new CodexClient({
  home: join(LOCAL_DIR, "codex-smoke"),
  workspace: join(LOCAL_DIR, "agent-smoke"),
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
}
