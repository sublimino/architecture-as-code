#!/usr/bin/env bats

setup() {
  root="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
  wait_lib="${WAIT_LIB_OVERRIDE:-$root/scripts/lib/wait.sh}"
  test_bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$test_bin"
  export COMMAND_LOG="$BATS_TEST_TMPDIR/kubectl.log"
  export MOCK_READY=""
  export MOCK_STATES=""
  export MOCK_ENDPOINTS=""
  export MOCK_SERVICE_EXISTS=1
  export MOCK_WAIT_RC=0

  cat >"$test_bin/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$COMMAND_LOG"
args="$*"

if [[ "$args" == *"get service"* ]]; then
  [ "${MOCK_SERVICE_EXISTS:-1}" = 1 ]
  exit $?
fi
if [[ "$args" == *"endpointslices.discovery.k8s.io"* ]]; then
  printf '%s' "${MOCK_ENDPOINTS:-}"
  exit 0
fi
if [[ "$args" == *"status.phase"* ]]; then
  printf '%s' "${MOCK_STATES:-}"
  exit 0
fi
if [[ "$args" == *"metadata.name"* ]]; then
  printf '%s' "${MOCK_READY:-}"
  exit 0
fi
if [[ "$args" == *" wait "* || "$args" == wait\ * || "$args" == *"rollout status"* ]]; then
  exit "${MOCK_WAIT_RC:-0}"
fi
exit 0
STUB
  chmod +x "$test_bin/kubectl"
  export PATH="$test_bin:$PATH"
  export WAIT_SLEEP=0.01 WAIT_BACKOFF=1 WAIT_JITTER=0 WAIT_ATTEMPT_TIMEOUT=1
  export WAIT_QUIET=1
  source "$wait_lib"
}

@test "wait_pods_ready keeps all-ready as the default policy" {
  export MOCK_READY=$'pod-a|true,\npod-b|false,'
  run wait_pods_ready app=demo 1
  [ "$status" -eq 1 ]
  [[ "$output" == *'site="pods ready app=demo "'* ]]
  [[ "$output" != *'(all-ready)'* ]]
}

@test "wait_pods_ready accepts multiple ready pods" {
  export MOCK_READY=$'pod-a|true,\npod-b|true,'
  run wait_pods_ready app=demo 1
  [ "$status" -eq 0 ]
}

@test "wait_pods_ready any-ready accepts mixed readiness" {
  export MOCK_READY=$'pod-a|true,\npod-b|false,'
  run wait_pods_ready app=demo --for=any-ready 1
  [ "$status" -eq 0 ]
}

@test "wait_pods_ready fail-fast rejects nonrestartable container failure" {
  export MOCK_STATES='Running|Never|1,,'
  export MOCK_READY='pod-a|false,'
  run wait_pods_ready app=demo --fail-fast 2
  [ "$status" -eq 1 ]
  [[ "$output" == *'result=failed'* ]]
}

@test "wait_pods_ready keeps CrashLoopBackOff retryable" {
  export MOCK_STATES='Running|Always|,CrashLoopBackOff,'
  export MOCK_READY='pod-a|false,'
  run wait_pods_ready app=demo --fail-fast 1
  [ "$status" -eq 1 ]
  [[ "$output" == *'result=timeout'* ]]
  [[ "$output" != *'terminal failure'* ]]
}

@test "wait_pods_ready detects invalid init-container image names" {
  export MOCK_STATES='Pending|Always|,InvalidImageName,'
  export MOCK_READY='pod-a|'
  run wait_pods_ready app=demo --fail-fast 2
  [ "$status" -eq 1 ]
  [[ "$output" == *'result=failed'* ]]
  run bash -c 'grep -q "status.initContainerStatuses" "$1"' _ "$COMMAND_LOG"
  [ "$status" -eq 0 ]
}

@test "wait_service_backends requires the Service object" {
  export MOCK_SERVICE_EXISTS=0
  run wait_service_backends api -n demo 1
  [ "$status" -eq 1 ]
  run bash -c '! grep -q endpointslices "$1"' _ "$COMMAND_LOG"
  [ "$status" -eq 0 ]
}

@test "wait_service_backends accepts a ready endpoint" {
  export MOCK_ENDPOINTS='10.0.0.1|true|false'
  run wait_service_backends api -n demo 2
  [ "$status" -eq 0 ]
}

@test "wait_service_backends accepts absent readiness as unknown" {
  export MOCK_ENDPOINTS='10.0.0.1||false'
  run wait_service_backends api 2
  [ "$status" -eq 0 ]
}

@test "wait_service_backends rejects empty endpoint sets" {
  export MOCK_ENDPOINTS=''
  run wait_service_backends api 1
  [ "$status" -eq 1 ]
}

@test "wait_service_backends ignores terminating endpoints" {
  export MOCK_ENDPOINTS='10.0.0.1|true|true'
  run wait_service_backends api 1
  [ "$status" -eq 1 ]
}

@test "wait_k8s_ready preserves a one-second positive budget" {
  run wait_k8s_ready pod ready -n demo 1
  [ "$status" -eq 0 ]
  run bash -c 'grep -q -- "--timeout=1s" "$1"' _ "$COMMAND_LOG"
  [ "$status" -eq 0 ]
}

@test "wait_rollout preserves a one-second positive budget" {
  run wait_rollout demo -n demo 1
  [ "$status" -eq 0 ]
  run bash -c 'grep -q -- "rollout status deploy/demo --timeout=1s" "$1"' _ "$COMMAND_LOG"
  [ "$status" -eq 0 ]
}
