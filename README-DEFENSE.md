# Lab HTTP/2 — część defensywno-edukacyjna

To jest **zredukowana** wersja środowiska z `PLAN_SETUP.md`. Zawiera wyłącznie
elementy nieofensywne: serwer-ofiarę nginx po HTTP/2 oraz generator ruchu
odniesienia `h2load`. Służy do zrozumienia protokołu HTTP/2 i mechaniki podatności
CVE-2023-44487, bez budowania działającego narzędzia ataku ani infrastruktury C2.

## Uruchomienie

```bash
cd ddos-lab
docker compose up -d --build
docker compose ps
```

## Weryfikacja (z wnętrza izolowanej sieci)

Sieć `labnet` jest `internal` (brak internetu, brak publikacji portów na host),
więc polecenia uruchamiamy przez `exec` w kontenerze `loadgen`:

```bash
# 1. serwer-ofiara odpowiada po HTTP/2
docker compose exec loadgen curl -k --http2 https://victim/ -I

# 2. baseline normalnego ruchu HTTP/2
docker compose exec loadgen h2load -n 1000 -c 10 https://victim/

# 3. podgląd stub_status serwera
docker compose exec loadgen curl -k https://victim/status
```

W logu dostępu nginx (`docker compose logs victim`) zobaczysz `proto=HTTP/2.0`
oraz liczbę żądań na połączenie.

## Mechanika CVE-2023-44487 (HTTP/2 Rapid Reset) — do zrozumienia, nie do użycia

HTTP/2 multipleksuje wiele **strumieni** (żądań) na jednym połączeniu TCP/TLS.
Serwer ogłasza limit równoczesnych strumieni przez `SETTINGS_MAX_CONCURRENT_STREAMS`.

Istota podatności: klient wysyła `HEADERS` (otwiera strumień, serwer zaczyna
alokować pracę), a natychmiast potem `RST_STREAM` (anuluje strumień). Anulowany
strumień **nie liczy się** do limitu równoczesnych strumieni, więc klient może w
pętli otwierać-i-anulować żądania znacznie szybciej, niż serwer zdąży je
posprzątać. Koszt po stronie klienta jest znikomy, po stronie serwera — realna
praca (routing, alokacja, czasem przekazanie do backendu). Stąd asymetria, która
czyni z tego wektor DoS możliwy do wywołania nawet z pojedynczego hosta.

## Wykrywanie

- **Nietypowy stosunek** liczby otwartych strumieni do ukończonych odpowiedzi;
  dużo `RST_STREAM` inicjowanych przez klienta tuż po `HEADERS`.
- **Krótkożyjące strumienie** masowo anulowane — widoczne w metrykach serwera /
  reverse-proxy (np. liczba resetów na połączenie).
- Wzrost obciążenia CPU przy niskim wolumenie ruchu „użytecznego" (mało
  kompletnych odpowiedzi 2xx przy dużej liczbie rozpoczętych żądań).
- Logi: wiele żądań na jednym połączeniu kończących się bez pełnej odpowiedzi.

## Mitygacja

- **Łatki** serwerów/bibliotek HTTP/2 wydane po ujawnieniu CVE-2023-44487
  (nginx, Apache, Go net/http, Envoy, HAProxy i in.) — podstawowy krok.
- **`http2_max_concurrent_streams`** — rozsądny limit (w konfiguracji labu: 128).
- **`keepalive_requests`** — ograniczenie liczby żądań na jedno połączenie, po
  przekroczeniu połączenie jest zamykane (w labie: 1000).
- **Limit tempa resetów**: zamykanie połączenia, które generuje nienaturalnie
  dużo `RST_STREAM` (mechanizm wprowadzony m.in. w Go i innych stosach).
- **Reverse-proxy / WAF / rate-limiting** przed serwerem aplikacyjnym.
- Monitoring i alerty na opisane wyżej sygnały.

## Sprzątanie

```bash
docker compose down
```
