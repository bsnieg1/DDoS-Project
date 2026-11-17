# Scenariusze A/B — HTTP/2 Rapid Reset

Dwie **kolejne symulacje** na jednym stanowisku, ze wspólnym zestawem metryk na końcu:

| Faza | nginx | konfiguracja | oczekiwany wynik |
|---|---|---|---|
| `vulnerable` | **1.25.2** (sprzed mitygacji) | `nginx.vuln.conf` (wysokie `keepalive_requests`) | atak degraduje serwer, CPU rośnie, ruch legalny cierpi |
| `secure` | **1.27** (mitygacja z 1.25.3) | `nginx.conf` (rozsądne limity) | nginx zamyka flood (**GOAWAY**), ruch legalny bez zmian |

## Uruchomienie

Z katalogu projektu, w Git Bash lub WSL:

```bash
bash scenarios/run-ab.sh                     # lean: victim + loadgen + bot
bash scenarios/run-ab.sh --with-monitoring   # dodatkowo Zabbix (timeline obu faz)
bash scenarios/run-ab.sh --down              # posprzątaj kontenery na końcu

# parametry ataku:
ATTACK_REQUESTS=40000 ATTACK_CONC=400 bash scenarios/run-ab.sh
#   lub
bash scenarios/run-ab.sh --attack 40000 --conc 400
```

## Co powstaje

Katalog `results/<timestamp>/`:

- `summary.md` — tabela porównawcza (Markdown),
- `results.csv` — te same liczby do arkusza/wykresu,
- `vulnerable.env` / `secure.env` — surowe metryki per faza,
- `*.attack.txt`, `*.legit.txt`, `*.baseline.txt`, `*.cpu.txt` — pełne logi i próbki.

## Jak czytać wyniki

- **Serwer obronił się (zamknął flood)** = `TAK`, jeśli atakujący dostał `GOAWAY`
  lub napotkał błędy wysyłki — czyli nginx zerwał połączenie zalewające.
  Oczekiwane: `NIE` dla `vulnerable`, `TAK` dla `secure`.
- **req/s ruchu legalnego POD atakiem** + **nieudane żądania legalne** — realny
  wpływ na zwykłego użytkownika. Na podatnym serwerze legalny ruch siada;
  na zabezpieczonym zostaje zdrowy.
- **CPU peak/avg** victima — asymetria kosztu ataku.

> Katalog `results/` jest w `.gitignore` (wyniki są generowane).
