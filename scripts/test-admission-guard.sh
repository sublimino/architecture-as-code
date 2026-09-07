#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EVIDENCE_DIR="$REPO_ROOT/docs/signalloom/evidence"
EVIDENCE_FILE="$EVIDENCE_DIR/admission-guard-proof.json"
mkdir -p "$EVIDENCE_DIR"

echo "=== Testing node-capability-guard admission webhook ==="

# 1. Run unit test suite
echo "Running Go unit test suite..."
export GOROOT=/home/linuxbrew/.linuxbrew/opt/go/libexec
export PATH=/home/linuxbrew/.linuxbrew/bin:$PATH
(cd "$REPO_ROOT/d2-signalloom/apps/node-capability-guard" && go test -v ./...)

# 2. Build webhook binary
BIN="$REPO_ROOT/bin/node-capability-guard"
mkdir -p "$REPO_ROOT/bin"
(cd "$REPO_ROOT/d2-signalloom/apps/node-capability-guard" && go build -o "$BIN" cmd/main.go)

# 3. Start local daemon on ephemeral port
PORT=18443
"$BIN" -port "$PORT" &
GUARD_PID=$!
trap "kill -9 $GUARD_PID 2>/dev/null || true" EXIT

# Wait for server ready
for i in {1..30}; do
  if curl -s "http://127.0.0.1:$PORT/healthz" >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

# 4. Probe unconfined agent pod (must be REJECTED 403)
UNCONFINED_REVIEW='{"apiVersion":"admission.k8s.io/v1","kind":"AdmissionReview","request":{"uid":"probe-unconfined-01","object":{"apiVersion":"v1","kind":"Pod","metadata":{"name":"agent-unconfined","labels":{"signalloom.ai/agent":"true"}},"spec":{"containers":[{"name":"c","image":"alpine"}]}}}}'

RESP_UNCONFINED=$(curl -s -X POST "http://127.0.0.1:$PORT/validate" \
  -H "Content-Type: application/json" \
  -d "$UNCONFINED_REVIEW")

ALLOWED_UNCONFINED=$(echo "$RESP_UNCONFINED" | jq -r '.response.allowed')
CODE_UNCONFINED=$(echo "$RESP_UNCONFINED" | jq -r '.response.status.code')
MSG_UNCONFINED=$(echo "$RESP_UNCONFINED" | jq -r '.response.status.message')

echo "Probe 1 [unconfined]: allowed=$ALLOWED_UNCONFINED code=$CODE_UNCONFINED"
if [ "$ALLOWED_UNCONFINED" != "false" ] || [ "$CODE_UNCONFINED" != "403" ]; then
  echo "FAIL: expected unconfined agent pod to be rejected 403"
  exit 1
fi

# 5. Probe compliant agent pod (must be ALLOWED 200)
CONFINED_REVIEW='{"apiVersion":"admission.k8s.io/v1","kind":"AdmissionReview","request":{"uid":"probe-confined-01","object":{"apiVersion":"v1","kind":"Pod","metadata":{"name":"agent-confined","labels":{"signalloom.ai/agent":"true"}},"spec":{"nodeSelector":{"node.signalloom.ai/cgroup-v2":"true","node.signalloom.ai/landlock":"true"},"containers":[{"name":"c","image":"alpine"}]}}}}'

RESP_CONFINED=$(curl -s -X POST "http://127.0.0.1:$PORT/validate" \
  -H "Content-Type: application/json" \
  -d "$CONFINED_REVIEW")

ALLOWED_CONFINED=$(echo "$RESP_CONFINED" | jq -r '.response.allowed')
echo "Probe 2 [confined]: allowed=$ALLOWED_CONFINED"
if [ "$ALLOWED_CONFINED" != "true" ]; then
  echo "FAIL: expected compliant agent pod to be allowed"
  exit 1
fi

# 6. Verify Prometheus metrics
METRICS=$(curl -s "http://127.0.0.1:$PORT/metrics")
REJECTIONS=$(echo "$METRICS" | grep '^node_capability_rejections_total' | awk '{print $2}')
ADMISSIONS=$(echo "$METRICS" | grep '^node_capability_admissions_total' | awk '{print $2}')

echo "Metrics: rejections=$REJECTIONS admissions=$ADMISSIONS"
if [ "$REJECTIONS" -lt 1 ] || [ "$ADMISSIONS" -lt 1 ]; then
  echo "FAIL: metrics not incremented"
  exit 1
fi

# 7. Write evidence artifact
TIMESTAMP="$(date -u +%Y-%m-%TT%H:%M:%SZ)"
jq -n \
  --arg ts "$TIMESTAMP" \
  --arg msg "$MSG_UNCONFINED" \
  --argjson rej "$REJECTIONS" \
  --argjson adm "$ADMISSIONS" \
  '{
    timestamp: $ts,
    component: "node-capability-guard",
    task: "CRKC-P3-3",
    verdict: "pass",
    probes: {
      unconfined_rejected: {
        allowed: false,
        code: 403,
        message: $msg
      },
      compliant_admitted: {
        allowed: true,
        code: 200
      },
      metrics: {
        node_capability_rejections_total: $rej,
        node_capability_admissions_total: $adm
      }
    }
  }' > "$EVIDENCE_FILE" 

echo "✓ node-capability-guard proof written to $EVIDENCE_FILE"
