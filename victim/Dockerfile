# Victim image extended with zabbix-agent2.
# The base lab (docker-compose.yml) still uses plain nginx:1.27-alpine;
# this image comes into play ONLY when you include docker-compose.monitoring.yml,
# which replaces the victim service with a build from this directory.
#
# This way the attacked host (nginx HTTP/2) is simultaneously a fully monitored
# host in Zabbix: the agent reports CPU, memory, load and network traffic
# of the same container that takes hits during the HTTP/2 Rapid Reset attack.

# The base nginx version is parameterized so the victim can be built on an older,
# VULNERABLE to HTTP/2 Rapid Reset nginx (<= 1.25.2, before the mitigation
# added in 1.25.3). Default 1.27-alpine (mitigated). Override:
#   docker compose ... build --build-arg NGINX_VERSION=1.25.2-alpine
# or via docker-compose.vuln.yml (sets this arg automatically).
ARG NGINX_VERSION=1.27-alpine
FROM nginx:${NGINX_VERSION}

# zabbix-agent2 is in the Alpine community repo (7.0.x, compatible with server 7.0 LTS).
RUN apk add --no-cache zabbix-agent2

COPY zabbix_agent2.conf /etc/zabbix/zabbix_agent2.conf
COPY docker-entrypoint-lab.sh /usr/local/bin/docker-entrypoint-lab.sh
RUN chmod +x /usr/local/bin/docker-entrypoint-lab.sh

# Agent listen port (passive checks: server -> agent).
EXPOSE 10050

# Our wrapper starts the agent in the background, then hands over control
# to the original nginx entrypoint (TLS setup + nginx in the foreground).
ENTRYPOINT ["/usr/local/bin/docker-entrypoint-lab.sh"]
CMD ["nginx", "-g", "daemon off;"]
