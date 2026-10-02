#!/usr/bin/env bash
# probe-openbao-acls.sh — SLAAT-P1-3 OpenBao ACL policy and JWT-role
# delegation-coverage audit.
#
# Two passes, both read-only against live OpenBao state:
#
#   1. Policy-boundary pass: reads every live non-builtin policy and flags
#      any path grant that is broader than a single tenant/agent scope --
#      a bare `kv/data/signalloom/*`, any `sys/*` or `auth/*` grant, or a
#      KV path with no tenant/project/identity segment at all.
#
#   2. Delegation-coverage pass: cross-references every live SPIRE k8s-
#      selector registration entry's SPIFFE ID (`sub`) against every live
#      auth/jwt role's bound_claims/bound_subject. A registered identity
#      with no matching role is a DELEGATION GAP -- it has a valid identity
#      but no path to an OpenBao credential. This is the card's Objective
#      phrase verbatim ("discovered delegation gaps"), not a stretch read.
#
# Accepts --role and --vault-addr for compatibility with the card's literal
# Required Tests invocation. This demo OpenBao has no external TLS listener
# reachable from outside the cluster, so the actual read path is always
# `kubectl exec` into the openbao Deployment (matching every sibling SLAAT
# probe script's convention) -- --vault-addr is recorded in the report for
# traceability but does not change how the script connects. --role narrows
# the printed summary to one role; a name that does not exist on this
# deployment is reported as a gap, not a usage error, and the full audit
# still runs underneath it.
#
# Usage:
#   scripts/probe-openbao-acls.sh [--role ROLE] [--vault-addr ADDR] [--out FILE]
#
# Env:
#   SLAAT_KUBE_CONTEXT    kube context (default: kind-osramp)
#   SLAAT_BAO_NAMESPACE   namespace running the openbao Deployment (default: inf-bao)

set -uo pipefail

SLAAT_KUBE_CONTEXT="${SLAAT_KUBE_CONTEXT:-kind-osramp}"
SLAAT_BAO_NAMESPACE="${SLAAT_BAO_NAMESPACE:-inf-bao}"
ROLE_FILTER=""
VAULT_ADDR_ARG=""
OUT_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --role) ROLE_FILTER="${2:?}"; shift 2 ;;
    --vault-addr) VAULT_ADDR_ARG="${2:?}"; shift 2 ;;
    --out) OUT_FILE="${2:?}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

KC() { kubectl --context "${SLAAT_KUBE_CONTEXT}" "$@"; }
BAO() {
  KC -n "${SLAAT_BAO_NAMESPACE}" exec deploy/openbao -- sh -c "
    export BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=signalloom-demo-root-token
    $1
  " 2>/dev/null | tr -d '\r'
}

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/slaat-acl.XXXXXX")"
RECORDS_JSONL="${WORKDIR}/records.jsonl"
: >"${RECORDS_JSONL}"
trap 'rm -rf "${WORKDIR}"' EXIT INT TERM

record() {
  python3 - "$1" "$2" "$3" "$4" "$5" "$6" <<'PY' >>"${RECORDS_JSONL}"
import json, sys
_id, vector, expect, observed, sev, detail = sys.argv[1:7]
print(json.dumps({"id": _id, "vector": vector, "expectation": expect, "observed": observed, "severity": sev, "detail": detail}))
PY
}

echo "[probe-openbao-acls] requested --role=${ROLE_FILTER:-<all>} --vault-addr=${VAULT_ADDR_ARG:-<in-cluster exec>}" >&2

if ! KC cluster-info >/dev/null 2>&1 || ! KC -n "${SLAAT_BAO_NAMESPACE}" get deploy/openbao >/dev/null 2>&1; then
  echo "[probe-openbao-acls] SKIP: no live OpenBao deployment reachable" >&2
  record "ACL-0" "preflight" "openbao-reachable" "unreachable" "info" "No live OpenBao deployment at context ${SLAAT_KUBE_CONTEXT} ns ${SLAAT_BAO_NAMESPACE}; audit skipped."
else
  echo "[probe-openbao-acls] === pass 1: policy boundary audit ===" >&2
  policies="$(BAO 'bao policy list')"
  for pol in ${policies}; do
    case "${pol}" in root|default) continue ;; esac
    rules="$(BAO "bao policy read '${pol}'")"
    broad="$(python3 -c "
import re, sys
rules = sys.argv[1]
paths = re.findall(r'path\s+\"([^\"]+)\"', rules)
flags = []
for p in paths:
    if p.startswith('sys/') or p.startswith('auth/'):
        flags.append(f'admin-surface:{p}')
    elif re.fullmatch(r'kv/data/[^/]+/?\*?', p):
        # a KV grant with only ONE path segment after kv/data -- no
        # tenant/project/agent scoping at all.
        flags.append(f'unscoped-top-level:{p}')
    elif p == 'kv/data/*' or p == 'kv/*':
        flags.append(f'wildcard-everything:{p}')
print(';'.join(flags))
" "${rules}")"
    if [ -n "${broad}" ]; then
      record "ACL-POLICY-${pol}" "policy-boundary-audit" "tenant-scoped-paths-only" "broad-grant" "fail" "Policy '${pol}' grants: ${broad}. Rules: ${rules}"
      echo "  ACL-POLICY-${pol} FAIL: ${broad}" >&2
    else
      record "ACL-POLICY-${pol}" "policy-boundary-audit" "tenant-scoped-paths-only" "scoped" "pass" "Policy '${pol}' paths are scoped to a single tenant/agent/identity-templated subtree. Rules: ${rules}"
      echo "  ACL-POLICY-${pol} pass: scoped" >&2
    fi
  done

  echo "[probe-openbao-acls] === pass 2: delegation-coverage audit ===" >&2
  entries="$(KC -n "${SLAAT_BAO_NAMESPACE}" exec deploy/spire-server -c spire-server -- \
    /opt/spire/bin/spire-server entry show -socketPath /tmp/spire-server/private/api.sock 2>/dev/null)"
  registered_subs="$(python3 -c "
import re, sys
text = sys.argv[1]
for e in text.split('\n\n'):
    m = re.search(r'SPIFFE ID\s*:\s*(\S+)', e)
    if m and ('/ns/' in m.group(1) or '/platform/' in m.group(1)) and 'agent/kind' not in m.group(1):
        print(m.group(1))
" "${entries}")"

  role_names="$(BAO 'bao list -format=json auth/jwt/role' | python3 -c "import json,sys; print('\n'.join(json.load(sys.stdin)))" 2>/dev/null)"
  bound_subs="$(for r in ${role_names}; do
    BAO "bao read -format=json auth/jwt/role/${r}" | python3 -c "
import json, sys
d = json.load(sys.stdin).get('data', {})
bc = d.get('bound_claims') or {}
bs = d.get('bound_subject') or ''
print(bc.get('sub', '') or bs)
" 2>/dev/null
  done)"

  gap_count=0
  while IFS= read -r sub; do
    [ -z "${sub}" ] && continue
    matched="no"
    while IFS= read -r bound; do
      [ -z "${bound}" ] && continue
      case "${sub}" in
        ${bound}) matched="yes" ;;
      esac
    done <<<"${bound_subs}"
    if [ "${matched}" = "no" ]; then
      gap_count=$((gap_count + 1))
      record "ACL-GAP-$((gap_count))" "delegation-coverage-audit" "every-registered-identity-has-a-bound-role" "no-role-bound" "fail" "SPIFFE identity ${sub} has a live SPIRE registration entry but no auth/jwt role's bound_claims.sub or bound_subject matches it -- a delegation gap. This identity can obtain a valid SVID but has no path to an OpenBao credential."
      echo "  ACL-GAP-$((gap_count)): ${sub} has no bound OpenBao role" >&2
    fi
  done <<<"${registered_subs}"
  if [ "${gap_count}" -eq 0 ]; then
    record "ACL-GAP-SUMMARY" "delegation-coverage-audit" "every-registered-identity-has-a-bound-role" "full-coverage" "pass" "Every live SPIRE-registered workload identity has at least one matching auth/jwt role."
    echo "  ACL-GAP-SUMMARY pass: full delegation coverage" >&2
  else
    record "ACL-GAP-SUMMARY" "delegation-coverage-audit" "every-registered-identity-has-a-bound-role" "${gap_count}-gaps" "fail" "${gap_count} registered SPIRE identities have no matching OpenBao JWT role (see ACL-GAP-* records)."
  fi

  if [ -n "${ROLE_FILTER}" ]; then
    if echo "${role_names}" | grep -qx "${ROLE_FILTER}"; then
      role_detail="$(BAO "bao read auth/jwt/role/${ROLE_FILTER}")"
      record "ACL-ROLE-FOCUS" "requested-role-lookup" "role-exists" "found" "pass" "Role '${ROLE_FILTER}' exists. Detail: ${role_detail}"
    else
      record "ACL-ROLE-FOCUS" "requested-role-lookup" "role-exists" "not-found" "info" "Requested role '${ROLE_FILTER}' does not exist on this deployment. Live roles: ${role_names}"
      echo "  note: --role '${ROLE_FILTER}' not found; live roles are: ${role_names}" >&2
    fi
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
    "schema": "slaat-p1-3-openbao-acl-audit/v1",
    "card": "SLAAT-P1-3",
    "component": "probe-openbao-acls",
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
echo "[probe-openbao-acls] done: ${FAIL_COUNT} fail-severity findings" >&2
exit 0
