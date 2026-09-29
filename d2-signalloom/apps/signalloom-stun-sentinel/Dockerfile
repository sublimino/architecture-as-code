# Build context is d2-signalloom/apps (see swarm-stun-sentinel-image): go.mod
# replaces .../apps/stun-sentinel => ../stun-sentinel, which must be inside the
# context. Same shape as fleet-manager (af95178a).
FROM golang:1.27-alpine AS build
COPY stun-sentinel/go.mod stun-sentinel/go.sum /src/stun-sentinel/
COPY signalloom-stun-sentinel/go.mod signalloom-stun-sentinel/go.sum /src/signalloom-stun-sentinel/
WORKDIR /src/signalloom-stun-sentinel
RUN go mod download
COPY stun-sentinel /src/stun-sentinel
COPY signalloom-stun-sentinel /src/signalloom-stun-sentinel
RUN CGO_ENABLED=0 GOFLAGS=-buildvcs=false go build -trimpath -ldflags="-s -w" -o /out/stun-sentinel .

FROM cgr.dev/chainguard/wolfi-base:latest
RUN apk add --no-cache iproute2
COPY --from=build /out/stun-sentinel /usr/local/bin/stun-sentinel
# Must run as root: needs write access to /sys/fs/cgroup (cgroup freeze)
# and CAP_NET_ADMIN for TC traffic control filters on host veth interfaces.
USER 0:0
ENTRYPOINT ["/usr/local/bin/stun-sentinel"]
