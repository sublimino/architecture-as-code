#!/usr/bin/env bats
# Live integration tests for the AFM cluster-import pipeline.
# Requires: `make demo-k8s-afm-up` (AFM deployed in fe-k8s-afm namespace).

NS="fe-k8s-afm"
PF_PID=""
AFM_PORT="18000"
AFM_URL="http://localhost:${AFM_PORT}"
TEST_JOB="afm-import-bats-test"

setup_file() {
  # Guard: skip entire file if AFM is not deployed
  kubectl get namespace "$NS" >/dev/null 2>&1 \
    || skip "namespace ${NS} not deployed"
  kubectl get deployment afm-platform -n "$NS" >/dev/null 2>&1 \
    || skip "deployment/afm-platform not deployed in ${NS}"

  # Port-forward
  kubectl -n "$NS" port-forward svc/afm-platform "${AFM_PORT}:8000" >/dev/null 2>&1 &
  PF_PID=$!
  export PF_PID

  # Wait for health
  local attempts=0
  while ! python3 -c "import urllib.request; urllib.request.urlopen('${AFM_URL}/health', timeout=3)" >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 30 ] || { echo "AFM health not reachable after 30s" >&2; return 1; }
    sleep 1
  done
}

teardown_file() {
  [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null || true
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

@test "escalation analysis finds non-admin escalation paths" {
  run python3 -c "
import json, time, urllib.request
# Trigger
req = urllib.request.Request('${AFM_URL}/clusters/local/analysis/escalation',
    method='POST', data=b'{}', headers={'Content-Type': 'application/json'})
urllib.request.urlopen(req, timeout=10)
# Poll (60s max)
for _ in range(30):
    time.sleep(2)
    r = urllib.request.urlopen('${AFM_URL}/clusters/local/analysis/latest', timeout=10)
    d = json.load(r)
    if d and isinstance(d, dict) and d.get('metadata'):
        non_admins = d['metadata'].get('non_admins', [])
        assert len(non_admins) > 0, 'no non-admin paths found'
        print(f'OK: {len(non_admins)} non-admin escalation paths')
        break
else:
    raise AssertionError('analysis did not complete in 60s')
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
