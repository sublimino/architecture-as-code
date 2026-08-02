# Bakes the pinned NetAssert v2.1.5 (https://github.com/controlplaneio/netassert)
# binary into a local image at BUILD time, the same hermetic pattern as
# proof-helper.Dockerfile / signalloom-spire-helper — every workload image in
# this demo is `docker build`ed then `kind load docker-image`d with
# imagePullPolicy: Never, so no cluster pod ever needs public-internet egress.
# The netassert-run Job (created by fake-integration-proxy on Scan Now) uses
# this image and therefore needs no new egress NetworkPolicy at all.
#
# NETASSERT_SHA256 pins the exact release asset digest (fetched from
# https://api.github.com/repos/controlplaneio/netassert/releases/tags/v2.1.5
# at authoring time) — a corrupted or substituted download fails the build
# rather than silently running something else.
FROM alpine:3.20 AS fetch
ARG NETASSERT_VERSION=v2.1.5
ARG NETASSERT_SHA256=bbf662f60e6fc5920f63cf2baa6a6aaf85b8441cdca506370afe96dedbd434ae
RUN apk add --no-cache curl && \
    curl -fsSL -o /tmp/netassert.tar.gz \
      "https://github.com/controlplaneio/netassert/releases/download/${NETASSERT_VERSION}/netassert_${NETASSERT_VERSION}_linux_amd64.tar.gz" && \
    echo "${NETASSERT_SHA256}  /tmp/netassert.tar.gz" | sha256sum -c - && \
    tar -xzf /tmp/netassert.tar.gz -C /tmp && \
    install -m 0755 /tmp/netassert /usr/local/bin/netassert

FROM alpine:3.20
RUN apk add --no-cache curl
COPY --from=fetch /usr/local/bin/netassert /usr/local/bin/netassert
COPY netassert-runner/resolve-agent-pod.sh /usr/local/bin/resolve-agent-pod.sh
RUN chmod +x /usr/local/bin/resolve-agent-pod.sh
ENTRYPOINT ["/usr/local/bin/netassert"]
