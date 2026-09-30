#!/usr/bin/env bats
#
# SLDC-P6-1: End-to-end adversarial super-test, clean teardown, scratch bootstrap, and replay.
#
# @target scripts/super-test-adversarial.sh scripts/verify-mutation-gate.sh
# @target scripts/cluster-clean-teardown.sh scripts/cluster-scratch-standup.sh
# @doc    docs/eap/SLDC-MISSION-CERTIFICATION.md

setup() {
  root="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "adversarial purple-team super-test suite passes on current estate" {
  run bash "$root/scripts/super-test-adversarial.sh" --run-all
  [ "$status" -eq 0 ]
  [[ "$output" =~ "VERDICT: PASS" ]]
  [ -f "$root/.evidence/coldstart-supertest-results.json" ]
}

@test "mutation verification gate proves all deliberate security mutations fail" {
  run bash "$root/scripts/verify-mutation-gate.sh" --check-all
  [ "$status" -eq 0 ]
  [[ "$output" =~ "MUTATION GATE: 4/4 mutations proven" ]]
}

@test "hermetic five-step containment mutation proof passes 21/21" {
  run bash "$root/test/e2e-mutation-proof.sh"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "mutations proven: 21/21" ]]
}

@test "forensic evidence bundle packager creates and signs fresh replay evidence" {
  out_replay="$root/.evidence/fresh-replay"
  mkdir -p "$out_replay/input"
  cp "$root"/test/fixtures/eap-evidence/* "$out_replay/input/"
  rm -f "$out_replay/input/audit-signature.sha256" "$out_replay/input/bundle-header.json"* "$out_replay/input/signing-key.pub.pem"
  run bash "$root/scripts/package-eap-evidence.sh" "$out_replay/input" --output-dir "$out_replay"
  [ "$status" -eq 0 ]
  [ -f "$out_replay/audit-signature.sha256" ]
  [ -f "$out_replay/eap-kusari-containment.tar.gz" ]
  [ "$(wc -l < "$out_replay/audit-signature.sha256")" -eq 7 ]
  run bash "$root/scripts/verify-eap-evidence.sh" "$out_replay/eap-kusari-containment.tar.gz"
  [ "$status" -eq 0 ]
}

@test "zero-state attestation digest can be computed and verified" {
  manifest="$root/.evidence/zero-state-attestation.sha256"
  (cd "$root" && sha256sum scripts/super-test-adversarial.sh \
    scripts/verify-mutation-gate.sh \
    scripts/cluster-clean-teardown.sh \
    scripts/cluster-scratch-standup.sh > "$manifest")
  [ -f "$manifest" ]
  run sha256sum -c "$manifest"
  [ "$status" -eq 0 ]
}
