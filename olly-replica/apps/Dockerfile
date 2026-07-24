# One build context (olly-replica/) for the Go service images (the MCP
# server and the stubs; the ADK sentinel builds from apps/sentinel/); APP
# selects the binary. The contracts ship inside every image at /contracts
# and the unit tests — including the contracts round-trip — run during the
# build, so an image with drifted contracts cannot exist.
#
#   docker build -f apps/Dockerfile --build-arg APP=elk-search-mcp -t olly-elk-mcp:dev .
FROM golang:1.25-alpine AS builder
ARG APP
WORKDIR /src
COPY apps/go.mod apps/go.sum ./apps/
RUN cd apps && go mod download
COPY apps ./apps
COPY contracts ./contracts
RUN cd apps && CGO_ENABLED=0 CONTRACTS_DIR=/src/contracts go test ./internal/...
RUN cd apps && CGO_ENABLED=0 go build -o /out/app ./cmd/${APP}
# The stubs image carries the replay producer alongside the mapping stub.
RUN cd apps && if [ "${APP}" = "mapping-stub" ]; then \
      CGO_ENABLED=0 go build -o /out/replay-producer ./cmd/replay-producer; \
    else touch /out/replay-producer; fi

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /out/app /app
COPY --from=builder /out/replay-producer /replay-producer
COPY --from=builder /src/contracts /contracts
USER 65532:65532
ENTRYPOINT ["/app"]
