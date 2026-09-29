#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# test/tetragon-telemetry-stream.bats — CRKC-P1-4
#
# Two halves, deliberately separated:
#
#   1. ENFORCEMENT DECOUPLING — static guards over the TracingPolicy manifests.
#      These are the tests that make "Tetragon is audit-only" a machine-checked
#      property rather than a claim in a comment. Adding a Sigkill to any policy
#      turns this suite red.
#
#   2. TELEMETRY STREAM — offline end-to-end verification through the real
#      generated protobuf service and a mock gRPC server.
#
# EVERY test here runs offline. There are no cluster-gated skips: a suite that
# skips its way to green is indistinguishable from a suite that passes, and this
# card's whole point is that the contract is provable before Tetragon exists.
# Live-cluster confirmation belongs to CRKC-P1-GOV.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  MANIFEST="${REPO_ROOT}/d2-signalloom/deploy/tetragon-agent-telemetry.yaml"
  HELM_VALUES="${REPO_ROOT}/d2-signalloom/deploy/tetragon-helm-values.yaml"
  EBPF_PKG="${REPO_ROOT}/d2-signalloom/apps/signal-ingest/collectors/ebpf"
  MOCK_DIR="${REPO_ROOT}/test/mocks"
  export CGO_ENABLED=0
  export GOPATH="${GOPATH:-/tmp/gopath}"
  export GOCACHE="${GOCACHE:-/tmp/gocache}"
  export GOMODCACHE="${GOMODCACHE:-/tmp/gomodcache}"
  export GONOSUMDB="${GONOSUMDB:-*}"
}

# ---------------------------------------------------------------------------
# 1. Enforcement decoupling — the anti-criteria
# ---------------------------------------------------------------------------

@test "tetragon manifest: exists and is valid YAML" {
  [ -f "$MANIFEST" ]
  run yq eval-all '.' "$MANIFEST"
  [ "$status" -eq 0 ]
}

@test "tetragon manifest: every document declares the cilium.io TracingPolicy API" {
  run grep -c 'kind: TracingPolicyNamespaced' "$MANIFEST"
  [ "$status" -eq 0 ]
  [ "$output" -ge 3 ]

  run grep -c 'apiVersion: cilium.io/v1alpha1' "$MANIFEST"
  [ "$status" -eq 0 ]
  [ "$output" -ge 3 ]
}

@test "tetragon manifest: sys_enter_execve tracepoint is present" {
  run grep -q 'sys_enter_execve' "$MANIFEST"
  [ "$status" -eq 0 ]
}

@test "tetragon manifest: tcp_connect kprobe is present" {
  run grep -q 'call: "tcp_connect"' "$MANIFEST"
  [ "$status" -eq 0 ]
}

@test "tetragon manifest: sys_enter_openat tracepoint is present" {
  run grep -q 'sys_enter_openat' "$MANIFEST"
  [ "$status" -eq 0 ]
}

# The count assertion matters as much as the presence one. A namespaced policy
# that lost its namespace would still contain the string "namespace:" via some
# other key; requiring one metadata.namespace per TracingPolicy document is what
# actually catches an unscoped cluster-wide trace.
@test "tetragon manifest: every TracingPolicy is namespace-scoped" {
  policies="$(grep -c 'kind: TracingPolicyNamespaced' "$MANIFEST")"

  run bash -c "yq eval-all -o=json '[.]' '$MANIFEST' | python3 -c '
import sys, json
docs = json.load(sys.stdin)
policies = [d for d in docs if d.get(\"kind\") == \"TracingPolicyNamespaced\"]
unscoped = [d[\"metadata\"].get(\"name\") for d in policies
            if not d.get(\"metadata\", {}).get(\"namespace\")]
if unscoped:
    print(\"UNSCOPED:\", unscoped)
    sys.exit(1)
print(f\"OK {len(policies)} namespaced policies\")
'"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "OK ${policies} namespaced policies" ]]
}

# ---------------------------------------------------------------------------
# The forbidden-verb guards.
#
# These read the PARSED YAML, not the file text. A text grep is wrong here in
# both directions, and the first cut of this suite proved it: the manifest's own
# header comment explains why `Sigkill` and `Override` are forbidden, so a bare
# `grep -c Sigkill` fired on the documentation that exists to prevent the thing
# it was searching for. And in the other direction, `Signal` appears in the
# words "signal-ingest", "Signal Loom", and "Signal Fusion" throughout.
#
# A guard that cries wolf gets deleted, and then the real check is gone. So the
# check walks the document tree and asserts on VALUES AT ACTION KEYS, which is
# what "this policy cannot enforce" actually means.
# ---------------------------------------------------------------------------

# forbidden_verb_scan walks every parsed document and prints one line per
# violation. Comments are invisible to it because yaml/json parser discards
# them; string values are visible because a matchAction is a string value.
forbidden_verb_scan() {
  yq eval-all -o=json '[.]' "$1" | python3 -c '
import sys, json

FORBIDDEN = {"sigkill", "override", "notifyenforcer", "signal", "post"}
ACTION_KEYS = {"action", "matchactions"}
violations = []

def walk(node, path):
    if isinstance(node, dict):
        for k, v in node.items():
            kl = str(k).lower()
            # Any matchActions block at all is a violation: an audit-only policy
            # has no reason to declare actions, and the default for a matched
            # selector is already "report the event".
            if kl == "matchactions":
                violations.append(f"{path}.{k} = matchActions block present")
            if kl in ACTION_KEYS and isinstance(v, str) and v.lower() in FORBIDDEN:
                violations.append(f"{path}.{k} = {v}")
            # An `enforcer` sensor is the other way to make a policy actionable.
            if kl == "enforcer":
                violations.append(f"{path}.{k} = enforcer sensor declared")
            walk(v, f"{path}.{k}")
    elif isinstance(node, list):
        for i, v in enumerate(node):
            walk(v, f"{path}[{i}]")

docs = [d for d in json.load(sys.stdin) if d]
if not docs:
    print("NO_DOCUMENTS_PARSED")
    sys.exit(2)

for d in docs:
    walk(d, d.get("metadata", {}).get("name", "?") + "/" + str(d.get("kind")))

for v in violations:
    print("VIOLATION:", v)
print(f"SCANNED {len(docs)} documents, {len(violations)} violations")
'
}

@test "tetragon manifest anti: no enforcement verb at any action key in any document" {
  run forbidden_verb_scan "$MANIFEST"
  [ "$status" -eq 0 ]
  [[ ! "$output" =~ "VIOLATION" ]]
  [[ "$output" =~ "0 violations" ]]
  # Assert the scanner actually parsed something. A scan of an empty or
  # unparseable file also reports zero violations, which is the shape of every
  # guard that passes because it never ran.
  [[ "$output" =~ "SCANNED 7 documents" ]]
}

# Falsification: the scanner must FAIL on a policy that does enforce. Without
# this, a scanner with a broken walk would report "0 violations" forever and the
# guard above would be decorative.
@test "tetragon manifest anti: the forbidden-verb scanner detects a planted Sigkill" {
  planted="${BATS_TEST_TMPDIR}/planted.yaml"
  cat > "$planted" <<'YAML'
apiVersion: cilium.io/v1alpha1
kind: TracingPolicyNamespaced
metadata:
  name: planted-enforcing-policy
  namespace: fe-signalloom-agents
spec:
  kprobes:
    - call: "tcp_connect"
      selectors:
        - matchActions:
            - action: Sigkill
YAML

  run forbidden_verb_scan "$planted"
  [[ "$output" =~ "VIOLATION" ]]
  [[ "$output" =~ "Sigkill" ]]
  [[ "$output" =~ "matchActions block present" ]]
}

# Belt and braces on the text form, with comments stripped. This catches an
# enforcement verb introduced somewhere the structural walk does not reach —
# for example inside a raw string blob in a ConfigMap.
@test "tetragon manifest anti: no enforcement verb in non-comment YAML text" {
  body="${BATS_TEST_TMPDIR}/nocomments.yaml"
  sed 's/[[:space:]]*#.*$//' "$MANIFEST" > "$body"

  for verb in Sigkill Override NotifyEnforcer matchActions; do
    run grep -c "$verb" "$body"
    [ "$output" -eq 0 ]
  done

  # Prove the comment-stripping did not simply empty the file, which would make
  # every assertion above vacuously true.
  run bash -c "grep -c 'kind: TracingPolicyNamespaced' '$body'"
  [ "$output" -ge 3 ]
}

@test "tetragon manifest: carries a machine-readable enforcement:disabled marker" {
  run grep -c 'signalloom.io/enforcement: disabled' "$MANIFEST"
  [ "$status" -eq 0 ]
  [ "$output" -ge 4 ]
}

@test "tetragon helm values: pin the export socket and disable rthooks" {
  [ -f "$HELM_VALUES" ]
  run grep -q '/var/run/cilium/tetragon/tetragon.sock' "$HELM_VALUES"
  [ "$status" -eq 0 ]

  run bash -c "yq -o=json '.' '$HELM_VALUES' | python3 -c '
import sys, json
v = json.load(sys.stdin)
assert v[\"rthooks\"][\"enabled\"] is False, \"rthooks must be disabled\"
assert v[\"tetragon\"][\"grpc\"][\"enabled\"] is True, \"grpc export must be enabled\"
assert v[\"tetragon\"][\"enablePolicyFilterCgroupMap\"] is False, \"cgroup map must stay off\"
print(\"OK\")
'"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "OK" ]]
}

# The socket path appears in three places that must never disagree: the Helm
# values, the ConfigMap contract, and the Go constant. Drift between them is
# silent — the collector dials a path nothing is listening on and reports a
# connection error that looks like Tetragon being down.
@test "tetragon: socket path agrees across helm values, ConfigMap, and Go constant" {
  run grep -q '/var/run/cilium/tetragon/tetragon.sock' "$HELM_VALUES"
  [ "$status" -eq 0 ]

  run grep -q 'exportSocket: "/var/run/cilium/tetragon/tetragon.sock"' "$MANIFEST"
  [ "$status" -eq 0 ]

  run grep -q 'DefaultSocketPath = "/var/run/cilium/tetragon/tetragon.sock"' "${EBPF_PKG}/client.go"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 2. Collector implementation
# ---------------------------------------------------------------------------

@test "tetragon collector: package builds under CGO_ENABLED=0" {
  cd "${REPO_ROOT}/d2-signalloom/apps/signal-ingest"
  run go build ./collectors/ebpf/...
  [ "$status" -eq 0 ]
}

@test "tetragon collector: protobuf API is pinned to v1.1.0 exactly" {
  run grep -E 'github.com/cilium/tetragon/api v1\.1\.0' \
    "${REPO_ROOT}/d2-signalloom/apps/signal-ingest/go.mod"
  [ "$status" -eq 0 ]
}

# A hand-rolled struct would make "parses Tetragon protobuf" vacuous. This
# asserts the collector consumes the genuine generated client.
@test "tetragon collector: uses the real generated FineGuidanceSensors client" {
  run grep -q 'tetragon.NewFineGuidanceSensorsClient' "${EBPF_PKG}/client.go"
  [ "$status" -eq 0 ]

  run grep -q 'github.com/cilium/tetragon/api/v1/tetragon' "${EBPF_PKG}/client.go"
  [ "$status" -eq 0 ]
}

@test "tetragon collector: go vet is clean" {
  cd "${REPO_ROOT}/d2-signalloom/apps/signal-ingest"
  run go vet ./collectors/ebpf/...
  [ "$status" -eq 0 ]
}

@test "tetragon collector: full unit suite passes with zero skips" {
  cd "${REPO_ROOT}/d2-signalloom/apps/signal-ingest"
  run go test ./collectors/ebpf/... -count=1 -v
  [ "$status" -eq 0 ]

  # A skipped test reads as a passing one in the summary line. Assert the
  # absence of skips explicitly, and assert a floor on the number that ran so a
  # suite that silently stopped loading cannot report green.
  run bash -c "cd '${REPO_ROOT}/d2-signalloom/apps/signal-ingest' && go test ./collectors/ebpf/... -count=1 -v | grep -c -- '--- SKIP'"
  [ "$output" -eq 0 ]

  run bash -c "cd '${REPO_ROOT}/d2-signalloom/apps/signal-ingest' && go test ./collectors/ebpf/... -count=1 -v | grep -c -- '--- PASS'"
  [ "$output" -ge 30 ]
}

@test "tetragon collector: metrics expose the two named counters plus drops" {
  run grep -q 'tetragon_flow_events_ingested_total' "${EBPF_PKG}/metrics.go"
  [ "$status" -eq 0 ]
  run grep -q 'tetragon_stream_errors_total' "${EBPF_PKG}/metrics.go"
  [ "$status" -eq 0 ]
  run grep -q 'tetragon_events_received_total' "${EBPF_PKG}/metrics.go"
  [ "$status" -eq 0 ]
  run grep -q 'tetragon_events_dropped_total' "${EBPF_PKG}/metrics.go"
  [ "$status" -eq 0 ]
}

# The bound is the control. An append without a capacity check is how a
# telemetry queue becomes a memory-exhaustion vector.
@test "tetragon collector anti: the flow queue is bounded, never append-grown" {
  run grep -c 'append(' "${EBPF_PKG}/ringbuffer.go"
  [ "$output" -eq 0 ]

  run grep -q 'make(\[\]\*netebpf.InboundFlowEvent, capacity)' "${EBPF_PKG}/ringbuffer.go"
  [ "$status" -eq 0 ]
}

@test "tetragon collector anti: does not modify the canonical InboundFlowEvent struct" {
  run git -C "$REPO_ROOT" diff --name-only HEAD -- \
    d2-signalloom/apps/signal-ingest/collectors/netebpf/collector.go
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# 3. Mock server module
# ---------------------------------------------------------------------------

@test "tetragon mock: standalone module builds" {
  cd "$MOCK_DIR"
  run go build -o /dev/null .
  [ "$status" -eq 0 ]
}

@test "tetragon mock: unit suite passes" {
  cd "$MOCK_DIR"
  run go test ./... -count=1 -v
  [ "$status" -eq 0 ]

  run bash -c "cd '$MOCK_DIR' && go test ./... -count=1 -v | grep -c -- '--- SKIP'"
  [ "$output" -eq 0 ]
}

@test "tetragon mock: reuses ebpf.MockTetragonServer rather than a second fake" {
  run grep -q 'ebpf.NewMockTetragonServer' "${MOCK_DIR}/tetragon_grpc_mock.go"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 4. End-to-end stream
# ---------------------------------------------------------------------------

@test "tetragon stream: end-to-end harness streams 1000 events with zero drops" {
  run env TETRAGON_PROOF_OUT=none "${REPO_ROOT}/scripts/test-tetragon-stream.sh" 1000
  [ "$status" -eq 0 ]
  [[ "$output" =~ "dropped   = 0" ]]
  [[ "$output" =~ "errors    = 0" ]]
  [[ "$output" =~ "received  = 1000" ]]
  [[ "$output" =~ "ingested  = 1000" ]]
}

@test "tetragon stream: container exec and curl events reach the flow pipeline within 500ms" {
  run env TETRAGON_PROOF_OUT=none TETRAGON_LATENCY_BUDGET_MS=500 \
    "${REPO_ROOT}/scripts/test-tetragon-stream.sh" 50
  [ "$status" -eq 0 ]
  [[ "$output" =~ "PASS: 50 events streamed" ]]
}

@test "tetragon stream: evidence artifact is produced with a pass verdict" {
  run "${REPO_ROOT}/scripts/test-tetragon-stream.sh" 100
  [ "$status" -eq 0 ]

  proof="${REPO_ROOT}/docs/signalloom/evidence/tetragon-stream-proof.json"
  [ -f "$proof" ]

  run python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
assert d['card']=='CRKC-P1-4', d['card']
assert d['verdict']=='pass', d['verdict']
assert d['results']['events_dropped']==0
assert d['results']['stream_errors']==0
assert d['results']['events_received']==d['results']['events_ingested']
assert d['harness']['protobuf_api'].endswith('v1.1.0')
print('OK')
" "$proof"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "OK" ]]
}

# ---------------------------------------------------------------------------
# 5. Documentation
# ---------------------------------------------------------------------------

@test "tetragon docs: pipeline documentation exists and covers the export contract" {
  doc="${REPO_ROOT}/docs/signalloom/tetragon-telemetry-pipeline.md"
  [ -f "$doc" ]
  for token in sys_enter_execve tcp_connect sys_enter_openat InboundFlowEvent \
               tetragon_flow_events_ingested_total tetragon.sock; do
    run grep -q "$token" "$doc"
    [ "$status" -eq 0 ]
  done
}

teardown_file() {
  git -C "$REPO_ROOT" checkout -- docs/signalloom/evidence/tetragon-stream-proof.json 2>/dev/null || true
}
