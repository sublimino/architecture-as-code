FROM golang:1.25-alpine AS builder

WORKDIR /app
COPY archiver.go .
COPY go.mod go.sum ./

RUN CGO_ENABLED=0 go build -o archiver-service archiver.go

FROM alpine:3.19

# Install CA certificates for HTTPS connections
RUN apk --no-cache add ca-certificates tzdata

WORKDIR /app

COPY --from=builder /app/archiver-service .

# Create non-root user
RUN adduser -D -s /bin/sh -u 65532 archiver

USER 65532:65532

ENTRYPOINT ["./archiver-service"]
