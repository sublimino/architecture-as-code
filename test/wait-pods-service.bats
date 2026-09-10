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
  export MOCK_GET_DELAY=0

  cat >"$test_bin/kubectl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$COMMAND_LOG"
args="$*"

if [[ "$args" == *"get pod ready"* || "$args" == *"get deploy "* || "$args" == *"get service "* ]] && [ "${MOCK_GET_DELAY:-0}" != 0 ]; then
  sleep "$MOCK_GET_DELAY"
fi

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

@test "wait_pods_ready rejects an unready init container" {
  export MOCK_READY='pod-a|false,true,'
  run wait_pods_ready app=demo 1
  [ "$status" -eq 1 ]
  run bash -c 'grep -q "status.initContainerStatuses" "$1"' _ "$COMMAND_LOG"
  [ "$status" -eq 0 ]
}

@test "wait_pods_ready rejects multi-init pod when first init succeeds but second init is unready" {
  export MOCK_READY='pod-a|true,false,true,'
  run wait_pods_ready app=demo 1
  [ "$status" -eq 1 ]
  run bash -c 'grep -q "status.initContainerStatuses" "$1"' _ "$COMMAND_LOG"
  [ "$status" -eq 0 ]
}

@test "wait_pods_ready accepts multi-init pod when all init containers and main succeed" {
  export MOCK_READY='pod-a|true,true,true,'
  run wait_pods_ready app=demo 1
  [ "$status" -eq 0 ]
}

@test "wait_pods_ready rejects multi-init pod when init containers succeed but main container is unready" {
  export MOCK_READY='pod-a|true,true,false,'
  run wait_pods_ready app=demo 1
  [ "$status" -eq 1 ]
}

@test "wait_pods_ready fail-fast keeps CrashLoopBackOff on second init container retryable" {
  export MOCK_STATES='Running|Always|0,,1,CrashLoopBackOff,,,'
  export MOCK_READY='pod-a|true,false,false,'
  run wait_pods_ready app=demo --fail-fast 1
  [ "$status" -eq 1 ]
  [[ "$output" == *'result=timeout'* ]]
  [[ "$output" != *'result=failed'* ]]
}

@test "wait_pods_ready fail-fast rejects multi-init pod on nonrestartable failure of second init" {
  export MOCK_STATES='Pending|Never|0,,1,,,'
  export MOCK_READY='pod-a|true,false,false,'
  run wait_pods_ready app=demo --fail-fast 2
  [ "$status" -eq 1 ]
  [[ "$output" == *'result=failed'* ]]
}

@test "wait_pods_ready fail-fast rejects multi-init pod on InvalidImageName of second init" {
  export MOCK_STATES='Pending|Always|0,,,InvalidImageName,,,'
  export MOCK_READY='pod-a|true,false,false,'
  run wait_pods_ready app=demo --fail-fast 2
  [ "$status" -eq 1 ]
  [[ "$output" == *'result=failed'* ]]
}

@test "wait_pods_ready any-ready accepts multi-init pod among mixed readiness pods" {
  export MOCK_READY=$'pod-a|true,true,true,\npod-b|true,false,false,'
  run wait_pods_ready app=demo --for=any-ready 1
  [ "$status" -eq 0 ]
  run wait_pods_ready app=demo 1
  [ "$status" -eq 1 ]
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

@test "wait_k8s_ready starts no second phase after budget exhaustion" {
  export MOCK_GET_DELAY=1
  run wait_k8s_ready pod ready -n demo 1
  [ "$status" -eq 1 ]
  run bash -c '! grep -q " wait " "$1"' _ "$COMMAND_LOG"
  [ "$status" -eq 0 ]
}

@test "wait_rollout preserves a one-second positive budget" {
  run wait_rollout demo -n demo 1
  [ "$status" -eq 0 ]
  run bash -c 'grep -q -- "rollout status deploy/demo --timeout=1s" "$1"' _ "$COMMAND_LOG"
  [ "$status" -eq 0 ]
}

@test "wait_rollout starts no second phase after budget exhaustion" {
  export MOCK_GET_DELAY=1
  run wait_rollout demo -n demo 1
  [ "$status" -eq 1 ]
  [[ "$output" == *'result=timeout'* ]]
  run bash -c '! grep -q "rollout status" "$1"' _ "$COMMAND_LOG"
  [ "$status" -eq 0 ]
}

@test "wait_service_backends starts no second phase after budget exhaustion" {
  export MOCK_GET_DELAY=1
  run wait_service_backends api -n demo 1
  [ "$status" -eq 1 ]
  [[ "$output" == *'result=timeout'* ]]
  run bash -c '! grep -q "endpointslices" "$1"' _ "$COMMAND_LOG"
  [ "$status" -eq 0 ]
}

@test "wait_k8s_ready rejects zero deadline immediately without executing probe" {
  run wait_k8s_ready pod ready -n demo 0
  [ "$status" -eq 1 ]
  [[ "$output" == *'result=timeout'* ]]
  run bash -c '! grep -q " wait " "$1"' _ "$COMMAND_LOG"
  [ "$status" -eq 0 ]
}

@test "wait_rollout rejects zero deadline immediately without executing probe" {
  run wait_rollout demo -n demo 0
  [ "$status" -eq 1 ]
  [[ "$output" == *'result=timeout'* ]]
  run bash -c '! grep -q "rollout status" "$1"' _ "$COMMAND_LOG"
  [ "$status" -eq 0 ]
}

@test "wait_service_backends rejects zero deadline immediately without executing probe" {
  run wait_service_backends api -n demo 0
  [ "$status" -eq 1 ]
  [[ "$output" == *'result=timeout'* ]]
  run bash -c '! grep -q "endpointslices" "$1"' _ "$COMMAND_LOG"
  [ "$status" -eq 0 ]
}
