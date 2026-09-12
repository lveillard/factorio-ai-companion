import { test, expect } from "bun:test";
import { EventEmitter } from "node:events";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { CompanionSession } from "../src/runtime/session";
import { EventLog } from "../src/runtime/events";
import { GameBridge } from "../src/runtime/game";
import type { CodexClient } from "../src/codex/client";
import type { RCONClient } from "../src/rcon/client";
import { readSettings } from "../config/settings";

class FakeCodex extends EventEmitter {
  ready = true;
  workspace = ".";
  calls: string[] = [];
  requests: Array<{ method: string; params?: Record<string, unknown> }> = [];
  turnStart?: () => Promise<unknown>;
  async start() {}
  async request(method: string, params?: Record<string, unknown>) {
    this.calls.push(method);
    this.requests.push({ method, params });
    if (method === "account/read") return { account: { type: "chatgpt" } };
    if (method === "model/list") return { data: [] };
    if (method === "thread/start") return { thread: { id: "thread1" } };
    if (method === "turn/start")
      return this.turnStart ? this.turnStart() : { turn: { id: "turn1" } };
    return {};
  }
  async close() {}
  respond() {}
  reject() {}
}
function fixture(
  overrides: Partial<NonNullable<ConstructorParameters<typeof CompanionSession>[4]>> = {},
) {
  const directory = mkdtempSync(join(tmpdir(), "factorio-session-"));
  const events = new EventLog();
  const rcon = {
    sendCommand: async () => ({
      success: true,
      data: JSON.stringify({ version: "0.17.0", session_id: "world1", tick: 1, companions: [] }),
    }),
    isConnected: () => true,
    disconnect: async () => {},
  } as unknown as RCONClient;
  const game = new GameBridge(rcon, events),
    codex = new FakeCodex();
  const defaults = readSettings({});
  const session = new CompanionSession(game, codex as unknown as CodexClient, events, directory, {
    pollMs: defaults.POLL_INTERVAL_MS,
    turnMs: defaults.TURN_TIMEOUT_MS,
    maxToolCalls: defaults.MAX_TOOL_CALLS,
    maxQueued: defaults.MAX_QUEUED_MESSAGES,
    maxContinuations: defaults.MAX_JOB_CONTINUATIONS,
    jobReviewMs: defaults.JOB_REVIEW_TIMEOUT_MS,
    ...overrides,
  });
  return {
    directory,
    events,
    game,
    codex,
    session,
    close: async () => {
      await session.close();
      rmSync(directory, { recursive: true });
    },
  };
}
test("game message identity is persisted before work; duplicate ingest is idempotent", async () => {
  const f = fixture();
  try {
    f.session.enqueue("Ayúdame", 1, "game", "Player", "game:world:7");
    f.session.enqueue("Ayúdame", 1, "game", "Player", "game:world:7");
    const saved = JSON.parse(readFileSync(join(f.directory, "session.json"), "utf8"));
    expect(saved.messages).toHaveLength(1);
    expect(saved.messages[0].id).toBe("game:world:7");
    expect(f.codex.calls).not.toContain("turn/start");
  } finally {
    await f.close();
  }
});
test("restart preserves chat but never replays an interrupted mutation", async () => {
  const f = fixture();
  try {
    f.session.enqueue("Construye", 1);
    await f.session.resume();
    const restored = new CompanionSession(
      f.game,
      new FakeCodex() as unknown as CodexClient,
      f.events,
      f.directory,
    );
    expect(restored.status().enabled).toBe(false);
    expect(restored.status().messages[0]!.status).toBe("failed");
    expect(restored.status().messages[0]!.error).toContain("not repeated");
    await restored.close();
  } finally {
    await f.close();
  }
});
test("pausing while turn/start is pending interrupts the late-starting turn", async () => {
  const f = fixture();
  try {
    let complete!: (value: unknown) => void;
    f.codex.turnStart = () =>
      new Promise((resolve) => {
        complete = resolve;
      });
    f.session.enqueue("Camina", 1);
    const starting = f.session.resume();
    while (!complete) await Bun.sleep(1);
    await f.session.pause(false);
    complete({ turn: { id: "late-turn" } });
    await starting;
    expect(f.codex.calls).toContain("turn/interrupt");
    expect(f.session.status().messages[0]!.status).toBe("cancelled");
    expect(f.session.status().busy).toBe(false);
  } finally {
    await f.close();
  }
});
test("queued game commands recheck cancellation at execution time", async () => {
  const f = fixture();
  try {
    let allowed = true;
    const pending = f.game.execute("companion_stop", { companionId: 1 }, "codex", () => allowed);
    allowed = false;
    expect(await pending).toEqual({ success: false, error: "Action cancelled before execution" });
  } finally {
    await f.close();
  }
});

test("final game replies retain the addressed companion, including the coordinator", async () => {
  for (const companionId of [0, 1, 2]) {
    const f = fixture();
    try {
      f.session.enqueue("¿Qué estás haciendo?", companionId);
      await f.session.resume();
      f.codex.emit("notification", {
        method: "item/completed",
        params: {
          threadId: "thread1",
          turnId: "turn1",
          item: { type: "agentMessage", text: "Estoy minando.", phase: "final_answer" },
        },
      });
      f.codex.emit("notification", {
        method: "turn/completed",
        params: { threadId: "thread1", turn: { id: "turn1", status: "completed" } },
      });
      for (let attempt = 0; attempt < 100 && f.session.status().busy; attempt++) await Bun.sleep(1);
      expect(f.session.status().busy).toBe(false);
      const replies = f.events.recent.filter(
        (event) =>
          event.type === "tool.started" && (event.data as { name: string }).name === "chat_say",
      );
      expect(replies).toHaveLength(1);
      expect((replies[0]!.data as { args: unknown }).args).toEqual({
        companionId,
        message: "Estoy minando.",
      });
    } finally {
      await f.close();
    }
  }
});

for (const finishesBeforeReply of [false, true])
  test(`native jobs wake the agent even when finished before reply: ${finishesBeforeReply}`, async () => {
    const f = fixture();
    try {
      const snapshot = await f.game.observe(1);
      snapshot.companions = [{ id: 1, queues: { gather: { active: true } } }];
      f.game.observe = async () => snapshot;
      f.session.enqueue("Mina hierro y prepara el horno", 1);
      await f.session.resume();
      f.codex.emit("request", {
        id: "gather1",
        method: "item/tool/call",
        params: {
          threadId: "thread1",
          turnId: "turn1",
          namespace: "factorio",
          tool: "gather",
          arguments: { companionId: 1, resource: "iron-ore", count: 60 },
        },
      });
      await Bun.sleep(10);
      if (finishesBeforeReply) snapshot.companions[0]!.queues = {};
      f.codex.emit("notification", {
        method: "turn/completed",
        params: { threadId: "thread1", turn: { id: "turn1", status: "completed" } },
      });
      await Bun.sleep(10);
      expect(f.session.status().messages[0]!.status).toBe("waiting");
      if (!finishesBeforeReply) {
        await f.session["poll"]();
        expect(f.codex.calls.filter((m) => m === "turn/start")).toHaveLength(1);
      }
      snapshot.companions[0]!.queues = {};
      await f.session["poll"]();
      await Bun.sleep(10);
      expect(f.codex.calls.filter((m) => m === "turn/start")).toHaveLength(2);
      expect(f.session.status().messages[0]!.continuations).toBe(1);
      await f.session["poll"]();
      expect(f.codex.calls.filter((m) => m === "turn/start")).toHaveLength(2);
      snapshot.companions[0]!.queues = { gather: { active: true } };
      f.codex.emit("request", {
        id: "gather2",
        method: "item/tool/call",
        params: {
          threadId: "thread1",
          turnId: "turn1",
          namespace: "factorio",
          tool: "gather",
          arguments: { companionId: 1, resource: "iron-ore", count: 27 },
        },
      });
      await Bun.sleep(10);
      f.codex.emit("notification", {
        method: "turn/completed",
        params: { threadId: "thread1", turn: { id: "turn1", status: "completed" } },
      });
      await Bun.sleep(10);
      expect(f.session.status().messages[0]!.status).toBe("waiting");
      await f.session.pause(false);
      snapshot.companions[0]!.queues = {};
      await f.session["poll"]();
      await f.session.resume();
      expect(f.session.status().messages[0]!.status).toBe("cancelled");
      expect(f.codex.calls.filter((m) => m === "turn/start")).toHaveLength(2);
    } finally {
      await f.close();
    }
  });

async function act(f: ReturnType<typeof fixture>, tool = "gather", companionId = 1) {
  await f.session["request"]({
    id: crypto.randomUUID(),
    method: "item/tool/call",
    params: {
      threadId: "thread1",
      turnId: "turn1",
      namespace: "factorio",
      tool,
      arguments:
        tool === "gather" ? { companionId, resource: "iron-ore", count: 60 } : { companionId },
    },
  });
}
async function complete(f: ReturnType<typeof fixture>, status = "completed") {
  await f.session["notification"]({
    method: "turn/completed",
    params: { threadId: "thread1", turn: { id: "turn1", status } },
  });
}
async function pendingJob(f: ReturnType<typeof fixture>) {
  const snapshot = await f.game.observe(1);
  snapshot.companions = [{ id: 1, queues: { gather: { active: true } } }];
  f.game.observe = async () => snapshot;
  f.session.enqueue("Mina hierro y monta la fábrica", 1);
  await f.session.resume();
  await act(f);
  await complete(f);
  expect(f.session.status().messages[0]!.status).toBe("waiting");
  return snapshot;
}

test("manual controls replace pending work only for the addressed companion", async () => {
  const f = fixture();
  try {
    await pendingJob(f);
    const original = f.session.status().messages[0]!;
    original.companionId = 0;
    await f.session.manualTool("gather_status", { companionId: 1 });
    await f.session.manualTool("companion_spawn", { companionId: 2, name: "Ada" });
    await f.session.manualTool("companion_stop", { companionId: 2 });
    expect(original.status).toBe("waiting");
    await f.session.manualTool("companion_stop", { companionId: 1 });
    expect(original.status).toBe("cancelled");
    await f.session["poll"]();
    expect(f.codex.calls.filter((m) => m === "turn/start")).toHaveLength(1);
  } finally {
    await f.close();
  }
});

test("manual stop still reaches the game when Codex interruption fails", async () => {
  const f = fixture();
  try {
    f.session.enqueue("Mine iron", 1);
    await f.session.resume();
    f.codex.request = async () => {
      throw new Error("Codex disconnected");
    };
    expect((await f.session.manualTool("companion_stop", { companionId: 1 })).success).toBe(true);
    expect(f.session.status().messages[0]!.status).toBe("cancelled");
    expect(f.session.status().busy).toBe(false);
    expect(
      f.events.recent.some(
        (e) =>
          e.type === "tool.completed" && (e.data as { name: string }).name === "companion_stop",
      ),
    ).toBe(true);
  } finally {
    await f.close();
  }
});

test("manual stop cancels a queued turn while observation is still in flight", async () => {
  const f = fixture();
  try {
    const snapshot = await f.game.observe();
    let observed!: () => void;
    f.game.observe = () =>
      new Promise((resolve) => {
        observed = () => resolve(snapshot);
      });
    f.session.enqueue("Mine iron", 1);
    const starting = f.session.resume();
    while (!observed) await Bun.sleep(1);
    await f.session.manualTool("companion_stop", { companionId: 1 });
    observed();
    await starting;
    expect(f.session.status().messages[0]!.status).toBe("cancelled");
    expect(f.codex.calls).not.toContain("turn/start");
  } finally {
    await f.close();
  }
});

test("a turn observes its target companion and sends compact terrain with full state", async () => {
  const f = fixture();
  try {
    const snapshot = await f.game.observe();
    snapshot.center = { x: 0, y: 0 };
    snapshot.entities = [{ name: "coal", type: "resource", amount: 30, position: { x: 2, y: 3 } }];
    let observed: number | undefined;
    f.game.observe = async (id) => {
      observed = id;
      return snapshot;
    };
    f.session.focus = 2;
    f.session.enqueue("Mine coal", 1);
    await f.session.resume();
    expect(observed).toBe(1);
    const input = f.codex.requests.find((r) => r.method === "turn/start")!.params!.input as Array<{
      text: string;
    }>;
    expect(input[0]!.text).toContain('"sampled_amount":30');
    expect(input[0]!.text).toContain('"detail_tool":"world_observe"');
    expect(snapshot.entities).toHaveLength(1);
  } finally {
    await f.close();
  }
});
test("questions preserve the pending objective; redirecting that companion replaces it", async () => {
  const f = fixture();
  try {
    await pendingJob(f);
    f.session.enqueue("¿Cómo vas?", 1);
    await f.session.resume();
    await complete(f);
    expect(f.session.status().messages[0]!.status).toBe("waiting");
    f.session.enqueue("Para", 1);
    await f.session.resume();
    await act(f, "companion_stop");
    await complete(f);
    expect(f.session.status().messages[0]!.status).toBe("cancelled");
    expect(f.session.status().waiting).toBe(0);
    expect(f.session.status().queued).toBe(0);
  } finally {
    await f.close();
  }
});
test("acting on another companion does not discard the first companion's job", async () => {
  const f = fixture();
  try {
    await pendingJob(f);
    f.session.enqueue("Para", 2);
    await f.session.resume();
    await act(f, "companion_stop", 2);
    await complete(f);
    expect(f.session.status().messages[0]!.status).toBe("waiting");
  } finally {
    await f.close();
  }
});
test("native job review has a bounded continuation budget", async () => {
  const f = fixture({ maxContinuations: 0 });
  try {
    f.session.enqueue("Mina", 1);
    await f.session.resume();
    await act(f);
    await complete(f);
    expect(f.session.status().messages[0]!.status).toBe("failed");
    expect(f.session.status().messages[0]!.error).toContain("limit reached");
    await f.session["poll"]();
    expect(f.codex.calls.filter((m) => m === "turn/start")).toHaveLength(1);
  } finally {
    await f.close();
  }
});
test("waiting survives temporary disconnect and reviews stuck jobs after its deadline", async () => {
  const f = fixture();
  try {
    const snapshot = await pendingJob(f);
    f.game.observe = async () => {
      throw new Error("offline");
    };
    await f.session["poll"]();
    expect(f.session.status().messages[0]!.status).toBe("waiting");
    f.game.observe = async () => snapshot;
    f.session.status().messages[0]!.reviewAt = Date.now() - 1;
    snapshot.paused = true;
    await f.session["poll"]();
    expect(f.session.status().messages[0]!.status).toBe("waiting");
    snapshot.paused = false;
    await f.session["poll"]();
    await f.session.resume();
    expect(f.codex.calls.filter((m) => m === "turn/start")).toHaveLength(2);
  } finally {
    await f.close();
  }
});
test("a pending compound task counts as work even when its native queue is empty", async () => {
  const f = fixture();
  try {
    const snapshot = await pendingJob(f);
    snapshot.companions[0]!.queues = {};
    snapshot.tasks = [{ companionId: 1, status: "active" }];
    await f.session["poll"]();
    expect(f.session.status().messages[0]!.status).toBe("waiting");
    snapshot.tasks = [];
    await f.session["poll"]();
    await f.session.resume();
    expect(f.codex.calls.filter((m) => m === "turn/start")).toHaveLength(2);
  } finally {
    await f.close();
  }
});
test("duplicate ingestion remains idempotent when the queue is full", async () => {
  const f = fixture({ maxQueued: 1 });
  try {
    const first = f.session.enqueue("Mina", 1, "game", "Player", "game:world:1");
    expect(f.session.enqueue("Mina", 1, "game", "Player", "game:world:1")).toBe(first);
    expect(() => f.session.enqueue("Otra", 1)).toThrow("full");
  } finally {
    await f.close();
  }
});
test("history retention does not drop an unfinished objective", async () => {
  const f = fixture();
  try {
    await pendingJob(f);
    for (let i = 0; i < 510; i++)
      f.session.status().messages.push({
        id: String(i),
        at: "",
        role: "assistant",
        text: "ok",
        source: "web",
        companionId: 1,
      });
    f.session.enqueue("Pregunta", 2);
    const saved = JSON.parse(readFileSync(join(f.directory, "session.json"), "utf8"));
    expect(saved.messages.some((m: { status: string }) => m.status === "waiting")).toBe(true);
    expect(saved.messages).toHaveLength(500);
  } finally {
    await f.close();
  }
});
