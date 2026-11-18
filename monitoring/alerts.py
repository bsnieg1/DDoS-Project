#!/usr/bin/env python3
"""
Zabbix detection setup: triggers detecting overload / HTTP/2 Rapid Reset on
the "victim" host + simple alerting channel (script type media -> server log).

Creates (idempotently):
  TRIGGERS on host victim:
    1. "DoS: high CPU usage on victim"             (High)
    2. "DoS: high request rate on nginx (victim)"  (Average)
    3. "Possible HTTP/2 Rapid Reset on victim"      (Disaster) -- signature:
        many requests/s relative to new connections (many streams per
        TCP connection) + elevated CPU. This is directly the CVE-2023-44487 pattern.
  ALERTING:
    - media type "Lab file alert" (script lab_alert.sh),
    - media assignment to Admin user,
    - action on problems -> send alert to Admin.

Usually run via the `zabbix-alerts` service (profile "provision").
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
HOST = "victim"

# Thresholds tuned for the lab (baseline: CPU ~0.5%, requests ~0.02/s).
TRIGGERS = [
    {
        "description": "DoS: high CPU usage on victim",
        "expression": "min(/victim/system.cpu.util,#2)>60",
        "priority": 4,  # High
        "comments": "Average victim CPU exceeds 60% in 2 consecutive samples. "
                    "With low volume of 'useful' traffic this signals DoS.",
    },
    {
        "description": "DoS: high request rate on nginx (victim)",
        "expression": "last(/victim/nginx.requests.total.rate)>30",
        "priority": 3,  # Average
        "comments": "Sharp increase in nginx request rate compared to baseline (~0.02/s).",
    },
    {
        "description": "Possible HTTP/2 Rapid Reset on victim",
        # Signature: requests/s >> rate of new connections (many streams per
        # TCP connection) + real request increase + elevated CPU.
        "expression": (
            "last(/victim/nginx.requests.total.rate)"
            ">20*last(/victim/nginx.connections.accepted.rate)"
            " and last(/victim/nginx.requests.total.rate)>20"
            " and last(/victim/system.cpu.util)>30"
        ),
        "priority": 5,  # Disaster
        "comments": "Many requests (HTTP/2 streams) per TCP connection with "
                    "elevated CPU — the CVE-2023-44487 (Rapid Reset) pattern.",
    },
]

MEDIA_NAME = "Lab file alert"
ACTION_NAME = "Lab: alert on victim problems"

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
    with urllib.request.urlopen(req, timeout=120) as resp:
        body = json.loads(resp.read().decode("utf-8"))
    if "error" in body:
        raise RuntimeError("%s: %s" % (method, body["error"]))
    return body["result"]


def wait_for_api(retries=60, delay=5):
    for i in range(retries):
        try:
            call("apiinfo.version", auth=False)
            return
        except (urllib.error.URLError, RuntimeError, ConnectionError) as e:
            print("[alerts] waiting for API (%d/%d): %s" % (i + 1, retries, e))
            time.sleep(delay)
    print("[alerts] API did not start", file=sys.stderr)
    sys.exit(1)


def login():
    global _token
    _token = call("user.login", {"username": USER, "password": PASS}, auth=False)
    print("[alerts] logged in as", USER)


def ensure_triggers():
    for t in TRIGGERS:
        exists = call("trigger.get", {
            "host": HOST,
            "filter": {"description": t["description"]},
            "output": ["triggerid"],
        })
        if exists:
            print("[alerts] trigger already exists:", t["description"])
            continue
        call("trigger.create", t)
        print("[alerts] created trigger:", t["description"])


def ensure_media_type():
    res = call("mediatype.get", {"filter": {"name": [MEDIA_NAME]}, "output": ["mediatypeid"]})
    if res:
        print("[alerts] media type already exists:", MEDIA_NAME)
        return res[0]["mediatypeid"]
    params = {
        "type": 1,  # 1 = script
        "name": MEDIA_NAME,
        "exec_path": "lab_alert.sh",
        "parameters": [
            {"sortorder": 0, "value": "{ALERT.SENDTO}"},
            {"sortorder": 1, "value": "{ALERT.SUBJECT}"},
            {"sortorder": 2, "value": "{ALERT.MESSAGE}"},
        ],
        "status": 0,
    }
    mtid = call("mediatype.create", params)["mediatypeids"][0]
    print("[alerts] created media type:", MEDIA_NAME)
    return mtid


def ensure_admin_media(mtid):
    users = call("user.get", {"filter": {"username": [USER]}, "selectMedias": "extend", "output": ["userid"]})
    uid = users[0]["userid"]
    for m in users[0].get("medias", []):
        if m.get("mediatypeid") == mtid:
            print("[alerts] Admin already has media 'Lab file alert'")
            return uid
    call("user.update", {
        "userid": uid,
        "medias": users[0].get("medias", []) + [{
            "mediatypeid": mtid,
            "sendto": "lab",
            "active": 0,       # 0 = enabled
            "severity": 63,    # all severities
            "period": "1-7,00:00-24:00",
        }],
    })
    print("[alerts] assigned media 'Lab file alert' to Admin user")
    return uid


def ensure_action(mtid, uid):
    existing = call("action.get", {"filter": {"name": [ACTION_NAME]}, "output": ["actionid"]})
    if existing:
        print("[alerts] action already exists:", ACTION_NAME)
        return
    params = {
        "name": ACTION_NAME,
        "eventsource": 0,   # 0 = triggers
        "status": 0,
        "esc_period": "1h",
        "filter": {
            "evaltype": 0,
            "conditions": [
                # conditiontype 1 = host; operator 0 = equals. Restrict to victim.
                # (hostid filled below)
            ],
        },
        "operations": [{
            "operationtype": 0,  # 0 = send message
            "opmessage": {
                # Script type media has no default message template,
                # so we provide the content explicitly (default_msg=0).
                "default_msg": 0,
                "mediatypeid": mtid,
                "subject": "[Zabbix] {EVENT.SEVERITY}: {TRIGGER.NAME}",
                "message": ("Problem: {TRIGGER.NAME}\nHost: {HOST.NAME}\n"
                            "Severity: {EVENT.SEVERITY}\nTime: {EVENT.DATE} {EVENT.TIME}\n"
                            "Details: {ITEM.NAME} = {ITEM.VALUE}"),
            },
            "opmessage_usr": [{"userid": uid}],
        }],
    }
    # restrict action to host victim
    hid = call("host.get", {"filter": {"host": [HOST]}, "output": ["hostid"]})[0]["hostid"]
    params["filter"]["conditions"] = [{"conditiontype": 1, "operator": 0, "value": hid}]
    call("action.create", params)
    print("[alerts] created alert action:", ACTION_NAME)


def main():
    wait_for_api()
    login()
    ensure_triggers()
    mtid = ensure_media_type()
    uid = ensure_admin_media(mtid)
    ensure_action(mtid, uid)
    print("[alerts] done. Alerts land in server log (docker compose logs zabbix-server)")


if __name__ == "__main__":
    main()
