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
set -euo pipefail

DOCKER_BIN="${DOCKER_BIN:-docker}"
KIND_BIN="${KIND_BIN:-kind}"
CLUSTER_NAME="${CLUSTER_NAME:-osramp}"
NODE="${SIGNALFUSION_NODE:-${CLUSTER_NAME}-control-plane}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/source-id.sh
source "${REPO_ROOT}/scripts/lib/source-id.sh"

# image-name|build-context|dockerfile (fields after image-name are repo-root
# relative; dockerfile is optional and defaults to <context>/Dockerfile)
SIGNALFUSION_IMAGES=(
  "signal-ingest:local|d2-signalloom/apps/signal-ingest|"
)

log()  { printf '\033[1;36m[signalfusion-images]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[signalfusion-images] ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[signalfusion-images] !\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m[signalfusion-images] FAILED:\033[0m %s\n' "$*" >&2; exit 1; }

image_name() {
  local image context dockerfile
  IFS='|' read -r image context dockerfile <<<"$1"
  printf '%s' "$image"
}

image_context() {
  local image context dockerfile
  IFS='|' read -r image context dockerfile <<<"$1"
  printf '%s' "$context"
}

image_dockerfile() {
  local image context dockerfile
  IFS='|' read -r image context dockerfile <<<"$1"
  printf '%s' "$dockerfile"
}

# kind nodes run the host architecture; pin it explicitly so a multi-arch base
# image cannot resolve to a platform the node cannot execute.
host_platform() {
  case "$(uname -m)" in
    x86_64|amd64)  printf 'linux/amd64' ;;
    aarch64|arm64) printf 'linux/arm64' ;;
    *)             printf 'linux/amd64' ;;
  esac
}
PLATFORM="${SIGNALFUSION_PLATFORM:-$(host_platform)}"

# ─── Verification ───────────────────────────────────────────────────────────

# True when the CRI can actually run the image. Deliberately NOT `ctr images ls`.
# See supercred-images.sh for the full explanation of why.
image_on_node() {
  local image="$1"
  local want="docker.io/library/${image%%:*}:${image##*:}"
  "$DOCKER_BIN" exec "$NODE" crictl images 2>/dev/null \
    | awk -v want="$want" '$1":"$2 == want { found = 1 } END { exit !found }'
}

listing_is_truncated() {
  "$DOCKER_BIN" exec "$NODE" crictl images 2>&1 >/dev/null \
    | grep -q "node.status.images is at the kubelet cap"
}

verify_images() {
  local entry image missing=()
  for entry in "${SIGNALFUSION_IMAGES[@]}"; do
    image="$(image_name "$entry")"
    if image_on_node "$image"; then
      ok "$image present on $NODE"
    else
      missing+=("$image")
    fi
  done
  if ((${#missing[@]} > 0)); then
    if listing_is_truncated; then
      warn "not visible in $NODE's image list: ${missing[*]}"
      warn "list is TRUNCATED (kubelet cap) — continuing; a genuinely absent"
      warn "image will fail as ErrImageNeverPull on the workload."
      return 0
    fi
    warn "missing from $NODE: ${missing[*]}"
    return 1
  fi
  return 0
}

# ─── Build ──────────────────────────────────────────────────────────────────

build_id_args() {
  local image="$1" args=()
  mapfile -t args < <(source_id_build_args "${image%%:*}" 2>/dev/null) || return 0
  ((${#args[@]})) || return 0
  printf '%s\n' "${args[@]}"
}

build_images() {
  local entry image context dockerfile id_args
  local target_arch="${PLATFORM##*/}"
  for entry in "${SIGNALFUSION_IMAGES[@]}"; do
    image="$(image_name "$entry")"
    context="$(image_context "$entry")"
    dockerfile="$(image_dockerfile "$entry")"
    mapfile -t id_args < <(build_id_args "$image")
    log "building $image ($PLATFORM)"
    if [ -n "$dockerfile" ]; then
      "$DOCKER_BIN" build --platform "$PLATFORM" --build-arg "TARGETARCH=${target_arch}" ${id_args[@]+"${id_args[@]}"} -f "$REPO_ROOT/$dockerfile" -t "$image" "$REPO_ROOT/$context" \
        || fail "docker build failed for $image via $dockerfile"
    else
      "$DOCKER_BIN" build --platform "$PLATFORM" --build-arg "TARGETARCH=${target_arch}" ${id_args[@]+"${id_args[@]}"} -t "$image" "$REPO_ROOT/$context" \
        || fail "docker build failed for $image"
    fi
  done
  ok "built ${#SIGNALFUSION_IMAGES[@]} image(s)"
}

# ─── Load ───────────────────────────────────────────────────────────────────

kind_load_all() {
  local entry names=()
  for entry in "${SIGNALFUSION_IMAGES[@]}"; do names+=("$(image_name "$entry")"); done
  log "loading into kind cluster $CLUSTER_NAME: ${names[*]}"
  "$KIND_BIN" load docker-image --name "$CLUSTER_NAME" "${names[@]}" || true
}

reload_via_archive() {
  local image="$1" context="$2" dockerfile="${3:-}"
  local tar
  tar="$(mktemp -t "signalfusion-${image%%:*}-XXXXXX.tar")"
  # shellcheck disable=SC2064  # expand $tar now, not at trap time
  trap "rm -f '$tar'" RETURN

  log "recovery: rebuilding $image directly into an archive"
  if [ -n "$dockerfile" ]; then
    "$DOCKER_BIN" buildx build \
      --platform "$PLATFORM" \
      --provenance=false --sbom=false \
      --output "type=docker,dest=$tar" \
      -f "$REPO_ROOT/$dockerfile" \
      -t "$image" "$REPO_ROOT/$context" \
      || { warn "buildx archive build failed for $image via $dockerfile"; return 1; }
  else
    "$DOCKER_BIN" buildx build \
      --platform "$PLATFORM" \
      --provenance=false --sbom=false \
      --output "type=docker,dest=$tar" \
      -t "$image" "$REPO_ROOT/$context" \
      || { warn "buildx archive build failed for $image"; return 1; }
  fi

  log "recovery: importing $image into containerd on $NODE"
  "$DOCKER_BIN" exec "$NODE" \
    ctr -n k8s.io images rm "docker.io/library/${image%%:*}:${image##*:}" >/dev/null 2>&1 \
    || true
  "$DOCKER_BIN" exec -i "$NODE" \
    ctr -n k8s.io images import --all-platforms --snapshotter=overlayfs - <"$tar" \
    || { warn "ctr import failed for $image"; return 1; }

  "$DOCKER_BIN" exec "$NODE" \
    ctr -n k8s.io images label "docker.io/library/${image%%:*}:${image##*:}" \
      io.cri-containerd.image=managed >/dev/null \
    || { warn "could not label $image as CRI-managed"; return 1; }

  local waited=0
  while [ "$waited" -lt "${SIGNALFUSION_CRI_ADOPT_TIMEOUT:-90}" ]; do
    image_on_node "$image" && return 0
    sleep 1
    waited=$((waited + 1))
  done

  if "$DOCKER_BIN" exec "$NODE" ctr -n k8s.io images ls -q 2>/dev/null \
      | grep -Fqx "docker.io/library/${image%%:*}:${image##*:}"; then
    warn "$image is in the content store and labelled, but the CRI has not adopted it after ${waited}s — slow unpack, not a failed import; re-run"
  else
    warn "$image is not in the content store after ${waited}s — the import itself failed"
  fi
  return 1
}

load_images() {
  kind_load_all

  local entry image context dockerfile recovered=0
  for entry in "${SIGNALFUSION_IMAGES[@]}"; do
    image="$(image_name "$entry")"
    context="$(image_context "$entry")"
    dockerfile="$(image_dockerfile "$entry")"
    if image_on_node "$image"; then
      continue
    fi
    warn "$image did not reach $NODE via kind load — attempting recovery"
    reload_via_archive "$image" "$context" "$dockerfile" || true
    recovered=1
  done
  [ "$recovered" -eq 1 ] && log "recovery attempted; re-verifying"

  if ! verify_images; then
    fail "Signal Fusion images are not runnable on $NODE.
       Inspect with:
         docker exec $NODE crictl images
         docker exec $NODE ctr -n k8s.io images ls
       Then retry:  make demo-signalloom-signalfusion-images"
  fi
  ok "all Signal Fusion images verified runnable on $NODE"
}

# ─── Dispatch ───────────────────────────────────────────────────────────────

case "${1:-load}" in
  build)  build_images ;;
  load)   build_images; load_images ;;
  verify) verify_images || fail "Signal Fusion images are not all present on $NODE — run: make demo-signalloom-signalfusion-images" ;;
  *)
    echo "Usage: $0 {build|load|verify}" >&2
    exit 1
    ;;
esac
