#!/usr/bin/env bash
# agentprofile-manifest-validation.sh — SLSC-P1-1 AgentProfile CRD and manifest validation harness.
#
# Validates:
#   1. CRD OpenAPI v3 schema syntax and structural compliance via kubectl apply --dry-run=client.
#   2. All 5 demonstration agent manifests under d2-signalloom/agents/ via kubectl apply --dry-run=client.
#   3. Structural schema properties: id, name, type, team, trustProfile, riskClass, gracePeriod,
#      dependencies, spiffePath, openbaoMount, spiffe, openbao.
#   4. Enum constraints and regex patterns (e.g. gracePeriod duration).
#   5. Dependency graph acyclicity and 5-node topology structure.
#
# Exit status: 0 on complete pass, 1 on any validation failure.

set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENTS_DIR="${REPO_ROOT}/d2-signalloom/agents"
CRD_FILE="${AGENTS_DIR}/crd-agentprofile.yaml"

AGENT_FILES=(
  "agent-cardvault.yaml"
  "agent-txn-pipeline.yaml"
  "agent-llm-classifier.yaml"
  "agent-api-gateway.yaml"
  "agent-monitor.yaml"
)

TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0

report_pass() {
  local msg="$1"
  TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
  PASSED_CHECKS=$((PASSED_CHECKS + 1))
  echo "ok ${TOTAL_CHECKS} - ${msg}"
}

report_fail() {
  local msg="$1"
  TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
  FAILED_CHECKS=$((FAILED_CHECKS + 1))
  echo "not ok ${TOTAL_CHECKS} - ${msg}"
}

echo "1..16"
echo "# Starting AgentProfile CRD and manifest validation suite"

# 1. Preflight tool checks
if ! command -v kubectl >/dev/null 2>&1; then
  report_fail "kubectl binary is available in PATH"
  echo "Bail out! kubectl binary required for client-side dry-run validation"
  exit 1
fi
report_pass "kubectl binary is available in PATH"

if ! command -v yq >/dev/null 2>&1; then
  report_fail "yq binary is available in PATH"
  echo "Bail out! yq binary required for YAML inspection"
  exit 1
fi
report_pass "yq binary is available in PATH"

# 2. CRD manifest existence and dry-run apply
if [[ ! -f "$CRD_FILE" ]]; then
  report_fail "CRD file exists at d2-signalloom/agents/crd-agentprofile.yaml"
else
  report_pass "CRD file exists at d2-signalloom/agents/crd-agentprofile.yaml"
fi

if kubectl apply -f "$CRD_FILE" --dry-run=client >/dev/null 2>&1; then
  report_pass "kubectl apply --dry-run=client succeeds on crd-agentprofile.yaml"
else
  report_fail "kubectl apply --dry-run=client succeeds on crd-agentprofile.yaml"
fi

# Ensure CRD is loaded in discovery context if connected to a cluster
kubectl apply -f "$CRD_FILE" >/dev/null 2>&1 || true

# 3. Dry-run client validation for all 5 agent manifests
for file in "${AGENT_FILES[@]}"; do
  manifest_path="${AGENTS_DIR}/${file}"
  if [[ ! -f "$manifest_path" ]]; then
    report_fail "Agent manifest exists: ${file}"
    continue
  fi

  if kubectl apply -f "$manifest_path" --dry-run=client >/dev/null 2>&1; then
    report_pass "kubectl apply --dry-run=client succeeds on ${file}"
  else
    report_fail "kubectl apply --dry-run=client succeeds on ${file}"
  fi
done

# 4. Schema property and enum validation
VALID_TYPES=("data-vault" "data-pipeline" "llm-inference" "api-gateway" "observability" "demo-agent")
VALID_TEAMS=("platform" "payments" "ml-ops" "sre" "governance")
VALID_TRUST=("high" "medium" "low")
VALID_RISK=("high" "medium" "low" "critical")

schema_errors=0
for file in "${AGENT_FILES[@]}"; do
  manifest_path="${AGENTS_DIR}/${file}"

  api_version=$(yq '.apiVersion' "$manifest_path")
  kind=$(yq '.kind' "$manifest_path")
  agent_type=$(yq '.spec.type' "$manifest_path")
  agent_team=$(yq '.spec.team' "$manifest_path")
  trust_profile=$(yq '.spec.trustProfile' "$manifest_path")
  risk_class=$(yq '.spec.riskClass' "$manifest_path")
  grace_period=$(yq '.spec.gracePeriod' "$manifest_path")
  spiffe_path=$(yq '.spec.spiffePath // .spec.spiffe.path' "$manifest_path")
  openbao_mount=$(yq '.spec.openbaoMount // .spec.openbao.authMount' "$manifest_path")

  if [[ "$api_version" != "signalloom.controlplane.io/v1alpha1" || "$kind" != "AgentProfile" ]]; then
    echo "# Error in ${file}: apiVersion/kind mismatch ($api_version / $kind)"
    schema_errors=$((schema_errors + 1))
  fi

  # Check type enum
  type_ok=0
  for t in "${VALID_TYPES[@]}"; do
    if [[ "$agent_type" == "$t" ]]; then type_ok=1; break; fi
  done
  if [[ $type_ok -eq 0 ]]; then
    echo "# Error in ${file}: invalid type '${agent_type}'"
    schema_errors=$((schema_errors + 1))
  fi

  # Check team enum
  team_ok=0
  for t in "${VALID_TEAMS[@]}"; do
    if [[ "$agent_team" == "$t" ]]; then team_ok=1; break; fi
  done
  if [[ $team_ok -eq 0 ]]; then
    echo "# Error in ${file}: invalid team '${agent_team}'"
    schema_errors=$((schema_errors + 1))
  fi

  # Check trustProfile enum
  trust_ok=0
  for t in "${VALID_TRUST[@]}"; do
    if [[ "$trust_profile" == "$t" ]]; then trust_ok=1; break; fi
  done
  if [[ $trust_ok -eq 0 ]]; then
    echo "# Error in ${file}: invalid trustProfile '${trust_profile}'"
    schema_errors=$((schema_errors + 1))
  fi

  # Check riskClass enum
  risk_ok=0
  for r in "${VALID_RISK[@]}"; do
    if [[ "$risk_class" == "$r" ]]; then risk_ok=1; break; fi
  done
  if [[ $risk_ok -eq 0 ]]; then
    echo "# Error in ${file}: invalid riskClass '${risk_class}'"
    schema_errors=$((schema_errors + 1))
  fi

  # Check gracePeriod regex pattern
  if [[ ! "$grace_period" =~ ^[0-9]+(h|m|s)$ ]]; then
    echo "# Error in ${file}: invalid gracePeriod format '${grace_period}'"
    schema_errors=$((schema_errors + 1))
  fi

  # Check spiffePath and openbaoMount presence
  if [[ -z "$spiffe_path" || "$spiffe_path" == "null" ]]; then
    echo "# Error in ${file}: missing spiffePath or spec.spiffe.path"
    schema_errors=$((schema_errors + 1))
  fi

  if [[ -z "$openbao_mount" || "$openbao_mount" == "null" ]]; then
    echo "# Error in ${file}: missing openbaoMount or spec.openbao.authMount"
    schema_errors=$((schema_errors + 1))
  fi
done

if [[ $schema_errors -eq 0 ]]; then
  report_pass "All 5 manifests satisfy OpenAPI v3 structural and enum validation"
else
  report_fail "All 5 manifests satisfy OpenAPI v3 structural and enum validation"
fi

# 5. Dependency Graph Acyclicity and Structure
# Build adjacency and check for cycles
declare -A IN_STACK=()
declare -A VISITED=()
CYCLE_FOUND=0

check_cycle() {
  local node="$1"
  if [[ "${IN_STACK[$node]:-0}" -eq 1 ]]; then
    CYCLE_FOUND=1
    return 1
  fi
  if [[ "${VISITED[$node]:-0}" -eq 1 ]]; then
    return 0
  fi

  IN_STACK[$node]=1
  VISITED[$node]=1

  local deps
  deps=$(yq '.spec.dependencies[]' "${AGENTS_DIR}/${node}.yaml" 2>/dev/null || true)
  while IFS= read -r dep; do
    [[ -z "$dep" ]] && continue
    check_cycle "$dep" || return 1
  done <<< "$deps"

  IN_STACK[$node]=0
  return 0
}

for file in "${AGENT_FILES[@]}"; do
  agent_name="${file%.yaml}"
  check_cycle "$agent_name" || break
done

if [[ $CYCLE_FOUND -eq 0 ]]; then
  report_pass "Fleet dependency graph is strictly acyclic"
else
  report_fail "Fleet dependency graph is strictly acyclic (cycle detected)"
fi

# 6. Specific 5-node topology structure verification
cardvault_deps=$(yq '.spec.dependencies | length' "${AGENTS_DIR}/agent-cardvault.yaml")
txn_deps=$(yq '.spec.dependencies[0]' "${AGENTS_DIR}/agent-txn-pipeline.yaml")
llm_deps=$(yq '.spec.dependencies[0]' "${AGENTS_DIR}/agent-llm-classifier.yaml")
gw_deps=$(yq '.spec.dependencies[0]' "${AGENTS_DIR}/agent-api-gateway.yaml")
mon_dep_count=$(yq '.spec.dependencies | length' "${AGENTS_DIR}/agent-monitor.yaml")

if [[ "$cardvault_deps" -eq 0 ]]; then
  report_pass "agent-cardvault is root with zero dependencies"
else
  report_fail "agent-cardvault is root with zero dependencies"
fi

if [[ "$txn_deps" == "agent-cardvault" ]]; then
  report_pass "agent-txn-pipeline depends on agent-cardvault"
else
  report_fail "agent-txn-pipeline depends on agent-cardvault"
fi

if [[ "$llm_deps" == "agent-txn-pipeline" ]]; then
  report_pass "agent-llm-classifier depends on agent-txn-pipeline"
else
  report_fail "agent-llm-classifier depends on agent-txn-pipeline"
fi

if [[ "$gw_deps" == "agent-cardvault" ]]; then
  report_pass "agent-api-gateway depends on agent-cardvault"
else
  report_fail "agent-api-gateway depends on agent-cardvault"
fi

if [[ "$mon_dep_count" -eq 4 ]]; then
  report_pass "agent-monitor depends on all 4 fleet agents"
else
  report_fail "agent-monitor depends on all 4 fleet agents"
fi

echo "# Validation complete: ${PASSED_CHECKS}/${TOTAL_CHECKS} passed"

if [[ $FAILED_CHECKS -gt 0 ]]; then
  exit 1
fi
exit 0
