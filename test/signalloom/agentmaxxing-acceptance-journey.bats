#!/usr/bin/env bats
# ==============================================================================
# AMXO-P6-3: Deterministic Local Onboarding-to-Removal Acceptance Journey Tests
# ==============================================================================

setup_file() {
    REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
    export REPO_ROOT
    export API_SRC="${REPO_ROOT}/d2-signalloom/apps/fe-signalloom/src"
    export JOURNEY_MODULE="tests.test_agentmaxxing_acceptance_journey"
}

@test "AMXO-P6-3 phase 1: attributable operator registration and one-time enrollment token issuance" {
    run env PYTHONPATH="${API_SRC}" python3 -m "${JOURNEY_MODULE}" --phase 1
    [ "$status" -eq 0 ]
    [[ "$output" =~ "PHASE_1_SUCCESS" ]]
}

@test "AMXO-P6-3 phase 2: one-time host enrollment key exchange, credential binding, and atomic single-use enforcement" {
    run env PYTHONPATH="${API_SRC}" python3 -m "${JOURNEY_MODULE}" --phase 2
    [ "$status" -eq 0 ]
    [[ "$output" =~ "PHASE_2_SUCCESS" ]]
}

@test "AMXO-P6-3 phase 3: audit session telemetry upload, hash chain validation, and evidence projection sanitization" {
    run env PYTHONPATH="${API_SRC}" python3 -m "${JOURNEY_MODULE}" --phase 3
    [ "$status" -eq 0 ]
    [[ "$output" =~ "PHASE_3_SUCCESS" ]]
}

@test "AMXO-P6-3 phase 4: denial falsification on tampered hash chain, sequence gap, and conflicting payload" {
    run env PYTHONPATH="${API_SRC}" python3 -m "${JOURNEY_MODULE}" --phase 4
    [ "$status" -eq 0 ]
    [[ "$output" =~ "PHASE_4_SUCCESS" ]]
}

@test "AMXO-P6-3 phase 5: independent host revocation and subsequent upload denial (403 host_revoked)" {
    run env PYTHONPATH="${API_SRC}" python3 -m "${JOURNEY_MODULE}" --phase 5
    [ "$status" -eq 0 ]
    [[ "$output" =~ "PHASE_5_SUCCESS" ]]
}

@test "AMXO-P6-3 e2e acceptance journey: complete onboarding-to-removal lifecycle execution" {
    run env PYTHONPATH="${API_SRC}" python3 -m "${JOURNEY_MODULE}" --phase all
    [ "$status" -eq 0 ]
    [[ "$output" =~ "ACCEPTANCE_JOURNEY_ALL_PHASES_SUCCESS" ]]
}
