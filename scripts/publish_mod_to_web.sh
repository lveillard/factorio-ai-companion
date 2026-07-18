#!/bin/bash
# Package factorio-mod/ into a versioned zip (Factorio mod-portal convention:
# modname_version.zip containing a top-level modname_version/ folder) and sync it to
# the website download folder, removing OLDER versions of THIS mod only.
#
# Zdendys (2026-07-06): "Then go ahead and get started on that tool that will save
# new mod versions to the web as soon as they're created, and delete the old ones." -- runs standalone (manual
# republish) or via .githooks/post-commit (automatic, right after any commit that
# touches factorio-mod/, since the pre-commit hook already bumps info.json's version
# on every such commit).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOD_DIR="$REPO_DIR/factorio-mod"
WEB_DIR="/home/zdendys/Backups/JZ79.website.sync/factorio/mods"
INFO="$MOD_DIR/info.json"

if [ ! -f "$INFO" ]; then
  echo "[publish] FAILED: $INFO not found" >&2
  exit 1
fi
if [ ! -d "$WEB_DIR" ]; then
  echo "[publish] FAILED: web dir $WEB_DIR does not exist" >&2
  exit 1
fi

# Basic regex (portable, no -P): matches "version": "0.16.25" or "name": "ai-companion".
name=$(sed -n 's/.*"name": *"\([^"]*\)".*/\1/p' "$INFO" | head -1)
version=$(sed -n 's/.*"version": *"\([0-9.]*\)".*/\1/p' "$INFO" | head -1)

if [ -z "$name" ] || [ -z "$version" ]; then
  echo "[publish] FAILED: could not read name/version from $INFO" >&2
  exit 1
fi

target="${name}_${version}"
zip_name="${target}.zip"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Factorio requires the zip's top-level directory to be named exactly "modname_version"
# (not "factorio-mod") -- copy into that exact folder name before zipping.
cp -r "$MOD_DIR" "$tmp/$target"
( cd "$tmp" && zip -rq "$zip_name" "$target" )

if [ ! -f "$tmp/$zip_name" ]; then
  echo "[publish] FAILED: zip creation did not produce $zip_name" >&2
  exit 1
fi

mv "$tmp/$zip_name" "$WEB_DIR/$zip_name"
echo "[publish] wrote $WEB_DIR/$zip_name"

# Remove OLDER versions of THIS mod only -- anchored to "${name}_" prefix + a
# version-shaped suffix, so it can never touch an unrelated mod's zip (e.g.
# Repair_Turret_2.0.5.zip) or non-zip files (README.md) sitting in the same folder.
removed=0
for f in "$WEB_DIR/${name}_"*.zip; do
  [ -e "$f" ] || continue   # literal glob (no match) -- skip
  base=$(basename "$f")
  if [ "$base" != "$zip_name" ]; then
    rm -f "$f"
    echo "[publish] removed old version: $base"
    removed=$((removed + 1))
  fi
done
echo "[publish] done: $zip_name published, $removed old version(s) removed"
