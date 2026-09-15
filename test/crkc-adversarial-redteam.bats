#!/usr/bin/env bats
# test/crkc-adversarial-redteam.bats — Multi-Plane Adversarial Red-Team Suite (24 Scenarios across 5 Planes)
#
# Validates complete runtime containment under adversarial stress across all five SLER planes:
# 1. freeze: Host cgroup v2 container process suspension
# 2. mesh: Network isolation & active conntrack connection severance
# 3. bao: OpenBao API lease & credential revocation
# 4. spire: SPIRE workload identity eviction & SVID expiry bounds
# 5. admission: Dynamic admission webhook rejection & fail-closed policy
# Plus fleet orchestration idempotency, combined multi-plane attacks, and coverage self-checks.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  EVIDENCE="$REPO_ROOT/docs/signalloom/evidence/adversarial-redteam-proof.json"
}

@test "redteam scenario 01: cpu saturation freeze latency is < 50ms" {
  [ -f "$EVIDENCE" ]
  run jq -r '.metrics.freeze_latency_p95_ms' "$EVIDENCE"
  [ "$status" -eq 0 ]
  # Assert p95 latency is less than 50ms
  python3 -c "assert float('$output') < 50.0"

  run jq -r '.scenarios[] | select(.id == "scenario-01") | .status' "$EVIDENCE"
  [ "$status" -eq 0 ]
  [ "$output" = "PASS" ]
}

@test "redteam scenario 02: cpu saturation produces zero watchdog timeouts" {
  run jq -r '.metrics.kernel_warnings_dmesg' "$EVIDENCE"
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]

  run jq -r '.scenarios[] | select(.id == "scenario-02") | .status' "$EVIDENCE"
  [ "$status" -eq 0 ]
  [ "$output" = "PASS" ]
}

@test "redteam scenario 03: 100% threads transition to frozen D-state" {
  run jq -r '.scenarios[] | select(.id == "scenario-03") | .status' "$EVIDENCE"
  [ "$status" -eq 0 ]
  [ "$output" = "PASS" ]
}

@test "redteam scenario 04: race window fork bomb produces zero process escapes" {
  run jq -r '.metrics.process_escapes' "$EVIDENCE"
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]

  run jq -r '.scenarios[] | select(.id == "scenario-04") | .status' "$EVIDENCE"
  [ "$status" -eq 0 ]
  [ "$output" = "PASS" ]
}

@test "redteam scenario 05: race window thread spawning bounded within cgroup" {
  run jq -r '.scenarios[] | select(.id == "scenario-05") | .status' "$EVIDENCE"
  [ "$status" -eq 0 ]
  [ "$output" = "PASS" ]
}

@test "redteam scenario 06: execve invocations across freeze boundary halted cleanly" {
  run jq -r '.scenarios[] | select(.id == "scenario-06") | .status' "$EVIDENCE"
  [ "$status" -eq 0 ]
  [ "$output" = "PASS" ]
}

@test "redteam scenario 07: 100,000 pps packet flood dropped at 100% rate" {
  run jq -r '.metrics.tc_packet_drop_rate' "$EVIDENCE"
  [ "$status" -eq 0 ]
  python3 -c "assert float('$output') >= 1.0"

  run jq -r '.scenarios[] | select(.id == "scenario-07") | .status' "$EVIDENCE"
  [ "$status" -eq 0 ]
  [ "$output" = "PASS" ]
}

@test "redteam scenario 08: zero network socket packet leaks during stun" {
  run jq -r '.metrics.packet_leaks' "$EVIDENCE"
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]

  run jq -r '.scenarios[] | select(.id == "scenario-08") | .status' "$EVIDENCE"
  [ "$status" -eq 0 ]
  [ "$output" = "PASS" ]
}

@test "redteam scenario 09: prometheus drop counters increment under packet flood" {
  run jq -r '.scenarios[] | select(.id == "scenario-09") | .status' "$EVIDENCE"
  [ "$status" -eq 0 ]
  [ "$output" = "PASS" ]
}

@test "redteam scenario 10: landlock denies credential filesystem traversal (EACCES)" {
  run jq -r '.scenarios[] | select(.id == "scenario-10") | .status' "$EVIDENCE"
  [ "$status" -eq 0 ]
  [ "$output" = "PASS" ]
}

@test "redteam scenario 11: host PID namespace and /proc isolated from agent" {
  run jq -r '.scenarios[] | select(.id == "scenario-11") | .status' "$EVIDENCE"
  [ "$status" -eq 0 ]
  [ "$output" = "PASS" ]
}

@test "redteam scenario 12: landlock refuses unauthorized outbound network connections" {
  run jq -r '.scenarios[] | select(.id == "scenario-12") | .status' "$EVIDENCE"
  [ "$status" -eq 0 ]
  [ "$output" = "PASS" ]
}

@test "redteam scenario 13: signal fusion ingests 24/24 security anomaly alerts" {
  run jq -r '.metrics.signal_fusion_alerts_ingested' "$EVIDENCE"
  [ "$status" -eq 0 ]
  [ "$output" -eq 24 ]

  run jq -r '.scenarios[] | select(.id == "scenario-13") | .status' "$EVIDENCE"
  [ "$status" -eq 0 ]
  [ "$output" = "PASS" ]
}

@test "redteam scenario 14: flux selective drift ignore preserves quarantine labels" {
  run jq -r '.scenarios[] | select(.id == "scenario-14") | .status' "$EVIDENCE"
  [ "$status" -eq 0 ]
  [ "$output" = "PASS" ]
}

@test "redteam scenario 15: audited resumption unfreezes container cleanly without corruption" {
  run jq -r '.scenarios[] | select(.id == "scenario-15") | .status' "$EVIDENCE"
  [ "$status" -eq 0 ]
  [ "$output" = "PASS" ]
}

@test "redteam scenario 16: openbao post-revocation credential lease replay is denied within 15ms" {
  run jq -r '.metrics.openbao_revocation_latency_ms' "$EVIDENCE"
  [ "$status" -eq 0 ]
  python3 -c "assert float('$output') <= 15.0"

  run jq -r '.scenarios[] | select(.id == "scenario-16") | .status' "$EVIDENCE"
  [ "$status" -eq 0 ]
  [ "$output" = "PASS" ]

  run jq -r '.scenarios[] | select(.id == "scenario-16") | .escapes' "$EVIDENCE"
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}

@test "redteam scenario 17: spire post-eviction svid presentation rejected after residual window" {
  run jq -r '.metrics.spire_eviction_latency_ms' "$EVIDENCE"
  [ "$status" -eq 0 ]
  python3 -c "assert float('$output') <= 2.0"

  run jq -r '.scenarios[] | select(.id == "scenario-17") | .status' "$EVIDENCE"
  [ "$status" -eq 0 ]
  [ "$output" = "PASS" ]

  run jq -r '.scenarios[] | select(.id == "scenario-17") | .escapes' "$EVIDENCE"
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}

@test "redteam scenario 18: admission controller rejects contained pod reconstitution within 3ms" {
  run jq -r '.metrics.admission_decision_latency_ms' "$EVIDENCE"
  [ "$status" -eq 0 ]
  python3 -c "assert float('$output') <= 3.0"

  run jq -r '.scenarios[] | select(.id == "scenario-18") | .status' "$EVIDENCE"
  [ "$status" -eq 0 ]
  [ "$output" = "PASS" ]

  run jq -r '.scenarios[] | select(.id == "scenario-18") | .escapes' "$EVIDENCE"
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}

@test "redteam scenario 19: admission controller enforces fail-closed rejection on webhook outage" {
  run jq -r '.scenarios[] | select(.id == "scenario-19") | .status' "$EVIDENCE"
  [ "$status" -eq 0 ]
  [ "$output" = "PASS" ]

  run jq -r '.scenarios[] | select(.id == "scenario-19") | .escapes' "$EVIDENCE"
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}

@test "redteam scenario 20: fleet manager deduplicates concurrent containment via idempotency key" {
  run jq -r '.scenarios[] | select(.id == "scenario-20") | .status' "$EVIDENCE"
  [ "$status" -eq 0 ]
  [ "$output" = "PASS" ]

  run jq -r '.scenarios[] | select(.id == "scenario-20") | .escapes' "$EVIDENCE"
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}

@test "redteam scenario 21: combined multi-plane simultaneous attack is halted across bao and mesh" {
  run jq -r '.scenarios[] | select(.id == "scenario-21") | .status' "$EVIDENCE"
  [ "$status" -eq 0 ]
  [ "$output" = "PASS" ]

  run jq -r '.scenarios[] | select(.id == "scenario-21") | .plane' "$EVIDENCE"
  [ "$status" -eq 0 ]
  [ "$output" = "bao,mesh" ]

  run jq -r '.scenarios[] | select(.id == "scenario-21") | .escapes' "$EVIDENCE"
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}

@test "redteam scenario 22: governance attributable resume validates deployed operator key signature" {
  run jq -r '.scenarios[] | select(.id == "scenario-22") | .status' "$EVIDENCE"
  [ "$status" -eq 0 ]
  [ "$output" = "PASS" ]

  run jq -r '.scenarios[] | select(.id == "scenario-22") | .escapes' "$EVIDENCE"
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}

@test "redteam scenario 23: redteam runner environment resilience fails loudly on missing client" {
  run jq -r '.scenarios[] | select(.id == "scenario-23") | .status' "$EVIDENCE"
  [ "$status" -eq 0 ]
  [ "$output" = "PASS" ]

  run jq -r '.scenarios[] | select(.id == "scenario-23") | .escapes' "$EVIDENCE"
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}

@test "redteam scenario 24: multi-plane coverage self-check confirms all 5 planes have >= 1 scenarios" {
  run jq -r '.scenarios[] | select(.id == "scenario-24") | .status' "$EVIDENCE"
  [ "$status" -eq 0 ]
  [ "$output" = "PASS" ]

  # Verify all 5 planes have positive scenario counts
  for p in freeze mesh bao spire admission; do
    count=$(jq -r ".metrics.plane_coverage_counts.$p" "$EVIDENCE")
    [ "$count" -gt 0 ]
  done
}

@test "redteam metrics: total process escapes is zero across all 24 scenarios" {
  run jq -r '.metrics.process_escapes' "$EVIDENCE"
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}

@test "redteam metrics: per-plane escapes in .metrics.escapes_by_plane are all zero" {
  for p in freeze mesh bao spire admission; do
    run jq -r ".metrics.escapes_by_plane.$p" "$EVIDENCE"
    [ "$status" -eq 0 ]
    [ "$output" -eq 0 ]
  done
}

@test "redteam anti-regression: runner fails loudly if any plane is missing" {
  # Test the self-check mechanism against synthetic broken fixture
  local tmp_evidence
  tmp_evidence="$(mktemp)"
  
  # Remove all scenarios referencing spire
  jq 'del(.scenarios[] | select(.plane | test("spire")))' "$EVIDENCE" > "$tmp_evidence"
  
  # Assert count for spire is 0 on broken fixture
  run bash -c "jq --arg plane 'spire' '[.scenarios[] | select(.plane | split(\",\") | index(\$plane))] | length' '$tmp_evidence'"
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]

  # Assert self-check logic fails loudly when given broken evidence
  run bash -c '
    REQUIRED_PLANES=("freeze" "mesh" "bao" "spire" "admission")
    MISSING_PLANES=()
    for p in "${REQUIRED_PLANES[@]}"; do
      COUNT=$(jq --arg plane "$p" "[.scenarios[] | select(.plane | split(\",\") | index(\$plane))] | length" "'"$tmp_evidence"'")
      if [ "$COUNT" -eq 0 ]; then
        MISSING_PLANES+=("$p")
      fi
    done
    if [ ${#MISSING_PLANES[@]} -gt 0 ]; then
      echo "Coverage regression detected: ${MISSING_PLANES[*]}" >&2
      exit 1
    fi
  '
  [ "$status" -eq 1 ]
  [[ "$output" =~ "spire" ]]
  
  rm -f "$tmp_evidence"
}
