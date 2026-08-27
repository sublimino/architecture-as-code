# Workspace manager image — Go HTTP server that provisions devcontainer pods.
FROM golang:1.24-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOFLAGS=-buildvcs=false go build -trimpath -ldflags="-s -w" -o /out/workspace-manager .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/workspace-manager /workspace-manager
USER 65532:65532
EXPOSE 8085
ENTRYPOINT ["/workspace-manager"]
