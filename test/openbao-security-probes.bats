#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# @id      openbao-security-probes
# @target  scripts/probe-openbao-acls.sh
# @doc     docs/slaat/p1-3/spiffe-openbao-privilege-escalation-dossier.md
# @spec    SLAAT-P1-3
#
# SLAAT-P1-3 — OpenBao ACL policy and JWT-role delegation-coverage audit.
#
# Two properties under test, both read-only against live OpenBao state:
#
#   1. Every live policy's path grants are scoped to a single tenant/agent/
#      identity-templated subtree -- no bare top-level kv/data/<x> catch-all,
#      no sys/* or auth/* admin-surface grant.
#   2. Every live SPIRE-registered workload identity (under the signalloom.demo
#      trust domain's k8s-selector entries) has at least one auth/jwt role
#      whose bound_claims.sub or bound_subject matches it. A registered
#      identity with no matching role is a delegation gap: it can obtain a
#      valid SVID but has no path to an OpenBao credential.
#
# d2-agent-trust currently provisions this for exactly ONE tenant/project
# (acme/payments); acme/risk and northstar/investigations have live SPIRE
# entries with no corresponding role. Those two are IN this card's scope
# (d2-agent-trust fixtures). The eap-* tenant-app entries this audit also
# surfaces belong to the unrelated EAPR mission (see EAPR-P2-1), which does
# not use OpenBao JWT auth at all -- see @test "delegation gap scope note"
# below for why those are reported as context, not scored as a SLAAT defect.

export PATH="/usr/bin:/home/linuxbrew/.linuxbrew/bin:$PATH"
DECLARED_TESTS=8

REPO_ROOT="$(cd -- "$(dirname -- "${BATS_TEST_FILENAME}")/.." && pwd)"
CLUSTER_CONTEXT="${SLAAT_KUBE_CONTEXT:-kind-osramp}"
ACL_JSON="${BATS_FILE_TMPDIR:-/tmp}/slaat-acl.json"
ACL_LOG="${BATS_FILE_TMPDIR:-/tmp}/slaat-acl.log"

have_cluster() {
  kubectl --context "${CLUSTER_CONTEXT}" cluster-info >/dev/null 2>&1
}

require_evidence() {
  [[ -s "${ACL_JSON}" ]] && return 0
  if have_cluster; then
    echo "# probe-openbao-acls.sh produced no evidence despite cluster '${CLUSTER_CONTEXT}' being present" >&3
    [[ -s "${ACL_LOG}" ]] && sed 's/^/#   /' "${ACL_LOG}" >&3
    return 1
  fi
  skip "no cluster '${CLUSTER_CONTEXT}' — live probe suite cannot run"
}

setup_file() {
  export REPO_ROOT CLUSTER_CONTEXT ACL_JSON ACL_LOG
  rm -f "${ACL_JSON}" "${ACL_LOG}"

  if ! have_cluster; then
    echo "# no cluster '${CLUSTER_CONTEXT}' — live tests will skip" >&3
    return 0
  fi

  echo "# running probe-openbao-acls.sh once for the whole file..." >&3
  SLAAT_KUBE_CONTEXT="${CLUSTER_CONTEXT}" bash "${REPO_ROOT}/scripts/probe-openbao-acls.sh" \
    --role agent-runtime --vault-addr http://openbao.inf-bao:8200 \
    --out "${ACL_JSON}" >"${ACL_LOG}" 2>&1 || true
}

# ─────────────────────────────────────────────────────────────────────────────

@test "ACL audit: evidence file was produced" {
  require_evidence
  run jq -e '.schema == "slaat-p1-3-openbao-acl-audit/v1"' "${ACL_JSON}"
  [ "$status" -eq 0 ]
}

@test "ACL audit: every live non-default/root policy is tenant/agent scoped (no bare top-level KV grant)" {
  require_evidence
  run jq -r '[.records[] | select(.id | startswith("ACL-POLICY-")) | .severity] | unique | join(",")' "${ACL_JSON}"
  [ "$status" -eq 0 ]
  [ "$output" = "pass" ]
}

@test "ACL audit: no live policy grants a sys/* or auth/* admin-surface path" {
  require_evidence
  run bash -c "jq -r '.records[] | select(.id | startswith(\"ACL-POLICY-\")) | .detail' '${ACL_JSON}' | grep -c 'admin-surface:' || true"
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}

@test "ACL audit: the d2-agent-trust acme/payments policy grants read-only on its own tenant subtree" {
  require_evidence
  run jq -r '.records[] | select(.id == "ACL-POLICY-agent-trust-acme-payments") | .detail' "${ACL_JSON}"
  [ "$status" -eq 0 ]
  [[ "$output" == *'kv/data/signalloom/agent-trust/acme/payments/*'* ]]
  [[ "$output" == *'"read"'* ]]
  [[ "$output" != *'"write"'* ]]
  [[ "$output" != *'"delete"'* ]]
}

@test "delegation coverage: d2-agent-trust's acme/risk and northstar/investigations identities are flagged as gaps" {
  require_evidence
  run jq -r '[.records[].detail] | map(select(test("tenant/acme/project/risk/agent/risk-reader|tenant/northstar/project/investigations/agent/investigator"))) | length' "${ACL_JSON}"
  [ "$status" -eq 0 ]
  [ "$output" -eq 2 ]
}

@test "delegation gap scope note: eap-* entries surfaced by this audit belong to EAPR, not SLAAT" {
  # Documents the scope boundary rather than asserting a count: the EAPR
  # mission (see EAPR-P2-1) provisions its own tenant-app auth path and does
  # not use OpenBao JWT roles, so its entries showing up as "gaps" here is
  # expected noise from a shared trust domain, not a SLAAT-P1-3 finding.
  require_evidence
  run jq -r '[.records[].detail] | map(select(test("ns/eap-"))) | length' "${ACL_JSON}"
  [ "$status" -eq 0 ]
  echo "# ${output} eap-* delegation-gap records observed; out of SLAAT-P1-3 scope, see EAPR-P2-1" >&3
}

@test "ACL audit: a requested but nonexistent --role is reported as a gap, not a usage error" {
  require_evidence
  run jq -r '.records[] | select(.id == "ACL-ROLE-FOCUS") | .severity' "${ACL_JSON}"
  [ "$status" -eq 0 ]
  [ "$output" = "info" ]
}

@test "arity: this suite defines exactly the number of tests it declares" {
  local defined
  defined="$(grep -c '^@test ' "${BATS_TEST_FILENAME}")"
  if [ "$defined" -ne "$DECLARED_TESTS" ]; then
    echo "# suite defines ${defined} tests but declares ${DECLARED_TESTS}" >&3
    false
  fi
  [ "$defined" -eq "$DECLARED_TESTS" ]
}
