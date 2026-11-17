# Obraz victima rozszerzony o zabbix-agent2.
# Bazowy lab (docker-compose.yml) nadal uzywa czystego nginx:1.27-alpine;
# ten obraz wchodzi do gry TYLKO gdy dolaczysz docker-compose.monitoring.yml,
# ktory podmienia usluge victim na build z tego katalogu.
#
# Dzieki temu atakowany host (nginx HTTP/2) jest jednoczesnie pelnoprawnym
# hostem monitorowanym w Zabbixie: agent raportuje CPU, pamiec, load i ruch
# sieciowy tego samego kontenera, ktory obrywa w czasie HTTP/2 Rapid Reset.

# Wersja bazowego nginx jest parametryzowana, zeby mozna bylo zbudowac victima
# na starszym, PODATNYM na HTTP/2 Rapid Reset nginx (<= 1.25.2, sprzed mitygacji
# dodanej w 1.25.3). Domyslnie 1.27-alpine (zmitygowany). Nadpisanie:
#   docker compose ... build --build-arg NGINX_VERSION=1.25.2-alpine
# albo przez docker-compose.vuln.yml (ustawia ten arg automatycznie).
ARG NGINX_VERSION=1.27-alpine
FROM nginx:${NGINX_VERSION}

# zabbix-agent2 jest w repo community Alpine (7.0.x, zgodny z serwerem 7.0 LTS).
RUN apk add --no-cache zabbix-agent2

COPY zabbix_agent2.conf /etc/zabbix/zabbix_agent2.conf
COPY docker-entrypoint-lab.sh /usr/local/bin/docker-entrypoint-lab.sh
RUN chmod +x /usr/local/bin/docker-entrypoint-lab.sh

# Port nasluchu agenta (passive checks: serwer -> agent).
EXPOSE 10050

# Nasz wrapper startuje agenta w tle, a potem oddaje sterowanie
# oryginalnemu entrypointowi nginx (konfiguracja TLS + nginx na pierwszym planie).
ENTRYPOINT ["/usr/local/bin/docker-entrypoint-lab.sh"]
CMD ["nginx", "-g", "daemon off;"]
