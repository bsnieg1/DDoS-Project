# Monitoring labu — serwer Zabbix + podłączony host (victim)

Opcjonalna warstwa defensywna dołożona do labu HTTP/2 (CVE-2023-44487 Rapid Reset).
Stawia **serwer Zabbix 7.0 LTS** i podłącza do niego **atakowany host `victim`**, żeby
na żywo obserwować wpływ ataku na serwer-ofiarę (CPU, pamięć, ruch sieciowy oraz
liczbę aktywnych połączeń / żądań nginx ze `stub_status`).

Bazowy lab (`victim` + `loadgen` [+ `bot` + `c2`]) działa bez tej warstwy — to
osobny plik compose, który włączasz tylko gdy chcesz monitoring.

## Co dochodzi

| Usługa | Obraz | Rola |
|---|---|---|
| `zabbix-db` | `postgres:16-alpine` | baza danych Zabbixa |
| `zabbix-server` | `zabbix/zabbix-server-pgsql:alpine-7.0-latest` | serwer Zabbix |
| `zabbix-web` | `zabbix/zabbix-web-nginx-pgsql:alpine-7.0-latest` | frontend WWW (`localhost:8080`) |
| `zabbix-provision` | `python:3.12-alpine` | jednorazowy provisioner hosta `victim` (profil `provision`) |
| `victim` (podmieniony) | build `./victim` | nginx HTTP/2 **+ zabbix-agent2** w jednym kontenerze |

Sieci:
- **`labnet`** (`internal: true`, z bazowego labu) — serwer ↔ agent(`victim`) ↔ baza, bez internetu.
- **`monnet`** (`bridge`) — jedyny powód: wystawić port `8080` frontendu na host.

## Uruchomienie

Z katalogu `ddos-lab`. Wygodnie ustawić `COMPOSE_FILE`, żeby nie dopisywać `-f`:

```bash
export COMPOSE_FILE=docker-compose.yml:docker-compose.override.yml:docker-compose.monitoring.yml
```

(PowerShell: `$env:COMPOSE_FILE="docker-compose.yml:docker-compose.override.yml:docker-compose.monitoring.yml"`)

Tylko monitoring + ofiara (bez budowania bota ataku i C2):

```bash
docker compose up -d --build victim zabbix-db zabbix-server zabbix-web
```

Albo pełny lab + monitoring naraz:

```bash
docker compose up -d --build
```

Pierwszy start serwera importuje schemat bazy — frontend bywa gotowy po ~1–2 min.

## Podłączenie hosta `victim` do Zabbixa (provisioning)

Host, grupę i szablony tworzy jednorazowy provisioner (idempotentny):

```bash
docker compose run --rm zabbix-provision
```

Skrypt loguje się do API, tworzy grupę **DDoS Lab**, hosta **victim** z interfejsem
agenta `victim:10050` i podpina szablony:
- **Linux by Zabbix agent** — CPU, pamięć, load, ruch sieciowy kontenera victim (z agenta),
- **Nginx by HTTP** — `stub_status` po HTTPS (aktywne połączenia, liczba żądań).

Po chwili w **Monitoring → Hosts** host `victim` powinien zświecić się na zielono
(ZBX). Jeśli wolisz klikać ręcznie — patrz sekcja „Ręczna konfiguracja" niżej.

## Pula wielu maszyn (fleet) z autorejestracją

Chcesz kilka monitorowanych maszyn naraz (np. 4–5)? Służy do tego overlay
`docker-compose.victims.yml` — skalowalna usługa `victim-node` (ten sam obraz:
nginx HTTP/2 + zabbix-agent2). Każda replika zgłasza się sama do serwera
(**autoregistration**), więc nie dodajesz hostów ręcznie.

Jednorazowo włącz regułę autorejestracji (tworzy akcję + grupę „DDoS Lab Pool",
podpina szablon *Linux by Zabbix agent*):

```bash
docker compose \
  -f docker-compose.yml -f docker-compose.override.yml \
  -f docker-compose.monitoring.yml -f docker-compose.victims.yml \
  run --rm zabbix-autoreg
```

Odpal 5 maszyn (zmień liczbę przez `--scale victim-node=N`):

```bash
docker compose \
  -f docker-compose.yml -f docker-compose.override.yml \
  -f docker-compose.monitoring.yml -f docker-compose.victims.yml \
  up -d --build --scale victim-node=5 victim-node
```

Po ~1–2 min w **Monitoring → Hosts** pojawią się hosty `victim-<id>` (np.
`victim-c73efa73e066`) w grupie **DDoS Lab Pool**, każdy zbierający CPU/RAM/sieć.
Nazwa = `victim-` + skrócony id kontenera (unikatowa per replika).

Zmniejszenie/zwiększenie liczby: ponów `up -d --scale victim-node=N`. Usunięte
repliki zostaną w Zabbixie jako „martwe" hosty (brak danych) — możesz je skasować
w **Data collection → Hosts** albo przez API.

> Pula jest niezależna od bazowego, atakowanego hosta `victim` (DNS `victim`),
> którego używają `bot` i `loadgen`. Pula to dodatkowe maszyny „do tła" / floty.

## Frontend

- URL: <http://localhost:8080>
- Login: **Admin** / hasło: **zabbix** (domyślne — to lab; zmień, jeśli potrzebujesz).

## Demo: zobacz atak w metrykach

1. Wygeneruj ruch odniesienia (baseline) z `loadgen`:
   ```bash
   docker compose exec loadgen h2load -n 2000 -c 20 https://victim/
   ```
2. W Zabbixie (**Monitoring → Latest data**, host `victim`) obserwuj
   `Nginx: Connections active` i obciążenie CPU.
3. Przy realnym teście Rapid Reset (`bot`) zobaczysz asymetrię z `README-DEFENSE.md`:
   skok aktywnych połączeń / CPU przy niewielkiej liczbie kompletnych odpowiedzi 2xx.

## Detekcja i alerty (triggery + Rapid Reset)

Sama widoczność to nie wszystko — overlay `docker-compose.monitoring.yml` ma też
jednorazowy setup detekcji (`zabbix-alerts`), który na hoście `victim` zakłada
triggery i kanał alertowania.

Włączenie (po tym, jak stoi stack i jest host `victim`):

```bash
docker compose \
  -f docker-compose.yml -f docker-compose.override.yml \
  -f docker-compose.monitoring.yml \
  run --rm zabbix-alerts
```

Tworzy (idempotentnie):

| Trigger | Waga | Warunek |
|---|---|---|
| DoS: wysokie uzycie CPU na victim | High | CPU > 60% w 2 kolejnych pomiarach |
| DoS: wysoka liczba zadan/s nginx (victim) | Average | `nginx.requests.total.rate` > 30/s |
| Mozliwy HTTP/2 Rapid Reset na victim | Disaster | zadania/s > 20× tempa nowych polaczen **i** > 20/s |

Ostatni to **sygnatura CVE-2023-44487**: dużo żądań (strumieni HTTP/2) na jedno
połączenie TCP — wprost obraz z `README-DEFENSE.md`. Jest czysto protokołowy
(nie zależy od CPU), bo nginx bywa zbyt wydajny, by atak podniósł CPU.

**Alertowanie:** media type typu *script* (`monitoring/alertscripts/lab_alert.sh`)
oraz akcja wysyłająca problem do użytkownika `Admin`. Alert ląduje w logu:

```bash
docker exec lab-zabbix-server tail -f /var/lib/zabbix/alert.log
```

Przykładowy wpis:

```
2026-... | ALERT to=lab | [Zabbix] Disaster: Mozliwy HTTP/2 Rapid Reset na victim | ...
```

### Test detekcji (wywołanie alarmu)

Podtrzymywany ruch HTTP/2 z `loadgen` (h2load zamyka połączenie po
`keepalive_requests=1000`, więc pętla utrzymuje wysoki rate):

```bash
docker compose -f docker-compose.yml -f docker-compose.override.yml \
  -f docker-compose.monitoring.yml exec loadgen \
  sh -c 'i=0; while [ $i -lt 40 ]; do h2load -n 8000 -c 8 -m 64 https://victim/ >/dev/null 2>&1; i=$((i+1)); done'
```

Po ~1–2 min w **Monitoring → Problems** zobaczysz problemy „DoS: wysoka liczba
zadan/s" i „Mozliwy HTTP/2 Rapid Reset", a w `alert.log` odpowiadające im alerty.

> Pod obciążeniem może też chwilowo wyskoczyć „Linux: Zabbix agent is not
> available" — agent bywa mniej responsywny, gdy host jest przeciążony. To
> realistyczny efekt uboczny, problem sam się zamyka po ustaniu ruchu.

## Hardening — mitygacja Rapid Reset (tryb utwardzony)

Overlay `docker-compose.hardening.yml` przełącza victima w wariant **utwardzony**:
podmienia konfigurację nginx na `victim/nginx.hardened.conf`, która dokłada
obronę w głąb przeciw HTTP/2 Rapid Reset (ponad wbudowaną łatkę nginx ≥ 1.25.3):

| Mechanizm | Podatny (`nginx.conf`) | Utwardzony (`nginx.hardened.conf`) |
|---|---|---|
| `http2_max_concurrent_streams` | 128 | **32** |
| `keepalive_requests` | 1000 | **100** |
| `limit_req` (tempo żądań/IP) | — | **20 r/s, burst 40, nadmiar → 429** |
| `limit_conn` (połączenia/IP) | — | **20** |

Rate-limiting odcina flood strumieni z jednego źródła tanim `429`, zamiast
obciążać backend. Endpoint `/status` (stub_status) jest wyłączony z limitów,
żeby Zabbix mógł zbierać metryki także w trakcie ataku.

### Porównanie before/after (materiał do pracy)

1. **Tryb podatny** — odpal atak i zobacz skok w Zabbixie (trigger „Rapid Reset” odpala):
   ```bash
   docker compose -f docker-compose.yml -f docker-compose.override.yml \
     -f docker-compose.monitoring.yml up -d --build victim
   ```
   (następnie pętla h2load z sekcji „Test detekcji”)

2. **Tryb utwardzony** — ten sam atak, rate-limit tnie flood:
   ```bash
   docker compose -f docker-compose.yml -f docker-compose.override.yml \
     -f docker-compose.monitoring.yml -f docker-compose.hardening.yml up -d victim
   ```
   (ta sama pętla h2load)

W **Monitoring → Latest data** porównaj `nginx.requests.total.rate`, CPU oraz
liczbę odpowiedzi `429` (w logu: `docker compose logs victim`). W trybie
utwardzonym atak zostaje przycięty — mniej przetworzonych żądań, niższe CPU,
a połączenia floodujące dostają `429`.

> Przełączenie trybu nie przebudowuje obrazu (zmienia się tylko montowana
> konfiguracja), więc `up -d victim` wystarczy; powrót do trybu podatnego to
> ten sam `up -d victim` bez pliku `-f docker-compose.hardening.yml`.

## Sprzątanie

```bash
docker compose down            # zatrzymuje kontenery
docker compose down -v         # dodatkowo usuwa wolumen bazy Zabbixa (zabbix-db-data)
```

## Ręczna konfiguracja (bez provisionera)

1. **Data collection → Hosts → Create host**.
2. Host name: `victim` (musi zgadzać się z `Hostname` w `victim/zabbix_agent2.conf`).
3. Groups: `DDoS Lab` (wpisz, by utworzyć).
4. Interfaces → Add → **Agent**: `DNS name = victim`, Connect to = DNS, port `10050`.
5. Templates → podlinkuj `Linux by Zabbix agent`.
6. (Opcjonalnie nginx) podlinkuj `Nginx by HTTP` i ustaw makra hosta:
   `{$NGINX.STUB_STATUS.HOST}=victim`, `{$NGINX.STUB_STATUS.PATH}=status`,
   `{$NGINX.STUB_STATUS.PORT}=443`, `{$NGINX.STUB_STATUS.SCHEME}=https`.

## Uwagi / rozwiązywanie problemów

- **Host szary / „ZBX" czerwone**: serwer nie dociąga do agenta. Sprawdź, czy
  `victim` wstał z nowego obrazu (`docker compose logs victim` → linia
  `[lab] starting zabbix-agent2`) i czy oba są na `labnet`.
- **Nginx template „No data"**: szablon `Nginx by HTTP` skrobie `https://victim/status`
  z self-signed certem; pozycja HTTP-agent ma domyślnie wyłączoną weryfikację TLS.
  Jeśli mimo to brak danych — metryki CPU/RAM z agenta i tak pokazują wpływ ataku.
- **Port 8080 zajęty**: zmień mapowanie w `docker-compose.monitoring.yml`
  (`"8080:8080"` → np. `"8090:8080"`).
- Hasło Postgresa (`zabbix_pg_pw`) i hasło `Admin/zabbix` są **labowe** — nie używać poza labem.
