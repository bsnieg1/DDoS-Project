FROM golang:1.22-alpine AS build
RUN apk add --no-cache git
WORKDIR /src
COPY rapidreset/ .
RUN [ -f go.mod ] || go mod init rapidreset; \
    go get golang.org/x/net/http2 golang.org/x/net/http2/hpack 2>/dev/null; \
    go mod tidy 2>/dev/null; \
    go build -o /rapidreset . 2>/dev/null || go build -o /rapidreset ./...
FROM alpine:3.20
# nghttp2 dostarcza h2load - uzywany w trybie "legit" (ruch imitujacy normalny
# klient HTTP/2), obok wlasnego PoC `rapidreset` (tryb "attack"). Wybor trybu
# nastepuje PO zbudowaniu obrazu, przez scenarios/botnet-fleet.sh - oba
# binarki siedza w obrazie od poczatku, nic nie jest doinstalowywane w runtime.
RUN apk add --no-cache ca-certificates nghttp2
COPY --from=build /rapidreset /usr/local/bin/rapidreset
ENTRYPOINT ["sleep", "infinity"]
