import { mkdirSync, appendFileSync, existsSync, readFileSync, renameSync, statSync } from "node:fs";
import { join } from "node:path";

export interface AppEvent {
  id: string;
  at: string;
  type: string;
  data: unknown;
}

/** Bounded replay for the UI, with rotating diagnostic logs. Auth tokens never enter this bus. */
export class EventLog {
  readonly recent: AppEvent[] = [];
  private listeners = new Set<(event: AppEvent) => void>();
  private sequence = 0;
  constructor(private readonly directory?: string) {
    if (directory) {
      mkdirSync(directory, { recursive: true });
      const file = join(directory, "events.jsonl");
      if (existsSync(file)) {
        for (const line of readFileSync(file, "utf8").trim().split("\n").slice(-300)) {
          try {
            this.recent.push(JSON.parse(line) as AppEvent);
          } catch {
            /* A interrupted final line is safe to discard. */
          }
        }
      }
    }
  }
  emit(type: string, data: unknown, persist = true): AppEvent {
    const event = {
      id: `${Date.now()}-${++this.sequence}`,
      at: new Date().toISOString(),
      type,
      data,
    };
    if (persist) {
      this.recent.push(event);
      if (this.recent.length > 500) this.recent.shift();
    }
    if (persist && this.directory) {
      const file = join(this.directory, "events.jsonl");
      if (existsSync(file) && statSync(file).size > 5 * 1024 * 1024)
        renameSync(file, join(this.directory, "events.previous.jsonl"));
      appendFileSync(file, JSON.stringify(event) + "\n");
    }
    for (const listener of this.listeners) listener(event);
    return event;
  }
  subscribe(listener: (event: AppEvent) => void): () => void {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }
}
