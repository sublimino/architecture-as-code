FROM ghcr.io/spiffe/spire-agent:1.11.1 AS spire
FROM alpine:3.20
COPY --from=spire /opt/spire/bin/spire-agent /usr/local/bin/spire-agent
ENTRYPOINT ["/bin/sh", "-ec"]
