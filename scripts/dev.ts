import { watch } from "node:fs";
import { join } from "node:path";
import { PROJECT_ROOT } from "../src/config";

let child: ReturnType<typeof Bun.spawn> | undefined;
let timer: ReturnType<typeof setTimeout>;
let building = false,
  pending = false,
  closing = false;
async function rebuild() {
  if (building) {
    pending = true;
    return;
  }
  building = true;
  try {
    if (child) {
      child.kill();
      await child.exited;
    }
    const build = Bun.spawn([process.execPath, "scripts/build.ts"], {
      cwd: PROJECT_ROOT,
      stdout: "inherit",
      stderr: "inherit",
      windowsHide: true,
    });
    if ((await build.exited) !== 0) return;
    if (!closing)
      child = Bun.spawn([process.execPath, "src/dashboard/main.ts"], {
        cwd: PROJECT_ROOT,
        stdout: "inherit",
        stderr: "inherit",
        windowsHide: true,
      });
  } finally {
    building = false;
    if (pending && !closing) {
      pending = false;
      void rebuild();
    }
  }
}
const watchers = ["src", "config"].map((path) =>
  watch(join(PROJECT_ROOT, path), { recursive: true }, () => {
    clearTimeout(timer);
    timer = setTimeout(() => {
      void rebuild();
    }, 250);
  }),
);
const stop = () => {
  closing = true;
  clearTimeout(timer);
  watchers.forEach((watcher) => watcher.close());
  child?.kill();
};
process.on("SIGINT", stop);
process.on("SIGTERM", stop);
await rebuild();
