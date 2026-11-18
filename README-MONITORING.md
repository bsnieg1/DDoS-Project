# Lab monitoring — Zabbix server + connected host (victim)

Optional defensive layer added to the HTTP/2 lab (CVE-2023-44487 Rapid Reset).
Deploys a **Zabbix 7.0 LTS server** and connects the **attacked host `victim`** to it, so you
can observe the impact of the attack on the victim server in real time (CPU, memory, network
traffic, and the number of active connections / nginx requests from `stub_status`).

The base lab (`victim` + `loadgen` [+ `bot` + `c2`]) works without this layer — it's
a separate compose file that you include only when you want monitoring.

## What's added

| Service | Image | Role |
|---|---|---|
| `zabbix-db` | `postgres:16-alpine` | Zabbix database |
| `zabbix-server` | `zabbix/zabbix-server-pgsql:alpine-7.0-latest` | Zabbix server |
| `zabbix-web` | `zabbix/zabbix-web-nginx-pgsql:alpine-7.0-latest` | web frontend (`localhost:8080`) |
| `zabbix-provision` | `python:3.12-alpine` | one-time provisioner for host `victim` (profile `provision`) |
| `victim` (replaced) | build `./victim` | nginx HTTP/2 **+ zabbix-agent2** in a single container |

Networks:
- **`labnet`** (`internal: true`, from base lab) — server ↔ agent(`victim`) ↔ database, no internet.
- **`monnet`** (`bridge`) — sole purpose: expose frontend port `8080` to the host.

## Startup

From the `ddos-lab` directory. It's convenient to set `COMPOSE_FILE` so you don't have to add `-f` each time:

```bash
export COMPOSE_FILE=docker-compose.yml:docker-compose.override.yml:docker-compose.monitoring.yml
```

(PowerShell: `$env:COMPOSE_FILE="docker-compose.yml:docker-compose.override.yml:docker-compose.monitoring.yml"`)

Monitoring + victim only (without building the attack bot and C2):

```bash
docker compose up -d --build victim zabbix-db zabbix-server zabbix-web
```

Or the full lab + monitoring together:

```bash
docker compose up -d --build
```

The first server start imports the database schema — the frontend may be ready after ~1–2 min.

## Connecting host `victim` to Zabbix (provisioning)

The host, group, and templates are created by a one-time provisioner (idempotent):

```bash
docker compose run --rm zabbix-provision
```

The script logs into the API, creates the **DDoS Lab** group, the **victim** host with
agent interface `victim:10050`, and links the templates:
- **Linux by Zabbix agent** — CPU, memory, load, network traffic of the victim container (from agent),
- **Nginx by HTTP** — `stub_status` over HTTPS (active connections, request count).

After a moment, in **Monitoring → Hosts**, host `victim` should turn green
(ZBX). If you prefer to configure manually — see the "Manual configuration" section below.

## Multi-machine pool (fleet) with autoregistration

Want several monitored machines at once (e.g. 4–5)? Use the overlay
`docker-compose.victims.yml` — a scalable `victim-node` service (same image:
nginx HTTP/2 + zabbix-agent2). Each replica registers itself with the server
(**autoregistration**), so you don't add hosts manually.

One-time: enable the autoregistration rule (creates action + "DDoS Lab Pool" group,
links the *Linux by Zabbix agent* template):

```bash
docker compose \
  -f docker-compose.yml -f docker-compose.override.yml \
  -f docker-compose.monitoring.yml -f docker-compose.victims.yml \
  run --rm zabbix-autoreg
```

Spin up 5 machines (change the number with `--scale victim-node=N`):

```bash
docker compose \
  -f docker-compose.yml -f docker-compose.override.yml \
  -f docker-compose.monitoring.yml -f docker-compose.victims.yml \
  up -d --build --scale victim-node=5 victim-node
```

After ~1–2 min, in **Monitoring → Hosts** you'll see hosts `victim-<id>` (e.g.
`victim-c73efa73e066`) in the **DDoS Lab Pool** group, each collecting CPU/RAM/network.
Name = `victim-` + truncated container id (unique per replica).

Scale up/down: rerun `up -d --scale victim-node=N`. Removed
replicas will remain in Zabbix as "dead" hosts (no data) — you can delete them
in **Data collection → Hosts** or via API.

> The pool is independent of the base, attacked host `victim` (DNS `victim`),
> which is used by `bot` and `loadgen`. The pool consists of additional "background" / fleet machines.

## Frontend

- URL: <http://localhost:8080>
- Login: **Admin** / password: **zabbix** (default — this is a lab; change if needed).

## Demo: observe the attack in metrics

1. Generate reference traffic (baseline) from `loadgen`:
   ```bash
   docker compose exec loadgen h2load -n 2000 -c 20 https://victim/
   ```
2. In Zabbix (**Monitoring → Latest data**, host `victim`) observe
   `Nginx: Connections active` and CPU load.
3. During a real Rapid Reset test (`bot`) you'll see the asymmetry from `README-DEFENSE.md`:
   a spike in active connections / CPU with a low number of complete 2xx responses.

## Detection and alerts (triggers + Rapid Reset)

Visibility alone is not enough — the `docker-compose.monitoring.yml` overlay also includes
a one-time detection setup (`zabbix-alerts`), which creates triggers and an alerting
channel on the `victim` host.

Enable (after the stack is up and host `victim` exists):

```bash
docker compose \
  -f docker-compose.yml -f docker-compose.override.yml \
  -f docker-compose.monitoring.yml \
  run --rm zabbix-alerts
```

Creates (idempotently):

| Trigger | Severity | Condition |
|---|---|---|
| DoS: high CPU usage on victim | High | CPU > 60% in 2 consecutive samples |
| DoS: high request rate on nginx (victim) | Average | `nginx.requests.total.rate` > 30/s |
| Possible HTTP/2 Rapid Reset on victim | Disaster | requests/s > 20× the rate of new connections **and** > 20/s |

The last one is the **CVE-2023-44487 signature**: many requests (HTTP/2 streams) per
TCP connection — directly the pattern from `README-DEFENSE.md`. It's purely protocol-based
(independent of CPU), since nginx can be too efficient for the attack to raise CPU.

**Alerting:** a *script* type media (`monitoring/alertscripts/lab_alert.sh`)
and an action that sends the problem to the `Admin` user. Alerts land in the log:

```bash
docker exec lab-zabbix-server tail -f /var/lib/zabbix/alert.log
```

Example entry:

```
2026-... | ALERT to=lab | [Zabbix] Disaster: Possible HTTP/2 Rapid Reset on victim | ...
```

### Detection test (triggering the alarm)

Sustained HTTP/2 traffic from `loadgen` (h2load closes the connection after
`keepalive_requests=1000`, so a loop maintains a high rate):

```bash
docker compose -f docker-compose.yml -f docker-compose.override.yml \
  -f docker-compose.monitoring.yml exec loadgen \
  sh -c 'i=0; while [ $i -lt 40 ]; do h2load -n 8000 -c 8 -m 64 https://victim/ >/dev/null 2>&1; i=$((i+1)); done'
```

After ~1–2 min, in **Monitoring → Problems** you'll see problems "DoS: high request
rate" and "Possible HTTP/2 Rapid Reset", and in `alert.log` the corresponding alerts.

> Under load, "Linux: Zabbix agent is not available" may also temporarily appear
> — the agent can be less responsive when the host is overloaded. This is a
> realistic side effect; the problem resolves itself after traffic stops.

## Hardening — Rapid Reset mitigation (hardened mode)

The overlay `docker-compose.hardening.yml` switches the victim to a **hardened** variant:
it replaces the nginx configuration with `victim/nginx.hardened.conf`, which adds
defense-in-depth against HTTP/2 Rapid Reset (on top of the built-in nginx patch ≥ 1.25.3):

| Mechanism | Vulnerable (`nginx.conf`) | Hardened (`nginx.hardened.conf`) |
|---|---|---|
| `http2_max_concurrent_streams` | 128 | **32** |
| `keepalive_requests` | 1000 | **100** |
| `limit_req` (request rate/IP) | — | **20 r/s, burst 40, excess → 429** |
| `limit_conn` (connections/IP) | — | **20** |

Rate-limiting cuts off the stream flood from a single source with a cheap `429`, instead
of loading the backend. The `/status` endpoint (stub_status) is exempt from limits,
so Zabbix can collect metrics even during an attack.

### Before/after comparison (material for the report)

1. **Vulnerable mode** — launch the attack and see the spike in Zabbix (the "Rapid Reset" trigger fires):
   ```bash
   docker compose -f docker-compose.yml -f docker-compose.override.yml \
     -f docker-compose.monitoring.yml up -d --build victim
   ```
   (then the h2load loop from the "Detection test" section)

2. **Hardened mode** — same attack, rate-limit cuts the flood:
   ```bash
   docker compose -f docker-compose.yml -f docker-compose.override.yml \
     -f docker-compose.monitoring.yml -f docker-compose.hardening.yml up -d victim
   ```
   (same h2load loop)

In **Monitoring → Latest data** compare `nginx.requests.total.rate`, CPU, and
the number of `429` responses (in logs: `docker compose logs victim`). In hardened
mode the attack is throttled — fewer processed requests, lower CPU,
and flooding connections get `429`.

> Switching modes does not rebuild the image (only the mounted
> configuration changes), so `up -d victim` is enough; returning to vulnerable mode is
> the same `up -d victim` without the `-f docker-compose.hardening.yml` file.

## Cleanup

```bash
docker compose down            # stops containers
docker compose down -v         # also removes the Zabbix database volume (zabbix-db-data)
```

## Manual configuration (without the provisioner)

1. **Data collection → Hosts → Create host**.
2. Host name: `victim` (must match the `Hostname` in `victim/zabbix_agent2.conf`).
3. Groups: `DDoS Lab` (type to create).
4. Interfaces → Add → **Agent**: `DNS name = victim`, Connect to = DNS, port `10050`.
5. Templates → link `Linux by Zabbix agent`.
6. (Optionally for nginx) link `Nginx by HTTP` and set host macros:
   `{$NGINX.STUB_STATUS.HOST}=victim`, `{$NGINX.STUB_STATUS.PATH}=status`,
   `{$NGINX.STUB_STATUS.PORT}=443`, `{$NGINX.STUB_STATUS.SCHEME}=https`.

## Notes / troubleshooting

- **Host grey / "ZBX" red**: server cannot reach the agent. Check if
  `victim` started with the new image (`docker compose logs victim` → line
  `[lab] starting zabbix-agent2`) and if both are on `labnet`.
- **Nginx template "No data"**: the `Nginx by HTTP` template scrapes `https://victim/status`
  with a self-signed cert; the HTTP-agent item has TLS verification disabled by default.
  If there's still no data — CPU/RAM metrics from the agent still show the attack impact.
- **Port 8080 busy**: change the mapping in `docker-compose.monitoring.yml`
  (`"8080:8080"` → e.g. `"8090:8080"`).
- The Postgres password (`zabbix_pg_pw`) and `Admin/zabbix` password are **lab-only** — do not use outside the lab.
