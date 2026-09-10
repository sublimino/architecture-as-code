#!/usr/bin/env bash
# scripts/run-adversarial-suite.sh
# Multi-agent cascade adversarial red-team execution harness.
# Asserts 100% detection rate across 24 attack scenarios and false-merge == 0 invariant.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SIGNAL_INGEST_DIR="${REPO_ROOT}/d2-signalloom/apps/signal-ingest"

echo "======================================================================"
echo " SFAS MULTI-AGENT CASCADE ADVERSARIAL RED-TEAM SUITE"
echo "======================================================================"
echo "Repo Root:        ${REPO_ROOT}"
echo "Signal Ingest:    ${SIGNAL_INGEST_DIR}"
echo "Timestamp:        $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "======================================================================"

export GOROOT="${GOROOT:-/usr/lib/go-1.24}"
export PATH="${GOROOT}/bin:${PATH}"
export GOPATH="${GOPATH:-/home/andy/go}"
export GOCACHE="${GOCACHE:-/tmp/gocache}"
export GOMODCACHE="${GOMODCACHE:-/tmp/gomodcache}"
export CGO_ENABLED=0

cd "${SIGNAL_INGEST_DIR}"

echo ""
echo "--- [1/4] Running Correlation Cascade Adversarial Engine (24 Scenarios) ---"
go test ./correlation/ -run TestCascadeAdversarial -v -count=1

echo ""
echo "--- [2/4] Running API Adversarial Cascade 5-Vector Test Suite ---"
go test ./api/ -run TestAdversarialCascade -v -count=1

echo ""
echo "--- [3/4] Running Sustained Adversarial Load Assertion (1,000 Req/s) ---"
go test ./api/ -run TestAdversarialSustainedLoad -v -count=1

echo ""
echo "--- [4/4] Validating Machine-Readable Ceiling Artifact ---"
CEILING_FILE="${SIGNAL_INGEST_DIR}/correlation/redteam_cascade_ceiling.json"
if [[ ! -f "${CEILING_FILE}" ]]; then
    echo "ERROR: Ceiling artifact missing: ${CEILING_FILE}" >&2
    exit 1
fi

python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)

total_injected = data.get("total_injected", 0)
total_caught = data.get("total_caught", 0)
false_merges = data.get("false_merges", -1)
resolution_rate = data.get("resolution_rate", 0.0)

print(f"Artifact Check: total_injected={total_injected}, total_caught={total_caught}, false_merges={false_merges}, resolution_rate={resolution_rate:.2%}")

if false_merges != 0:
    print(f"CRITICAL FAILURE: false_merges is non-zero ({false_merges})!", file=sys.stderr)
    sys.exit(1)

if total_injected != total_caught or total_injected < 24:
    print(f"FAILURE: expected at least 24 caught cases, got {total_caught}/{total_injected}", file=sys.stderr)
    sys.exit(1)

print("Machine-readable ceiling validated: false-merge == 0 invariant preserved.")
' "${CEILING_FILE}"

echo ""
echo "======================================================================"
echo " ALL ADVERSARIAL CASCADE ASSERTIONS PASSED (false-merge == 0)"
echo "======================================================================"
