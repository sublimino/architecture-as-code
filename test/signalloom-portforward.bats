#!/usr/bin/env bats
# signalloom-portforward.bats — Test suite for durable systemd user port-forwarding service

setup() {
  REPO_ROOT="${BATS_TEST_DIRNAME}/.."
  UNIT_FILE="${REPO_ROOT}/d2-signalloom/infra/systemd/signalloom-portforward.service"
  DROPIN_EXAMPLE="${REPO_ROOT}/d2-signalloom/infra/systemd/signalloom-portforward.service.d/10-port-override.conf.example"
  MANAGE_SCRIPT="${REPO_ROOT}/scripts/manage-portforward-service.sh"
  VERIFY_SCRIPT="${REPO_ROOT}/scripts/verify-portforward-service.sh"
  DOC_FILE="${REPO_ROOT}/docs/signalloom/durable-port-forwarding.md"
  EVIDENCE_FILE="${REPO_ROOT}/docs/signalloom/evidence/portforward-service-proof.json"
}

@test "systemd unit definition exists and contains required properties" {
  [ -f "${UNIT_FILE}" ]
  grep -q "Description=Signal Loom Dashboard Local Port-Forward" "${UNIT_FILE}"
  grep -q "Restart=always" "${UNIT_FILE}"
  grep -q "RestartSec=3s" "${UNIT_FILE}"
  grep -q "Environment=KUBECONFIG=" "${UNIT_FILE}"
  grep -q "Environment=LOCAL_PORT=5173" "${UNIT_FILE}"
  grep -q "Environment=REMOTE_PORT=8080" "${UNIT_FILE}"
  grep -q "WantedBy=default.target" "${UNIT_FILE}"
}

@test "drop-in override example exists and is valid" {
  [ -f "${DROPIN_EXAMPLE}" ]
  grep -q "Environment=LOCAL_PORT=" "${DROPIN_EXAMPLE}"
}

@test "manage-portforward-service.sh exists and is executable" {
  [ -x "${MANAGE_SCRIPT}" ]
}

@test "verify-portforward-service.sh exists and is executable" {
  [ -x "${VERIFY_SCRIPT}" ]
}

@test "operational documentation exists and covers architecture and troubleshooting" {
  [ -f "${DOC_FILE}" ]
  grep -q "signalloom-portforward.service" "${DOC_FILE}"
  grep -q "manage-portforward-service.sh" "${DOC_FILE}"
  grep -q "Troubleshooting" "${DOC_FILE}"
}

@test "manage-portforward-service.sh help returns usage" {
  run "${MANAGE_SCRIPT}" help
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Usage:" ]]
  [[ "$output" =~ "install" ]]
  [[ "$output" =~ "status" ]]
}

@test "manage-portforward-service.sh status reports active service and HTTP 200" {
  run "${MANAGE_SCRIPT}" status
  [ "$status" -eq 0 ]
  [[ "$output" =~ "active (running)" ]]
  [[ "$output" =~ "HTTP 200 OK" ]]
}

@test "manage-portforward-service.sh logs displays recent entries" {
  run "${MANAGE_SCRIPT}" logs 5
  [ "$status" -eq 0 ]
}

@test "evidence proof artifact exists and passes schema validation" {
  [ -f "${EVIDENCE_FILE}" ]
  grep -q '"status": "PASSED"' "${EVIDENCE_FILE}"
  grep -q '"task": "CRKC-P2-3"' "${EVIDENCE_FILE}"
  grep -q '"http_code": 200' "${EVIDENCE_FILE}"
  grep -q '"auto_healed": true' "${EVIDENCE_FILE}"
}
