FROM golang:1.24-alpine AS build
WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/fleet-manager .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/fleet-manager /fleet-manager
USER 65532:65532
EXPOSE 8082
ENTRYPOINT ["/fleet-manager"]
