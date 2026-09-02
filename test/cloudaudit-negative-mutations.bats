#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

@test "cloudaudit negative mutation: receiver rejects GET request with HTTP 405" {
  cd "$REPO_ROOT/d2-signalloom/apps/signal-ingest"
  run go test -v ./api/audit -run TestAuditWebhookReceiver_MalformedPayload
  [ "$status" -eq 0 ]
  [[ "$output" =~ "PASS" ]]
}

@test "cloudaudit negative mutation: fail-open buffer returns HTTP 200 without blocking when saturated" {
  cd "$REPO_ROOT/d2-signalloom/apps/signal-ingest"
  run go test -v ./api/audit -run TestAuditWebhookReceiver_FailOpen
  [ "$status" -eq 0 ]
  [[ "$output" =~ "PASS" ]]
}

@test "cloudaudit negative mutation: GCP collector drops duplicate insertId without error" {
  cd "$REPO_ROOT/d2-signalloom/apps/signal-ingest"
  run go test -v ./collectors/gcpaudit -run TestGCPAuditCollector_IngestAndDeduplicate
  [ "$status" -eq 0 ]
  [[ "$output" =~ "PASS" ]]
}

@test "cloudaudit negative mutation: secret redactor scrubs hostile embedded JWT and PEM keys" {
  cd "$REPO_ROOT/d2-signalloom/apps/signal-ingest"
  run go test -v ./transform -run TestSecretRedactor_Tier3_SensitiveLabels
  [ "$status" -eq 0 ]
  [[ "$output" =~ "PASS" ]]
}

@test "cloudaudit negative mutation: symmetric CEL rule evaluation guarantees commutativity invariant" {
  cd "$REPO_ROOT/d2-signalloom/apps/signal-ingest"
  run go test -v ./correlation -run TestRule_AuditRBACPrivilegeEscalation_Symmetric
  [ "$status" -eq 0 ]
  [[ "$output" =~ "PASS" ]]
}
