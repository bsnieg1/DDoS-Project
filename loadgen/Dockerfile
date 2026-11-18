# Reference traffic generator: h2load from the nghttp2 package (MIT) + curl.
# Used solely for measuring HTTP/2 baseline against the victim container.
FROM debian:bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends nghttp2-client curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Container stays idle; measurement commands are run via
# `docker compose exec loadgen ...`.
CMD ["sleep", "infinity"]
