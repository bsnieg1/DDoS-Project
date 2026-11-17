#!/usr/bin/env bash
# =============================================================================
# run-experiments.sh — odpal 4 eksperymenty HTTP/2 Rapid Reset, kazdy z
# wlasnym Zabbixem. Eksperymenty ida SEKWENCYJNIE (wspolne rdzenie CPU),
# ale wszystkie 4 Zabbixy zostaja wlaczone po zakonczeniu — mozesz wejsc
# na kazdy i porownac dane.
#
# Uzycie:
#   cd /sciezka/do/projektu/cloud
#   bash run-experiments.sh
#
# Po zakonczeniu:
#   Zabbix exp1 (old-normal):   http://<IP>:8081  (Admin/zabbix)
#   Zabbix exp2 (old-hardened): http://<IP>:8082
#   Zabbix exp3 (new-normal):   http://<IP>:8083
#   Zabbix exp4 (new-hardened): http://<IP>:8084
#
# Dane sondy: results/<wariant>/probe.csv
#
# Parametry (zmienne srodowiskowe):
#   BASELINE_SEC   czas baseline bez ataku (domyslnie 120 = 2 min)
#   RAMP_SEC       czas na fazie 10 botow (domyslnie 120 = 2 min)
#   PEAK_SEC       czas na fazie 30 botow (domyslnie 180 = 3 min)
#   COOLDOWN_SEC   czas uspokojenia po ataku (domyslnie 60 = 1 min)
#   FLEET_CPUSET   rdzenie dla floty botow (domyslnie "3-7")
#   FLEET_CPUS     limit CPU na bota (domyslnie 0.5)
# =============================================================================
set -euo pipefail

BASELINE_SEC="${BASELINE_SEC:-120}"
RAMP_SEC="${RAMP_SEC:-120}"
PEAK_SEC="${PEAK_SEC:-180}"
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

# ---------- 1. Zbuduj wspolne obrazy ----------
log "Buduje obraz floty (bot) ..."
docker build -q -t "$FLEET_IMAGE" ../bot >/dev/null
log "Obraz floty gotowy."

log "Buduje obraz sondy (probe) ..."
docker build -q -t lab-probe:latest ../probe >/dev/null
log "Obraz sondy gotowy."

# Katalogi wynikow
mkdir -p results/old-normal results/old-hardened results/new-normal results/new-hardened

# ---------- 2. Funkcje floty ----------
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

# ---------- 3. Uruchom eksperyment ----------
run_experiment() {
  local envfile="$1" label="$2" port="$3" exp
  exp=$(grep COMPOSE_PROJECT_NAME "$envfile" | cut -d= -f2)

  echo ""
  log "${C_Y}====== EKSPERYMENT: $label (Zabbix :$port) ======${C_0}"

  # Postaw stos
  log "Stawiam stos ($label) ..."
  dc "$envfile" up -d --build victim zabbix-db zabbix-server zabbix-web probe

  # Czekaj na victim
  log "Czekam na victim ..."
  wait_victim "$exp" || { log "${C_R}victim nie odpowiedzial!${C_0}"; return 1; }
  log "victim gotowy."

  # Provisioning Zabbix
  log "Provisionuje Zabbix ..."
  dc "$envfile" run --rm zabbix-provision 2>&1 | tail -3

  # Baseline
  log "Baseline (${BASELINE_SEC}s bez ataku) ..."
  sleep "$BASELINE_SEC"

  # Faza 1: 10 botow
  log "${C_R}Atak: 10 botow (${RAMP_SEC}s) ...${C_0}"
  create_bots "$exp" 10
  fire_attack "$exp"
  sleep "$RAMP_SEC"

  # Faza 2: 30 botow
  log "${C_R}Atak: skaluje do 30 botow (${PEAK_SEC}s) ...${C_0}"
  create_bots "$exp" 30
  fire_attack "$exp"
  sleep "$PEAK_SEC"

  # Stop
  log "${C_G}Stop ataku + cooldown (${COOLDOWN_SEC}s) ...${C_0}"
  stop_attack "$exp"
  remove_bots "$exp"
  sleep "$COOLDOWN_SEC"

  # Zostawiamy Zabbix + probe
  log "${C_G}Eksperyment $label zakonczony. Zabbix :$port dziala.${C_0}"
}

# ---------- 4. Odpal wszystkie 4 ----------
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
log "${C_G}Wszystkie 4 eksperymenty zakonczone (${ELAPSED} min).${C_0}"
log "${C_G}========================================${C_0}"
echo ""
echo "Zabbix dashboardy (Admin / zabbix):"
echo "  old-normal:   http://$(hostname -I | awk '{print $1}'):8081"
echo "  old-hardened: http://$(hostname -I | awk '{print $1}'):8082"
echo "  new-normal:   http://$(hostname -I | awk '{print $1}'):8083"
echo "  new-hardened: http://$(hostname -I | awk '{print $1}'):8084"
echo ""
echo "Dane sondy: results/*/probe.csv"
echo ""
echo "Aby zdjac wszystko:"
echo "  for e in env/exp*.env; do docker compose --env-file \$e -f docker-compose.experiment.yml down -v; done"
