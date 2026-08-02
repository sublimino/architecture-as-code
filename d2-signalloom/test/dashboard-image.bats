#!/usr/bin/env bats
#
# Real container + supply-chain evidence checks for the dashboard workload.
# The build+run test needs a docker daemon; the evidence/signature tests need
# the artifacts produced by scripts/build-sign-dashboard.sh. Every test skips
# gracefully when its prerequisites are absent so the suite stays portable.

setup() {
  root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  # Shared polling/wait primitives — deadline-bounded exponential backoff
  # with jitter, instead of a hand-rolled sleep loop.
  # shellcheck source=../../scripts/lib/wait.sh
  source "$root/scripts/lib/wait.sh"
  context="$root/d2-signalloom/apps/dashboard-signalloom"
  script="$root/scripts/build-sign-dashboard.sh"
  cosign_pub="$root/.keys/cosign.pub"

  evidence_dir="${EVIDENCE_DIR:-$root/docs/signalloom/evidence}"
  sbom_file="$evidence_dir/dashboard-signalloom.sbom.spdx.json"
  provenance_file="$evidence_dir/dashboard-signalloom.provenance.slsa.json"
  digest_file="$evidence_dir/dashboard-signalloom.digest.txt"

  local_ref="${LOCAL_REF:-localhost:5001/acme/images/signalloom/apps/dashboard-signalloom:latest}"

  image="signalloom-dashboard-image-test:local"
  container="signalloom-dashboard-image-test"
  host_port="18080"
}

teardown() {
  docker rm -f "$container" >/dev/null 2>&1 || true
  docker image rm -f "$image" >/dev/null 2>&1 || true
}

@test "Dashboard container serves readiness, root, and SPA fallback" {
  command -v docker >/dev/null 2>&1 || skip "docker required"
  command -v curl >/dev/null 2>&1 || skip "curl required"
  docker info >/dev/null 2>&1 || skip "docker daemon unavailable"

  # Prefer the signed pipeline when its prerequisites are present; otherwise
  # fall back to a plain image build so the runtime behaviour is still covered.
  if [ -x "$script" ] && [ -f "$root/.keys/cosign.key" ]; then
    run env IMAGE_REF="$image" LOCAL_REF="$local_ref" "$script"
    [ "$status" -eq 0 ]
  else
    run docker build -t "$image" "$context"
    [ "$status" -eq 0 ]
  fi

  run docker run --detach --name "$container" -p "127.0.0.1:${host_port}:8080" "$image"
  [ "$status" -eq 0 ]

  wait_reachable "http://127.0.0.1:${host_port}/readyz" 10

  run curl -fsS "http://127.0.0.1:${host_port}/readyz"
  [ "$status" -eq 0 ]
  [ "$output" = "ready" ]

  run curl -fsS "http://127.0.0.1:${host_port}/"
  [ "$status" -eq 0 ]
  [[ "$output" == *'id="root"'* ]]

  run curl -fsS "http://127.0.0.1:${host_port}/deep/spa/link"
  [ "$status" -eq 0 ]
  [[ "$output" == *'id="root"'* ]]
}

@test "Dashboard supply-chain evidence is SPDX SBOM, SLSA provenance, and a resolved digest" {
  command -v jq >/dev/null 2>&1 || skip "jq required"
  [ -f "$sbom_file" ] || skip "SBOM evidence not generated yet: $sbom_file"
  [ -f "$provenance_file" ] || skip "provenance evidence not generated yet: $provenance_file"
  [ -f "$digest_file" ] || skip "digest evidence not generated yet: $digest_file"

  run jq -e '.spdxVersion // .SPDXID' "$sbom_file"
  [ "$status" -eq 0 ]

  run jq -e '.predicateType | test("slsa\\.dev/provenance")' "$provenance_file"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]

  # Allow the digest file to carry an optional registry-ref prefix before the digest.
  run grep -Eo 'sha256:[a-f0-9]{64}' "$digest_file"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^sha256:[a-f0-9]{64}$ ]]
}

@test "Dashboard image signature verifies against the local trust anchor" {
  command -v cosign >/dev/null 2>&1 || skip "cosign required"
  command -v curl >/dev/null 2>&1 || skip "curl required"
  [ -f "$cosign_pub" ] || skip "cosign public key not present: $cosign_pub"
  [ -f "$digest_file" ] || skip "digest evidence not generated yet: $digest_file"
  curl -fsS "http://localhost:5001/v2/" >/dev/null 2>&1 || skip "local registry unavailable on localhost:5001"

  digest="$(grep -Eo 'sha256:[a-f0-9]{64}' "$digest_file" | head -n1)"
  [ -n "$digest" ]
  ref="${local_ref%:*}@${digest}"

  run cosign verify \
    --key "$cosign_pub" \
    --insecure-ignore-tlog \
    --allow-insecure-registry \
    "$ref"
  [ "$status" -eq 0 ]
}
