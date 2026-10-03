FROM golang:1.27-alpine AS build
WORKDIR /src
COPY stun-sentinel /src/stun-sentinel
COPY fleet-manager /src/fleet-manager
WORKDIR /src/fleet-manager
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/fleet-manager .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/fleet-manager /fleet-manager
USER 65532:65532
EXPOSE 8082
ENTRYPOINT ["/fleet-manager"]

