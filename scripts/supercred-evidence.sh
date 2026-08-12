#!/usr/bin/env bash
# supercred-evidence.sh — what is ACTUALLY true about the SuperCred credential
# chain right now, with the command that proved each claim.
#
#   supercred-evidence.sh json     # machine-readable evidence document (the API reads this)
#   supercred-evidence.sh text     # same evidence, human-readable, for the terminal
#
# ─── Why this exists ────────────────────────────────────────────────────────
#
# The dashboard's Credential Lifecycle card used to derive all six steps from
# ONE boolean:
#
#     const hasAgent = !!agent.id
#     status:    hasAgent ? 'completed' : 'pending'
#     timestamp: hasAgent ? '2026-01-01T00:00:01Z' : null   // a literal
#
# so the moment step 1 deployed the agent, steps 1-4 read "completed" and step 5
# "active" — regardless of whether a SPIFFE SVID had ever been issued or an
# OpenBao lease ever minted. It asserted a credential chain nobody had observed,
# with fabricated timestamps. The source called itself "Fake lifecycle data for
# demo enrichment"; the UI did not.
#
# Two distinct questions were being conflated, and this script answers only the
# second:
#
#   Demo Phases        "what have I, the operator, run?"      -> demo_runner.py
#   Credential Lifecycle "what is true about this credential?" -> HERE
#
# They are not the same axis and the mapping is not 1:1 — phase 2 ("Credential
# chain") fans out to lifecycle steps 2, 3 and 4. The lifecycle has to be able
# to CONTRADICT the phases: a chain job that reports success while no OpenBao
# lease exists is exactly the finding worth surfacing, and it is unrepresentable
# if the lifecycle is derived from what the operator clicked.
#
# ─── The contract ───────────────────────────────────────────────────────────
#
# Every step reports a `state` from a closed vocabulary. There is no "completed"
# without evidence:
#
#   observed      a probe ran and confirmed the thing exists / happened
#   absent        a probe ran and confirmed it does NOT exist  (a real negative)
#   unavailable   the probe could not run (no cluster, no pod, no binary).
#                 NOT the same as absent, and never rendered as progress.
#
# `unavailable` is load-bearing. Collapsing it into `absent` is how a broken
# probe becomes a confident claim — the failure this repo has hit repeatedly
# (see d2-agent-trust/AGENTS.md Pitfalls), and the reason each step also carries
# the literal command it ran, so a human can rerun it and disagree.

set -Eeuo pipefail

NAMESPACE_BAO="${NAMESPACE_BAO:-inf-bao}"
NAMESPACE_INFRA="${NAMESPACE_INFRA:-fe-signalloom}"
SPIFFE_ID="${SPIFFE_ID:-spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/cardvault-agent}"
BAO_KV_PATH="${BAO_KV_PATH:-kv/signalloom/cardvault-agent}"
BAO_ROLE="${BAO_ROLE:-auth/jwt/role/signalloom-cardvault-agent}"
# The demo lands the agent in fe-signalloom-agents; fe-signalloom is kept as a
# fallback for older layouts. Order matters — first namespace with a match wins.
AGENT_NAMESPACE_CANDIDATES=(fe-signalloom-agents "${NAMESPACE_INFRA}")
# The supercred agent pod is labelled signalloom.ai/supercred=true. It is NOT
# app.kubernetes.io/name=cardvault-agent — that selector matches nothing, and a
# selector that matches nothing reports "absent" as confidently as a real
# negative does.
AGENT_SELECTOR="${AGENT_SELECTOR:-signalloom.ai/supercred=true}"

# Collected as parallel arrays so the JSON writer stays a pure function of them.
STEP_IDS=(); STEP_LABELS=(); STEP_STATES=(); STEP_CMDS=(); STEP_DETAILS=(); STEP_SUMMARIES=()

have_cluster() { kubectl cluster-info >/dev/null 2>&1; }

record() {
  STEP_IDS+=("$1"); STEP_LABELS+=("$2"); STEP_STATES+=("$3")
  STEP_CMDS+=("$4"); STEP_DETAILS+=("$5"); STEP_SUMMARIES+=("$6")
}

# Run a probe and classify. Anything that is not a clean exit-0 with the
# expected marker is `absent`; anything that could not run at all is
# `unavailable`. The command string is what gets shown in the UI console.
bao_exec() {
  kubectl -n "$NAMESPACE_BAO" exec deployment/openbao -- \
    env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$(bao_token)" "$@" 2>&1
}

bao_token() {
  kubectl -n "$NAMESPACE_BAO" get deployment openbao -o jsonpath='{range .spec.template.spec.containers[*]}{range .env[*]}{.name}={.value}{"\n"}{end}{end}' 2>/dev/null \
    | awk -F= '/^BAO_DEV_ROOT_TOKEN_ID=/{print $2; exit}'
}

spire_pod() {
  kubectl -n "$NAMESPACE_BAO" get pod -l app.kubernetes.io/name=spire-server \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

agent_namespace() {
  local ns
  for ns in "${AGENT_NAMESPACE_CANDIDATES[@]}"; do
    if kubectl -n "$ns" get pod -l "${AGENT_SELECTOR}" \
         -o jsonpath='{.items[0].metadata.name}' >/dev/null 2>&1; then printf '%s' "$ns"; return; fi
  done
  printf '%s' "$NAMESPACE_INFRA"
}

# ── Step 1: the agent is actually deployed and ready ────────────────────────
probe_deployment() {
  local ns cmd out ready
  ns="$(agent_namespace)"
  cmd="kubectl -n ${ns} get pod -l ${AGENT_SELECTOR} -o jsonpath='{.items[*].status.containerStatuses[*].ready}'"
  if ! have_cluster; then
    record 1 "Agent Deployment" unavailable "$cmd" "no reachable cluster" "Cannot reach a cluster, so deployment is unproven"
    return
  fi
  out="$(kubectl -n "$ns" get pod -l "${AGENT_SELECTOR}" \
    -o jsonpath='{.items[*].status.containerStatuses[*].ready}' 2>&1 || true)"
  ready="$out"
  if [[ "$ready" == *true* && "$ready" != *false* ]]; then
    record 1 "Agent Deployment" observed "$cmd" "$out" "Agent pod is running and ready in ${ns}"
  elif [[ -z "$ready" ]]; then
    record 1 "Agent Deployment" absent "$cmd" "(no pods matched)" "No cardvault-agent pod exists yet"
  else
    record 1 "Agent Deployment" absent "$cmd" "$out" "Agent pod exists but is not ready"
  fi
}

# ── Step 2: SPIFFE identity — the ENTRY, and its selectors ──────────────────
#
# Entry existence alone is not attestation. The selectors are what bind the
# SVID to one workload; without them any pod in the namespace can obtain this
# identity. The agent-trust slice had exactly this gap (see its AGENTS.md).
probe_spiffe() {
  local sp cmd out
  cmd="kubectl -n ${NAMESPACE_BAO} exec <spire-server> -- /opt/spire/bin/spire-server entry show -spiffeID ${SPIFFE_ID}"
  if ! have_cluster; then
    record 2 "SPIFFE Identity" unavailable "$cmd" "no reachable cluster" "Cannot reach a cluster, so identity issuance is unproven"
    return
  fi
  sp="$(spire_pod)"
  if [[ -z "$sp" ]]; then
    record 2 "SPIFFE Identity" unavailable "$cmd" "no spire-server pod found" "SPIRE server is not reachable — issuance unproven, not disproven"
    return
  fi
  out="$(kubectl -n "$NAMESPACE_BAO" exec "$sp" -- \
    /opt/spire/bin/spire-server entry show -spiffeID "$SPIFFE_ID" 2>&1 || true)"
  if grep -q 'Entry ID' <<<"$out"; then
    if grep -q 'Selector' <<<"$out"; then
      record 2 "SPIFFE Identity" observed "$cmd" "$out" "SVID registration exists and is bound by selectors"
    else
      record 2 "SPIFFE Identity" absent "$cmd" "$out" "Entry exists but carries NO selectors — any pod could assume this identity"
    fi
  else
    record 2 "SPIFFE Identity" absent "$cmd" "$out" "No SPIRE registration for this SPIFFE ID"
  fi
}

# ── Step 3: OpenBao exchange — credential material actually minted ──────────
#
# `bao kv get` exits 0 on a SOFT-DELETED secret, returning data:null with a
# deletion_time, so exit status alone would call a revoked credential live.
probe_openbao() {
  local cmd out
  cmd="kubectl -n ${NAMESPACE_BAO} exec deployment/openbao -- bao kv get ${BAO_KV_PATH}"
  if ! have_cluster; then
    record 3 "OpenBao Exchange" unavailable "$cmd" "no reachable cluster" "Cannot reach a cluster, so credential minting is unproven"
    return
  fi
  if ! kubectl -n "$NAMESPACE_BAO" get deployment openbao >/dev/null 2>&1; then
    record 3 "OpenBao Exchange" unavailable "$cmd" "openbao deployment not found" "OpenBao is not deployed — exchange unproven, not disproven"
    return
  fi
  out="$(bao_exec bao kv get -field=username "$BAO_KV_PATH" || true)"
  if [[ -n "$out" && "$out" != *"No value found"* && "$out" != *"error"* && "$out" != *"deletion_time"* ]]; then
    record 3 "OpenBao Exchange" observed "$cmd" "$out" "A live credential exists in the vault for this agent"
  else
    local meta
    meta="$(bao_exec bao kv metadata get "$BAO_KV_PATH" || true)"
    if grep -q 'deletion_time' <<<"$meta" 2>/dev/null; then
      record 3 "OpenBao Exchange" absent "$cmd" "$meta" "Credential was minted then revoked (soft-deleted, recoverable)"
    else
      record 3 "OpenBao Exchange" absent "$cmd" "${out:-$meta}" "No credential has been minted for this agent"
    fi
  fi
}

# ── Step 4: service access — the JWT role that authorises the call ──────────
probe_service_access() {
  local cmd out
  cmd="kubectl -n ${NAMESPACE_BAO} exec deployment/openbao -- bao read ${BAO_ROLE}"
  if ! have_cluster; then
    record 4 "Service Access" unavailable "$cmd" "no reachable cluster" "Cannot reach a cluster, so service access is unproven"
    return
  fi
  if ! kubectl -n "$NAMESPACE_BAO" get deployment openbao >/dev/null 2>&1; then
    record 4 "Service Access" unavailable "$cmd" "openbao deployment not found" "OpenBao is not deployed — access path unproven"
    return
  fi
  out="$(bao_exec bao read "$BAO_ROLE" || true)"
  if grep -qE 'bound_subject|role_type|token_ttl' <<<"$out"; then
    record 4 "Service Access" observed "$cmd" "$out" "The JWT role the agent authenticates with is configured"
  else
    record 4 "Service Access" absent "$cmd" "$out" "No JWT role — the agent cannot exchange its SVID for access"
  fi
}

# ── Step 5: compliance scan — a real verdict, not a rendered box ────────────
probe_compliance() {
  local ns cmd out
  ns="$(agent_namespace)"
  cmd="kubectl -n ${ns} get pod -l ${AGENT_SELECTOR} -o jsonpath='{.items[0].spec.containers[0].securityContext}'"
  if ! have_cluster; then
    record 5 "Compliance Scan" unavailable "$cmd" "no reachable cluster" "Cannot reach a cluster, so no scan has been performed"
    return
  fi
  # Establish the pod EXISTS before reading anything off it. With no pods,
  # `-o jsonpath='{.items[0]...}'` exits 0 and prints
  #   error: ... array index out of bounds: index 0, length 0
  # on stdout. That string contains neither "not found" nor an empty result, so
  # a naive else-branch reads a jsonpath ERROR as a securityContext and reports
  # the agent compliant. A scan that cannot see a pod must say so.
  local pods
  pods="$(kubectl -n "$ns" get pod -l "${AGENT_SELECTOR}" -o name 2>/dev/null || true)"
  if [[ -z "$pods" ]]; then
    record 5 "Compliance Scan" absent "$cmd" "(no cardvault-agent pod in ${ns})" "Nothing to scan — the agent is not deployed"
    return
  fi
  out="$(kubectl -n "$ns" get pod -l "${AGENT_SELECTOR}" \
    -o jsonpath='{.items[0].spec.containers[0].securityContext}' 2>/dev/null || true)"
  if [[ "$out" == *"array index out of bounds"* || "$out" == error:* ]]; then
    record 5 "Compliance Scan" unavailable "$cmd" "$out" "The scan could not read the pod spec — result unproven"
  elif [[ -z "$out" || "$out" == "map[]" ]]; then
    # The demo's whole point: the agent ships with no securityContext.
    record 5 "Compliance Scan" observed "$cmd" "(empty securityContext)" "Scanned: agent runs with NO securityContext — non-compliant"
  else
    record 5 "Compliance Scan" observed "$cmd" "$out" "Scanned: agent declares a securityContext"
  fi
}

# ── Step 6: platform response — revoked and isolated, or not ────────────────
probe_response() {
  local ns cmd out
  ns="$(agent_namespace)"
  cmd="kubectl -n ${ns} get networkpolicy -o name   # looking for an isolating policy"
  if ! have_cluster; then
    record 6 "Platform Response" unavailable "$cmd" "no reachable cluster" "Cannot reach a cluster, so enforcement is unproven"
    return
  fi
  out="$(kubectl -n "$ns" get networkpolicy -o name 2>&1 | grep -i 'stun\|cardvault-agent' || true)"
  if [[ -n "$out" ]]; then
    record 6 "Platform Response" observed "$cmd" "$out" "Agent has been stunned — an isolating NetworkPolicy is in force"
  else
    record 6 "Platform Response" absent "$cmd" "(no isolating NetworkPolicy)" "No platform response yet — stun is available to the operator"
  fi
}

collect() {
  probe_deployment
  probe_spiffe
  probe_openbao
  probe_service_access
  probe_compliance
  probe_response
}

json_escape() { python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'; }

emit_json() {
  local i first=1
  printf '{"generated_at":"%s","source":"supercred-evidence.sh","steps":[' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  for i in "${!STEP_IDS[@]}"; do
    [[ $first -eq 1 ]] || printf ','
    first=0
    printf '{"step":%s,"label":%s,"state":%s,"command":%s,"detail":%s,"summary":%s}' \
      "${STEP_IDS[$i]}" \
      "$(printf '%s' "${STEP_LABELS[$i]}" | json_escape)" \
      "$(printf '%s' "${STEP_STATES[$i]}" | json_escape)" \
      "$(printf '%s' "${STEP_CMDS[$i]}" | json_escape)" \
      "$(printf '%s' "${STEP_DETAILS[$i]}" | json_escape)" \
      "$(printf '%s' "${STEP_SUMMARIES[$i]}" | json_escape)"
  done
  printf ']}\n'
}

emit_text() {
  local i icon
  printf '\nSuperCred credential chain — observed evidence (%s)\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  for i in "${!STEP_IDS[@]}"; do
    case "${STEP_STATES[$i]}" in
      observed)    icon="[OBSERVED]   " ;;
      absent)      icon="[ABSENT]     " ;;
      *)           icon="[UNAVAILABLE]" ;;
    esac
    printf '%s Step %s: %s\n' "$icon" "${STEP_IDS[$i]}" "${STEP_LABELS[$i]}"
    printf '              %s\n' "${STEP_SUMMARIES[$i]}"
    printf '              $ %s\n' "${STEP_CMDS[$i]}"
    printf '\n'
  done
  printf 'observed = a probe confirmed it; absent = a probe disproved it;\n'
  printf 'unavailable = the probe could not run, which is NOT the same as absent.\n\n'
}

main() {
  case "${1:-text}" in
    json) collect; emit_json ;;
    text) collect; emit_text ;;
    *) printf 'usage: supercred-evidence.sh <json|text>\n' >&2; exit 2 ;;
  esac
}

main "$@"
