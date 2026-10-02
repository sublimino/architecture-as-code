#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 ControlPlane Security Authors
#
# test/network-microsegmentation-hardening.bats : SLAAT-P2-1 remediation suite
#
# @id      slaat-p2-1-network-microsegmentation-hardening
# @target  d2-osramp-apps/components/backend/base/networkpolicy.yaml,
#          d2-osramp-apps/components/frontend/base/networkpolicy.yaml,
#          d2-infra/components/ingress/configs/base/networkpolicy.yaml,
#          d2-infra/components/ingress/configs/base/clienttrafficpolicy.yaml,
#          d2-signalloom/infra/kagent/base/networkpolicy.yaml
# @doc     docs/slaat/p2-1/network-microsegmentation-hardening-report.md
# @spec    SLAAT-P2-1
#
# SLAAT-P2-1 -- Ingress Route Protection & Network Microsegmentation Fixes.
#
# Tier 1 (hermetic, always runs): `kustomize build` + `kubectl apply
# --dry-run=client` for every kustomize tree this card touched, plus static
# shape assertions on the new manifests (yq-driven, no cluster needed).
#
# Tier 2 (live, skips without a cluster): precision probes proving the fix is
# neither too loose (an unauthorized pod still blocked) nor too tight (the
# one legitimate consumer still works), plus an end-to-end proof that the
# ClientTrafficPolicy actually strips a spoofed X-Forwarded-For/X-Real-IP
# rather than merely declaring the CRD fields. Every probe pod is
# self-deleting (--rm) with a non-blocking safety-net delete in teardown.

export PATH="/usr/bin:/home/linuxbrew/.linuxbrew/bin:$PATH"
DECLARED_TESTS=14

REPO_ROOT="$(cd -- "$(dirname -- "${BATS_TEST_FILENAME}")/.." && pwd)"
CLUSTER_CONTEXT="${SLAAT_KUBE_CONTEXT:-kind-osramp}"
BACKEND_NETPOL="${REPO_ROOT}/d2-osramp-apps/components/backend/base/networkpolicy.yaml"
FRONTEND_NETPOL="${REPO_ROOT}/d2-osramp-apps/components/frontend/base/networkpolicy.yaml"
INGRESS_NETPOL="${REPO_ROOT}/d2-infra/components/ingress/configs/base/networkpolicy.yaml"
CTP="${REPO_ROOT}/d2-infra/components/ingress/configs/base/clienttrafficpolicy.yaml"
KAGENT_NETPOL="${REPO_ROOT}/d2-signalloom/infra/kagent/base/networkpolicy.yaml"

have_cluster() {
  kubectl --context "${CLUSTER_CONTEXT}" cluster-info >/dev/null 2>&1
}

KC() { kubectl --context "${CLUSTER_CONTEXT}" "$@"; }

# probe_tcp NS LABEL IP PORT -> prints "reachable" or "blocked" on stdout
probe_tcp() {
  local ns="$1" label="$2" ip="$3" port="$4"
  local pod="slaat-p2-1-${label}-$$-${RANDOM}"
  KC -n "${ns}" run "${pod}" \
    --image=busybox:1.36.1 --restart=Never --rm -i --attach \
    --labels="slaat.controlplane.io/probe=p2-1,slaat.controlplane.io/role=${label}" \
    --overrides="{\"metadata\":{\"labels\":{\"app\":\"${label}\"}}}" \
    --quiet --command -- timeout 3 nc -z -w 3 "${ip}" "${port}" \
    >/dev/null 2>&1
  local rc=$?
  KC -n "${ns}" delete pod "${pod}" --ignore-not-found --wait=false >/dev/null 2>&1
  [ "${rc}" -eq 0 ] && echo reachable || echo blocked
}

teardown_file() {
  if have_cluster; then
    KC delete pods -A -l slaat.controlplane.io/probe=p2-1 --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Tier 1: hermetic manifest shape
# ─────────────────────────────────────────────────────────────────────────────

@test "kustomize build: all four touched trees build cleanly" {
  run kubectl kustomize "${REPO_ROOT}/d2-osramp-apps/components/backend/base"
  [ "$status" -eq 0 ]
  run kubectl kustomize "${REPO_ROOT}/d2-osramp-apps/components/frontend/base"
  [ "$status" -eq 0 ]
  run kubectl kustomize "${REPO_ROOT}/d2-infra/components/ingress/configs/base"
  [ "$status" -eq 0 ]
  run kubectl kustomize "${REPO_ROOT}/d2-signalloom/infra/kagent/base"
  [ "$status" -eq 0 ]
}

@test "kubectl apply --dry-run=client: inf-signalloom base still validates (shared-file collision check)" {
  run kubectl apply --dry-run=client -k "${REPO_ROOT}/d2-signalloom/infra/inf-signalloom/configs/base"
  [ "$status" -eq 0 ]
}

docs_json() {
  # Render every document in a multi-doc YAML file as one JSON array in a
  # temp file, printing the temp path on stdout. yq's own multi-doc boolean
  # chaining (`select(...) | ... and ...`) is unreliable across non-matching
  # documents in a stream (observed: non-matching docs leak stray
  # "false"/"Error: no matches found" into the result); a temp-file handoff
  # into python3 -- rather than inlining JSON as a shell string, which would
  # break on the double quotes JSON itself contains -- is the safe version
  # of the same house convention the probe scripts already use.
  local tmp
  tmp="$(mktemp "${BATS_TEST_TMPDIR:-/tmp}/netpol-docs.XXXXXX.json")"
  yq -o=json ea '[.]' "$1" >"${tmp}"
  echo "${tmp}"
}

@test "backend networkpolicy.yaml declares a blanket podSelector:{} default-deny for Ingress and Egress" {
  local docs; docs="$(docs_json "${BACKEND_NETPOL}")"
  run python3 -c "
import json
docs = json.load(open('${docs}'))
d = next(x for x in docs if x['metadata']['name'] == 'default-deny')
assert d['spec']['podSelector'] == {}
assert set(d['spec']['policyTypes']) == {'Ingress', 'Egress'}
"
  [ "$status" -eq 0 ]
}

@test "frontend networkpolicy.yaml declares a blanket podSelector:{} default-deny for Ingress and Egress" {
  local docs; docs="$(docs_json "${FRONTEND_NETPOL}")"
  run python3 -c "
import json
docs = json.load(open('${docs}'))
d = next(x for x in docs if x['metadata']['name'] == 'default-deny')
assert d['spec']['podSelector'] == {}
assert set(d['spec']['policyTypes']) == {'Ingress', 'Egress'}
"
  [ "$status" -eq 0 ]
}

@test "ingress networkpolicy.yaml is deliberately NOT a blanket default-deny (scoped to the control-plane pods and Ingress only)" {
  # No podSelector:{} anywhere in this file, and no Egress policyType -- see
  # the file's own header comment for why (apiserver watch + cross-namespace
  # proxying egress).
  local docs; docs="$(docs_json "${INGRESS_NETPOL}")"
  run python3 -c "
import json
docs = json.load(open('${docs}'))
assert not any(d['spec']['podSelector'] == {} for d in docs)
assert not any('Egress' in d['spec']['policyTypes'] for d in docs)
assert all('Ingress' in d['spec']['policyTypes'] for d in docs)
"
  [ "$status" -eq 0 ]
}

@test "ingress networkpolicy.yaml restricts the LAT-9 metrics port (19001) on both envoy-gateway and the data-plane proxy" {
  local docs; docs="$(docs_json "${INGRESS_NETPOL}")"
  run python3 -c "
import json
docs = json.load(open('${docs}'))
names = {'restrict-envoy-gateway-control-plane', 'restrict-envoy-proxy-control-ports'}
hits = 0
for d in docs:
    if d['metadata']['name'] not in names:
        continue
    for rule in d['spec']['ingress']:
        for p in rule.get('ports', []):
            if p['port'] == 19001:
                hits += 1
assert hits == 2, hits
"
  [ "$status" -eq 0 ]
}

@test "ingress networkpolicy.yaml still allows the external data-plane listeners (10080/10443) from anywhere" {
  local docs; docs="$(docs_json "${INGRESS_NETPOL}")"
  run python3 -c "
import json
docs = json.load(open('${docs}'))
d = next(x for x in docs if x['metadata']['name'] == 'restrict-envoy-proxy-control-ports')
open_ports = sorted(
    p['port'] for rule in d['spec']['ingress'] if 'from' not in rule for p in rule['ports']
)
assert open_ports == [10080, 10443], open_ports
"
  [ "$status" -eq 0 ]
}

@test "clienttrafficpolicy.yaml strips X-Forwarded-For and X-Real-IP and declares a one-hop trust boundary" {
  run yq -e '.spec.headers.earlyRequestHeaders.remove | contains(["X-Forwarded-For", "X-Real-IP"])' "${CTP}"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
  run yq -e '.spec.clientIPDetection.xForwardedFor.numTrustedHops' "${CTP}"
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
  run yq -e '.spec.targetRefs[0].kind' "${CTP}"
  [ "$status" -eq 0 ]
  [ "$output" = "Gateway" ]
}

@test "kagent networkpolicy.yaml adds ingress-only coverage for controller, ui, and the tools-metrics port" {
  local docs; docs="$(docs_json "${KAGENT_NETPOL}")"
  run python3 -c "
import json
docs = json.load(open('${docs}'))
names = {'kagent-controller-ingress', 'kagent-ui-ingress', 'kagent-tools-metrics-ingress'}
matched = [d for d in docs if d['metadata']['name'] in names]
assert len(matched) == 3, len(matched)
assert all(d['spec']['policyTypes'] == ['Ingress'] for d in matched)
"
  [ "$status" -eq 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Tier 2: live precision probes
# ─────────────────────────────────────────────────────────────────────────────

@test "live: an unlabelled frontend pod cannot reach backend/postgres, but a pod labelled osramp-archiver can" {
  have_cluster || skip "no cluster '${CLUSTER_CONTEXT}'"
  PG_IP="$(KC -n backend get svc postgres -o jsonpath='{.spec.clusterIP}')"
  [ -n "${PG_IP}" ]
  run probe_tcp frontend generic-worker "${PG_IP}" 5432
  [ "$output" = "blocked" ]
  run probe_tcp frontend osramp-archiver "${PG_IP}" 5432
  [ "$output" = "reachable" ]
}

@test "live: the Gateway control-plane metrics port (19001) is blocked from an unprivileged pod, same-namespace stays open" {
  have_cluster || skip "no cluster '${CLUSTER_CONTEXT}'"
  GW_IP="$(KC -n ingress get svc envoy-gateway -o jsonpath='{.spec.clusterIP}')"
  [ -n "${GW_IP}" ]
  run probe_tcp frontend outsider "${GW_IP}" 19001
  [ "$output" = "blocked" ]
  run probe_tcp ingress same-namespace "${GW_IP}" 19001
  [ "$output" = "reachable" ]
}

@test "live: kagent-controller's A2A port (8083) is blocked from an arbitrary namespace, open from fe-signalloom-agents" {
  have_cluster || skip "no cluster '${CLUSTER_CONTEXT}'"
  KC get ns fe-signalloom-agents >/dev/null 2>&1 || skip "fe-signalloom-agents namespace not present"
  CTRL_IP="$(KC -n kagent get svc kagent-controller -o jsonpath='{.spec.clusterIP}')"
  [ -n "${CTRL_IP}" ]
  run probe_tcp default outsider "${CTRL_IP}" 8083
  [ "$output" = "blocked" ]
  # fe-signalloom-agents carries its own default-deny with a narrow egress
  # allow-list (allow-kagent-managed-agents), scoped to
  # app.kubernetes.io/managed-by=kagent -- that label, not a generic one, is
  # what actually clears fe-signalloom-agents' own egress boundary, so the
  # probe pod needs it to isolate THIS card's ingress rule as the thing under
  # test rather than tripping over a different card's egress policy.
  pod="slaat-p2-1-managed-agent-$$-${RANDOM}"
  KC -n fe-signalloom-agents run "${pod}" \
    --image=busybox:1.36.1 --restart=Never --rm -i --attach \
    --labels="slaat.controlplane.io/probe=p2-1,app.kubernetes.io/managed-by=kagent" \
    --quiet --command -- timeout 3 nc -z -w 3 "${CTRL_IP}" 8083 \
    >/dev/null 2>&1
  rc=$?
  KC -n fe-signalloom-agents delete pod "${pod}" --ignore-not-found --wait=false >/dev/null 2>&1
  [ "${rc}" -eq 0 ]
}

xff_strip_probe() {
  # shellcheck source=scripts/lib/slaat-portforward.sh
  source "${REPO_ROOT}/scripts/lib/slaat-portforward.sh"
  GW_SERVICE="$(KC -n ingress get svc -l gateway.envoyproxy.io/owning-gateway-name=cluster -o name | head -1)"
  [ -n "${GW_SERVICE}" ] || { echo "no gateway service found" >&2; return 1; }
  local logfile marker pf_pid
  logfile="$(mktemp "${BATS_TEST_TMPDIR:-/tmp}/xff-probe.XXXXXX")"
  pf_pid="$(slaat_portforward_start ingress "${GW_SERVICE}" 18444 443 "${logfile}")"
  trap 'slaat_portforward_stop "'"${pf_pid}"'"' RETURN
  slaat_portforward_wait_ready 127.0.0.1 18444 20 || { echo "port-forward never ready" >&2; return 1; }
  marker="slaat-p2-1-spoof-$$-${RANDOM}"
  curl -ks --resolve "dashboard.osramp.acme.local:18444:127.0.0.1" --max-time 5 \
    -H "X-Forwarded-For: ${marker}" -H "X-Real-IP: ${marker}" \
    -o /dev/null "https://dashboard.osramp.acme.local:18444/" >/dev/null 2>&1
  sleep 2
  if KC -n ingress logs -l gateway.envoyproxy.io/owning-gateway-name=cluster -c envoy --since=30s --tail=200 2>/dev/null | grep -q "${marker}"; then
    echo "SPOOFED VALUE SURVIVED into the access log" >&2
    return 1
  fi
  return 0
}

@test "live: a spoofed X-Forwarded-For/X-Real-IP sent through the Gateway does not survive into the upstream request" {
  have_cluster || skip "no cluster '${CLUSTER_CONTEXT}'"
  run xff_strip_probe
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
