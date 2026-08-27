# shellcheck shell=bash
# agent-auto-claim.sh — auto-claim lifecycle for agent pods.
#
# Called by the OpenBao Agent sidecar's process_supervisor hook after the
# agent pod receives its SPIFFE SVID and OpenBao lease. Posts a claim
# request to Signal Loom's platform API and returns the claim_id.
#
# Usage:
#   source scripts/lib/agent-auto-claim.sh
#   claim_id=$(auto_claim_agent "pod-name" "namespace" "spiffe://..." "claude-code" "claude-sonnet-4")

# Default Signal Loom API endpoint — overridable for testing.
SIGNALLOOM_API="${SIGNALLOOM_API:-http://dashboard-signalloom.fe-signalloom.svc.cluster.local:5173}"

# auto_claim_agent <pod_name> <namespace> <spiffe_id> <harness> <model>
#
# Posts to /api/v1/agents/claim and prints the claim_id on success.
# Returns 0 on success, 1 on denial, 2 on error.
auto_claim_agent() {
  local pod_name="${1:?pod_name required}"
  local namespace="${2:?namespace required}"
  local spiffe_id="${3:?spiffe_id required}"
  local harness="${4:?harness required}"
  local model="${5:?model required}"
  local token_budget="${6:-0}"

  local payload
  payload=$(cat <<EOF
{
  "pod_name": "${pod_name}",
  "namespace": "${namespace}",
  "spiffe_id": "${spiffe_id}",
  "harness": "${harness}",
  "model": "${model}",
  "declared_tools": [],
  "token_budget_limit": ${token_budget}
}
EOF
  )

  local response http_code body
  response=$(curl -s -w '\n%{http_code}' \
    -X POST \
    -H "Content-Type: application/json" \
    -d "${payload}" \
    "${SIGNALLOOM_API}/api/v1/agents/claim" \
    --max-time 10 \
    2>/dev/null) || {
    echo >&2 "[auto-claim] ERROR: curl failed for ${pod_name}"
    return 2
  }

  http_code=$(echo "${response}" | tail -1)
  body=$(echo "${response}" | sed '$d')

  case "${http_code}" in
    200|201)
      local claim_id
      claim_id=$(echo "${body}" | grep -o '"claim_id":"[^"]*"' | cut -d'"' -f4)
      if [ -z "${claim_id}" ]; then
        echo >&2 "[auto-claim] ERROR: no claim_id in response for ${pod_name}"
        return 2
      fi
      echo "${claim_id}"
      return 0
      ;;
    403)
      echo >&2 "[auto-claim] DENIED: ${pod_name} — ${body}"
      return 1
      ;;
    *)
      echo >&2 "[auto-claim] ERROR: HTTP ${http_code} for ${pod_name} — ${body}"
      return 2
      ;;
  esac
}

# release_claim <claim_id>
#
# Releases a claim when the agent is shutting down.
# Returns 0 on success (including 404 — already released).
release_claim() {
  local claim_id="${1:?claim_id required}"

  local http_code
  http_code=$(curl -s -o /dev/null -w '%{http_code}' \
    -X DELETE \
    "${SIGNALLOOM_API}/api/v1/agents/claim/${claim_id}" \
    --max-time 10 \
    2>/dev/null) || {
    echo >&2 "[auto-claim] WARNING: curl failed releasing ${claim_id}"
    return 0  # best-effort — don't block shutdown
  }

  case "${http_code}" in
    200|204|404)
      return 0
      ;;
    *)
      echo >&2 "[auto-claim] WARNING: release returned HTTP ${http_code} for ${claim_id}"
      return 0  # best-effort
      ;;
  esac
}
