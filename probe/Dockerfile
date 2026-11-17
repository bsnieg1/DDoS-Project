# Sonda latencji "uczciwego klienta": vegeta (HTTP load-tester z histogramami
# p50/p95/p99 + success%). Uzywana przy NISKIM, stalym tempie jako POMIAR, nie
# atak - pokazuje czas odpowiedzi serwera dla normalnego uzytkownika przed i w
# trakcie naporu floty.
FROM alpine:3.20 AS build
ARG VEGETA_VERSION=12.12.0
RUN apk add --no-cache curl tar \
 && curl -sSL "https://github.com/tsenart/vegeta/releases/download/v${VEGETA_VERSION}/vegeta_${VEGETA_VERSION}_linux_amd64.tar.gz" \
    | tar -xz -C /usr/local/bin vegeta

FROM alpine:3.20
RUN apk add --no-cache ca-certificates jq
COPY --from=build /usr/local/bin/vegeta /usr/local/bin/vegeta
COPY run.sh /run.sh
RUN chmod +x /run.sh
ENTRYPOINT ["/run.sh"]
