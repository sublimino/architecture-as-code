#!/usr/bin/env bats
# test/sentinel-image-provenance.bats
#
# The stun-sentinel image must be traceable to the source that built it.
# Before this suite the base pinned ghcr.io/...:v0.2.0, a tag never published
# and reused for about seven side-loaded builds, so the running image said
# nothing about its code and a node replacement meant ImagePullBackOff.
#
# Now the tag is the 12-hex commit that last changed the image inputs
# (`make -C d2-signalloom sentinel-image-source-commit`), the kind overlays
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

# An immutable source-commit tag: exactly 12 lowercase hex characters.
assert_commit_tag() {
  local image="$1" tag="${1##*:}"
  [[ "$tag" =~ ^[0-9a-f]{12}$ ]] || { echo "image ${image} has tag '${tag}', not a 12-hex source commit (mutable tags such as latest or v0.2.0 are refused)" >&2; return 1; }
}

@test "sentinel-image-provenance: each kind overlay deploys the zot image under a source-commit tag" {
  for overlay in "${OVERLAYS[@]}"; do
    run rendered_image "$overlay"
    [ "$status" -eq 0 ]
    [[ "$output" == "${ZOT}:"* ]] || { echo "${overlay##*/} renders '${output}', want ${ZOT}:<commit>" >&2; return 1; }
    assert_commit_tag "$output"
  done
}

@test "sentinel-image-provenance: the base keeps the canonical ghcr reference for remote clusters" {
  run rendered_image "$BASE_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == "${CANONICAL}:"* ]] || { echo "base renders '${output}'" >&2; return 1; }
  assert_commit_tag "$output"
}

@test "sentinel-image-provenance: base and both overlays carry one tag" {
  local base_tag tag
  base_tag="$(rendered_image "$BASE_DIR")"; base_tag="${base_tag##*:}"
  for overlay in "${OVERLAYS[@]}"; do
    tag="$(rendered_image "$overlay")"; tag="${tag##*:}"
    [ "$tag" = "$base_tag" ] || { echo "${overlay##*/} tag ${tag} != base ${base_tag}" >&2; return 1; }
  done
}

@test "sentinel-image-provenance: the deployed tag is the commit that last changed the image inputs" {
  run make -s --no-print-directory -C "${REPO_ROOT}/d2-signalloom" sentinel-image-source-commit
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9a-f]{12}$ ]]
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

# The real d2-signalloom/Makefile recipe, in a throwaway repository: the real
# checkout is never dirtied.
make_tag_in_scratch_repo() {
  local scratch="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "${scratch}/d2-signalloom/apps/stun-sentinel" "${scratch}/d2-signalloom/apps/signalloom-stun-sentinel"
  cp "${REPO_ROOT}/d2-signalloom/Makefile" "${scratch}/d2-signalloom/Makefile"
  echo lib >"${scratch}/d2-signalloom/apps/stun-sentinel/lib.go"
  echo main >"${scratch}/d2-signalloom/apps/signalloom-stun-sentinel/main.go"
  git -C "$scratch" init -q
  git -C "$scratch" add -A
  git -C "$scratch" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m inputs
  echo "$scratch"
}

@test "sentinel-image-provenance: sentinel-image-tag prints the inputs' commit on a clean tree" {
  local scratch; scratch="$(make_tag_in_scratch_repo)"
  run make -s --no-print-directory -C "${scratch}/d2-signalloom" sentinel-image-tag
  [ "$status" -eq 0 ]
  [ "$output" = "$(git -C "$scratch" rev-parse HEAD | cut -c1-12)" ]
}

@test "sentinel-image-provenance: sentinel-image-tag refuses a dirty build and names the file" {
  local scratch; scratch="$(make_tag_in_scratch_repo)"
  echo edit >>"${scratch}/d2-signalloom/apps/signalloom-stun-sentinel/main.go"
  run --separate-stderr make -s --no-print-directory -C "${scratch}/d2-signalloom" sentinel-image-tag
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"refusing a -dirty build"* ]]
  [[ "$stderr" == *"apps/signalloom-stun-sentinel/main.go"* ]]
}

@test "sentinel-image-provenance: an untracked input file is dirty too" {
  local scratch; scratch="$(make_tag_in_scratch_repo)"
  echo new >"${scratch}/d2-signalloom/apps/stun-sentinel/new.go"
  run --separate-stderr make -s --no-print-directory -C "${scratch}/d2-signalloom" sentinel-image-tag
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"apps/stun-sentinel/new.go"* ]]
}
