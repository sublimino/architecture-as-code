#!/usr/bin/env bats
# test/kanban-check.bats — regression coverage for Kanban healthcheck boundaries.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

stage_check() {
  CHECK_ROOT="${BATS_TEST_TMPDIR}/check-repo"
  mkdir -p "${CHECK_ROOT}/scripts/bin"
  cp "${REPO_ROOT}/scripts/kanban-check.sh" "${CHECK_ROOT}/scripts/"
  chmod +x "${CHECK_ROOT}/scripts/kanban-check.sh"
  export TEST_HOME="${BATS_TEST_TMPDIR}/home"
  mkdir -p "${TEST_HOME}"
}

write_sessions() {
  local workspace="$1" contents="$2"
  mkdir -p "${TEST_HOME}/.cline/kanban/workspaces/${workspace}"
  printf '%s\n' "$contents" >"${TEST_HOME}/.cline/kanban/workspaces/${workspace}/sessions.json"
}

check() {
  env HOME="${TEST_HOME}" "${CHECK_ROOT}/scripts/kanban-check.sh" "$@"
}

@test "kanban output-check honors target repository and minimum lines" {
  stage_check
  target="${BATS_TEST_TMPDIR}/target-repository"
  mkdir -p "${target}"
  write_sessions "$(basename "${target}")" '{"CARD-1":{"state":"completed","lines":[],"agentId":"agent"}}'

  run check output-check --repo "${target}" --min-lines 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"CARD-1"* ]]
}

@test "kanban checks scope proof exemptions to the matching task" {
  stage_check
  target="${BATS_TEST_TMPDIR}/target-repository"
  mkdir -p "${target}"
  write_sessions "$(basename "${target}")" '{"CARD-1":{"state":"completed","lines":[],"agentId":"agent"}}'
  cat >"${target}/.kagent-preflight-proof.json" <<'EOF'
{"task_id":"P0","status":"COMPLETED","test_status":"PASS","proof_errors":[]}
EOF

  run check output-check --repo "${target}" --min-lines 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"CARD-1"* ]]
}

@test "kanban duration-check honors a caller-supplied threshold" {
  stage_check
  target="${BATS_TEST_TMPDIR}/target-repository"
  mkdir -p "${target}"
  write_sessions "$(basename "${target}")" \
    '{"CARD-1":{"state":"completed","lines":["output"],"startedAt":1000,"updatedAt":1000}}'

  run check duration-check --repo "${target}" --min-sec 0
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "kanban review-record preserves hostile review data" {
  stage_check
  marker="${BATS_TEST_TMPDIR}/review-injected"
  task_id=$'review "task"\n'; task_id+="', __import__('pathlib').Path('${marker}').touch(), 'x"
  reason=$'reason "quoted"\nline'

  run check review-record --task-id "$task_id" --verdict APPROVED --reason "$reason" --reviewer "reviewer 'one'"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ ! -e "$marker" ] || { echo "review data executed as Python"; return 1; }

  run python3 - "${CHECK_ROOT}/.kanban-review-ledger.json" "$task_id" "$reason" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    ledger = json.load(handle)
entry = ledger[sys.argv[2]]
assert entry["reason"] == sys.argv[3].strip()
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "kanban review ledger rejects duplicates and corrupt state" {
  stage_check

  run check review-record --task-id FIRST --verdict APPROVED --reason initial
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  run check review-record --task-id FIRST --verdict REJECTED --reason replacement
  [ "$status" -ne 0 ]
  run jq -e '.FIRST.verdict == "APPROVED" and .FIRST.reason == "initial"' "${CHECK_ROOT}/.kanban-review-ledger.json"
  [ "$status" -eq 0 ]

  printf '{not-json}\n' >"${CHECK_ROOT}/.kanban-review-ledger.json"
  run check review-record --task-id SECOND --verdict APPROVED --reason second
  [ "$status" -ne 0 ]
  [ "$(<"${CHECK_ROOT}/.kanban-review-ledger.json")" = "{not-json}" ]
}

@test "kanban review-record retains concurrent ledger updates" {
  stage_check

  check review-record --task-id FIRST --verdict APPROVED --reason first >/dev/null &
  first_pid=$!
  check review-record --task-id SECOND --verdict APPROVED --reason second >/dev/null &
  second_pid=$!
  wait "$first_pid"
  wait "$second_pid"

  run jq -e 'length == 2 and has("FIRST") and has("SECOND")' "${CHECK_ROOT}/.kanban-review-ledger.json"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}
