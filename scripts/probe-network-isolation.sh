#!/usr/bin/env bash
# probe-network-isolation.sh — SLAAT-P1-1 NetworkPolicy microsegmentation audit
# and cross-namespace lateral-movement probe.
#
# Two passes, both read-only against cluster state:
#
#   1. Coverage pass: for every namespace with running pods, does ANY
#      NetworkPolicy select ALL pods (podSelector: {}) for Ingress, and for
#      Egress? That is the only shape that behaves as a genuine default-deny --
#      a namespace with only narrow podSelector policies still leaves any pod
#      those policies don't select fully open.
#
#   2. Lateral-movement pass: launches short-lived `kubectl run --rm` busybox
#      pods (image is already cached on the kind node; no pull required) that
#      attempt a raw `nc -z` TCP connect to a fixed set of ClusterIP:port
#      targets. Pods are labelled distinctly (slaat.controlplane.io/probe=p1-1)
#      so they never inherit an unrelated mission's carve-out policy (e.g. the
#      dual-cluster SLDC mission's `app.kubernetes.io/name=probe` grant in the
#      default namespace). Every probe pod is deleted on exit (--rm) with a
#      non-blocking safety-net delete as a second line of defence.
#
# This script creates and deletes EPHEMERAL pods only. It never creates,
# modifies, or deletes a Namespace, NetworkPolicy, Gateway, or HTTPRoute --
# see the SLAAT-P1-1 card's merge boundary.
#
# Usage:
#   scripts/probe-network-isolation.sh [--out FILE] [--timeout SECONDS]
#
# Env:
#   SLAAT_KUBE_CONTEXT   kube context (default: kind-osramp)
#   SLAAT_PROBE_IMAGE    probe pod image (default: busybox:1.36.1, pre-cached)

set -uo pipefail

SLAAT_KUBE_CONTEXT="${SLAAT_KUBE_CONTEXT:-kind-osramp}"
SLAAT_PROBE_IMAGE="${SLAAT_PROBE_IMAGE:-busybox:1.36.1}"
TIMEOUT=3
OUT_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT_FILE="${2:?}"; shift 2 ;;
    --timeout) TIMEOUT="${2:?}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/slaat-netiso.XXXXXX")"
RECORDS_JSONL="${WORKDIR}/records.jsonl"
: >"${RECORDS_JSONL}"
cleanup() { rm -rf "${WORKDIR}"; }
trap cleanup EXIT INT TERM

KC() { kubectl --context "${SLAAT_KUBE_CONTEXT}" "$@"; }

echo "[probe-network-isolation] === pass 1: NetworkPolicy coverage audit ===" >&2
namespaces="$(KC get pods -A --no-headers 2>/dev/null | awk '{print $1}' | sort -u)"
# Namespaces this mission treats as "governed application tenants" -- the
# Verified Facts in the SLAAT-P1-1 card name these as the zero-trust boundary.
# Core platform namespaces (kube-system, cert-manager, spire-system,
# local-path-storage, registry) are reported too, but scored lower-priority:
# a blanket default-deny there risks breaking CNI/DNS/ACME/attestation
# plumbing and needs a carefully-scoped allowlist, not a blind copy of the
# tenant pattern.
PLATFORM_NAMESPACES="kube-system cert-manager spire-system local-path-storage registry kube-node-lease kube-public"

for ns in ${namespaces}; do
  pol_json="$(KC -n "${ns}" get networkpolicy -o json 2>/dev/null || echo '{"items":[]}')"
  pods="$(KC -n "${ns}" get pods --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  read -r policy_count blanket_ingress blanket_egress <<EOF
$(python3 - "${pol_json}" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
items = d.get("items", [])
bi = any(it["spec"].get("podSelector", {}) == {} and "Ingress" in it["spec"].get("policyTypes", []) for it in items)
be = any(it["spec"].get("podSelector", {}) == {} and "Egress" in it["spec"].get("policyTypes", []) for it in items)
print(len(items), "yes" if bi else "no", "yes" if be else "no")
PY
)
EOF
  priority="tenant"
  for p in ${PLATFORM_NAMESPACES}; do [ "${ns}" = "${p}" ] && priority="platform"; done
  severity="pass"
  if [ "${blanket_ingress}" = "no" ] || [ "${blanket_egress}" = "no" ]; then
    severity="fail"
    [ "${priority}" = "platform" ] && severity="advisory"
  fi
  python3 - "${ns}" "${pods}" "${policy_count}" "${blanket_ingress}" "${blanket_egress}" "${priority}" "${severity}" <<'PY' >>"${RECORDS_JSONL}"
import json, sys
ns, pods, pol, bi, be, prio, sev = sys.argv[1:8]
print(json.dumps({
    "id": f"NETPOL-{ns}", "vector": "default-deny-coverage", "namespace": ns,
    "pod_count": int(pods), "policy_count": int(pol),
    "blanket_ingress_deny": bi == "yes", "blanket_egress_deny": be == "yes",
    "priority": prio, "severity": sev,
}))
PY
done

echo "[probe-network-isolation] === pass 2: lateral-movement probes ===" >&2
lateral_probe() {
  # lateral_probe ID SOURCE_NS LABEL TARGET_DESC IP PORT
  #
  # The zero-trust expectation under test is ALWAYS "blocked" -- the SLAAT-P1-1
  # card's Verified Facts state workload ingress must route strictly through
  # Envoy Gateway or an explicit peer NetworkPolicy, for every governed
  # namespace. There is no probe here where "reachable" is the desired
  # outcome: a reachable target from an unprivileged probe pod IS the
  # adversarial finding (fail), a blocked one IS the control holding (pass).
  local id="$1" ns="$2" label="$3" desc="$4" ip="$5" port="$6"
  local pod="slaat-p1-1-${label}-$$-${RANDOM}"
  local rc
  KC -n "${ns}" run "${pod}" \
    --image="${SLAAT_PROBE_IMAGE}" --restart=Never --rm -i --attach \
    --labels="slaat.controlplane.io/probe=p1-1,slaat.controlplane.io/role=${label}" \
    --quiet --command -- timeout "${TIMEOUT}" nc -z -w "${TIMEOUT}" "${ip}" "${port}" \
    >/dev/null 2>&1
  rc=$?
  KC -n "${ns}" delete pod "${pod}" --ignore-not-found --wait=false >/dev/null 2>&1
  local observed severity
  if [ "${rc}" -eq 0 ]; then observed="reachable"; severity="fail"; else observed="blocked"; severity="pass"; fi
  python3 - "${id}" "${ns}" "${desc}" "${ip}" "${port}" "${observed}" "${rc}" "${severity}" <<'PY' >>"${RECORDS_JSONL}"
import json, sys
_id, ns, desc, ip, port, observed, rc, sev = sys.argv[1:9]
print(json.dumps({
    "id": _id, "vector": "lateral-movement", "source_namespace": ns,
    "target": desc, "target_ip": ip, "target_port": int(port),
    "zero_trust_expectation": "blocked", "observed": observed, "nc_exit_code": int(rc),
    "severity": sev,
}))
PY
  echo "  ${ns} -> ${desc} (${ip}:${port}): observed=${observed} severity=${severity}" >&2
}

# Baseline: `default` ns carries a blanket default-deny and grants this
# probe's label nothing extra -- the strictest case in the cluster.
lateral_probe LAT-1 default baseline "inf-signalloom/postgresql" 10.96.124.70 5432
lateral_probe LAT-2 default baseline "kube-apiserver"            10.96.0.1    443
lateral_probe LAT-3 default baseline "ingress/envoy-gateway-metrics" 10.96.146.65 19001

# frontend and backend both carry ZERO NetworkPolicy objects (see pass 1) --
# this is the "Missing DefaultDeny" failure mode named on the SLAAT-P1-1 card,
# demonstrated concretely rather than inferred from policy counts alone. Both
# are expected (and found) to FAIL the zero-trust expectation above.
lateral_probe LAT-4 frontend open-to-open "backend/minio"    10.96.137.247 9000
lateral_probe LAT-5 frontend open-to-open "backend/nats"     10.96.101.44  4222
lateral_probe LAT-6 frontend open-to-open "backend/postgres" 10.96.155.95  5432

# Same unprotected source, but the target namespace (inf-signalloom) DOES
# carry a default-deny + narrow allow-list -- defense-in-depth should hold
# even though the source has no egress restriction at all.
lateral_probe LAT-7 frontend open-to-protected "inf-signalloom/postgresql" 10.96.124.70 5432
lateral_probe LAT-8 frontend open-to-protected "inf-signalloom/redis"      10.96.53.136 6379

# The Gateway control-plane namespace itself carries zero NetworkPolicy
# objects, so its metrics port is reachable from any unprivileged tenant pod.
lateral_probe LAT-9 frontend open-to-gw-admin "ingress/envoy-gateway-metrics" 10.96.146.65 19001

echo "[probe-network-isolation] === sanctioned exec check (control-plane channel, NOT a network-path test) ===" >&2
pg_out="$(KC -n inf-signalloom exec deployment/postgresql -- pg_isready 2>&1)"
pg_rc=$?
python3 - "${pg_rc}" "${pg_out}" <<'PY' >>"${RECORDS_JSONL}"
import json, sys
rc, out = sys.argv[1], sys.argv[2]
print(json.dumps({
    "id": "PGREADY-1", "vector": "control-plane-exec", "namespace": "inf-signalloom",
    "command": "kubectl exec deployment/postgresql -- pg_isready", "exit_code": int(rc),
    "output": out.strip(), "severity": "info",
    "note": "kubectl exec runs over the API-server->kubelet exec stream, not the pod network; it does NOT traverse NetworkPolicy and must not be read as evidence about network isolation. Included only because the card's Required Tests name it explicitly.",
}))
PY

python3 - "${RECORDS_JSONL}" <<'PY' > "${WORKDIR}/final.json"
import json, sys
records = []
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if line:
            records.append(json.loads(line))
out = {
    "schema": "slaat-p1-1-netiso-audit/v1",
    "card": "SLAAT-P1-1",
    "component": "probe-network-isolation",
    "generated_at": __import__("datetime").datetime.now(__import__("datetime").timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "record_count": len(records),
    "fail_count": sum(1 for r in records if r["severity"] == "fail"),
    "records": records,
}
print(json.dumps(out, indent=2))
PY

if [ -n "${OUT_FILE}" ]; then
  cp "${WORKDIR}/final.json" "${OUT_FILE}"
fi
cat "${WORKDIR}/final.json"

FAIL_COUNT="$(python3 -c "import json; print(json.load(open('${WORKDIR}/final.json'))['fail_count'])")"
echo "[probe-network-isolation] done: ${FAIL_COUNT} fail-severity findings" >&2
exit 0
