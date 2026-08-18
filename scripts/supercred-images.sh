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
NODE="${SUPERCRED_NODE:-${CLUSTER_NAME}-control-plane}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/source-id.sh
source "${REPO_ROOT}/scripts/lib/source-id.sh"
# shellcheck source=scripts/lib/image-identity.sh
source "${REPO_ROOT}/scripts/lib/image-identity.sh"

# image-name|build-context|dockerfile (fields after image-name are repo-root
# relative; dockerfile is optional and defaults to <context>/Dockerfile)
SUPERCRED_IMAGES=(
  "cardvault:local|d2-signalloom/apps/cardvault|"
  "policy-engine:local|d2-signalloom/apps/policy-engine|"
  "cardvault-agent:local|d2-signalloom/apps/cardvault-agent|"
  # Deliberately verify the runner alongside the other SuperCred images. That
  # is stricter than the host-side CLI path alone requires, but omitting it
  # would let the shared preflight pass while the dashboard-driven entrypoint
  # was still undeployed or stale.
  "supercred-demo-runner:local|.|d2-signalloom/apps/supercred-demo-runner/Dockerfile"
)

log()  { printf '\033[1;36m[supercred-images]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[supercred-images] ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[supercred-images] !\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m[supercred-images] FAILED:\033[0m %s\n' "$*" >&2; exit 1; }

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
PLATFORM="${SUPERCRED_PLATFORM:-$(host_platform)}"

# ─── Verification ───────────────────────────────────────────────────────────

# True when the CRI can actually run the image. Deliberately NOT `ctr images ls`.
#
# The match is done inside a single awk that reads the listing to EOF, rather
# than piping awk into `grep -Fqx`. `grep -q` exits the instant it matches,
# which closes the pipe and kills the upstream `docker exec`/`awk` with SIGPIPE
# (141). Under this script's `set -o pipefail` that 141 becomes the exit status
# of the whole pipeline -- so image_on_node returned FAILURE for an image that
# was present, and returned it *more reliably the more images the node had*,
# because a longer listing loses the race every time. That inverted the entire
# preflight: preflight_images failed closed on a healthy cluster and blocked
# steps 1, 2, 4 and `all` with "images missing", while `crictl images` plainly
# listed all three. awk as the final stage has no early exit, so there is no
# SIGPIPE and its own status is the pipeline's status.
image_on_node() {
  image_identity_invalidate
  image_identity_present_on_node "$1"
}

# True when the listing we just read is known to be incomplete, in which case a
# miss proves nothing. The in-cluster shim emits this warning on stderr when
# node.status.images is at the kubelet's --node-status-max-images cap; that
# list is sorted by size, so small images fall off the end while sitting
# perfectly happily on the node.
listing_is_truncated() { image_identity_listing_is_truncated; }

# verify_images MODE   — MODE is `identity` (default) or `presence`.
#
# Exit: 0 PASS, 1 FAIL, 3 COULD-NOT-VERIFY. Three outcomes, never two.
#
# ─── Why three, and why 3 is not folded into either neighbour ───────────────
#
# Do not fail closed on a listing that cannot answer the question.
#
# On 2026-08-03 this gate blocked the entire demo with "images are not all
# present" against a node whose own `crictl images` listed every one of them:
# the runner's shim reads node.status.images, which was capped at 50 and
# size-sorted, so cardvault:local (8.9MB) and policy-engine:local (14.9MB) were
# missing from the DATA, not from the node.
#
# The obvious correction — treat a truncated miss as a pass — is the OTHER
# defect. On 2026-08-17 a gate that could not tell a fresh image from a stale
# one assumed fresh and shipped stale. Both directions have now cost a day.
#
# So an unanswerable question gets its own answer. 3 mirrors
# scripts/check-node-images.sh, which uses 3 for "indeterminate" for the same
# reason. The CALLER decides policy and must say which of the three it got:
# scripts/supercred-demo.sh's preflight deliberately continues on 3, because a
# genuinely absent image does not go unnoticed there — the pods run
# imagePullPolicy: Never, so it surfaces immediately and unmistakably as
# ErrImageNeverPull on the workload itself, which is a far better error than a
# preflight guess. That is a decision made in the open, not a gate lying.
verify_images() {
  local mode="${1:-identity}"
  local entry image rc failed=() unverified=()

  # One sample of the node for the whole set. Re-reading per image is two
  # samples of a changing system, which between them can describe a node that
  # never existed.
  image_identity_invalidate
  image_identity_read_node || true

  for entry in "${SUPERCRED_IMAGES[@]}"; do
    image="$(image_name "$entry")"
    rc=0; image_identity_verify "$image" || rc=$?

    # Presence mode answers the weaker question and says so. It is what the
    # demo runner asks, and it must not be silently reported as an identity
    # check that passed.
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

# Build args that bake a build identity into images which declare the ARGs, so
# scripts/check-deployed-staleness.sh can later read that identity back out of
# the running container and prove the pod is running this source tree.
#
# Empty for images with no marker: passing --build-arg for an ARG a Dockerfile
# never declares is a warning on every build, and noise at build time is how
# real warnings stop being read.
build_id_args() {
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
  # Every SuperCred image failed to build, starting at cardvault:local.
  ((${#args[@]})) || return 0
  printf '%s\n' "${args[@]}"
}

build_images() {
  local entry image context dockerfile id_args
  # TARGETARCH is one of BuildKit's AUTOMATIC build args -- it is populated by
  # the builder, not by the Dockerfile, and the LEGACY builder does not populate
  # it at all. The runner's Dockerfile selects its kubectl checksum on it:
  #
  #   Unsupported TARGETARCH for kubectl:            <- empty, and it exits 1
  #
  # So the build silently depended on the caller having buildx. Docker resolves
  # the buildx plugin through ~/.docker/config.json, and any environment where
  # that file is unreadable falls back to the legacy builder and hits this --
  # a confusing failure four steps into a build, blamed on the Dockerfile.
  # Passing it explicitly costs nothing under BuildKit (same value, stated
  # rather than inferred) and is the difference between working and not without.
  local target_arch="${PLATFORM##*/}"
  for entry in "${SUPERCRED_IMAGES[@]}"; do
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
  ok "built ${#SUPERCRED_IMAGES[@]} images"
}

# ─── Load ───────────────────────────────────────────────────────────────────

kind_load_all() {
  local entry names=()
  for entry in "${SUPERCRED_IMAGES[@]}"; do names+=("$(image_name "$entry")"); done
  log "loading into kind cluster $CLUSTER_NAME: ${names[*]}"
  # Exit status is not SUFFICIENT here — this script exists because `kind load`
  # exits 0 having transferred nothing — but it is not worthless either, and it
  # used to be thrown away entirely. A load that ANNOUNCED failure before a
  # mismatch is a different bug report from one that claimed success, and only
  # one of the two is the silent-no-op defect. Recorded, and reported by the
  # caller; the identity check below is still what decides.
  KIND_LOAD_EXIT=0
  "$KIND_BIN" load docker-image --name "$CLUSTER_NAME" "${names[@]}" || KIND_LOAD_EXIT=$?
  [ "$KIND_LOAD_EXIT" -eq 0 ] || warn "kind load exited $KIND_LOAD_EXIT"
}

# Rebuild straight into a docker-archive tarball and import that.
#
# This is the recovery path for an image `kind load` silently declines to
# transfer. It never round-trips through the local docker image store, so a
# layer that was only lazily materialised there cannot be the missing blob:
# `--output type=docker,dest=…` forces BuildKit to write every layer into the
# archive before the command returns.
reload_via_archive() {
  local image="$1" context="$2" dockerfile="${3:-}"

  # Label-first, before the rebuild below. On 2026-08-18 a cold run aborted here
  # on supercred-demo-runner:local after 3/3 retries, while the same run's
  # diagnostics showed the content store holding images the CRI could not see —
  # ctr=102 against crictl=40 on a node at 9% disk. The recovery that worked
  # elsewhere in that run reported `Importing … total: 0.0 B`: the bytes were
  # never missing, only the io.cri-containerd.image=managed label was.
  #
  # This path is more expensive than kind-load-verified.sh's — it REBUILDS the
  # image — so the saving is larger and the reason to try the cheap action first
  # is stronger. It cannot mask anything: image_identity_adopt_if_present
  # returns 0 only when image_identity_verify proves identity afterwards, so a
  # failed adoption falls through to the rebuild rather than reporting success.
  if image_identity_adopt_if_present "$image" "${SUPERCRED_CRI_ADOPT_TIMEOUT:-90}"; then
    log "recovery: content was already on $NODE — labelled it CRI-managed, no rebuild needed"
    return 0
  fi

  local tar
  tar="$(mktemp -t "supercred-${image%%:*}-XXXXXX.tar")"
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
  # `kind load` can leave the requested tag pointing at an incomplete HTML
  # manifest. Importing under that occupied reference reports success but keeps
  # the poisoned target, so CRI cannot adopt the recovered archive. Remove only
  # the known-unrunnable reference immediately before its replacement.
  "$DOCKER_BIN" exec "$NODE" \
    ctr -n k8s.io images rm "docker.io/library/${image%%:*}:${image##*:}" >/dev/null 2>&1 \
    || true
  # --snapshotter=overlayfs so the layers are unpacked into the snapshotter the
  # CRI actually reads. Without it the import succeeds and the image is not
  # runnable.
  "$DOCKER_BIN" exec -i "$NODE" \
    ctr -n k8s.io images import --all-platforms --snapshotter=overlayfs - <"$tar" \
    || { warn "ctr import failed for $image"; return 1; }

  # Load-bearing, and the reason this recovery path had never once worked.
  #
  # containerd's CRI plugin only surfaces images carrying this label. An
  # imported-but-unlabelled image sits in the content store, is listed by
  # `ctr images ls`, is NOT listed by `crictl images`, and cannot be run — so
  # the recovery reported success, the verification that follows it failed, and
  # the whole thing read as "the archive rebuild didn't help either".
  #
  # Observed on the CI VM 2026-08-04: after recovery, `ctr images ls` listed
  # cardvault-agent:local while `crictl images` did not, and the deploy failed.
  # Adding the label made crictl list it immediately.
  "$DOCKER_BIN" exec "$NODE" \
    ctr -n k8s.io images label "docker.io/library/${image%%:*}:${image##*:}" \
      io.cri-containerd.image=managed >/dev/null \
    || { warn "could not label $image as CRI-managed"; return 1; }

  # The CRI does not adopt the freshly-labelled image synchronously, so an
  # immediate re-verify can miss it by a second or two. Observed on the CI VM
  # 2026-08-04: recovery labelled cardvault-agent:local, the caller's
  # verification reported it missing and failed the build, and `crictl images`
  # listed it moments later. A recovery that worked and was then declared a
  # failure is worse than one that plainly did not work, because it sends the
  # reader looking in the wrong place.
  # 90s, not 20s. The 20 was fitted to cardvault-agent (54MB) on 2026-08-04 and
  # is not a property of containerd — adoption follows the snapshotter unpacking
  # the layers, so it scales with image size. supercred-demo-runner is 111MB,
  # roughly twice that, and on 2026-08-13 it timed out at 20s having worked:
  # `crictl images` listed it a short time later and the pod ran from it with no
  # further intervention.
  #
  # That is precisely the failure the comment above warns about, reproduced by
  # the fix for it — the recovery succeeded and was declared a failure, and the
  # reader was sent to look at the registry (the bare `:local` tag resolves to
  # docker.io, so the kubelet's message names Docker Hub) instead of at a wait
  # that was simply too short.
  #
  # The wait is on IDENTITY where identity is knowable. A recovery re-importing
  # the right image onto a node still holding the wrong one would otherwise
  # satisfy a presence poll on its very first iteration — against the stale
  # image it was sent to replace.
  local waited=0 rc
  while [ "$waited" -lt "${SUPERCRED_CRI_ADOPT_TIMEOUT:-90}" ]; do
    image_identity_invalidate
    rc=0; image_identity_verify "$image" || rc=$?
    [ "$rc" -eq 0 ] && return 0
    # No local image to compare against is not something waiting will fix, and
    # presence is then the strongest answer available.
    [ "$rc" -eq 2 ] && [ "$IMAGE_IDENTITY_PRESENT" = "yes" ] && return 0
    sleep 1
    waited=$((waited + 1))
  done

  # Say which of the two states we are actually in. "Not adopted" with the image
  # sitting in the content store is a slow unpack and is very likely to resolve
  # on its own; "not adopted" with nothing in the content store is a genuinely
  # failed import. Collapsing those into one message is what made this cost an
  # afternoon.
  if "$DOCKER_BIN" exec "$NODE" ctr -n k8s.io images ls -q 2>/dev/null \
      | grep -Fqx "docker.io/library/${image%%:*}:${image##*:}"; then
    warn "$image is in the content store and labelled, but the CRI has not adopted it after ${waited}s — this is a slow unpack, not a failed import; re-run and it will usually be present"
  else
    warn "$image is not in the content store after ${waited}s — the import itself failed"
  fi
  return 1
}

load_images() {
  kind_load_all

  local entry image context dockerfile recovered=0 rc
  for entry in "${SUPERCRED_IMAGES[@]}"; do
    image="$(image_name "$entry")"
    context="$(image_context "$entry")"
    dockerfile="$(image_dockerfile "$entry")"

    image_identity_invalidate
    rc=0; image_identity_verify "$image" || rc=$?
    [ "$rc" -eq 0 ] && continue

    # A MISMATCH is never recovered from. The node holds a DIFFERENT image under
    # this tag; re-importing the right one and then reporting success leaves the
    # loader that dropped the transfer in place, which is exactly how the
    # 2026-08-17 defect stayed invisible. Verify and fail — verify_images below
    # is what turns this into a non-zero exit, with both IDs printed.
    if [ "$IMAGE_IDENTITY_OUTCOME" = "MISMATCH" ]; then
      warn "$image on $NODE is a DIFFERENT image from the local build — NOT recovering"
      continue
    fi
    # Likewise for a question the data cannot answer: recovery on a guess would
    # churn the node and prove nothing.
    [ "$rc" -eq 2 ] && continue

    warn "$image did not reach $NODE via kind load (exit ${KIND_LOAD_EXIT:-0}) — attempting recovery"
    reload_via_archive "$image" "$context" "$dockerfile" || true
    recovered=1
  done
  [ "$recovered" -eq 1 ] && log "recovery attempted; re-verifying"

  rc=0; verify_images identity || rc=$?
  case "$rc" in
    3)
      warn "COULD-NOT-VERIFY — the node's listing cannot answer whether these images
       are the ones just built. This is neither a pass nor a failure; no claim is
       being made about what is running.
       Inspect with:
         docker exec $NODE crictl images --no-trunc"
      exit 3
      ;;
    0) : ;;
    *)
      fail "one or more SuperCred images on $NODE are absent, or are NOT the image
       just built locally.
       Nothing has been repaired. A gate that reloads on a mismatch and then
       reports success hides the broken loader — which is how a stale binary ran
       under a green pipeline on 2026-08-17.
       'ctr images ls' can list an image whose layers never transferred, so this
       check uses 'crictl images' instead — a listed-but-unusable image is
       reported as missing here on purpose. Neither command tells you WHICH
       image.
       Do NOT answer that by comparing the IMAGE ID column against 'docker image
       inspect'. On Docker's containerd image store those are different KINDS of
       digest — docker reports the manifest/index digest, crictl the config
       digest — so they disagree for identical images and agree for none.
       Identity is the rootfs diffID list, which lives in the image config and
       so reads the same on both sides. See scripts/lib/image-identity.sh.
       Inspect with — these compare the axis that IS comparable, so their
       output can be diffed directly:
         docker image inspect --format '{{range .RootFS.Layers}}{{println .}}{{end}}' IMAGE
         docker exec $NODE crictl inspecti IMAGE | jq -r '.info.imageSpec.rootfs.diff_ids[]'
       And for presence only, which is a different question:
         docker exec $NODE crictl images
       Then retry:  make demo-signalloom-supercred-images"
      ;;
  esac
  ok "PASS — all SuperCred images on $NODE are the images just built locally"

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
      3) warn "COULD-NOT-VERIFY — $NODE's image listing cannot answer whether these
       images are present. Not a pass and not a failure. A genuinely absent
       image will surface as ErrImageNeverPull on the workload."
         exit 3 ;;
      *) fail "SuperCred images are not all present on $NODE — run: make demo-signalloom-supercred-images" ;;
    esac
    ;;
  # The strict form of `verify`, for callers that DO have the local images: is
  # what the node holds the thing this checkout builds?
  verify-identity)
    verify_images identity || VERIFY_RC=$?
    case "$VERIFY_RC" in
      0) ;;
      3) exit 3 ;;
      *) fail "SuperCred images on $NODE are not the images this checkout builds — run: make demo-signalloom-supercred-images" ;;
    esac
    ;;
  *)
    echo "Usage: $0 {build|load|verify|verify-identity}" >&2
    exit 1
    ;;
esac
