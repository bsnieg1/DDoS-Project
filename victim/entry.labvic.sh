#!/bin/sh
# Piszemy do /etc/nginx/active.conf (NIE /etc/nginx/nginx.conf). Powod: gdy ten
# obraz jest podlaczony pod usluge "victim" w docker-compose (docker-compose.labvic.yml),
# bazowy docker-compose.yml bind-montuje host ./victim/nginx.conf jako read-only
# na /etc/nginx/nginx.conf - nakladka nie moze tego "wyzerowac" (compose scala
# listy wolumenow po target path, nie zastepuje ich). Inna nazwa pliku omija ten
# konflikt. Domyslny CMD w Dockerfile.labvic wskazuje nginx na ten plik przez -c.
cp /conf/${MODE:-normal}.conf /etc/nginx/active.conf
exec /docker-entrypoint.sh "$@"
