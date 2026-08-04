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
set -euo pipefail

DOCKER_BIN="${DOCKER_BIN:-docker}"
KIND_BIN="${KIND_BIN:-kind}"
CLUSTER_NAME="${CLUSTER_NAME:-osramp}"
NODE="${KIND_LOAD_NODE:-${CLUSTER_NAME}-control-plane}"

log()  { printf '\033[1;36m[kind-load]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[kind-load] ✓\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[kind-load] !\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m[kind-load] FAILED:\033[0m %s\n' "$*" >&2; exit 1; }

# How crictl prints a reference. A bare `name:tag` is normalised to
# docker.io/library/name:tag; anything already carrying a registry or a path is
# printed as given.
canonical_ref() {
  local image="$1" repo="${1%:*}" tag="${1##*:}"
  case "$repo" in
    */*) printf '%s:%s' "$repo" "$tag" ;;
    *)   printf 'docker.io/library/%s:%s' "$repo" "$tag" ;;
  esac
}

# True when the CRI can actually run the image.
#
# The match runs inside a single awk that reads to EOF rather than piping into
# `grep -q`. grep exits on first match, closing the pipe and killing the
# upstream `docker exec` with SIGPIPE (141), which under `set -o pipefail`
# becomes the pipeline's status — so the check reported FAILURE for an image
# that was present, and did so more reliably the more images the node had.
# supercred-images.sh carries the same note; it is not a hypothetical.
image_on_node() {
  local want
  want="$(canonical_ref "$1")"
  "$DOCKER_BIN" exec "$NODE" crictl images 2>/dev/null \
    | awk -v want="$want" '$1":"$2 == want { found = 1 } END { exit !found }'
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
  local waited=0
  while [ "$waited" -lt "${KIND_LOAD_CRI_ADOPT_TIMEOUT:-20}" ]; do
    image_on_node "$image" && return 0
    sleep 1
    waited=$((waited + 1))
  done
  warn "$image is labelled but the CRI has not adopted it after ${waited}s"
  return 1
}

main() {
  [ "$#" -gt 0 ] || fail "usage: kind-load-verified.sh IMAGE [IMAGE...]"

  # One kind invocation for the whole set: it is faster, and it is the call the
  # Makefile used to make directly, so the happy path is unchanged.
  log "loading into kind cluster $CLUSTER_NAME: $*"
  "$KIND_BIN" load docker-image --name "$CLUSTER_NAME" "$@" || \
    warn "kind load reported failure — verifying each image anyway"

  local image missing=()
  for image in "$@"; do
    if image_on_node "$image"; then
      ok "$image present on $NODE"
      continue
    fi
    warn "$image did NOT reach $NODE despite kind load succeeding — recovering"
    if recover_via_archive "$image" && image_on_node "$image"; then
      ok "$image present on $NODE (via archive recovery)"
    else
      missing+=("$image")
    fi
  done

  if [ "${#missing[@]}" -gt 0 ]; then
    # Name the consequence, not just the fact. A bare "image missing" here has
    # historically been read as a build problem and sent people to the wrong
    # place; the failure surfaces three layers away as an unrelated Flux
    # timeout.
    printf '\n' >&2
    fail "$(cat <<EOF
these images are not runnable on $NODE: ${missing[*]}

  'ctr images ls' may still list them — it reads the content store, which holds
  the manifest even when no layers arrived. 'crictl images' is the CRI's view
  and is what kubelet can actually run.

  Left unfixed, the pods enter ImagePullBackOff, inf-signalloom/infra-configs
  fails its health check, signalloom-apps never reconciles, and fe-signalloom
  stays empty — which surfaces as a Flux convergence timeout naming no image.

  Inspect with:
    docker exec $NODE crictl images
    docker exec $NODE ctr -n k8s.io images ls
EOF
)"
  fi

  ok "all ${#} image(s) verified runnable on $NODE"
}

main "$@"
