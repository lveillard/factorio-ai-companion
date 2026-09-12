import { z } from "zod";
import definitions from "../../config/commands.json";
export type InputSchema = {
  type: "object";
  properties: Record<string, Record<string, unknown>>;
  required?: string[];
  additionalProperties: boolean;
};
export interface CommandDefinition {
  description: string;
  execution: "game" | "session" | "wait";
  effect: "read" | "chat" | "act";
  inputSchema: InputSchema;
  before?: string[];
}
export const COMMANDS = definitions as Record<string, CommandDefinition>;
const validators = new Map(
  Object.entries(COMMANDS).map(([name, definition]) => [
    name,
    z.fromJSONSchema(definition.inputSchema),
  ]),
);
export function validateToolArgs(name: string, raw: unknown): Record<string, unknown> {
  const definition = Object.hasOwn(COMMANDS, name) ? COMMANDS[name] : undefined;
  if (!definition) throw new Error("Unknown tool: " + name);
  const args = validators.get(name)!.parse(raw ?? {}) as Record<string, unknown>;
  for (const [key, schema] of Object.entries(definition.inputSchema.properties))
    if (args[key] === undefined && schema.default !== undefined) args[key] = schema.default;
  return args;
}
export function buildRCONCommand(name: string, raw: unknown): string {
  return "/fac_api " + JSON.stringify({ tool: name, args: validateToolArgs(name, raw) });
}
export function generateToolSchemas() {
  return Object.entries(COMMANDS).map(([name, definition]) => ({
    name,
    description: definition.description,
    inputSchema: definition.inputSchema,
  }));
}
