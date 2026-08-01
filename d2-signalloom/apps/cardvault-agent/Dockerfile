FROM golang:1.24-alpine AS build
WORKDIR /src
COPY main.go go.mod ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/cardvault-agent .

FROM ghcr.io/spiffe/spire-agent:1.11.1 AS spire

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=spire /opt/spire/bin/spire-agent /usr/local/bin/spire-agent
COPY --from=build /out/cardvault-agent /cardvault-agent
USER 65532:65532
ENTRYPOINT ["/cardvault-agent"]
