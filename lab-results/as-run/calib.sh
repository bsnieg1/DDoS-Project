#!/usr/bin/env bash
# Kalibracja: znajdź parametry h2load dające ~20/50/100% CPU victima (limit 1 rdzeń).
set -u
OUT="/c/Users/kubal/AppData/Local/Temp/claude/5e5918a8413307bf/f6fdd80f-03f5-4b24-af5e-60f3345b4710/scratchpad/calib.out"
: > "$OUT"

cpu_usec(){ docker exec lab-victim sh -c 'awk "/usage_usec/{print \$2}" /sys/fs/cgroup/cpu.stat' 2>/dev/null; }

measure(){ # c m
  local c=$1 m=$2
  docker exec -d lab-loadgen sh -c "h2load -c $c -m $m -D 14 https://victim/ >/tmp/h.out 2>&1" >/dev/null 2>&1
  sleep 3                      # warmup
  local a t0 b t1 dt pct
  a=$(cpu_usec); t0=$(date +%s%N)
  sleep 8
  b=$(cpu_usec); t1=$(date +%s%N)
  dt=$(( (t1 - t0) / 1000 ))   # usec
  pct=$(awk "BEGIN{printf \"%.0f\", ($b-$a)/$dt*100}")
  sleep 4                      # pozwól h2load dokończyć
  local rps
  rps=$(docker exec lab-loadgen sh -c 'grep -E "finished in|req/s" /tmp/h.out 2>/dev/null' | tr "\n" " ")
  echo "c=$c m=$m CPU=${pct}% | $rps" | tee -a "$OUT"
  sleep 3                      # cisza między próbami
}

echo "# kalibracja start $(date)" | tee -a "$OUT"
for c in 4 10 25 50 100 200; do
  measure "$c" 64
done
echo "# koniec" | tee -a "$OUT"
