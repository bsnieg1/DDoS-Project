#!/usr/bin/env bash
# =============================================================================
# setup-cloud.sh — prepare the cloud/ directory for running.
# Copies (or symlinks) needed sources from the main repo into cloud/.
#
# Usage (from the cloud/ directory):
#   bash setup-cloud.sh
#
# After this: bash run-experiments.sh
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PARENT="$(dirname "$ROOT")"
cd "$ROOT"

echo "[setup] Linking sources from $PARENT to $ROOT ..."

for dir in victim bot probe monitoring; do
  if [ ! -e "$dir" ]; then
    ln -sf "$PARENT/$dir" "$dir"
    echo "  -> $dir (symlink)"
  else
    echo "  -> $dir (already exists)"
  fi
done

mkdir -p results

echo "[setup] Done. Now run: bash run-experiments.sh"
