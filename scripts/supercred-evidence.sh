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
# Each entry is a ready-made JSON array of {label,command,detail} for one step,
# plus the same proofs preformatted for the terminal renderer.
STEP_PROOFS=(); STEP_PROOF_TEXT=()

# ─── Several commands can decide ONE step ───────────────────────────────────
#
# A step used to carry exactly one command, which forced every verdict to rest
# on a single probe. Step 6 is the case that broke it: a stun is a revocation
# (the mechanism), plus an annotation (a label the platform writes), plus a
# NetworkPolicy (containment). One command can only ever prove one of those, so
# whichever one was chosen became the definition of "stunned" — and the one that
# had been chosen was the weakest.
#
# So a step accumulates proofs and `record` serialises them. The FIRST proof is
# the primary one and is also published as the legacy top-level `command` /
# `detail` pair, so a consumer that predates this array still shows the
# mechanism rather than a corroborating detail.
PROOF_LABELS=(); PROOF_CMDS=(); PROOF_DETAILS=()

proof_reset() { PROOF_LABELS=(); PROOF_CMDS=(); PROOF_DETAILS=(); }
proof_add() { PROOF_LABELS+=("$1"); PROOF_CMDS+=("$2"); PROOF_DETAILS+=("$3"); }

have_cluster() { kubectl cluster-info >/dev/null 2>&1; }

record() {
  # A step that added no proofs of its own is a single-command step; its one
  # command becomes its one proof, so every step has the same shape downstream.
  if (( ${#PROOF_CMDS[@]} == 0 )); then proof_add "$2" "$4" "$5"; fi
  STEP_IDS+=("$1"); STEP_LABELS+=("$2"); STEP_STATES+=("$3")
  STEP_CMDS+=("$4"); STEP_DETAILS+=("$5"); STEP_SUMMARIES+=("$6")
  STEP_PROOFS+=("$(proofs_json)")
  STEP_PROOF_TEXT+=("$(proofs_text)")
  proof_reset
}

# The same proofs, laid out for a terminal. A single-proof step prints exactly
# what it always printed; a multi-proof step names each command.
proofs_text() {
  local i out=""
  for i in "${!PROOF_CMDS[@]}"; do
    if (( ${#PROOF_CMDS[@]} > 1 )); then
      out+="              [${PROOF_LABELS[$i]}]"$'\n'
    fi
    out+="              $ ${PROOF_CMDS[$i]//$'\n'/$'\n'                }"$'\n'
  done
  printf '%s' "$out"
}

# `record` for a step whose verdict rests on several commands: the primary
# proof supplies the legacy single command/detail pair.
record_proven() { record "$1" "$2" "$3" "${PROOF_CMDS[0]}" "${PROOF_DETAILS[0]}" "$4"; }

# Run a probe and classify. Anything that is not a clean exit-0 with the
# expected marker is `absent`; anything that could not run at all is
# `unavailable`. The command string is what gets shown in the UI console.
bao_exec() {
  kubectl -n "$NAMESPACE_BAO" exec deployment/openbao -- \
    env BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN="$(bao_token)" "$@" 2>&1
}

# Did that `bao kv get -field=…` return a LIVE value?
#
# Neither half of this is optional. Against the running cluster, reading a field
# off a revoked secret prints
#
#     No data found at kv/data/signalloom/cardvault-agent
#     command terminated with exit code 2
#
# — on stderr, which bao_exec merges into stdout — and exits 2. Testing the
# CONTENT alone passed that string through as a username (it contains none of
# "No value found", "error" or "deletion_time"), so the probe reported a live
# credential for a credential that had just been revoked. Testing the STATUS
# alone is no better: `bao kv get` exits 0 on a soft-deleted secret and returns
# data:null with a deletion_time. Both, or the answer is wrong in one direction
# or the other.
bao_value_is_live() {
  local status="$1" out="$2"
  (( status == 0 )) || return 1
  [[ -n "$out" ]] || return 1
  case "$out" in
    *"No value found"*|*"No data found"*|*"command terminated"*|*deletion_time*|*Error*|*error*) return 1 ;;
  esac
  return 0
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
#
# Per POD, not flattened across pods. The selector matches more than one pod in
# practice — the long-lived agent-cardvault AND the transient
# supercred-agent-run-* Job pod both carry signalloom.ai/supercred=true — and
# `{.items[*].status.containerStatuses[*].ready}` concatenates their readiness
# into one string. Two ways that lied:
#
#   * a Pending pod has NO containerStatuses at all, so it contributes nothing.
#     [ready, pending] flattened to "true", and the step read `observed` while a
#     pod was not running.
#   * with one string there is no count, so "the agent is ready" said nothing
#     about how many agents that was.
#
# Now every matched pod must be ready, and the count is in the summary either
# way — a mixed set can never report as observed.
#
# Pods that have already terminated (Succeeded/Failed) are counted and named but
# excluded from the verdict: a Job pod that ran to completion is finished, not
# unready, and after a stun the agent Job is SUPPOSED to fail. Letting a
# deliberately-failed Job drag "Agent Deployment" to absent would be the mirror
# image of the bug above — a false negative in place of a false positive.
probe_deployment() {
  local ns cmd out total running notready finished names line pod phase ready
  ns="$(agent_namespace)"
  cmd="kubectl -n ${ns} get pod -l ${AGENT_SELECTOR} -o jsonpath='{range .items[*]}{.metadata.name}{\"=\"}{.status.phase}{\"=\"}{.status.containerStatuses[*].ready}{\"\\n\"}{end}'"
  if ! have_cluster; then
    record 1 "Agent Deployment" unavailable "$cmd" "no reachable cluster" "Cannot reach a cluster, so deployment is unproven"
    return
  fi
  out="$(kubectl -n "$ns" get pod -l "${AGENT_SELECTOR}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.status.phase}{"="}{.status.containerStatuses[*].ready}{"\n"}{end}' 2>&1 || true)"

  total=0; running=0; notready=0; finished=0; names=""
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    pod="${line%%=*}"
    phase="${line#*=}"; phase="${phase%%=*}"
    ready="${line##*=}"
    total=$((total + 1))
    if [[ "$phase" == Succeeded || "$phase" == Failed ]]; then
      finished=$((finished + 1))
      continue
    fi
    running=$((running + 1))
    # No `true` at all (Pending, no containerStatuses yet) or any `false` (a
    # container not passing its readiness probe) means this pod is not ready.
    if [[ "$ready" != *true* || "$ready" == *false* ]]; then
      notready=$((notready + 1))
      names+="${names:+, }${pod}"
    fi
  done <<<"$out"

  local tail=""
  if (( finished > 0 )); then tail=" (${finished} further matched pod(s) have already terminated)"; fi

  if (( total == 0 )); then
    record 1 "Agent Deployment" absent "$cmd" "(no pods matched ${AGENT_SELECTOR})" \
      "No agent pod exists yet — 0 pods match ${AGENT_SELECTOR} in ${ns}"
  elif (( running == 0 )); then
    record 1 "Agent Deployment" absent "$cmd" "$out" \
      "No agent pod is running in ${ns} — all ${total} matched pods have terminated"
  elif (( notready == 0 )); then
    local phrase="All ${running} agent pods in ${ns} are running and ready${tail}"
    if (( running == 1 )); then phrase="The 1 agent pod in ${ns} is running and ready${tail}"; fi
    record 1 "Agent Deployment" observed "$cmd" "$out" "$phrase"
  else
    record 1 "Agent Deployment" absent "$cmd" "$out" \
      "${notready} of ${running} running agent pods in ${ns} are NOT ready (${names})${tail}"
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
  local status=0
  out="$(bao_exec bao kv get -field=username "$BAO_KV_PATH")" || status=$?
  if bao_value_is_live "$status" "$out"; then
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
#
# A stun has three parts and they are NOT equally load-bearing:
#
#   1. REVOCATION — supercred-demo.sh step 4 deletes kv/signalloom/cardvault-agent
#      and auth/jwt/role/signalloom-cardvault-agent. This is the mechanism: it is
#      what actually stops the agent, and it is what step 4 then proves by
#      re-running the agent Job and watching it fail.
#   2. The stun ANNOTATION/label the platform writes on the pod. INFORMATIONAL.
#      It is a claim the platform makes about itself, and a claim is not a
#      control — anyone with pods:patch can write it, and it survives a re-seed
#      of the credentials it purports to describe. Corroboration, never proof.
#   3. The NetworkPolicy — containment, and the weakest of the three signals
#      because it is namespace-scoped and may exist for unrelated reasons.
#
# This probe used to check (3) ALONE. So an agent whose credentials had been
# revoked read "no platform response yet" if no policy happened to exist, and —
# worse — a pod merely LABELLED stunned while its credentials were live could be
# painted as stunned by a policy that had nothing to do with it. The verdict now
# turns on (1): `observed` requires the credential material to be genuinely gone.
probe_response() {
  local ns np_cmd np_out ann_cmd ann_out rev_cmd kv_value kv_meta role_out rev_detail
  local kv_live=0 kv_existed=0 role_live=0 annotated=0 isolated=0 bao_reachable=0
  ns="$(agent_namespace)"

  rev_cmd="kubectl -n ${NAMESPACE_BAO} exec deployment/openbao -- bao kv get ${BAO_KV_PATH}
kubectl -n ${NAMESPACE_BAO} exec deployment/openbao -- bao read ${BAO_ROLE}"
  ann_cmd="kubectl -n ${ns} get pod -l ${AGENT_SELECTOR} -o jsonpath='{range .items[*]}{.metadata.name}{\" state=\"}{.metadata.labels.signalloom\\.ai/state}{\" stunned-at=\"}{.metadata.annotations.signalloom\\.ai/stunned-at}{\"\\n\"}{end}'"
  np_cmd="kubectl -n ${ns} get networkpolicy -o name   # looking for an isolating policy"

  if ! have_cluster; then
    proof_add "Credential revocation" "$rev_cmd" "no reachable cluster"
    proof_add "Stun annotation (corroboration)" "$ann_cmd" "no reachable cluster"
    proof_add "Network isolation" "$np_cmd" "no reachable cluster"
    record_proven 6 "Platform Response" unavailable "Cannot reach a cluster, so enforcement is unproven"
    return
  fi

  # ── 1. Revocation (the mechanism) ──
  if ! kubectl -n "$NAMESPACE_BAO" get deployment openbao >/dev/null 2>&1; then
    rev_detail="openbao deployment not found — revocation could not be checked"
  else
    bao_reachable=1
    # Same soft-delete trap probe_openbao documents: `bao kv get` exits 0 on a
    # SOFT-deleted secret, so the FIELD read is the predicate, not exit status.
    local kv_status=0
    kv_value="$(bao_exec bao kv get -field=username "$BAO_KV_PATH")" || kv_status=$?
    kv_meta="$(bao_exec bao kv metadata get "$BAO_KV_PATH" || true)"
    role_out="$(bao_exec bao read "$BAO_ROLE" || true)"
    if bao_value_is_live "$kv_status" "$kv_value"; then kv_live=1; fi
    # Metadata survives a soft delete and is what distinguishes "minted then
    # revoked" from "never minted at all" — deleting a credential that never
    # existed is not a platform response.
    if [[ -n "$kv_meta" && "$kv_meta" != *"No value found"* && "$kv_meta" != *"* error"* ]]; then
      kv_existed=1
    fi
    if grep -qE 'bound_subject|role_type|token_ttl' <<<"$role_out"; then role_live=1; fi
    rev_detail="$(printf 'kv secret (%s):\n%s\n\nkv metadata (%s):\n%s\n\njwt role (%s):\n%s' \
      "$( ((kv_live)) && printf 'LIVE' || printf 'not readable')" "${kv_value:-(no value)}" \
      "$( ((kv_existed)) && printf 'present' || printf 'absent')" "${kv_meta:-(none)}" \
      "$( ((role_live)) && printf 'LIVE' || printf 'absent')" "${role_out:-(none)}")"
  fi
  proof_add "Credential revocation" "$rev_cmd" "$rev_detail"

  # ── 2. The annotation (corroboration only) ──
  ann_out="$(kubectl -n "$ns" get pod -l "${AGENT_SELECTOR}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{" state="}{.metadata.labels.signalloom\.ai/state}{" stunned-at="}{.metadata.annotations.signalloom\.ai/stunned-at}{"\n"}{end}' 2>&1 || true)"
  if grep -qE 'state=stunned|stunned-at=[0-9]' <<<"$ann_out"; then annotated=1; fi
  proof_add "Stun annotation (corroboration)" "$ann_cmd" "${ann_out:-(no pods matched)}"

  # ── 3. Network isolation ──
  np_out="$(kubectl -n "$ns" get networkpolicy -o name 2>&1 | grep -i 'stun\|cardvault-agent' || true)"
  if [[ -n "$np_out" ]]; then isolated=1; fi
  proof_add "Network isolation" "$np_cmd" "${np_out:-(no isolating NetworkPolicy)}"

  # ── The verdict ──
  if (( ! bao_reachable )); then
    record_proven 6 "Platform Response" unavailable \
      "OpenBao is not deployed, so revocation could not be checked — the response is unproven, not disproven"
    return
  fi
  if (( kv_live || role_live )); then
    # The case the annotation-only reading got wrong. A pod can be labelled
    # stunned while the credentials it names are still mintable, and that is not
    # a stun by any definition the platform can enforce.
    if (( annotated )); then
      record_proven 6 "Platform Response" absent \
        "NOT stunned: the pod is labelled stunned, but the agent's credentials are still live in OpenBao"
    else
      record_proven 6 "Platform Response" absent \
        "No platform response yet — the agent's credentials are live and stun is available to the operator"
    fi
    return
  fi
  if (( kv_existed || annotated || isolated )); then
    local corroboration="" verdict
    if (( annotated )); then corroboration+=", pod annotated stunned"; fi
    if (( isolated )); then corroboration+=", isolating NetworkPolicy in force"; fi
    verdict="Agent has been stunned — its OpenBao secret and JWT role are both gone${corroboration}"
    record_proven 6 "Platform Response" observed "$verdict"
    return
  fi
  # Nothing was ever minted, so nothing has been revoked. Reporting that as a
  # stun would turn an empty cluster into a platform success story.
  record_proven 6 "Platform Response" absent \
    "No credential material has ever existed for this agent, so nothing has been revoked"
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

# The pending proof list as a JSON array. Built at `record` time so the emitters
# stay pure functions of the collected arrays.
proofs_json() {
  local i first=1
  printf '['
  for i in "${!PROOF_CMDS[@]}"; do
    [[ $first -eq 1 ]] || printf ','
    first=0
    printf '{"label":%s,"command":%s,"detail":%s}' \
      "$(printf '%s' "${PROOF_LABELS[$i]}" | json_escape)" \
      "$(printf '%s' "${PROOF_CMDS[$i]}" | json_escape)" \
      "$(printf '%s' "${PROOF_DETAILS[$i]}" | json_escape)"
  done
  printf ']'
}

emit_json() {
  local i first=1
  printf '{"generated_at":"%s","source":"supercred-evidence.sh","steps":[' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  for i in "${!STEP_IDS[@]}"; do
    [[ $first -eq 1 ]] || printf ','
    first=0
    # `command`/`detail` stay alongside `proofs` on purpose: they are the
    # PRIMARY proof, so a consumer that predates the array still shows the
    # command that decided the step rather than nothing at all.
    printf '{"step":%s,"label":%s,"state":%s,"command":%s,"detail":%s,"summary":%s,"proofs":%s}' \
      "${STEP_IDS[$i]}" \
      "$(printf '%s' "${STEP_LABELS[$i]}" | json_escape)" \
      "$(printf '%s' "${STEP_STATES[$i]}" | json_escape)" \
      "$(printf '%s' "${STEP_CMDS[$i]}" | json_escape)" \
      "$(printf '%s' "${STEP_DETAILS[$i]}" | json_escape)" \
      "$(printf '%s' "${STEP_SUMMARIES[$i]}" | json_escape)" \
      "${STEP_PROOFS[$i]}"
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
    printf '%s\n\n' "${STEP_PROOF_TEXT[$i]}"
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
