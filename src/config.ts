import { resolve } from "node:path";
import type { RCONConfig } from "./rcon/types";
import { readSettings } from "../config/settings";
export type { RCONConfig } from "./rcon/types";
export function getRCONConfig(): RCONConfig {
  const settings = readSettings();
  const config = {
    host: settings.FACTORIO_HOST,
    port: settings.FACTORIO_RCON_PORT,
    password: settings.FACTORIO_RCON_PASSWORD,
  };
  validateRCONConfig(config);
  return config;
}
export function validateRCONConfig(config: RCONConfig): void {
  if (!config.host.trim()) throw new Error("RCON host cannot be empty");
  if (!Number.isInteger(config.port) || config.port < 1 || config.port > 65535)
    throw new Error("Invalid RCON port: " + config.port);
  if (!config.password) throw new Error("RCON password cannot be empty");
}
export const PROJECT_ROOT = resolve(import.meta.dir, "..");
export const LOCAL_DIR = resolve(PROJECT_ROOT, ".local");
