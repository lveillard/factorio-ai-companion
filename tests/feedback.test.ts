import { test, expect } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readSettings } from "../config/settings";
import { FeedbackStore } from "../src/runtime/feedback";
import { EventLog } from "../src/runtime/events";
import { GameBridge } from "../src/runtime/game";
import type { RCONClient } from "../src/rcon/client";

const report = {
  key: "research-trigger-not-exposed",
  title: "Trigger research looks like science research",
  category: "capability",
  expected: "Show the trigger and prerequisites",
  actual: "Research tool omits the trigger",
  reproduction: "Call research_get before electronics is unlocked",
};
function fixture(repository = "owner/repo") {
  const directory = mkdtempSync(join(tmpdir(), "factorio-feedback-"));
  const events = new EventLog();
  const settings = readSettings({
    COMPANION_DATA_DIR: directory,
    FEEDBACK_GITHUB_REPOSITORY: repository,
    FACTORIO_RCON_PASSWORD: 'private"password',
  });
  type Issue = { number: number; state: string; body: string };
  const issues: Issue[] = [];
  const calls: Array<{ path: string; method: string; body?: Record<string, unknown> }> = [];
  let intercept: ((method: string) => Promise<Response | void>) | undefined;
  const request = (async (input: string | URL | Request, init: RequestInit = {}) => {
    expect(String(input).startsWith("https://api.github.com/repos/owner/repo/")).toBe(true);
    expect(init.redirect).toBe("error");
    const method = init.method || "GET",
      path = new URL(String(input)).pathname;
    const body = init.body ? JSON.parse(String(init.body)) : undefined;
    calls.push({ method, path, body });
    const response = await intercept?.(method);
    if (response) return response;
    if (method === "POST") {
      const issue = { number: issues.length + 1, state: "open", body: body.body };
      issues.push(issue);
      return Response.json(issue, { status: 201 });
    }
    const number = Number(path.split("/").at(-1));
    if (method === "PATCH")
      Object.assign(
        issues.find((i) => i.number === number)!,
        body,
      );
    return Response.json(number ? issues.find((i) => i.number === number) : issues);
  }) as typeof fetch;
  const stores: FeedbackStore[] = [];
  const open = () => {
    const store = new FeedbackStore(settings, events, {
      automatic: false,
      fetch: request,
      token: async () => "ghp_testsecret",
    });
    stores.push(store);
    return store;
  };
  return {
    events,
    settings,
    issues,
    calls,
    open,
    store: open(),
    setIntercept: (f: typeof intercept) => {
      intercept = f;
    },
    close: async () => {
      for (const store of stores) await store.close();
      rmSync(directory, { recursive: true });
    },
  };
}

test("reports survive restart, deduplicate and exclude chat, names, arguments and known secrets", async () => {
  const f = fixture("");
  try {
    f.events.emit("tool.completed", {
      name: "gather",
      success: false,
      source: "codex",
      args: { message: "private transcript" },
      error: "private transcript",
    });
    f.store.report(
      {
        ...report,
        actual: 'private"password ghp_notpublic person@example.com C:\\Users\\Private\\file',
        suggestion: "https://user:pass@example.com/path?token=hidden",
      },
      null,
    );
    await f.store.close();
    const store = f.open();
    const saved = JSON.stringify(store.list({ key: report.key }));
    for (const text of [
      'private\\"password',
      "ghp_notpublic",
      "person@example.com",
      "Private",
      "private transcript",
      "user:pass",
      "token=hidden",
    ])
      expect(saved).not.toContain(text);
    expect(saved).toContain('"tool":"gather"');
    expect(saved).toContain("https://example.com/path");
    expect(store.report(report, null).occurrences).toBe(2);
    expect(store.list().reports).toHaveLength(1);
    await store.sync();
    expect(f.calls).toHaveLength(0);
  } finally {
    await f.close();
  }
});

test("sync coalesces repeats, preserves reviewer notes and reads closed state without reopening", async () => {
  const f = fixture();
  try {
    f.store.report(report, null);
    f.store.report(report, null);
    await f.store.sync();
    expect(f.issues).toHaveLength(1);
    expect(f.issues[0]!.body).toContain("Occurrences: 2");
    f.issues[0]!.body += "\n\nReviewer: fixed by PR #42";
    f.issues[0]!.state = "closed";
    f.store.report(report, null);
    await f.store.sync();
    expect(f.issues).toHaveLength(1);
    expect(f.issues[0]!.body).toContain("Reviewer: fixed by PR #42");
    expect(f.issues[0]!.body).toContain("Occurrences: 3");
    expect(f.store.list().reports[0]).toMatchObject({
      occurrences: 3,
      state: "closed",
      pending: false,
      url: "https://github.com/owner/repo/issues/1",
    });
    expect(f.calls.filter((c) => c.method === "PATCH")[0]!.body).not.toHaveProperty("state");
    f.issues[0]!.state = "open";
    await f.store.sync();
    expect(f.store.list().reports[0]!.state).toBe("open");
  } finally {
    await f.close();
  }
});

test("missing credentials / definite GitHub rejection retain reports and permit safe retry", async () => {
  const f = fixture();
  try {
    f.store.report(report, null);
    f.setIntercept(async (method) =>
      method === "POST" ? new Response("denied", { status: 403 }) : undefined,
    );
    await f.store.sync();
    expect(f.store.list().reports[0]).toMatchObject({ state: "pending", pending: true });
    f.setIntercept(undefined);
    await f.store.sync();
    expect(f.store.list().reports[0]).toMatchObject({ state: "open", error: null });
  } finally {
    await f.close();
  }
});

test("ambiguous create survives restart and reconciles its marker without duplicate POSTs", async () => {
  const f = fixture();
  try {
    f.store.report(report, null);
    f.setIntercept(async (method) => {
      if (method === "POST") throw new Error("Socket closed ghp_testsecret");
    });
    await f.store.sync();
    expect(f.store.list().reports[0]).toMatchObject({ state: "uncertain" });
    expect(f.store.list().reports[0]!.error).not.toContain("ghp_testsecret");
    await f.store.close();
    const store = f.open();
    f.setIntercept(undefined);
    await store.sync();
    expect(f.calls.filter((c) => c.method === "POST")).toHaveLength(1);
    f.issues.push({
      number: 7,
      state: "open",
      body: String(f.calls.find((c) => c.method === "POST")!.body!.body),
    });
    await store.sync();
    expect(store.list().reports[0]).toMatchObject({
      state: "open",
      pending: false,
      url: "https://github.com/owner/repo/issues/7",
    });
    expect(f.calls.filter((c) => c.method === "POST")).toHaveLength(1);
  } finally {
    await f.close();
  }
});

test("concurrent dashboard/stdio stores share a publication lease and preserve in-flight repeats", async () => {
  const f = fixture();
  let release!: () => void;
  const blocked = new Promise<void>((resolve) => {
    release = resolve;
  });
  try {
    const other = f.open();
    f.store.report(report, null);
    f.setIntercept(async (method) => {
      if (method === "POST") await blocked;
    });
    const pending = f.store.sync();
    while (!f.calls.some((c) => c.method === "POST")) await Bun.sleep(1);
    other.report(report, null);
    await other.sync();
    release();
    await pending;
    expect(other.list().reports[0]).toMatchObject({ occurrences: 2, pending: true });
    await other.sync();
    expect(f.issues).toHaveLength(1);
    expect(other.list().reports[0]!.pending).toBe(false);
    expect(f.issues[0]!.body).toContain("Occurrences: 2");
  } finally {
    release();
    await f.close();
  }
});

test("feedback works without RCON, bypasses a blocked game queue, and validates its input", async () => {
  const f = fixture("");
  let release!: () => void;
  const blocked = new Promise<void>((resolve) => {
    release = resolve;
  });
  const rcon = {
    sendCommand: async () => {
      await blocked;
      return { success: true, data: "{}" };
    },
    disconnect: async () => {},
  } as unknown as RCONClient;
  const game = new GameBridge(rcon, f.events, f.store);
  try {
    const pending = game.execute("companion_list");
    expect((await game.execute("feedback_report", report)).success).toBe(true);
    expect((await game.execute("feedback_report", { ...report, key: "../invalid" })).success).toBe(
      false,
    );
    expect((await game.execute("feedback_report", report, "codex", () => false)).success).toBe(
      false,
    );
    expect(f.store.list().reports[0]!.occurrences).toBe(1);
    expect(f.events.recent.filter((event) => event.type === "feedback.changed")[0]!.data).toEqual({
      key: report.key,
    });
    release();
    await pending;
  } finally {
    release();
    await f.close();
  }
});
