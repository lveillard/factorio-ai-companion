import { cp, mkdir } from "node:fs/promises";
import { join } from "node:path";
import { PROJECT_ROOT } from "../src/config";
import { generate } from "./generate";

generate();
const out = join(PROJECT_ROOT, "dist/web");
await mkdir(out, { recursive: true });
const build = await Bun.build({
  entrypoints: [join(PROJECT_ROOT, "src/dashboard/web/app.ts")],
  outdir: out,
  target: "browser",
  minify: true,
  naming: "app.js",
});
if (!build.success) throw new Error(build.logs.join("\n"));
for (const file of ["index.html", "style.css"])
  await cp(join(PROJECT_ROOT, "src/dashboard/web", file), join(out, file));
console.log("Dashboard built; generated mod contract is current.");
