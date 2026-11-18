# "Legitimate client" latency probe: vegeta (HTTP load-tester with p50/p95/p99
# histograms + success%). Used at a LOW, constant rate as a MEASUREMENT, not an
# attack - shows server response time for a normal user before and during fleet pressure.
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
