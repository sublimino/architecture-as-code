FROM golang:1.24-alpine AS build
WORKDIR /src
COPY go.mod main.go token.go webhook.go ./
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -buildvcs=false -o /out/prod-deploy-gate .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/prod-deploy-gate /prod-deploy-gate
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/prod-deploy-gate"]
