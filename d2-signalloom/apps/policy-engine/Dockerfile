FROM golang:1.27-alpine AS build
WORKDIR /src
# BUILD CONTEXT: d2-signalloom/ — NOT apps/policy-engine/.
#
# go.mod carries `replace .../pkg/obscel => ../../pkg/obscel`, so the module is
# no longer self-contained: a build context rooted at apps/policy-engine cannot
# see pkg/obscel and fails with `replacement directory ../../pkg/obscel does not
# exist`. Both paths below are therefore relative to d2-signalloom/.
#
#   docker build -f apps/policy-engine/Dockerfile d2-signalloom
#
# Copy whole directories, not a named file list. This was `COPY go.mod main.go
# ./`, which broke the moment the module grew beyond one file: compliance.go
# went missing (undefined: newComplianceHandler), then go.sum (missing go.sum
# entry for cel.dev/expr), then the fair/ and frameworks/ subpackages.
# `go build ./...` passed locally throughout, because locally nothing was
# missing — only the image build saw the truncated context.
COPY pkg/obscel/ ./pkg/obscel/
COPY apps/policy-engine/ ./apps/policy-engine/
WORKDIR /src/apps/policy-engine
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/policy-engine .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/policy-engine /policy-engine
USER 65532:65532
EXPOSE 8081
ENTRYPOINT ["/policy-engine"]
