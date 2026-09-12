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

class FakeCodex extends EventEmitter {
  ready = true;
  workspace = ".";
  calls: string[] = [];
  turnStart?: () => Promise<unknown>;
  async start() {}
  async request(method: string) {
    this.calls.push(method);
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
function fixture() {
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
  const session = new CompanionSession(game, codex as unknown as CodexClient, events, directory);
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
