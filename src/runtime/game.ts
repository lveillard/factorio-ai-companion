import { RCONClient } from "../rcon/client";
import { buildRCONCommand, generateToolSchemas, validateToolArgs } from "../mcp/schema";
import { COMMANDS } from "../mcp/schema";
import type { EventLog } from "./events";

export interface ToolResult {
  success: boolean;
  data?: unknown;
  error?: string;
}
export interface WorldSnapshot {
  version: string;
  factorio: string;
  session_id: string;
  tick: number;
  paused: boolean;
  center: { x: number; y: number };
  radius: number;
  surface: string;
  companions: Array<{
    id: number;
    name?: string;
    dead?: boolean;
    position?: { x: number; y: number };
    inventory?: unknown;
    queues?: unknown;
  }>;
  players: unknown[];
  entities: unknown[];
  errors: unknown[];
  [key: string]: unknown;
}

export class GameBridge {
  readonly schemas = generateToolSchemas();
  snapshot: WorldSnapshot | null = null;
  lastObservedAt: string | null = null;
  error: string | null = null;
  private serial: Promise<unknown> = Promise.resolve();
  constructor(
    readonly rcon: RCONClient,
    private readonly events: EventLog,
  ) {}

  execute(
    name: string,
    raw: unknown = {},
    source = "manual",
    allowed: () => boolean = () => true,
  ): Promise<ToolResult> {
    const operation = this.serial.then(async () => {
      if (!allowed()) return { success: false, error: "Action cancelled before execution" };
      const started = Date.now();
      let args: Record<string, unknown>;
      try {
        args = validateToolArgs(name, raw);
      } catch (error) {
        return { success: false, error: String(error) };
      }
      this.events.emit("tool.started", { name, args, source }, source !== "poll");
      let result: ToolResult;
      try {
        if (COMMANDS[name]?.execution === "session")
          result = { success: true, data: this.status() };
        else if (COMMANDS[name]?.execution === "wait") {
          await Bun.sleep(Number(args.milliseconds));
          result = { success: true };
        } else result = await this.command(name, args);
      } catch (error) {
        result = { success: false, error: error instanceof Error ? error.message : String(error) };
      }
      this.events.emit(
        "tool.completed",
        { name, args, source, durationMs: Date.now() - started, ...result },
        source !== "poll",
      );
      return result;
    });
    this.serial = operation;
    return operation;
  }

  async command(name: string, args: unknown = {}): Promise<ToolResult> {
    const command = buildRCONCommand(name, args);
    const response = await this.rcon.sendCommand(command);
    if (!response.success) return { success: false, error: response.error };
    try {
      const data: unknown = JSON.parse(response.data);
      if (data && typeof data === "object" && "error" in data && data.error)
        return { success: false, data, error: String(data.error) };
      return { success: true, data };
    } catch {
      return {
        success: false,
        error: `Invalid mod response: ${response.data.slice(0, 500) || "empty reply"}`,
      };
    }
  }

  async observe(companionId = 0, radius = 48): Promise<WorldSnapshot> {
    const response = await this.execute("world_observe", { companionId, radius }, "poll");
    if (!response.success) {
      const error = response.error || "Unable to observe Factorio";
      if (this.error !== error) this.events.emit("game.disconnected", { error });
      this.error = error;
      throw new Error(error);
    }
    const snapshot = response.data as WorldSnapshot;
    if (!snapshot || !snapshot.version || !snapshot.session_id || typeof snapshot.tick !== "number")
      throw new Error("Unsupported world snapshot; install the matching mod");
    for (const key of ["companions", "players", "entities", "water", "errors", "tasks"] as const)
      if (!Array.isArray(snapshot[key])) snapshot[key] = [];
    this.snapshot = snapshot;
    this.lastObservedAt = new Date().toISOString();
    if (this.error)
      this.events.emit("game.connected", {
        version: snapshot.version,
        factorio: snapshot.factorio,
      });
    this.error = null;
    this.events.emit("world", { snapshot, observedAt: this.lastObservedAt }, false);
    return snapshot;
  }

  status() {
    return {
      connected: this.rcon.isConnected() && !this.error,
      error: this.error,
      observedAt: this.lastObservedAt,
      snapshot: this.snapshot,
    };
  }

  async stopAll(): Promise<ToolResult[]> {
    const list = await this.execute("companion_list", {}, "stop");
    if (!list.success) return [list];
    const data = list.data as { companions?: Array<{ id: number }> };
    const companions = Array.isArray(data.companions) ? data.companions : [];
    const results: ToolResult[] = [];
    for (const c of companions)
      results.push(await this.execute("companion_stop", { companionId: c.id }, "stop"));
    return results;
  }

  async close(): Promise<void> {
    await this.rcon.disconnect();
  }
}
