#!/bin/sh
# Sonda latencji uczciwego klienta. Co WINDOW sekund wysyla do victima niski,
# staly strumien zadan (RATE/s - POMIAR, nie atak) i raportuje czas odpowiedzi
# (p50/p95/p99), success% i realna przepustowosc. To jest wiarygodny sygnal
# "czy serwer pada": gdy flota napiera, p95 rosnie i success spada.
#
# Wyjscie: linia na stdout (widoczna w `docker logs lab-probe` i w control.sh
# 'status'/'probe') + wiersz do CSV (/data/probe.csv) do pozniejszych wykresow.
#
# Konfiguracja (env):
#   TARGET  URL ofiary (domyslnie https://victim/)
#   RATE    zadan/s uczciwego ruchu (domyslnie 10 - celowo niskie, to pomiar)
#   WINDOW  dlugosc okna pomiarowego w sek (domyslnie 2)
#   CSV     plik CSV (domyslnie /data/probe.csv)
set -u

TARGET="${TARGET:-https://victim/}"
RATE="${RATE:-10}"
WINDOW="${WINDOW:-2}"
CSV="${CSV:-/data/probe.csv}"

mkdir -p "$(dirname "$CSV")" 2>/dev/null || true
if [ ! -f "$CSV" ]; then
  echo "epoch,iso,p50_ms,p95_ms,p99_ms,max_ms,success_pct,rps,requests" > "$CSV"
fi

echo "[probe] target=$TARGET rate=${RATE}/s okno=${WINDOW}s -> CSV=$CSV"

while true; do
  json=$(echo "GET $TARGET" \
    | vegeta attack -insecure -rate="${RATE}/s" -duration="${WINDOW}s" -timeout=5s 2>/dev/null \
    | vegeta report -type=json 2>/dev/null)

  if [ -z "$json" ]; then
    # vegeta nic nie zwrocilo (np. victim calkowicie nieosiagalny)
    epoch=$(date +%s); iso=$(date '+%H:%M:%S')
    echo "$epoch,$iso,,,,,0,0,0" >> "$CSV"
    printf '%s  p95=  --    success=  0%%   (brak odpowiedzi)\n' "$iso"
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

  # Czytelna linia na zywo; oznacz, gdy serwer sie dlawi.
  flag=""
  case "$succ" in 100|100.0) : ;; *) flag="  <-- SPADEK DOSTEPNOSCI" ;; esac
  printf '%s  p50=%-7s p95=%-8s p99=%-8s success=%-5s%%  rps=%-6s%s\n' \
    "$iso" "$p50" "$p95" "$p99" "$succ" "$rps" "$flag"
done
