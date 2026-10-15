#!/usr/bin/env bats
#
# SLCO-P2-4: Automated verification of H2 tenant readiness checklist.
# Tests scripts/verify-tenant-readiness.sh across positive, negative, and edge cases.
#
# @id     verify-tenant-readiness-bats
# @target scripts/verify-tenant-readiness.sh
# @task   SLCO-P2-4

setup() {
  repo_root="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
  script="${repo_root}/scripts/verify-tenant-readiness.sh"
}

@test "verify-tenant-readiness: offline positive run exits 0 with RESULT PASS" {
  run "${script}" --tenant kusari --offline
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"PASS: [tenant_existence] authoritative tenant 'kusari' active (derived hash: 4b53ab6b)"* ]]
  [[ "${output}" == *"PASS: [tenant_isolation]"* ]]
  [[ "${output}" == *"PASS: [host_autoclaim]"* ]]
  [[ "${output}" == *"PASS: [telemetry_arrival]"* ]]
  [[ "${output}" == *"PASS: [known_issues]"* ]]
  [[ "${output}" == *"PASS: [support_routing]"* ]]
  [[ "${output}" == *"PASS: [ingress_perimeter]"* ]]
  [[ "${output}" == *"RESULT PASS (7 checks: 7 passed, 0 failed)"* ]]
}

@test "verify-tenant-readiness: missing --tenant option exits 2" {
  run "${script}" --offline
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"ERROR: Missing mandatory option: --tenant"* ]]
}

@test "verify-tenant-readiness: unknown option exits 2" {
  run "${script}" --tenant kusari --invalid-flag
  [ "${status}" -eq 2 ]
  [[ "${output}" == *"ERROR: Unknown option: --invalid-flag"* ]]
}

@test "verify-tenant-readiness: nonexistent known-issues file fails check and exits 1" {
  run "${script}" --tenant kusari --offline --known-issues "${BATS_TEST_TMPDIR}/nonexistent.json"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"FAIL: [known_issues] known issues file not found"* ]]
  [[ "${output}" == *"RESULT FAIL"* ]]
}

@test "verify-tenant-readiness: invalid json in known-issues file fails check and exits 1" {
  echo "not-json" > "${BATS_TEST_TMPDIR}/bad_issues.json"
  run "${script}" --tenant kusari --offline --known-issues "${BATS_TEST_TMPDIR}/bad_issues.json"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"FAIL: [known_issues] known issues file contains invalid JSON"* ]]
  [[ "${output}" == *"RESULT FAIL"* ]]
}

@test "verify-tenant-readiness: valid known-issues and support-route files pass cleanly" {
  echo '{"issues": []}' > "${BATS_TEST_TMPDIR}/good_issues.json"
  cat <<'EOF' > "${BATS_TEST_TMPDIR}/good_support.json"
{
  "contact": "support@kusari.test",
  "first_responder": "alice@signalloom.test",
  "fixer": "bob@signalloom.test",
  "cover": "charlie@signalloom.test",
  "test_ticket_acknowledged": true
}
EOF

  run "${script}" --tenant kusari --offline \
    --known-issues "${BATS_TEST_TMPDIR}/good_issues.json" \
    --support-route "${BATS_TEST_TMPDIR}/good_support.json"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"PASS: [known_issues] known issues artifact verified (0 tracked issues, zero unowned)"* ]]
  [[ "${output}" == *"PASS: [support_routing] support routing verified (contact, first responder, fixer, cover confirmed)"* ]]
  [[ "${output}" == *"RESULT PASS"* ]]
}

@test "verify-tenant-readiness: support-route missing required responder fields fails check and exits 1" {
  echo '{"contact": "only-contact@test.local"}' > "${BATS_TEST_TMPDIR}/incomplete_support.json"
  run "${script}" --tenant kusari --offline --support-route "${BATS_TEST_TMPDIR}/incomplete_support.json"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"FAIL: [support_routing] support route file missing required responder fields"* ]]
  [[ "${output}" == *"RESULT FAIL"* ]]
}

@test "verify-tenant-readiness: structured json output flag generates valid json report" {
  run "${script}" --tenant kusari --offline --json
  [ "${status}" -eq 0 ]
  # Validate JSON using python
  echo "${output}" | python3 -c '
import json, sys
data = json.load(sys.stdin)
assert data["tenant"] == "kusari"
assert data["result"] == "PASS"
assert data["failed_checks"] == 0
assert data["total_checks"] == 7
'
}
