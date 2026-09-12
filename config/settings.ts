/** Environment contract: defaults, validation and generated .env.example come from this table. */
export const SETTINGS = {
  COMPANION_HOST: {
    type: "string",
    default: "127.0.0.1",
    description: "HTTP bind address; use 0.0.0.0 inside Docker",
  },
  COMPANION_PORT: {
    type: "integer",
    default: 3210,
    min: 1,
    max: 65535,
    description: "Dashboard and MCP Streamable HTTP port",
  },
  COMPANION_PUBLIC_URL: {
    type: "string",
    default: "",
    description: "External HTTPS origin when behind a reverse proxy",
  },
  COMPANION_ACCESS_TOKEN: {
    type: "string",
    default: "",
    secret: true,
    description: "Required for non-loopback hosting (at least 32 characters); bearer token for MCP",
  },
  COMPANION_DATA_DIR: {
    type: "string",
    default: ".local",
    description: "Persistent logs, chat state and isolated Codex credentials",
  },
  FACTORIO_HOST: {
    type: "string",
    default: "127.0.0.1",
    description: "RCON server hostname/IP; host.docker.internal for a host game",
  },
  FACTORIO_RCON_PORT: {
    type: "integer",
    default: 34198,
    min: 1,
    max: 65535,
    description: "Factorio RCON port (local or remote)",
  },
  FACTORIO_RCON_PASSWORD: {
    type: "string",
    default: "factorio",
    secret: true,
    description: "Must match the Factorio RCON password",
  },
  FACTORIO_BINARY: {
    type: "string",
    default: "",
    description:
      "Optional Factorio executable for installation diagnostics and isolated game tests",
  },
  FACTORIO_MOD_DIR: {
    type: "string",
    default: "",
    description: "Optional Factorio mods directory; otherwise inferred from this operating system",
  },
  FACTORIO_MOD_UPLOAD_API_KEY: {
    type: "string",
    default: "",
    secret: true,
    description: "Mod Portal key with Upload Mods scope; used only by mod:publish",
  },
  POLL_INTERVAL_MS: {
    type: "integer",
    default: 2000,
    min: 500,
    max: 60000,
    description: "World and chat refresh interval",
  },
  TURN_TIMEOUT_MS: {
    type: "integer",
    default: 180000,
    min: 10000,
    max: 900000,
    description: "Maximum time per Codex turn before pausing",
  },
  MAX_TOOL_CALLS: {
    type: "integer",
    default: 64,
    min: 1,
    max: 256,
    description: "Maximum game tools per Codex turn",
  },
  MAX_QUEUED_MESSAGES: {
    type: "integer",
    default: 50,
    min: 10,
    max: 200,
    description: "Durable chat queue capacity",
  },
} as const;

type SettingValue<T> = T extends { type: "integer" } ? number : string;
export type Settings = { [K in keyof typeof SETTINGS]: SettingValue<(typeof SETTINGS)[K]> };

export function applicationUrl(settings: Settings): URL {
  const host = settings.COMPANION_HOST.includes(":")
    ? `[${settings.COMPANION_HOST.replace(/[\[\]]/g, "")}]`
    : settings.COMPANION_HOST === "0.0.0.0"
      ? "localhost"
      : settings.COMPANION_HOST;
  const url = new URL(settings.COMPANION_PUBLIC_URL || `http://${host}:${settings.COMPANION_PORT}`);
  if (!["http:", "https:"].includes(url.protocol))
    throw new Error("COMPANION_PUBLIC_URL must use HTTP or HTTPS");
  return url;
}

export function readSettings(env: Record<string, string | undefined> = process.env): Settings {
  const result: Record<string, string | number> = {};
  for (const [name, config] of Object.entries(SETTINGS)) {
    const raw = env[name];
    const value =
      raw === undefined || raw === ""
        ? config.default
        : config.type === "integer"
          ? Number(raw)
          : raw;
    if (
      config.type === "integer" &&
      (!Number.isInteger(value) || Number(value) < config.min || Number(value) > config.max)
    )
      throw new Error(`${name}: expected integer ${config.min}–${config.max}`);
    result[name] = value;
  }
  return result as Settings;
}
