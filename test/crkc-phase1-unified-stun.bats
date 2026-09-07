#!/usr/bin/env bats
# test/crkc-phase1-unified-stun.bats
# Unified Phase 1 Governor verification suite:
# Integrates Tier 0 (cgroup freezer, TC eBPF) + Tier 1 (Flux drift ignore, Tetragon telemetry)

DECLARED_TESTS=10

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
}

@test "unified-p1: flux selective drift ignore rules are valid RFC 6901 pointers" {
  run bash "${REPO_ROOT}/scripts/lint-flux-ignore-rfc6901.sh"
  [ "$status" -eq 0 ]
}

@test "unified-p1: flux dynamic labels checker passes on all managed paths" {
  run bash "${REPO_ROOT}/scripts/check-flux-dynamic-labels.sh"
  [ "$status" -eq 0 ]
}

@test "unified-p1: stun-sentinel binary builds statically and compiles cleanly" {
  export PATH=/usr/bin:$PATH
  run bash -c "cd ${REPO_ROOT}/d2-signalloom/apps/stun-sentinel && CGO_ENABLED=0 go build -o /dev/null ./cmd/stun-sentinel"
  [ "$status" -eq 0 ]
}

@test "unified-p1: stun-tcctl binary builds cleanly" {
  export PATH=/usr/bin:$PATH
  run bash -c "cd ${REPO_ROOT}/d2-signalloom/apps/stun-sentinel && go build -o /dev/null ./cmd/stun-tcctl"
  [ "$status" -eq 0 ]
}

@test "unified-p1: cgroup-v2 freeze proof artifact satisfies sub-50ms halting gate" {
  local proof="${REPO_ROOT}/docs/signalloom/evidence/cgroup-freeze-proof.json"
  [ -f "$proof" ]
  [ "$(jq -r '.overall' "$proof")" = "pass" ]
  local latency
  latency="$(jq -r '.measurements.freeze_latency_ms' "$proof")"
  awk -v l="$latency" 'BEGIN{exit !(l < 50)}'
  [ "$(jq -r '.measurements.cpu_usec_frozen' "$proof")" -eq 0 ]
}

@test "unified-p1: host-side TC eBPF packet severance proof satisfies sub-100ms activation gate" {
  local proof="${REPO_ROOT}/docs/signalloom/evidence/tc-drop-proof.json"
  [ -f "$proof" ]
  local reported
  reported="$(jq -r '.live_severance_proof.severance.isolate_reported_ms' "$proof")"
  awk -v r="$reported" 'BEGIN{exit !(r < 100)}'
  [ "$(jq -r '.live_severance_proof.conntrack.entries_after' "$proof")" -eq 0 ]
  [ "$(jq -r '.live_severance_proof.severance.post_isolate_reachable' "$proof")" = "false" ]
}

@test "unified-p1: tetragon telemetry pipeline proof satisfies zero drop and latency SLA" {
  local proof="${REPO_ROOT}/docs/signalloom/evidence/tetragon-stream-proof.json"
  [ -f "$proof" ]
  [ "$(jq -r '.verdict' "$proof")" = "pass" ]
  [ "$(jq -r '.results.events_dropped' "$proof")" -eq 0 ]
  local lat
  lat="$(jq -r '.results.first_event_latency_ms' "$proof")"
  awk -v l="$lat" 'BEGIN{exit !(l < 500)}'
}

@test "unified-p1: tetragon deployment manifests contain zero forbidden blocking verbs" {
  local manifest="${REPO_ROOT}/d2-signalloom/deploy/tetragon-agent-telemetry.yaml"
  [ -f "$manifest" ]
  local body="${BATS_TEST_TMPDIR}/nocomments.yaml"
  sed 's/[[:space:]]*#.*$//' "$manifest" > "$body"
  for verb in Sigkill Override NotifyEnforcer matchActions; do
    run grep -c "$verb" "$body"
    [ "$output" -eq 0 ]
  done
}

@test "unified-p1: combined containment latency is strictly sub-second (< 1000ms)" {
  local cgroup_proof="${REPO_ROOT}/docs/signalloom/evidence/cgroup-freeze-proof.json"
  local tc_proof="${REPO_ROOT}/docs/signalloom/evidence/tc-drop-proof.json"
  local freeze_ms
  local tc_ms
  freeze_ms="$(jq -r '.measurements.freeze_latency_ms' "$cgroup_proof")"
  tc_ms="$(jq -r '.live_severance_proof.severance.isolate_reported_ms' "$tc_proof")"
  awk -v f="$freeze_ms" -v t="$tc_ms" 'BEGIN{total = f + t; exit !(total < 1000)}'
}

@test "unified-p1: test suite arity matches declared count" {
  local count
  count="$(grep -c "^@test " "${BATS_TEST_FILENAME}")"
  [ "$count" -eq "$DECLARED_TESTS" ]
}
