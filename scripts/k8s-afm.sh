#!/usr/bin/env bash
# Lifecycle script for the KubeSec-AFM D2 demo slice.
#
#   k8s-afm.sh preflight  Check the external AFM source repo is present. No side effects.
#   k8s-afm.sh build    Build the image and kind-load it. No deploy, no cluster writes.
#   k8s-afm.sh up       Build image, kind-load, deploy, wait.
#   k8s-afm.sh down     Remove the AFM platform namespace + resources.
#   k8s-afm.sh test     Run the backend pytest suite inside the source repo.
#   k8s-afm.sh seed     POST the demo cluster YAML so the dashboard has data.
#   k8s-afm.sh status   Show pods + /health.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/wait.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/wait.sh"
AFM_SOURCE="${KUBESEC_AFM_ROOT:-/home/andy/src/cp/kubesec-afm}"
CLUSTER_NAME="${CLUSTER_NAME:-osramp}"
NS="fe-k8s-afm"
IMAGE="kubesec-afm:latest"

cmd="${1:-up}"

# The AFM image is built from a source repo that lives OUTSIDE this one. When it
# is absent, `docker build -f <missing>` fails with a bare "no such file or
# directory" naming a path nobody set explicitly, which reads as a broken
# Makefile rather than a missing checkout. Say which repo, and which variable
# relocates it, before spending anything on the build.
require_afm_source() {
  if [ ! -f "$AFM_SOURCE/AFM/docker/backend.Dockerfile" ]; then
    cat >&2 <<EOF
error: KubeSec-AFM source repo not found at: $AFM_SOURCE
  Expected: \$AFM_SOURCE/AFM/docker/backend.Dockerfile
  The AFM image is built from a separate checkout, not from this repo.
  Clone it, then either place it at that path or set KUBESEC_AFM_ROOT:
      KUBESEC_AFM_ROOT=/path/to/kubesec-afm make demo-k8s-afm-up
  Until AFM is deployed, Signal Loom's RBAC Explorer reports
  "KubeSec-AFM is not deployed" — that page reads its data from this slice.
EOF
    exit 1
  fi
}

case "$cmd" in
  preflight)
    # Single source of truth for "can the AFM slice be built here?", so callers
    # that must decide without failing (make demo-signalloom-afm-up) probe it
    # rather than duplicating the path.
    require_afm_source
    echo "KubeSec-AFM source: $AFM_SOURCE"
    ;;
  build)
    # Image build only — no kubectl apply, no rollout, no seeding. This is what
    # `make images-afm` calls, so the AFM slice can be rebuilt alongside every
    # other slice without deploying to (or otherwise touching) a live cluster.
    require_afm_source
    echo "==> Building kubesec-afm image (multi-stage: Next.js + FastAPI + Z3)..."
    docker build -q -f "$AFM_SOURCE/AFM/docker/backend.Dockerfile" \
      -t "$IMAGE" "$AFM_SOURCE/AFM" 2>&1 | tail -2
    echo "==> Loading into kind cluster ${CLUSTER_NAME}..."
    kind load docker-image --name "$CLUSTER_NAME" "$IMAGE" 2>&1 | tail -1
    echo "kubesec-afm image built and loaded: $IMAGE"
    ;;
  up)
    require_afm_source
    echo "==> Building kubesec-afm image (multi-stage: Next.js + FastAPI + Z3)..."
    docker build -q -f "$AFM_SOURCE/AFM/docker/backend.Dockerfile" \
      -t "$IMAGE" "$AFM_SOURCE/AFM" 2>&1 | tail -2
    echo "==> Loading into kind cluster ${CLUSTER_NAME}..."
    kind load docker-image --name "$CLUSTER_NAME" "$IMAGE" 2>&1 | tail -1
    echo "==> Deploying AFM platform to ${NS}..."
    kubectl apply -k "$REPO_ROOT/d2-k8s-afm/apps/afm-platform/local" 2>&1
    echo "==> Waiting for rollout..."
    wait_rollout afm-platform -n "$NS" 120 2>&1 | tail -1
    echo "==> Seeding demo cluster data..."
    kubectl -n "$NS" port-forward svc/afm-platform 18000:8000 >/dev/null 2>&1 &
    PF=$!; wait_reachable "http://localhost:18000/health" 60
    for sample in "$AFM_SOURCE"/AFM/backend/samples/clusters/*.yaml "$AFM_SOURCE"/AFM/backend/samples/clusters/*.json; do
      [ -f "$sample" ] || continue
      name="$(basename "$sample")"
      if python3 -c "
import urllib.request, json, sys, pathlib
data = pathlib.Path('$sample').read_text()
ct = 'application/x-yaml' if '$sample'.endswith('.yaml') else 'application/json'
try:
    r = urllib.request.urlopen(urllib.request.Request('http://localhost:18000/clusters/upload', data=data.encode(), headers={'Content-Type': ct}), timeout=10)
    print(f'  seeded: $name ({r.status})')
except Exception as e:
    print(f'  skip: $name ({e})')
" 2>&1; then true; fi
    done
    # Trigger the escalation analysis so /clusters/local/analysis/latest is
    # populated before acceptance tests run. The CronJob imports the live cluster
    # RBAC as id=local; this POST kicks off the async analysis and waits for it.
    echo "==> Triggering escalation analysis for local cluster..."
    curl -sS -X POST http://localhost:18000/clusters/local/analysis/escalation \
      -H 'Content-Type: application/json' -d '{}' >/dev/null 2>&1 || true
    if _wait_retry 60 "local cluster analysis ready" "curl -fsS http://localhost:18000/clusters/local/analysis/latest 2>/dev/null | jq -e '.metadata.non_admins' >/dev/null 2>&1"; then
      count=$(curl -fsS http://localhost:18000/clusters/local/analysis/latest 2>/dev/null | jq -r '.metadata.non_admins | length // 0')
      echo "  analysis ready: ${count} non-admin subjects"
    else
      echo "  analysis not ready after 60s (tests may fail on /analysis/latest)"
    fi
    kill "$PF" 2>/dev/null || true
    echo "==> KubeSec-AFM deployed."
    kubectl -n "$NS" get pods
    echo ""
    echo "    port-forward: kubectl -n $NS port-forward svc/afm-platform 8000:8000"
    echo "    dashboard:    http://localhost:8000/dashboard"
    echo "    API health:   http://localhost:8000/health"
    ;;
  down)
    echo "==> Removing KubeSec-AFM platform..."
    kubectl delete -k "$REPO_ROOT/d2-k8s-afm/apps/afm-platform/local" --ignore-not-found 2>&1
    echo "==> Done."
    ;;
  test)
    require_afm_source
    echo "==> Running backend pytest from source repo..."
    cd "$AFM_SOURCE/AFM/backend"
    if [ -d "$AFM_SOURCE/AFM/.venv" ]; then
      "$AFM_SOURCE/AFM/.venv/bin/python" -m pytest -q 2>&1
    else
      echo "  No .venv found; running: make -C $AFM_SOURCE/AFM setup && make -C $AFM_SOURCE/AFM test"
      make -C "$AFM_SOURCE/AFM" setup 2>&1 | tail -3
      make -C "$AFM_SOURCE/AFM" test 2>&1
    fi
    ;;
  seed)
    echo "==> Seeding sample clusters..."
    kubectl -n "$NS" port-forward svc/afm-platform 18000:8000 >/dev/null 2>&1 &
    PF=$!; wait_reachable "http://localhost:18000/health" 60
    bash "$AFM_SOURCE/scripts/seed-demo.sh" 2>&1 || true
    kill "$PF" 2>/dev/null || true
    ;;
  status)
    echo "==> Pods in $NS:"
    kubectl -n "$NS" get pods 2>&1
    echo "==> Health:"
    kubectl -n "$NS" port-forward svc/afm-platform 18000:8000 >/dev/null 2>&1 &
    PF=$!; wait_reachable "http://localhost:18000/health" 60
    python3 -c "import urllib.request,json; print(json.load(urllib.request.urlopen('http://localhost:18000/health',timeout=5)))" 2>&1 || echo "  (unreachable)"
    kill "$PF" 2>/dev/null || true
    ;;
  *)
    echo "usage: $0 [preflight|build|up|down|test|seed|status]" >&2
    exit 64
    ;;
esac
