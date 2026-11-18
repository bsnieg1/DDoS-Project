# HANDOVER — ddos-lab

Handover package for the HTTP/2 lab (CVE-2023-44487, HTTP/2 Rapid Reset) to continue the work.
Technical details — vulnerability mechanics, detection, mitigation — are in `README-DEFENSE.md`.
This file only describes **how to run the flow**.

> **This ZIP package does not contain the Sliver binary** (`c2/bin/sliver-server`) — Google blocks executable files in attachments.
> The binary must be delivered separately: download `sliver-server` (Linux) from https://github.com/BishopFox/sliver/releases and place it in `c2/bin/`.
> The rest of Sliver state (`c2/data/sliver.db` etc.) is included in the package, so after adding the binary, C2 starts with its preserved state.

## What's in the package
- `docker-compose.yml` — base services: `victim` (nginx HTTP/2, TLS self-signed) + `loadgen` (h2load).
- `docker-compose.override.yml` — adds `bot` (builds `rapidreset` from source) and `c2` (Sliver).
- `victim/` — `nginx.conf`, `html/`, and lab-only self-signed certs (`cert.pem` / `key.pem` — lab use only).
- `bot/rapidreset/` — PoC source code, built in the image (see `bot/Dockerfile`).
- `loadgen/` — measurement image (h2load + curl).
- `c2/bin/sliver-server` — Sliver server binary (~287 MB).
- `c2/data/` — Sliver state (`sliver.db`, `configs/`, `traffic-encoders/`, ...).

## What's NOT included (intentionally)
- `c2/data/go/` and `c2/data/zig/` (~617 MB) — toolchains that **Sliver unpacks on its own**
  from the server binary on first start. No need to transfer them; the lab network is
  `internal`, and unpacking does not require internet access.
- `.git/` — history is not transferred.

## Requirements
- Docker + `docker compose` plugin (v2).
- ~2–3 GB of free space (Sliver will recreate `go/` and `zig/` in `c2/data` on first start).

## Running the full flow
```bash
cd ddos-lab
docker compose up -d --build        # victim + loadgen + bot + c2 (override loaded automatically)
docker compose ps
```

## Basic verification (from inside the isolated network)
The `labnet` network has `internal: true` → no internet and no ports published to the host,
so commands are run via `exec`:
```bash
docker compose exec loadgen curl -k --http2 https://victim/ -I
docker compose exec loadgen h2load -n 1000 -c 10 https://victim/
```

## Sliver (C2) — first start
On first entry, Sliver will recreate toolchains in `/root/.sliver` (mounted from `./c2/data`):
```bash
docker compose exec c2 /opt/sliver/sliver-server
```
The first run may take a while (unpacking `go/` + `zig/`); subsequent starts are fast.

## Cleanup
```bash
docker compose down            # add -v to also remove networks/volumes
```

## Notes
- Certs in `victim/` are **self-signed, lab-only** — do not use outside the lab.
- Everything is designed to run on the isolated `labnet` network; no ports are published to the host.
