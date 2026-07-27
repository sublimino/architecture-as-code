#!/usr/bin/env bats
#
# Static wiring assertions for the dashboard supply-chain pipeline. Runs no
# docker/cosign/buildx — it only proves the build+sign script and the Makefile
# target exist and carry the required flags, so it is safe on any host.

setup() {
  root="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  script="$root/scripts/build-sign-dashboard.sh"
  makefile="$root/Makefile"
}

@test "Dashboard build-sign script exists and is executable" {
  [ -f "$script" ]
  [ -x "$script" ]
}

@test "Dashboard build-sign script generates BuildKit SBOM and provenance" {
  run grep -F -- '--sbom=true' "$script"
  [ "$status" -eq 0 ]
  run grep -F -- '--provenance' "$script"
  [ "$status" -eq 0 ]
}

@test "Dashboard build-sign script signs the digest with the local cosign key" {
  run grep -F 'cosign sign' "$script"
  [ "$status" -eq 0 ]
  run grep -F -- '--key "${COSIGN_KEY}"' "$script"
  [ "$status" -eq 0 ]
  run grep -F -- '--use-signing-config=false' "$script"
  [ "$status" -eq 0 ]
  run grep -F -- '--allow-insecure-registry' "$script"
  [ "$status" -eq 0 ]
  run grep -F -- '--registry-referrers-mode=legacy' "$script"
  [ "$status" -eq 0 ]
}

@test "Dashboard build-sign script keeps the transparency log disabled" {
  run grep -F -- '--tlog-upload=false' "$script"
  [ "$status" -eq 0 ]
  run grep -F -- '--tlog-upload=true' "$script"
  [ "$status" -ne 0 ]
}

@test "Dashboard build-sign script writes the three evidence artifacts" {
  run grep -F 'dashboard-signalloom.sbom.spdx.json' "$script"
  [ "$status" -eq 0 ]
  run grep -F 'dashboard-signalloom.provenance.slsa.json' "$script"
  [ "$status" -eq 0 ]
  run grep -F 'dashboard-signalloom.digest.txt' "$script"
  [ "$status" -eq 0 ]
}

@test "Makefile exposes the signed dashboard image target" {
  run grep -F '.PHONY: signalloom-dashboard-image' "$makefile"
  [ "$status" -eq 0 ]
  run grep -E '^signalloom-dashboard-image:' "$makefile"
  [ "$status" -eq 0 ]
  run grep -F './scripts/build-sign-dashboard.sh' "$makefile"
  [ "$status" -eq 0 ]
}
