#!/usr/bin/env bats
# Smoke tests for the KubeSec-AFM D2 slice.
# Run: bats d2-k8s-afm/test/afm-smoke.bats
# Requires: the AFM platform deployed (make demo-k8s-afm-up) + port-forward on 18000.

# Two dirs up: test/ → d2-k8s-afm/ → governor root (the OSRAMP repo).
repo_root="$(cd "$(dirname "$BATS_TEST_DIRNAME")/.." && pwd)"

setup_file() {
  # Start a background port-forward for the test run.
  kubectl -n fe-k8s-afm port-forward svc/afm-platform 18000:8000 >/dev/null 2>&1 &
  export PF_PID=$!
  sleep 3
}

teardown_file() {
  kill "$PF_PID" 2>/dev/null || true
}

@test "AFM namespace exists and has a running pod" {
  run kubectl -n fe-k8s-afm get pods --no-headers
  [[ "$output" == *"Running"* ]]
}

@test "AFM /health returns 200" {
  run python3 -c "import urllib.request; r=urllib.request.urlopen('http://localhost:18000/health',timeout=5); print(r.status)"
  [[ "$output" == *"200"* ]]
}

@test "AFM /dashboard/ returns HTML" {
  run python3 -c "import urllib.request; r=urllib.request.urlopen('http://localhost:18000/dashboard/',timeout=5); print(r.read()[:100].decode())"
  [[ "$output" == *"html"* ]] || [[ "$output" == *"DOCTYPE"* ]] || [[ "$output" == *"__NEXT"* ]]
}

@test "AFM /clusters responds (sample data loaded)" {
  run python3 -c "import urllib.request,json; r=urllib.request.urlopen('http://localhost:18000/clusters',timeout=5); d=json.load(r); print(type(d).__name__, len(d) if isinstance(d,list) else '')"
  [[ "$output" == *"list"* ]]
}

@test "D2 kustomization builds cleanly" {
  run kubectl kustomize "$repo_root/d2-k8s-afm/apps/afm-platform/local"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"kind: Deployment"* ]]
  [[ "$output" == *"afm-platform"* ]]
}
