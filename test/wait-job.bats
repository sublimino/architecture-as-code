#!/usr/bin/env bats

setup() {
  root="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
  wait_lib="$root/scripts/lib/wait.sh"

  test_bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$test_bin"
  export COMMAND_LOG="$BATS_TEST_TMPDIR/kubectl_commands.log"
  export MOCK_JOB_EXISTS=1
  export MOCK_JOB_CONDITIONS=""
  export MOCK_POD_CONTAINER_STATUSES=""
  export MOCK_PODS=""
  export MOCK_INIT_CONTAINERS=""
  export MOCK_CONTAINERS=""

  cat >"$test_bin/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$COMMAND_LOG"
args="$*"

if [[ "$args" =~ "get job" ]] && [[ ! "$args" =~ "-o" ]]; then
  if [ "${MOCK_JOB_EXISTS:-1}" = "0" ]; then
    exit 1
  fi
  exit 0
fi

if [[ "$args" =~ "get job" ]] && [[ "$args" =~ "status.conditions" ]]; then
  printf '%s ' "${MOCK_JOB_CONDITIONS:-}"
  exit 0
fi

if [[ "$args" =~ "get pods" ]] && [[ "$args" =~ "status.containerStatuses" ]]; then
  printf '%s ' "${MOCK_POD_CONTAINER_STATUSES:-}"
  exit 0
fi

if [[ "$args" =~ "get pods" ]] && [[ "$args" =~ "items[*].metadata.name" ]]; then
  printf '%s ' "${MOCK_PODS:-}"
  exit 0
fi

if [[ "$args" =~ "get pod" ]] && [[ "$args" =~ "initContainers" ]]; then
  printf '%s ' "${MOCK_INIT_CONTAINERS:-}"
  exit 0
fi

if [[ "$args" =~ "get pod" ]] && [[ "$args" =~ "spec.containers" ]]; then
  printf '%s ' "${MOCK_CONTAINERS:-}"
  exit 0
fi

if [[ "$args" =~ "logs" ]]; then
  printf 'log: %s\n' "$args"
  exit 0
fi

exit 0
STUB
  chmod +x "$test_bin/kubectl"
  export PATH="$test_bin:$PATH"

  # Source library
  # shellcheck source=scripts/lib/wait.sh
  source "$wait_lib"
}

@test "wait_job on a complete job succeeds" {
  export MOCK_JOB_CONDITIONS="Complete=True"
  export MOCK_POD_CONTAINER_STATUSES="worker=0"

  run wait_job test-job -n default 5

  [ "$status" -eq 0 ]
  [[ "$output" == *"Complete=True"* || "$output" == *"complete"* ]]
  [[ "$output" == *'WAIT_STAT site="job/test-job -n default"'* ]]
  [[ "$output" == *'result=ok'* ]]
}

@test "wait_job on a failing job fails fast and does not wait out deadline" {
  export MOCK_JOB_CONDITIONS="Failed=True"
  export MOCK_POD_CONTAINER_STATUSES="worker=1"

  start=$SECONDS
  run wait_job failing-job -n default 10
  elapsed=$((SECONDS - start))

  [ "$status" -eq 1 ]
  [ "$elapsed" -le 2 ]
  [[ "$output" == *'failed'* ]]
  [[ "$output" == *'WAIT_STAT site="job/failing-job -n default"'* ]]
  [[ "$output" == *'result=failed'* ]]
}

@test "wait_job --fail-fast aborts on non-zero container exit" {
  # Job condition is empty (controller has not marked it Failed yet due to backoffLimit)
  export MOCK_JOB_CONDITIONS=""
  export MOCK_POD_CONTAINER_STATUSES="probe=1"

  start=$SECONDS
  run wait_job fast-fail-job -n default --fail-fast 10
  elapsed=$((SECONDS - start))

  [ "$status" -eq 1 ]
  [ "$elapsed" -le 2 ]
  [[ "$output" == *'failed'* ]]
  [[ "$output" == *'WAIT_STAT site="job/fast-fail-job -n default"'* ]]
  [[ "$output" == *'result=failed'* ]]
}

@test "wait_job --for=terminal succeeds when job terminates" {
  # Succeeds when job completes
  export MOCK_JOB_CONDITIONS="Complete=True"
  export MOCK_POD_CONTAINER_STATUSES="worker=0"

  run wait_job term-complete-job -n default --for=terminal 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"terminal state reached"* ]]
  [[ "$output" == *'result=ok'* ]]

  # Also succeeds when job fails
  export MOCK_JOB_CONDITIONS="Failed=True"
  export MOCK_POD_CONTAINER_STATUSES="worker=1"

  run wait_job term-failed-job -n default --for=terminal 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"terminal state reached"* ]]
  [[ "$output" == *'result=ok'* ]]
}

@test "wait_job --for=failed succeeds when job fails and fails when job completes" {
  # Case 1: Job fails -> wait_job --for=failed succeeds
  export MOCK_JOB_CONDITIONS="Failed=True"
  export MOCK_POD_CONTAINER_STATUSES="worker=1"

  run wait_job failed-expected-job -n default --for=failed 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"failed as expected"* ]]
  [[ "$output" == *'result=ok'* ]]

  # Case 2: Job completes -> wait_job --for=failed fails
  export MOCK_JOB_CONDITIONS="Complete=True"
  export MOCK_POD_CONTAINER_STATUSES="worker=0"

  run wait_job complete-unexpected-job -n default --for=failed 5
  [ "$status" -eq 1 ]
  [[ "$output" == *"completed but expected failure"* ]]
  [[ "$output" == *'result=failed'* ]]
}

@test "wait_k8s_ready job delegates to wait_job" {
  export MOCK_JOB_CONDITIONS="Complete=True"
  export MOCK_POD_CONTAINER_STATUSES="worker=0"

  # lowercase 'job'
  run wait_k8s_ready job delegated-job -n default --for condition=complete 5
  [ "$status" -eq 0 ]
  [[ "$output" == *'WAIT_STAT site="job/delegated-job -n default"'* ]]
  [[ "$output" == *'result=ok'* ]]

  # capitalized 'Job'
  run wait_k8s_ready Job delegated-job-cap -n default 5
  [ "$status" -eq 0 ]
  [[ "$output" == *'WAIT_STAT site="job/delegated-job-cap -n default"'* ]]
  [[ "$output" == *'result=ok'* ]]

  # plural 'jobs'
  run wait_k8s_ready jobs delegated-job-plural -n default 5
  [ "$status" -eq 0 ]
  [[ "$output" == *'WAIT_STAT site="job/delegated-job-plural -n default"'* ]]
  [[ "$output" == *'result=ok'* ]]

  # plural capitalized 'Jobs' with --for failed (fails on complete job)
  run wait_k8s_ready Jobs delegated-job-fail -n default --for failed 5
  [ "$status" -eq 1 ]
  [[ "$output" == *'completed but expected failure'* ]]
  [[ "$output" == *'result=failed'* ]]
}

@test "get_job_logs targets explicit container names (-c) for both initContainers and containers" {
  # Dynamic query behavior for pods
  cat >"$test_bin/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$COMMAND_LOG"
args="$*"

if [[ "$args" =~ "get pods" ]] && [[ "$args" =~ "items[*].metadata.name" ]]; then
  echo "pod-alpha pod-beta"
  exit 0
fi

if [[ "$args" =~ "get pod pod-alpha" ]] && [[ "$args" =~ "initContainers" ]]; then
  echo "init-setup"
  exit 0
fi

if [[ "$args" =~ "get pod pod-alpha" ]] && [[ "$args" =~ "spec.containers" ]]; then
  echo "app sidecar"
  exit 0
fi

if [[ "$args" =~ "get pod pod-beta" ]] && [[ "$args" =~ "initContainers" ]]; then
  echo ""
  exit 0
fi

if [[ "$args" =~ "get pod pod-beta" ]] && [[ "$args" =~ "spec.containers" ]]; then
  echo "worker"
  exit 0
fi

if [[ "$args" =~ "logs" ]]; then
  echo "log from: $args"
  exit 0
fi

exit 0
STUB
  chmod +x "$test_bin/kubectl"

  run get_job_logs demo-job -n demo-ns

  [ "$status" -eq 0 ]

  # Verify explicit container name targeting for pod-alpha:
  grep -q "logs pod-alpha -c init-setup" "$COMMAND_LOG"
  grep -q "logs pod-alpha -c init-setup --previous" "$COMMAND_LOG"
  grep -q "logs pod-alpha -c app" "$COMMAND_LOG"
  grep -q "logs pod-alpha -c app --previous" "$COMMAND_LOG"
  grep -q "logs pod-alpha -c sidecar" "$COMMAND_LOG"
  grep -q "logs pod-alpha -c sidecar --previous" "$COMMAND_LOG"

  # Verify explicit container name targeting for pod-beta:
  grep -q "logs pod-beta -c worker" "$COMMAND_LOG"
  grep -q "logs pod-beta -c worker --previous" "$COMMAND_LOG"
}
