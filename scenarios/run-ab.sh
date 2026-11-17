#!/usr/bin/env bash
# =====================================================================
# A/B HTTP/2 Rapid Reset (CVE-2023-44487) — dwie kolejne symulacje:
#
#   RUN 1  PODATNY       nginx 1.25.2 + nginx.vuln.conf   (sprzed mitygacji)
#   RUN 2  ZABEZPIECZONY nginx 1.27    + nginx.conf        (mitygacja 1.25.3+)
#
# Dla kazdej fazy skrypt:
#   1. stawia stos (victim + loadgen + bot [+ monitoring]),
#   2. czeka az victim odpowiada po HTTP/2,
#   3. mierzy baseline (h2load) na czystym serwerze,
#   4. odpala atak `rapidreset` i RÓWNOCZEŚNIE ruch legalny (h2load),
#      probkujac przy tym CPU kontenera victim,
#   5. zapisuje metryki do results/<timestamp>/<faza>.env
#
# Na koniec drukuje tabele porownawcza i zapisuje summary.md + results.csv.
#
# Kluczowe sygnaly holistyczne:
#   - atakujacy:  HEADERS/RST wyslane, rps, GOAWAY, bledy wysylki
#                 (GOAWAY>0 lub bledy>0  => serwer ZAMKNAL polaczenie floodu)
#   - ofiara:     CPU peak/avg, req/s ruchu legalnego W TRAKCIE ataku,
#                 liczba nieudanych zadan legalnych (impact na uzytkownika)
#
# Uruchomienie (z Git Bash / WSL, z katalogu projektu):
#   bash scenarios/run-ab.sh
#   bash scenarios/run-ab.sh --with-monitoring      # dodatkowo Zabbix
#   ATTACK_REQUESTS=40000 ATTACK_CONC=400 bash scenarios/run-ab.sh
#   bash scenarios/run-ab.sh --down                 # posprzataj na koncu
# =====================================================================
set -euo pipefail

# MSYS (Git Bash) inaczej mangluje argumenty typu https://victim:443 i /status.
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'

# --- Parametry (nadpisywalne przez zmienne srodowiskowe / flagi) ---
ATTACK_REQUESTS="${ATTACK_REQUESTS:-20000}"   # ile strumieni HEADERS+RST
ATTACK_CONC="${ATTACK_CONC:-200}"             # rozmiar bufora workerow
LEGIT_N="${LEGIT_N:-3000}"                    # zadan legalnych w trakcie ataku
LEGIT_C="${LEGIT_C:-20}"                      # polaczen klienta legalnego
WITH_MONITORING=0
DO_DOWN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --with-monitoring) WITH_MONITORING=1 ;;
    --down)            DO_DOWN=1 ;;
    --attack)          ATTACK_REQUESTS="$2"; shift ;;
    --conc)            ATTACK_CONC="$2"; shift ;;
    *) echo "Nieznana flaga: $1" >&2; exit 2 ;;
  esac
  shift
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BASE=(-f docker-compose.yml -f docker-compose.override.yml)
MON=()
[ "$WITH_MONITORING" -eq 1 ] && MON=(-f docker-compose.monitoring.yml)
VULN=(-f docker-compose.vuln.yml)

TS="$(date +%Y%m%d-%H%M%S)"
OUT="results/$TS"
mkdir -p "$OUT"
echo "[*] Wyniki -> $OUT"

FILES=()   # ustawiane per faza

dc()   { docker compose "${FILES[@]}" "$@"; }
# wywolania w kontenerach (bez TTY -> bezpieczne w skrypcie/CI)
ex()   { docker compose "${FILES[@]}" exec -T "$@"; }

wait_victim() {
  echo -n "[*] Czekam na victim (HTTP/2)"
  for _ in $(seq 1 60); do
    code="$(ex loadgen curl -k --http2 -s -o /dev/null -w '%{http_code}' https://victim/ 2>/dev/null || true)"
    if [ "$code" = "200" ]; then echo " OK"; return 0; fi
    echo -n "."; sleep 1
  done
  echo " BLAD: victim nie wstal"; return 1
}

# stub_status -> "Active connections: N" + linia "A H R" (accepts handled requests)
stub_total() { ex loadgen curl -k -s https://victim/status 2>/dev/null \
                 | awk '/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+[[:space:]]*$/{print $3}'; }

cpu_sampler() { # $1 = plik wyjsciowy; probkuje CPU% victima co ~1s
  while :; do
    docker stats --no-stream --format '{{.CPUPerc}}' lab-victim 2>/dev/null | tr -d '%'
    sleep 1
  done >> "$1"
}

num() { # bezpieczne "0" gdy pusto
  local v="$1"; [ -n "$v" ] && echo "$v" || echo 0
}

run_phase() {
  local name="$1"; shift
  FILES=("$@")
  local env_file="$OUT/$name.env"
  echo
  echo "============================================================"
  echo "   FAZA: $name"
  echo "============================================================"

  echo "[*] Stawiam stos (--build) ..."
  dc up -d --build >/dev/null 2>&1 || dc up -d --build
  wait_victim

  # Baseline na czystym serwerze (przed atakiem)
  echo "[*] Baseline h2load (czysty serwer) ..."
  ex loadgen h2load -n 2000 -c 20 https://victim/ > "$OUT/$name.baseline.txt" 2>&1 || true
  local base_rps
  base_rps="$(grep -oE '[0-9.]+ req/s' "$OUT/$name.baseline.txt" | head -1 | grep -oE '[0-9.]+' || echo 0)"

  local stub_before stub_after
  stub_before="$(num "$(stub_total)")"

  # Start probkowania CPU
  local cpu_file="$OUT/$name.cpu.txt"; : > "$cpu_file"
  cpu_sampler "$cpu_file" &
  local CPU_PID=$!

  # Start ataku w tle
  echo "[*] Atak rapidreset: requests=$ATTACK_REQUESTS conc=$ATTACK_CONC ..."
  ex bot rapidreset -quiet -url https://victim:443 \
      -requests "$ATTACK_REQUESTS" -concurrency "$ATTACK_CONC" -wait 0 \
      > "$OUT/$name.attack.txt" 2>&1 &
  local ATK_PID=$!

  # Rownoczesnie: ruch legalny (to mierzy REALNY wplyw na uzytkownika)
  echo "[*] Ruch legalny w trakcie ataku (h2load -n $LEGIT_N -c $LEGIT_C) ..."
  ex loadgen h2load -n "$LEGIT_N" -c "$LEGIT_C" https://victim/ > "$OUT/$name.legit.txt" 2>&1 || true

  wait "$ATK_PID" 2>/dev/null || true
  kill "$CPU_PID" 2>/dev/null || true
  wait "$CPU_PID" 2>/dev/null || true

  stub_after="$(num "$(stub_total)")"

  # --- Parsowanie metryk ---
  local a="$OUT/$name.attack.txt"
  local headers rsts recv goaway serr rps
  headers="$(grep -oE 'HEADERS = [0-9]+' "$a" | grep -oE '[0-9]+' || echo 0)"
  rsts="$(grep -oE 'RST_STREAM = [0-9]+' "$a" | grep -oE '[0-9]+' || echo 0)"
  recv="$(grep -oE 'Frames received: [0-9]+' "$a" | grep -oE '[0-9]+' || echo 0)"
  goaway="$(grep -oE 'GOAWAY received: [0-9]+' "$a" | grep -oE '[0-9]+' || echo 0)"
  serr="$(grep -oE 'Send errors \(conn closed\): [0-9]+' "$a" | grep -oE '[0-9]+$' || echo 0)"
  rps="$(grep -oE '\([0-9]+ rps\)' "$a" | grep -oE '[0-9]+' || echo 0)"

  local lg="$OUT/$name.legit.txt"
  local legit_rps legit_fail legit_mean
  legit_rps="$(grep -oE '[0-9.]+ req/s' "$lg" | head -1 | grep -oE '[0-9.]+' || echo 0)"
  legit_fail="$(grep -oE '[0-9]+ failed' "$lg" | head -1 | grep -oE '[0-9]+' || echo 0)"
  legit_mean="$(awk '/time for request:/{print $5}' "$lg" | head -1 || echo n/a)"

  local cpu_peak cpu_avg
  cpu_peak="$(awk 'BEGIN{m=0}{if($1+0>m)m=$1}END{printf "%.1f", m}' "$cpu_file" 2>/dev/null || echo 0)"
  cpu_avg="$(awk '{s+=$1;n++}END{if(n)printf "%.1f", s/n; else print 0}' "$cpu_file" 2>/dev/null || echo 0)"

  local nginx_reqs=$(( stub_after - stub_before ))
  local defended="NIE"
  if [ "$goaway" -gt 0 ] || [ "$serr" -gt 0 ]; then defended="TAK"; fi

  # --- Zapis ---
  {
    echo "phase=$name"
    echo "baseline_rps=$base_rps"
    echo "attack_headers=$headers"
    echo "attack_rsts=$rsts"
    echo "attack_rps=$rps"
    echo "attack_recv_frames=$recv"
    echo "attack_goaway=$goaway"
    echo "attack_send_errors=$serr"
    echo "defended_early=$defended"
    echo "legit_rps_under_attack=$legit_rps"
    echo "legit_failed=$legit_fail"
    echo "legit_mean_latency=$legit_mean"
    echo "cpu_peak_pct=$cpu_peak"
    echo "cpu_avg_pct=$cpu_avg"
    echo "nginx_requests_delta=$nginx_reqs"
  } > "$env_file"

  echo "[*] Faza $name gotowa -> $env_file"
}

# ====================== URUCHOMIENIE OBU FAZ ======================
run_phase vulnerable  "${BASE[@]}" "${MON[@]}" "${VULN[@]}"
run_phase secure      "${BASE[@]}" "${MON[@]}"

# ====================== RAPORT PORÓWNAWCZY ========================
# shellcheck disable=SC1090
. "$OUT/vulnerable.env"; v_brps=$baseline_rps; v_head=$attack_headers; v_rst=$attack_rsts
v_rps=$attack_rps; v_goaway=$attack_goaway; v_serr=$attack_send_errors; v_def=$defended_early
v_lrps=$legit_rps_under_attack; v_lfail=$legit_failed; v_lmean=$legit_mean_latency
v_cpk=$cpu_peak_pct; v_cav=$cpu_avg_pct; v_nreq=$nginx_requests_delta

. "$OUT/secure.env"; s_brps=$baseline_rps; s_head=$attack_headers; s_rst=$attack_rsts
s_rps=$attack_rps; s_goaway=$attack_goaway; s_serr=$attack_send_errors; s_def=$defended_early
s_lrps=$legit_rps_under_attack; s_lfail=$legit_failed; s_lmean=$legit_mean_latency
s_cpk=$cpu_peak_pct; s_cav=$cpu_avg_pct; s_nreq=$nginx_requests_delta

row() { printf "%-34s | %-18s | %-18s\n" "$1" "$2" "$3"; }
line() { printf '%.0s-' $(seq 1 76); echo; }

REPORT="$OUT/summary.md"
{
  echo "# A/B Rapid Reset — wyniki ($TS)"
  echo
  echo "Atak: requests=$ATTACK_REQUESTS, concurrency=$ATTACK_CONC."
  echo "Ruch legalny w trakcie ataku: h2load -n $LEGIT_N -c $LEGIT_C."
  echo
  echo "| Metryka | PODATNY (nginx 1.25.2) | ZABEZPIECZONY (nginx 1.27) |"
  echo "|---|---|---|"
  echo "| Baseline req/s (czysty serwer) | $v_brps | $s_brps |"
  echo "| HEADERS wyslane | $v_head | $s_head |"
  echo "| RST_STREAM wyslane | $v_rst | $s_rst |"
  echo "| Tempo ataku (rps) | $v_rps | $s_rps |"
  echo "| GOAWAY odebrane | $v_goaway | $s_goaway |"
  echo "| Bledy wysylki (conn zamkniete) | $v_serr | $s_serr |"
  echo "| **Serwer obronil sie (zamknal flood)** | **$v_def** | **$s_def** |"
  echo "| req/s ruchu legalnego POD atakiem | $v_lrps | $s_lrps |"
  echo "| Nieudane zadania legalne | $v_lfail | $s_lfail |"
  echo "| Srednia latencja legalna | $v_lmean | $s_lmean |"
  echo "| CPU victim peak % | $v_cpk | $s_cpk |"
  echo "| CPU victim avg % | $v_cav | $s_cav |"
  echo "| nginx zadania (delta) | $v_nreq | $s_nreq |"
} > "$REPORT"

CSV="$OUT/results.csv"
{
  echo "metric,vulnerable,secure"
  echo "baseline_rps,$v_brps,$s_brps"
  echo "attack_headers,$v_head,$s_head"
  echo "attack_rsts,$v_rst,$s_rst"
  echo "attack_rps,$v_rps,$s_rps"
  echo "attack_goaway,$v_goaway,$s_goaway"
  echo "attack_send_errors,$v_serr,$s_serr"
  echo "defended_early,$v_def,$s_def"
  echo "legit_rps_under_attack,$v_lrps,$s_lrps"
  echo "legit_failed,$v_lfail,$s_lfail"
  echo "cpu_peak_pct,$v_cpk,$s_cpk"
  echo "cpu_avg_pct,$v_cav,$s_cav"
  echo "nginx_requests_delta,$v_nreq,$s_nreq"
} > "$CSV"

echo
line
echo "  WYNIKI A/B — HTTP/2 Rapid Reset"
line
row "Metryka" "PODATNY 1.25.2" "ZABEZP. 1.27"
line
row "Baseline req/s" "$v_brps" "$s_brps"
row "HEADERS wyslane" "$v_head" "$s_head"
row "RST_STREAM wyslane" "$v_rst" "$s_rst"
row "Tempo ataku (rps)" "$v_rps" "$s_rps"
row "GOAWAY odebrane" "$v_goaway" "$s_goaway"
row "Bledy wysylki (conn zamkn.)" "$v_serr" "$s_serr"
row "Obronil sie (zamknal flood)" "$v_def" "$s_def"
row "Legalny req/s pod atakiem" "$v_lrps" "$s_lrps"
row "Nieudane zadania legalne" "$v_lfail" "$s_lfail"
row "CPU peak %" "$v_cpk" "$s_cpk"
row "CPU avg %" "$v_cav" "$s_cav"
line
echo
echo "[*] Raport:  $REPORT"
echo "[*] CSV:     $CSV"
[ "$WITH_MONITORING" -eq 1 ] && echo "[*] Zabbix:  http://localhost:8080  (Admin/zabbix) — timeline obu faz"

if [ "$DO_DOWN" -eq 1 ]; then
  echo "[*] Sprzatam (docker compose down) ..."
  FILES=("${BASE[@]}" "${MON[@]}" "${VULN[@]}")
  dc down >/dev/null 2>&1 || true
fi
