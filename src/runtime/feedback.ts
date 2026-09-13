import { Database } from "bun:sqlite";
import { createHash } from "node:crypto";
import { mkdirSync } from "node:fs";
import { join, resolve } from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { SETTINGS, type Settings } from "../../config/settings";
import limits from "../../config/feedback.json";
import pkg from "../../package.json";
import { PROJECT_ROOT } from "../config";
import { validateToolArgs } from "../mcp/schema";
import type { EventLog } from "./events";
import type { WorldSnapshot } from "./game";

type Issue = {
  number: number;
  state: "open" | "closed";
  body: string | null;
  pull_request?: unknown;
};
type Row = {
  id: string;
  repository: string;
  key: string;
  payload: string;
  count: number;
  first_seen: string;
  last_seen: string;
  synced_count: number;
  issue: number | null;
  state: "local" | "pending" | "uncertain" | "open" | "closed";
  error: string | null;
};
type Payload = {
  title: string;
  category: string;
  details: Record<string, unknown>;
  context: unknown;
};
type Options = {
  fetch?: typeof globalThis.fetch;
  token?: () => Promise<string>;
  automatic?: boolean;
};

/** Only this boundary handles text intended for publication. No raw event or snapshot export. */
export function feedbackRedactor(secrets: string[]) {
  return (value: string) => {
    for (const secret of secrets.filter(Boolean).sort((a, b) => b.length - a.length))
      value = value.replaceAll(secret, "[redacted]");
    return value
      .replace(/https?:\/\/[^\s"<>]+/gi, (text) => {
        try {
          const url = new URL(text);
          url.username = "";
          url.password = "";
          url.search = "";
          url.hash = "";
          return url.href;
        } catch {
          return "[url]";
        }
      })
      .replace(/(?:github_pat_|gh[pousr]_)[A-Za-z0-9_]+/g, "[redacted]")
      .replace(/\bBearer\s+\S+/gi, "Bearer [redacted]")
      .replace(
        /\b(?:password|token|api[-_]?key|secret)\s*[:=]\s*[^\s,;]+/gi,
        "credential=[redacted]",
      )
      .replace(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi, "[email]")
      .replace(/(?<![\w:/])(?:[A-Z]:[\\/]|\/(?:home|Users|root)\/)[^\s"<>]+/gi, "[local path]");
  };
}

function context(snapshot: WorldSnapshot | null, events: EventLog, companionId: number) {
  return {
    serverVersion: pkg.version,
    ...(snapshot
      ? {
          modVersion: snapshot.version,
          factorioVersion: snapshot.factorio,
          tick: snapshot.tick,
          paused: snapshot.paused,
          companions: snapshot.companions
            .filter((c) => !companionId || c.id === companionId)
            .slice(0, 10)
            .map((c) => ({
              id: c.id,
              position: c.position,
              dead: c.dead,
              activeQueues: Object.entries(c.queues || {})
                .filter(([, q]) => q && q.active !== false)
                .map(([name]) => name),
            })),
        }
      : { observed: false }),
    recentFailures: events.recent
      .filter((e) => {
        const data = e.data as Record<string, unknown> | null;
        return e.type === "tool.completed" && data?.success === false && data.source !== "poll";
      })
      .slice(-limits.recentFailures)
      .map((e) => {
        const data = e.data as Record<string, unknown>;
        // Arguments and raw errors may contain chat, commands or credentials.
        return { at: e.at, tool: data.name, durationMs: data.durationMs };
      }),
  };
}

export class FeedbackStore {
  private readonly db: Database;
  private readonly owner = crypto.randomUUID();
  private readonly redact: (value: string) => string;
  private readonly secrets: string[];
  private readonly repository: string;
  private timer?: ReturnType<typeof setInterval>;
  private syncing?: Promise<void>;
  private closed = false;
  constructor(
    private readonly settings: Settings,
    private readonly events: EventLog,
    private readonly options: Options = {},
  ) {
    this.repository = settings.FEEDBACK_GITHUB_REPOSITORY.toLowerCase();
    if (this.repository && !/^[a-z0-9][a-z0-9-]*\/[a-z0-9_.-]+$/.test(this.repository))
      throw new Error("FEEDBACK_GITHUB_REPOSITORY must be owner/repo");
    this.secrets = Object.entries(SETTINGS).flatMap(([key, config]) =>
      "secret" in config && settings[key as keyof Settings] !== config.default
        ? [String(settings[key as keyof Settings])]
        : [],
    );
    this.redact = feedbackRedactor(this.secrets);
    const directory = resolve(PROJECT_ROOT, settings.COMPANION_DATA_DIR);
    mkdirSync(directory, { recursive: true });
    this.db = new Database(join(directory, "feedback.sqlite"));
    this.db.exec(`PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000;
      CREATE TABLE IF NOT EXISTS reports (
        id TEXT PRIMARY KEY, repository TEXT NOT NULL, key TEXT NOT NULL, payload TEXT NOT NULL,
        count INTEGER NOT NULL DEFAULT 1, first_seen TEXT NOT NULL, last_seen TEXT NOT NULL,
        synced_count INTEGER NOT NULL DEFAULT 0, issue INTEGER,
        state TEXT NOT NULL, error TEXT);
      CREATE TABLE IF NOT EXISTS leases (repository TEXT PRIMARY KEY, owner TEXT, expires INTEGER NOT NULL);`);
    if (this.repository && options.automatic !== false) {
      this.timer = setInterval(() => {
        void this.sync();
      }, settings.FEEDBACK_SYNC_INTERVAL_MS);
      this.timer.unref();
      queueMicrotask(() => {
        if (!this.closed) void this.sync();
      });
    }
  }

  private rows(limit = 100): Row[] {
    return this.db
      .query<Row, [string, number]>(
        "SELECT * FROM reports WHERE repository=? ORDER BY last_seen DESC LIMIT ?",
      )
      .all(this.repository, limit);
  }
  private view(row: Row, full = false) {
    const payload = JSON.parse(row.payload) as Payload;
    return {
      key: row.key,
      title: payload.title,
      category: payload.category,
      occurrences: row.count,
      firstSeen: row.first_seen,
      lastSeen: row.last_seen,
      state: row.state,
      pending: row.synced_count < row.count,
      error: row.error,
      url: row.issue ? `https://github.com/${row.repository}/issues/${row.issue}` : null,
      ...(full ? { details: payload.details, context: payload.context } : {}),
    };
  }
  list(raw: unknown = {}) {
    const args = validateToolArgs("feedback_list", raw);
    const rows = args.key
      ? this.db
          .query<Row, [string, string]>("SELECT * FROM reports WHERE repository=? AND key=?")
          .all(this.repository, String(args.key))
      : this.rows(Number(args.limit));
    return {
      repository: this.repository || null,
      reports: rows.map((row) => this.view(row, !!args.key)),
    };
  }
  report(raw: unknown, snapshot: WorldSnapshot | null) {
    const args = validateToolArgs("feedback_report", raw);
    const key = this.redact(String(args.key));
    if (key !== args.key) throw new Error("Feedback key must not contain private data");
    const id = createHash("sha256").update(`${this.repository}:${key}`).digest("hex");
    const { title, category, companionId, key: _key, ...details } = args;
    const payload = JSON.stringify({
      title,
      category,
      details,
      context: context(snapshot, this.events, Number(companionId)),
    });
    // Redact leaf strings before encoding, preserving valid JSON even for quoted secrets.
    const clean = JSON.stringify(JSON.parse(payload), (_key, value) =>
      typeof value === "string" ? this.redact(value) : value,
    );
    const now = new Date().toISOString();
    this.db.transaction(() => {
      const existing = this.db.query("SELECT id FROM reports WHERE id=?").get(id);
      if (!existing && this.rows(limits.maxReports).length >= limits.maxReports)
        throw new Error("Feedback capacity reached; review existing reports before adding more");
      this.db
        .query(
          `INSERT INTO reports (id, repository, key, payload, first_seen, last_seen, state)
        VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET
        payload=excluded.payload, count=count+1, last_seen=excluded.last_seen`,
        )
        .run(id, this.repository, key, clean, now, now, this.repository ? "pending" : "local");
    })();
    this.events.emit("feedback.changed", { key });
    return this.list({ key }).reports[0]!;
  }

  sync(): Promise<void> {
    if (this.closed || !this.repository) return Promise.resolve();
    if (!this.syncing)
      this.syncing = this.publish().finally(() => {
        this.syncing = undefined;
      });
    return this.syncing;
  }
  private lease(): boolean {
    const now = Date.now();
    return (
      this.db
        .query(
          `INSERT INTO leases VALUES (?, ?, ?) ON CONFLICT(repository) DO UPDATE SET
      owner=excluded.owner, expires=excluded.expires WHERE leases.expires < ? OR leases.owner=?`,
        )
        .run(this.repository, this.owner, now + limits.leaseMs, now, this.owner).changes > 0
    );
  }
  private async publish() {
    if (!this.rows(1).length || !this.lease()) return;
    try {
      const token = await (this.options.token?.() || this.getToken());
      if (!token) throw new Error("Set FEEDBACK_GITHUB_TOKEN or sign in with gh auth login");
      if (!this.secrets.includes(token)) this.secrets.push(token);
      const request = async (path: string, method = "GET", body?: unknown) => {
        if (!this.lease()) throw new Error("Feedback sync lease lost");
        const response = await (this.options.fetch || fetch)(
          `https://api.github.com/repos/${this.repository}${path}`,
          {
            method,
            redirect: "error",
            signal: AbortSignal.timeout(limits.requestTimeoutMs),
            headers: {
              authorization: `Bearer ${token}`,
              accept: "application/vnd.github+json",
              "X-GitHub-Api-Version": "2026-03-10",
              "content-type": "application/json",
            },
            ...(body ? { body: JSON.stringify(body) } : {}),
          },
        );
        if (!response.ok) throw new Error(`GitHub ${method} ${response.status}`);
        return response.json();
      };
      let issues: Issue[] | undefined;
      const findIssue = async (marker: string) => {
        if (!issues) {
          const scanned: Issue[] = [];
          for (let page = 1; ; page++) {
            if (page > limits.maxIssuePages)
              throw new Error("Issue scan limit reached; no issue created");
            const batch = (await request(`/issues?state=all&per_page=100&page=${page}`)) as Issue[];
            scanned.push(...batch.filter((issue) => !issue.pull_request));
            if (batch.length < 100) break;
          }
          issues = scanned;
        }
        return issues.find((issue) => issue.body?.includes(marker));
      };
      let creates = 0;
      for (const row of this.rows(limits.maxReports)) {
        try {
          const marker = `<!-- companion-feedback:${row.id} -->`;
          const end = `<!-- /companion-feedback:${row.id} -->`;
          let issue = row.issue
            ? ((await request(`/issues/${row.issue}`)) as Issue)
            : await findIssue(marker);
          if (!issue && row.state === "uncertain")
            throw new Error(
              "Previous create outcome unknown; waiting for its issue marker. Review GitHub before retrying.",
            );
          const payload = JSON.parse(row.payload) as Payload;
          const escape = (text: string) =>
            text
              .replaceAll("&", "&amp;")
              .replaceAll("<", "&lt;")
              .replaceAll(">", "&gt;")
              .replaceAll("@", "&#64;");
          const section = [
            marker,
            `Category: ${payload.category} · Occurrences: ${row.count}`,
            `First seen: ${row.first_seen} · Last seen: ${row.last_seen}`,
            ...Object.entries(payload.details).map(
              ([name, value]) =>
                `### ${name[0]!.toUpperCase() + name.slice(1)}\n\n<pre>${escape(String(value))}</pre>`,
            ),
            `### Context\n\n<pre>${escape(JSON.stringify(payload.context, null, 2))}</pre>`,
            end,
          ].join("\n\n");
          if (!issue) {
            if (++creates > limits.maxCreatesPerSync)
              throw new Error("New issue limit reached; queued for the next sync");
            // Persist uncertainty before a mutation: restart/timeout must reconcile, never blindly resend.
            this.db.query("UPDATE reports SET state='uncertain' WHERE id=?").run(row.id);
            try {
              issue = (await request("/issues", "POST", {
                title: limits.issueTitlePrefix + escape(payload.title),
                body: section,
              })) as Issue;
            } catch (error) {
              // A definite client rejection is safe to retry after credentials/rate limits are fixed.
              if (/GitHub POST 4\d\d$/.test(String(error)) && !String(error).endsWith("408"))
                this.db.query("UPDATE reports SET state='pending' WHERE id=?").run(row.id);
              throw error;
            }
            issues?.push(issue);
          } else if (row.synced_count < row.count) {
            const body = issue.body || "";
            const start = body.indexOf(marker),
              finish = body.indexOf(end, start);
            if (start < 0 || finish < 0)
              throw new Error("Issue feedback markers removed; preserving reviewer edits");
            await request(`/issues/${issue.number}`, "PATCH", {
              body: body.slice(0, start) + section + body.slice(finish + end.length),
            });
          }
          this.db
            .query("UPDATE reports SET issue=?, state=?, synced_count=?, error=NULL WHERE id=?")
            .run(issue.number, issue.state, row.count, row.id);
        } catch (error) {
          this.db
            .query("UPDATE reports SET error=? WHERE id=?")
            .run(this.redact(String(error)).slice(0, 400), row.id);
        }
      }
    } catch (error) {
      this.db
        .query("UPDATE reports SET error=? WHERE repository=?")
        .run(this.redact(String(error)).slice(0, 400), this.repository);
    } finally {
      this.db
        .query("DELETE FROM leases WHERE repository=? AND owner=?")
        .run(this.repository, this.owner);
      this.events.emit("feedback.changed", {});
    }
  }
  private async getToken(): Promise<string> {
    if (this.settings.FEEDBACK_GITHUB_TOKEN) return this.settings.FEEDBACK_GITHUB_TOKEN;
    try {
      const { stdout } = await promisify(execFile)(
        "gh",
        ["auth", "token", "--hostname", "github.com"],
        { windowsHide: true, timeout: limits.requestTimeoutMs },
      );
      return stdout.trim();
    } catch {
      return "";
    }
  }
  async close() {
    if (this.closed) return;
    this.closed = true;
    clearInterval(this.timer);
    await this.syncing;
    this.db.close();
  }
}
