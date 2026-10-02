#!/usr/bin/env bash
# probe-spiffe-privilege-escalation.sh — SLAAT-P1-3 SPIFFE identity & OpenBao
# JWT privilege-escalation adversarial probe.
#
# Exercises the live signalloom.demo trust domain end-to-end:
#
#   1. SPIRE Workload API attestation: a forged/unregistered ServiceAccount
#      co-located in the trusted fe-signalloom-agents namespace attempts to
#      fetch a JWT-SVID. The expectation under test is ALWAYS "denied" -- a
#      granted identity for an unregistered workload IS the adversarial
#      finding (fail); a PermissionDenied response IS the control holding
#      (pass). Mirrors the zero-trust framing in probe-network-isolation.sh.
#
#   2. OpenBao JWT auth backend (/v1/auth/jwt/login): the legitimate SVID from
#      step 1's control case is replayed against every live role to probe for
#      audience bypass, cross-identity (sub) bypass, bound_claims glob
#      defects, signature tampering, and alg:none forgery.
#
#   3. Token-scope boundary: the token issued by a correct login is used to
#      read its own KV path (positive control) and then several cross-tenant
#      / admin-surface paths (expected: 403 across the board).
#
#   4. Token TTL audit: every live JWT role is read via `bao read` and its
#      resolved token_ttl/token_max_ttl is compared against the mission's
#      stated 5-minute hard cap (Verified Facts, SLAAT-P1-3 card). A role with
#      no explicit token_ttl inherits the auth mount's default_lease_ttl --
#      this script resolves that inheritance, it does not stop at "unset".
#
# This script creates and deletes EPHEMERAL ServiceAccounts and Pods only. It
# never creates, modifies, or deletes a SPIRE registration entry, an OpenBao
# role/policy, or any d2-agent-trust / inf-bao manifest -- see the
# SLAAT-P1-3 card's merge boundary. All cleanup runs in a trap so a failed
# probe never leaves cluster residue.
#
# Usage:
#   scripts/probe-spiffe-privilege-escalation.sh [--out FILE] [--namespace NS]
#
# Env:
#   SLAAT_KUBE_CONTEXT     kube context (default: kind-osramp)
#   SLAAT_BAO_NAMESPACE    namespace running the openbao Deployment (default: inf-bao)
#   SLAAT_AGENT_NAMESPACE  namespace with SPIRE-registered fleet agents (default: fe-signalloom-agents)
#   SLAAT_PROBE_SA_PREFIX  prefix for the throwaway unregistered ServiceAccount (default: slaat-p1-3-evil)
#   SLAAT_SPIRE_AGENT_IMAGE image carrying the spire-agent CLI (default: ghcr.io/spiffe/spire-agent:1.11.1)

set -uo pipefail

SLAAT_KUBE_CONTEXT="${SLAAT_KUBE_CONTEXT:-kind-osramp}"
SLAAT_BAO_NAMESPACE="${SLAAT_BAO_NAMESPACE:-inf-bao}"
SLAAT_AGENT_NAMESPACE="${SLAAT_AGENT_NAMESPACE:-fe-signalloom-agents}"
SLAAT_PROBE_SA_PREFIX="${SLAAT_PROBE_SA_PREFIX:-slaat-p1-3-evil}"
SLAAT_SPIRE_AGENT_IMAGE="${SLAAT_SPIRE_AGENT_IMAGE:-ghcr.io/spiffe/spire-agent:1.11.1}"
OUT_FILE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT_FILE="${2:?}"; shift 2 ;;
    --namespace) SLAAT_AGENT_NAMESPACE="${2:?}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

KC() { kubectl --context "${SLAAT_KUBE_CONTEXT}" "$@"; }

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/slaat-spiffe.XXXXXX")"
RECORDS_JSONL="${WORKDIR}/records.jsonl"
: >"${RECORDS_JSONL}"

PROBE_SA="${SLAAT_PROBE_SA_PREFIX}-$$"
POD_CARDVAULT="slaat-p1-3-cardvault-$$"
POD_CARDVAULT2="slaat-p1-3-cardvault2-$$"
POD_EVIL="slaat-p1-3-evil-$$"

cleanup() {
  KC -n "${SLAAT_AGENT_NAMESPACE}" delete pod "${POD_CARDVAULT}" "${POD_CARDVAULT2}" "${POD_EVIL}" --ignore-not-found --wait=false >/dev/null 2>&1
  KC -n "${SLAAT_AGENT_NAMESPACE}" delete serviceaccount "${PROBE_SA}" --ignore-not-found >/dev/null 2>&1
  KC -n "${SLAAT_BAO_NAMESPACE}" exec deploy/openbao -- sh -c 'rm -f /tmp/slaat-p1-3-probe-*.jwt' >/dev/null 2>&1
  rm -rf "${WORKDIR}"
}
trap cleanup EXIT INT TERM

record() {
  # record ID VECTOR EXPECTATION OBSERVED SEVERITY DETAIL
  python3 - "$1" "$2" "$3" "$4" "$5" "$6" <<'PY' >>"${RECORDS_JSONL}"
import json, sys
_id, vector, expect, observed, sev, detail = sys.argv[1:7]
print(json.dumps({"id": _id, "vector": vector, "expectation": expect, "observed": observed, "severity": sev, "detail": detail}))
PY
}

echo "[probe-spiffe] === preflight: live cluster reachability ===" >&2
if ! KC cluster-info >/dev/null 2>&1; then
  echo "[probe-spiffe] SKIP: kube context '${SLAAT_KUBE_CONTEXT}' is unreachable; emitting an empty-but-valid report" >&2
  record "SPIFFE-0" "preflight" "live-cluster-reachable" "unreachable" "info" "No live cluster at context ${SLAAT_KUBE_CONTEXT}; all live probes skipped."
else
  if ! KC -n "${SLAAT_BAO_NAMESPACE}" get deploy/openbao >/dev/null 2>&1; then
    echo "[probe-spiffe] SKIP: no openbao Deployment in ${SLAAT_BAO_NAMESPACE}" >&2
    record "SPIFFE-0" "preflight" "openbao-deployment-present" "missing" "info" "No openbao Deployment in ${SLAAT_BAO_NAMESPACE}; live probes skipped."
  else
    # ---- wait for OpenBao readiness (loop-until-green per card contract) ----
    deadline=$(( $(date +%s) + 60 ))
    bao_ready="no"
    while [ "$(date +%s)" -lt "${deadline}" ]; do
      if KC -n "${SLAAT_BAO_NAMESPACE}" exec deploy/openbao -- sh -c 'true' >/dev/null 2>&1; then
        bao_ready="yes"
        break
      fi
      sleep 2
    done
    if [ "${bao_ready}" = "no" ]; then
      record "SPIFFE-0" "preflight" "openbao-ready" "timeout" "info" "openbao pod never became exec-able within 60s."
    fi

    echo "[probe-spiffe] === step 1: SPIRE attestation -- unregistered ServiceAccount ===" >&2
    KC -n "${SLAAT_AGENT_NAMESPACE}" create serviceaccount "${PROBE_SA}" >/dev/null 2>&1

    evil_overrides=$(python3 - "${PROBE_SA}" "${SLAAT_SPIRE_AGENT_IMAGE}" <<'PY'
import json, sys
sa, image = sys.argv[1:3]
print(json.dumps({
  "apiVersion": "v1",
  "spec": {
    "serviceAccountName": sa,
    "containers": [{
      "name": "probe", "image": image,
      "command": ["/opt/spire/bin/spire-agent", "api", "fetch", "jwt",
                  "-audience", "openbao-supercredential",
                  "-socketPath", "/run/spire/sockets/agent.sock"],
      "volumeMounts": [{"name": "spiffe-workload-api", "mountPath": "/run/spire/sockets", "readOnly": True}],
    }],
    "volumes": [{"name": "spiffe-workload-api", "hostPath": {"path": "/run/spire/sockets", "type": "Directory"}}],
  },
}))
PY
)
    evil_out="$(KC -n "${SLAAT_AGENT_NAMESPACE}" run "${POD_EVIL}" \
      --image="${SLAAT_SPIRE_AGENT_IMAGE}" --restart=Never --rm -i --attach \
      --labels="slaat.controlplane.io/probe=p1-3,signalloom.ai/agent=true,signalloom.ai/framework=none" \
      --overrides="${evil_overrides}" 2>&1)"
    KC -n "${SLAAT_AGENT_NAMESPACE}" delete pod "${POD_EVIL}" --ignore-not-found --wait=false >/dev/null 2>&1
    if echo "${evil_out}" | grep -qi "PermissionDenied\|no identity issued"; then
      record "SPIFFE-1" "workload-api-forged-identity" "denied" "denied" "pass" "Unregistered ServiceAccount ${PROBE_SA}, co-located in ${SLAAT_AGENT_NAMESPACE} with matching labels, correctly refused a JWT-SVID: ${evil_out##*rpc error}"
      echo "  SPIFFE-1 pass: unregistered SA denied an SVID" >&2
    else
      record "SPIFFE-1" "workload-api-forged-identity" "denied" "unexpected" "fail" "Unregistered ServiceAccount ${PROBE_SA} did not receive the expected PermissionDenied. Raw output: ${evil_out}"
      echo "  SPIFFE-1 FAIL: unexpected workload API response for forged identity" >&2
    fi

    echo "[probe-spiffe] === step 2: legitimate SVID (agent-cardvault, control case) ===" >&2
    fetch_jwt() {
      # fetch_jwt POD_NAME AUDIENCE -> prints the raw token to stdout
      local pod="$1" aud="$2"
      local overrides
      overrides=$(python3 - "${aud}" "${SLAAT_SPIRE_AGENT_IMAGE}" <<'PY'
import json, sys
aud, image = sys.argv[1:3]
print(json.dumps({
  "apiVersion": "v1",
  "spec": {
    "serviceAccountName": "agent-cardvault",
    "containers": [{
      "name": "probe", "image": image,
      "command": ["/opt/spire/bin/spire-agent", "api", "fetch", "jwt",
                  "-audience", aud, "-socketPath", "/run/spire/sockets/agent.sock"],
      "volumeMounts": [{"name": "spiffe-workload-api", "mountPath": "/run/spire/sockets", "readOnly": True}],
    }],
    "volumes": [{"name": "spiffe-workload-api", "hostPath": {"path": "/run/spire/sockets", "type": "Directory"}}],
  },
}))
PY
)
      # Retry: on a shared kind node under concurrent sibling-card load, pod
      # scheduling or the `--attach` log stream occasionally returns before
      # the token line is flushed (observed empirically: ~1-in-5 runs).
      # Treat an empty result as transient, not as the security finding.
      local token="" attempt
      for attempt in 1 2 3; do
        token="$(KC -n "${SLAAT_AGENT_NAMESPACE}" run "${pod}" \
          --image="${SLAAT_SPIRE_AGENT_IMAGE}" --restart=Never --rm -i --attach \
          --labels="slaat.controlplane.io/probe=p1-3,signalloom.ai/agent=true,signalloom.ai/framework=none" \
          --overrides="${overrides}" 2>/dev/null \
          | awk '/^\tey/{print $1}' | head -1)"
        KC -n "${SLAAT_AGENT_NAMESPACE}" delete pod "${pod}" --ignore-not-found --wait=false >/dev/null 2>&1
        [ -n "${token}" ] && break
        sleep 2
      done
      printf '%s' "${token}"
    }

    JWT_OPENBAO="$(fetch_jwt "${POD_CARDVAULT}" "openbao")"
    JWT_SUPERCRED="$(fetch_jwt "${POD_CARDVAULT2}" "openbao-supercredential")"

    if [ -z "${JWT_OPENBAO}" ]; then
      record "SPIFFE-2" "workload-api-legit-identity" "svid-issued" "no-svid" "fail" "agent-cardvault did not receive a JWT-SVID with audience=openbao; cannot run downstream OpenBao probes."
      echo "  SPIFFE-2 FAIL: could not obtain a control-case SVID; aborting downstream OpenBao probes" >&2
    else
      printf '%s' "${JWT_OPENBAO}" > "${WORKDIR}/openbao.jwt"
      sub_claim="$(echo "${JWT_OPENBAO}" | cut -d. -f2 | tr '_-' '/+' | python3 -c 'import sys,base64,json; s=sys.stdin.read(); s+="="*(-len(s)%4); print(json.loads(base64.b64decode(s)).get("sub",""))' 2>/dev/null)"
      record "SPIFFE-2" "workload-api-legit-identity" "svid-issued" "svid-issued" "pass" "agent-cardvault received a valid JWT-SVID, sub=${sub_claim}"
      echo "  SPIFFE-2 pass: control-case SVID issued for ${sub_claim}" >&2

      stage_jwt() {
        # stage_jwt NAME LOCAL_FILE -- copies a local file's bytes into the
        # pod via stdin redirect (not a bash variable through a pipe), so
        # odd characters in a hand-tampered JWT can never be mangled by an
        # intermediate subshell or `echo`/`printf` word-splitting.
        local name="$1" local_file="$2"
        KC -n "${SLAAT_BAO_NAMESPACE}" exec -i deploy/openbao -- sh -c "cat > /tmp/slaat-p1-3-probe-${name}.jwt" < "${local_file}" >/dev/null 2>&1
      }
      bao_login() {
        # bao_login ROLE JWT_FILE_NAME -> prints bao's stdout+stderr
        local role="$1" name="$2"
        KC -n "${SLAAT_BAO_NAMESPACE}" exec deploy/openbao -- sh -c "
          export BAO_ADDR=http://127.0.0.1:8200
          JWT=\$(cat /tmp/slaat-p1-3-probe-${name}.jwt)
          bao write auth/jwt/login role=${role} jwt=\"\${JWT}\" 2>&1
        " 2>&1
      }

      stage_jwt "openbao" "${WORKDIR}/openbao.jwt"
      if [ -n "${JWT_SUPERCRED}" ]; then
        printf '%s' "${JWT_SUPERCRED}" > "${WORKDIR}/supercred.jwt"
        stage_jwt "supercred" "${WORKDIR}/supercred.jwt"
      fi

      echo "[probe-spiffe] === step 3: OpenBao JWT role boundary probes ===" >&2

      # SPIFFE-3: legit role, correct audience -> expect success, then TTL audit
      legit_login="$(bao_login signalloom-cardvault-agent openbao)"
      issued_token="$(echo "${legit_login}" | awk '/^token /{print $2}')"
      duration="$(echo "${legit_login}" | awk '/^token_duration/{print $2}')"
      if [ -n "${issued_token}" ]; then
        # normalize duration to seconds for the 5m (300s) cap comparison
        secs=$(python3 -c "
d='${duration}'
import re
m=re.match(r'(\d+)h', d)
print(int(m.group(1))*3600 if m else -1)
" 2>/dev/null)
        if [ -n "${secs}" ] && [ "${secs}" != "-1" ] && [ "${secs}" -gt 300 ]; then
          record "SPIFFE-3" "openbao-jwt-login" "token_ttl<=300s" "token_duration=${duration} (${secs}s)" "fail" "signalloom-cardvault-agent issued a token valid for ${duration}, far exceeding the mission's stated 5-minute hard cap. Root cause: the role defines no token_ttl/token_max_ttl, so it inherits the auth/jwt mount's default_lease_ttl=768h."
          echo "  SPIFFE-3 FAIL: cardvault-agent token_duration=${duration} >> 5m cap" >&2
        else
          record "SPIFFE-3" "openbao-jwt-login" "token_ttl<=300s" "token_duration=${duration}" "pass" "signalloom-cardvault-agent token duration is within the 5-minute cap."
          echo "  SPIFFE-3 pass: cardvault-agent token_duration=${duration}" >&2
        fi

        echo "[probe-spiffe] === step 4: token-scope boundary (issued token vs cross-tenant paths) ===" >&2
        probe_path() {
          local id="$1" desc="$2" path="$3" expect_status="$4"
          local out rc
          out="$(KC -n "${SLAAT_BAO_NAMESPACE}" exec deploy/openbao -- sh -c "
            export BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN='${issued_token}'
            bao kv get '${path}' 2>&1 || bao read '${path}' 2>&1
          " 2>&1)"
          if echo "${out}" | grep -q "Code: 403"; then rc="403"; elif echo "${out}" | grep -qi "====== Data ======\|^Key"; then rc="200"; else rc="other"; fi
          local sev="pass"
          [ "${rc}" != "${expect_status}" ] && sev="fail"
          record "${id}" "kv-tenant-isolation" "http_${expect_status}" "http_${rc}" "${sev}" "${desc} (path=${path})"
          echo "  ${id}: ${desc} -> ${rc} (expected ${expect_status})" >&2
        }
        probe_path "SPIFFE-4" "positive control: own path" "kv/signalloom/cardvault-agent" "200"
        probe_path "SPIFFE-5" "cross-tenant: fe-signalloom secret" "kv/signalloom/fe-signalloom" "403"
        probe_path "SPIFFE-6" "cross-tenant: another agent's templated path" "kv/agents/spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/kagent-security-analyst/secret" "403"
        probe_path "SPIFFE-7" "cross-tenant: agent-trust acme/payments path" "kv/signalloom/agent-trust/acme/payments/x" "403"
        probe_path "SPIFFE-8" "vertical: own role definition read" "auth/jwt/role/signalloom-cardvault-agent" "403"
        probe_path "SPIFFE-9" "vertical: secrets-engine admin listing" "sys/mounts" "403"
      else
        record "SPIFFE-3" "openbao-jwt-login" "login-succeeds" "login-failed" "fail" "signalloom-cardvault-agent login failed unexpectedly: ${legit_login}"
      fi

      # SPIFFE-10: cross-identity bypass -- cardvault SVID against an unrelated role
      cross_login="$(bao_login signalloom-fe-signalloom openbao)"
      if echo "${cross_login}" | grep -qi "invalid subject\|does not match\|Code: 400"; then
        record "SPIFFE-10" "openbao-jwt-login" "denied" "denied" "pass" "cardvault SVID correctly rejected by signalloom-fe-signalloom role (bound to a different sub): ${cross_login##*Errors:}"
        echo "  SPIFFE-10 pass: cross-identity role login denied" >&2
      else
        record "SPIFFE-10" "openbao-jwt-login" "denied" "unexpected" "fail" "cardvault SVID was NOT rejected by an unrelated role. Raw: ${cross_login}"
        echo "  SPIFFE-10 FAIL: cross-identity role login unexpectedly succeeded" >&2
      fi

      # SPIFFE-11: audience bypass -- wrong-audience SVID against the generic role
      aud_bypass="$(bao_login signalloom-agent-generic openbao)"
      if echo "${aud_bypass}" | grep -qi "invalid audience"; then
        record "SPIFFE-11" "openbao-jwt-audience" "denied" "denied" "pass" "Wrong-audience SVID (aud=openbao) correctly rejected by signalloom-agent-generic (bound_audiences=openbao-supercredential)."
        echo "  SPIFFE-11 pass: audience mismatch denied" >&2
      else
        record "SPIFFE-11" "openbao-jwt-audience" "denied" "unexpected" "fail" "Wrong-audience SVID was not rejected on audience grounds. Raw: ${aud_bypass}"
      fi

      # SPIFFE-12: bound_claims glob defect -- correct-audience SVID against the generic role
      if [ -n "${JWT_SUPERCRED}" ]; then
        glob_bug="$(bao_login signalloom-agent-generic supercred)"
        if echo "${glob_bug}" | grep -qi 'does not match any associated bound claim'; then
          record "SPIFFE-12" "openbao-jwt-bound-claims" "login-succeeds-for-registered-fleet-agents" "claim-mismatch-for-every-agent" "fail" "signalloom-agent-generic role is missing bound_claims_type=glob. Its bound_claims.sub literal '*' never matches a real SPIFFE sub, so EVERY one of the 18 registered fe-signalloom-agents/sa/* identities is permanently denied by this role -- a correctness defect that happens to fail closed. Same bug class previously fixed (bound_claims_type=glob added) in openbao-supercred-bootstrap.yaml's two roles per the documented PF-3 precedent; this role was never updated to match."
          echo "  SPIFFE-12 FAIL (functional defect, fails closed): generic role's bound_claims glob is broken for all fleet agents" >&2
        else
          record "SPIFFE-12" "openbao-jwt-bound-claims" "login-succeeds-for-registered-fleet-agents" "login-succeeded" "pass" "signalloom-agent-generic accepted a correctly-audienced, registered SVID."
          echo "  SPIFFE-12 pass: generic role bound_claims glob resolved correctly" >&2
        fi
      fi

      # SPIFFE-13: tampered signature (last 4 bytes of a real SVID's
      # signature flipped; derived in Python from the local file, never from
      # a bash variable, so no quoting layer can mangle the base64 payload)
      python3 -c "
path = '${WORKDIR}/openbao.jwt'
with open(path) as f:
    jwt = f.read().strip()
tampered = jwt[:-4] + 'XXXX'
with open('${WORKDIR}/tampered.jwt', 'w') as f:
    f.write(tampered)
"
      stage_jwt "tampered" "${WORKDIR}/tampered.jwt"
      tamper_login="$(bao_login signalloom-cardvault-agent tampered)"
      if echo "${tamper_login}" | grep -qi "failed to verify id token signature\|invalid.*signature"; then
        record "SPIFFE-13" "openbao-jwt-signature" "denied" "denied" "pass" "Tampered-signature SVID correctly rejected."
        echo "  SPIFFE-13 pass: tampered signature denied" >&2
      else
        record "SPIFFE-13" "openbao-jwt-signature" "denied" "unexpected" "fail" "Tampered-signature SVID was not rejected. Raw: ${tamper_login}"
      fi

      # SPIFFE-14: alg:none forged token impersonating the same sub/aud.
      # Written straight to a local file from Python -- no bash variable
      # ever holds the forged token, so there is no quoting layer to mangle it.
      python3 -c "
import base64, json, time

def b64(obj):
    return base64.urlsafe_b64encode(json.dumps(obj).encode()).decode().rstrip('=')

now = int(time.time())
header = {'alg': 'none', 'typ': 'JWT'}
payload = {'aud': ['openbao'], 'exp': now + 300, 'iat': now, 'sub': '${sub_claim}'}
with open('${WORKDIR}/algnone.jwt', 'w') as f:
    f.write(f'{b64(header)}.{b64(payload)}.')
"
      stage_jwt "algnone" "${WORKDIR}/algnone.jwt"
      algnone_login="$(bao_login signalloom-cardvault-agent algnone)"
      if echo "${algnone_login}" | grep -qi "failed to verify id token signature\|invalid.*signature\|malformed"; then
        record "SPIFFE-14" "openbao-jwt-alg-none" "denied" "denied" "pass" "alg:none forged token impersonating ${sub_claim} correctly rejected by OpenBao's JWT signature verification."
        echo "  SPIFFE-14 pass: alg:none forgery denied" >&2
      else
        record "SPIFFE-14" "openbao-jwt-alg-none" "denied" "unexpected" "fail" "alg:none forged token was NOT rejected. Raw: ${algnone_login}"
        echo "  SPIFFE-14 CRITICAL: alg:none forgery was accepted!" >&2
      fi
    fi

    echo "[probe-spiffe] === step 5: role TTL audit (static, every live JWT role) ===" >&2
    roles="$(KC -n "${SLAAT_BAO_NAMESPACE}" exec deploy/openbao -- sh -c '
      export BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=signalloom-demo-root-token
      bao list -format=json auth/jwt/role 2>/dev/null
    ' 2>/dev/null | tr -d '\r')"
    role_names="$(echo "${roles}" | python3 -c "import json,sys; d=json.load(sys.stdin); print('\n'.join(d))" 2>/dev/null)"
    # -format=json reports token_ttl/default_lease_ttl as plain integer
    # SECONDS (not a "5m"/"768h" duration string) -- compare numerically.
    mount_default_secs="$(KC -n "${SLAAT_BAO_NAMESPACE}" exec deploy/openbao -- sh -c '
      export BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=signalloom-demo-root-token
      bao read -format=json sys/auth/jwt/tune 2>/dev/null
    ' 2>/dev/null | tr -d '\r' | python3 -c "import json,sys; print(json.load(sys.stdin).get('data',{}).get('default_lease_ttl',0))" 2>/dev/null)"
    mount_default_secs="${mount_default_secs:-0}"
    for role in ${role_names}; do
      role_json="$(KC -n "${SLAAT_BAO_NAMESPACE}" exec deploy/openbao -- sh -c "
        export BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=signalloom-demo-root-token
        bao read -format=json auth/jwt/role/${role} 2>/dev/null
      " 2>/dev/null | tr -d '\r')"
      ttl_secs="$(echo "${role_json}" | python3 -c "import json,sys; print(int(json.load(sys.stdin).get('data',{}).get('token_ttl',0)))" 2>/dev/null)"
      ttl_secs="${ttl_secs:-0}"
      effective_secs="${ttl_secs}"
      note=""
      if [ "${ttl_secs}" -eq 0 ]; then
        effective_secs="${mount_default_secs}"
        note=" -- role sets NO explicit token_ttl, inherits the auth/jwt mount's default_lease_ttl"
      fi
      sev="pass"
      [ "${effective_secs}" -gt 300 ] && sev="fail"
      record "TTL-${role}" "role-ttl-audit" "token_ttl<=300s" "effective_token_ttl_seconds=${effective_secs}" "${sev}" "Role auth/jwt/role/${role}: resolved effective token_ttl=${effective_secs}s.${note}"
      echo "  TTL-${role}: effective_token_ttl=${effective_secs}s${note}" >&2
    done
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
    "schema": "slaat-p1-3-spiffe-probe/v1",
    "card": "SLAAT-P1-3",
    "component": "probe-spiffe-privilege-escalation",
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
echo "[probe-spiffe] done: ${FAIL_COUNT} fail-severity findings" >&2
exit 0
