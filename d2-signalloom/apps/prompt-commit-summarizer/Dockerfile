FROM golang:1.27-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOFLAGS=-buildvcs=false go build -trimpath -ldflags="-s -w" -o /out/prompt-commit-summarizer .

FROM cgr.dev/chainguard/static:latest
COPY --from=build /out/prompt-commit-summarizer /prompt-commit-summarizer
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/prompt-commit-summarizer"]
