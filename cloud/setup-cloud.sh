#!/usr/bin/env bash
# =============================================================================
# setup-cloud.sh — przygotuj katalog cloud/ do uruchomienia.
# Kopiuje (lub linkuje) potrzebne zrodla z glownego repo do cloud/.
#
# Uzycie (z katalogu cloud/):
#   bash setup-cloud.sh
#
# Po tym: bash run-experiments.sh
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
PARENT="$(dirname "$ROOT")"
cd "$ROOT"

echo "[setup] Linkuje zrodla z $PARENT do $ROOT ..."

for dir in victim bot probe monitoring; do
  if [ ! -e "$dir" ]; then
    ln -sf "$PARENT/$dir" "$dir"
    echo "  -> $dir (symlink)"
  else
    echo "  -> $dir (juz istnieje)"
  fi
done

mkdir -p results

echo "[setup] Gotowe. Teraz odpal: bash run-experiments.sh"
