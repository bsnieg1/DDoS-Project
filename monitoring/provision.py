#!/usr/bin/env python3
"""
Provisioning hosta "victim" w Zabbixie przez API (tylko biblioteka standardowa).

Co robi (idempotentnie):
  1. czeka az API Zabbixa wstanie,
  2. loguje sie jako Admin/zabbix,
  3. tworzy grupe hostow "DDoS Lab" (jesli brak),
  4. tworzy hosta "victim" z interfejsem agenta victim:10050 (jesli brak),
  5. podpina dostepne szablony: "Linux by Zabbix agent" (CPU/RAM/load/siec
     z agenta w kontenerze victim) oraz "Nginx by HTTP" (stub_status po HTTPS:
     liczba aktywnych polaczen i zadan — kluczowy sygnal przy Rapid Reset).

Uruchamiane zwykle przez usluge `zabbix-provision` (profil "provision").
Konfiguracja przez zmienne srodowiskowe: ZBX_URL, ZBX_USER, ZBX_PASS.
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

HOST_NAME = "victim"
HOST_GROUP = "DDoS Lab"
TEMPLATES = ["Linux by Zabbix agent", "Nginx by HTTP"]

NGINX_MACROS = [
    {"macro": "{$NGINX.STUB_STATUS.HOST}", "value": "victim"},
    {"macro": "{$NGINX.STUB_STATUS.PATH}", "value": "status"},
    {"macro": "{$NGINX.STUB_STATUS.PORT}", "value": "443"},
    {"macro": "{$NGINX.STUB_STATUS.SCHEME}", "value": "https"},
]

_token = None
_id = 0


def call(method, params=None, auth=True):
    """Pojedyncze wywolanie JSON-RPC do API Zabbixa 7.0 (auth przez naglowek Bearer)."""
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
    """Czekaj az frontend/baza wstana (apiinfo.version nie wymaga logowania)."""
    for i in range(retries):
        try:
            ver = call("apiinfo.version", auth=False)
            print("[provision] Zabbix API gotowe, wersja", ver)
            return
        except (urllib.error.URLError, RuntimeError, ConnectionError) as e:
            print("[provision] czekam na API (%d/%d): %s" % (i + 1, retries, e))
            time.sleep(delay)
    print("[provision] API nie wstalo w zadanym czasie", file=sys.stderr)
    sys.exit(1)


def login():
    global _token
    _token = call("user.login", {"username": USER, "password": PASS}, auth=False)
    print("[provision] zalogowano jako", USER)


def ensure_group():
    res = call("hostgroup.get", {"filter": {"name": [HOST_GROUP]}, "output": ["groupid"]})
    if res:
        print("[provision] grupa hostow juz istnieje:", HOST_GROUP)
        return res[0]["groupid"]
    gid = call("hostgroup.create", {"name": HOST_GROUP})["groupids"][0]
    print("[provision] utworzono grupe hostow:", HOST_GROUP)
    return gid


def resolve_templates():
    found = []
    for name in TEMPLATES:
        res = call("template.get", {"filter": {"host": [name]}, "output": ["templateid", "host"]})
        if res:
            found.append({"templateid": res[0]["templateid"], "name": name})
        else:
            print("[provision] UWAGA: szablon nie znaleziony, pomijam:", name)
    return found


def host_exists():
    res = call("host.get", {"filter": {"host": [HOST_NAME]}, "output": ["hostid"]})
    return res[0]["hostid"] if res else None


def create_host(groupid, templates):
    params = {
        "host": HOST_NAME,
        "groups": [{"groupid": groupid}],
        "templates": [{"templateid": t["templateid"]} for t in templates],
        "macros": NGINX_MACROS,
        "interfaces": [{
            "type": 1,        # 1 = agent
            "main": 1,
            "useip": 0,       # uzyj DNS zamiast IP
            "ip": "",
            "dns": "victim",  # nazwa uslugi w sieci labnet
            "port": "10050",
        }],
    }
    hostid = call("host.create", params)["hostids"][0]
    print("[provision] utworzono hosta '%s' (id=%s)" % (HOST_NAME, hostid))
    print("[provision] podpiete szablony:", ", ".join(t["name"] for t in templates) or "(brak)")
    return hostid


def main():
    wait_for_api()
    login()
    existing = host_exists()
    if existing:
        print("[provision] host '%s' juz istnieje (id=%s) — nic nie zmieniam." % (HOST_NAME, existing))
        print("[provision] gotowe.")
        return
    gid = ensure_group()
    templates = resolve_templates()
    create_host(gid, templates)
    print("[provision] gotowe. Frontend: http://localhost:8080  (Admin / zabbix)")


if __name__ == "__main__":
    main()
