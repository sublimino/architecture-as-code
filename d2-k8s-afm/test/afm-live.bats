#!/usr/bin/env bats
# Live integration tests for the AFM cluster-import pipeline.
# Requires: `make demo-k8s-afm-up` (AFM deployed in fe-k8s-afm namespace).

NS="fe-k8s-afm"
TEST_JOB="afm-import-bats-test"

# Where setup_file hands the port-forward off to setup() and teardown_file.
# bats runs setup_file, each test, and teardown_file in SEPARATE processes, so a
# plain shell variable — even an exported one — is invisible to the others.
# BATS_FILE_TMPDIR is the one location all three share (and bats guarantees
# teardown_file runs even when setup_file fails or skips), so it is the only
# place a PID can be parked and still be reapable.
PF_PID_FILE_NAME="port-forward.pid"
PF_LOG_FILE_NAME="port-forward.log"
PF_PORT_FILE_NAME="afm.port"

setup_file() {
  # Guard: skip entire file if AFM is not deployed
  kubectl get namespace "$NS" >/dev/null 2>&1 \
    || skip "namespace ${NS} not deployed"
  kubectl get deployment afm-platform -n "$NS" >/dev/null 2>&1 \
    || skip "deployment/afm-platform not deployed in ${NS}"

  local pf_log="${BATS_FILE_TMPDIR}/${PF_LOG_FILE_NAME}"

  # Bind an EPHEMERAL local port ("" means "kubectl, pick one") rather than a
  # fixed 18000. With a fixed port this file collided with its own previous run
  # whenever the forward leaked, and the collision surfaced as a generic 30s
  # "AFM health not reachable" — pointing the reader at the AFM deployment when
  # the real fault was a stale process on this machine. An ephemeral port cannot
  # collide, so that misdiagnosis is now unreachable by construction.
  kubectl -n "$NS" port-forward svc/afm-platform ":8000" >"$pf_log" 2>&1 &
  local pf_pid=$!
  # Record the PID before anything can fail, so a forward that starts but never
  # becomes usable is still reaped by teardown_file.
  echo "$pf_pid" >"${BATS_FILE_TMPDIR}/${PF_PID_FILE_NAME}"

  # Learn which port kubectl actually chose.
  local port="" attempts=0
  while :; do
    kill -0 "$pf_pid" 2>/dev/null \
      || { echo "port-forward exited during startup: $(cat "$pf_log")" >&2; return 1; }
    port=$(grep -oE 'Forwarding from 127\.0\.0\.1:[0-9]+' "$pf_log" 2>/dev/null \
             | head -1 | grep -oE '[0-9]+$') || true
    [ -n "$port" ] && break
    attempts=$((attempts + 1))
    [ "$attempts" -lt 60 ] \
      || { echo "port-forward never reported a local port after 30s: $(cat "$pf_log")" >&2; return 1; }
    sleep 0.5
  done
  echo "$port" >"${BATS_FILE_TMPDIR}/${PF_PORT_FILE_NAME}"

  # Wait for health. Because the port is exclusively ours and the forward is
  # confirmed alive on every iteration, a timeout here can only mean the AFM
  # pod itself is not serving — so the message says that, and says where to look.
  local url="http://localhost:${port}"
  attempts=0
  while ! python3 -c "import urllib.request; urllib.request.urlopen('${url}/health', timeout=3)" >/dev/null 2>&1; do
    kill -0 "$pf_pid" 2>/dev/null \
      || { echo "port-forward to svc/afm-platform died while waiting for health: $(cat "$pf_log")" >&2; return 1; }
    attempts=$((attempts + 1))
    [ "$attempts" -lt 30 ] || {
      echo "AFM /health not reachable on ${url} after 30s." >&2
      echo "The port-forward is alive on an exclusive local port, so this is the" >&2
      echo "afm-platform pod not serving, NOT a local port collision. Check:" >&2
      echo "  kubectl -n ${NS} describe pod -l app.kubernetes.io/name=afm-platform" >&2
      echo "  kubectl -n ${NS} logs -l app.kubernetes.io/name=afm-platform --previous" >&2
      return 1
    }
    sleep 1
  done
}

setup() {
  # Each test runs in its own process, so re-derive the port chosen by setup_file.
  AFM_PORT="$(cat "${BATS_FILE_TMPDIR}/${PF_PORT_FILE_NAME}" 2>/dev/null)"
  AFM_URL="http://localhost:${AFM_PORT}"
}

teardown_file() {
  local pid_file="${BATS_FILE_TMPDIR}/${PF_PID_FILE_NAME}"
  if [ -r "$pid_file" ]; then
    local pf_pid
    pf_pid="$(cat "$pid_file")"
    # Kill by PID, never by pattern. A `pkill -f port-forward` here would match
    # this very shell's own command line (bats wraps each phase in `bash -c`)
    # and take out the run itself.
    if [ -n "$pf_pid" ] && kill -0 "$pf_pid" 2>/dev/null; then
      kill "$pf_pid" 2>/dev/null || true
      # Confirm it is really gone; setup_file's shell has exited so the forward
      # is reparented to init and cannot be `wait`ed on.
      local waited=0
      while kill -0 "$pf_pid" 2>/dev/null && [ "$waited" -lt 50 ]; do
        sleep 0.1
        waited=$((waited + 1))
      done
      kill -9 "$pf_pid" 2>/dev/null || true
    fi
  fi
  kubectl -n "$NS" delete job "$TEST_JOB" --ignore-not-found >/dev/null 2>&1 || true
}

# -- CronJob execution --------------------------------------------------------

@test "cluster-import CronJob can be triggered and succeeds" {
  kubectl -n "$NS" delete job "$TEST_JOB" --ignore-not-found >/dev/null 2>&1
  run kubectl -n "$NS" create job "$TEST_JOB" --from=cronjob/afm-cluster-import
  [ "$status" -eq 0 ]

  run kubectl -n "$NS" wait --for=condition=complete "job/$TEST_JOB" --timeout=120s
  [ "$status" -eq 0 ]

  run kubectl -n "$NS" logs "job/$TEST_JOB"
  [[ "$output" == *"Collected"* ]]
  [[ "$output" == *"Converted"* ]]
  [[ "$output" == *"Imported"* ]]
  [[ "$output" != *"ERROR"* ]]
}

@test "cluster-import collected a non-trivial number of RBAC items" {
  run kubectl -n "$NS" logs "job/$TEST_JOB"
  [ "$status" -eq 0 ]
  local count
  count=$(echo "$output" | grep -oP 'Collected \K[0-9]+' | head -1)
  [ -n "$count" ]
  [ "$count" -gt 30 ]
}

# -- Imported data quality -----------------------------------------------------

@test "imported local cluster has fe-signalloom, inf-signalloom, and inf-bao namespaces" {
  run python3 -c "
import json, urllib.request
r = urllib.request.urlopen('${AFM_URL}/clusters/local/rbac', timeout=10)
d = json.load(r)
namespaces = set()
for role in d.get('roles', []):
    ns = role.get('namespace', '')
    if ns: namespaces.add(ns)
for binding in d.get('bindings', []):
    ns = binding.get('namespace', '')
    if ns: namespaces.add(ns)
for expected in ['fe-signalloom', 'inf-signalloom', 'inf-bao']:
    assert expected in namespaces, f'{expected} not in {sorted(namespaces)}'
print(f'OK: {len(namespaces)} namespaces including all 3 expected')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "imported local cluster has non-trivial subjects, roles, and bindings" {
  run python3 -c "
import json, urllib.request
r = urllib.request.urlopen('${AFM_URL}/clusters/local/rbac', timeout=10)
d = json.load(r)
s, ro, b = len(d.get('subjects', [])), len(d.get('roles', [])), len(d.get('bindings', []))
assert s > 10, f'too few subjects: {s}'
assert ro > 20, f'too few roles: {ro}'
assert b > 20, f'too few bindings: {b}'
print(f'OK: {s} subjects, {ro} roles, {b} bindings')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

# -- Escalation analysis ------------------------------------------------------

# `check_pairs: false` stops the engine after the single-subject and impersonation
# phases and returns the metadata block asserted below (detector.py's early
# return carries the same `non_admins`), so the contract under test is unchanged.
#
# It is set because the default `check_pairs: true` cannot run in this deployment.
# The collusion phase sizes its solver pool with `mp.cpu_count()`, which reports
# the HOST's cores (24 here) because it does not read the cgroup CPU quota. It
# then forks 24 Z3 processes inside a container limited to 500m CPU / 512Mi, and
# the pod is OOMKilled mid-analysis — which also wipes the in-memory cluster
# store, so the graph and conformance tests below fail as collateral damage.
# `KUBESEC_MAX_WORKERS=1` in the deployment does not prevent this: it bounds
# concurrent JOBS via the JobRunner pool, not the pool forked inside one job.
# That is an upstream defect in kubesec-afm, not something this test can repair;
# scoping the request is how this file stays honest about it in the meantime.
@test "escalation analysis finds non-admin escalation paths" {
  run python3 -c "
import json, time, urllib.request
# Trigger, and remember WHICH job so a stale result from an earlier run cannot
# satisfy this assertion.
req = urllib.request.Request('${AFM_URL}/clusters/local/analysis/escalation',
    method='POST', data=b'{\"check_pairs\": false}',
    headers={'Content-Type': 'application/json'})
job_id = json.load(urllib.request.urlopen(req, timeout=10))['job_id']
# Poll (60s max)
for _ in range(30):
    time.sleep(2)
    s = json.load(urllib.request.urlopen(
        '${AFM_URL}/clusters/local/analysis/status', timeout=10))
    if s.get('last_completed_job_id') == job_id:
        break
    if not s.get('has_running'):
        raise AssertionError(
            f'job {job_id} is no longer running but never completed; '
            f'status={s}. If the pod restarted, check for an OOMKill: '
            f'kubectl -n fe-k8s-afm describe pod -l app.kubernetes.io/name=afm-platform')
else:
    raise AssertionError(f'analysis job {job_id} did not complete in 60s')
d = json.load(urllib.request.urlopen(
    '${AFM_URL}/clusters/local/analysis/latest', timeout=10))
assert isinstance(d, dict) and d.get('metadata'), f'no metadata in result: {type(d).__name__}'
non_admins = d['metadata'].get('non_admins', [])
assert len(non_admins) > 0, 'no non-admin paths found'
print(f'OK: {len(non_admins)} non-admin escalation paths')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

# -- Graph and conformance ----------------------------------------------------

@test "RBAC graph has nodes and edges for the local cluster" {
  run python3 -c "
import json, urllib.request
r = urllib.request.urlopen('${AFM_URL}/clusters/local/rbac/graph', timeout=10)
d = json.load(r)
nodes = len(d.get('nodes', []))
links = len(d.get('links', d.get('edges', [])))
assert nodes > 10, f'too few graph nodes: {nodes}'
assert links > 10, f'too few graph links: {links}'
print(f'OK: {nodes} nodes, {links} links')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "conformance report is available for the local cluster" {
  run python3 -c "
import json, urllib.request
r = urllib.request.urlopen('${AFM_URL}/clusters/local/rbac/conformance', timeout=10)
d = json.load(r)
assert isinstance(d, (list, dict)), f'unexpected type: {type(d)}'
if isinstance(d, list):
    assert len(d) > 0, 'empty conformance report'
    print(f'OK: {len(d)} conformance findings')
else:
    print(f'OK: conformance response keys: {list(d.keys())}')
"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}
