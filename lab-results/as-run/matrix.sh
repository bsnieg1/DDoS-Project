#!/usr/bin/env bash
# Matryca botnet (średnia z 3 okien -> tłumi burst). CPU = delta usec / czas okna.
# Użycie: matrix.sh <ver: old|new> <mode: normal|hardened>
set -u
export MSYS_NO_PATHCONV=1
SP="/c/Users/kubal/AppData/Local/Temp/claude/5e5918a8413307bf/f6fdd80f-03f5-4b24-af5e-60f3345b4710/scratchpad"
CSV="$SP/botnet.csv"; TL="$SP/botnet_timeline.txt"
cd /c/Users/kubal/ddos-lab
VER=$1; MODE=$2; IMG="labvic:$VER"
WARM=3; WIN=5; NWIN=3; GAP=4; SIZES="1 2 3 4 5"
DUR=$((WARM + WIN*NWIN + 2))

[ -f "$CSV" ] || echo "config,ver,hard,size,cpu_pct,active" > "$CSV"
log(){ echo "$(date '+%H:%M:%S') | $*" | tee -a "$TL"; }
cpu_usec(){ timeout 6 docker exec lab-victim2 sh -c 'awk "/usage_usec/{print \$2}" /sys/fs/cgroup/cpu.stat' 2>/dev/null; }
active(){ timeout 6 docker exec lab-loadgen sh -c 'curl -sk --max-time 4 https://victim/status 2>/dev/null' | awk '/Active/{print $3}'; }
storm(){ for b in $(seq 1 $1); do docker exec -d lab-bot$b sh -c 'end=$(( $(date +%s)+'"$2"' )); while [ $(date +%s) -lt $end ]; do rapidreset -url https://victim:443 -requests 2000 -concurrency 400 >/dev/null 2>&1; done' 2>/dev/null; done; }
stopb(){ for b in $(seq 1 $1); do docker exec lab-bot$b pkill rapidreset 2>/dev/null; done; }

docker rm -f lab-victim2 >/dev/null 2>&1
docker run -d --name lab-victim2 --network ddos-lab_labnet --network-alias victim --cpus=1.0 -e MODE=$MODE "$IMG" >/dev/null 2>&1
log "=== CONFIG $VER/$MODE ==="
i=0; while [ $i -lt 20 ]; do timeout 4 docker exec lab-loadgen sh -c 'curl -sk --max-time 3 https://victim/status >/dev/null 2>&1' && break; i=$((i+1)); sleep 1; done
# pre-warm (odrzucone)
storm 2 6; sleep 6; stopb 2; sleep 3

for N in $SIZES; do
  storm $N $DUR
  sleep $WARM
  sum=0; k=0; acc=0
  for w in $(seq 1 $NWIN); do
    u0=$(cpu_usec); t0=$(date +%s%N); sleep $WIN; u1=$(cpu_usec); t1=$(date +%s%N)
    [ $w -eq 2 ] && acc=$(active)
    if [ -n "$u0" ] && [ -n "$u1" ]; then
      cw=$(awk "BEGIN{printf \"%.2f\", ($u1-$u0)/(($t1-$t0)/1000)*100}")
      sum=$(awk "BEGIN{print $sum+$cw}"); k=$((k+1))
    fi
  done
  stopb $N
  cpu=$(awk "BEGIN{if($k>0)printf \"%.1f\", $sum/$k; else print \"NA\"}")
  echo "$VER/$MODE,$VER,$MODE,$N,$cpu,${acc:-0}" >> "$CSV"
  log "size=$N -> CPU=${cpu}% active=${acc:-0}"
  sleep $GAP
done
log "CONFIG $VER/$MODE DONE"
