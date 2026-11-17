#!/bin/sh
# Entrypoint victima (wariant labvic): wybor configu nginx wg MODE + start
# zabbix-agent2 w tle + nginx na pierwszym planie.
set -e

# --- 1. Wybor configu nginx (MODE=normal|hardened) ---
# Piszemy do /etc/nginx/active.conf (NIE /etc/nginx/nginx.conf), bo bazowy
# docker-compose.yml bind-montuje host ./victim/nginx.conf jako read-only na
# /etc/nginx/nginx.conf. Nginx startuje z `-c /etc/nginx/active.conf` (CMD w
# Dockerfile.labvic), wiec ten bind-mount jest nieuzywany.
cp "/conf/${MODE:-normal}.conf" /etc/nginx/active.conf

# --- 2. zabbix-agent2 w tle (jesli obecny w obrazie) ---
# Agent raportuje CPU/pamiec/siec kontenera do serwera Zabbix (passive checks).
# Hostname bierze z pliku (domyslnie "victim") albo ze zmiennej ZBX_HOSTNAME.
ZBX_CONF=/etc/zabbix/zabbix_agent2.conf
if command -v zabbix_agent2 >/dev/null 2>&1 && [ -f "$ZBX_CONF" ]; then
    if [ -n "$ZBX_HOSTNAME" ]; then
        sed -i "s/^Hostname=.*/Hostname=${ZBX_HOSTNAME}/" "$ZBX_CONF"
    fi
    echo "[lab] starting zabbix-agent2 ..."
    zabbix_agent2 -c "$ZBX_CONF" &
else
    echo "[lab] zabbix-agent2 niedostepny w obrazie - pomijam (nginx wstaje normalnie)"
fi

# --- 3. nginx na pierwszym planie (oryginalny entrypoint: TLS itd.) ---
echo "[lab] handing over to nginx entrypoint ..."
exec /docker-entrypoint.sh "$@"
