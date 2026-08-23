#!/usr/bin/env bash
# shellcheck shell=bash
# demo-images.sh — shared build/load/verify logic for kind-loaded demo images.
#
# Both signalfusion-images.sh and supercred-images.sh do the same job for
# different image sets. This library holds the common code so a fix to one is
# a fix to both, and defences cannot diverge.
#
# ─── Contract ──────────────────────────────────────────────────────────────
#
# The sourcing script MUST set these before calling any function:
#
#   DEMO_IMAGES        — indexed array of "name:tag|context|dockerfile" entries
#   DEMO_LOG_PREFIX    — string for log output, e.g. "signalfusion-images"
#   DEMO_NODE          — kind node name
#   DEMO_CRI_ADOPT_TIMEOUT — seconds to wait for CRI adoption (optional,
#                             defaults to IMAGE_IDENTITY_ADOPT_CHECKS or 300)
#   PLATFORM           — docker platform string, e.g. "linux/amd64"
#   REPO_ROOT          — absolute path to repository root
#   DOCKER_BIN         — docker binary (default: docker)
#   KIND_BIN           — kind binary (default: kind)
#   CLUSTER_NAME       — kind cluster name (default: osramp)
#
# The sourcing script MUST have already sourced:
#   scripts/lib/source-id.sh
#   scripts/lib/image-identity.sh

# ─── Logging ───────────────────────────────────────────────────────────────

demo_log()  { printf '\033[1;36m[%s]\033[0m %s\n' "$DEMO_LOG_PREFIX" "$*"; }
demo_ok()   { printf '\033[1;32m[%s] ✓\033[0m %s\n' "$DEMO_LOG_PREFIX" "$*"; }
demo_warn() { printf '\033[1;33m[%s] !\033[0m %s\n' "$DEMO_LOG_PREFIX" "$*" >&2; }
demo_fail() { printf '\033[1;31m[%s] FAILED:\033[0m %s\n' "$DEMO_LOG_PREFIX" "$*" >&2; exit 1; }

# ─── Image entry parsing ──────────────────────────────────────────────────

demo_image_name() {
  local image context dockerfile
  IFS='|' read -r image context dockerfile <<<"$1"
  printf '%s' "$image"
}

demo_image_context() {
  local image context dockerfile
  IFS='|' read -r image context dockerfile <<<"$1"
  printf '%s' "$context"
}

demo_image_dockerfile() {
  local image context dockerfile
  IFS='|' read -r image context dockerfile <<<"$1"
  printf '%s' "$dockerfile"
}

# ─── Platform ──────────────────────────────────────────────────────────────

# kind nodes run the host architecture; pin it explicitly so a multi-arch base
# image cannot resolve to a platform the node cannot execute.
demo_host_platform() {
  case "$(uname -m)" in
    x86_64|amd64)  printf 'linux/amd64' ;;
    aarch64|arm64) printf 'linux/arm64' ;;
    *)             printf 'linux/amd64' ;;
  esac
}

# ─── Verification ──────────────────────────────────────────────────────────

# True when the CRI can actually run *an* image under this tag. Deliberately NOT
# `ctr images ls`. See supercred-images.sh's header for the full explanation.
#
# Presence only — it says nothing about WHICH image.
demo_image_on_node() {
  image_identity_invalidate
  image_identity_present_on_node "$1"
}

demo_listing_is_truncated() { image_identity_listing_is_truncated; }

# demo_verify_images MODE   — MODE is `identity` (default) or `presence`.
#
# Exit: 0 PASS, 1 FAIL, 3 COULD-NOT-VERIFY. Three outcomes, never two.
#
# Do not fail closed on a listing that cannot answer the question. On 2026-08-03
# this gate blocked the entire demo with "images are not all present" against a
# node whose own `crictl images` listed every one of them: the runner's shim
# reads node.status.images, which was capped at 50 and size-sorted, so small
# images were missing from the DATA, not from the node.
#
# The obvious correction — treat a truncated miss as a pass — is the OTHER
# defect. On 2026-08-17 a gate that could not tell a fresh image from a stale
# one assumed fresh and shipped stale. Both directions have now cost a day.
#
# So an unanswerable question gets its own answer. The CALLER decides policy.
demo_verify_images() {
  local mode="${1:-identity}"
  local entry image rc failed=() unverified=()

  # One sample of the node for the whole set. Re-reading per image is two
  # samples of a changing system, which between them can describe a node that
  # never existed.
  image_identity_invalidate
  image_identity_read_node || true

  for entry in "${DEMO_IMAGES[@]}"; do
    image="$(demo_image_name "$entry")"
    rc=0; image_identity_verify "$image" || rc=$?

    # Presence mode answers the weaker question and says so. It is what the
    # demo runner asks, and it must not be silently reported as an identity
    # check that passed.
    if [ "$mode" = "presence" ] && [ "$IMAGE_IDENTITY_PRESENT" = "yes" ]; then
      demo_ok "$image present on $DEMO_NODE (presence only — identity not checked)"
      continue
    fi

    case "$rc" in
      0) demo_ok   "PASS  $IMAGE_IDENTITY_DETAIL" ;;
      2) demo_warn "COULD-NOT-VERIFY  $IMAGE_IDENTITY_DETAIL"; unverified+=("$image") ;;
      *) demo_warn "FAIL  $IMAGE_IDENTITY_DETAIL";             failed+=("$image") ;;
    esac
  done

  if ((${#failed[@]} > 0)); then
    demo_warn "FAIL on $DEMO_NODE: ${failed[*]}"
    return 1
  fi
  if ((${#unverified[@]} > 0)); then
    demo_warn "COULD-NOT-VERIFY on $DEMO_NODE: ${unverified[*]}"
    return 3
  fi
  return 0
}

# ─── Build ─────────────────────────────────────────────────────────────────

# Build args that bake a build identity into images which declare the ARGs, so
# scripts/check-deployed-staleness.sh can later read that identity back out of
# the running container and prove the pod is running this source tree.
#
# Empty for images with no marker: passing --build-arg for an ARG a Dockerfile
# never declares is a warning on every build, and noise at build time is how
# real warnings stop being read.
demo_build_id_args() {
  local image="$1" args=()
  mapfile -t args < <(source_id_build_args "${image%%:*}" 2>/dev/null) || return 0
  # Return with NO output when there are no args, rather than falling through to
  # printf. `printf '%s\n'` runs its format once even with zero arguments, so an
  # image with no marker emitted a single blank line here; mapfile in the caller
  # turned that into a one-element array holding "", and docker received an empty
  # positional argument alongside the build context:
  #
  #   docker: 'docker build' requires 1 argument     (it had been handed two)
  #
  # Every image failed to build.
  ((${#args[@]})) || return 0
  printf '%s\n' "${args[@]}"
}

demo_build_images() {
  local entry image context dockerfile id_args
  # TARGETARCH is one of BuildKit's AUTOMATIC build args — it is populated by
  # the builder, not by the Dockerfile, and the LEGACY builder does not populate
  # it at all. The runner's Dockerfile selects its kubectl checksum on it:
  #
  #   Unsupported TARGETARCH for kubectl:            <- empty, and it exits 1
  #
  # So the build silently depended on the caller having buildx. Docker resolves
  # the buildx plugin through ~/.docker/config.json, and any environment where
  # that file is unreadable falls back to the legacy builder and hits this —
  # a confusing failure four steps into a build, blamed on the Dockerfile.
  # Passing it explicitly costs nothing under BuildKit (same value, stated
  # rather than inferred) and is the difference between working and not without.
  local target_arch="${PLATFORM##*/}"
  for entry in "${DEMO_IMAGES[@]}"; do
    image="$(demo_image_name "$entry")"
    context="$(demo_image_context "$entry")"
    dockerfile="$(demo_image_dockerfile "$entry")"
    mapfile -t id_args < <(demo_build_id_args "$image")
    demo_log "building $image ($PLATFORM)"
    if [ -n "$dockerfile" ]; then
      "$DOCKER_BIN" build --platform "$PLATFORM" --build-arg "TARGETARCH=${target_arch}" ${id_args[@]+"${id_args[@]}"} -f "$REPO_ROOT/$dockerfile" -t "$image" "$REPO_ROOT/$context" \
        || demo_fail "docker build failed for $image via $dockerfile"
    else
      "$DOCKER_BIN" build --platform "$PLATFORM" --build-arg "TARGETARCH=${target_arch}" ${id_args[@]+"${id_args[@]}"} -t "$image" "$REPO_ROOT/$context" \
        || demo_fail "docker build failed for $image"
    fi
  done
  demo_ok "built ${#DEMO_IMAGES[@]} image(s)"
}

# ─── Load ──────────────────────────────────────────────────────────────────

demo_kind_load_all() {
  local entry names=()
  for entry in "${DEMO_IMAGES[@]}"; do names+=("$(demo_image_name "$entry")"); done
  demo_log "loading into kind cluster $CLUSTER_NAME: ${names[*]}"
  # Exit status is not SUFFICIENT here — this script exists because `kind load`
  # exits 0 having transferred nothing — but it is not worthless either. A load
  # that ANNOUNCED failure before a mismatch is a different bug report from one
  # that claimed success. Recorded, and reported by the caller; the identity
  # check below is still what decides.
  KIND_LOAD_EXIT=0
  "$KIND_BIN" load docker-image --name "$CLUSTER_NAME" "${names[@]}" || KIND_LOAD_EXIT=$?
  [ "$KIND_LOAD_EXIT" -eq 0 ] || demo_warn "kind load exited $KIND_LOAD_EXIT"
}

# Rebuild straight into a docker-archive tarball and import that.
#
# This is the recovery path for an image `kind load` silently declines to
# transfer. It never round-trips through the local docker image store, so a
# layer that was only lazily materialised there cannot be the missing blob:
# `--output type=docker,dest=…` forces BuildKit to write every layer into the
# archive before the command returns.
demo_reload_via_archive() {
  local image="$1" context="$2" dockerfile="${3:-}"

  # Label-first, before the rebuild below. On 2026-08-18 the content store held
  # images the CRI could not see — ctr=102 against crictl=40, disk 9%. The
  # recovery that worked reported `Importing … total: 0.0 B`: the bytes were
  # never missing, only the io.cri-containerd.image=managed label was.
  #
  # This path is more expensive than kind-load-verified.sh's — it REBUILDS the
  # image — so the saving is larger and the reason to try the cheap action first
  # is stronger. It cannot mask anything: image_identity_adopt_if_present
  # returns 0 only when image_identity_verify proves identity afterwards, so a
  # failed adoption falls through to the rebuild rather than reporting success.
  if image_identity_adopt_if_present "$image" "${DEMO_CRI_ADOPT_TIMEOUT:-${IMAGE_IDENTITY_ADOPT_CHECKS:-300}}"; then
    demo_log "recovery: content was already on $DEMO_NODE — labelled it CRI-managed, no rebuild needed"
    return 0
  fi

  local tar
  tar="$(mktemp -t "demo-${image%%:*}-XXXXXX.tar")"
  # shellcheck disable=SC2064  # expand $tar now, not at trap time
  trap "rm -f '$tar'" RETURN

  demo_log "recovery: rebuilding $image directly into an archive"
  if [ -n "$dockerfile" ]; then
    "$DOCKER_BIN" buildx build \
      --platform "$PLATFORM" \
      --provenance=false --sbom=false \
      --output "type=docker,dest=$tar" \
      -f "$REPO_ROOT/$dockerfile" \
      -t "$image" "$REPO_ROOT/$context" \
      || { demo_warn "buildx archive build failed for $image via $dockerfile"; return 1; }
  else
    "$DOCKER_BIN" buildx build \
      --platform "$PLATFORM" \
      --provenance=false --sbom=false \
      --output "type=docker,dest=$tar" \
      -t "$image" "$REPO_ROOT/$context" \
      || { demo_warn "buildx archive build failed for $image"; return 1; }
  fi

  demo_log "recovery: importing $image into containerd on $DEMO_NODE"
  # `kind load` can leave the requested tag pointing at an incomplete HTML
  # manifest. Importing under that occupied reference reports success but keeps
  # the poisoned target, so CRI cannot adopt the recovered archive. Remove only
  # the known-unrunnable reference immediately before its replacement.
  "$DOCKER_BIN" exec "$DEMO_NODE" \
    ctr -n k8s.io images rm "docker.io/library/${image%%:*}:${image##*:}" >/dev/null 2>&1 \
    || true
  # --snapshotter=overlayfs so the layers are unpacked into the snapshotter the
  # CRI actually reads. Without it the import succeeds and the image is not
  # runnable.
  "$DOCKER_BIN" exec -i "$DEMO_NODE" \
    ctr -n k8s.io images import --all-platforms --snapshotter=overlayfs - <"$tar" \
    || { demo_warn "ctr import failed for $image"; return 1; }

  # Load-bearing, and the reason this recovery path had never once worked.
  #
  # containerd's CRI plugin only surfaces images carrying this label. An
  # imported-but-unlabelled image sits in the content store, is listed by
  # `ctr images ls`, is NOT listed by `crictl images`, and cannot be run.
  "$DOCKER_BIN" exec "$DEMO_NODE" \
    ctr -n k8s.io images label "docker.io/library/${image%%:*}:${image##*:}" \
      io.cri-containerd.image=managed >/dev/null \
    || { demo_warn "could not label $image as CRI-managed"; return 1; }

  # The CRI does not adopt the freshly-labelled image synchronously. A recovery
  # that worked and was then declared a failure is worse than one that plainly
  # did not work, because it sends the reader looking in the wrong place.
  #
  # The wait is on IDENTITY where identity is knowable. A recovery re-importing
  # the right image onto a node still holding the wrong one would otherwise
  # satisfy a presence poll on its very first iteration — against the stale
  # image it was sent to replace.
  local waited=0 rc
  while [ "$waited" -lt "${DEMO_CRI_ADOPT_TIMEOUT:-${IMAGE_IDENTITY_ADOPT_CHECKS:-300}}" ]; do
    image_identity_invalidate
    rc=0; image_identity_verify "$image" || rc=$?
    [ "$rc" -eq 0 ] && return 0
    # No local image to compare against is not something waiting will fix, and
    # presence is then the strongest answer available.
    [ "$rc" -eq 2 ] && [ "$IMAGE_IDENTITY_PRESENT" = "yes" ] && return 0
    sleep 1
    waited=$((waited + 1))
  done

  # Say which of the two states we are actually in.
  if "$DOCKER_BIN" exec "$DEMO_NODE" ctr -n k8s.io images ls -q 2>/dev/null \
      | grep -Fqx "docker.io/library/${image%%:*}:${image##*:}"; then
    demo_warn "$image is in the content store and labelled, but the CRI has not adopted it after ${waited}s — slow unpack, not a failed import; re-run"
  else
    demo_warn "$image is not in the content store after ${waited}s — the import itself failed"
  fi
  return 1
}

demo_load_images() {
  demo_kind_load_all

  local entry image context dockerfile recovered=0 rc
  for entry in "${DEMO_IMAGES[@]}"; do
    image="$(demo_image_name "$entry")"
    context="$(demo_image_context "$entry")"
    dockerfile="$(demo_image_dockerfile "$entry")"

    image_identity_invalidate
    rc=0; image_identity_verify "$image" || rc=$?
    [ "$rc" -eq 0 ] && continue

    # A MISMATCH is never recovered from. The node holds a DIFFERENT image under
    # this tag; re-importing the right one and then reporting success leaves the
    # loader that dropped the transfer in place, which is exactly how the
    # 2026-08-17 defect stayed invisible. Verify and fail — verify_images below
    # is what turns this into a non-zero exit, with both IDs printed.
    if [ "$IMAGE_IDENTITY_OUTCOME" = "MISMATCH" ]; then
      demo_warn "$image on $DEMO_NODE is a DIFFERENT image from the local build — NOT recovering"
      continue
    fi
    # Likewise for a question the data cannot answer: recovery on a guess would
    # churn the node and prove nothing.
    [ "$rc" -eq 2 ] && continue

    demo_warn "$image did not reach $DEMO_NODE via kind load (exit ${KIND_LOAD_EXIT:-0}) — attempting recovery"
    demo_reload_via_archive "$image" "$context" "$dockerfile" || true
    recovered=1
  done
  [ "$recovered" -eq 1 ] && demo_log "recovery attempted; re-verifying"

  rc=0; demo_verify_images identity || rc=$?
  case "$rc" in
    3)
      demo_warn "COULD-NOT-VERIFY — the node's listing cannot answer whether these images
       are the ones just built. This is neither a pass nor a failure; no claim is
       being made about what is running.
       Inspect with:
         docker exec $DEMO_NODE crictl images --no-trunc"
      exit 3
      ;;
    0) : ;;
    *)
      demo_fail "one or more images on $DEMO_NODE are absent, or are NOT the image just
       built locally.
       Nothing has been repaired. A gate that reloads on a mismatch and then
       reports success hides the broken loader — which is how a stale binary ran
       under a green pipeline on 2026-08-17.
       Do NOT compare docker's .Id against the crictl IMAGE ID column. On the
       containerd image store those are different KINDS of digest — manifest
       versus config — so they never match, for correct images or wrong ones.
       Identity is the rootfs diffID list. See scripts/lib/image-identity.sh.
       Inspect with — these compare the axis that IS comparable:
         docker image inspect --format '{{range .RootFS.Layers}}{{println .}}{{end}}' IMAGE
         docker exec $DEMO_NODE crictl inspecti IMAGE | jq -r '.info.imageSpec.rootfs.diff_ids[]'
       And for presence only, which is a different question:
         docker exec $DEMO_NODE crictl images"
      ;;
  esac
}
