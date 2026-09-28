FROM golang:1.27-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOFLAGS=-buildvcs=false go build -trimpath -ldflags="-s -w" -o /out/cpai-engineer .

FROM cgr.dev/chainguard/wolfi-base:latest
# nono binary — in production, copy from a builder or install from package.
# For the demo, we ship a stub that logs the sandbox command.
COPY --from=build /out/cpai-engineer /usr/local/bin/cpai-engineer
COPY nono-profiles/ /etc/nono/profiles/

RUN apk add --no-cache git && \
    mkdir -p /workspace/.cpai /tmp && \
    chown -R 65534:65534 /workspace /tmp

USER 65534:65534
EXPOSE 8084
ENTRYPOINT ["cpai-engineer"]
