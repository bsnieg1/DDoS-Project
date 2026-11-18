#!/usr/bin/env python3
"""
AUTOREGISTRATION rule configuration in Zabbix (standard library only).

Creates (idempotently):
  - host group "DDoS Lab Pool",
  - autoregistration action that for every machine registering with
    HostMetadata containing "ddos-lab-pool":
        * creates the host,
        * adds it to the "DDoS Lab Pool" group,
        * links the "Linux by Zabbix agent" template.

This way `docker compose ... up -d --scale victim-node=N` causes N
machines to automatically appear in Zabbix, without manual host creation.

Usually run via the `zabbix-autoreg` service (profile "provision").
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
            print("[autoreg] Zabbix API ready, version", ver)
            return
        except (urllib.error.URLError, RuntimeError, ConnectionError) as e:
            print("[autoreg] waiting for API (%d/%d): %s" % (i + 1, retries, e))
            time.sleep(delay)
    print("[autoreg] API did not start in time", file=sys.stderr)
    sys.exit(1)


def login():
    global _token
    _token = call("user.login", {"username": USER, "password": PASS}, auth=False)
    print("[autoreg] logged in as", USER)


def ensure_group():
    res = call("hostgroup.get", {"filter": {"name": [GROUP]}, "output": ["groupid"]})
    if res:
        return res[0]["groupid"]
    gid = call("hostgroup.create", {"name": GROUP})["groupids"][0]
    print("[autoreg] created group:", GROUP)
    return gid


def template_id():
    res = call("template.get", {"filter": {"host": [TEMPLATE]}, "output": ["templateid"]})
    if not res:
        print("[autoreg] ERROR: template '%s' not found" % TEMPLATE, file=sys.stderr)
        sys.exit(1)
    return res[0]["templateid"]


def create_action(gid, tid):
    existing = call("action.get", {"filter": {"name": [ACTION]}, "output": ["actionid"]})
    if existing:
        print("[autoreg] action already exists:", ACTION)
        return
    params = {
        "name": ACTION,
        "eventsource": 2,   # 2 = autoregistration
        "status": 0,        # enabled
        "filter": {
            "evaltype": 0,  # And/Or
            "conditions": [
                # conditiontype 24 = host metadata, operator 2 = like (contains)
                {"conditiontype": 24, "operator": 2, "value": METADATA_MATCH},
            ],
        },
        "operations": [
            {"operationtype": 2},  # add host
            {"operationtype": 4, "opgroup": [{"groupid": gid}]},     # add to group
            {"operationtype": 6, "optemplate": [{"templateid": tid}]},  # link template
        ],
    }
    call("action.create", params)
    print("[autoreg] created autoregistration action:", ACTION)


def main():
    wait_for_api()
    login()
    gid = ensure_group()
    tid = template_id()
    create_action(gid, tid)
    print("[autoreg] done. Scale machines:  docker compose ... up -d --scale victim-node=N")


if __name__ == "__main__":
    main()
