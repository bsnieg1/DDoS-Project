#!/usr/bin/env bash
# =============================================================================
# 3D Matrix: TRAFFIC TYPE x SERVER VARIANT x BOTNET SIZE
#
#   traffic type:  attack (rapidreset: HEADERS+RST_STREAM) | legit (h2load: complete requests)
#   variant:       old_normal | old_hardened | new_normal | new_hardened
#                  (old = nginx 1.25.1, pre-mitigation 1.25.3; new = nginx 1.27)
#   size:          1 5 10 25 50 100 (configurable via SIZES)
#
# For each combination measures (all sampled via `docker stats`, one
# call/second returns victim + active bot subset at once - no unnecessary
# additional docker exec calls):
#   - victim CPU% (lab-victim)
#   - SUM of CPU% of bots actively generating traffic in this step (attacker cost)
#   - connection/request delta from nginx stub_status
#
# The botfleet fleet is brought up ONCE to max(SIZES) and kept for the entire
# matrix; each step uses only the first N containers from that (stable)
# list of IDs. Victim is rebuilt/restarted between variants
# (docker-compose.labvic.yml, variables NGINX_OLD / VICTIM_MODE).
#
# Output: $OUTDIR/raw.csv (long format, 1 row = 1 repetition),
#         $OUTDIR/timeline.txt (run log)
#
# Parameters (environment variables):
#   SIZES="1 5 10 25 50 100"
#   MODES="attack legit"
#   REPS=2            repetitions per matrix cell
#   REQ=2000 CONC=100  per-bot parameters per single burst (CONSTANT across the entire
#                      matrix, only N varies - to isolate the effect of botnet size)
#   WARM=3 WIN=4 NWIN=2 GAP=3   measurement windows (seconds)
#   BOT_CPUS=0.5 VIC_CPUS=2     CPU limits (VIC_CPUS must match
#                               worker_processes in victim/nginx*.conf!)
#
# CORE ISOLATION: victim is pinned to cores 0,1, fleet to 2-11
# (docker-compose.labvic.yml / docker-compose.botnet.yml, cpuset). This way
# BOT_CPUS x max(SIZES) can safely exceed the number of cores available to the
# fleet (fleet containers will throttle AMONG THEMSELVES, which is OK and
# realistic - but they will NEVER steal CPU from the victim). Still, for
# readable results, keep BOT_CPUS x max(SIZES) around the number of cores
# assigned to the fleet (e.g. 10 cores -> BOT_CPUS=0.1 for SIZES up to 100).
#
# Requires: docker compose up -d --build (base lab) is NOT required upfront -
# the script builds/starts everything it needs on its own.
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

# --- 0. Fleet: bring up ONCE to NMAX, store stable list of IDs ---
log "=== SETUP: base + fleet botfleet=$NMAX (BOT_CPUS=$BOT_CPUS) ==="
BOT_CPUS="$BOT_CPUS" dc up -d --build --scale "botfleet=$NMAX"
sleep 2
ALL_BOT_IDS=($(dc ps -q botfleet))
ACTUAL_N=${#ALL_BOT_IDS[@]}
log "fleet ready: $ACTUAL_N bots (requested $NMAX)"
if [ "$ACTUAL_N" -lt "$NMAX" ]; then
  log "WARNING: got fewer bots than requested - check Docker/host limits"
fi

# --- helpers ---
stub_pair() { # returns "active req accept" from stub_status (0 0 0 on error)
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

# docker stats for victim + specific bot subset, single sample
sample_once() { # $@ = list of bot IDs to sum
  local ids=("lab-victim" "$@")
  docker stats --no-stream --format '{{.Name}}\t{{.CPUPerc}}' "${ids[@]}" 2>/dev/null
}

run_window() { # $1=duration(s) $2...=bot ids active in this step; echo "cpu_victim cpu_bots_sum"
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
  log "=== VARIANT $label (nginx=$ver, mode=$hard) ==="
  NGINX_OLD="$ver" VICTIM_MODE="$hard" VIC_CPUS="$VIC_CPUS" dc build victim >/dev/null 2>&1
  NGINX_OLD="$ver" VICTIM_MODE="$hard" VIC_CPUS="$VIC_CPUS" dc up -d --force-recreate victim >/dev/null 2>&1
  if ! wait_victim; then
    log "ERROR: victim did not start for $label - skipping"
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

# --- Baseline (no traffic, for reference) - one per variant is later in CSV as a separate size entry and is not needed; we skip it, since the smallest 'size' (1) already provides reference ---

run_variant old_normal   1.25.1-alpine normal
run_variant old_hardened 1.25.1-alpine hardened
run_variant new_normal   1.27-alpine   normal
run_variant new_hardened 1.27-alpine   hardened

log "=== MATRIX COMPLETE -> $CSV ==="
echo
echo "Rows in CSV: $(($(wc -l < "$CSV") - 1))"
echo "Next: python scenarios/make_charts.py $CSV $OUTDIR/charts"
