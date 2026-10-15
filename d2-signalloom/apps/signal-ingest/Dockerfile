FROM golang:1.27-alpine AS build
WORKDIR /src

# The build context is d2-signalloom/, not d2-signalloom/apps/ (see DEMO_IMAGES in
# scripts/signalfusion-images.sh). It has to be: signal-ingest/go.mod carries
# `replace ... /pkg/obscel => ../../pkg/obscel`, which resolves outside apps/, and
# docker refuses a COPY whose source lies outside the context. The layout under
# /src mirrors the repo so the ../ hops in both replace directives still resolve.
#
# All three local modules are copied even though obscel has no importer yet: the
# first commit that imports it would otherwise break the image build, and nothing
# in the offline suite would catch it. TestBuildScriptAndDockerfileAgreeOnTheContext
# resolves every COPY source against the context the script passes.
COPY apps/signal-ingest/ ./apps/signal-ingest/
COPY apps/policy-engine/ ./apps/policy-engine/
COPY pkg/obscel/ ./pkg/obscel/
WORKDIR /src/apps/signal-ingest
# -tags frostdb selects store/factory_frostdb.go. Without it the !frostdb factory
# is compiled in, SIGNAL_STORE=frostdb in the Deployment is ignored, and the pod
# runs an in-memory store over a PersistentVolumeClaim it never writes to.
# internal/imagetag lists with the same tag, so the tag covers what this compiles.
RUN CGO_ENABLED=0 go build -tags frostdb -trimpath -ldflags="-s -w" -o /out/signal-ingest .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/signal-ingest /signal-ingest
# FrostDB fans every scan out to GOMAXPROCS consumer goroutines (read once at init,
# query/physicalplan concurrencyHardcoded), each holding a 5 MiB read buffer per
# projected Parquet column chunk. The Deployment sets no CPU limit, so without this
# GOMAXPROCS is the node's core count (24 on kind-osramp) and any scan that reads the
# whole store holds 24 row groups at once: the working set tracked the store, and the
# pod was OOM-killed at 2 GiB (2026-10-15). A Deployment env or a CPU limit overrides it.
# See store.TestFrostDB_FullScanPeakIsBoundedAtTheImageGOMAXPROCS.
ENV GOMAXPROCS=2
USER 65532:65532
EXPOSE 8082
ENTRYPOINT ["/signal-ingest"]
