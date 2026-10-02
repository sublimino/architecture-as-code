#!/usr/bin/env bats
#
# @id      demo-agent-autoclaim
# @target  scripts/demo-agent-autoclaim.sh
# @doc     docs/eap/SLDC-P5-1-E2E-CONTAINMENT.md
#
# scripts/demo-agent-autoclaim.sh claims a running workload through the product
# API: a Dex password grant, then POST /api/v1/agents/claim, both run inside the
# dashboard pod with the token on stdin. It is the claim path Step 2 of
# test/e2e-dual-cluster-containment.bats relies on, so it must never create a
# registry row the product would not, and never report a claim it did not see.
#
# Offline. A fake kubectl answers every shape the script uses; each API call is
# dispatched on the METHOD and PATH the script passes to `sh -c`, and every
# claim body is recorded so a test can assert what was sent.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  SCRIPT="${REPO_ROOT}/scripts/demo-agent-autoclaim.sh"
  FAKE="${BATS_TEST_TMPDIR}/fake"
  mkdir -p "${FAKE}/bin"
  export FAKE_LOG="${FAKE}/calls.log" FAKE_CLAIMS="${FAKE}/claims.jsonl"
  : >"${FAKE_LOG}"; : >"${FAKE_CLAIMS}"
  export SLAC_DEMO_RESULT_FILE="${BATS_TEST_TMPDIR}/result.json"
  export WAIT_QUIET=1 WAIT_DEADLINE_SCALE=0.05 WAIT_SLEEP=0.05 WAIT_HEARTBEAT_START=0
  export NO_COLOR=1
  # Posture of the agent after the claim: six evaluated controls by default.
  export FAKE_CONTROLS=6 FAKE_PASSING=5 FAKE_POSTURE=0.83
  export FAKE_KUSARI_MODEL_LABEL=deterministic

  cat >"${FAKE}/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_LOG}"
args=" $* "
case "${args}" in
  *" version "*) exit 0 ;;
  *" get pods "*" -o json "*)
    if [ -n "${FAKE_KUSARI_MODEL_LABEL}" ]; then
      kusari_model="\"signalloom.ai/model\":\"${FAKE_KUSARI_MODEL_LABEL}\","
    else
      kusari_model=""
    fi
    cat <<JSON
{"items":[
 {"metadata":{"name":"kagent-k8s-reader-0","labels":{"app.kubernetes.io/name":"kagent-k8s-reader","signalloom.ai/model":"gpt-4o"}},
  "spec":{"serviceAccountName":"k8s-reader"},
  "status":{"phase":"Running","containerStatuses":[{"ready":true}]}},
 {"metadata":{"name":"agent-kusari-abc","labels":{"app.kubernetes.io/name":"kusari-agent",${kusari_model}"signalloom.ai/harness":"go-http"}},
  "spec":{"serviceAccountName":"kusari-agent"},
  "status":{"phase":"Running","containerStatuses":[{"ready":true}]}}
]}
JSON
    exit 0 ;;
  *" get pods "*) printf 'pod-a|true,\n'; exit 0 ;;
esac
case "${args}" in
  *" exec -i "*) ;;
  *" exec "*) exit 0 ;;
  *) echo "fake kubectl: unhandled: $*" >&2; exit 1 ;;
esac
# exec -i ... -- sh -c PROGRAM [sh METHOD PATH]
while [ $# -gt 0 ] && [ "$1" != "-c" ]; do shift; done
shift 2  # -c PROGRAM; what follows is $0 METHOD PATH for an API call
method="${2:-}" path="${3:-}"
if [ -z "${method}" ]; then
  cat >/dev/null
  echo '{"id_token":"fake.id.token"}'
  exit 0
fi
IFS= read -r _token
IFS= read -r body
st=200
case "${method} ${path}" in
  "GET /api/agents?namespace="*)
    out='{"agents":[{"id":"d-1","name":"kagent-k8s-reader","record_class":"discovered","is_registry_linked":false,"compliance_summary":{"total_controls":0}},{"id":"d-2","name":"kusari-agent","record_class":"discovered","is_registry_linked":false,"compliance_summary":{"total_controls":0}}]}' ;;
  "POST /api/v1/agents/claim")
    printf '%s\n' "${body}" >>"${FAKE_CLAIMS}"
    out='{"claim_id":"claim-1","status":"granted","spiffe_svid_verified":true,"allocated_token_budget":250000,"agent_id":"a-1"}' ;;
  "GET /api/agents?search="*)
    name="${path#*search=}"; name="${name%%&*}"
    if [ "${FAKE_CONTROLS}" -gt 0 ]; then posture="${FAKE_POSTURE}"; else posture=null; fi
    out="{\"agents\":[{\"id\":\"a-1\",\"name\":\"${name}\",\"record_class\":\"resolved\",\"is_registry_linked\":true,\"compliance_summary\":{\"total_controls\":${FAKE_CONTROLS},\"passing\":${FAKE_PASSING},\"failing\":0,\"pending\":$((FAKE_CONTROLS - FAKE_PASSING)),\"posture_score\":${posture}}}]}" ;;
  "GET /api/audit?limit=100")
    name="$(jq -r '.pod_name' <"${FAKE_CLAIMS}" | tail -1)"
    out="{\"events\":[{\"agent_name\":\"${name}\",\"event_type\":\"agent.claimed\",\"actor\":\"op@signalloom.local\",\"timestamp\":\"2026-10-02T00:00:00Z\",\"detail\":{\"action\":\"claimed\",\"claim_id\":\"claim-1\"}}]}" ;;
  *) out='{"detail":"not found"}'; st=404 ;;
esac
printf '%s\n__SLAC_HTTP_STATUS__:%s' "${out}" "${st}"
STUB
  chmod +x "${FAKE}/bin/kubectl"
  export PATH="${FAKE}/bin:${PATH}"
}

@test "autoclaim: a claimed agent with no evaluated controls fails with that reason and a valid evidence file" {
  # posture_score is null when no control was evaluated. jq -e printed "null",
  # set -e aborted the assignment silently, and the result writer then died on
  # ("null" | tonumber), leaving a ZERO-BYTE evidence file -- measured live
  # 2026-10-01 as "dies at step 5/7 on a jq parse error".
  export FAKE_CONTROLS=0 FAKE_PASSING=0
  run "${SCRIPT}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[4/7]"* ]]
  [[ "$output" == *"no compliance controls were evaluated"* ]]
  [[ "$output" != *"cannot be parsed"* ]]
  run jq -r '.status + "|" + .reason + "|" + (.steps_completed | tostring)' "${SLAC_DEMO_RESULT_FILE}"
  [ "$status" -eq 0 ]
  [[ "$output" == "fail|"*"no compliance controls were evaluated"*"|4" ]]
}

@test "autoclaim: the default run still claims the first discovered workload and passes" {
  run "${SCRIPT}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS: all seven demonstration steps completed."* ]]
  [ "$(jq -r '.pod_name' "${FAKE_CLAIMS}")" = "kagent-k8s-reader" ]
  [ "$(jq -r '.status' "${SLAC_DEMO_RESULT_FILE}")" = "pass" ]
}

@test "autoclaim: --workload claims only the named workload, with model and harness from its labels" {
  run "${SCRIPT}" --workload kusari-agent
  [ "$status" -eq 0 ]
  [ "$(wc -l <"${FAKE_CLAIMS}")" -eq 1 ]
  run jq -r '[.pod_name, .model, .harness, .spiffe_id] | join("|")' "${FAKE_CLAIMS}"
  [ "$output" = "kusari-agent|deterministic|go-http|spiffe://signalloom.demo/ns/fe-signalloom-agents/sa/kusari-agent" ]
  [ "$(jq -r '.workload' "${SLAC_DEMO_RESULT_FILE}")" = "kusari-agent" ]
}

@test "autoclaim: --workload waits for that workload's pods, not for kagent" {
  run "${SCRIPT}" --workload kusari-agent
  [ "$status" -eq 0 ]
  grep -q -- "-l app.kubernetes.io/name=kusari-agent" "${FAKE_LOG}"
  ! grep -q -- "managed-by=kagent" "${FAKE_LOG}"
}

@test "autoclaim: --workload refuses a workload with no model label instead of inventing one" {
  export FAKE_KUSARI_MODEL_LABEL=""
  run "${SCRIPT}" --workload kusari-agent
  [ "$status" -eq 1 ]
  [[ "$output" == *"kusari-agent has no signalloom.ai/model label"* ]]
  [ ! -s "${FAKE_CLAIMS}" ]
}

@test "autoclaim: --workload naming no running workload claims nothing" {
  run "${SCRIPT}" --workload kusarі-agent
  [ "$status" -eq 1 ]
  [[ "$output" == *"no running unclaimed agent"* ]]
  [ ! -s "${FAKE_CLAIMS}" ]
}

@test "autoclaim: --workload without a name is a usage error" {
  run "${SCRIPT}" --workload
  [ "$status" -eq 1 ]
  [[ "$output" == *"--workload requires a workload name"* ]]
  [ ! -s "${FAKE_CLAIMS}" ]
}

@test "autoclaim: SLAC_KUBE_CONTEXT pins every kubectl call, including the wait probes" {
  SLAC_KUBE_CONTEXT=kind-osramp run "${SCRIPT}" --workload kusari-agent
  [ "$status" -eq 0 ]
  local n_all n_ctx
  n_all="$(grep -c . "${FAKE_LOG}")"
  n_ctx="$(grep -c -- '^--context kind-osramp ' "${FAKE_LOG}")"
  [ "$n_all" -gt 5 ]
  [ "$n_ctx" -eq "$n_all" ]
}
