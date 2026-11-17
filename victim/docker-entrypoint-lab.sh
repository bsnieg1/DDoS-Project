#!/bin/sh
# Wrapper entrypointu victima: najpierw zabbix-agent2 w tle, potem nginx.
set -e

CONF=/etc/zabbix/zabbix_agent2.conf

# --- Tozsamosc agenta sterowana przez zmienne srodowiskowe ---
# Bazowy host "victim" nie ustawia zadnej z nich -> zostaje Hostname=victim z pliku.
# Skalowalna pula (docker-compose.victims.yml) ustawia ZBX_HOSTNAME_ITEM +
# ZBX_METADATA, zeby kazda replika miala unikalna nazwe i sama zarejestrowala
# sie w serwerze (autoregistration).

if [ -n "$ZBX_HOSTNAME" ]; then
    # Sztywna nazwa hosta.
    sed -i "s/^Hostname=.*/Hostname=${ZBX_HOSTNAME}/" "$CONF"
fi

if [ -n "$ZBX_HOSTNAME_PREFIX" ]; then
    # Czytelna, unikalna nazwa: <prefiks>-<hostname kontenera>, np. victim-ab12cd34.
    # Uzywane przez skalowalna pule (--scale), gdzie nie da sie nadac sztywnej
    # nazwy per replika.
    sed -i "s/^Hostname=.*/Hostname=${ZBX_HOSTNAME_PREFIX}-$(hostname)/" "$CONF"
fi

if [ -n "$ZBX_HOSTNAME_ITEM" ]; then
    # Dynamiczna nazwa z systemu (np. system.hostname = hostname kontenera).
    # Wylaczamy sztywny Hostname, wlaczamy HostnameItem.
    sed -i "s/^Hostname=.*/# Hostname wylaczony (uzywamy HostnameItem)/" "$CONF"
    echo "HostnameItem=${ZBX_HOSTNAME_ITEM}" >> "$CONF"
fi

if [ -n "$ZBX_METADATA" ]; then
    # Metadane widoczne dla reguly autoregistration na serwerze.
    echo "HostMetadata=${ZBX_METADATA}" >> "$CONF"
fi

# Start agenta w tle. Jesli agent padnie, nginx i tak wstaje — lab pozostaje
# uzywalny, a brak metryk zobaczysz w Zabbixie.
echo "[lab] starting zabbix-agent2 ..."
zabbix_agent2 -c "$CONF" &

# Oddaj sterowanie oryginalnemu entrypointowi nginx (ustawia TLS, uruchamia
# nginx na pierwszym planie jako PID glowny kontenera).
echo "[lab] handing over to nginx entrypoint ..."
exec /docker-entrypoint.sh "$@"
