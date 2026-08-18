#!/usr/bin/env bash
# Load images onto the kind node and PROVE they arrived.
#
#   kind-load-verified.sh IMAGE [IMAGE...]
#
# ─── The defect ─────────────────────────────────────────────────────────────
#
# `kind load docker-image` can print "loading..." and exit 0 having transferred
# nothing. On a Docker daemon using the containerd image store (the default
# from Docker 25 with `containerd-snapshotter`), `docker save` emits an OCI
# index whose layers kind's importer does not always materialise on the node.
# The command succeeds. The image is not there.
#
# What that costs, in order: the pod goes ImagePullBackOff, because kubelet
# falls back to pulling `fake-integration-proxy:dev` from Docker Hub and gets
# an HTML error page —
#
#   failed to unpack image ... unexpected media type text/html for sha256:… : not found
#
# — then `inf-signalloom/infra-configs` fails its health check waiting on that
# Deployment, then `signalloom-apps` never reconciles because it depends on
# infra-configs, so `fe-signalloom` stays EMPTY and the dashboard, the API and
# the SuperCred demo runner never deploy. Stages 6, 7 and 8 of the CI pipeline
# then fail together, ~443s apart, none of them naming an image.
#
# It is invisible on a warm VM: the kind node's image cache survives between
# runs, so the second run finds the image already there and the silent failure
# never bites. It bites every cold run. Two CI runs on 2026-08-04 failed this
# way, on a branch with no related changes.
#
# ─── Why `crictl images` and not `ctr images ls` ────────────────────────────
#
# `ctr -n k8s.io images ls` STILL LISTS a half-transferred image, because the
# content store holds the manifest even when the layers never arrived. A check
# built on it passes while the pod cannot start. `crictl images` reports the
# CRI's view — unpacked, labelled and runnable — so it is the only sound
# verification. scripts/supercred-images.sh reached the same conclusion
# independently; this script generalises it to every image the build loads.
#
# ─── Recovery ───────────────────────────────────────────────────────────────
#
# `docker save` WITHOUT --platform, so the archive is an OCI index rather than
# a single-platform manifest. Measured on the CI VM: importing the
# single-platform form leaves an image that `ctr` lists and `crictl` does not,
# which is the same dead end by another route. The index form imports cleanly.
#
# Then `ctr images label io.cri-containerd.image=managed`. Without that label
# the CRI does not adopt the image and `crictl images` still will not list it,
# even though the content and the unpacked snapshot are both present. This is
# the step that actually makes a recovered image usable, and it is missing from
# the recovery path in supercred-images.sh — which is survivable there only
# because its images happen to load cleanly.
#
# ─── Presence was never the whole question ──────────────────────────────────
#
# Everything above is about an image that did not arrive. On 2026-08-17 a worse
# variant was measured on the live cluster: the image did not arrive AND the
# node was already holding an older image under the same tag, so the presence
# check above passed on the stale one and `make demo-signalloom-up` exited 0
# with the cluster running a different binary. See scripts/lib/image-identity.sh
# for the measurement. Verification is now by image ID, not by tag.
set -euo pipefail

DOCKER_BIN="${DOCKER_BIN:-docker}"
KIND_BIN="${KIND_BIN:-kind}"
CLUSTER_NAME="${CLUSTER_NAME:-osramp}"
NODE="${KIND_LOAD_NODE:-${CLUSTER_NAME}-control-plane}"

# shellcheck source=scripts/lib/image-identity.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/image-identity.sh"

log()  { printf '\033[1;36m[kind-load]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[kind-load] ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[kind-load] !\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m[kind-load] FAILED:\033[0m %s\n' "$*" >&2; exit 1; }

# How crictl prints a reference. Delegates to the shared helper so there is one
# definition of it in the repo rather than the three there used to be.
canonical_ref() { image_identity_canonical_ref "$@"; }

# True when the CRI can actually run *an* image under this tag.
#
# Presence only — it says nothing about WHICH image, which is why it is no
# longer the gate. Kept because the recovery loop below needs it as a fallback
# when the image has no local counterpart to compare against.
#
# The match runs inside a single awk that reads to EOF rather than piping into
# `grep -q`. grep exits on first match, closing the pipe and killing the
# upstream `docker exec` with SIGPIPE (141), which under `set -o pipefail`
# becomes the pipeline's status — so the check reported FAILURE for an image
# that was present, and did so more reliably the more images the node had.
# supercred-images.sh carries the same note; it is not a hypothetical.
image_on_node() {
  image_identity_invalidate
  image_identity_present_on_node "$1"
}

# The gate. Reports PASS / FAIL / COULD-NOT-VERIFY for one image and returns
# 0 / 1 / 2 to match. Never repairs: a mismatch is reported, not reloaded.
verify_identity() {
  local image="$1" rc=0
  image_identity_invalidate
  image_identity_verify "$image" || rc=$?
  case "$rc" in
    0) ok   "PASS  $IMAGE_IDENTITY_DETAIL" ;;
    2) warn "COULD-NOT-VERIFY  $IMAGE_IDENTITY_DETAIL" ;;
    *) warn "FAIL  $IMAGE_IDENTITY_DETAIL" ;;
  esac
  return "$rc"
}

# Re-import an image the loader declined to transfer. See the header for why
# each flag is what it is.
recover_via_archive() {
  local image="$1"
  local safe tar
  safe="$(printf '%s' "$image" | tr -c 'A-Za-z0-9._-' '_')"
  tar="$(mktemp -t "kind-load-${safe}-XXXXXX.tar")"
  # shellcheck disable=SC2064  # expand $tar now, not at trap time
  trap "rm -f '$tar'" RETURN

  log "recovery: exporting $image as an OCI index"
  "$DOCKER_BIN" save -o "$tar" "$image" \
    || { warn "docker save failed for $image"; return 1; }

  log "recovery: importing $image into containerd on $NODE"
  "$DOCKER_BIN" exec -i "$NODE" \
    ctr -n k8s.io images import --all-platforms --digests --snapshotter=overlayfs - <"$tar" \
    || { warn "ctr import failed for $image"; return 1; }

  # The label is load-bearing, not tidiness — see the header.
  "$DOCKER_BIN" exec "$NODE" \
    ctr -n k8s.io images label "$(canonical_ref "$image")" io.cri-containerd.image=managed >/dev/null \
    || { warn "could not label $image as CRI-managed"; return 1; }

  # Adoption is not synchronous. Measured on the CI VM 2026-08-04: a labelled
  # image was reported missing by an immediate re-verify and appeared in
  # `crictl images` moments later — a recovery that worked, declared a failure.
  #
  # The wait is on IDENTITY, not presence. A recovery that re-imports the right
  # image onto a node still holding the wrong one would otherwise satisfy a
  # presence poll on the very first iteration — against the stale image it was
  # sent to replace.
  local waited=0 rc
  while [ "$waited" -lt "${KIND_LOAD_CRI_ADOPT_TIMEOUT:-20}" ]; do
    image_identity_invalidate
    rc=0; image_identity_verify "$image" || rc=$?
    [ "$rc" -eq 0 ] && return 0
    # No local image to compare against is not something waiting will fix, and
    # presence is then the strongest answer available.
    [ "$rc" -eq 2 ] && [ "$IMAGE_IDENTITY_PRESENT" = "yes" ] && return 0
    sleep 1
    waited=$((waited + 1))
  done
  warn "$image is labelled but the CRI has not adopted the recovered image after ${waited}s"
  return 1
}

main() {
  [ "$#" -gt 0 ] || fail "usage: kind-load-verified.sh IMAGE [IMAGE...]"

  # Record what the local daemon holds BEFORE the load. On a mismatch this is
  # the only way to say whether the loader dropped the transfer or the build
  # never produced what the caller thinks it did.
  # The ID is logged as a breadcrumb only. Identity is the rootfs diffID list —
  # on the containerd image store this ID is the manifest digest and is NOT
  # comparable to anything crictl prints, so the layer count is the number that
  # actually corresponds to what gets compared below.
  local image local_id local_diffids
  for image in "$@"; do
    local_id="$(image_identity_local_id "$image")"
    local_diffids="$(image_identity_local_diffids "$image")"
    log "local  $image  ${local_id:+sha256:}${local_id:-<not in the local image store>}${local_diffids:+  ($(printf '%s' "$local_diffids" | grep -c .) rootfs layers)}"
  done

  # One kind invocation for the whole set: it is faster, and it is the call the
  # Makefile used to make directly, so the happy path is unchanged.
  #
  # Its exit status is captured rather than discarded. It is not sufficient —
  # this whole script exists because `kind load` exits 0 having transferred
  # nothing — but it is not worthless either, and a load that ANNOUNCED failure
  # before a mismatch is a different bug report from one that claimed success.
  log "loading into kind cluster $CLUSTER_NAME: $*"
  local kind_status=0
  "$KIND_BIN" load docker-image --name "$CLUSTER_NAME" "$@" || kind_status=$?
  if [ "$kind_status" -ne 0 ]; then
    warn "kind load exited $kind_status — verifying each image anyway"
  fi

  local broken=() unverified=() rc
  for image in "$@"; do
    rc=0; verify_identity "$image" || rc=$?
    case "$rc" in
      0) continue ;;
      2) unverified+=("$image"); continue ;;
    esac

    # A MISMATCH is never recovered from here. The node is holding a DIFFERENT
    # image under this tag; silently re-importing the right one and then
    # reporting success is precisely how the 2026-08-17 defect stayed invisible
    # for as long as it did — the gate would go green and the loader that
    # dropped the transfer would stay broken. Verify and fail.
    if [ "$IMAGE_IDENTITY_OUTCOME" = "MISMATCH" ]; then
      broken+=("$image")
      continue
    fi

    warn "$image did NOT reach $NODE despite kind load exiting $kind_status — recovering"
    rc=0; recover_via_archive "$image" || rc=$?
    if [ "$rc" -eq 0 ]; then
      rc=0; verify_identity "$image" || rc=$?
      case "$rc" in
        0) ok "$image on $NODE via archive recovery" ; continue ;;
        2) unverified+=("$image") ; continue ;;
      esac
    fi
    broken+=("$image")
  done

  if [ "${#broken[@]}" -gt 0 ]; then
    # Name the consequence, not just the fact. A bare "image missing" here has
    # historically been read as a build problem and sent people to the wrong
    # place; the failure surfaces three layers away as an unrelated Flux
    # timeout.
    printf '\n' >&2
    fail "$(cat <<EOF
FAIL — these images on $NODE are absent, or are NOT the image built locally:
  ${broken[*]}

  Nothing has been repaired. A gate that reloads and then reports success hides
  the broken loader, which is how a stale binary ran under a green pipeline on
  2026-08-17.

  'ctr images ls' may still list them — it reads the content store, which holds
  the manifest even when no layers arrived. 'crictl images' is the CRI's view
  and is what kubelet can actually run. Neither can tell you WHICH image.

  Do NOT answer that by comparing the IMAGE ID column against 'docker image
  inspect'. On Docker's containerd image store those are different KINDS of
  digest — docker reports the manifest/index digest, crictl the config digest —
  so they disagree for identical images and agree for none. That comparison is
  the defect that aborted CI in build-images with 0 stages run. 'ctr' agreeing
  with docker is not a counter-argument: ctr reads the content store, so it
  agrees about bytes the CRI never adopted.

  Identity is the rootfs diffID list, which lives in the image config and so
  reads the same on both sides. See scripts/lib/image-identity.sh.

  Left unfixed, the pods enter ImagePullBackOff, inf-signalloom/infra-configs
  fails its health check, signalloom-apps never reconciles, and fe-signalloom
  stays empty — which surfaces as a Flux convergence timeout naming no image.
  Or, worse and silently, the pods keep running the PREVIOUS build:
  imagePullPolicy IfNotPresent on a mutable :local tag never re-pulls.

  Inspect with — these compare the two sides on the axis that is actually
  comparable, so their output can be diffed directly:
    docker image inspect --format '{{range .RootFS.Layers}}{{println .}}{{end}}' ${broken[0]}
    docker exec $NODE crictl inspecti ${broken[0]} | jq -r '.info.imageSpec.rootfs.diff_ids[]'

  And for presence only, which is a different question:
    docker exec $NODE crictl images

  Then reload and re-run this script:
    kind load docker-image --name $CLUSTER_NAME ${broken[*]}
EOF
)"
  fi

  if [ "${#unverified[@]}" -gt 0 ]; then
    # The third outcome. Not a pass: nothing was proven. Not a fail: nothing was
    # disproven either. Exit 3 mirrors scripts/check-node-images.sh, which uses
    # 3 for "indeterminate" for the same reason.
    printf '\n' >&2
    warn "COULD-NOT-VERIFY — identity unproven for: ${unverified[*]}"
    warn "$IMAGE_IDENTITY_DETAIL"
    warn "This is neither a pass nor a failure. The node's listing could not answer"
    warn "the question, so no claim is made about what is running."
    warn "Inspect with:  docker exec $NODE crictl images --no-trunc"
    exit 3
  fi

  ok "PASS — all ${#} image(s) on $NODE are the images built locally"
}

main "$@"
