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
set -euo pipefail

DOCKER_BIN="${DOCKER_BIN:-docker}"
KIND_BIN="${KIND_BIN:-kind}"
CLUSTER_NAME="${CLUSTER_NAME:-osramp}"
NODE="${SUPERCRED_NODE:-${CLUSTER_NAME}-control-plane}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# image-name|build-context (relative to the repo root)
SUPERCRED_IMAGES=(
  "cardvault:local|d2-signalloom/apps/cardvault"
  "policy-engine:local|d2-signalloom/apps/policy-engine"
  "cardvault-agent:local|d2-signalloom/apps/cardvault-agent"
)

log()  { printf '\033[1;36m[supercred-images]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[supercred-images] ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[supercred-images] !\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m[supercred-images] FAILED:\033[0m %s\n' "$*" >&2; exit 1; }

image_name()    { printf '%s' "${1%%|*}"; }
image_context() { printf '%s' "${1##*|}"; }

# kind nodes run the host architecture; pin it explicitly so a multi-arch base
# image cannot resolve to a platform the node cannot execute.
host_platform() {
  case "$(uname -m)" in
    x86_64|amd64)  printf 'linux/amd64' ;;
    aarch64|arm64) printf 'linux/arm64' ;;
    *)             printf 'linux/amd64' ;;
  esac
}
PLATFORM="${SUPERCRED_PLATFORM:-$(host_platform)}"

# ─── Verification ───────────────────────────────────────────────────────────

# True when the CRI can actually run the image. Deliberately NOT `ctr images ls`.
image_on_node() {
  local image="$1"
  "$DOCKER_BIN" exec "$NODE" crictl images 2>/dev/null \
    | awk '{print $1":"$2}' \
    | grep -Fx "docker.io/library/${image%%:*}:${image##*:}" >/dev/null
}

verify_images() {
  local entry image missing=()
  for entry in "${SUPERCRED_IMAGES[@]}"; do
    image="$(image_name "$entry")"
    if image_on_node "$image"; then
      ok "$image present on $NODE"
    else
      missing+=("$image")
    fi
  done
  if ((${#missing[@]} > 0)); then
    warn "missing from $NODE: ${missing[*]}"
    return 1
  fi
  return 0
}

# ─── Build ──────────────────────────────────────────────────────────────────

build_images() {
  local entry image context
  for entry in "${SUPERCRED_IMAGES[@]}"; do
    image="$(image_name "$entry")"
    context="$(image_context "$entry")"
    log "building $image ($PLATFORM)"
    "$DOCKER_BIN" build --platform "$PLATFORM" -t "$image" "$REPO_ROOT/$context" \
      || fail "docker build failed for $image"
  done
  ok "built ${#SUPERCRED_IMAGES[@]} images"
}

# ─── Load ───────────────────────────────────────────────────────────────────

kind_load_all() {
  local entry names=()
  for entry in "${SUPERCRED_IMAGES[@]}"; do names+=("$(image_name "$entry")"); done
  log "loading into kind cluster $CLUSTER_NAME: ${names[*]}"
  # Exit status is not trustworthy here — verification below is what decides.
  "$KIND_BIN" load docker-image --name "$CLUSTER_NAME" "${names[@]}" || true
}

# Rebuild straight into a docker-archive tarball and import that.
#
# This is the recovery path for an image `kind load` silently declines to
# transfer. It never round-trips through the local docker image store, so a
# layer that was only lazily materialised there cannot be the missing blob:
# `--output type=docker,dest=…` forces BuildKit to write every layer into the
# archive before the command returns.
reload_via_archive() {
  local image="$1" context="$2"
  local tar
  tar="$(mktemp -t "supercred-${image%%:*}-XXXXXX.tar")"
  # shellcheck disable=SC2064  # expand $tar now, not at trap time
  trap "rm -f '$tar'" RETURN

  log "recovery: rebuilding $image directly into an archive"
  "$DOCKER_BIN" buildx build \
    --platform "$PLATFORM" \
    --provenance=false --sbom=false \
    --output "type=docker,dest=$tar" \
    -t "$image" "$REPO_ROOT/$context" \
    || { warn "buildx archive build failed for $image"; return 1; }

  log "recovery: importing $image into containerd on $NODE"
  "$DOCKER_BIN" exec -i "$NODE" ctr -n k8s.io images import --all-platforms - <"$tar" \
    || { warn "ctr import failed for $image"; return 1; }
  return 0
}

load_images() {
  kind_load_all

  local entry image context recovered=0
  for entry in "${SUPERCRED_IMAGES[@]}"; do
    image="$(image_name "$entry")"
    context="$(image_context "$entry")"
    if image_on_node "$image"; then
      continue
    fi
    warn "$image did not reach $NODE via kind load — attempting recovery"
    reload_via_archive "$image" "$context" || true
    recovered=1
  done
  [ "$recovered" -eq 1 ] && log "recovery attempted; re-verifying"

  if ! verify_images; then
    fail "one or more SuperCred images are not runnable on $NODE.
       'ctr images ls' can list an image whose layers never transferred, so this
       check uses 'crictl images' instead — a listed-but-unusable image is
       reported as missing here on purpose.
       Inspect with:
         docker exec $NODE crictl images
         docker exec $NODE ctr -n k8s.io images ls
       Then retry:  make demo-signalloom-supercred-images"
  fi
  ok "all SuperCred images verified runnable on $NODE"
}

# ─── Dispatch ───────────────────────────────────────────────────────────────

case "${1:-load}" in
  build)  build_images ;;
  load)   build_images; load_images ;;
  verify) verify_images || fail "SuperCred images are not all present on $NODE — run: make demo-signalloom-supercred-images" ;;
  *)
    echo "Usage: $0 {build|load|verify}" >&2
    exit 1
    ;;
esac
