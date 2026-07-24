FROM golang:1.25-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o listener .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /app/listener /listener
USER 65532:65532
ENTRYPOINT ["/listener"]
