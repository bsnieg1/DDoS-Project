#!/usr/bin/env bash
# Jeden scenariusz. Sampler 1s: CPU(cgroup)+mem+nginx(active/reqs/accepts ze stub).
# 429 liczone RAZ na koniec z access.log (truncowanego na starcie) -> stats.csv.
# Użycie: runseg.sh <scenario> <mode> <level> <attacker> <dur>   attacker: idle|bot|<klienci>
set -u
SP="/c/Users/kubal/AppData/Local/Temp/claude/5e5918a8413307bf/f6fdd80f-03f5-4b24-af5e-60f3345b4710/scratchpad"
CSV="$SP/results.csv"; TL="$SP/timeline.txt"; ATK="$SP/attackers.txt"; STATS="$SP/stats.csv"
cd /c/Users/kubal/ddos-lab
SC=$1; MODE=$2; LVL=$3; ATKR=$4; DUR=$5; M=64

[ -f "$CSV" ]   || echo "scenario,mode,level,epoch,iso,cpu_pct,mem_mib,ngx_active,ngx_reqs_total,ngx_accepts_total" > "$CSV"
[ -f "$STATS" ] || echo "scenario,mode,level,attacker,dur,total_log,s2xx,s429,other" > "$STATS"
log(){ echo "$(date '+%Y-%m-%d %H:%M:%S') | $*" | tee -a "$TL"; }

# tylko CPU+mem (oba natychmiastowe)
vics(){ timeout 6 docker exec lab-victim sh -c 'u=$(awk "/usage_usec/{print \$2}" /sys/fs/cgroup/cpu.stat); m=$(cat /sys/fs/cgroup/memory.current); echo "$u $m"' 2>/dev/null; }
stub(){ timeout 6 docker exec lab-loadgen sh -c 'curl -sk https://victim/status 2>/dev/null' | awk '/Active connections/{a=$3} /^ [0-9]/{acc=$1; req=$3} END{print a" "req" "acc}'; }

prev_u=""; prev_t=""
sample(){ local now u m cpu act req acc dt mib
  now=$(date +%s%N); read u m <<<"$(vics)"; read act req acc <<<"$(stub)"
  [ -z "${u:-}" ] && return
  if [ -n "$prev_u" ]; then dt=$(((now-prev_t)/1000)); [ "$dt" -gt 0 ] && cpu=$(awk "BEGIN{d=$u-$prev_u;if(d<0)d=0;printf \"%.1f\",d/$dt*100}") || cpu=0; else cpu=0; fi
  prev_u=$u; prev_t=$now; mib=$(awk "BEGIN{printf \"%.1f\", ${m:-0}/1048576}")
  echo "$SC,$MODE,$LVL,$(date +%s),$(date '+%H:%M:%S'),$cpu,$mib,${act:-0},${req:-0},${acc:-0}" >> "$CSV"
}

# launch attacker
if [ "$ATKR" = "bot" ]; then
  docker exec -d lab-bot sh -c 'end=$(( $(date +%s) + '"$DUR"' )); : > /tmp/bot.out; while [ $(date +%s) -lt $end ]; do rapidreset -url https://victim:443 -requests 20000 -concurrency 1000 >> /tmp/bot.out 2>&1; done' >/dev/null 2>&1
  log "START $SC (mode=$MODE bot rapid-reset dur=${DUR}s)"
elif [ "$ATKR" = "idle" ]; then
  log "START $SC (baseline idle dur=${DUR}s)"
else
  docker exec -d lab-loadgen sh -c "h2load -c $ATKR -m $M -D $DUR https://victim/ > /tmp/atk.out 2>&1" >/dev/null 2>&1
  log "START $SC (mode=$MODE load~${LVL}% c=$ATKR dur=${DUR}s)"
fi

end=$(( $(date +%s) + DUR ))
while [ $(date +%s) -lt $end ]; do sample; sleep 1; done
log "END   $SC"

# status breakdown z raportu klienta h2load (bez czytania access.log)
tot=0; s2=0; s4=0
if [ "$ATKR" != "bot" ] && [ "$ATKR" != "idle" ]; then
  sc_line=$(timeout 6 docker exec lab-loadgen sh -c 'grep "status codes" /tmp/atk.out 2>/dev/null | tail -1')
  rq_line=$(timeout 6 docker exec lab-loadgen sh -c 'grep "requests:" /tmp/atk.out 2>/dev/null | tail -1')
  s2=$(echo "$sc_line" | grep -oE '[0-9]+ 2xx' | grep -oE '^[0-9]+'); s2=${s2:-0}
  s4=$(echo "$sc_line" | grep -oE '[0-9]+ 4xx' | grep -oE '^[0-9]+'); s4=${s4:-0}
  tot=$(echo "$rq_line" | grep -oE '[0-9]+ total' | grep -oE '^[0-9]+'); tot=${tot:-0}
fi
oth=$(( tot - s2 - s4 ))
echo "$SC,$MODE,$LVL,$ATKR,$DUR,$tot,$s2,$s4,$oth" >> "$STATS"
log "STATS $SC: total=$tot 2xx=$s2 4xx/429=$s4"

# attacker client-side summary
if [ "$ATKR" = "bot" ]; then
  echo "== $SC (bot rapid-reset) ==" >> "$ATK"
  docker exec lab-bot sh -c 'h=$(grep -oE "HEADERS = [0-9]+" /tmp/bot.out|awk "{s+=\$3}END{print s}"); r=$(grep -oE "RST_STREAM = [0-9]+" /tmp/bot.out|awk "{s+=\$3}END{print s}"); n=$(grep -c Summary /tmp/bot.out); echo "reconnecty=$n HEADERS=$h RST_STREAM=$r"' >> "$ATK" 2>&1
  echo >> "$ATK"
elif [ "$ATKR" != "idle" ]; then
  echo "== $SC (h2load c=$ATKR) ==" >> "$ATK"
  docker exec lab-loadgen sh -c 'grep -E "finished in|requests:|status codes|req/s" /tmp/atk.out 2>/dev/null' >> "$ATK" 2>&1
  echo >> "$ATK"
fi
echo "SEGDONE $SC" > "$SP/seg.done"
