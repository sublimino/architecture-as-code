FROM golang:1.24-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY a2a/ ./a2a/
COPY main.go dispatcher.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -buildvcs=false -o /out/swarm-governor .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/swarm-governor /swarm-governor
COPY .well-known/ /.well-known/
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/swarm-governor"]
