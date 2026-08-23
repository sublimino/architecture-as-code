#!/usr/bin/env bash
# Build the Signal Fusion images and put them on the kind node — verified.
#
#   signalfusion-images.sh build     # build locally only
#   signalfusion-images.sh load      # build, load onto the node, verify
#   signalfusion-images.sh verify    # verify only (no build, no load)
#   signalfusion-images.sh           # same as load
#
# Same verified-build pattern as supercred-images.sh: build, kind load, crictl
# verify. See that script's header for why crictl (not ctr) is the only sound
# verification.
#
# ─── What "verified" did not cover, and now does ────────────────────────────
#
# The pattern copied from supercred-images.sh compared NAME AND TAG ONLY, so any
# image carrying the tag satisfied it — including the previous build. This
# script's own image is the one that proved it. On 2026-08-17, after
# `make demo-signalloom-up` exited 0:
#
#   host docker : signal-ingest:local  sha256:ac70e5d4e068…  14.5MB  (9 min old)
#   kind node   : signal-ingest:local  7913092728b75          5.33MB  (different)
#
# The header above said "verified". It was not. Verification is now by IMAGE ID
# via scripts/lib/image-identity.sh, which carries the measurement in full.
set -euo pipefail

DOCKER_BIN="${DOCKER_BIN:-docker}"
KIND_BIN="${KIND_BIN:-kind}"
CLUSTER_NAME="${CLUSTER_NAME:-osramp}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/source-id.sh
source "${REPO_ROOT}/scripts/lib/source-id.sh"
# shellcheck source=scripts/lib/image-identity.sh
source "${REPO_ROOT}/scripts/lib/image-identity.sh"
# shellcheck source=scripts/lib/demo-images.sh
source "${REPO_ROOT}/scripts/lib/demo-images.sh"

# ─── Configuration for the shared library ──────────────────────────────────

DEMO_LOG_PREFIX="signalfusion-images"
NODE="${SIGNALFUSION_NODE:-${CLUSTER_NAME}-control-plane}"
DEMO_NODE="$NODE"
DEMO_CRI_ADOPT_TIMEOUT="${SIGNALFUSION_CRI_ADOPT_TIMEOUT:-${IMAGE_IDENTITY_ADOPT_CHECKS:-300}}"
PLATFORM="${SIGNALFUSION_PLATFORM:-$(demo_host_platform)}"

# image-name|build-context|dockerfile (fields after image-name are repo-root
# relative; dockerfile is optional and defaults to <context>/Dockerfile)
DEMO_IMAGES=(
  "signal-ingest:local|d2-signalloom/apps/signal-ingest|"
)

# Backward-compat aliases: tests and callers may reference the old names.
log()  { demo_log "$@"; }
ok()   { demo_ok "$@"; }
warn() { demo_warn "$@"; }
fail() { demo_fail "$@"; }
image_name()       { demo_image_name "$@"; }
image_context()    { demo_image_context "$@"; }
image_dockerfile() { demo_image_dockerfile "$@"; }
host_platform()    { demo_host_platform "$@"; }
image_on_node()    { demo_image_on_node "$@"; }
listing_is_truncated() { demo_listing_is_truncated "$@"; }
verify_images()    { demo_verify_images "$@"; }
build_id_args()    { demo_build_id_args "$@"; }
build_images()     { demo_build_images "$@"; }
kind_load_all()    { demo_kind_load_all "$@"; }
reload_via_archive() { demo_reload_via_archive "$@"; }

# Also expose the image list under its old name for anything that reads it.
SIGNALFUSION_IMAGES=("${DEMO_IMAGES[@]}")

load_images() {
  demo_load_images
  demo_ok "PASS — all Signal Fusion images on $DEMO_NODE are the images just built locally"
}

# ─── Dispatch ───────────────────────────────────────────────────────────────

VERIFY_RC=0
case "${1:-load}" in
  build)  build_images ;;
  load)   build_images; load_images ;;
  # PRESENCE, for callers that only need to know a workload can start.
  verify)
    verify_images presence || VERIFY_RC=$?
    case "$VERIFY_RC" in
      0) ;;
      3) warn "COULD-NOT-VERIFY — $DEMO_NODE's image listing cannot answer. Not a pass and
       not a failure; a genuinely absent image surfaces as ErrImageNeverPull."
         exit 3 ;;
      *) fail "Signal Fusion images are not all present on $DEMO_NODE — run: make demo-signalloom-signalfusion-images" ;;
    esac
    ;;
  # IDENTITY, for callers that hold the local images and need to know the node
  # is running what this checkout builds.
  verify-identity)
    verify_images identity || VERIFY_RC=$?
    case "$VERIFY_RC" in
      0) ;;
      3) exit 3 ;;
      *) fail "Signal Fusion images on $DEMO_NODE are not the images this checkout builds — run: make demo-signalloom-signalfusion-images" ;;
    esac
    ;;
  *)
    echo "Usage: $0 {build|load|verify|verify-identity}" >&2
    exit 1
    ;;
esac
