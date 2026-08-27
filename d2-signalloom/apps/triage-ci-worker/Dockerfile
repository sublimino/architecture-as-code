FROM golang:1.22-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOFLAGS=-buildvcs=false go build -trimpath -ldflags="-s -w" -o /out/triage-ci-worker .

FROM cgr.dev/chainguard/wolfi-base:latest
RUN apk add --no-cache github-cli
COPY --from=build /out/triage-ci-worker /triage-ci-worker
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/triage-ci-worker"]
