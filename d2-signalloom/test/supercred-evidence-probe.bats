#!/usr/bin/env bats
# What the evidence probe CONCLUDES, driven by a stub kubectl.
#
# The probes are the only place in this system that turn a cluster into a claim,
# and until now nothing tested them: the Python tests point
# SUPERCRED_EVIDENCE_SCRIPT at a fixture that prints canned JSON, and the React
# tests inject a fetcher. Both assert on evidence they invented. The two defects
# these tests exist to prevent were therefore invisible to the whole suite:
#
#   step 6  concluded "stunned" from a NetworkPolicy alone — the weakest of the
#           three signals, and not the mechanism. A pod merely LABELLED stunned
#           beside a policy that existed for unrelated reasons read as stunned;
#           an agent whose credentials had genuinely been revoked read as "no
#           platform response yet" if no policy happened to exist.
#
#   step 1  flattened readiness across every matched pod. A Pending pod has no
#           containerStatuses at all, so [ready, pending] became "true" and the
#           step reported `observed` while a pod was not running.
#
# The stub answers BOTH the old and the new jsonpath, so this file can be run
# against a pre-fix copy of the script (EVIDENCE_SCRIPT=/path/to/old.sh) and is
# expected to fail there. That is the mutation proof.

setup() {
  repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  script="${EVIDENCE_SCRIPT:-${repo_root}/scripts/supercred-evidence.sh}"
  stub_dir="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$stub_dir"
  cp "${BATS_TEST_DIRNAME}/fixtures/kubectl-evidence-stub.sh" "${stub_dir}/kubectl"
  chmod +x "${stub_dir}/kubectl"

  # Defaults: one ready agent pod, a live credential, no stun of any kind.
  export STUB_PODS="agent-cardvault=Running=true"
  export STUB_ANNOTATION="agent-cardvault state= stunned-at="
  export STUB_NETPOL=""
  export STUB_KV_FIELD="cardvault-svc"
  export STUB_KV_META="current_version 1"
  export STUB_ROLE="role_type    jwt"
  export STUB_BAO_DEPLOYED=1
  export STUB_SPIRE_ENTRY="Entry ID : abc
Selector : k8s:ns:fe-signalloom-agents"
}

run_evidence() {
  PATH="${stub_dir}:${PATH}" run "$script" json
  [ "$status" -eq 0 ] || {
    echo "evidence script exited ${status}: ${output}" >&2
    return 1
  }
}

# Read one field off one step. Keeps the assertions about MEANING, not about
# where a key sits in a JSON document.
field() {
  local step="$1" key="$2"
  printf '%s' "$output" | python3 -c '
import json,sys
doc = json.loads(sys.stdin.read())
step, key = int(sys.argv[1]), sys.argv[2]
s = next(x for x in doc["steps"] if x["step"] == step)
if key == "proof_labels":
    print("|".join(p["label"] for p in s.get("proofs", [])))
elif key == "proof_commands":
    print("|".join(p["command"] for p in s.get("proofs", [])))
elif key == "proof_count":
    print(len(s.get("proofs", [])))
else:
    print(s[key])
' "$step" "$key"
}

# ─── Step 1: every matched pod, counted ─────────────────────────────────────

@test "SUPERCRED step 1 is not observed when a matched pod is not running" {
  # The exact shape the flattened jsonpath could not see: a Pending pod
  # contributes NO containerStatuses, so the old probe read "true" and called
  # this ready.
  export STUB_PODS="agent-cardvault=Running=true
supercred-agent-run-x9=Pending="
  run_evidence
  [ "$(field 1 state)" = "absent" ]
  [[ "$(field 1 summary)" == *"1 of 2"* ]]
  [[ "$(field 1 summary)" == *"supercred-agent-run-x9"* ]]
}

@test "SUPERCRED step 1 is not observed when a matched pod reports not ready" {
  export STUB_PODS="agent-cardvault=Running=true
supercred-agent-run-x9=Running=false"
  run_evidence
  [ "$(field 1 state)" = "absent" ]
  [[ "$(field 1 summary)" == *"1 of 2"* ]]
}

@test "SUPERCRED step 1 states how many pods it observed when they are all ready" {
  export STUB_PODS="agent-cardvault=Running=true
cardvault-agent-2=Running=true"
  run_evidence
  [ "$(field 1 state)" = "observed" ]
  # "the agent is ready" said nothing about how many agents that was.
  [[ "$(field 1 summary)" == *"All 2 agent pods"* ]]
}

@test "SUPERCRED step 1 ignores a pod that has already terminated" {
  # After a stun the agent Job is SUPPOSED to fail. Letting a deliberately
  # failed Job drag Agent Deployment to absent is the mirror image of the bug.
  export STUB_PODS="agent-cardvault=Running=true
supercred-agent-run-x9=Failed=false"
  run_evidence
  [ "$(field 1 state)" = "observed" ]
  [[ "$(field 1 summary)" == *"terminated"* ]]
}

@test "SUPERCRED step 1 is absent, with the count, when nothing matches" {
  export STUB_PODS=""
  run_evidence
  [ "$(field 1 state)" = "absent" ]
  [[ "$(field 1 summary)" == *"0 pods match"* ]]
}

# ─── Step 6: the three parts of a stun ──────────────────────────────────────

@test "SUPERCRED step 6 is observed when the credentials are gone, with no NetworkPolicy" {
  # Revocation is the mechanism. A stun that revoked the credential material is
  # a stun whether or not a policy exists.
  export STUB_KV_FIELD=""
  export STUB_KV_META="current_version 2"
  export STUB_ROLE="No value found at auth/jwt/role/signalloom-cardvault-agent"
  export STUB_NETPOL=""
  run_evidence
  [ "$(field 6 state)" = "observed" ]
  [[ "$(field 6 summary)" == *"OpenBao secret and JWT role are both gone"* ]]
}

@test "SUPERCRED step 6 is NOT observed when the pod says stunned but the credentials are live" {
  # The annotation is a claim the platform makes about itself, and a claim is
  # not a control. With a policy present too, the old probe called this stunned.
  export STUB_ANNOTATION="agent-cardvault state=stunned stunned-at=2026-08-12T23:52:58Z"
  export STUB_NETPOL="networkpolicy/stun-cardvault-agent"
  export STUB_KV_FIELD="cardvault-svc"
  export STUB_ROLE="role_type    jwt"
  run_evidence
  [ "$(field 6 state)" = "absent" ]
  [[ "$(field 6 summary)" == *"NOT stunned"* ]]
  [[ "$(field 6 summary)" == *"still live"* ]]
}

@test "SUPERCRED step 6 does not call a half-revocation a stun" {
  # KV gone, JWT role still there: the agent can still authenticate.
  export STUB_KV_FIELD=""
  export STUB_ROLE="role_type    jwt"
  export STUB_NETPOL="networkpolicy/stun-cardvault-agent"
  run_evidence
  [ "$(field 6 state)" = "absent" ]
}

@test "SUPERCRED step 6 does not read a never-minted credential as a revoked one" {
  # Deleting a credential that never existed is not a platform response, and an
  # empty cluster must not render as a platform success story.
  export STUB_KV_FIELD=""
  export STUB_KV_META="No value found at kv/metadata/signalloom/cardvault-agent"
  export STUB_ROLE="No value found"
  export STUB_ANNOTATION=""
  export STUB_NETPOL=""
  run_evidence
  [ "$(field 6 state)" = "absent" ]
  [[ "$(field 6 summary)" == *"has ever existed"* ]]
  [[ "$(field 6 summary)" == *"nothing has been revoked"* ]]
}

@test "SUPERCRED step 6 is unavailable, not absent, when OpenBao cannot be reached" {
  # "We could not check the mechanism" is not "the platform did not respond",
  # and a NetworkPolicy sitting there must not paper over the difference.
  export STUB_BAO_DEPLOYED=0
  export STUB_NETPOL="networkpolicy/stun-cardvault-agent"
  run_evidence
  [ "$(field 6 state)" = "unavailable" ]
  [[ "$(field 6 summary)" == *"unproven, not disproven"* ]]
}

@test "SUPERCRED step 6 corroborates an observed stun with the annotation and the policy" {
  export STUB_KV_FIELD=""
  export STUB_ROLE="No value found"
  export STUB_ANNOTATION="agent-cardvault state=stunned stunned-at=2026-08-12T23:52:58Z"
  export STUB_NETPOL="networkpolicy/stun-cardvault-agent"
  run_evidence
  [ "$(field 6 state)" = "observed" ]
  [[ "$(field 6 summary)" == *"pod annotated stunned"* ]]
  [[ "$(field 6 summary)" == *"NetworkPolicy in force"* ]]
}

# ─── What a revoked secret actually looks like ──────────────────────────────
#
# Captured verbatim from the running cluster after `supercred-demo.sh 4`. This
# is the case that made the first pass at the fix report a live credential for a
# credential it had just watched being revoked: `bao kv get -field=…` writes its
# diagnostic to stderr (merged into stdout by bao_exec) and exits 2, and the
# content contains none of the markers the old predicate looked for.

@test "SUPERCRED a revoked secret is not read as a live credential" {
  export STUB_KV_FIELD="No data found at kv/data/signalloom/cardvault-agent
command terminated with exit code 2"
  export STUB_KV_FIELD_STATUS=2
  export STUB_KV_META="current_version 5"
  export STUB_ROLE="No value found at auth/jwt/role/signalloom-cardvault-agent"
  run_evidence
  # Step 3 and step 6 must agree: a card that says "a live credential exists"
  # beside "the credentials are gone" has told the audience nothing.
  [ "$(field 3 state)" = "absent" ]
  [ "$(field 6 state)" = "observed" ]
}

@test "SUPERCRED an exit status alone does not make a value live" {
  # The mirror trap: `bao kv get` exits 0 on a SOFT-deleted secret.
  export STUB_KV_FIELD="No data found at kv/data/signalloom/cardvault-agent"
  export STUB_KV_FIELD_STATUS=0
  export STUB_ROLE="No value found"
  run_evidence
  [ "$(field 3 state)" = "absent" ]
  [ "$(field 6 state)" = "observed" ]
}

@test "SUPERCRED a real username with a failed exit is not a live credential" {
  # Stale output from a command that did not succeed proves nothing.
  export STUB_KV_FIELD="cardvault-svc-account"
  export STUB_KV_FIELD_STATUS=1
  export STUB_ROLE="No value found"
  run_evidence
  [ "$(field 3 state)" = "absent" ]
}

# ─── The multi-proof contract ───────────────────────────────────────────────

@test "SUPERCRED step 6 publishes all three proofs, revocation first" {
  run_evidence
  [ "$(field 6 proof_count)" = "3" ]
  [[ "$(field 6 proof_labels)" == "Credential revocation|"* ]]
  [[ "$(field 6 proof_labels)" == *"Stun annotation"* ]]
  [[ "$(field 6 proof_labels)" == *"Network isolation"* ]]
}

@test "SUPERCRED each proof carries the command that can be pasted and rerun" {
  run_evidence
  local commands
  commands="$(field 6 proof_commands)"
  [[ "$commands" == *"bao kv get kv/signalloom/cardvault-agent"* ]]
  [[ "$commands" == *"bao read auth/jwt/role/signalloom-cardvault-agent"* ]]
  [[ "$commands" == *"get networkpolicy -o name"* ]]
  [[ "$commands" == *"stunned-at"* ]]
}

@test "SUPERCRED the legacy single command is the PRIMARY proof, not a corroborating one" {
  # A consumer predating `proofs` shows one command. It must be the mechanism.
  run_evidence
  [[ "$(field 6 command)" == *"bao kv get"* ]]
  [[ "$(field 6 command)" != *"networkpolicy"* ]]
}

@test "SUPERCRED a single-command step still publishes exactly one proof" {
  # One shape downstream: the renderer never has to special-case the old form.
  run_evidence
  [ "$(field 1 proof_count)" = "1" ]
  [ "$(field 1 proof_labels)" = "Agent Deployment" ]
  [ "$(field 1 command)" = "$(field 1 proof_commands)" ]
}

@test "SUPERCRED every step emits a proof for the command it reports" {
  run_evidence
  local step
  for step in 1 2 3 4 5 6; do
    [ "$(field "$step" proof_count)" -ge 1 ]
  done
}
