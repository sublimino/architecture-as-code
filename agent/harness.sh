#!/usr/bin/env bash
# Human-in-the-loop remediation harness (Phase 4 PoC).
#
# Default mode analyzes one CVE against the OSRAMP evidence and stops at a
# recommendation. Applying it requires an explicit --approve. The agent runs
# sandboxed under nono and both phases run under witness, so the audit trail
# (inputs, recommendation, approver, change) is signed evidence in Archivista.
#
# Usage:
#   agent/harness.sh [CVE-ID]             analyze and recommend (stops here)
#   agent/harness.sh [CVE-ID] --approve   apply the recommendation as a PR branch
#
# Requires Linux (WSL2 works): nono is kernel-enforced via Landlock.
set -euo pipefail

cd "$(dirname "$0")/.."

CVE="${1:-CVE-2022-32149}"
APPROVE="${2:-}"
NONO_PROFILE="${NONO_PROFILE:-always-further/claude-code}"
RUN_ID="agent-$(date +%s)"
RUN_DIR="agent/out/${RUN_ID}"

[ "$(uname -s)" = "Linux" ] || { echo "the harness needs Linux (nono uses Landlock); use WSL2"; exit 1; }
command -v nono >/dev/null || { echo "nono not installed: curl -fsSL https://nono.sh/install.sh | sh"; exit 1; }
command -v claude >/dev/null || { echo "claude CLI not installed"; exit 1; }
command -v witness >/dev/null || { echo "witness not installed"; exit 1; }
test -f .keys/witness.pem || { echo "run 'make signing-keys' first"; exit 1; }

mkdir -p "${RUN_DIR}/evidence"

kubectl -n backend port-forward svc/osramp-archivista 8082:8082 >/dev/null 2>&1 &
PORT_FORWARD_PID=$!
trap 'kill ${PORT_FORWARD_PID} 2>/dev/null || true' EXIT
sleep 2

echo "=== assembling the evidence bundle for ${CVE}"
cp vex/out/scans/*.baseline.json "${RUN_DIR}/evidence/" 2>/dev/null || true
cp vex/out/govulncheck-processor.txt "${RUN_DIR}/evidence/" 2>/dev/null || true
./scripts/fetch-vex.sh "${RUN_DIR}/evidence/current.openvex.json" 2>/dev/null || \
  echo "(no attested VEX in Archivista yet)"
ls "${RUN_DIR}/evidence" | sed 's/^/  evidence: /'

cat > "${RUN_DIR}/prompt.md" <<PROMPT
You are the remediation analysis agent for Acme Co.'s OSRAMP pipeline.
Analyze exactly one vulnerability: ${CVE}.

Evidence files are in ${RUN_DIR}/evidence: grype scan results (baseline
findings per image), govulncheck reachability output for the processor
service, and the current attested VEX status if present.

Respond with a single JSON object and nothing else:
{
  "cve": "${CVE}",
  "applicable": true|false,
  "recommendation": {
    "type": "dependency_bump" | "vex_not_affected",
    "service": "<listener|processor|archiver, when dependency_bump>",
    "module": "<go module path, when dependency_bump>",
    "version": "<fixed version, when dependency_bump>",
    "justification": "<openvex justification, when vex_not_affected>"
  },
  "reasoning": "<three sentences maximum, grounded in the evidence files>"
}

Rules: recommend vex_not_affected only if the evidence proves the vulnerable
code is not reachable or not present. Recommend dependency_bump only when a
fixed version exists. Do not recommend anything outside these two shapes.
PROMPT

echo "=== running the sandboxed analysis (nono profile: ${NONO_PROFILE})"
witness run --step agent-analysis \
  -o "${RUN_DIR}/agent-analysis.attestation.json" \
  -k .keys/witness.pem \
  --enable-archivista --archivista-server=http://localhost:8082 \
  -- bash -c "nono run --profile '${NONO_PROFILE}' -- \
       claude -p \"\$(cat '${RUN_DIR}/prompt.md')\" --output-format json \
       > '${RUN_DIR}/agent-response.json'"

jq -r '.result' "${RUN_DIR}/agent-response.json" > "${RUN_DIR}/recommendation.json"

echo
echo "=== recommendation"
jq . "${RUN_DIR}/recommendation.json"

if [ "${APPROVE}" != "--approve" ]; then
  echo
  echo "HUMAN GATE: nothing has been changed."
  echo "To apply: agent/harness.sh ${CVE} --approve"
  exit 0
fi

echo
echo "=== approval received; applying under witness"
TYPE=$(jq -r '.recommendation.type' "${RUN_DIR}/recommendation.json")
BRANCH="remediation/${CVE,,}"

case "${TYPE}" in
  dependency_bump)
    SERVICE=$(jq -r '.recommendation.service' "${RUN_DIR}/recommendation.json")
    MODULE=$(jq -r '.recommendation.module' "${RUN_DIR}/recommendation.json")
    VERSION=$(jq -r '.recommendation.version' "${RUN_DIR}/recommendation.json")
    case "${SERVICE}" in
      listener|processor|archiver) ;;
      *) echo "REJECTED: service '${SERVICE}' outside the allowed scope"; exit 1 ;;
    esac
    git checkout -b "${BRANCH}"
    witness run --step agent-remediation \
      -o "${RUN_DIR}/agent-remediation.attestation.json" \
      -k .keys/witness.pem \
      --enable-archivista --archivista-server=http://localhost:8082 \
      -- bash -c "cd d2-osramp-apps/apps/${SERVICE} && go get ${MODULE}@${VERSION} && go mod tidy"
    git add "d2-osramp-apps/apps/${SERVICE}/go.mod" "d2-osramp-apps/apps/${SERVICE}/go.sum"
    git commit -m "Bump ${MODULE} to ${VERSION} in ${SERVICE} to remediate ${CVE}

Agent-recommended, human-approved. Evidence: ${RUN_ID} in Archivista."
    ;;
  vex_not_affected)
    JUSTIFICATION=$(jq -r '.recommendation.justification' "${RUN_DIR}/recommendation.json")
    echo "VEX proposal: ${CVE} not_affected (${JUSTIFICATION})"
    echo "This is propose-only: a security team member issues the signed statement:"
    echo "  vexctl create --vuln='${CVE}' --status=not_affected --justification='${JUSTIFICATION}' ..."
    exit 0
    ;;
  *)
    echo "REJECTED: recommendation type '${TYPE}' outside the allowed scope"
    exit 1
    ;;
esac

if command -v gh >/dev/null && git remote get-url origin >/dev/null 2>&1; then
  git push -u origin "${BRANCH}"
  gh pr create --fill --title "Remediate ${CVE} (agent-assisted, human-approved)" \
    --body "Recommendation and evidence: run ${RUN_ID}, attested in Archivista (steps agent-analysis, agent-remediation)."
else
  echo "branch ${BRANCH} committed locally; push it and open a PR to complete the workflow"
fi

echo "audit artifacts: ${RUN_DIR}"
