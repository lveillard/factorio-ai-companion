import type { Settings } from "../config/settings";

/** Update one INI section without matching comments or keys in other sections. */
function setSection(text: string, name: string, values: Record<string, string>): string {
  const newline = text.includes("\r\n") ? "\r\n" : "\n";
  const lines = text.split(/\r?\n/);
  let start = lines.findIndex((line) => line.trim() === `[${name}]`);
  if (start < 0) {
    lines.push(`[${name}]`);
    start = lines.length - 1;
  }
  let end = lines.findIndex((line, index) => index > start && /^\s*\[/.test(line));
  if (end < 0) end = lines.length;
  const keys = new Set(Object.keys(values));
  const section = lines.slice(start + 1, end).filter((line) => {
    const key = line.match(/^\s*;?\s*([^=\s]+)\s*=/)?.[1];
    return !key || !keys.has(key);
  });
  for (const [key, value] of Object.entries(values)) {
    if (/[\r\n\0]/.test(value))
      throw new Error("Factorio config values cannot contain newlines or NUL");
    section.unshift(`${key}=${value}`);
  }
  lines.splice(start + 1, end - start - 1, ...section);
  return lines.join(newline);
}

export function configureLocalGame(
  text: string,
  settings: Pick<Settings, "FACTORIO_RCON_PORT" | "FACTORIO_RCON_PASSWORD">,
  paths: { readData: string; writeData: string },
): string {
  text = setSection(text, "path", {
    "read-data": paths.readData.replaceAll("\\", "/"),
    "write-data": paths.writeData.replaceAll("\\", "/"),
  });
  return setSection(text, "other", {
    "local-rcon-socket": `127.0.0.1:${settings.FACTORIO_RCON_PORT}`,
    "local-rcon-password": settings.FACTORIO_RCON_PASSWORD,
  });
}
