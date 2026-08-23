#!/usr/bin/env bash
# Build the three SuperCred demo images and put them on the kind node — verified.
#
#   supercred-images.sh build     # build locally only
#   supercred-images.sh load      # build, load onto the node, verify
#   supercred-images.sh verify    # verify only (no build, no load)
#   supercred-images.sh           # same as load
#
# Why this exists rather than a two-line Makefile recipe:
#
# `kind load docker-image` can print "loading..." and exit 0 having transferred
# nothing. The image's manifest lands in containerd's content store while its
# layers do not, so the node ends up with a reference it cannot unpack. kubelet
# then tries to fetch the missing blob from the pull-through mirror, gets an HTML
# error page back, and reports:
#
#   failed to unpack image ... unexpected media type text/html for sha256:… : not found
#
# The trap is that `ctr -n k8s.io images ls` STILL LISTS such an image, because the
# content store holds the manifest. Any check built on `ctr images ls` therefore
# passes while the image is unusable — which is exactly how this failed silently.
# `crictl images` reports the CRI's view (unpacked and runnable), so that is the
# only sound verification and it is what this script uses.
#
# ─── …and `crictl images` alone was still not enough ────────────────────────
#
# Everything above concerns an image that did not arrive. On 2026-08-17 the
# worse variant was measured on the live cluster: the image did not arrive AND
# the node was already holding an OLDER image under the same tag. The check
# compared name and tag only, so it passed on the stale one, the pipeline exited
# 0, and the cluster ran a different binary than the one just built.
#
# Verification is therefore by IMAGE ID, in scripts/lib/image-identity.sh, which
# carries the measurement and the reasoning. Two questions, kept apart:
#
#   `load`   asks IDENTITY — is the node's image the one we just built. Nothing
#            else is a verified build.
#   `verify` asks PRESENCE — can the CRI run an image under this tag. That is
#            all the demo runner can ask: it reaches the node through
#            scripts/supercred-crictl-shim.sh, has no docker daemon and so has
#            no local image to compare against.
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

DEMO_LOG_PREFIX="supercred-images"
NODE="${SUPERCRED_NODE:-${CLUSTER_NAME}-control-plane}"
DEMO_NODE="$NODE"
DEMO_CRI_ADOPT_TIMEOUT="${SUPERCRED_CRI_ADOPT_TIMEOUT:-${IMAGE_IDENTITY_ADOPT_CHECKS:-300}}"
PLATFORM="${SUPERCRED_PLATFORM:-$(demo_host_platform)}"

# image-name|build-context|dockerfile (fields after image-name are repo-root
# relative; dockerfile is optional and defaults to <context>/Dockerfile)
DEMO_IMAGES=(
  "cardvault:local|d2-signalloom/apps/cardvault|"
  "policy-engine:local|d2-signalloom/apps/policy-engine|"
  "cardvault-agent:local|d2-signalloom/apps/cardvault-agent|"
  # Deliberately verify the runner alongside the other SuperCred images. That
  # is stricter than the host-side CLI path alone requires, but omitting it
  # would let the shared preflight pass while the dashboard-driven entrypoint
  # was still undeployed or stale.
  "supercred-demo-runner:local|.|d2-signalloom/apps/supercred-demo-runner/Dockerfile"
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
SUPERCRED_IMAGES=("${DEMO_IMAGES[@]}")

load_images() {
  demo_load_images
  demo_ok "PASS — all SuperCred images on $DEMO_NODE are the images just built locally"

  # `supercred-demo-runner` uses imagePullPolicy: IfNotPresent. Loading a new
  # local tag does not replace an already-running pod, so dashboard-triggered
  # steps could execute an older runner than the CLI path just verified.
  if kubectl -n fe-signalloom get deployment supercred-demo-runner >/dev/null 2>&1; then
    kubectl -n fe-signalloom rollout restart deployment/supercred-demo-runner
    kubectl -n fe-signalloom rollout status deployment/supercred-demo-runner --timeout=300s
  fi
}

# ─── Dispatch ───────────────────────────────────────────────────────────────

VERIFY_RC=0
case "${1:-load}" in
  build)  build_images ;;
  load)   build_images; load_images ;;
  # PRESENCE, not identity. This is the runner's preflight: it reaches the node
  # through scripts/supercred-crictl-shim.sh with no docker daemon behind it, so
  # there is no local image to compare against and identity is unanswerable
  # there by construction. Asking the weaker question and SAYING SO is honest;
  # asking the stronger one and reporting COULD-NOT-VERIFY on every image would
  # be noise that trains the reader to ignore the word.
  verify)
    verify_images presence || VERIFY_RC=$?
    case "$VERIFY_RC" in
      0) ;;
      3) warn "COULD-NOT-VERIFY — $DEMO_NODE's image listing cannot answer whether these
        images are present. Not a pass and not a failure. A genuinely absent
        image triggers Kubelet to attempt a registry pull under IfNotPresent."
         exit 3 ;;
      *) fail "SuperCred images are not all present on $DEMO_NODE — run: make demo-signalloom-supercred-images" ;;
    esac
    ;;
  # The strict form of `verify`, for callers that DO have the local images: is
  # what the node holds the thing this checkout builds?
  verify-identity)
    verify_images identity || VERIFY_RC=$?
    case "$VERIFY_RC" in
      0) ;;
      3) exit 3 ;;
      *) fail "SuperCred images on $DEMO_NODE are not the images this checkout builds — run: make demo-signalloom-supercred-images" ;;
    esac
    ;;
  *)
    echo "Usage: $0 {build|load|verify|verify-identity}" >&2
    exit 1
    ;;
esac
