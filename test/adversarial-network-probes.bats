#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# @id      adversarial-network-probes
# @target  scripts/envoy-gateway-audit.sh, scripts/probe-network-isolation.sh
# @doc     docs/slaat/p1-1/ingress-network-isolation-adversarial-audit-report.md
# @spec    SLAAT-P1-1
#
# SLAAT-P1-1 — Ingress Gateway & Network Isolation Attack Probing.
#
# Adversarial probe suite against the live Envoy Gateway and the cluster's
# NetworkPolicy microsegmentation boundary. Read-only: every probe is a
# curl/TCP connect or a self-cleaning ephemeral pod; nothing here edits a
# Gateway, HTTPRoute, or NetworkPolicy manifest.
#
# Structure. Both live scripts run ONCE in setup_file() against the real
# kind-osramp cluster and each writes its own JSON evidence file; individual
# @test cases assert properties of that evidence rather than re-running live
# probes per assertion (each lateral-movement probe alone costs several
# seconds of pod scheduling). A DECLARED_TESTS arity check at the end catches
# silent truncation the same way test_declared_count does elsewhere in this
# repo.
#
# On skipping. If the cluster is absent, skip and say so. If the cluster is
# present and a script still produces nothing, that is a suite failure, not a
# quieter pass — a broken live harness must not read as green.

export PATH="/usr/bin:/home/linuxbrew/.linuxbrew/bin:$PATH"
DECLARED_TESTS=20

REPO_ROOT="$(cd -- "$(dirname -- "${BATS_TEST_FILENAME}")/.." && pwd)"
CLUSTER_CONTEXT="${SLAAT_KUBE_CONTEXT:-kind-osramp}"
GW_AUDIT_JSON="${BATS_FILE_TMPDIR:-/tmp}/slaat-gw-audit.json"
NETISO_JSON="${BATS_FILE_TMPDIR:-/tmp}/slaat-netiso.json"
FINDINGS_JSON="${REPO_ROOT}/ci-evidence/slaat-p1-1-network-findings.json"
GW_HARNESS_LOG="${BATS_FILE_TMPDIR:-/tmp}/slaat-gw-audit.log"
NETISO_HARNESS_LOG="${BATS_FILE_TMPDIR:-/tmp}/slaat-netiso.log"

have_cluster() {
  kubectl --context "${CLUSTER_CONTEXT}" cluster-info >/dev/null 2>&1
}

require_evidence() {
  # Shared skip/fail gate for every @test below. Mirrors cgroup-freeze-stun.bats:
  # an absent cluster skips; a present cluster with empty evidence is a failure.
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
  export REPO_ROOT CLUSTER_CONTEXT GW_AUDIT_JSON NETISO_JSON FINDINGS_JSON GW_HARNESS_LOG NETISO_HARNESS_LOG
  rm -f "${GW_AUDIT_JSON}" "${NETISO_JSON}" "${GW_HARNESS_LOG}" "${NETISO_HARNESS_LOG}"

  if ! have_cluster; then
    echo "# no cluster '${CLUSTER_CONTEXT}' — live tests will skip" >&3
    return 0
  fi

  echo "# running envoy-gateway-audit.sh once for the whole file..." >&3
  SLAAT_KUBE_CONTEXT="${CLUSTER_CONTEXT}" bash "${REPO_ROOT}/scripts/envoy-gateway-audit.sh" \
    --out "${GW_AUDIT_JSON}" >"${GW_HARNESS_LOG}" 2>&1 || true

  echo "# running probe-network-isolation.sh once for the whole file..." >&3
  SLAAT_KUBE_CONTEXT="${CLUSTER_CONTEXT}" bash "${REPO_ROOT}/scripts/probe-network-isolation.sh" \
    --out "${NETISO_JSON}" >"${NETISO_HARNESS_LOG}" 2>&1 || true

  if [[ -s "${GW_AUDIT_JSON}" && -s "${NETISO_JSON}" ]]; then
    python3 - "${GW_AUDIT_JSON}" "${NETISO_JSON}" "${FINDINGS_JSON}" "${CLUSTER_CONTEXT}" <<'PY'
import json, sys, datetime, subprocess
gw_path, net_path, out_path, ctx = sys.argv[1:5]
gw = json.load(open(gw_path))
net = json.load(open(net_path))
try:
    head = subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True, cwd=".").stdout.strip()
except Exception:
    head = ""
records = gw["records"] + net["records"]
out = {
    "schema": "slaat-p1-1-network-findings/v1",
    "card": "SLAAT-P1-1",
    "generated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "cluster_context": ctx,
    "repo_head": head,
    "components": {
        "envoy_gateway_audit": {"probe_count": gw["probe_count"], "fail_count": gw["fail_count"]},
        "network_isolation_audit": {"record_count": net["record_count"], "fail_count": net["fail_count"]},
    },
    "total_record_count": len(records),
    "total_fail_count": gw["fail_count"] + net["fail_count"],
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
    kubectl --context "${CLUSTER_CONTEXT}" delete pods -A -l slaat.controlplane.io/probe=p1-1 \
      --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Envoy Gateway audit assertions
# ─────────────────────────────────────────────────────────────────────────────

@test "gateway audit: evidence file was produced" {
  require_evidence "${GW_AUDIT_JSON}" "${GW_HARNESS_LOG}" "envoy-gateway-audit.sh"
  run jq -e '.schema == "slaat-p1-1-gateway-audit/v1"' "${GW_AUDIT_JSON}"
  [ "$status" -eq 0 ]
}

@test "gateway audit: at least 15 distinct probe vectors executed" {
  require_evidence "${GW_AUDIT_JSON}" "${GW_HARNESS_LOG}" "envoy-gateway-audit.sh"
  run jq -r '.probe_count' "${GW_AUDIT_JSON}"
  [ "$status" -eq 0 ]
  [ "$output" -ge 15 ]
}

@test "gateway audit: unregistered SNI is rejected before any HTTP routing" {
  require_evidence "${GW_AUDIT_JSON}" "${GW_HARNESS_LOG}" "envoy-gateway-audit.sh"
  run jq -r '.records[] | select(.id == "GW-VHOST-1") | .severity' "${GW_AUDIT_JSON}"
  [ "$status" -eq 0 ]
  [ "$output" = "pass" ]
}

@test "gateway audit: spoofed Host header does not cross into another tenant's route" {
  require_evidence "${GW_AUDIT_JSON}" "${GW_HARNESS_LOG}" "envoy-gateway-audit.sh"
  run jq -r '.records[] | select(.id == "GW-VHOST-2") | .observed_code' "${GW_AUDIT_JSON}"
  [ "$status" -eq 0 ]
  [ "$output" = "404" ]
}

@test "gateway audit: dot-segment and encoded-dot-segment traversal do not escape the matched route" {
  require_evidence "${GW_AUDIT_JSON}" "${GW_HARNESS_LOG}" "envoy-gateway-audit.sh"
  run jq -r '[.records[] | select(.id == "GW-TRAV-1" or .id == "GW-TRAV-2" or .id == "GW-TRAV-3") | .severity] | unique | .[]' "${GW_AUDIT_JSON}"
  [ "$status" -eq 0 ]
  [ "$output" = "pass" ]
}

@test "gateway audit: encoded-slash path never reaches a backend (path_normalization_failed, no upstream contacted)" {
  require_evidence "${GW_AUDIT_JSON}" "${GW_HARNESS_LOG}" "envoy-gateway-audit.sh"
  run jq -r '.records[] | select(.id == "GW-TRAV-4") | .observed_code' "${GW_AUDIT_JSON}"
  [ "$status" -eq 0 ]
  [ "$output" = "307" ]
}

@test "gateway audit: embedded null byte is rejected as malformed (400)" {
  require_evidence "${GW_AUDIT_JSON}" "${GW_HARNESS_LOG}" "envoy-gateway-audit.sh"
  run jq -r '.records[] | select(.id == "GW-TRAV-5") | .observed_code' "${GW_AUDIT_JSON}"
  [ "$status" -eq 0 ]
  [ "$output" = "400" ]
}

@test "gateway audit: TLS 1.0 and TLS 1.1 are refused by the listener" {
  require_evidence "${GW_AUDIT_JSON}" "${GW_HARNESS_LOG}" "envoy-gateway-audit.sh"
  run jq -r '[.records[] | select(.id == "GW-TLS-1.0" or .id == "GW-TLS-1.1") | .observed_code] | unique | .[]' "${GW_AUDIT_JSON}"
  [ "$status" -eq 0 ]
  [ "$output" = "rejected" ]
}

@test "gateway audit: TLS 1.2 and TLS 1.3 are accepted with strong AEAD ciphers" {
  require_evidence "${GW_AUDIT_JSON}" "${GW_HARNESS_LOG}" "envoy-gateway-audit.sh"
  run jq -r '.records[] | select(.id == "GW-TLS-1.2") | .observed_code' "${GW_AUDIT_JSON}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TLSv1.2"* ]]
  run jq -r '.records[] | select(.id == "GW-TLS-1.3") | .observed_code' "${GW_AUDIT_JSON}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TLSv1.3"* ]]
}

@test "gateway audit: zero fail-severity findings on this run" {
  require_evidence "${GW_AUDIT_JSON}" "${GW_HARNESS_LOG}" "envoy-gateway-audit.sh"
  run jq -r '.fail_count' "${GW_AUDIT_JSON}"
  [ "$status" -eq 0 ]
  [ "$output" -eq 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# NetworkPolicy / lateral-movement assertions
# ─────────────────────────────────────────────────────────────────────────────

@test "network isolation: evidence file was produced" {
  require_evidence "${NETISO_JSON}" "${NETISO_HARNESS_LOG}" "probe-network-isolation.sh"
  run jq -e '.schema == "slaat-p1-1-netiso-audit/v1"' "${NETISO_JSON}"
  [ "$status" -eq 0 ]
}

@test "network isolation: every populated namespace was assessed for default-deny coverage" {
  require_evidence "${NETISO_JSON}" "${NETISO_HARNESS_LOG}" "probe-network-isolation.sh"
  run jq -r '[.records[] | select(.vector == "default-deny-coverage")] | length' "${NETISO_JSON}"
  [ "$status" -eq 0 ]
  [ "$output" -ge 15 ]
}

@test "network isolation: the default namespace's blanket default-deny blocks postgresql, kube-apiserver, and gateway metrics" {
  require_evidence "${NETISO_JSON}" "${NETISO_HARNESS_LOG}" "probe-network-isolation.sh"
  run jq -r '[.records[] | select(.id == "LAT-1" or .id == "LAT-2" or .id == "LAT-3") | .observed] | unique | .[]' "${NETISO_JSON}"
  [ "$status" -eq 0 ]
  [ "$output" = "blocked" ]
}

@test "network isolation: inf-signalloom's ingress policy blocks postgresql/redis even from an unrestricted source namespace" {
  require_evidence "${NETISO_JSON}" "${NETISO_HARNESS_LOG}" "probe-network-isolation.sh"
  run jq -r '[.records[] | select(.id == "LAT-7" or .id == "LAT-8") | .observed] | unique | .[]' "${NETISO_JSON}"
  [ "$status" -eq 0 ]
  [ "$output" = "blocked" ]
}

@test "network isolation: FINDING — frontend can reach backend/minio, backend/nats and backend/postgres with no NetworkPolicy on either side" {
  require_evidence "${NETISO_JSON}" "${NETISO_HARNESS_LOG}" "probe-network-isolation.sh"
  run jq -r '[.records[] | select(.id == "LAT-4" or .id == "LAT-5" or .id == "LAT-6") | .observed] | unique | .[]' "${NETISO_JSON}"
  [ "$status" -eq 0 ]
  [ "$output" = "reachable" ]
}

@test "network isolation: FINDING — the gateway control-plane namespace's metrics port is reachable from an unprivileged tenant pod" {
  require_evidence "${NETISO_JSON}" "${NETISO_HARNESS_LOG}" "probe-network-isolation.sh"
  run jq -r '.records[] | select(.id == "LAT-9") | .observed' "${NETISO_JSON}"
  [ "$status" -eq 0 ]
  [ "$output" = "reachable" ]
}

@test "network isolation: FINDING — backend, frontend, fe-k8s-afm, ingress, cpai and kagent carry no blanket default-deny" {
  require_evidence "${NETISO_JSON}" "${NETISO_HARNESS_LOG}" "probe-network-isolation.sh"
  run jq -r '[.records[] | select(.priority == "tenant" and .severity == "fail") | .namespace] | sort | join(",")' "${NETISO_JSON}"
  [ "$status" -eq 0 ]
  [ "$output" = "backend,cpai,fe-k8s-afm,frontend,ingress,kagent" ]
}

@test "network isolation: postgresql control-plane exec check is informational, not a network-path proof" {
  require_evidence "${NETISO_JSON}" "${NETISO_HARNESS_LOG}" "probe-network-isolation.sh"
  run jq -r '.records[] | select(.id == "PGREADY-1") | .severity' "${NETISO_JSON}"
  [ "$status" -eq 0 ]
  [ "$output" = "info" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Aggregated findings manifest
# ─────────────────────────────────────────────────────────────────────────────

@test "findings manifest: ci-evidence/slaat-p1-1-network-findings.json was generated and is well-formed" {
  [[ -s "${FINDINGS_JSON}" ]] || skip "no cluster '${CLUSTER_CONTEXT}' — findings manifest not regenerated this run"
  run jq -e '.schema == "slaat-p1-1-network-findings/v1" and (.total_record_count > 0)' "${FINDINGS_JSON}"
  [ "$status" -eq 0 ]
}

@test "arity: this suite defines exactly the number of tests it declares" {
  # bats -f with a zero-match filter exits 0, and a suite that stops parsing
  # partway through reports fewer tests. Both read as success without this.
  local defined
  defined="$(grep -c '^@test ' "${BATS_TEST_FILENAME}")"
  if [ "$defined" -ne "$DECLARED_TESTS" ]; then
    echo "# suite defines ${defined} tests but declares ${DECLARED_TESTS}" >&3
    false
  fi
  [ "$defined" -eq "$DECLARED_TESTS" ]
}
