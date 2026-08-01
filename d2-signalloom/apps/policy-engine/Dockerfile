FROM golang:1.24-alpine AS build
WORKDIR /src
COPY go.mod main.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/policy-engine .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/policy-engine /policy-engine
USER 65532:65532
EXPOSE 8081
ENTRYPOINT ["/policy-engine"]
