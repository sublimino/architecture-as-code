#!/usr/bin/env bats
# test/sentinel-image-provenance.bats
#
# The stun-sentinel image must be traceable to the source that built it.
# Before this suite the base pinned ghcr.io/...:v0.2.0, a tag never published
# and reused for about seven side-loaded builds, so the running image said
# nothing about its code and a node replacement meant ImagePullBackOff.
#
# Now the tag is `src-` + 12 hex of the estate's source fingerprint
# (scripts/lib/source-id.sh: a deterministic tar of exactly what the Dockerfile
# COPYs; `make -C d2-signalloom sentinel-image-source-id`). It tracks CONTENT,
# so a rebase or merge that rewrites commit hashes leaves it unchanged. The kind overlays
# point at the in-cluster zot repository every other estate image uses, and
# the flux ResourceSet deploys the kind-osramp overlay. Rendered with
# `kubectl kustomize`, offline. Nothing here skips.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  SWARM="${REPO_ROOT}/d2-signalloom/infra/agent-swarm"
  BASE_DIR="${SWARM}/signalloom-stun-sentinel"
  OVERLAYS=("${SWARM}/signalloom-stun-sentinel-overlays/kind-osramp" "${SWARM}/signalloom-stun-sentinel-overlays/kind-signalloom-hub")
  CANONICAL="ghcr.io/controlplaneio-in-toto/signalloom-stun-sentinel"
  ZOT="zot.registry.svc.cluster.local:5000/acme/images/signalloom/apps/stun-sentinel"
  export KUBECONFIG=/dev/null
  command -v kubectl >/dev/null || { echo "kubectl is required" >&2; return 1; }
  command -v yq >/dev/null || { echo "yq is required" >&2; return 1; }
}

rendered_image() {
  kubectl kustomize "$1" | yq -r 'select(.kind == "DaemonSet") | .spec.template.spec.containers[] | select(.name == "sentinel") | .image'
}

# An immutable source-fingerprint tag: src- and exactly 12 lowercase hex.
assert_source_tag() {
  local image="$1" tag="${1##*:}"
  [[ "$tag" =~ ^src-[0-9a-f]{12}$ ]] || { echo "image ${image} has tag '${tag}', not src-<12 hex> (mutable tags such as latest or v0.2.0 are refused)" >&2; return 1; }
}

@test "sentinel-image-provenance: each kind overlay deploys the zot image under a source-fingerprint tag" {
  for overlay in "${OVERLAYS[@]}"; do
    run rendered_image "$overlay"
    [ "$status" -eq 0 ]
    [[ "$output" == "${ZOT}:"* ]] || { echo "${overlay##*/} renders '${output}', want ${ZOT}:src-<id>" >&2; return 1; }
    assert_source_tag "$output"
  done
}

@test "sentinel-image-provenance: the base keeps the canonical ghcr reference for remote clusters" {
  run rendered_image "$BASE_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == "${CANONICAL}:"* ]] || { echo "base renders '${output}'" >&2; return 1; }
  assert_source_tag "$output"
}

@test "sentinel-image-provenance: base and both overlays carry one tag" {
  local base_tag tag
  base_tag="$(rendered_image "$BASE_DIR")"; base_tag="${base_tag##*:}"
  for overlay in "${OVERLAYS[@]}"; do
    tag="$(rendered_image "$overlay")"; tag="${tag##*:}"
    [ "$tag" = "$base_tag" ] || { echo "${overlay##*/} tag ${tag} != base ${base_tag}" >&2; return 1; }
  done
}

@test "sentinel-image-provenance: the deployed tag is the fingerprint of the sentinel source on disk" {
  run make -s --no-print-directory -C "${REPO_ROOT}/d2-signalloom" sentinel-image-source-id
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^src-[0-9a-f]{12}$ ]]
  local want="$output" got
  got="$(rendered_image "${OVERLAYS[0]}")"
  [ "${got##*:}" = "$want" ] || {
    echo "kind-osramp deploys :${got##*:} but the sentinel source is at ${want}." >&2
    echo "Rebuild and re-pin: make -C d2-signalloom sentinel-image-pin && make -C d2-signalloom sentinel-image-publish" >&2
    return 1
  }
}

@test "sentinel-image-provenance: the flux ResourceSet deploys the kind-osramp overlay, not the base" {
  run yq -r '.spec.resources[] | select(.kind == "Kustomization" and .metadata.name == "agent-signalloom-stun-sentinel") | .spec.path' \
    "${REPO_ROOT}/d2-osramp-fleet/tenants/base/agent-swarm.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "./signalloom-stun-sentinel-overlays/kind-osramp" ]
  # The path is relative to the agent-swarm artifact, published from this directory.
  [ -f "${SWARM}/${output#./}/kustomization.yaml" ]
}

# The real d2-signalloom/Makefile recipe and the real scripts/lib/source-id.sh,
# in a throwaway repository: the real checkout is never dirtied.
scratch_repo() {
  local scratch="${BATS_TEST_TMPDIR}/repo" apps
  apps="${scratch}/d2-signalloom/apps"
  mkdir -p "${apps}/stun-sentinel" "${apps}/signalloom-stun-sentinel" "${scratch}/scripts/lib"
  cp "${REPO_ROOT}/d2-signalloom/Makefile" "${scratch}/d2-signalloom/Makefile"
  cp "${REPO_ROOT}/scripts/lib/source-id.sh" "${scratch}/scripts/lib/source-id.sh"
  cp "${REPO_ROOT}/d2-signalloom/apps/signalloom-stun-sentinel/Dockerfile" "${apps}/signalloom-stun-sentinel/Dockerfile"
  for d in stun-sentinel signalloom-stun-sentinel; do
    echo "module x/${d}" >"${apps}/${d}/go.mod"
    : >"${apps}/${d}/go.sum"
  done
  echo lib >"${apps}/stun-sentinel/lib.go"
  echo main >"${apps}/signalloom-stun-sentinel/main.go"
  git -C "$scratch" init -q
  scratch_commit "$scratch" inputs
  echo "$scratch"
}

scratch_commit() {
  git -C "$1" add -A
  git -C "$1" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m "$2"
}

scratch_tag() {
  make -s --no-print-directory -C "$1/d2-signalloom" sentinel-image-tag
}

@test "sentinel-image-provenance: sentinel-image-tag prints src-<12 hex> on a clean tree" {
  local scratch; scratch="$(scratch_repo)"
  run scratch_tag "$scratch"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^src-[0-9a-f]{12}$ ]]
}

@test "sentinel-image-provenance: rewriting history without changing the source keeps the tag" {
  local scratch before; scratch="$(scratch_repo)"
  before="$(scratch_tag "$scratch")"
  git -C "$scratch" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --amend -m "rebased"
  echo docs >"${scratch}/README.md"; scratch_commit "$scratch" "unrelated"
  run scratch_tag "$scratch"
  [ "$status" -eq 0 ]
  [ "$output" = "$before" ]
}

@test "sentinel-image-provenance: a committed change to any COPYd file changes the tag" {
  local scratch before; scratch="$(scratch_repo)"
  before="$(scratch_tag "$scratch")"
  echo "// fix" >>"${scratch}/d2-signalloom/apps/stun-sentinel/lib.go"; scratch_commit "$scratch" lib
  run scratch_tag "$scratch"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^src-[0-9a-f]{12}$ ]]
  [ "$output" != "$before" ]
}

@test "sentinel-image-provenance: sentinel-image-tag refuses a dirty build and names the file" {
  local scratch; scratch="$(scratch_repo)"
  echo edit >>"${scratch}/d2-signalloom/apps/signalloom-stun-sentinel/main.go"
  run --separate-stderr scratch_tag "$scratch"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"refusing a -dirty build"* ]]
  [[ "$stderr" == *"apps/signalloom-stun-sentinel/main.go"* ]]
}

@test "sentinel-image-provenance: an untracked input file is dirty too" {
  local scratch; scratch="$(scratch_repo)"
  echo new >"${scratch}/d2-signalloom/apps/stun-sentinel/new.go"
  run --separate-stderr scratch_tag "$scratch"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"apps/stun-sentinel/new.go"* ]]
}

@test "sentinel-image-provenance: a Dockerfile COPY of a missing path is refused, not hashed as empty" {
  local scratch; scratch="$(scratch_repo)"
  git -C "$scratch" rm -q d2-signalloom/apps/stun-sentinel/go.sum; scratch_commit "$scratch" "drop go.sum"
  run --separate-stderr scratch_tag "$scratch"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"COPYs stun-sentinel/go.sum, which does not exist"* ]]
}
