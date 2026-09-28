FROM golang:1.27-alpine AS build
WORKDIR /src

COPY signal-ingest/ ./signal-ingest/
COPY policy-engine/ ./policy-engine/
WORKDIR /src/signal-ingest
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/signal-ingest .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/signal-ingest /signal-ingest
USER 65532:65532
EXPOSE 8082
ENTRYPOINT ["/signal-ingest"]
