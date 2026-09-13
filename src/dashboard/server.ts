import { timingSafeEqual, randomBytes } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { applicationUrl, readSettings, type Settings } from "../../config/settings";
import { PROJECT_ROOT } from "../config";
import { createMCPHttp } from "../mcp/server";
import { RCONClient } from "../rcon/client";
import { EventLog } from "../runtime/events";
import { GameBridge } from "../runtime/game";
import { CodexClient } from "../codex/client";
import { CompanionSession } from "../runtime/session";
import pkg from "../../package.json";

const LOCAL_HOSTS = new Set(["127.0.0.1", "localhost", "::1", "[::1]"]);
const safeEqual = (a: string, b: string): boolean => {
  const left = Buffer.from(a),
    right = Buffer.from(b);
  return left.length === right.length && timingSafeEqual(left, right);
};

export function createApplication(
  settings: Settings = readSettings(),
  services?: { game: GameBridge; session: CompanionSession; events: EventLog },
) {
  const directory = resolve(PROJECT_ROOT, settings.COMPANION_DATA_DIR);
  mkdirSync(directory, { recursive: true });
  const local =
    LOCAL_HOSTS.has(settings.COMPANION_HOST) &&
    (!settings.COMPANION_PUBLIC_URL ||
      LOCAL_HOSTS.has(new URL(settings.COMPANION_PUBLIC_URL).hostname));
  let token = settings.COMPANION_ACCESS_TOKEN;
  if (!local && token.length < 32)
    throw new Error(
      "COMPANION_ACCESS_TOKEN must contain at least 32 characters for remote hosting",
    );
  if (!token) {
    const path = join(directory, "server-token");
    token = existsSync(path) ? readFileSync(path, "utf8").trim() : randomBytes(32).toString("hex");
    if (!existsSync(path)) writeFileSync(path, token, { mode: 0o600 });
  }
  const publicUrl = applicationUrl(settings);
  const origins = new Set([
    publicUrl.origin,
    `http://127.0.0.1:${settings.COMPANION_PORT}`,
    `http://localhost:${settings.COMPANION_PORT}`,
  ]);
  const hosts = new Set([...origins].map((origin) => new URL(origin).host));
  const cookie = `companion_session=${token}; HttpOnly; SameSite=Strict; Path=/${publicUrl.protocol === "https:" ? "; Secure" : ""}`;
  const events = services?.events || new EventLog(join(directory, "logs"));
  const game =
    services?.game ||
    new GameBridge(
      new RCONClient({
        host: settings.FACTORIO_HOST,
        port: settings.FACTORIO_RCON_PORT,
        password: settings.FACTORIO_RCON_PASSWORD,
      }),
      events,
    );
  const session =
    services?.session ||
    new CompanionSession(
      game,
      new CodexClient({ home: join(directory, "codex-home"), workspace: join(directory, "agent") }),
      events,
      directory,
      {
        pollMs: settings.POLL_INTERVAL_MS,
        turnMs: settings.TURN_TIMEOUT_MS,
        maxToolCalls: settings.MAX_TOOL_CALLS,
        maxQueued: settings.MAX_QUEUED_MESSAGES,
        maxContinuations: settings.MAX_JOB_CONTINUATIONS,
        jobReviewMs: settings.JOB_REVIEW_TIMEOUT_MS,
      },
    );
  const mcp = createMCPHttp(game);
  let streams = 0;
  const json = (data: unknown, status = 200, headers: HeadersInit = {}) =>
    Response.json(data, { status, headers: { "Cache-Control": "no-store", ...headers } });
  const authorized = (request: Request, bearerOnly = false) => {
    const bearer = request.headers.get("authorization")?.replace(/^Bearer /, "") || "";
    const sessionCookie =
      request.headers
        .get("cookie")
        ?.split(";")
        .map((part) => part.trim())
        .find((part) => part.startsWith("companion_session="))
        ?.slice(18) || "";
    return safeEqual(bearer, token) || (!bearerOnly && safeEqual(sessionCookie, token));
  };

  async function body(request: Request): Promise<Record<string, unknown>> {
    if (!request.headers.get("content-type")?.startsWith("application/json"))
      throw new Error("Expected application/json");
    const text = await request.text();
    if (text.length > 128 * 1024) throw new Error("Request too large");
    const value: unknown = JSON.parse(text);
    if (!value || typeof value !== "object" || Array.isArray(value))
      throw new Error("Expected an object");
    return value as Record<string, unknown>;
  }
  async function fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (!hosts.has(request.headers.get("host") || url.host))
      return json({ error: "Untrusted host" }, 403);
    const origin = request.headers.get("origin");
    if (origin && !origins.has(origin)) return json({ error: "Untrusted origin" }, 403);
    if (request.headers.get("sec-fetch-site") === "cross-site")
      return json({ error: "Cross-site request denied" }, 403);
    if (url.pathname === "/healthz") return json({ status: "ok", version: pkg.version });
    if (request.method === "GET" && ["/", "/app.js", "/style.css"].includes(url.pathname)) {
      const path = url.pathname === "/" ? "index.html" : url.pathname.slice(1);
      const file = Bun.file(join(PROJECT_ROOT, "dist/web", path));
      if (!(await file.exists())) return new Response("Run bun run build first", { status: 503 });
      return new Response(file, {
        headers: {
          "Content-Type": path.endsWith("html")
            ? "text/html; charset=utf-8"
            : path.endsWith("js")
              ? "text/javascript; charset=utf-8"
              : "text/css; charset=utf-8",
          "Content-Security-Policy":
            "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'self'",
          "Referrer-Policy": "no-referrer",
          "X-Content-Type-Options": "nosniff",
          "Cache-Control": "no-cache",
          ...(local && path === "index.html" ? { "Set-Cookie": cookie } : {}),
        },
      });
    }
    if (url.pathname === "/mcp") {
      if (!authorized(request, true))
        return json({ error: "Bearer token required" }, 401, { "WWW-Authenticate": "Bearer" });
      return mcp.fetch(request);
    }
    try {
      if (url.pathname === "/api/unlock" && request.method === "POST") {
        const data = await body(request);
        if (!safeEqual(String(data.token || ""), token))
          return json({ error: "Invalid access token" }, 401);
        return json({ ok: true }, 200, { "Set-Cookie": cookie });
      }
      if (!authorized(request))
        return json({ error: "Unlock this dashboard with the server access token" }, 401);
      if (request.method === "GET" && url.pathname === "/api/state")
        return json({
          version: pkg.version,
          game: game.status(),
          agent: session.status(),
          events: events.recent,
          tools: game.schemas,
          rcon: { host: settings.FACTORIO_HOST, port: settings.FACTORIO_RCON_PORT },
          mcp: { url: `${publicUrl.origin}/mcp`, protocol: "2026-07-28" },
        });
      if (request.method === "GET" && url.pathname === "/api/events") {
        if (streams >= 16) return json({ error: "Too many event streams" }, 429);
        let unsubscribe = () => {};
        let heartbeat: ReturnType<typeof setInterval>;
        let closed = false;
        const close = () => {
          if (closed) return;
          closed = true;
          clearInterval(heartbeat);
          unsubscribe();
          streams--;
        };
        const stream = new ReadableStream({
          start(controller) {
            streams++;
            const write = (text: string) => {
              if (!closed) {
                try {
                  controller.enqueue(new TextEncoder().encode(text));
                } catch {
                  close();
                }
              }
            };
            write(": connected\n\n");
            unsubscribe = events.subscribe((event) => write(`data: ${JSON.stringify(event)}\n\n`));
            heartbeat = setInterval(() => write(": heartbeat\n\n"), 15000);
            request.signal.addEventListener(
              "abort",
              () => {
                close();
                try {
                  controller.close();
                } catch {}
              },
              { once: true },
            );
          },
          cancel: close,
        });
        return new Response(stream, {
          headers: {
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",
          },
        });
      }
      if (request.method !== "POST") return json({ error: "Not found" }, 404);
      const data = await body(request);
      switch (url.pathname) {
        case "/api/auth/login":
          return json(
            await session.login(data.type === "chatgpt" ? "chatgpt" : "chatgptDeviceCode"),
          );
        case "/api/auth/cancel":
          return json(await session.cancelLogin(String(data.loginId)));
        case "/api/auth/refresh":
          await session.refreshAccount();
          return json({ account: session.account });
        case "/api/auth/logout":
          await session.logout();
          return json({ ok: true });
        case "/api/chat":
          return json(
            session.enqueue(String(data.message || ""), Number(data.companionId || 0)),
            202,
          );
        case "/api/agent/resume":
          await session.resume();
          return json({ ok: true });
        case "/api/agent/pause":
          await session.pause();
          return json({ ok: true });
        case "/api/agent/new":
          await session.newConversation();
          return json({ ok: true });
        case "/api/settings": {
          const focus = Number(data.focus ?? session.focus);
          if (!Number.isInteger(focus) || focus < 0 || focus > 1000)
            throw new Error("Invalid focus");
          const model = String(data.model ?? session.model);
          if (model.length > 100) throw new Error("Invalid model");
          session.focus = focus;
          session.model = model;
          return json({ ok: true });
        }
        case "/api/tools/call":
          return json(await session.manualTool(String(data.name), data.args));
        default:
          return json({ error: "Not found" }, 404);
      }
    } catch (error) {
      return json({ error: error instanceof Error ? error.message : String(error) }, 400);
    }
  }
  return {
    fetch,
    session,
    game,
    events,
    url: publicUrl.origin,
    close: async () => {
      await session.close();
      await mcp.close();
    },
  };
}
