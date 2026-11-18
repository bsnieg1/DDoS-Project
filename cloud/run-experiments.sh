#!/usr/bin/env bash
# =============================================================================
# run-experiments.sh — run 4 HTTP/2 Rapid Reset experiments, each with
# its own Zabbix. Experiments run SEQUENTIALLY (shared CPU cores),
# but all 4 Zabbix instances remain running after completion — you can open
# each one and compare the data.
#
# Usage:
#   cd /path/to/project/cloud
#   bash run-experiments.sh
#
# After completion:
#   Zabbix exp1 (old-normal):   http://<IP>:8081  (Admin/zabbix)
#   Zabbix exp2 (old-hardened): http://<IP>:8082
#   Zabbix exp3 (new-normal):   http://<IP>:8083
#   Zabbix exp4 (new-hardened): http://<IP>:8084
#
# Probe data: results/<variant>/probe.csv
#
# Parameters (environment variables):
#   BASELINE_SEC   baseline time without attack (default 120 = 2 min)
#   PHASE_SEC      time per bot phase (default 150 = 2.5 min)
#   COOLDOWN_SEC   cooldown time after attack (default 60 = 1 min)
#   FLEET_CPUSET   cores for the bot fleet (default "3-7")
#   FLEET_CPUS     CPU limit per bot (default 0.5)
# =============================================================================
set -euo pipefail

BASELINE_SEC="${BASELINE_SEC:-120}"
PHASE_SEC="${PHASE_SEC:-150}"
COOLDOWN_SEC="${COOLDOWN_SEC:-60}"
FLEET_CPUSET="${FLEET_CPUSET:-3-7}"
FLEET_CPUS="${FLEET_CPUS:-0.5}"
FLEET_IMAGE="lab-fleetbot:latest"

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

C_G='\033[32m'; C_R='\033[31m'; C_Y='\033[33m'; C_B='\033[36m'; C_0='\033[0m'

dc() {
  local envfile="$1"; shift
  docker compose --env-file "$envfile" -f docker-compose.experiment.yml "$@"
}

log() { echo -e "${C_B}[$(date +%H:%M:%S)]${C_0} $*"; }

# ---------- 1. Build shared images ----------
log "Building fleet image (bot) ..."
docker build -q -t "$FLEET_IMAGE" ../bot >/dev/null
log "Fleet image ready."

log "Building probe image (probe) ..."
docker build -q -t lab-probe:latest ../probe >/dev/null
log "Probe image ready."

# Result directories
mkdir -p results/old-normal results/old-hardened results/new-normal results/new-hardened

# ---------- 2. Fleet functions ----------
fleet_names() {
  docker ps --filter "label=lab-exp=$1" --format '{{.Names}}' 2>/dev/null
}

create_bots() {
  local exp="$1" n="$2" net="${exp}_labnet"
  local existing
  existing=$(fleet_names "$exp" | wc -l)
  local i
  for i in $(seq $((existing + 1)) "$n"); do
    docker run -d --name "${exp}-fbot-${i}" --label "lab-exp=$exp" --init \
      --network "$net" --cpuset-cpus "$FLEET_CPUSET" --cpus "$FLEET_CPUS" \
      "$FLEET_IMAGE" sleep infinity >/dev/null
  done
}

remove_bots() {
  local exp="$1"
  local names
  names=$(fleet_names "$exp")
  [ -z "$names" ] && return 0
  echo "$names" | xargs docker rm -f >/dev/null 2>&1
}

_KILL='for d in /proc/[0-9]*; do p=${d#/proc/}; [ "$p" = "1" ] && continue; [ "$p" = "$$" ] && continue; c=$(cat "$d/comm" 2>/dev/null); [ "$c" = "sleep" ] && continue; [ "$c" = "docker-init" ] && continue; kill -9 "$p" 2>/dev/null; done; exit 0'

fire_attack() {
  local exp="$1"
  local names
  names=$(fleet_names "$exp")
  local loop='while true; do rapidreset -url https://victim:443 -requests 20000 -concurrency 200 -quiet >/dev/null 2>&1; done'
  local cid
  for cid in $names; do
    docker exec "$cid" sh -c "$_KILL" >/dev/null 2>&1
    docker exec -d "$cid" sh -c "$loop"
  done
}

stop_attack() {
  local exp="$1"
  local names
  names=$(fleet_names "$exp")
  [ -z "$names" ] && return 0
  local cid
  for cid in $names; do
    docker exec "$cid" sh -c "$_KILL" >/dev/null 2>&1
  done
}

wait_victim() {
  local exp="$1" net="${exp}_labnet"
  local i=0
  while [ $i -lt 60 ]; do
    docker run --rm --network "$net" curlimages/curl:8.8.0 \
      -sk --max-time 2 https://victim/ -o /dev/null 2>/dev/null && return 0
    i=$((i + 1)); sleep 2
  done
  return 1
}

# ---------- 3. Run experiment ----------
run_experiment() {
  local envfile="$1" label="$2" port="$3" exp
  exp=$(grep COMPOSE_PROJECT_NAME "$envfile" | cut -d= -f2)

  echo ""
  log "${C_Y}====== EXPERIMENT: $label (Zabbix :$port) ======${C_0}"

  # Deploy stack
  log "Deploying stack ($label) ..."
  dc "$envfile" up -d --build victim zabbix-db zabbix-server zabbix-web probe

  # Wait for victim
  log "Waiting for victim ..."
  wait_victim "$exp" || { log "${C_R}victim did not respond!${C_0}"; return 1; }
  log "victim ready."

  # Provisioning Zabbix
  log "Provisioning Zabbix ..."
  dc "$envfile" run --rm zabbix-provision 2>&1 | tail -3

  # Baseline
  log "Baseline (${BASELINE_SEC}s without attack) ..."
  sleep "$BASELINE_SEC"

  # Phase 1: 10 bots
  log "${C_R}Attack: 10 bots (${PHASE_SEC}s) ...${C_0}"
  create_bots "$exp" 10
  fire_attack "$exp"
  sleep "$PHASE_SEC"

  # Phase 2: 30 bots
  log "${C_R}Attack: scaling to 30 bots (${PHASE_SEC}s) ...${C_0}"
  create_bots "$exp" 30
  fire_attack "$exp"
  sleep "$PHASE_SEC"

  # Phase 3: 50 bots
  log "${C_R}Attack: scaling to 50 bots (${PHASE_SEC}s) ...${C_0}"
  create_bots "$exp" 50
  fire_attack "$exp"
  sleep "$PHASE_SEC"

  # Phase 4: 100 bots
  log "${C_R}Attack: scaling to 100 bots (${PHASE_SEC}s) ...${C_0}"
  create_bots "$exp" 100
  fire_attack "$exp"
  sleep "$PHASE_SEC"

  # Stop
  log "${C_G}Stopping attack + cooldown (${COOLDOWN_SEC}s) ...${C_0}"
  stop_attack "$exp"
  remove_bots "$exp"
  sleep "$COOLDOWN_SEC"

  # Leave Zabbix + probe running
  log "${C_G}Experiment $label completed. Zabbix :$port running.${C_0}"
}

# ---------- 4. Run all 4 ----------
EXPERIMENTS=(
  "env/exp1.env old-normal 8081"
  "env/exp2.env old-hardened 8082"
  "env/exp3.env new-normal 8083"
  "env/exp4.env new-hardened 8084"
)

START_TIME=$(date +%s)

for entry in "${EXPERIMENTS[@]}"; do
  read -r envfile label port <<< "$entry"
  run_experiment "$envfile" "$label" "$port"
done

END_TIME=$(date +%s)
ELAPSED=$(( (END_TIME - START_TIME) / 60 ))

echo ""
log "${C_G}========================================${C_0}"
log "${C_G}All 4 experiments completed (${ELAPSED} min).${C_0}"
log "${C_G}========================================${C_0}"
echo ""
echo "Zabbix dashboards (Admin / zabbix):"
echo "  old-normal:   http://$(hostname -I | awk '{print $1}'):8081"
echo "  old-hardened: http://$(hostname -I | awk '{print $1}'):8082"
echo "  new-normal:   http://$(hostname -I | awk '{print $1}'):8083"
echo "  new-hardened: http://$(hostname -I | awk '{print $1}'):8084"
echo ""
echo "Probe data: results/*/probe.csv"
echo ""
echo "To tear down everything:"
echo "  for e in env/exp*.env; do docker compose --env-file \$e -f docker-compose.experiment.yml down -v; done"
