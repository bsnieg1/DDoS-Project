#!/bin/sh
# Labowy skrypt alertu Zabbixa (media type typu "script").
# Zabbix wola go z parametrami, ktore ustawiamy w definicji media type:
#   $1 = odbiorca ({ALERT.SENDTO})
#   $2 = temat    ({ALERT.SUBJECT})
#   $3 = tresc    ({ALERT.MESSAGE})
#
# Alert laduje w logu serwera (widoczny: docker compose logs zabbix-server)
# oraz w pliku /var/lib/zabbix/alert.log wewnatrz kontenera serwera.
LOG=/var/lib/zabbix/alert.log
LINE="$(date '+%F %T') | ALERT to=$1 | $2 | $3"
echo "[lab-alert] $LINE"
echo "$LINE" >> "$LOG" 2>/dev/null || true
