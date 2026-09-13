import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { readSettings } from "../config/settings";
import mod from "../config/mod.json";
import pkg from "../package.json";
import { PROJECT_ROOT } from "../src/config";

const key = readSettings().FACTORIO_MOD_UPLOAD_API_KEY;
if (!key) throw new Error("Set FACTORIO_MOD_UPLOAD_API_KEY in .env (ModPortal: Upload Mods scope)");
const portal = "https://mods.factorio.com";
const releaseUrl = `${portal}/api/mods/${encodeURIComponent(mod.name)}`;
type Release = { version: string; sha1: string };
async function releases(): Promise<Release[]> {
  const response = await fetch(releaseUrl, { signal: AbortSignal.timeout(30000) });
  if (!response.ok) throw new Error(`Cannot read Mod Portal releases: HTTP ${response.status}`);
  return ((await response.json()) as { releases: Release[] }).releases;
}
if ((await releases()).some((release) => release.version === pkg.version))
  throw new Error(`${mod.name} ${pkg.version} is already published`);
await import("./package-mod");
const filename = `${mod.name}_${pkg.version}.zip`;
const bytes = readFileSync(join(PROJECT_ROOT, "dist", filename));
const sha1 = createHash("sha1").update(bytes).digest("hex");
const init = new FormData();
init.set("mod", mod.name);
const response = await fetch(`${portal}/api/v2/mods/releases/init_upload`, {
  method: "POST",
  headers: { Authorization: `Bearer ${key}` },
  body: init,
  redirect: "error",
  signal: AbortSignal.timeout(30000),
});
const initialized = (await response.json()) as { upload_url?: string; error?: string };
if (!response.ok || !initialized.upload_url)
  throw new Error(
    `Mod Portal upload initialization failed: ${initialized.error || response.status}`,
  );
const target = new URL(initialized.upload_url);
if (target.protocol !== "https:") throw new Error("Mod Portal returned a non-HTTPS upload URL");
const upload = new FormData();
upload.set("file", new Blob([bytes], { type: "application/zip" }), filename);
const finished = await fetch(target, {
  method: "POST",
  body: upload,
  redirect: "error",
  signal: AbortSignal.timeout(120000),
});
const result = (await finished.json()) as { success?: boolean; error?: string };
if (!finished.ok || !result.success)
  throw new Error(
    `Mod upload failed: ${result.error || finished.status}. Check the portal before retrying.`,
  );
const published = (await releases()).find((release) => release.version === pkg.version);
if (!published || published.sha1 !== sha1)
  throw new Error(
    "Upload accepted, but public release verification is pending. Check the portal before retrying.",
  );
console.log(`Published and SHA-1 verified: ${portal}/mod/${mod.name}/downloads (${pkg.version})`);
