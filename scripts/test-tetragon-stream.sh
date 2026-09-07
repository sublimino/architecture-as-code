#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# CRKC-P1-4 — end-to-end Tetragon telemetry stream harness.
#
# Proves the ingestion path offline: mock Tetragon gRPC server → real
# StreamClient → real normaliser → real bounded ring buffer → Prometheus
# metrics endpoint. No cluster, no Tetragon install, no kernel privileges.
#
# Usage:
#   scripts/test-tetragon-stream.sh [EVENT_COUNT]
#
# Exit status: 0 when every assertion holds, non-zero on the first failure.
#
# Writes docs/signalloom/evidence/tetragon-stream-proof.json when the run
# succeeds, unless TETRAGON_PROOF_OUT=none.

set -euo pipefail

# NOTE: no `set -u` interaction hazard here — this script does not source the
# Claude Code shell snapshot. But we deliberately do NOT use `set -o nounset`
# beyond what -u already gives, and every expansion below is defaulted.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOCK_DIR="${REPO_ROOT}/test/mocks"
EVENT_COUNT="${1:-1000}"
LATENCY_BUDGET_MS="${TETRAGON_LATENCY_BUDGET_MS:-500}"
PROOF_OUT="${TETRAGON_PROOF_OUT:-${REPO_ROOT}/docs/signalloom/evidence/tetragon-stream-proof.json}"

export CGO_ENABLED=0
export GOCACHE="${GOCACHE:-/tmp/gocache}"
export GOMODCACHE="${GOMODCACHE:-/tmp/gomodcache}"

WORKDIR=""
MOCK_PID=""

cleanup() {
  # Kill by explicit PID. `pkill -f tetragon_grpc_mock` would match this
  # script's own bash -c wrapper when run from an agent harness, and kill the
  # shell running the cleanup.
  if [[ -n "${MOCK_PID}" ]] && kill -0 "${MOCK_PID}" 2>/dev/null; then
    kill "${MOCK_PID}" 2>/dev/null || true
    wait "${MOCK_PID}" 2>/dev/null || true
  fi
  [[ -n "${WORKDIR}" && -d "${WORKDIR}" ]] && rm -rf "${WORKDIR}"
  return 0
}
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
info() { printf '  %s\n' "$*"; }

printf '=== Tetragon telemetry stream harness (CRKC-P1-4) ===\n'
printf 'events=%s latency_budget=%sms\n\n' "${EVENT_COUNT}" "${LATENCY_BUDGET_MS}"

# Short path: the mock listens on a unix socket, and sun_path caps at 108 bytes.
WORKDIR="$(mktemp -d /tmp/tgstream.XXXXXX)"
MOCK_BIN="${WORKDIR}/tetragon_grpc_mock"

printf '[1/5] building mock server\n'
( cd "${MOCK_DIR}" && go build -o "${MOCK_BIN}" . ) || fail "mock server did not build"
[[ -x "${MOCK_BIN}" ]] || fail "mock binary missing at ${MOCK_BIN}"
info "built ${MOCK_BIN}"

printf '[2/5] starting mock + self-consumer\n'
# Fully detached: setsid plus all three fds redirected. Without both, the child
# stays in this shell's session and keeps the harness's output stream open, so
# a caller waiting on this script never sees it settle.
setsid "${MOCK_BIN}" \
  -socket-dir "${WORKDIR}" \
  -events "${EVENT_COUNT}" \
  -mode mixed \
  -metrics-addr 127.0.0.1:0 \
  </dev/null >"${WORKDIR}/mock.out" 2>"${WORKDIR}/mock.err" &
MOCK_PID=$!

# Poll for readiness rather than sleeping. A fixed sleep is either too short
# (flaky) or too long (wasted); the METRICS line is the actual readiness signal.
METRICS_URL=""
for _ in $(seq 1 200); do
  if METRICS_URL="$(grep -m1 '^METRICS=' "${WORKDIR}/mock.out" 2>/dev/null | cut -d= -f2-)"; then
    [[ -n "${METRICS_URL}" ]] && break
  fi
  sleep 0.05
done
[[ -n "${METRICS_URL}" ]] || fail "mock never reported a metrics endpoint; stderr: $(cat "${WORKDIR}/mock.err" 2>/dev/null)"

SOCKET="$(grep -m1 '^SOCKET=' "${WORKDIR}/mock.out" | cut -d= -f2-)"
info "socket  ${SOCKET}"
info "metrics ${METRICS_URL}"

printf '[3/5] polling until tetragon_events_received_total > 0\n'
START_NS=$(date +%s%N)
RECEIVED=0
DEADLINE_NS=$(( START_NS + 30 * 1000000000 ))
while (( $(date +%s%N) < DEADLINE_NS )); do
  BODY="$(curl -sf --max-time 2 "${METRICS_URL}" 2>/dev/null || true)"
  if [[ -n "${BODY}" ]]; then
    RECEIVED="$(printf '%s\n' "${BODY}" | awk '/^tetragon_events_received_total /{print $2; exit}')"
    RECEIVED="${RECEIVED:-0}"
    (( RECEIVED > 0 )) && break
  fi
  sleep 0.01
done
FIRST_EVENT_NS=$(date +%s%N)
FIRST_EVENT_MS=$(( (FIRST_EVENT_NS - START_NS) / 1000000 ))

(( RECEIVED > 0 )) || fail "tetragon_events_received_total never exceeded 0"
info "first events observed after ${FIRST_EVENT_MS}ms (received=${RECEIVED})"

(( FIRST_EVENT_MS <= LATENCY_BUDGET_MS )) \
  || fail "first event took ${FIRST_EVENT_MS}ms, budget is ${LATENCY_BUDGET_MS}ms"

printf '[4/5] waiting for the full burst to drain\n'
DEADLINE_NS=$(( $(date +%s%N) + 60 * 1000000000 ))
BODY=""
while (( $(date +%s%N) < DEADLINE_NS )); do
  BODY="$(curl -sf --max-time 2 "${METRICS_URL}" 2>/dev/null || true)"
  RECEIVED="$(printf '%s\n' "${BODY}" | awk '/^tetragon_events_received_total /{print $2; exit}')"
  RECEIVED="${RECEIVED:-0}"
  (( RECEIVED >= EVENT_COUNT )) && break
  sleep 0.02
done

metric() { printf '%s\n' "${BODY}" | awk -v k="$1" '$1==k{print $2; exit}'; }

RECEIVED="$(metric tetragon_events_received_total)";      RECEIVED="${RECEIVED:-0}"
INGESTED="$(metric tetragon_flow_events_ingested_total)"; INGESTED="${INGESTED:-0}"
DROPPED="$(metric tetragon_events_dropped_total)";        DROPPED="${DROPPED:-0}"
ERRORS="$(metric tetragon_stream_errors_total)";          ERRORS="${ERRORS:-0}"
SKIPPED="$(metric tetragon_events_skipped_total)";        SKIPPED="${SKIPPED:-0}"

printf '[5/5] assertions\n'

# Every required series must be PRESENT, not merely non-zero. A metric that is
# absent and a metric that is zero both read as "0" from awk; checking the HELP
# line is what distinguishes them.
for m in tetragon_events_received_total tetragon_flow_events_ingested_total \
         tetragon_events_dropped_total tetragon_stream_errors_total \
         tetragon_events_skipped_total; do
  printf '%s\n' "${BODY}" | grep -q "^# HELP ${m} " || fail "metric ${m} is absent from /metrics"
  printf '%s\n' "${BODY}" | grep -q "^# TYPE ${m} counter$" || fail "metric ${m} has no counter TYPE line"
done
info "all five metric series present with HELP and TYPE"

(( RECEIVED == EVENT_COUNT )) || fail "received=${RECEIVED}, want exactly ${EVENT_COUNT}"
info "received  = ${RECEIVED}"

(( DROPPED == 0 )) || fail "dropped=${DROPPED} during a ${EVENT_COUNT}-event burst, want 0"
info "dropped   = ${DROPPED}"

(( INGESTED == EVENT_COUNT )) || fail "ingested=${INGESTED}, want ${EVENT_COUNT} (no data loss permitted)"
info "ingested  = ${INGESTED}"

(( ERRORS == 0 )) || fail "stream_errors=${ERRORS} on a clean run, want 0"
info "errors    = ${ERRORS}"
info "skipped   = ${SKIPPED}"

printf '\nPASS: %s events streamed, 0 dropped, 0 errors, first event in %sms\n' \
  "${RECEIVED}" "${FIRST_EVENT_MS}"

if [[ "${PROOF_OUT}" != "none" ]]; then
  mkdir -p "$(dirname "${PROOF_OUT}")"
  cat > "${PROOF_OUT}" <<JSON
{
  "card": "CRKC-P1-4",
  "artifact": "tetragon-stream-proof",
  "generated_by": "scripts/test-tetragon-stream.sh",
  "generated_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "commit": "$(git -C "${REPO_ROOT}" rev-parse HEAD 2>/dev/null || echo unknown)",
  "harness": {
    "mode": "offline",
    "producer": "test/mocks/tetragon_grpc_mock (ebpf.MockTetragonServer)",
    "transport": "grpc over unix socket, tetragon.FineGuidanceSensors/GetEvents",
    "protobuf_api": "github.com/cilium/tetragon/api v1.1.0",
    "consumer": "collectors/ebpf.StreamClient -> Normalizer -> RingBuffer"
  },
  "results": {
    "events_requested": ${EVENT_COUNT},
    "events_received": ${RECEIVED},
    "events_ingested": ${INGESTED},
    "events_dropped": ${DROPPED},
    "events_skipped": ${SKIPPED},
    "stream_errors": ${ERRORS},
    "first_event_latency_ms": ${FIRST_EVENT_MS},
    "latency_budget_ms": ${LATENCY_BUDGET_MS}
  },
  "assertions": {
    "all_metric_series_present": true,
    "zero_dropped_during_burst": true,
    "zero_stream_errors": true,
    "no_event_loss": true,
    "within_latency_budget": true
  },
  "enforcement_decoupling": {
    "manifest": "d2-signalloom/deploy/tetragon-agent-telemetry.yaml",
    "forbidden_verbs": ["Sigkill", "Override", "NotifyEnforcer", "Signal"],
    "guard": "test/tetragon-telemetry-stream.bats"
  },
  "verdict": "pass"
}
JSON
  printf 'evidence written: %s\n' "${PROOF_OUT}"
fi
