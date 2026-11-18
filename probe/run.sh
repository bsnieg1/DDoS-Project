#!/bin/sh
# Legitimate client latency probe. Every WINDOW seconds sends a low, constant
# stream of requests (RATE/s - MEASUREMENT, not an attack) to the victim and
# reports response time (p50/p95/p99), success% and actual throughput. This is a
# reliable signal for "is the server degrading": when the fleet pushes, p95 rises
# and success drops.
#
# Output: line to stdout (visible in `docker logs lab-probe` and in control.sh
# 'status'/'probe') + row to CSV (/data/probe.csv) for later charts.
#
# Configuration (env):
#   TARGET  victim URL (default https://victim/)
#   RATE    legitimate requests/s (default 10 - intentionally low, this is a measurement)
#   WINDOW  measurement window length in seconds (default 2)
#   CSV     CSV file (default /data/probe.csv)
set -u

TARGET="${TARGET:-https://victim/}"
RATE="${RATE:-10}"
WINDOW="${WINDOW:-2}"
CSV="${CSV:-/data/probe.csv}"

mkdir -p "$(dirname "$CSV")" 2>/dev/null || true
if [ ! -f "$CSV" ]; then
  echo "epoch,iso,p50_ms,p95_ms,p99_ms,max_ms,success_pct,rps,requests" > "$CSV"
fi

echo "[probe] target=$TARGET rate=${RATE}/s window=${WINDOW}s -> CSV=$CSV"

while true; do
  json=$(echo "GET $TARGET" \
    | vegeta attack -insecure -rate="${RATE}/s" -duration="${WINDOW}s" -timeout=5s 2>/dev/null \
    | vegeta report -type=json 2>/dev/null)

  if [ -z "$json" ]; then
    # vegeta returned nothing (e.g. victim completely unreachable)
    epoch=$(date +%s); iso=$(date '+%H:%M:%S')
    echo "$epoch,$iso,,,,,0,0,0" >> "$CSV"
    printf '%s  p95=  --    success=  0%%   (no response)\n' "$iso"
    sleep 1; continue
  fi

  p50=$(echo "$json" | jq -r '.latencies["50th"]/1e6 | (.*100|round)/100')
  p95=$(echo "$json" | jq -r '.latencies["95th"]/1e6 | (.*100|round)/100')
  p99=$(echo "$json" | jq -r '.latencies["99th"]/1e6 | (.*100|round)/100')
  pmax=$(echo "$json" | jq -r '.latencies.max/1e6 | (.*100|round)/100')
  succ=$(echo "$json" | jq -r '.success*100 | (.*10|round)/10')
  rps=$(echo "$json" | jq -r '.throughput | (.*10|round)/10')
  reqs=$(echo "$json" | jq -r '.requests')

  epoch=$(date +%s); iso=$(date '+%H:%M:%S')
  echo "$epoch,$iso,$p50,$p95,$p99,$pmax,$succ,$rps,$reqs" >> "$CSV"

  # Readable live line; flag when server is choking.
  flag=""
  case "$succ" in 100|100.0) : ;; *) flag="  <-- AVAILABILITY DROP" ;; esac
  printf '%s  p50=%-7s p95=%-8s p99=%-8s success=%-5s%%  rps=%-6s%s\n' \
    "$iso" "$p50" "$p95" "$p99" "$succ" "$rps" "$flag"
done
