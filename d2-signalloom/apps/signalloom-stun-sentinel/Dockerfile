FROM golang:1.22-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
RUN CGO_ENABLED=0 GOFLAGS=-buildvcs=false go build -trimpath -ldflags="-s -w" -o /out/stun-sentinel .

FROM cgr.dev/chainguard/wolfi-base:latest
RUN apk add --no-cache iproute2
COPY --from=build /out/stun-sentinel /usr/local/bin/stun-sentinel
# Must run as root: needs write access to /sys/fs/cgroup (cgroup freeze)
# and CAP_NET_ADMIN for TC traffic control filters on host veth interfaces.
USER 0:0
ENTRYPOINT ["/usr/local/bin/stun-sentinel"]
