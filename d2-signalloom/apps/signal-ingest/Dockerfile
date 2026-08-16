FROM golang:1.24-alpine AS build
WORKDIR /src

# Copy the whole module, not a named file list.
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/signal-ingest .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/signal-ingest /signal-ingest
USER 65532:65532
EXPOSE 8082
ENTRYPOINT ["/signal-ingest"]
