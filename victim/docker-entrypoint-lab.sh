#!/bin/sh
# Wrapper entrypoint for victim: first zabbix-agent2 in the background, then nginx.
set -e

CONF=/etc/zabbix/zabbix_agent2.conf

# --- Agent identity controlled via environment variables ---
# The base host "victim" does not set any of them -> keeps Hostname=victim from the file.
# The scalable pool (docker-compose.victims.yml) sets ZBX_HOSTNAME_ITEM +
# ZBX_METADATA, so each replica has a unique name and auto-registers
# with the server (autoregistration).

if [ -n "$ZBX_HOSTNAME" ]; then
    # Fixed hostname.
    sed -i "s/^Hostname=.*/Hostname=${ZBX_HOSTNAME}/" "$CONF"
fi

if [ -n "$ZBX_HOSTNAME_PREFIX" ]; then
    # Readable, unique name: <prefix>-<container hostname>, e.g. victim-ab12cd34.
    # Used by the scalable pool (--scale), where you can't assign a fixed
    # name per replica.
    sed -i "s/^Hostname=.*/Hostname=${ZBX_HOSTNAME_PREFIX}-$(hostname)/" "$CONF"
fi

if [ -n "$ZBX_HOSTNAME_ITEM" ]; then
    # Dynamic name from system (e.g. system.hostname = container hostname).
    # Disable fixed Hostname, enable HostnameItem.
    sed -i "s/^Hostname=.*/# Hostname disabled (using HostnameItem)/" "$CONF"
    echo "HostnameItem=${ZBX_HOSTNAME_ITEM}" >> "$CONF"
fi

if [ -n "$ZBX_METADATA" ]; then
    # Metadata visible to the autoregistration rule on the server.
    echo "HostMetadata=${ZBX_METADATA}" >> "$CONF"
fi

# Start agent in the background. If the agent dies, nginx starts anyway — the lab remains
# usable, and you'll see the missing metrics in Zabbix.
echo "[lab] starting zabbix-agent2 ..."
zabbix_agent2 -c "$CONF" &

# Hand over control to the original nginx entrypoint (sets up TLS, starts
# nginx in the foreground as the main container PID).
echo "[lab] handing over to nginx entrypoint ..."
exec /docker-entrypoint.sh "$@"
