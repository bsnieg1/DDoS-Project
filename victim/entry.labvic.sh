#!/bin/sh
# Entrypoint for victim (labvic variant): select nginx config by MODE + start
# zabbix-agent2 in the background + nginx in the foreground.
set -e

# --- 1. Select nginx config (MODE=normal|hardened) ---
# Write to /etc/nginx/active.conf (NOT /etc/nginx/nginx.conf), because the base
# docker-compose.yml bind-mounts host ./victim/nginx.conf as read-only to
# /etc/nginx/nginx.conf. Nginx starts with `-c /etc/nginx/active.conf` (CMD in
# Dockerfile.labvic), so that bind-mount is unused.
cp "/conf/${MODE:-normal}.conf" /etc/nginx/active.conf

# --- 2. zabbix-agent2 in the background (if present in the image) ---
# Agent reports CPU/memory/network of the container to Zabbix server (passive checks).
# Hostname comes from the file (default "victim") or from the ZBX_HOSTNAME variable.
ZBX_CONF=/etc/zabbix/zabbix_agent2.conf
if command -v zabbix_agent2 >/dev/null 2>&1 && [ -f "$ZBX_CONF" ]; then
    if [ -n "$ZBX_HOSTNAME" ]; then
        sed -i "s/^Hostname=.*/Hostname=${ZBX_HOSTNAME}/" "$ZBX_CONF"
    fi
    echo "[lab] starting zabbix-agent2 ..."
    zabbix_agent2 -c "$ZBX_CONF" &
else
    echo "[lab] zabbix-agent2 not available in image - skipping (nginx starts normally)"
fi

# --- 3. nginx in the foreground (original entrypoint: TLS etc.) ---
echo "[lab] handing over to nginx entrypoint ..."
exec /docker-entrypoint.sh "$@"
