#!/usr/bin/env bats
# test/sfas-p1-2-nono-ingest.bats — SFAS-P1-2 Live Signed Audit Session Ingestion Tests

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  KUBECONFIG_PATH="${KUBECONFIG:-${REPO_ROOT}/.kind/kubeconfig}"
  if [ -f "${KUBECONFIG_PATH}" ]; then
    export KUBECONFIG="${KUBECONFIG_PATH}"
  fi
  AGENT_NS="fe-signalloom-agents"
  SIGNAL_INGEST_DIR="${REPO_ROOT}/d2-signalloom/apps/signal-ingest"
}

@test "sfas-p1-2: agentnono collector unit tests pass" {
  cd "$SIGNAL_INGEST_DIR"
  run env GOCACHE=/tmp/gocache GOMODCACHE=/tmp/gomodcache CGO_ENABLED=0 go test -v ./collectors/agentnono/...
  [ "$status" -eq 0 ]
  [[ "$output" =~ "PASS" ]]
}

@test "sfas-p1-2: collector falsification and mode matrix include agentnono collector" {
  cd "$SIGNAL_INGEST_DIR"
  run env GOCACHE=/tmp/gocache GOMODCACHE=/tmp/gomodcache CGO_ENABLED=0 go test -v ./collectors -run 'TestCollectorFalsification_AgentNono|TestCollectorMatrix'
  [ "$status" -eq 0 ]
  [[ "$output" =~ "TestCollectorFalsification_AgentNono" ]]
  [[ "$output" =~ "PASS" ]]
}

@test "sfas-p1-2: ringbuffer enforces drop-tail semantics under saturation" {
  cd "$SIGNAL_INGEST_DIR"
  run env GOCACHE=/tmp/gocache GOMODCACHE=/tmp/gomodcache CGO_ENABLED=0 go test -v ./collectors/agentnono -run TestRingBuffer_SaturationDropTail
  [ "$status" -eq 0 ]
  [[ "$output" =~ "PASS" ]]
}

@test "sfas-p1-2: detached SPIFFE signature verifier rejects tampered session events" {
  cd "$SIGNAL_INGEST_DIR"
  run env GOCACHE=/tmp/gocache GOMODCACHE=/tmp/gomodcache CGO_ENABLED=0 go test -v ./collectors/agentnono -run 'TestVerifier_TamperedSignatureRejection|TestVerifier_DigestChainBreakage'
  [ "$status" -eq 0 ]
  [[ "$output" =~ "PASS" ]]
}

@test "sfas-p1-2: nono audit HTTP ingestion endpoint validates payload and updates metrics" {
  cd "$SIGNAL_INGEST_DIR"
  run env GOCACHE=/tmp/gocache GOMODCACHE=/tmp/gomodcache CGO_ENABLED=0 go test -v ./api -run TestHandleNonoAuditIngest
  [ "$status" -eq 0 ]
  [[ "$output" =~ "PASS" ]]
}

@test "sfas-p1-2: fe-signalloom-agents pod agent-nono-evidenced emits canonical telemetry with SPIFFE ID" {
  # Query pod logs without using exec probes
  run kubectl logs -n "$AGENT_NS" -l signalloom.ai/agent-name=agent-nono-evidenced --tail=50
  [ "$status" -eq 0 ]
  [[ "$output" =~ "spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/agent-nono-evidenced" ]]
  [[ "$output" =~ "agent-nono-evidenced" ]]
}
