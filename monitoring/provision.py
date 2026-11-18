#!/usr/bin/env python3
"""
Provisioning of the "victim" host in Zabbix via API (standard library only).

What it does (idempotently):
  1. waits for the Zabbix API to start,
  2. logs in as Admin/zabbix,
  3. creates the "DDoS Lab" host group (if missing),
  4. creates the "victim" host with agent interface victim:10050 (if missing),
  5. links available templates: "Linux by Zabbix agent" (CPU/RAM/load/network
     from the agent in the victim container) and "Nginx by HTTP" (stub_status over HTTPS:
     active connections and request count — key signal for Rapid Reset).

Usually run via the `zabbix-provision` service (profile "provision").
Configuration via environment variables: ZBX_URL, ZBX_USER, ZBX_PASS.
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
    """Single JSON-RPC call to the Zabbix 7.0 API (auth via Bearer header)."""
    global _id
    _id += 1
    payload = {"jsonrpc": "2.0", "method": method, "params": params or {}, "id": _id}
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(URL, data=data, method="POST")
    req.add_header("Content-Type", "application/json-rpc")
    if auth and _token:
        req.add_header("Authorization", "Bearer " + _token)
    with urllib.request.urlopen(req, timeout=30) as resp:
        body = json.loads(resp.read().decode("utf-8"))
    if "error" in body:
        raise RuntimeError("%s: %s" % (method, body["error"]))
    return body["result"]


def wait_for_api(retries=30, delay=3):
    """Wait for the frontend/database to start and login to work."""
    global _token
    api_up = False
    for i in range(retries):
        try:
            if not api_up:
                ver = call("apiinfo.version", auth=False)
                print("[provision] Zabbix API ready, version", ver)
                api_up = True
            _token = call("user.login", {"username": USER, "password": PASS}, auth=False)
            print("[provision] logged in as", USER)
            return
        except (urllib.error.URLError, RuntimeError, ConnectionError, TimeoutError, OSError) as e:
            status = "API" if not api_up else "database"
            print("[provision] waiting for %s (%d/%d): %s" % (status, i + 1, retries, e))
            time.sleep(delay)
    print("[provision] Zabbix not ready in time", file=sys.stderr)
    sys.exit(1)


def login():
    pass


def ensure_group():
    res = call("hostgroup.get", {"filter": {"name": [HOST_GROUP]}, "output": ["groupid"]})
    if res:
        print("[provision] host group already exists:", HOST_GROUP)
        return res[0]["groupid"]
    gid = call("hostgroup.create", {"name": HOST_GROUP})["groupids"][0]
    print("[provision] created host group:", HOST_GROUP)
    return gid


def resolve_templates():
    found = []
    for name in TEMPLATES:
        res = call("template.get", {"filter": {"host": [name]}, "output": ["templateid", "host"]})
        if res:
            found.append({"templateid": res[0]["templateid"], "name": name})
        else:
            print("[provision] WARNING: template not found, skipping:", name)
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
            "useip": 0,       # use DNS instead of IP
            "ip": "",
            "dns": "victim",  # service name on the labnet network
            "port": "10050",
        }],
    }
    hostid = call("host.create", params)["hostids"][0]
    print("[provision] created host '%s' (id=%s)" % (HOST_NAME, hostid))
    print("[provision] linked templates:", ", ".join(t["name"] for t in templates) or "(none)")
    return hostid


def main():
    wait_for_api()
    existing = host_exists()
    if existing:
        print("[provision] host '%s' already exists (id=%s) — no changes made." % (HOST_NAME, existing))
        print("[provision] done.")
        return
    gid = ensure_group()
    templates = resolve_templates()
    create_host(gid, templates)
    print("[provision] done. Frontend: http://localhost:8080  (Admin / zabbix)")


if __name__ == "__main__":
    main()
