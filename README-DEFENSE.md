# Lab HTTP/2 — defensive / educational part

This is a **reduced** version of the environment from `PLAN_SETUP.md`. It contains only
non-offensive elements: the nginx victim server over HTTP/2 and the reference traffic
generator `h2load`. It serves to understand the HTTP/2 protocol and the mechanics of
vulnerability CVE-2023-44487, without building a working attack tool or C2 infrastructure.

## Startup

```bash
cd ddos-lab
docker compose up -d --build
docker compose ps
```

## Verification (from inside the isolated network)

The `labnet` network is `internal` (no internet, no ports published to the host),
so commands are run via `exec` in the `loadgen` container:

```bash
# 1. victim server responds over HTTP/2
docker compose exec loadgen curl -k --http2 https://victim/ -I

# 2. baseline of normal HTTP/2 traffic
docker compose exec loadgen h2load -n 1000 -c 10 https://victim/

# 3. view server stub_status
docker compose exec loadgen curl -k https://victim/status
```

In the nginx access log (`docker compose logs victim`) you will see `proto=HTTP/2.0`
and the number of requests per connection.

## CVE-2023-44487 mechanics (HTTP/2 Rapid Reset) — for understanding, not for use

HTTP/2 multiplexes many **streams** (requests) over a single TCP/TLS connection.
The server announces the concurrent stream limit via `SETTINGS_MAX_CONCURRENT_STREAMS`.

The essence of the vulnerability: the client sends `HEADERS` (opens a stream, the server
starts allocating work), then immediately sends `RST_STREAM` (cancels the stream). The
cancelled stream **does not count** toward the concurrent stream limit, so the client can
open-and-cancel requests in a loop much faster than the server can clean them up. The cost
on the client side is negligible; on the server side — real work (routing, allocation,
sometimes forwarding to the backend). Hence the asymmetry that makes this a DoS vector
achievable even from a single host.

## Detection

- **Unusual ratio** of opened streams to completed responses;
  many `RST_STREAM` initiated by the client right after `HEADERS`.
- **Short-lived streams** being mass-cancelled — visible in server /
  reverse-proxy metrics (e.g. resets per connection).
- CPU load increase with low volume of "useful" traffic (few
  complete 2xx responses despite a high number of initiated requests).
- Logs: many requests on a single connection ending without a full response.

## Mitigation

- **Patches** for HTTP/2 servers/libraries released after disclosure of CVE-2023-44487
  (nginx, Apache, Go net/http, Envoy, HAProxy, etc.) — the fundamental step.
- **`http2_max_concurrent_streams`** — a reasonable limit (in lab config: 128).
- **`keepalive_requests`** — limiting requests per connection; after exceeding
  this limit, the connection is closed (in lab: 1000).
- **Reset rate limiting**: closing connections that generate an unnaturally
  high number of `RST_STREAM` (mechanism introduced in Go and other stacks).
- **Reverse-proxy / WAF / rate-limiting** in front of the application server.
- Monitoring and alerts on the signals described above.

## Cleanup

```bash
docker compose down
```
