FROM golang:1.22-alpine AS build
RUN apk add --no-cache git
WORKDIR /src
COPY rapidreset/ .
RUN [ -f go.mod ] || go mod init rapidreset; \
    go get golang.org/x/net/http2 golang.org/x/net/http2/hpack 2>/dev/null; \
    go mod tidy 2>/dev/null; \
    go build -o /rapidreset . 2>/dev/null || go build -o /rapidreset ./...
FROM alpine:3.20
# nghttp2 provides h2load - used in "legit" mode (traffic imitating a normal
# HTTP/2 client), alongside the custom PoC `rapidreset` ("attack" mode). Mode
# selection happens AFTER the image is built, via scenarios/botnet-fleet.sh - both
# binaries are in the image from the start, nothing is installed at runtime.
RUN apk add --no-cache ca-certificates nghttp2
COPY --from=build /rapidreset /usr/local/bin/rapidreset
ENTRYPOINT ["sleep", "infinity"]
