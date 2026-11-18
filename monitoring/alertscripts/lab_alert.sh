#!/bin/sh
# Lab Zabbix alert script (script type media).
# Zabbix calls it with parameters set in the media type definition:
#   $1 = recipient ({ALERT.SENDTO})
#   $2 = subject   ({ALERT.SUBJECT})
#   $3 = body      ({ALERT.MESSAGE})
#
# Alert lands in the server log (visible: docker compose logs zabbix-server)
# and in the file /var/lib/zabbix/alert.log inside the server container.
LOG=/var/lib/zabbix/alert.log
LINE="$(date '+%F %T') | ALERT to=$1 | $2 | $3"
echo "[lab-alert] $LINE"
echo "$LINE" >> "$LOG" 2>/dev/null || true
