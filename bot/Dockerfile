FROM golang:1.22-alpine AS build
RUN apk add --no-cache git
WORKDIR /src
COPY rapidreset/ .
RUN [ -f go.mod ] || go mod init rapidreset; \
    go get golang.org/x/net/http2 golang.org/x/net/http2/hpack 2>/dev/null; \
    go mod tidy 2>/dev/null; \
    go build -o /rapidreset . 2>/dev/null || go build -o /rapidreset ./...
FROM alpine:3.20
RUN apk add --no-cache ca-certificates
COPY --from=build /rapidreset /usr/local/bin/rapidreset
ENTRYPOINT ["sleep", "infinity"]
