FROM golang:1.24-alpine AS build
WORKDIR /src
# Copy the whole module, not a named file list. This was `COPY go.mod main.go ./`,
# which broke the moment the module grew beyond one file: compliance.go went
# missing (undefined: newComplianceHandler), then go.sum (missing go.sum entry
# for cel.dev/expr), then the fair/ and frameworks/ subpackages. `go build ./...`
# passed locally throughout, because locally nothing was missing — only the image
# build saw the truncated context.
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/policy-engine .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/policy-engine /policy-engine
USER 65532:65532
EXPOSE 8081
ENTRYPOINT ["/policy-engine"]
