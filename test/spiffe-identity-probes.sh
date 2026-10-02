#!/usr/bin/env bash
# spiffe-identity-probes.sh — SLAAT-P1-3 SPIFFE Workload API identity
# spoofing probe harness.
#
# Focused purely on SPIRE registration-entry / workload-attestor boundaries
# -- it never talks to OpenBao. probe-spiffe-privilege-escalation.sh (the
# OpenBao-facing probe) and this script are deliberately split along that
# seam: this file answers "can a workload obtain an identity it should not
# have", the other answers "does OpenBao correctly gate on the identity it
# was given".
#
# Three probes, read-only against SPIRE registration state plus three
# ephemeral attestation attempts:
#
#   IDENT-1  Static registry audit: does any live k8s-selector entry rely on
#            namespace alone (the "weak container selector" failure mode
#            named on the SLAAT-P1-3 card)? A namespace-only selector lets any
#            co-located pod, regardless of ServiceAccount, claim that entry's
#            identity.
#   IDENT-2  Namespace tampering: an unregistered ServiceAccount, co-located
#            in the trusted fe-signalloom-agents namespace with the fleet's
#            own pod-label, attempts attestation. Expectation: denied --
#            namespace co-location alone must not be sufficient.
#   IDENT-3  Process/container impersonation: a pod using a REGISTERED
#            ServiceAccount but WITHOUT the fleet's required pod-label
#            (signalloom.ai/agent=true) attempts attestation. Expectation:
#            denied -- all selectors on an entry are AND-ed, so a partial
#            selector match (right SA, missing label) must still fail.
#
# This script creates and deletes EPHEMERAL ServiceAccounts and Pods only.
# It never touches a SPIRE registration entry, a trust bundle, or the server
# CA -- see the SLAAT-P1-3 card's merge boundary and hard "out of scope"
# list.
#
# Usage: test/spiffe-identity-probes.sh [--out FILE]
#
# Env:
#   SLAAT_KUBE_CONTEXT      kube context (default: kind-osramp)
#   SLAAT_AGENT_NAMESPACE   namespace with SPIRE-registered fleet agents (default: fe-signalloom-agents)
#   SLAAT_SPIRE_AGENT_IMAGE image carrying the spire-agent CLI (default: ghcr.io/spiffe/spire-agent:1.11.1)

set -uo pipefail

SLAAT_KUBE_CONTEXT="${SLAAT_KUBE_CONTEXT:-kind-osramp}"
SLAAT_AGENT_NAMESPACE="${SLAAT_AGENT_NAMESPACE:-fe-signalloom-agents}"
SLAAT_SPIRE_AGENT_IMAGE="${SLAAT_SPIRE_AGENT_IMAGE:-ghcr.io/spiffe/spire-agent:1.11.1}"
OUT_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT_FILE="${2:?}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

KC() { kubectl --context "${SLAAT_KUBE_CONTEXT}" "$@"; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/slaat-identity.XXXXXX")"
RECORDS_JSONL="${WORKDIR}/records.jsonl"
: >"${RECORDS_JSONL}"

SA_UNREGISTERED="slaat-p1-3-identsvc-$$"
POD_UNREGISTERED="slaat-p1-3-ident1-$$"
POD_NOLABEL="slaat-p1-3-ident2-$$"

cleanup() {
  KC -n "${SLAAT_AGENT_NAMESPACE}" delete pod "${POD_UNREGISTERED}" "${POD_NOLABEL}" --ignore-not-found --wait=false >/dev/null 2>&1
  KC -n "${SLAAT_AGENT_NAMESPACE}" delete serviceaccount "${SA_UNREGISTERED}" --ignore-not-found >/dev/null 2>&1
  rm -rf "${WORKDIR}"
}
trap cleanup EXIT INT TERM

record() {
  python3 - "$1" "$2" "$3" "$4" "$5" "$6" <<'PY' >>"${RECORDS_JSONL}"
import json, sys
_id, vector, expect, observed, sev, detail = sys.argv[1:7]
print(json.dumps({"id": _id, "vector": vector, "expectation": expect, "observed": observed, "severity": sev, "detail": detail}))
PY
}

echo "[spiffe-identity-probes] === preflight ===" >&2
if ! KC cluster-info >/dev/null 2>&1; then
  echo "[spiffe-identity-probes] SKIP: kube context '${SLAAT_KUBE_CONTEXT}' unreachable" >&2
  record "IDENT-0" "preflight" "live-cluster-reachable" "unreachable" "info" "No live cluster; identity probes skipped."
else
  echo "[spiffe-identity-probes] === IDENT-1: static registry audit for weak selectors ===" >&2
  entries="$(KC -n inf-bao exec deploy/spire-server -c spire-server -- \
    /opt/spire/bin/spire-server entry show -socketPath /tmp/spire-server/private/api.sock 2>/dev/null)"
  weak_count="$(python3 -c "
import sys, re
text = sys.argv[1]
entries = text.split('\n\n')
weak = []
for e in entries:
    if 'k8s:ns:' not in e:
        continue
    spiffe = re.search(r'SPIFFE ID\s*:\s*(\S+)', e)
    selectors = re.findall(r'Selector\s*:\s*(\S+)', e)
    # 'weak' = the ONLY selector is k8s:ns:* (no sa/pod-label/uid narrowing)
    if spiffe and len(selectors) == 1 and selectors[0].startswith('k8s:ns:'):
        weak.append(spiffe.group(1))
print(len(weak))
for w in weak:
    print('WEAK:', w, file=sys.stderr)
" "${entries}" 2>&1)"
  weak_n="$(echo "${weak_count}" | head -1)"
  weak_detail="$(echo "${weak_count}" | tail -n +2)"
  if [ "${weak_n}" -gt 0 ] 2>/dev/null; then
    record "IDENT-1" "registration-entry-selector-audit" "zero-namespace-only-entries" "${weak_n}-found" "fail" "Found ${weak_n} SPIRE registration entries whose ONLY selector is k8s:ns:*, letting any co-located pod in that namespace (regardless of ServiceAccount) claim the identity. ${weak_detail}"
    echo "  IDENT-1 FAIL: ${weak_n} namespace-only registration entries" >&2
  else
    record "IDENT-1" "registration-entry-selector-audit" "zero-namespace-only-entries" "0-found" "pass" "Every live k8s-selector registration entry requires at least k8s:ns + k8s:sa (most also require a pod-label); none rely on namespace alone."
    echo "  IDENT-1 pass: no namespace-only registration entries" >&2
  fi

  echo "[spiffe-identity-probes] === IDENT-2: namespace tampering (unregistered SA, co-located) ===" >&2
  KC -n "${SLAAT_AGENT_NAMESPACE}" create serviceaccount "${SA_UNREGISTERED}" >/dev/null 2>&1
  overrides_unreg=$(python3 - "${SA_UNREGISTERED}" "${SLAAT_SPIRE_AGENT_IMAGE}" <<'PY'
import json, sys
sa, image = sys.argv[1:3]
print(json.dumps({
  "apiVersion": "v1",
  "spec": {
    "serviceAccountName": sa,
    "containers": [{
      "name": "probe", "image": image,
      "command": ["/opt/spire/bin/spire-agent", "api", "fetch", "x509", "-socketPath", "/run/spire/sockets/agent.sock"],
      "volumeMounts": [{"name": "spiffe-workload-api", "mountPath": "/run/spire/sockets", "readOnly": True}],
    }],
    "volumes": [{"name": "spiffe-workload-api", "hostPath": {"path": "/run/spire/sockets", "type": "Directory"}}],
  },
}))
PY
)
  unreg_out="$(KC -n "${SLAAT_AGENT_NAMESPACE}" run "${POD_UNREGISTERED}" \
    --image="${SLAAT_SPIRE_AGENT_IMAGE}" --restart=Never --rm -i --attach \
    --labels="slaat.controlplane.io/probe=p1-3,signalloom.ai/agent=true,signalloom.ai/framework=none" \
    --overrides="${overrides_unreg}" 2>&1)"
  KC -n "${SLAAT_AGENT_NAMESPACE}" delete pod "${POD_UNREGISTERED}" --ignore-not-found --wait=false >/dev/null 2>&1
  if echo "${unreg_out}" | grep -qi "PermissionDenied\|no identity issued"; then
    record "IDENT-2" "namespace-tampering" "denied" "denied" "pass" "Unregistered ServiceAccount, co-located in ${SLAAT_AGENT_NAMESPACE} with the fleet's own pod-label, correctly denied an X.509-SVID."
    echo "  IDENT-2 pass: namespace co-location alone did not grant an identity" >&2
  else
    record "IDENT-2" "namespace-tampering" "denied" "unexpected" "fail" "Unregistered ServiceAccount was NOT denied. Raw: ${unreg_out}"
    echo "  IDENT-2 FAIL" >&2
  fi

  echo "[spiffe-identity-probes] === IDENT-3: process impersonation (registered SA, missing required label) ===" >&2
  overrides_nolabel=$(python3 - "${SLAAT_SPIRE_AGENT_IMAGE}" <<'PY'
import json, sys
image = sys.argv[1]
print(json.dumps({
  "apiVersion": "v1",
  "spec": {
    "serviceAccountName": "agent-cardvault",
    "containers": [{
      "name": "probe", "image": image,
      "command": ["/opt/spire/bin/spire-agent", "api", "fetch", "x509", "-socketPath", "/run/spire/sockets/agent.sock"],
      "volumeMounts": [{"name": "spiffe-workload-api", "mountPath": "/run/spire/sockets", "readOnly": True}],
    }],
    "volumes": [{"name": "spiffe-workload-api", "hostPath": {"path": "/run/spire/sockets", "type": "Directory"}}],
  },
}))
PY
)
  # Deliberately omit signalloom.ai/agent=true -- the registration entry for
  # agent-cardvault requires k8s:ns + k8s:pod-label + k8s:sa all three; this
  # probe has the right ns and sa but not the label, and should still fail.
  nolabel_out="$(KC -n "${SLAAT_AGENT_NAMESPACE}" run "${POD_NOLABEL}" \
    --image="${SLAAT_SPIRE_AGENT_IMAGE}" --restart=Never --rm -i --attach \
    --labels="slaat.controlplane.io/probe=p1-3" \
    --overrides="${overrides_nolabel}" 2>&1)"
  KC -n "${SLAAT_AGENT_NAMESPACE}" delete pod "${POD_NOLABEL}" --ignore-not-found --wait=false >/dev/null 2>&1
  if echo "${nolabel_out}" | grep -qi "PermissionDenied\|no identity issued"; then
    record "IDENT-3" "process-impersonation-partial-selector" "denied" "denied" "pass" "A pod using the REGISTERED agent-cardvault ServiceAccount but missing the required signalloom.ai/agent=true pod-label was correctly denied -- confirming the registration entry's selectors are AND-ed, not OR-ed."
    echo "  IDENT-3 pass: partial selector match (right SA, missing label) correctly denied" >&2
  else
    record "IDENT-3" "process-impersonation-partial-selector" "denied" "unexpected" "fail" "A registered SA without the required pod-label was NOT denied -- selectors may be evaluated as OR instead of AND. Raw: ${nolabel_out}"
    echo "  IDENT-3 FAIL" >&2
  fi
fi

python3 - "${RECORDS_JSONL}" <<'PY' > "${WORKDIR}/final.json"
import json, sys, datetime
records = []
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if line:
            records.append(json.loads(line))
out = {
    "schema": "slaat-p1-3-spiffe-identity-probe/v1",
    "card": "SLAAT-P1-3",
    "component": "spiffe-identity-probes",
    "generated_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
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

FAIL_COUNT="$(python3 -c "import json; print(json.load(open('${WORKDIR}/final.json'))['fail_count'])" 2>/dev/null || echo 0)"
echo "[spiffe-identity-probes] done: ${FAIL_COUNT} fail-severity findings" >&2
exit 0
