#!/usr/bin/env bats
#
# @id      sl-memory-hunt
# @target  .agents/skills/sl-memory-hunt/Tools/memory-hunt.sh
# @target  .agents/skills/sl-silent-failure-audit/Tools/audit-invariants.sh (check 5)
# @doc     .agents/skills/sl-memory-hunt/SKILL.md
#
# Offline contracts for memory-hunt.sh and the audit's OOM/restart-loop check.
# Everything runs against fixture JSON and fake kubectl/docker/sleep binaries;
# no cluster is touched. Assertions check names, counts, timestamps and MiB
# values, not just exit codes.

setup() {
  repo_root="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
  tool="${repo_root}/.agents/skills/sl-memory-hunt/Tools/memory-hunt.sh"
  audit="${repo_root}/.agents/skills/sl-silent-failure-audit/Tools/audit-invariants.sh"
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  export CALL_LOG="$BATS_TEST_TMPDIR/calls.log"
  : >"$CALL_LOG"
  export FAKE_PODS="$BATS_TEST_TMPDIR/pods.json"
  export FAKE_SERIES="$BATS_TEST_TMPDIR/series.txt"
  export FAKE_COUNTER="$BATS_TEST_TMPDIR/counter"
  : >"$FAKE_SERIES"
  echo 0 >"$FAKE_COUNTER"

  cat >"$bin/kubectl" <<'FAKE'
#!/usr/bin/env bash
echo "kubectl $*" >>"$CALL_LOG"
case "$*" in
  cluster-info*) exit 0 ;;
  "get nodes"*) echo "osramp-control-plane"; exit 0 ;;
  "get pods"*) cat "$FAKE_PODS"; exit 0 ;;
  "get pod "*)
    name="$3"
    jq -e --arg n "$name" '.items[] | select(.metadata.name == $n)' "$FAKE_PODS" || exit 1
    exit 0 ;;
esac
exit 0
FAKE

  cat >"$bin/docker" <<'FAKE'
#!/usr/bin/env bash
echo "docker $*" >>"$CALL_LOG"
case "$*" in
  *"crictl stats -o json"*)
    i=$(cat "$FAKE_COUNTER"); i=$((i + 1)); echo "$i" >"$FAKE_COUNTER"
    v=$(sed -n "${i}p" "$FAKE_SERIES")
    [ -n "$v" ] || exit 1
    printf '{"stats":[{"memory":{"workingSetBytes":{"value":"%s"}}}]}\n' "$v" ;;
  *"crictl inspecti"*)
    echo '{"info":{"imageSpec":{"config":{"Env":["PATH=/usr/bin","GOMAXPROCS=2"]}}}}' ;;
  *"crictl inspect "*)
    echo '{"status":{"image":{"image":"zot/signal-ingest:src-abc"}},"info":{"runtimeSpec":{"process":{"env":["HOSTNAME=x","GOMEMLIMIT=1800MiB"]}}}}' ;;
  *"crictl images"*) : ;;
esac
exit 0
FAKE

  # Fake sleep: records the interval and, for /proc sampling, swaps in the next
  # status snapshot so a fixed PID file can carry a time series.
  cat >"$bin/sleep" <<'FAKE'
#!/usr/bin/env bash
echo "sleep $*" >>"$CALL_LOG"
if [ -n "${FAKE_PROC_QUEUE:-}" ]; then
  i=$(cat "$FAKE_COUNTER"); i=$((i + 1)); echo "$i" >"$FAKE_COUNTER"
  next="${FAKE_PROC_QUEUE}/${i}.status"
  if [ -f "$next" ]; then cp "$next" "$FAKE_PROC_TARGET"; else rm -f "$FAKE_PROC_TARGET"; fi
fi
exit 0
FAKE
  chmod +x "$bin/kubectl" "$bin/docker" "$bin/sleep"
  export KUBECTL="$bin/kubectl" DOCKER="$bin/docker" SLEEP="$bin/sleep"
}

# pod_json NAME RESTARTS LAST_REASON LAST_FINISHED [STATE] [LIMIT] [INIT_REASON]
pod_json() {
  jq -n --arg name "$1" --argjson rc "$2" --arg reason "$3" --arg fin "$4" \
    --arg state "${5:-running}" --arg limit "${6:-2Gi}" --arg init "${7:-}" '
    {metadata: {name: $name, namespace: "fe-signalloom"},
     spec: {nodeName: "osramp-control-plane",
            containers: [{name: ($name | sub("-[a-z0-9]+-[a-z0-9]+$"; "")), resources: {limits: {memory: $limit}}}]},
     status: {phase: "Running",
       containerStatuses: [{
         name: ($name | sub("-[a-z0-9]+-[a-z0-9]+$"; "")),
         restartCount: $rc,
         containerID: "containerd://cid-\($name)",
         imageID: "zot/img@sha256:abc",
         state: (if $state == "running" then {running: {startedAt: "2026-10-15T09:00:00Z"}}
                 else {terminated: {reason: $state, finishedAt: "2026-10-15T09:30:00Z"}} end),
         lastState: (if $reason == "" then {} else {terminated: {reason: $reason, finishedAt: $fin}} end)
       }],
       initContainerStatuses: (if $init == "" then [] else
         [{name: "migrate", restartCount: 1, state: {running: {}},
           lastState: {terminated: {reason: $init, finishedAt: "2026-10-15T08:00:00Z"}}}] end)
     }}'
}

pods() { jq -s '{items: .}' >"$FAKE_PODS"; }

# ---------------------------------------------------------------- scan

@test "scan flags an OOMKilled container with its name, restart count, OOM time and limit" {
  { pod_json signal-ingest-7f9c-abcde 28 OOMKilled 2026-10-15T14:58:01Z
    pod_json dashboard-signalloom-5d8-xyz12 0 "" ""; } | pods
  run "$tool" scan -n fe-signalloom
  [ "$status" -eq 1 ]
  [[ "$output" == *"FLAGGED: 1 container(s)"* ]]
  [[ "$output" == *"fe-signalloom/signal-ingest-7f9c-abcde [signal-ingest] restarts=28 last=OOMKilled at=2026-10-15T14:58:01Z limit=2Gi flags=oom,restarts last_oom=2026-10-15T14:58:01Z"* ]]
  [[ "$output" != *dashboard* ]]
  grep -q -- "get pods -n fe-signalloom -o json" "$CALL_LOG"

  run "$tool" scan -n fe-signalloom --json
  [ "$status" -eq 1 ]
  [ "$(jq -r '.flagged' <<<"$output")" = 1 ]
  [ "$(jq -r '.containers[0].pod' <<<"$output")" = signal-ingest-7f9c-abcde ]
  [ "$(jq -r '.containers[0].restarts' <<<"$output")" = 28 ]
  [ "$(jq -r '.containers[0].last_oom_at' <<<"$output")" = 2026-10-15T14:58:01Z ]
  [ "$(jq -c '.containers[0].flags' <<<"$output")" = '["oom","restarts"]' ]
}

@test "scan flags an OOM even below the restart threshold, and a currently-terminated OOM" {
  { pod_json api-6c7-aaaaa 1 OOMKilled 2026-10-15T10:00:00Z
    pod_json worker-6c7-bbbbb 0 "" "" OOMKilled; } | pods
  run "$tool" scan -A --json
  [ "$status" -eq 1 ]
  [ "$(jq -r '[.containers[].pod] | join(",")' <<<"$output")" = "api-6c7-aaaaa,worker-6c7-bbbbb" ]
  [ "$(jq -c '[.containers[].flags]' <<<"$output")" = '[["oom"],["oom"]]' ]
  [ "$(jq -r '.containers[1].last_oom_at' <<<"$output")" = 2026-10-15T09:30:00Z ]
  grep -q -- "get pods -A -o json" "$CALL_LOG"
}

@test "scan detects an OOMKilled init container" {
  pod_json app-1a2-ccccc 0 "" "" running 1Gi OOMKilled | pods
  run "$tool" scan --json
  [ "$status" -eq 1 ]
  [ "$(jq -r '.containers[0].container' <<<"$output")" = migrate ]
  [ "$(jq -r '.containers[0].last_oom_at' <<<"$output")" = 2026-10-15T08:00:00Z ]
}

@test "clean pods pass with exit 0 and a CLEAN line" {
  { pod_json signal-ingest-7f9c-abcde 0 "" ""
    pod_json policy-engine-867-lvh5v 2 Error 2026-10-14T00:00:00Z; } | pods
  run "$tool" scan -n fe-signalloom
  [ "$status" -eq 0 ]
  [ "$output" = "CLEAN: no OOMKilled containers, none above 5 restarts" ]
  run "$tool" scan --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.flagged' <<<"$output")" = 0 ]
}

@test "restart threshold boundary: equal to threshold passes, one above is flagged" {
  { pod_json at-th-aaaaa 5 Error 2026-10-15T01:00:00Z
    pod_json over-th-bbbbb 6 Completed 2026-10-15T02:00:00Z; } | pods
  run "$tool" scan --json
  [ "$status" -eq 1 ]
  [ "$(jq -r '[.containers[].pod] | join(",")' <<<"$output")" = over-th-bbbbb ]
  [ "$(jq -r '.containers[0].restarts' <<<"$output")" = 6 ]
  [ "$(jq -c '.containers[0].flags' <<<"$output")" = '["restarts"]' ]
  [ "$(jq -r '.containers[0].last_oom_at' <<<"$output")" = null ]
  [ "$(jq -r '.containers[0].last_reason' <<<"$output")" = Completed ]

  run "$tool" scan --threshold 4 --json
  [ "$(jq -r '[.containers[].pod] | join(",")' <<<"$output")" = "at-th-aaaaa,over-th-bbbbb" ]
  [ "$(jq -r '.threshold' <<<"$output")" = 4 ]

  run "$tool" scan --threshold 6
  [ "$status" -eq 0 ]
  [[ "$output" == *"none above 6 restarts"* ]]
}

@test "scan exits 3 when the cluster is unreachable and 2 on a bad threshold" {
  cat >"$BATS_TEST_TMPDIR/bin/kubectl" <<'FAKE'
#!/usr/bin/env bash
exit 1
FAKE
  run "$tool" scan
  [ "$status" -eq 3 ]
  [[ "$output" == *"kubectl get pods failed"* ]]
  run "$tool" scan --threshold x
  [ "$status" -eq 2 ]
}

@test "usage: no subcommand exits 2, unknown subcommand exits 2" {
  run "$tool"
  [ "$status" -eq 2 ]
  run "$tool" frobnicate
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown subcommand 'frobnicate'"* ]]
}

# ---------------------------------------------------------------- sample (crictl)

@test "sample computes peak MiB, peak time and percent of limit from a crictl series" {
  pod_json signal-ingest-7f9c-abcde 0 "" "" | pods
  # 194 MiB -> 1700 MiB -> 1024 MiB -> 900 MiB (the 2026-10-15 shape)
  printf '%s\n' 203423744 1782579200 1073741824 943718400 >"$FAKE_SERIES"
  run "$tool" sample --pod signal-ingest-7f9c-abcde -n fe-signalloom --interval 15 --duration 60 --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.target' <<<"$output")" = fe-signalloom/signal-ingest-7f9c-abcde/signal-ingest ]
  [ "$(jq -r '.samples | length' <<<"$output")" = 4 ]
  [ "$(jq -c '[.samples[].t_s]' <<<"$output")" = '[0,15,30,45]' ]
  [ "$(jq -r '.peak_bytes' <<<"$output")" = 1782579200 ]
  [ "$(jq -r '.peak_mib' <<<"$output")" = 1700 ]
  [ "$(jq -r '.peak_at_s' <<<"$output")" = 15 ]
  [ "$(jq -r '.first_bytes' <<<"$output")" = 203423744 ]
  [ "$(jq -r '.last_bytes' <<<"$output")" = 943718400 ]
  [ "$(jq -r '.limit_bytes' <<<"$output")" = 2147483648 ]
  [ "$(jq -r '.peak_pct_of_limit' <<<"$output")" = 83 ]
  # crictl ran on the pod's node against the bare container id
  grep -q "docker exec osramp-control-plane crictl stats -o json cid-signal-ingest-7f9c-abcde" "$CALL_LOG"
  [ "$(grep -c '^sleep 15$' "$CALL_LOG")" = 3 ]
}

@test "sample text output prints the series and a peak line" {
  pod_json signal-ingest-7f9c-abcde 0 "" "" | pods
  printf '%s\n' 203423744 1782579200 >"$FAKE_SERIES"
  run "$tool" sample --pod signal-ingest-7f9c-abcde -n fe-signalloom --interval 15 --duration 30
  [ "$status" -eq 0 ]
  [[ "$output" == *"t=   0s       194.0 MiB"* ]]
  [[ "$output" == *"t=  15s      1700.0 MiB"* ]]
  [[ "$output" == *"samples=2 first=194.0 MiB last=1700.0 MiB peak=1700.0 MiB at t=15s"* ]]
  [[ "$output" == *"limit=2048.0 MiB peak_pct_of_limit=83.0%"* ]]
}

@test "sample resolves a unique pod-name prefix and honours CRICTL_NODE" {
  { pod_json signal-ingest-659-vggd6 0 "" ""
    pod_json fleet-manager-7c5-mt9zg 0 "" ""; } | pods
  printf '%s\n' 44040192 >"$FAKE_SERIES"
  CRICTL_NODE=osramp-worker2 run "$tool" sample --pod signal-ingest -n fe-signalloom --interval 5 --duration 5 --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.target' <<<"$output")" = fe-signalloom/signal-ingest-659-vggd6/signal-ingest ]
  [ "$(jq -r '.peak_mib' <<<"$output")" = 42 ]
  grep -q "docker exec osramp-worker2 crictl stats -o json cid-signal-ingest-659-vggd6" "$CALL_LOG"
}

@test "sample refuses an ambiguous prefix and a missing pod with exit 3" {
  { pod_json signal-ingest-659-aaaaa 0 "" ""
    pod_json signal-ingest-659-bbbbb 0 "" ""; } | pods
  run "$tool" sample --pod signal-ingest -n fe-signalloom --duration 1 --interval 1
  [ "$status" -eq 3 ]
  [[ "$output" == *"ambiguous"*"signal-ingest-659-aaaaa signal-ingest-659-bbbbb"* ]]
  run "$tool" sample --pod nope -n fe-signalloom
  [ "$status" -eq 3 ]
  [[ "$output" == *"not found"* ]]
}

@test "sample exits 3 when the container yields no samples" {
  pod_json signal-ingest-7f9c-abcde 0 "" "" | pods
  : >"$FAKE_SERIES"
  run "$tool" sample --pod signal-ingest-7f9c-abcde -n fe-signalloom --interval 1 --duration 3
  [ "$status" -eq 3 ]
  [[ "$output" == *"no samples taken"* ]]
}

# ---------------------------------------------------------------- sample (/proc)

@test "sample --pid reads VmRSS series and VmHWM from a fake /proc" {
  proc="$BATS_TEST_TMPDIR/proc"; queue="$BATS_TEST_TMPDIR/queue"
  mkdir -p "$proc/4242" "$queue"
  mk() { printf 'Name:\tsignal-ingest\nVmHWM:\t%s kB\nVmRSS:\t%s kB\nThreads:\t9\n' "$1" "$2"; }
  mk 1000 1000 >"$proc/4242/status"
  mk 5000 5000 >"$queue/1.status"
  mk 6000 3000 >"$queue/2.status"
  export FAKE_PROC_QUEUE="$queue" FAKE_PROC_TARGET="$proc/4242/status"
  PROC_ROOT="$proc" run "$tool" sample --pid 4242 --interval 2 --duration 6 --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.target' <<<"$output")" = pid:4242 ]
  [ "$(jq -r '.source' <<<"$output")" = proc ]
  [ "$(jq -c '[.samples[].bytes]' <<<"$output")" = '[1024000,5120000,3072000]' ]
  [ "$(jq -r '.peak_bytes' <<<"$output")" = 5120000 ]
  [ "$(jq -r '.peak_mib' <<<"$output")" = 4.9 ]
  [ "$(jq -r '.vmhwm_bytes' <<<"$output")" = 6144000 ]
  [ "$(jq -r '.limit_bytes' <<<"$output")" = null ]
}

@test "sample --pid stops cleanly when the process exits mid-series, exits 3 if absent" {
  proc="$BATS_TEST_TMPDIR/proc"; queue="$BATS_TEST_TMPDIR/queue"
  mkdir -p "$proc/77" "$queue"
  printf 'VmHWM:\t2048 kB\nVmRSS:\t2048 kB\n' >"$proc/77/status"
  export FAKE_PROC_QUEUE="$queue" FAKE_PROC_TARGET="$proc/77/status"
  PROC_ROOT="$proc" run "$tool" sample --pid 77 --interval 1 --duration 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"target gone or unreadable, stopping"* ]]
  [[ "$output" == *"samples=1 first=2.0 MiB last=2.0 MiB peak=2.0 MiB"* ]]
  PROC_ROOT="$proc" run "$tool" sample --pid 999
  [ "$status" -eq 3 ]
}

@test "sample rejects --pod with --pid and a missing target with exit 2" {
  run "$tool" sample --pod a --pid 1
  [ "$status" -eq 2 ]
  run "$tool" sample
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------- env

@test "env reports image and runtime env (GOMAXPROCS, GOMEMLIMIT)" {
  pod_json signal-ingest-7f9c-abcde 0 "" "" | pods
  run "$tool" env --pod signal-ingest-7f9c-abcde -n fe-signalloom --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.image' <<<"$output")" = zot/signal-ingest:src-abc ]
  [ "$(jq -r '.image_env | map(select(startswith("GOMAXPROCS="))) | .[0]' <<<"$output")" = GOMAXPROCS=2 ]
  [ "$(jq -r '.runtime_env | map(select(startswith("GOMEMLIMIT="))) | .[0]' <<<"$output")" = GOMEMLIMIT=1800MiB ]
  grep -q "crictl inspecti zot/signal-ingest:src-abc" "$CALL_LOG"
}

# ---------------------------------------------------------------- sl-silent-failure-audit check 5

audit_env() {
  # Empty REPO_ROOT: checks 1-3 find nothing to scan and pass; checks 4-5 see the fakes.
  mkdir -p "$BATS_TEST_TMPDIR/repo"
  export REPO_ROOT="$BATS_TEST_TMPDIR/repo"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  unset KUBECTL DOCKER
}

@test "audit check 5 fails on an OOMKilled container and names it" {
  audit_env
  { pod_json signal-ingest-7f9c-abcde 28 OOMKilled 2026-10-15T14:58:01Z
    pod_json docs-signalloom-9c6-phdjx 0 "" ""; } | pods
  run "$audit"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL] OOM / restart loop: containers OOMKilled or restarting:"* ]]
  [[ "$output" == *"fe-signalloom/signal-ingest-7f9c-abcde [signal-ingest] restarts=28 last=OOMKilled"* ]]
  [[ "$output" == *"RESULT: 1 INVARIANT FAILURES DETECTED"* ]]
  # existing check 4 still ran and passed (pod is Running, not CrashLoopBackOff)
  [[ "$output" == *"[PASS] Pod CRI Runtime"* ]]
}

@test "audit check 5 passes on clean pods and honours AUDIT_RESTART_THRESHOLD" {
  audit_env
  pod_json fleet-manager-7c5-mt9zg 6 Completed 2026-10-15T15:20:29Z | pods
  AUDIT_RESTART_THRESHOLD=10 run "$audit"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[PASS] OOM / restart loop: no OOMKilled containers, none above 10 restarts"* ]]
  [[ "$output" == *"RESULT: ALL INVARIANTS PASS"* ]]
  run "$audit"
  [ "$status" -eq 1 ]
  [[ "$output" == *"fleet-manager-7c5-mt9zg [fleet-manager] restarts=6 last=Completed"* ]]
}

@test "audit check 5 fails loudly when the detector is missing" {
  audit_env
  pod_json docs-signalloom-9c6-phdjx 0 "" "" | pods
  MEMORY_HUNT="$BATS_TEST_TMPDIR/absent.sh" run "$audit"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[FAIL] OOM / restart loop: detector missing"* ]]
}
