# Generator ruchu odniesienia: h2load z pakietu nghttp2 (MIT) + curl.
# Sluzy wylacznie do pomiaru baseline HTTP/2 wobec kontenera victim.
FROM debian:bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends nghttp2-client curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Kontener stoi bezczynnie; polecenia pomiarowe uruchamiamy przez
# `docker compose exec loadgen ...`.
CMD ["sleep", "infinity"]
