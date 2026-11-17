# HANDOVER — ddos-lab

Paczka przekazawcza labu HTTP/2 (CVE-2023-44487, HTTP/2 Rapid Reset) do kontynuacji pracy.
Merytoryka — mechanika podatności, wykrywanie, mitygacja — jest w `README-DEFENSE.md`.
Ten plik opisuje tylko, **jak odpalić flow**.

> **Ta paczka ZIP nie zawiera binarki Sliver** (`c2/bin/sliver-server`) — Google blokuje pliki wykonywalne w zalacznikach.
> Binarke trzeba dostarczyc osobno: pobrac `sliver-server` (Linux) z https://github.com/BishopFox/sliver/releases i wrzucic do `c2/bin/`.
> Reszta stanu Sliver (`c2/data/sliver.db` itd.) jest w paczce, wiec po dolozeniu binarki C2 wstaje z zachowanym stanem.

## Co jest w paczce
- `docker-compose.yml` — usługi bazowe: `victim` (nginx HTTP/2, TLS self-signed) + `loadgen` (h2load).
- `docker-compose.override.yml` — dokłada `bot` (buduje `rapidreset` ze źródeł) i `c2` (Sliver).
- `victim/` — `nginx.conf`, `html/`, oraz labowe certy self-signed (`cert.pem` / `key.pem` — tylko do labu).
- `bot/rapidreset/` — źródła PoC, budowane w obrazie (patrz `bot/Dockerfile`).
- `loadgen/` — obraz pomiarowy (h2load + curl).
- `c2/bin/sliver-server` — binarka serwera Sliver (~287 MB).
- `c2/data/` — stan Sliver (`sliver.db`, `configs/`, `traffic-encoders/`, ...).

## Czego NIE ma (świadomie)
- `c2/data/go/` i `c2/data/zig/` (~617 MB) — toolchainy, które **Sliver sam rozpakowuje**
  z binarki serwera przy pierwszym starcie. Nie trzeba ich przenosić; sieć labu jest
  `internal`, a rozpakowanie nie wymaga internetu.
- `.git/` — historia nie jest przenoszona.

## Wymagania
- Docker + wtyczka `docker compose` (v2).
- ~2–3 GB wolnego miejsca (Sliver po pierwszym starcie odtworzy `go/` i `zig/` w `c2/data`).

## Uruchomienie pełnego flow
```bash
cd ddos-lab
docker compose up -d --build        # victim + loadgen + bot + c2 (override wczytywany automatycznie)
docker compose ps
```

## Weryfikacja bazowa (z wnętrza izolowanej sieci)
Sieć `labnet` ma `internal: true` → brak internetu i brak publikacji portów na host,
więc polecenia uruchamiamy przez `exec`:
```bash
docker compose exec loadgen curl -k --http2 https://victim/ -I
docker compose exec loadgen h2load -n 1000 -c 10 https://victim/
```

## Sliver (C2) — pierwszy start
Przy pierwszym wejściu Sliver odtworzy toolchainy w `/root/.sliver` (montowane z `./c2/data`):
```bash
docker compose exec c2 /opt/sliver/sliver-server
```
Pierwsze uruchomienie może chwilę potrwać (rozpakowanie `go/` + `zig/`); kolejne są szybkie.

## Sprzątanie
```bash
docker compose down            # dodaj -v, aby usunąć też sieci/wolumeny
```

## Uwagi
- Certy w `victim/` są **self-signed, wyłącznie labowe** — nie używać poza labem.
- Całość ma działać w odciętej sieci `labnet`; nie publikujemy portów na host.
