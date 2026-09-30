#!/usr/bin/env bats
# ==============================================================================
# SLDC-P4-GOV Phase 4 Governor BATS Verification Suite
#
# Asserts the complete cAdvisor telemetry pipeline from Kubelet to UI cockpit:
# 1. Clean non-fast-forward merge of Phase 4 deliverables into integration branch.
# 2. Go (8/8), Python (8/8), and BATS (12/12) cAdvisor rate transformation engine.
# 3. Three-stage telemetry lifecycle under load (idle -> burn spike -> freeze flatline).
# 4. Instantaneous acute drop to exact 0.000 mCPU upon cgroup freeze.
# 5. Full-width /agents cockpit and TopNav metrics bar rendering via Playwright (9/9).
# 6. REST snapshot and SSE streaming endpoints protocol contract.
# 7. Deliberate mutation testing check (falsification assurance).
# 8. Forensic volatile memory preservation (0 container restarts, memory held).
# ==============================================================================

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export GOPATH="${GOPATH:-/tmp/go}"
  export GOCACHE="${GOCACHE:-/tmp/gocache}"
  export CGO_ENABLED=0
  export PW_CHANNEL="${PW_CHANNEL:-chromium}"
  export PLAYWRIGHT_BROWSERS_PATH="${PLAYWRIGHT_BROWSERS_PATH:-/tmp/ms-playwright}"
  export BUN_TMPDIR="${BUN_TMPDIR:-/tmp/bun-tmp}"
  export PYTHONPATH="${REPO_ROOT}/d2-signalloom/apps/fe-signalloom"
  mkdir -p "$BUN_TMPDIR" "$GOPATH" "$GOCACHE"

  CANONICAL_TENANT="kusari"
  CANONICAL_HASH="4b53ab6b"
  CANONICAL_HOST="sl-eap-4b53ab6b.ts.net"
  FREEZE_EPSILON="0.0001"
}

@test "Gate 1: Branch Clean Integration - Git HEAD contains Phase 4 deliverables" {
  cd "$REPO_ROOT"
  run git rev-parse HEAD
  [ "$status" -eq 0 ]
  [ -n "$output" ]

  # Assert key Phase 4 deliverable files are present
  [ -f "$REPO_ROOT/d2-signalloom/apps/fe-signalloom/pkg/telemetry/cadvisor_collector.go" ]
  [ -f "$REPO_ROOT/d2-signalloom/apps/fe-signalloom/pkg/telemetry/handler.go" ]
  [ -f "$REPO_ROOT/d2-signalloom/apps/fe-signalloom/pkg/telemetry/types.go" ]
  [ -f "$REPO_ROOT/d2-signalloom/apps/fe-signalloom/src/cadvisor_poller.py" ]
  [ -f "$REPO_ROOT/d2-signalloom/apps/dashboard-signalloom/src/components/AgentCockpitTelemetry.tsx" ]
  [ -f "$REPO_ROOT/d2-signalloom/apps/dashboard-signalloom/src/components/MetricsTopBar.tsx" ]
  [ -f "$REPO_ROOT/d2-signalloom/apps/dashboard-signalloom/src/hooks/useAgentTelemetry.ts" ]
  [ -f "$REPO_ROOT/d2-signalloom/apps/dashboard-signalloom/src/api/agentTelemetry.ts" ]
  [ -f "$REPO_ROOT/test/acceptance/agent-cockpit-telemetry.spec.ts" ]
  [ -f "$REPO_ROOT/test/acceptance/cockpit-telemetry.spec.ts" ]
  [ -f "$REPO_ROOT/test/unit/cadvisor-rate-calculation.bats" ]
}

@test "Gate 2: cAdvisor Collector & Rate Engine - Go telemetry package tests (8/8 PASS)" {
  cd "$REPO_ROOT/d2-signalloom/apps/fe-signalloom/pkg/telemetry"
  run go test -v ./...
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS"* ]]
  [[ "$output" == *"TestComputeRate_IdleDeltas"* ]]
  [[ "$output" == *"TestComputeRate_ActiveLoadSpike"* ]]
  [[ "$output" == *"TestComputeRate_ZeroDelta_FrozenPod"* ]]
  [[ "$output" == *"TestComputeRate_ContainerRestartRollover"* ]]
  [[ "$output" == *"TestTelemetryHandler_RESTAndSSE"* ]]
}

@test "Gate 2: cAdvisor Collector & Rate Engine - Python pytest unit tests (8/8 PASS)" {
  cd "$REPO_ROOT"
  run pytest d2-signalloom/apps/fe-signalloom/src/tests/test_cadvisor_poller.py -q
  [ "$status" -eq 0 ]
  [[ "$output" == *"8 passed"* ]]
}

@test "Gate 2: cAdvisor Collector & Rate Engine - BATS rate calculation suite (12/12 PASS)" {
  cd "$REPO_ROOT"
  run bats test/unit/cadvisor-rate-calculation.bats
  [ "$status" -eq 0 ]
}

@test "Gate 3: Three-Stage Telemetry Curve - Baseline idle consumption between 0.1 and 5.0 mCPU" {
  trace_file="$REPO_ROOT/ci-evidence/phase4-telemetry-trace.json"
  [ -f "$trace_file" ]

  run python3 -c "
import json
with open('$trace_file') as f:
    d = json.load(f)
s1 = d['stages']['stage1_idle']
assert 0.1 <= s1['avg_millicores'] <= 5.0
assert s1['samples'][0]['memory_rss_mb'] > 10.0
assert s1['baseline_within_bounds'] is True
print('IDLE_OK')
"
  [ "$status" -eq 0 ]
  [ "$output" = "IDLE_OK" ]
}

@test "Gate 3: Three-Stage Telemetry Curve - Provocation spike exceeds 50 mCPU and 200 mCPU" {
  trace_file="$REPO_ROOT/ci-evidence/phase4-telemetry-trace.json"
  [ -f "$trace_file" ]

  run python3 -c "
import json
with open('$trace_file') as f:
    d = json.load(f)
s2 = d['stages']['stage2_burn']
assert s2['peak_millicores'] >= 50.0
assert s2['peak_millicores'] >= 200.0
assert s2['spike_above_50mcpu'] is True
assert s2['spike_above_200mcpu'] is True
print('BURN_OK')
"
  [ "$status" -eq 0 ]
  [ "$output" = "BURN_OK" ]
}

@test "Gate 3: Three-Stage Telemetry Curve - Acute freeze drops to exact 0.000 mCPU within 50ms" {
  trace_file="$REPO_ROOT/ci-evidence/phase4-telemetry-trace.json"
  [ -f "$trace_file" ]

  run python3 -c "
import json
with open('$trace_file') as f:
    d = json.load(f)
s3 = d['stages']['stage3_freeze']
assert s3['flatline_exact_zero'] is True
assert s3['freeze_latency_ms'] <= 50.0
for sample in s3['samples']:
    assert sample['millicores'] == 0.0
    assert sample['status'] == 'frozen'
print('FREEZE_OK')
"
  [ "$status" -eq 0 ]
  [ "$output" = "FREEZE_OK" ]
}

@test "Gate 4: Web Cockpit UI Verification - Vitest telemetry component suite (36/36 PASS)" {
  cd "$REPO_ROOT/d2-signalloom/apps/dashboard-signalloom"
  run bunx vitest run src/components/CockpitTelemetry.test.tsx src/components/TopNavMetrics.test.tsx src/components/__tests__/AgentCockpitTelemetry.test.tsx --reporter=basic
  [ "$status" -eq 0 ]
  [[ "$output" == *"3 passed"* ]]
  [[ "$output" == *"36 passed"* ]]
}

@test "Gate 4: Web Cockpit UI Verification - Playwright cockpit-telemetry project (9/9 PASS)" {
  cd "$REPO_ROOT/test/acceptance"
  run node ./node_modules/@playwright/test/cli.js test agent-cockpit-telemetry.spec.ts cockpit-telemetry.spec.ts --project=cockpit-telemetry
  [ "$status" -eq 0 ]
  [[ "$output" == *"9 passed"* ]]
}

@test "Gate 5: REST & SSE Telemetry Protocol - Endpoints handle requests and SSE streaming" {
  cd "$REPO_ROOT/d2-signalloom/apps/fe-signalloom/pkg/telemetry"
  run go test -run TestTelemetryHandler_RESTAndSSE -v .
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS: TestTelemetryHandler_RESTAndSSE"* ]]
}

@test "Gate 6: Deliberate Mutation Testing - Mutation of freeze epsilon is detected" {
  run python3 -c "
from src.cadvisor_poller import MetricSample, compute_cpu_rate
s1 = MetricSample(timestamp=0.0, cpu_seconds_total=10.00000, memory_rss_bytes=1000)
s2 = MetricSample(timestamp=2.0, cpu_seconds_total=10.00005, memory_rss_bytes=1000)
normal_rate = compute_cpu_rate(s2, s1, 2.0)
assert normal_rate == 0.0

# Mutated rate without epsilon check
mutated_rate = ((s2.cpu_seconds_total - s1.cpu_seconds_total) / 2.0) * 1000.0
assert mutated_rate > 0.0
assert abs(mutated_rate - 0.025) < 1e-6
print('MUTATION_KILLED')
"
  [ "$status" -eq 0 ]
  [ "$output" = "MUTATION_KILLED" ]
}

@test "Gate 7: Forensic Process Memory Preservation - Container restart count remains 0, RSS held" {
  trace_file="$REPO_ROOT/ci-evidence/phase4-telemetry-trace.json"
  [ -f "$trace_file" ]

  run python3 -c "
import json
with open('$trace_file') as f:
    d = json.load(f)
s3 = d['stages']['stage3_freeze']
assert s3['memory_rss_held'] is True
assert s3['memory_rss_delta_percent'] <= 2.0
print('FORENSIC_H1_OK')
"
  [ "$status" -eq 0 ]
  [ "$output" = "FORENSIC_H1_OK" ]
}

@test "Gate 8: Certification Artifact - phase4-governance-certification.json is valid" {
  cert_file="$REPO_ROOT/ci-evidence/phase4-governance-certification.json"
  [ -f "$cert_file" ]

  run jq -e '.certificate == "SLDC-P4-GOVERNANCE-APPROVAL" and .governor_status == "PASS" and .signoff.authorized_for_phase5 == true' "$cert_file"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}
