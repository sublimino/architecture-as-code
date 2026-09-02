#!/usr/bin/env bats
# Signal Fusion V2 dynamic coverage and correlation engine tests — structural and offline-safe.

setup() {
  root="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
  ingest_dir="$root/d2-signalloom/apps/signal-ingest"
  dashboard_dir="$root/d2-signalloom/apps/dashboard-signalloom"
}

@test "signal-ingest: Go module and root structure exist" {
  [ -f "$ingest_dir/go.mod" ]
  [ -f "$ingest_dir/main.go" ]
  [ -d "$ingest_dir/store" ]
  [ -d "$ingest_dir/correlation" ]
  [ -d "$ingest_dir/collectors" ]
  [ -d "$ingest_dir/api" ]
  [ -d "$ingest_dir/model" ]
}

@test "signal-ingest: 7-layer unified signal model is defined" {
  run grep -E "(LayerNetwork|LayerIdentity|LayerSaaS|LayerEndpoint|LayerPipeline|LayerCloud|LayerBehavior)" "$ingest_dir/model/signal.go"
  [ "$status" -eq 0 ]
}

@test "signal-ingest: FrostDB columnar store implements pushdown filtering" {
  run grep -E "(frostdb|Pushdown|Scan|Query)" "$ingest_dir/store/frostdb.go"
  [ "$status" -eq 0 ]
}

@test "signal-ingest: non-blocking audit buffer prevents OpenBao deadlock" {
  run grep -E "(RingBuffer|NonBlocking|Drop|Buffer)" "$ingest_dir/audit/audit.go"
  [ "$status" -eq 0 ]
}

@test "signal-ingest: partitioned CEL correlation engine defines temporal window" {
  run grep -E "(cel\.Program|Evaluate|Window|Correlate)" "$ingest_dir/correlation/engine.go"
  [ "$status" -eq 0 ]
}

@test "signal-ingest: coverage endpoint and blind spot telemetry are defined" {
  run grep -E "(CoverageResponse|BlindSpot|handleCoverage)" "$ingest_dir/api/handlers.go"
  [ "$status" -eq 0 ]
}

@test "signal-ingest: SSE streaming handler with keepalive is defined" {
  run grep -E "(handleStream|text/event-stream|keepalive)" "$ingest_dir/api/handlers.go"
  [ "$status" -eq 0 ]
}

@test "dashboard: SignalFusionPage and WeavePage contain blind spot honesty telemetry" {
  run grep -E "(blind_spots|blindSpots|BlindSpot|coverage)" "$dashboard_dir/src/pages/SignalFusionPage.tsx"
  [ "$status" -eq 0 ]
  run grep -E "(blind_spots|blindSpots|BlindSpot|coverage)" "$dashboard_dir/src/pages/WeavePage.tsx"
  [ "$status" -eq 0 ]
}

@test "signal-ingest: unit and race tests pass cleanly" {
  run bash -c "cd \"$ingest_dir\" && go test ./..."
  [ "$status" -eq 0 ]
}

@test "dashboard: SignalFusion and Weave Vitest test suites pass cleanly" {
  run bash -c "cd \"$dashboard_dir\" && bun x vitest run src/pages/SignalFusionPage.test.tsx src/pages/WeavePage.test.tsx"
  [ "$status" -eq 0 ]
}
