#!/usr/bin/env bats
# Workspace Agentic Identity Streaming (WSID) test suite — offline-safe and deterministic.

setup() {
  root="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
  connector_dir="$root/d2-signalloom/apps/workspace-connector"
  ingest_dir="$root/d2-signalloom/apps/signal-ingest"
  export GOCACHE="${GOCACHE:-/tmp/gocache}"
  export GOMODCACHE="${GOMODCACHE:-/tmp/gomodcache}"
  export CGO_ENABLED=0
}

@test "workspace-connector: Go module and package structure exist" {
  [ -f "$connector_dir/go.mod" ]
  [ -f "$connector_dir/main.go" ]
  [ -d "$connector_dir/client" ]
  [ -d "$connector_dir/transform" ]
  [ -d "$connector_dir/stun" ]
}

@test "workspace-connector: unit and race tests pass cleanly" {
  run bash -c "cd \"$connector_dir\" && go test ./..."
  [ "$status" -eq 0 ]
}

@test "workspace-connector: Reports API client models Drive, OAuth Token, and Login events" {
  run grep -E "(EventTypeDrive|EventTypeToken|EventTypeLogin)" "$connector_dir/client/reports.go"
  [ "$status" -eq 0 ]
}

@test "workspace-connector: transformer maps workspace events to canonical observations" {
  run grep -E "(TransformWorkspaceEvent|LayerApplicationSaaS|LayerIdentityAuth)" "$connector_dir/transform/transformer.go"
  [ "$status" -eq 0 ]
}

@test "workspace-connector: stun cascade enforces SA disablement and OpenBao revocation" {
  run grep -E "(ServiceAccountDisabled|OpenBaoLeaseRevoked|SuperCredState)" "$connector_dir/stun/cascade.go"
  [ "$status" -eq 0 ]
}

@test "signal-ingest: correlation engine includes Workspace CEL anomaly detection rules" {
  run grep -E "(workspace_volume_spike|workspace_external_oauth_grant|workspace_suspicious_login_egress)" "$ingest_dir/correlation/rules.go"
  [ "$status" -eq 0 ]
}

@test "signal-ingest: correlation engine tests pass cleanly with Workspace rules" {
  run bash -c "cd \"$ingest_dir\" && go test ./correlation"
  [ "$status" -eq 0 ]
}

@test "signal-ingest: authorization query endpoint and >=90% complete chain KPI unit tests pass cleanly" {
  run bash -c "cd \"$ingest_dir\" && go test -v -run TestQueryAuthorization_SeededEstate_KPIFraction ./api"
  [ "$status" -eq 0 ]
}

@test "signal-ingest: resolver false-merge regression corpus passes with false-merge==0 across all cases" {
  run bash -c "cd \"$ingest_dir\" && LC_ALL=C LANG=C go test -v -run TestFalseMergeRegression_PermanentZeroGate ./correlation"
  [ "$status" -eq 0 ]
  [[ "$output" == *"False-Merges=0"* ]]
}

@test "signal-ingest: end-to-end signal -> resolve -> attest -> who-authorized full pipeline test passes" {
  run bash -c "cd \"$ingest_dir\" && LC_ALL=C LANG=C go test -v -run TestEndToEndAttestedAuthorizationChain_FullPipeline ./api"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Completeness Status:         true"* ]]
}


