import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { EventEmitter } from "node:events";
import { StringDecoder } from "node:string_decoder";
import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { LOCAL_DIR, PROJECT_ROOT } from "../config";
import pkg from "../../package.json";

export type RpcMessage = {
  id?: number | string;
  method?: string;
  params?: Record<string, unknown>;
  result?: unknown;
  error?: { code: number; message: string };
};

export function textInput(text: string) {
  return { type: "text" as const, text, text_elements: [] };
}
type Pending = {
  resolve: (result: unknown) => void;
  reject: (error: Error) => void;
  timer: ReturnType<typeof setTimeout>;
};

/** JSONL app-server transport, pinned and smoke-tested against Codex CLI 0.154.0. */
export class CodexClient extends EventEmitter {
  private process: ChildProcessWithoutNullStreams | null = null;
  private starting: Promise<void> | null = null;
  private sequence = 0;
  private pending = new Map<number, Pending>();
  ready = false;
  readonly home: string;
  readonly workspace: string;

  constructor(
    private readonly options: {
      command?: string;
      args?: string[];
      home?: string;
      workspace?: string;
      timeoutMs?: number;
    } = {},
  ) {
    super();
    this.home = options.home || join(LOCAL_DIR, "codex-home");
    this.workspace = options.workspace || join(LOCAL_DIR, "agent");
  }

  async start(): Promise<void> {
    if (this.ready) return;
    if (this.starting) return this.starting;
    this.starting = this.open();
    try {
      await this.starting;
    } finally {
      this.starting = null;
    }
  }

  private async open(): Promise<void> {
    mkdirSync(this.home, { recursive: true });
    mkdirSync(this.workspace, { recursive: true });
    const proc = spawn(
      this.options.command || process.execPath,
      this.options.args || [
        join(PROJECT_ROOT, "node_modules/@openai/codex/bin/codex.js"),
        "app-server",
        "-c",
        "features.shell_tool=false",
        "-c",
        'web_search="disabled"',
      ],
      {
        cwd: this.workspace,
        windowsHide: true,
        stdio: "pipe",
        env: {
          ...process.env,
          CODEX_HOME: this.home,
          OPENAI_API_KEY: undefined,
          CODEX_API_KEY: undefined,
        },
      },
    );
    this.process = proc;
    let buffer = "";
    const decoder = new StringDecoder("utf8");
    proc.stdout.on("data", (chunk: Buffer) => {
      buffer += decoder.write(chunk);
      if (buffer.length > 8 * 1024 * 1024) {
        this.fail(new Error("Codex message exceeds limit"));
        proc.kill();
        return;
      }
      let end: number;
      while ((end = buffer.indexOf("\n")) >= 0) {
        const line = buffer.slice(0, end);
        buffer = buffer.slice(end + 1);
        if (!line.trim()) continue;
        try {
          this.receive(JSON.parse(line) as RpcMessage);
        } catch {
          this.emit("diagnostic", "Invalid JSON from Codex app-server");
        }
      }
    });
    // Never forward raw stderr: third-party auth and HTTP diagnostics may contain secrets.
    proc.stderr.on("data", () => {
      this.emit("diagnostic", "Codex emitted a diagnostic on stderr");
    });
    proc.stdin.on("error", (error) => this.fail(error));
    proc.on("error", (error) => this.fail(error));
    proc.on("exit", (code) => {
      if (this.process === proc) {
        this.process = null;
        this.fail(new Error(`Codex app-server exited (${code})`));
      }
    });
    try {
      await this.request("initialize", {
        clientInfo: {
          name: "factorio_companion",
          title: "Factorio AI Companion",
          version: pkg.version,
        },
        capabilities: { experimentalApi: true },
      });
      this.send({ method: "initialized", params: {} });
      this.ready = true;
    } catch (error) {
      proc.kill();
      throw error;
    }
  }

  request<T = unknown>(method: string, params: Record<string, unknown> = {}): Promise<T> {
    return new Promise((resolve, reject) => {
      const id = ++this.sequence;
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`Codex ${method} timed out`));
      }, this.options.timeoutMs || 30000);
      this.pending.set(id, { resolve: (result) => resolve(result as T), reject, timer });
      try {
        this.send({ id, method, params });
      } catch (error) {
        clearTimeout(timer);
        this.pending.delete(id);
        reject(error);
      }
    });
  }

  respond(id: string | number, result: unknown): void {
    this.send({ id, result });
  }
  reject(id: string | number, message: string): void {
    this.send({ id, error: { code: -32601, message } });
  }
  private send(message: RpcMessage): void {
    if (!this.process || this.process.killed || !this.process.stdin.writable)
      throw new Error("Codex is not running");
    this.process.stdin.write(JSON.stringify(message) + "\n");
  }
  private receive(message: RpcMessage): void {
    if (message.method) {
      this.emit(message.id === undefined ? "notification" : "request", message);
      return;
    }
    const pending = this.pending.get(Number(message.id));
    if (!pending) return;
    this.pending.delete(Number(message.id));
    clearTimeout(pending.timer);
    if (message.error) pending.reject(new Error(message.error.message));
    else pending.resolve(message.result);
  }
  private fail(error: Error): void {
    this.ready = false;
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(error);
    }
    this.pending.clear();
    this.emit("disconnected", error.message);
  }
  async close(): Promise<void> {
    const proc = this.process;
    this.process = null;
    this.fail(new Error("Codex stopped"));
    if (proc) {
      proc.stdin.end();
      proc.kill();
    }
  }
}
