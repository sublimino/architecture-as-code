FROM golang:1.27-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY *.go ./
RUN CGO_ENABLED=0 GOFLAGS=-buildvcs=false go build -trimpath -ldflags="-s -w" -o /out/nono-containment-probe .

FROM cgr.dev/chainguard/wolfi-base:latest
RUN mkdir -p /usr/local/bin && \
    printf '#!/bin/sh\nwhile [ $# -gt 0 ]; do\n  if [ "$1" = "--" ]; then shift; exec "$@"; fi\n  shift\ndone\nexec /usr/local/bin/nono-containment-probe "$@"\n' > /usr/local/bin/nono && \
    chmod +x /usr/local/bin/nono
COPY --from=build /out/nono-containment-probe /usr/local/bin/nono-containment-probe
COPY nono-profiles/probe.toml /etc/nono/probe.toml
RUN mkdir -p /workspace && \
    echo "nono-containment-probe: workspace test file" > /workspace/test.txt
USER 65532:65532
ENTRYPOINT ["nono", "--profile", "/etc/nono/probe.toml", "--", "/usr/local/bin/nono-containment-probe"]
