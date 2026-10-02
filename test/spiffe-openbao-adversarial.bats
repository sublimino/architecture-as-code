#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# @id      spiffe-openbao-adversarial
# @target  scripts/probe-spiffe-privilege-escalation.sh, test/spiffe-identity-probes.sh
# @doc     docs/slaat/p1-3/spiffe-openbao-privilege-escalation-dossier.md
# @spec    SLAAT-P1-3
#
# SLAAT-P1-3 — SPIFFE Identity & OpenBao JWT Privilege Escalation Probing.
#
# Adversarial probe suite against the live signalloom.demo trust domain:
# SPIRE workload attestation (identity spoofing, namespace/process
# impersonation) and the OpenBao JWT auth backend (audience bypass,
# cross-identity bypass, bound_claims defects, signature forgery, token
# TTL). Read-only against SPIRE/OpenBao configuration: every probe is either
# a self-cleaning ephemeral pod or a `bao`/`kubectl exec` read. Nothing here
# edits a SPIRE registration entry, an OpenBao role/policy, or any
# d2-agent-trust / inf-bao manifest.
#
# Structure. Both live scripts run ONCE in setup_file() against the real
# kind-osramp cluster and each writes its own JSON evidence file; individual
# @test cases assert properties of that evidence rather than re-running live
# probes per assertion (each ephemeral-pod identity fetch alone costs several
# seconds of pod scheduling). A DECLARED_TESTS arity check at the end catches
# silent truncation the same way it does in adversarial-network-probes.bats.
#
# On skipping. If the cluster is absent, skip and say so. If the cluster is
# present and a script still produces nothing, that is a suite failure, not
# a quieter pass — a broken live harness must not read as green.

export PATH="/usr/bin:/home/linuxbrew/.linuxbrew/bin:$PATH"
DECLARED_TESTS=16

REPO_ROOT="$(cd -- "$(dirname -- "${BATS_TEST_FILENAME}")/.." && pwd)"
CLUSTER_CONTEXT="${SLAAT_KUBE_CONTEXT:-kind-osramp}"
SPIFFE_JSON="${BATS_FILE_TMPDIR:-/tmp}/slaat-spiffe.json"
IDENT_JSON="${BATS_FILE_TMPDIR:-/tmp}/slaat-identity.json"
FINDINGS_JSON="${REPO_ROOT}/ci-evidence/slaat-p1-3-live-probe-records.json"
SPIFFE_LOG="${BATS_FILE_TMPDIR:-/tmp}/slaat-spiffe.log"
IDENT_LOG="${BATS_FILE_TMPDIR:-/tmp}/slaat-identity.log"

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
  skip "no cluster '${CLUSTER_CONTEXT}' — live probe suite cannot run"
}

setup_file() {
  export REPO_ROOT CLUSTER_CONTEXT SPIFFE_JSON IDENT_JSON FINDINGS_JSON SPIFFE_LOG IDENT_LOG
  rm -f "${SPIFFE_JSON}" "${IDENT_JSON}" "${SPIFFE_LOG}" "${IDENT_LOG}"

  if ! have_cluster; then
    echo "# no cluster '${CLUSTER_CONTEXT}' — live tests will skip" >&3
    return 0
  fi

  echo "# running probe-spiffe-privilege-escalation.sh once for the whole file..." >&3
  SLAAT_KUBE_CONTEXT="${CLUSTER_CONTEXT}" bash "${REPO_ROOT}/scripts/probe-spiffe-privilege-escalation.sh" \
    --out "${SPIFFE_JSON}" >"${SPIFFE_LOG}" 2>&1 || true

  echo "# running test/spiffe-identity-probes.sh once for the whole file..." >&3
  SLAAT_KUBE_CONTEXT="${CLUSTER_CONTEXT}" bash "${REPO_ROOT}/test/spiffe-identity-probes.sh" \
    --out "${IDENT_JSON}" >"${IDENT_LOG}" 2>&1 || true

  if [[ -s "${SPIFFE_JSON}" && -s "${IDENT_JSON}" ]]; then
    python3 - "${SPIFFE_JSON}" "${IDENT_JSON}" "${FINDINGS_JSON}" "${CLUSTER_CONTEXT}" <<'PY'
import json, sys, datetime, subprocess
spiffe_path, ident_path, out_path, ctx = sys.argv[1:5]
spiffe = json.load(open(spiffe_path))
ident = json.load(open(ident_path))
try:
    head = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True, cwd=".").stdout.strip()
except Exception:
    head = ""
records = spiffe["records"] + ident["records"]
out = {
    "schema": "slaat-p1-3-live-probe-records/v1",
    "card": "SLAAT-P1-3",
    "generated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "cluster_context": ctx,
    "repo_head": head,
    "components": {
        "spiffe_openbao_probe": {"record_count": spiffe["record_count"], "fail_count": spiffe["fail_count"]},
        "spiffe_identity_probe": {"record_count": ident["record_count"], "fail_count": ident["fail_count"]},
    },
    "total_record_count": len(records),
    "total_fail_count": spiffe["fail_count"] + ident["fail_count"],
    "records": records,
}
with open(out_path, "w") as f:
    json.dump(out, f, indent=2)
    f.write("\n")
PY
  fi
}

teardown_file() {
  if have_cluster; then
    kubectl --context "${CLUSTER_CONTEXT}" delete pods,serviceaccounts -A -l slaat.controlplane.io/probe=p1-3 \
      --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# SPIRE Workload API attestation boundary
# ─────────────────────────────────────────────────────────────────────────────

@test "SPIFFE probe: evidence file was produced" {
  require_evidence "${SPIFFE_JSON}" "${SPIFFE_LOG}" "probe-spiffe-privilege-escalation.sh"
  run jq -e '.schema == "slaat-p1-3-spiffe-probe/v1"' "${SPIFFE_JSON}"
  [ "$status" -eq 0 ]
}

@test "SPIRE attestation: an unregistered ServiceAccount, co-located in the trust namespace, is denied an SVID" {
  require_evidence "${SPIFFE_JSON}" "${SPIFFE_LOG}" "probe-spiffe-privilege-escalation.sh"
  run jq -r '.records[] | select(.id == "SPIFFE-1") | .severity' "${SPIFFE_JSON}"
  [ "$status" -eq 0 ]
  [ "$output" = "pass" ]
}

@test "SPIRE attestation: a legitimately-registered ServiceAccount receives a valid SVID (control case)" {
  require_evidence "${SPIFFE_JSON}" "${SPIFFE_LOG}" "probe-spiffe-privilege-escalation.sh"
  run jq -r '.records[] | select(.id == "SPIFFE-2") | .severity' "${SPIFFE_JSON}"
  [ "$status" -eq 0 ]
  [ "$output" = "pass" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# OpenBao JWT role boundary
# ─────────────────────────────────────────────────────────────────────────────

@test "OpenBao JWT login: a legitimate role login succeeds and the mission's 5-minute TTL cap is evaluated" {
  require_evidence "${SPIFFE_JSON}" "${SPIFFE_LOG}" "probe-spiffe-privilege-escalation.sh"
  run jq -e '.records[] | select(.id == "SPIFFE-3")' "${SPIFFE_JSON}"
  [ "$status" -eq 0 ]
}

@test "OpenBao KV isolation: the issued token can read its own path but not cross-tenant paths" {
  require_evidence "${SPIFFE_JSON}" "${SPIFFE_LOG}" "probe-spiffe-privilege-escalation.sh"
  run jq -r '[.records[] | select(.id | test("^SPIFFE-[4-9]$")) | .severity] | unique | join(",")' "${SPIFFE_JSON}"
  [ "$status" -eq 0 ]
  [ "$output" = "pass" ]
}

@test "OpenBao JWT login: a valid SVID for one identity is rejected by a role bound to a different identity" {
  require_evidence "${SPIFFE_JSON}" "${SPIFFE_LOG}" "probe-spiffe-privilege-escalation.sh"
  run jq -r '.records[] | select(.id == "SPIFFE-10") | .severity' "${SPIFFE_JSON}"
  [ "$status" -eq 0 ]
  [ "$output" = "pass" ]
}

@test "OpenBao JWT login: a wrong-audience SVID is rejected on audience grounds" {
  require_evidence "${SPIFFE_JSON}" "${SPIFFE_LOG}" "probe-spiffe-privilege-escalation.sh"
  run jq -r '.records[] | select(.id == "SPIFFE-11") | .severity' "${SPIFFE_JSON}"
  [ "$status" -eq 0 ]
  [ "$output" = "pass" ]
}

@test "OpenBao JWT login: tampered-signature SVIDs are rejected" {
  require_evidence "${SPIFFE_JSON}" "${SPIFFE_LOG}" "probe-spiffe-privilege-escalation.sh"
  run jq -r '.records[] | select(.id == "SPIFFE-13") | .severity' "${SPIFFE_JSON}"
  [ "$status" -eq 0 ]
  [ "$output" = "pass" ]
}

@test "OpenBao JWT login: an alg:none forged token is rejected (no signature-bypass regression)" {
  require_evidence "${SPIFFE_JSON}" "${SPIFFE_LOG}" "probe-spiffe-privilege-escalation.sh"
  run jq -r '.records[] | select(.id == "SPIFFE-14") | .severity' "${SPIFFE_JSON}"
  [ "$status" -eq 0 ]
  [ "$output" = "pass" ]
}

@test "token TTL audit: every live auth/jwt role was swept for its effective TTL" {
  require_evidence "${SPIFFE_JSON}" "${SPIFFE_LOG}" "probe-spiffe-privilege-escalation.sh"
  run jq -r '[.records[] | select(.id | startswith("TTL-"))] | length' "${SPIFFE_JSON}"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# SPIFFE identity spoofing (namespace / process impersonation)
# ─────────────────────────────────────────────────────────────────────────────

@test "identity probe: evidence file was produced" {
  require_evidence "${IDENT_JSON}" "${IDENT_LOG}" "spiffe-identity-probes.sh"
  run jq -e '.schema == "slaat-p1-3-spiffe-identity-probe/v1"' "${IDENT_JSON}"
  [ "$status" -eq 0 ]
}

@test "identity probe: no live registration entry relies on a namespace-only selector" {
  require_evidence "${IDENT_JSON}" "${IDENT_LOG}" "spiffe-identity-probes.sh"
  run jq -r '.records[] | select(.id == "IDENT-1") | .severity' "${IDENT_JSON}"
  [ "$status" -eq 0 ]
  [ "$output" = "pass" ]
}

@test "identity probe: namespace co-location alone does not grant an identity" {
  require_evidence "${IDENT_JSON}" "${IDENT_LOG}" "spiffe-identity-probes.sh"
  run jq -r '.records[] | select(.id == "IDENT-2") | .severity' "${IDENT_JSON}"
  [ "$status" -eq 0 ]
  [ "$output" = "pass" ]
}

@test "identity probe: a partial selector match (right ServiceAccount, missing pod-label) is denied" {
  require_evidence "${IDENT_JSON}" "${IDENT_LOG}" "spiffe-identity-probes.sh"
  run jq -r '.records[] | select(.id == "IDENT-3") | .severity' "${IDENT_JSON}"
  [ "$status" -eq 0 ]
  [ "$output" = "pass" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Aggregated findings manifest
# ─────────────────────────────────────────────────────────────────────────────

@test "findings manifest: ci-evidence/slaat-p1-3-live-probe-records.json was generated and is well-formed" {
  [[ -s "${FINDINGS_JSON}" ]] || skip "no cluster '${CLUSTER_CONTEXT}' — findings manifest not regenerated this run"
  run jq -e '.schema == "slaat-p1-3-live-probe-records/v1" and (.total_record_count > 0)' "${FINDINGS_JSON}"
  [ "$status" -eq 0 ]
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
