FROM golang:1.27-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY *.go ./
RUN CGO_ENABLED=0 GOFLAGS=-buildvcs=false go build -trimpath -ldflags="-s -w" -o /out/kusari-agent .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/kusari-agent /kusari-agent
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/kusari-agent"]
