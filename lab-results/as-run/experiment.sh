#!/usr/bin/env bash
# Pełny eksperyment DDoS lab: 5 progów obciążenia victima (~10/20/40/55/80% CPU)
# x {bez obrony (vuln), z obroną (hard)} + baseline + autentyczny HTTP/2 Rapid Reset (bot).
# Zbiera pomiary 1-sekundowe do CSV oraz oś czasu scenariuszy (do zrzutów Zabbix).
set -u

SP="/c/Users/kubal/AppData/Local/Temp/claude/5e5918a8413307bf/f6fdd80f-03f5-4b24-af5e-60f3345b4710/scratchpad"
CSV="$SP/results.csv"
TL="$SP/timeline.txt"
ATK="$SP/attackers.txt"
cd /c/Users/kubal/ddos-lab
CF="-f docker-compose.yml -f docker-compose.override.yml -f docker-compose.monitoring.yml"
HARD="-f docker-compose.hardening.yml"

M=64
DUR=${DUR:-150}
GAP=${GAP:-35}
BASE=${BASE:-90}
BOTDUR=${BOTDUR:-150}

# 5 progów: "etykieta:liczba_klientow"
LEVELS=("10:4" "20:10" "40:25" "55:35" "80:50")

echo "scenario,mode,level,epoch,iso,cpu_pct,mem_mib,ngx_active,ngx_reqs_total,ngx_accepts_total,http429_cum" > "$CSV"
: > "$TL"; : > "$ATK"
log(){ echo "$(date '+%Y-%m-%d %H:%M:%S') | $*" | tee -a "$TL"; }

vics(){ docker exec lab-victim sh -c 'u=$(awk "/usage_usec/{print \$2}" /sys/fs/cgroup/cpu.stat); m=$(cat /sys/fs/cgroup/memory.current); r=$(grep -c "status=429" /var/log/nginx/access.log 2>/dev/null || echo 0); echo "$u $m $r"' 2>/dev/null; }
stub(){ docker exec lab-loadgen sh -c 'curl -sk https://victim/status 2>/dev/null' | awk '/Active connections/{a=$3} /^ [0-9]/{acc=$1; req=$3} END{print a" "req" "acc}'; }

prev_u=""; prev_t=""
sample(){ local sc=$1 mode=$2 lvl=$3 now u m r cpu act req acc dt mib
  now=$(date +%s%N); read u m r <<<"$(vics)"; read act req acc <<<"$(stub)"
  [ -z "${u:-}" ] && return
  if [ -n "$prev_u" ]; then dt=$(( (now-prev_t)/1000 )); [ "$dt" -gt 0 ] && cpu=$(awk "BEGIN{d=$u-$prev_u;if(d<0)d=0;printf \"%.1f\",d/$dt*100}") || cpu=0; else cpu=0; fi
  prev_u=$u; prev_t=$now; mib=$(awk "BEGIN{printf \"%.1f\", ${m:-0}/1048576}")
  echo "$sc,$mode,$lvl,$(date +%s),$(date '+%H:%M:%S'),$cpu,$mib,${act:-0},${req:-0},${acc:-0},${r:-0}" >> "$CSV"
}
run_window(){ local sc=$1 mode=$2 lvl=$3 end=$(( $(date +%s)+$4 )); prev_u=""; prev_t=""
  while [ $(date +%s) -lt $end ]; do sample "$sc" "$mode" "$lvl"; sleep 1; done; }

start_h2load(){ docker exec -d lab-loadgen sh -c "h2load -c $1 -m $M -D $DUR https://victim/ > /tmp/atk.out 2>&1" >/dev/null 2>&1; }
read_h2load(){ echo "== $1 (h2load) ==" >> "$ATK"; docker exec lab-loadgen sh -c 'grep -E "finished in|requests:|status codes|req/s" /tmp/atk.out 2>/dev/null' >> "$ATK" 2>&1; echo >> "$ATK"; }

scenario_h2(){ local sc=$1 mode=$2 lvl=$3 c=$4
  log "START $sc (mode=$mode load~${lvl}% c=$c dur=${DUR}s)"
  start_h2load "$c"; run_window "$sc" "$mode" "$lvl" "$DUR"; log "END   $sc"; read_h2load "$sc"; }

run_staircase(){ # mode
  local mode=$1 lv lbl c
  for lv in "${LEVELS[@]}"; do
    lbl=${lv%%:*}; c=${lv##*:}
    scenario_h2 "${mode}_${lbl}" "$mode" "$lbl" "$c"
    log "GAP ${GAP}s"; sleep "$GAP"
  done
}

log "=== EKSPERYMENT START ==="
# 0) baseline idle
log "START baseline_idle (${BASE}s)"; run_window "baseline" "vuln" "idle" "$BASE"; log "END baseline_idle"
log "GAP ${GAP}s"; sleep "$GAP"

# 1) TRYB PODATNY — schodki 10..80%
run_staircase "vuln"

# 2) Autentyczny HTTP/2 Rapid Reset (bot) — tryb podatny
log "START vuln_rapidreset (bot, ${BOTDUR}s)"
docker exec -d lab-bot sh -c 'end=$(( $(date +%s) + '"$BOTDUR"' )); : > /tmp/bot.out; while [ $(date +%s) -lt $end ]; do rapidreset -url https://victim:443 -requests 20000 -concurrency 1000 >> /tmp/bot.out 2>&1; done' >/dev/null 2>&1
run_window "vuln_rr" "vuln" "rr" "$BOTDUR"; log "END vuln_rapidreset"
echo "== vuln_rapidreset (bot) ==" >> "$ATK"
docker exec lab-bot sh -c 'h=$(grep -oE "HEADERS = [0-9]+" /tmp/bot.out | awk "{s+=\$3}END{print s}"); r=$(grep -oE "RST_STREAM = [0-9]+" /tmp/bot.out | awk "{s+=\$3}END{print s}"); n=$(grep -c "Summary" /tmp/bot.out); echo "reconnecty=$n HEADERS=$h RST_STREAM=$r"' >> "$ATK" 2>&1
echo >> "$ATK"
log "GAP ${GAP}s"; sleep "$GAP"

# 3) PRZEŁĄCZENIE W TRYB UTWARDZONY
log "SWITCH -> hardened"
docker compose $CF $HARD up -d victim >/dev/null 2>&1
i=0; while [ $i -lt 40 ]; do docker exec lab-loadgen sh -c 'curl -sk --max-time 2 https://victim/status >/dev/null 2>&1' && break; i=$((i+1)); sleep 1; done
log "hardened aktywny (po ${i}s)"; sleep 10

# 4) TRYB UTWARDZONY — ten sam offered load, schodki 10..80%
run_staircase "hard"

log "=== EKSPERYMENT KONIEC ==="
echo "DONE" > "$SP/experiment.done"
