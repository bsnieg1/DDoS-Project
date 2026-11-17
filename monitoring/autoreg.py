#!/usr/bin/env python3
"""
Konfiguracja reguly AUTOREGISTRATION w Zabbixie (tylko biblioteka standardowa).

Tworzy (idempotentnie):
  - grupe hostow "DDoS Lab Pool",
  - akcje autoregistration, ktora dla kazdej maszyny zglaszajacej sie z
    HostMetadata zawierajacym "ddos-lab-pool":
        * zaklada hosta,
        * dodaje go do grupy "DDoS Lab Pool",
        * podpina szablon "Linux by Zabbix agent".

Dzieki temu  `docker compose ... up -d --scale victim-node=N`  sprawia, ze N
maszyn samo pojawia sie w Zabbixie, bez recznego dodawania.

Uruchamiane zwykle przez usluge `zabbix-autoreg` (profil "provision").
"""
import json
import os
import sys
import time
import urllib.request
import urllib.error

URL = os.environ.get("ZBX_URL", "http://localhost:8080/api_jsonrpc.php")
USER = os.environ.get("ZBX_USER", "Admin")
PASS = os.environ.get("ZBX_PASS", "zabbix")

GROUP = "DDoS Lab Pool"
TEMPLATE = "Linux by Zabbix agent"
ACTION = "Auto-register DDoS Lab victims"
METADATA_MATCH = "ddos-lab-pool"

_token = None
_id = 0


def call(method, params=None, auth=True):
    global _id
    _id += 1
    payload = {"jsonrpc": "2.0", "method": method, "params": params or {}, "id": _id}
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(URL, data=data, method="POST")
    req.add_header("Content-Type", "application/json-rpc")
    if auth and _token:
        req.add_header("Authorization", "Bearer " + _token)
    with urllib.request.urlopen(req, timeout=15) as resp:
        body = json.loads(resp.read().decode("utf-8"))
    if "error" in body:
        raise RuntimeError("%s: %s" % (method, body["error"]))
    return body["result"]


def wait_for_api(retries=60, delay=5):
    for i in range(retries):
        try:
            ver = call("apiinfo.version", auth=False)
            print("[autoreg] Zabbix API gotowe, wersja", ver)
            return
        except (urllib.error.URLError, RuntimeError, ConnectionError) as e:
            print("[autoreg] czekam na API (%d/%d): %s" % (i + 1, retries, e))
            time.sleep(delay)
    print("[autoreg] API nie wstalo w zadanym czasie", file=sys.stderr)
    sys.exit(1)


def login():
    global _token
    _token = call("user.login", {"username": USER, "password": PASS}, auth=False)
    print("[autoreg] zalogowano jako", USER)


def ensure_group():
    res = call("hostgroup.get", {"filter": {"name": [GROUP]}, "output": ["groupid"]})
    if res:
        return res[0]["groupid"]
    gid = call("hostgroup.create", {"name": GROUP})["groupids"][0]
    print("[autoreg] utworzono grupe:", GROUP)
    return gid


def template_id():
    res = call("template.get", {"filter": {"host": [TEMPLATE]}, "output": ["templateid"]})
    if not res:
        print("[autoreg] BLAD: brak szablonu '%s'" % TEMPLATE, file=sys.stderr)
        sys.exit(1)
    return res[0]["templateid"]


def create_action(gid, tid):
    existing = call("action.get", {"filter": {"name": [ACTION]}, "output": ["actionid"]})
    if existing:
        print("[autoreg] akcja juz istnieje:", ACTION)
        return
    params = {
        "name": ACTION,
        "eventsource": 2,   # 2 = autoregistration
        "status": 0,        # wlaczona
        "filter": {
            "evaltype": 0,  # And/Or
            "conditions": [
                # conditiontype 24 = host metadata, operator 2 = like (zawiera)
                {"conditiontype": 24, "operator": 2, "value": METADATA_MATCH},
            ],
        },
        "operations": [
            {"operationtype": 2},  # dodaj hosta
            {"operationtype": 4, "opgroup": [{"groupid": gid}]},     # dodaj do grupy
            {"operationtype": 6, "optemplate": [{"templateid": tid}]},  # podepnij szablon
        ],
    }
    call("action.create", params)
    print("[autoreg] utworzono akcje autoregistration:", ACTION)


def main():
    wait_for_api()
    login()
    gid = ensure_group()
    tid = template_id()
    create_action(gid, tid)
    print("[autoreg] gotowe. Skaluj maszyny:  docker compose ... up -d --scale victim-node=N")


if __name__ == "__main__":
    main()
