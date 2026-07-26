FROM golang:1.24-alpine AS helper
WORKDIR /src
COPY proof-helper/go.mod proof-helper/main.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/signalloom-spire-proof .

FROM ghcr.io/spiffe/spire-agent:1.11.1 AS spire
FROM alpine:3.20
COPY --from=spire /opt/spire/bin/spire-agent /usr/local/bin/spire-agent
COPY --from=helper /out/signalloom-spire-proof /usr/local/bin/signalloom-spire-proof
ENTRYPOINT ["/usr/local/bin/signalloom-spire-proof"]
