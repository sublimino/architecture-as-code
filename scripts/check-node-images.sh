#!/usr/bin/env bash
# check-node-images.sh — is every image this cluster references on the kind node?
#
#   check-node-images.sh          # against the running cluster (doctor)
#
# Exit: 0 all present, 1 one or more absent, 3 indeterminate (nothing to read).
#
# ─── Why this exists ────────────────────────────────────────────────────────
#
# doctor.sh used to check a seven-element constant:
#
#   listener:dev processor:dev olly-sentinel:dev olly-authz:dev
#   olly-tenant-app:dev olly-elk-mcp:dev olly-stubs:dev
#
# Every one belongs to Olly Sentinel or the OSRAMP listener/processor path, and
# scripts/ci/vm-pipeline.sh deliberately skips the OSRAMP-demo ResourceSets. So
# on a signalloom-only run all seven are absent BY DESIGN, and doctor printed
#
#   ⚠ 7 image(s) missing from kind node — run: make images
#
# on runs where all 13 CI stages passed, naming none of them, and pointing at a
# target that would not have changed the outcome.
#
# The cost was not untidiness. During a genuinely failing run a lane agent read
# that constant as a variable, inferred the CI build list was short by more than
# the one target actually identified, and passed the arithmetic on. It was a
# false lead end to end: the number is a fixed list length, so it read the same
# in the green run as in the red one. A warning that is unconditionally true is
# indistinguishable from one that has just become true, and it consumed real
# attention at the worst possible moment.
#
# ─── Why the expected set is DERIVED ────────────────────────────────────────
#
# A hand-maintained list of "images this profile needs" is the same artefact as
# the constant above: it is correct on the day it is written and drifts on the
# day a slice is added, which is precisely the failure being guarded. So this
# asks the cluster instead.
#
# The set of images a workload references IS the set of images the node must
# have — a pod cannot run an image that is not there, and a reference to an
# image nobody built is exactly the ImagePullBackOff this check exists to catch.
# Deploy Olly and its images become expected; run the signalloom-only path and
# they are not, with no list to update either way. The profile is not declared,
# it is observed.
#
# Same reasoning as scripts/check-backends.sh, which derives the backends that
# must be deployed from nginx.conf's proxy_pass lines, and
# scripts/check-ci-build-parity.sh, which derives CI's build steps from the
# Makefile. Aimed here at what the node holds rather than at deployment or
# build parity.
#
# ─── Why the match is columnar ──────────────────────────────────────────────
#
# The old match was `grep -q "${img%%:*}.*${img##*:}"` — repo-prefix, anything,
# tag, anywhere on a line. `crictl images` is columnar, so the name could come
# from column 1 while the tag was satisfied by a completely unrelated column.
# On the live osramp node today:
#
#   docker.io/library/postgres    16-alpine    de3a4eab8fdfa    116MB
#
# satisfies `postgres:16` (TAG prefix), `postgres:116` (the SIZE) and
# `postgres:de3` (the IMAGE ID). Each is an image that is not on the node
# reported as present. Only a warning today, but a false PASS is the worst
# direction for a check to fail in, and it becomes one the moment anyone
# promotes this to a gate.
#
# The comparison is done inside a single awk that reads the listing to EOF
# rather than piping into `grep -q`, for the reason documented at length in
# scripts/supercred-images.sh: `grep -q` exits on first match, closes the pipe,
# and kills the upstream with SIGPIPE (141), which under `pipefail` becomes the
# status of the whole pipeline — so the check failed for images that were
# present, and did so more reliably the more images the node had.

set -Eeuo pipefail

DOCKER_BIN="${DOCKER_BIN:-docker}"
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
KIND_NODE="${KIND_NODE:-osramp-control-plane}"

case "${1:-}" in
  -h|--help) sed -n '2,6p' "${BASH_SOURCE[0]}"; exit 0 ;;
  "") : ;;
  *) printf 'usage: check-node-images.sh\n' >&2; exit 2 ;;
esac

# ── What the node can actually run ──────────────────────────────────────────
#
# Deliberately `crictl images`, not `ctr -n k8s.io images ls`. A `kind load`
# that transferred a manifest but no layers still appears in the content store,
# so `ctr images ls` lists images the kubelet cannot unpack. `crictl` reports
# the CRI's view, which is the only view that predicts whether a pod will run.
#
# --digests because Flux pins its controllers by digest, and crictl reports a
# digest-pinned image with TAG `<none>`; without the digest column four healthy
# controllers read as missing.
listing="$("$DOCKER_BIN" exec "$KIND_NODE" crictl images --digests 2>/dev/null || true)"

if [ -z "${listing//[[:space:]]/}" ] || [ "$(printf '%s\n' "$listing" | wc -l)" -lt 2 ]; then
  printf 'cannot read the image listing from %s — image state unproven, not disproven\n' "$KIND_NODE"
  printf 'Is this a kind cluster, and is `%s exec %s` permitted from here?\n' "$DOCKER_BIN" "$KIND_NODE"
  exit 3
fi

# ── What the cluster references ─────────────────────────────────────────────
#
# Init containers count: a slice whose init container image was never built
# fails exactly as loudly as one whose main image was not.
workloads="$("$KUBECTL_BIN" get pods --all-namespaces -o go-template='{{range .items}}{{$ns := .metadata.namespace}}{{$pod := .metadata.name}}{{$ph := .status.phase}}{{range .spec.containers}}{{$ns}} {{$pod}} {{$ph}} {{.image}}{{"\n"}}{{end}}{{range .spec.initContainers}}{{$ns}} {{$pod}} {{$ph}} {{.image}}{{"\n"}}{{end}}{{end}}' 2>/dev/null || true)"
workloads="$(printf '%s\n' "$workloads" | awk 'NF == 4')"

# Cannot pass vacuously. A renamed field or a broken template would otherwise
# yield an empty expected set and a confident green for a cluster nobody looked
# at — the same shape of false assurance this script was written to remove.
if [ -z "$workloads" ]; then
  printf 'no workloads found in the cluster — nothing to check the node against\n'
  printf 'Either nothing is deployed, or the pod query returned a shape this script cannot read.\n'
  exit 3
fi

# ── Normalise a Kubernetes reference into crictl's columns ──────────────────
#
# Emits `<repo> <tag> <digest>`. crictl always reports a fully-qualified repo,
# so `netassert-controller:dev` has to become `docker.io/library/...` and
# `minio/minio:latest` has to become `docker.io/minio/minio` — but only when the
# first path component is not itself a registry host. A component containing a
# dot or a colon (or being `localhost`) is a host; that is the distinction that
# keeps zot.registry.svc.cluster.local:5000/... from being mangled.
normalise() {
  local ref="$1" digest="" name tag first
  case "$ref" in *@sha256:*) digest="${ref##*@sha256:}"; ref="${ref%@sha256:*}" ;; esac
  case "${ref##*/}" in
    *:*) tag="${ref##*:}"; name="${ref%:*}" ;;
    *)   tag="latest";     name="$ref" ;;
  esac
  first="${name%%/*}"
  if [ "$name" = "$first" ]; then
    name="docker.io/library/${name}"
  else
    case "$first" in
      *.*|*:*|localhost) : ;;
      *) name="docker.io/${name}" ;;
    esac
  fi
  printf '%s %s %s\n' "$name" "$tag" "$digest"
}

# True when the CRI can run this exact image. Columns are compared as columns:
# repo is column 1 and tag is column 2, never each other's and never the
# IMAGE ID's or the SIZE's.
image_on_node() {
  local repo="$1" tag="$2" digest="$3"
  awk -v repo="$repo" -v tag="$tag" -v dig="$digest" '
    $1 == "IMAGE" { next }
    $1 != repo    { next }
    # A digest-pinned reference is identified by content, not by name. crictl
    # abbreviates the digest, so the listing value must PREFIX the wanted one —
    # never the other way round, which would match any digest at all.
    dig != "" { if ($3 != "" && $3 != "<none>" && index(dig, $3) == 1) found = 1; next }
    $2 == tag { found = 1 }
    END { exit !found }
  ' <<<"$listing"
}

total=0
absent=0
details=""

while read -r ref; do
  [ -n "$ref" ] || continue
  total=$((total + 1))
  read -r repo tag digest <<<"$(normalise "$ref")"
  if image_on_node "$repo" "$tag" "${digest:-}"; then
    continue
  fi
  absent=$((absent + 1))
  # Name the workload that wants it. "2 images absent" sends the reader
  # nowhere; "fe-signalloom/proxy-def (Pending) wants fake-integration-proxy:dev"
  # sends them somewhere.
  wanted_by="$(printf '%s\n' "$workloads" | awk -v r="$ref" '$4 == r { printf "%s/%s (%s)", $1, $2, $3; exit }')"
  details="${details}$(printf 'ABSENT  %-52s %s' "$ref" "$wanted_by")"$'\n'
done <<<"$(printf '%s\n' "$workloads" | awk '{print $4}' | sort -u)"

namespaces="$(printf '%s\n' "$workloads" | awk '{print $1}' | sort -u | wc -l)"
pods="$(printf '%s\n' "$workloads" | awk '{print $1"/"$2}' | sort -u | wc -l)"

if [ "$absent" -eq 0 ]; then
  printf '%s image(s) referenced by %s pod(s) across %s namespace(s), all present on %s\n' \
    "$total" "$pods" "$namespaces" "$KIND_NODE"
  exit 0
fi

printf '%s of %s image(s) referenced by deployed workloads are not on %s\n' \
  "$absent" "$total" "$KIND_NODE"
printf '%s' "$details"
printf 'Each is referenced by something already deployed, so the pod cannot start until\n'
printf 'the image is built and loaded — see the `images-<slice>` targets in the Makefile.\n'
exit 1
