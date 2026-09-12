import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { strict as assert } from "node:assert";
import { Client, StreamableHTTPClientTransport } from "@modelcontextprotocol/client";
import pkg from "../package.json";

const installed = "C:/Program Files/Docker/Docker/resources/bin/docker.exe";
const binary = process.env.DOCKER_BINARY || (existsSync(installed) ? installed : "docker");
const name = `factorio-smoke-${Date.now()}`,
  volume = `${name}-data`;
const token = crypto.randomUUID() + crypto.randomUUID();
const url = "http://127.0.0.1:33210";
async function docker(args: string[]) {
  const child = spawn(binary, args, {
    windowsHide: true,
    env: { ...process.env, COMPANION_ACCESS_TOKEN: token },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let output = "";
  child.stdout.on("data", (data) => {
    output += data;
  });
  child.stderr.on("data", (data) => {
    output += data;
  });
  const timer = setTimeout(() => child.kill(), 60000);
  const code = await new Promise<number | null>((resolve, reject) => {
    child.on("exit", resolve);
    child.on("error", reject);
  });
  clearTimeout(timer);
  if (code !== 0) throw new Error(`Docker ${args[0]} failed: ${output}`);
  return output.trim();
}
const api = async (path: string, body?: unknown) =>
  fetch(`${url}/api/${path}`, {
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    ...(body === undefined ? {} : { method: "POST", body: JSON.stringify(body) }),
  });
async function ready() {
  const deadline = Date.now() + 30000;
  while (Date.now() < deadline) {
    try {
      if ((await fetch(`${url}/healthz`)).ok) return;
    } catch {}
    await Bun.sleep(250);
  }
  throw new Error("Container did not become healthy");
}
try {
  await docker([
    "run",
    "-d",
    "--name",
    name,
    "--init",
    "-p",
    "127.0.0.1:33210:3210",
    "-e",
    "COMPANION_ACCESS_TOKEN",
    "-e",
    `COMPANION_PUBLIC_URL=${url}`,
    "-v",
    `${volume}:/data`,
    `factorio-ai-companion:${pkg.version}`,
  ]);
  await ready();
  assert.equal((await fetch(`${url}/api/state`)).status, 401);
  assert.equal((await fetch(`${url}/`)).headers.get("set-cookie"), null);
  await Bun.sleep(2000);
  const initial = await (await api("state")).json();
  assert.equal(initial.agent.error, null, JSON.stringify(initial.agent));
  assert.equal(initial.agent.enabled, false);
  assert.equal((await api("chat", { message: "Persist this queued test message" })).status, 202);
  const client = new Client(
    { name: "docker-smoke", version: "1" },
    { versionNegotiation: { mode: { pin: "2026-07-28" } } },
  );
  await client.connect(
    new StreamableHTTPClientTransport(new URL(`${url}/mcp`), {
      requestInit: { headers: { authorization: `Bearer ${token}` } },
    }),
  );
  assert.equal((await client.listTools()).tools.length, initial.tools.length);
  await client.close();
  await docker(["restart", "--time", "15", name]);
  await ready();
  const restored = await (await api("state")).json();
  assert.equal(restored.agent.queued, 1);
  assert.equal(restored.agent.enabled, false);
  assert.equal(await docker(["exec", name, "id", "-u"]), "1000");
  console.log(
    "Docker smoke passed: non-root runtime, Codex startup, HTTP authentication, modern MCP and persistent chat.",
  );
} finally {
  await docker(["rm", "-f", name]).catch(() => {});
  await docker(["volume", "rm", volume]).catch(() => {});
}
