#!/usr/bin/env bash
# ==============================================================================
# Signal Loom - Production External Agent Onboarding Helper
# ==============================================================================
# Performs end-to-end registration, token issuance, host enrollment, and
# inventory verification against Signal Loom sovereign infrastructure.
# ==============================================================================
set -euo pipefail

NODE_IP="${SIGNAL_LOOM_NODE_IP:-172.18.0.5}"
NODE_PORT="${SIGNAL_LOOM_NODE_PORT:-31436}"
HOST_HEADER="${SIGNAL_LOOM_HOST:-dashboard.osramp.acme.local}"
BASE_URL="https://${HOST_HEADER}:${NODE_PORT}"
DEX_USER="${SIGNAL_LOOM_USER:-demo-user@signalloom.local}"
DEX_PASS="${SIGNAL_LOOM_PASS:-demo-user}"

RANDOM_SUFFIX="$(head /dev/urandom | tr -dc 'a-z0-9' | head -c 6)"
AGENT_ID="${1:-agent-test-${RANDOM_SUFFIX}}"
HOST_ID="${2:-host-test-${RANDOM_SUFFIX}}"
MODEL="${3:-claude-3-5-sonnet}"
BUDGET="${4:-100000}"

echo "======================================================================"
echo " Signal Loom External Agent Onboarding"
echo " Target API: ${BASE_URL} (resolve to ${NODE_IP})"
echo " Agent ID:   ${AGENT_ID}"
echo " Host ID:    ${HOST_ID}"
echo " Model:      ${MODEL}"
echo "======================================================================"

# Helper for curl with SNI resolve
sl_curl() {
  curl -sk --resolve "${HOST_HEADER}:${NODE_PORT}:${NODE_IP}" "$@"
}

# 1. Authenticate with Dex OIDC
echo -n "[1/5] Authenticating operator (${DEX_USER})... "
AUTH_RESP="$(sl_curl "${BASE_URL}/dex/token" \
  -u "signalloom-dashboard:" \
  -d "grant_type=password&username=${DEX_USER}&password=${DEX_PASS}&scope=openid%20profile%20email%20audience:server:client_id:signalloom-api")"

OPERATOR_TOKEN="$(echo "${AUTH_RESP}" | jq -r .access_token)"
if [[ -z "${OPERATOR_TOKEN}" || "${OPERATOR_TOKEN}" == "null" ]]; then
  echo "FAILED"
  echo "Auth response: ${AUTH_RESP}"
  exit 1
fi
echo "SUCCESS"

# 2. Register External Agent
echo -n "[2/5] Registering external agent (${AGENT_ID})... "
REG_RESP="$(sl_curl "${BASE_URL}/api/v1/external-agents/register" \
  -H "Authorization: Bearer ${OPERATOR_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{
    \"agent_id\": \"${AGENT_ID}\",
    \"host_id\": \"${HOST_ID}\",
    \"host_os\": \"debian-12\",
    \"runtime_profile\": \"nono-0.73.0-standard\",
    \"allocated_token_budget\": ${BUDGET},
    \"metadata\": {\"onboarded_by\": \"cli-script\", \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}
  }")"

REG_STATUS="$(echo "${REG_RESP}" | jq -r '.enrollment_status // empty')"
if [[ "${REG_STATUS}" != "pending" ]]; then
  echo "FAILED"
  echo "Registration response: ${REG_RESP}"
  exit 1
fi
echo "SUCCESS (Status: pending)"

# 3. Issue One-Time Enrollment Token
echo -n "[3/5] Issuing enrollment token... "
TOKEN_RESP="$(sl_curl "${BASE_URL}/api/v1/external-agents/registrations/${AGENT_ID}/token" \
  -H "Authorization: Bearer ${OPERATOR_TOKEN}" \
  -H "Content-Type: application/json" \
  -X POST)"

ENROLLMENT_TOKEN="$(echo "${TOKEN_RESP}" | jq -r '.enrollment_token // empty')"
if [[ -z "${ENROLLMENT_TOKEN}" || "${ENROLLMENT_TOKEN}" == "null" ]]; then
  echo "FAILED"
  echo "Token response: ${TOKEN_RESP}"
  exit 1
fi
echo "SUCCESS"

# 4. Redeem Token & Enroll Host
echo -n "[4/5] Enrolling host with cryptographic identity... "
ENROLL_RESP="$(sl_curl "${BASE_URL}/api/v1/external-agents/enroll" \
  -H "Authorization: Bearer ${ENROLLMENT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{
    \"schema_version\": \"1.0.0\",
    \"agent_id\": \"${AGENT_ID}\",
    \"host_id\": \"${HOST_ID}\",
    \"key_id\": \"host-key:${AGENT_ID}\",
    \"key_algorithm\": \"Ed25519\",
    \"public_key\": \"A6EHv_POEL4dcN0Y50vAmWfk1jCbpQ1fHdyGZBJVMbg\",
    \"client_nonce\": \"bm9uY2UtMDAwMDAwMDAwMDAx\",
    \"credential_kind\": \"existing-mtls-identity\",
    \"credential_scope\": \"audit-upload-only\",
    \"credential_bootstrap\": \"pre-provisioned-out-of-band\",
    \"credential_reference\": \"spiffe://signalloom.demo/ns/agents/sa/${AGENT_ID}\"
  }")"

ENROLL_STATE="$(echo "${ENROLL_RESP}" | jq -r '.enrollment_state // empty')"
if [[ "${ENROLL_STATE}" != "enrolled" ]]; then
  echo "FAILED"
  echo "Enroll response: ${ENROLL_RESP}"
  exit 1
fi
echo "SUCCESS (State: enrolled, Scope: audit-upload-only)"

# 5. Verify Inventory & Audit Persistence
echo -n "[5/5] Verifying live inventory & audit trail... "
INVENTORY_MATCH="$(sl_curl "${BASE_URL}/api/agents" \
  -H "Authorization: Bearer ${OPERATOR_TOKEN}" | jq --arg id "${AGENT_ID}" '.agents[] | select(.name==$id) | .lifecycle_state' -r)"

AUDIT_COUNT="$(sl_curl "${BASE_URL}/api/audit?agent=${AGENT_ID}" \
  -H "Authorization: Bearer ${OPERATOR_TOKEN}" | jq -r .total)"

if [[ "${INVENTORY_MATCH}" == "active" && "${AUDIT_COUNT}" -ge 2 ]]; then
  echo "SUCCESS"
  echo "Agent '${AGENT_ID}' is ACTIVE in inventory with ${AUDIT_COUNT} audit events verified."
else
  echo "FAILED (Inventory state: '${INVENTORY_MATCH}', Audit count: ${AUDIT_COUNT})"
  exit 1
fi

echo "======================================================================"
echo " ✅ Onboarding complete and verified on sovereign infrastructure!"
echo "======================================================================"
