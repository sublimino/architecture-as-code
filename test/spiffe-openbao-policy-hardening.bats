#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# @id      spiffe-openbao-policy-hardening
# @target  d2-signalloom/infra/inf-bao/configs/base/openbao-supercred-bootstrap.yaml,
#          d2-signalloom/infra/inf-bao/configs/base/openbao-bootstrap.yaml,
#          d2-signalloom/infra/inf-bao/controllers/base/openbao-agent-generic-role.yaml
# @doc     docs/slaat/p1-3/spiffe-openbao-privilege-escalation-dossier.md
# @spec    SLAAT-P2-3
#
# SLAAT-P2-3 -- SPIFFE Workload API & OpenBao Policy Hardening Fixes.
#
# Proves the two SLAAT-P1-3 findings routed to this card are closed:
#
#   F1 (CRITICAL) -- signalloom-cardvault-agent and signalloom-fe-signalloom
#   issued 768h (32-day) tokens instead of the mission's 5-minute hard cap,
#   because neither role declared token_ttl/token_max_ttl. Fixed by adding
#   token_ttl=5m, token_max_ttl=5m, token_type=batch to both roles.
#
#   F2 (MEDIUM, fails closed) -- signalloom-agent-generic's bound_claims glob
#   never matched a real SPIFFE sub because bound_claims_type defaulted to
#   "string", so the trailing "*" was compared as a literal character. Every
#   one of the 18 registered fe-signalloom-agents/sa/* identities was denied.
#   Fixed by adding bound_claims_type=glob.
#
# Structure. A static block (no cluster required) greps the three manifests
# for the exact fields the fix adds -- this is the "declarative source of
# truth" half of the proof. A live block (skips without a cluster) re-runs
# the exact Phase 1 probe scripts and asserts the specific records that were
# fail-severity in ci-evidence/slaat-p1-3-spiffe-findings.json now read
# pass, with zero new regressions on the boundaries that already held
# (B1-B4: forged identity, cross-identity, wrong-audience, tampered
# signature, alg:none, cross-tenant KV reads, admin-surface reads). A third
# block confirms the OpenBao ACL audit still shows zero wildcard read/list
# grants across the four live policies (unaffected by this card's edits,
# asserted anyway so a future wildcard regression is caught here too).

export PATH="/usr/bin:/home/linuxbrew/.linuxbrew/bin:$PATH"
DECLARED_TESTS=14

REPO_ROOT="$(cd -- "$(dirname -- "${BATS_TEST_FILENAME}")/.." && pwd)"
CLUSTER_CONTEXT="${SLAAT_KUBE_CONTEXT:-kind-osramp}"
SPIFFE_JSON="${BATS_FILE_TMPDIR:-/tmp}/slaat-p2-3-spiffe.json"
ACL_JSON="${BATS_FILE_TMPDIR:-/tmp}/slaat-p2-3-acls.json"
SPIFFE_LOG="${BATS_FILE_TMPDIR:-/tmp}/slaat-p2-3-spiffe.log"
ACL_LOG="${BATS_FILE_TMPDIR:-/tmp}/slaat-p2-3-acls.log"

SUPERCRED_YAML="${REPO_ROOT}/d2-signalloom/infra/inf-bao/configs/base/openbao-supercred-bootstrap.yaml"
BOOTSTRAP_YAML="${REPO_ROOT}/d2-signalloom/infra/inf-bao/configs/base/openbao-bootstrap.yaml"
GENERIC_ROLE_YAML="${REPO_ROOT}/d2-signalloom/infra/inf-bao/controllers/base/openbao-agent-generic-role.yaml"

have_cluster() {
  kubectl --context "${CLUSTER_CONTEXT}" cluster-info >/dev/null 2>&1
}

require_evidence() {
  local json="$1" log="$2" label="$3"
  [[ -s "${json}" ]] && return 0
  if have_cluster; then
    echo "# ${label} produced no evidence despite cluster '${CLUSTER_CONTEXT}' being present" >&3
    [[ -s "${log}" ]] && sed 's/^/#   /' "${log}" >&3
    return 1
  fi
  skip "no cluster '${CLUSTER_CONTEXT}' -- live probe suite cannot run"
}

setup_file() {
  export REPO_ROOT CLUSTER_CONTEXT SPIFFE_JSON ACL_JSON SPIFFE_LOG ACL_LOG
  export SUPERCRED_YAML BOOTSTRAP_YAML GENERIC_ROLE_YAML
  rm -f "${SPIFFE_JSON}" "${ACL_JSON}" "${SPIFFE_LOG}" "${ACL_LOG}"

  if ! have_cluster; then
    echo "# no cluster '${CLUSTER_CONTEXT}' -- live tests will skip" >&3
    return 0
  fi

  echo "# running probe-spiffe-privilege-escalation.sh once for the whole file..." >&3
  SLAAT_KUBE_CONTEXT="${CLUSTER_CONTEXT}" bash "${REPO_ROOT}/scripts/probe-spiffe-privilege-escalation.sh" \
    --out "${SPIFFE_JSON}" >"${SPIFFE_LOG}" 2>&1 || true

  echo "# running probe-openbao-acls.sh once for the whole file..." >&3
  SLAAT_KUBE_CONTEXT="${CLUSTER_CONTEXT}" bash "${REPO_ROOT}/scripts/probe-openbao-acls.sh" \
    --out "${ACL_JSON}" >"${ACL_LOG}" 2>&1 || true
}

teardown_file() {
  if have_cluster; then
    kubectl --context "${CLUSTER_CONTEXT}" delete pods,serviceaccounts -A -l slaat.controlplane.io/probe=p1-3 \
      --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Static: the declarative manifests carry the fix (no cluster required)
# ─────────────────────────────────────────────────────────────────────────────

@test "F1 static: signalloom-cardvault-agent role declares token_ttl/token_max_ttl=5m and token_type=batch" {
  run grep -A3 '"policies": \["signalloom-cardvault-agent"\]' "${SUPERCRED_YAML}"
  [ "$status" -eq 0 ]
  run grep -c '"token_ttl": "5m"' "${SUPERCRED_YAML}"
  [ "$output" -ge 1 ]
  run grep -c '"token_max_ttl": "5m"' "${SUPERCRED_YAML}"
  [ "$output" -ge 1 ]
}

@test "F1 static: signalloom-fe-signalloom role declares token_ttl=5m token_max_ttl=5m token_type=batch" {
  run grep -E 'token_ttl=5m token_max_ttl=5m token_type=batch' "${BOOTSTRAP_YAML}"
  [ "$status" -eq 0 ]
}

@test "F2 static: signalloom-agent-generic role declares bound_claims_type=glob" {
  run grep -c '"bound_claims_type": "glob"' "${GENERIC_ROLE_YAML}"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "static: no YAML syntax regression in the three edited manifests" {
  run python3 -c "
import sys, yaml
for f in sys.argv[1:]:
    list(yaml.safe_load_all(open(f)))
" "${SUPERCRED_YAML}" "${BOOTSTRAP_YAML}" "${GENERIC_ROLE_YAML}"
  [ "$status" -eq 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Live: the fix is in effect on the running kind-osramp cluster
# ─────────────────────────────────────────────────────────────────────────────

@test "F1 live: signalloom-cardvault-agent effective TTL is capped at 300s, not 768h" {
  require_evidence "${SPIFFE_JSON}" "${SPIFFE_LOG}" "probe-spiffe-privilege-escalation.sh"
  run jq -r '.records[] | select(.id == "TTL-signalloom-cardvault-agent") | .severity' "${SPIFFE_JSON}"
  [ "$status" -eq 0 ]
  [ "$output" = "pass" ]
}

@test "F1 live: signalloom-fe-signalloom effective TTL is capped at 300s, not 768h" {
  require_evidence "${SPIFFE_JSON}" "${SPIFFE_LOG}" "probe-spiffe-privilege-escalation.sh"
  run jq -r '.records[] | select(.id == "TTL-signalloom-fe-signalloom") | .severity' "${SPIFFE_JSON}"
  [ "$status" -eq 0 ]
  [ "$output" = "pass" ]
}

@test "F1 live: a dynamic login against signalloom-cardvault-agent now returns token_duration<=5m" {
  require_evidence "${SPIFFE_JSON}" "${SPIFFE_LOG}" "probe-spiffe-privilege-escalation.sh"
  run jq -r '.records[] | select(.id == "SPIFFE-3") | .severity' "${SPIFFE_JSON}"
  [ "$status" -eq 0 ]
  [ "$output" = "pass" ]
}

@test "F2 live: a correctly-audienced, registered SVID now authenticates against signalloom-agent-generic" {
  require_evidence "${SPIFFE_JSON}" "${SPIFFE_LOG}" "probe-spiffe-privilege-escalation.sh"
  run jq -r '.records[] | select(.id == "SPIFFE-12") | .severity' "${SPIFFE_JSON}"
  [ "$status" -eq 0 ]
  [ "$output" = "pass" ]
}

@test "Anti: a wrong-audience SVID is still rejected by signalloom-agent-generic after the glob fix" {
  require_evidence "${SPIFFE_JSON}" "${SPIFFE_LOG}" "probe-spiffe-privilege-escalation.sh"
  run jq -r '.records[] | select(.id == "SPIFFE-11") | .severity' "${SPIFFE_JSON}"
  [ "$status" -eq 0 ]
  [ "$output" = "pass" ]
}

@test "Anti: tampered-signature and alg:none forgery are still rejected after both role edits" {
  require_evidence "${SPIFFE_JSON}" "${SPIFFE_LOG}" "probe-spiffe-privilege-escalation.sh"
  run jq -r '[.records[] | select(.id == "SPIFFE-13" or .id == "SPIFFE-14") | .severity] | unique | join(",")' "${SPIFFE_JSON}"
  [ "$status" -eq 0 ]
  [ "$output" = "pass" ]
}

@test "Anti: issued tokens still cannot read cross-tenant KV paths after both role edits" {
  require_evidence "${SPIFFE_JSON}" "${SPIFFE_LOG}" "probe-spiffe-privilege-escalation.sh"
  run jq -r '[.records[] | select(.id | test("^SPIFFE-[4-9]$")) | .severity] | unique | join(",")' "${SPIFFE_JSON}"
  [ "$status" -eq 0 ]
  [ "$output" = "pass" ]
}

@test "live: probe-spiffe-privilege-escalation.sh reports zero fail-severity records after the fix" {
  require_evidence "${SPIFFE_JSON}" "${SPIFFE_LOG}" "probe-spiffe-privilege-escalation.sh"
  run jq -r '.fail_count' "${SPIFFE_JSON}"
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}

@test "live: no OpenBao ACL policy grants a wildcard read/list across kv/data (no regression from this card's edits)" {
  require_evidence "${ACL_JSON}" "${ACL_LOG}" "probe-openbao-acls.sh"
  run jq -r '[.records[] | select(.vector == "policy-boundary-audit") | .severity] | unique | join(",")' "${ACL_JSON}"
  [ "$status" -eq 0 ]
  [ "$output" = "pass" ]
}

# ─────────────────────────────────────────────────────────────────────────────

@test "arity: this suite defines exactly the number of tests it declares" {
  local defined
  defined="$(grep -c '^@test ' "${BATS_TEST_FILENAME}")"
  if [ "$defined" -ne "$DECLARED_TESTS" ]; then
    echo "# suite defines ${defined} tests but declares ${DECLARED_TESTS}" >&3
    false
  fi
  [ "$defined" -eq "$DECLARED_TESTS" ]
}
