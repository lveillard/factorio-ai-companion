#!/bin/bash
# Mirror factorio-mod/ into the LOCAL Factorio install's own mods folder
# (~/.factorio/mods/ai-companion), so a commit actually takes effect in the
# running game -- not just published to the website download folder.
#
# CRITICAL GAP THIS CLOSES (2026-07-29, ep135 discard investigation, live-caught):
# .githooks/post-commit already auto-publishes factorio-mod/ to the WEBSITE sync
# folder (scripts/publish_mod_to_web.sh) on every commit that touches it, but
# NOTHING ever copied those same changes into ~/.factorio/mods/ai-companion --
# the actual directory the running Factorio server loads its mods FROM. The
# mod-mod/README.md's own "Install" section always documented this as a MANUAL
# step ("cp -r factorio-mod ~/.factorio/mods/ai-companion"), never automated.
# Confirmed live: ~/.factorio/mods/ai-companion sat at version 0.16.128 while the
# repo had already advanced to 0.16.130 -- meaning the LAST TWO mod-side fixes of
# this same overnight session (task_pool.lua's needs-unmet-giveup fix, 14th
# distinct bug, and queues_core.lua's mine-state universal-stale-gap fix, 22nd
# distinct bug) were COMPLETELY INERT in the actual running game the whole time,
# despite passing this project's own established "luac -p + live RCON smoke test"
# verification -- that verification only proves the (unchanged) mod loads without
# crashing, never that the NEW code is actually the code running. Episode 135's
# discard reproduced the EXACT symptom the mine-state fix was supposed to close,
# proving the fix itself was correct but had simply never been deployed.
#
# Runs standalone (manual redeploy) or via .githooks/post-commit (automatic,
# right after any commit that touches factorio-mod/), mirroring
# publish_mod_to_web.sh's own dual-use convention exactly.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOD_DIR="$REPO_DIR/factorio-mod"
LOCAL_MODS_DIR="$HOME/.factorio/mods/ai-companion"

if [ ! -d "$MOD_DIR" ]; then
  echo "[deploy-local] FAILED: $MOD_DIR not found" >&2
  exit 1
fi

# rsync -a --delete: an EXACT mirror of factorio-mod/'s current contents into
# the local mods folder, removing any file there that no longer exists in the
# repo (mirrors publish_mod_to_web.sh's own "delete the old ones" convention,
# Zdendys's own explicit ask, applied here to stale/removed mod files instead of
# stale zip versions). Trailing slashes on both paths are REQUIRED for rsync to
# copy MOD_DIR's own CONTENTS into LOCAL_MODS_DIR, not create a nested
# factorio-mod/ subdirectory inside it.
mkdir -p "$LOCAL_MODS_DIR"
rsync -a --delete "$MOD_DIR/" "$LOCAL_MODS_DIR/"
echo "[deploy-local] mirrored $MOD_DIR/ -> $LOCAL_MODS_DIR/"

version=$(sed -n 's/.*"version": *"\([0-9.]*\)".*/\1/p' "$MOD_DIR/info.json" | head -1)
echo "[deploy-local] done: ai-companion $version now live in $LOCAL_MODS_DIR"
echo "[deploy-local] NOTE: the running Factorio server does NOT hot-reload mods --" \
     "restart it (kill the process, let the wrapper relaunch) for this to take effect."
