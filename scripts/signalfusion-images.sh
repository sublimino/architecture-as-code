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
NODE="${SIGNALFUSION_NODE:-${CLUSTER_NAME}-control-plane}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/source-id.sh
source "${REPO_ROOT}/scripts/lib/source-id.sh"
# shellcheck source=scripts/lib/image-identity.sh
source "${REPO_ROOT}/scripts/lib/image-identity.sh"

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

# True when the CRI can actually run *an* image under this tag. Deliberately NOT
# `ctr images ls`. See supercred-images.sh for the full explanation of why.
#
# Presence only — it says nothing about WHICH image, which is why it is no
# longer the gate.
image_on_node() {
  image_identity_invalidate
  image_identity_present_on_node "$1"
}

listing_is_truncated() { image_identity_listing_is_truncated; }

# verify_images MODE   — MODE is `identity` (default) or `presence`.
#
# Exit: 0 PASS, 1 FAIL, 3 COULD-NOT-VERIFY. Three outcomes, never two — see
# scripts/supercred-images.sh's verify_images for why an unanswerable question
# gets its own answer rather than being folded into either neighbour.
verify_images() {
  local mode="${1:-identity}"
  local entry image rc failed=() unverified=()

  # One sample of the node for the whole set.
  image_identity_invalidate
  image_identity_read_node || true

  for entry in "${SIGNALFUSION_IMAGES[@]}"; do
    image="$(image_name "$entry")"
    rc=0; image_identity_verify "$image" || rc=$?

    if [ "$mode" = "presence" ] && [ "$IMAGE_IDENTITY_PRESENT" = "yes" ]; then
      ok "$image present on $NODE (presence only — identity not checked)"
      continue
    fi

    case "$rc" in
      0) ok   "PASS  $IMAGE_IDENTITY_DETAIL" ;;
      2) warn "COULD-NOT-VERIFY  $IMAGE_IDENTITY_DETAIL"; unverified+=("$image") ;;
      *) warn "FAIL  $IMAGE_IDENTITY_DETAIL";             failed+=("$image") ;;
    esac
  done

  if ((${#failed[@]} > 0)); then
    warn "FAIL on $NODE: ${failed[*]}"
    return 1
  fi
  if ((${#unverified[@]} > 0)); then
    warn "COULD-NOT-VERIFY on $NODE: ${unverified[*]}"
    return 3
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
  # Not sufficient — this script exists because `kind load` exits 0 having
  # transferred nothing — but not worthless either, and it used to be discarded
  # outright. A load that ANNOUNCED failure before a mismatch is a different bug
  # report from one that claimed success.
  KIND_LOAD_EXIT=0
  "$KIND_BIN" load docker-image --name "$CLUSTER_NAME" "${names[@]}" || KIND_LOAD_EXIT=$?
  [ "$KIND_LOAD_EXIT" -eq 0 ] || warn "kind load exited $KIND_LOAD_EXIT"
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

  # The wait is on IDENTITY where identity is knowable: a presence poll would be
  # satisfied on its first iteration by the very stale image the recovery was
  # sent to replace.
  local waited=0 rc
  while [ "$waited" -lt "${SIGNALFUSION_CRI_ADOPT_TIMEOUT:-90}" ]; do
    image_identity_invalidate
    rc=0; image_identity_verify "$image" || rc=$?
    [ "$rc" -eq 0 ] && return 0
    [ "$rc" -eq 2 ] && [ "$IMAGE_IDENTITY_PRESENT" = "yes" ] && return 0
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

  local entry image context dockerfile recovered=0 rc
  for entry in "${SIGNALFUSION_IMAGES[@]}"; do
    image="$(image_name "$entry")"
    context="$(image_context "$entry")"
    dockerfile="$(image_dockerfile "$entry")"

    image_identity_invalidate
    rc=0; image_identity_verify "$image" || rc=$?
    [ "$rc" -eq 0 ] && continue

    # A MISMATCH is never recovered from. Re-importing the right image and then
    # reporting success leaves the loader that dropped the transfer in place —
    # which is exactly how the 2026-08-17 defect stayed invisible. Verify and
    # fail; verify_images below turns this into a non-zero exit with both IDs.
    if [ "$IMAGE_IDENTITY_OUTCOME" = "MISMATCH" ]; then
      warn "$image on $NODE is a DIFFERENT image from the local build — NOT recovering"
      continue
    fi
    # Likewise for a question the data cannot answer.
    [ "$rc" -eq 2 ] && continue

    warn "$image did not reach $NODE via kind load (exit ${KIND_LOAD_EXIT:-0}) — attempting recovery"
    reload_via_archive "$image" "$context" "$dockerfile" || true
    recovered=1
  done
  [ "$recovered" -eq 1 ] && log "recovery attempted; re-verifying"

  rc=0; verify_images identity || rc=$?
  case "$rc" in
    3)
      warn "COULD-NOT-VERIFY — $NODE's listing cannot answer whether these images are
       the ones just built. Neither a pass nor a failure; no claim is being made
       about what is running.
       Inspect with:
         docker exec $NODE crictl images --no-trunc"
      exit 3
      ;;
    0) : ;;
    *)
      fail "Signal Fusion images on $NODE are absent, or are NOT the image just
       built locally.
       Nothing has been repaired. A gate that reloads on a mismatch and then
       reports success hides the broken loader — which is how a stale binary ran
       under a green pipeline on 2026-08-17.
       Inspect with:
         docker image inspect --format '{{.Id}}' signal-ingest:local
         docker exec $NODE crictl images --no-trunc
         docker exec $NODE ctr -n k8s.io images ls
       Then retry:  make demo-signalloom-signalfusion-images"
      ;;
  esac
  ok "PASS — all Signal Fusion images on $NODE are the images just built locally"
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
      3) warn "COULD-NOT-VERIFY — $NODE's image listing cannot answer. Not a pass and
       not a failure; a genuinely absent image surfaces as ErrImageNeverPull."
         exit 3 ;;
      *) fail "Signal Fusion images are not all present on $NODE — run: make demo-signalloom-signalfusion-images" ;;
    esac
    ;;
  # IDENTITY, for callers that hold the local images and need to know the node
  # is running what this checkout builds.
  verify-identity)
    verify_images identity || VERIFY_RC=$?
    case "$VERIFY_RC" in
      0) ;;
      3) exit 3 ;;
      *) fail "Signal Fusion images on $NODE are not the images this checkout builds — run: make demo-signalloom-signalfusion-images" ;;
    esac
    ;;
  *)
    echo "Usage: $0 {build|load|verify|verify-identity}" >&2
    exit 1
    ;;
esac
