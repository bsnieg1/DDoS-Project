#!/usr/bin/env python3
"""
Detekcja w Zabbixie: triggery wykrywajace przeciazenie / HTTP/2 Rapid Reset na
hoscie "victim" + prosty kanal alertowania (media type typu "script" -> log serwera).

Tworzy (idempotentnie):
  TRIGGERY na hoscie victim:
    1. "DoS: wysokie uzycie CPU na victim"        (High)
    2. "DoS: wysoka liczba zadan/s nginx (victim)" (Average)
    3. "Mozliwy HTTP/2 Rapid Reset na victim"       (Disaster) -- sygnatura:
        duzo zadan/s w stosunku do nowych polaczen (wiele strumieni na jedno
        polaczenie TCP) + podwyzszone CPU. To wprost obraz CVE-2023-44487.
  ALERTOWANIE:
    - media type "Lab file alert" (script lab_alert.sh),
    - przypisanie media userowi Admin,
    - akcja na problemy -> wyslij alert do Admina.

Uruchamiane zwykle przez usluge `zabbix-alerts` (profil "provision").
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

# Progi dobrane do labu (baseline: CPU ~0.5%, zadania ~0.02/s).
TRIGGERS = [
    {
        "description": "DoS: wysokie uzycie CPU na victim",
        "expression": "min(/victim/system.cpu.util,#2)>60",
        "priority": 4,  # High
        "comments": "Srednie uzycie CPU victima przekracza 60% w 2 kolejnych pomiarach. "
                    "Przy niskim wolumenie 'uzytecznego' ruchu to sygnal DoS.",
    },
    {
        "description": "DoS: wysoka liczba zadan/s nginx (victim)",
        "expression": "last(/victim/nginx.requests.total.rate)>30",
        "priority": 3,  # Average
        "comments": "Gwaltowny wzrost liczby zadan/s na nginx wzgledem baseline (~0.02/s).",
    },
    {
        "description": "Mozliwy HTTP/2 Rapid Reset na victim",
        # Sygnatura: zadania/s >> tempo nowych polaczen (duzo strumieni na
        # jedno polaczenie) + realny wzrost zadan + podwyzszone CPU.
        "expression": (
            "last(/victim/nginx.requests.total.rate)"
            ">20*last(/victim/nginx.connections.accepted.rate)"
            " and last(/victim/nginx.requests.total.rate)>20"
            " and last(/victim/system.cpu.util)>30"
        ),
        "priority": 5,  # Disaster
        "comments": "Wiele zadan (strumieni HTTP/2) na jedno polaczenie TCP przy "
                    "podwyzszonym CPU — obraz CVE-2023-44487 (Rapid Reset).",
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
    with urllib.request.urlopen(req, timeout=15) as resp:
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
            print("[alerts] czekam na API (%d/%d): %s" % (i + 1, retries, e))
            time.sleep(delay)
    print("[alerts] API nie wstalo", file=sys.stderr)
    sys.exit(1)


def login():
    global _token
    _token = call("user.login", {"username": USER, "password": PASS}, auth=False)
    print("[alerts] zalogowano jako", USER)


def ensure_triggers():
    for t in TRIGGERS:
        exists = call("trigger.get", {
            "host": HOST,
            "filter": {"description": t["description"]},
            "output": ["triggerid"],
        })
        if exists:
            print("[alerts] trigger juz istnieje:", t["description"])
            continue
        call("trigger.create", t)
        print("[alerts] utworzono trigger:", t["description"])


def ensure_media_type():
    res = call("mediatype.get", {"filter": {"name": [MEDIA_NAME]}, "output": ["mediatypeid"]})
    if res:
        print("[alerts] media type juz istnieje:", MEDIA_NAME)
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
    print("[alerts] utworzono media type:", MEDIA_NAME)
    return mtid


def ensure_admin_media(mtid):
    users = call("user.get", {"filter": {"username": [USER]}, "selectMedias": "extend", "output": ["userid"]})
    uid = users[0]["userid"]
    for m in users[0].get("medias", []):
        if m.get("mediatypeid") == mtid:
            print("[alerts] Admin ma juz media 'Lab file alert'")
            return uid
    call("user.update", {
        "userid": uid,
        "medias": users[0].get("medias", []) + [{
            "mediatypeid": mtid,
            "sendto": "lab",
            "active": 0,       # 0 = enabled
            "severity": 63,    # wszystkie severity
            "period": "1-7,00:00-24:00",
        }],
    })
    print("[alerts] przypisano media 'Lab file alert' userowi Admin")
    return uid


def ensure_action(mtid, uid):
    existing = call("action.get", {"filter": {"name": [ACTION_NAME]}, "output": ["actionid"]})
    if existing:
        print("[alerts] akcja juz istnieje:", ACTION_NAME)
        return
    params = {
        "name": ACTION_NAME,
        "eventsource": 0,   # 0 = triggery
        "status": 0,
        "esc_period": "1h",
        "filter": {
            "evaltype": 0,
            "conditions": [
                # conditiontype 1 = host; operator 0 = equals. Ograniczamy do victima.
                # (hostid uzupelniamy nizej)
            ],
        },
        "operations": [{
            "operationtype": 0,  # 0 = send message
            "opmessage": {
                # Media type typu "script" nie ma domyslnego szablonu wiadomosci,
                # wiec podajemy tresc wprost (default_msg=0).
                "default_msg": 0,
                "mediatypeid": mtid,
                "subject": "[Zabbix] {EVENT.SEVERITY}: {TRIGGER.NAME}",
                "message": ("Problem: {TRIGGER.NAME}\nHost: {HOST.NAME}\n"
                            "Waga: {EVENT.SEVERITY}\nCzas: {EVENT.DATE} {EVENT.TIME}\n"
                            "Szczegoly: {ITEM.NAME} = {ITEM.VALUE}"),
            },
            "opmessage_usr": [{"userid": uid}],
        }],
    }
    # ogranicz akcje do hosta victim
    hid = call("host.get", {"filter": {"host": [HOST]}, "output": ["hostid"]})[0]["hostid"]
    params["filter"]["conditions"] = [{"conditiontype": 1, "operator": 0, "value": hid}]
    call("action.create", params)
    print("[alerts] utworzono akcje alertowa:", ACTION_NAME)


def main():
    wait_for_api()
    login()
    ensure_triggers()
    mtid = ensure_media_type()
    uid = ensure_admin_media(mtid)
    ensure_action(mtid, uid)
    print("[alerts] gotowe. Alerty laduja w logu serwera (docker compose logs zabbix-server)")


if __name__ == "__main__":
    main()
