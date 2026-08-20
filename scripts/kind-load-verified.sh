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

  # Label-first. The export below moves 0.0 B whenever the content is already on
  # the node, which on 2026-08-18 was every observed case — the CRI was missing
  # the label, not the bytes. Try the cheap correct action, and fall through to
  # the full export only when the content genuinely is not there.
  #
  # This cannot mask a failure: image_identity_adopt_if_present returns 0 only
  # when image_identity_verify PROVES identity afterwards, so a failed adoption
  # falls through to the expensive path rather than being reported as success.
  if image_identity_adopt_if_present "$image" "${KIND_LOAD_CRI_ADOPT_TIMEOUT:-90}"; then
    log "recovery: content was already on $NODE — labelled it CRI-managed, no re-export needed"
    return 0
  fi

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
  # KIND_LOAD_CRI_ADOPT_TIMEOUT bounds ITERATIONS, not seconds, and on a busy
  # node the two are nowhere near each other. Each iteration costs one `sleep 1`
  # PLUS two `docker exec` round trips — `crictl images` for presence and
  # `crictl inspecti` for the diffIDs. Idle, those are milliseconds and 20
  # checks really is about 20 seconds. On a node that is itself busy adopting
  # images they dominate, and 20 checks can be minutes of wall clock.
  #
  # This mattered. The cold run on 2026-08-18 printed "has not adopted the
  # recovered image after 20s", the iteration count wearing a seconds suffix,
  # and the obvious reading — "the 20s timeout is too short" — was wrong. The
  # repo even supplies corroborating precedent for it: supercred-images.sh:356
  # runs the same poll at 90 with a comment saying 20 was fitted to a 54MB image.
  # A controlled experiment on the CI VM then showed the default AND 90 both
  # PASS on an idle node, because the number in the message had never been the
  # elapsed time. Report both, so the next person reads a measurement rather
  # than a unit error.
  #
  # Do NOT "fix" this by making the bound wall-clock. Under load a real
  # 20-second deadline is TIGHTER than 20 checks, so changing the unit would
  # make the failure MORE likely while looking like a correctness fix. The bound
  # stays on iterations deliberately; only the reporting changes here.
  #
  # ─── 2026-08-20: the default moved 20 → 90, and the paragraph above is why
  #     that is a raise rather than the unit error it warns against ───────────
  #
  # The reporting change demanded above is what made this decidable. demo-1
  # failed with "after 20 checks over 22s" — the count and the elapsed time
  # BOTH printed, ~1.1s per iteration. That is an essentially idle node: the
  # `docker exec` round trips were not dominating, so this is NOT the
  # under-load case where iterations and seconds diverge. Adoption simply had
  # not finished in 22 seconds.
  #
  # So the earlier controlled experiment stands and is not being overridden.
  # It showed 20 and 90 both PASS *on an idle node*, and it ran when a lane was
  # n2-standard-16. These lanes are now n2-standard-8 — half the vCPU, and
  # containerd unpacking is exactly the CPU-bound work that halves with it.
  # The experiment's conclusion was "the number in the message was never the
  # elapsed time", which was true and remains true; it was not "20 is enough
  # for every image on every machine".
  #
  # 90 is not a guess either: it is what supercred-images.sh:290/374 and
  # signalfusion-images.sh:185/230 have always used for the identical poll
  # against the identical shared helper. This file was the outlier at 20, and
  # its own comment records that 20 "was fitted to a 54MB image". Three call
  # sites of one helper now agree, which is worth more than the four-and-a-half
  # times headroom on its own — a model that differs per copy is how this class
  # of defect keeps returning.
  #
  # The failure remains reported in BOTH units, so if this ever fires again the
  # next person can tell "adoption is slow" from "the node is thrashing"
  # without re-deriving it.
  local checks=0 rc started elapsed
  started="$(date +%s)"
  while [ "$checks" -lt "${KIND_LOAD_CRI_ADOPT_TIMEOUT:-90}" ]; do
    image_identity_invalidate
    rc=0; image_identity_verify "$image" || rc=$?
    [ "$rc" -eq 0 ] && return 0
    # No local image to compare against is not something waiting will fix, and
    # presence is then the strongest answer available.
    [ "$rc" -eq 2 ] && [ "$IMAGE_IDENTITY_PRESENT" = "yes" ] && return 0
    sleep 1
    checks=$((checks + 1))
  done
  elapsed=$(( $(date +%s) - started ))
  warn "$image is labelled but the CRI has not adopted the recovered image after ${checks} checks over ${elapsed}s"
  return 1
}

# Capture the node's state at the moment an image the loader claimed to have
# transferred is not there.
#
# PURE DIAGNOSTICS. Every probe is best-effort and every one ends in `|| true`
# under this script's `set -euo pipefail`: a failure to COLLECT evidence must
# never change a verdict, and must never fail a run. If a line is missing below,
# the probe failed — that is not the same as the reading being empty, and the
# header line says so rather than leaving the reader to guess.
#
# Aimed at the FIRST stage. The cold run on 2026-08-18 had `kind load` exit 0
# having transferred nothing, three times, while the same command completed in
# ~1s on an idle node and 0 of 2 synthetic-load attempts reproduced it. We have
# never captured why. These readings separate the candidates that verdict alone
# cannot:
#
#   ctr lists it, crictl does not   a half-transferred image — manifest written,
#                                   layers absent, CRI never adopts it. This is
#                                   the shape the header describes.
#   neither lists it                the transfer genuinely did not happen.
#   both list it                    a verification-timing problem, not a load one.
#   disk near full                  the classic cause of a write that reports
#                                   success and stores nothing, and it is
#                                   invisible in every verdict this script prints.
diagnose_load_failure() {
  local image="$1" ref name
  ref="$(canonical_ref "$image")"
  name="${ref%:*}"

  warn "--- diagnostics for $image (best-effort; a MISSING line means the probe itself failed) ---"

  warn "  ctr, content store:"
  "$DOCKER_BIN" exec "$NODE" ctr -n k8s.io images ls 2>/dev/null \
    | awk -v r="$ref" '$1 == r {print "      " $1 "  " $3}' || true

  warn "  crictl, CRI view:"
  "$DOCKER_BIN" exec "$NODE" crictl images 2>/dev/null \
    | awk -v n="$name" '$1 == n {print "      " $1 "  " $2 "  " $3}' || true

  local ctr_n crictl_n
  ctr_n="$("$DOCKER_BIN" exec "$NODE" ctr -n k8s.io images ls -q 2>/dev/null | grep -c . || true)"
  crictl_n="$("$DOCKER_BIN" exec "$NODE" crictl images -q 2>/dev/null | grep -c . || true)"
  warn "  totals: ctr=${ctr_n:-MISSING} crictl=${crictl_n:-MISSING}  (tells 'this image is missing' from 'the node lost everything')"

  warn "  node disk:"
  "$DOCKER_BIN" exec "$NODE" df -h / /var/lib/containerd 2>/dev/null \
    | sed 's/^/      /' || true
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
  # Captured rather than streamed, because WHAT kind said is evidence and we have
  # never had it. On 2026-08-18 a cold run had kind exit 0 having transferred
  # nothing, three times; the report showed the verdict but not kind's own
  # account of the transfer, so "it announced a load that did not happen" and "it
  # said nothing at all" were indistinguishable afterwards. They are different
  # bugs. The cost is that output appears after the load rather than during it.
  local kind_status=0 kind_out=""
  kind_out="$("$KIND_BIN" load docker-image --name "$CLUSTER_NAME" "$@" 2>&1)" || kind_status=$?
  if [ -n "$kind_out" ]; then
    while IFS= read -r kind_line; do log "kind: $kind_line"; done <<<"$kind_out"
  else
    log "kind: (no output at all — it neither named an image nor reported a transfer)"
  fi
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
    # Read the node BEFORE recovery mutates it. Afterwards the import and the
    # label have already changed what we would be looking at, so the state that
    # explains the empty transfer is gone.
    diagnose_load_failure "$image"
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
