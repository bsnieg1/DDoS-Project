#!/bin/sh
cp /conf/${MODE:-normal}.conf /etc/nginx/nginx.conf
exec /docker-entrypoint.sh "$@"
