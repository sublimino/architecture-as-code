# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors

FROM golang:1.24-alpine AS build
WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/node-capability-guard ./cmd

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/node-capability-guard /node-capability-guard
USER 65532:65532
EXPOSE 8443
ENTRYPOINT ["/node-capability-guard"]
