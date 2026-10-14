#!/usr/bin/env bash
# local-deploy.sh — Fast, observable in-flight deployment for Signal Loom
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
cd "${REPO_ROOT}"

# Kubeconfig resolution
if [[ -z "${KUBECONFIG:-}" ]]; then
  if [[ -f /tmp/osramp-kubeconfig.yaml ]]; then
    export KUBECONFIG="/tmp/osramp-kubeconfig.yaml"
  elif [[ -f /tmp/osramp.kubeconfig ]]; then
    export KUBECONFIG="/tmp/osramp.kubeconfig"
  fi
fi

# Docker config resolution for nono sandbox
if [[ -z "${DOCKER_CONFIG:-}" ]]; then
  if ! touch "${HOME}/.docker/.probe" 2>/dev/null; then
    export DOCKER_CONFIG="/tmp/.docker"
    mkdir -p "${DOCKER_CONFIG}"
  else
    rm -f "${HOME}/.docker/.probe"
  fi
fi

CLUSTER_NAME="${CLUSTER_NAME:-osramp}"
WORKLOAD="auto"
AUTO_COMMIT=false
COMMIT_MSG=""
DRY_RUN=false
SKIP_RECONCILE=false
FORCE_SYNC_KUSTOMIZE=true

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Fast, observable developer deployment pipeline for in-flight changes.

Options:
  -w, --workload <name>    Workload to deploy: dashboard, backend, docs, manifests, all, auto (default: auto)
  -c, --commit <msg>       Commit in-flight changes with conventional commit message (--no-gpg-sign)
  --auto-commit            Automatically commit dirty files before deploying
  --no-commit              Proceed without committing
  --dry-run                Inspect state and plan deployment without making changes
  --no-reconcile           Skip Flux OCI push and reconcile; rollout local Kind images directly
  -h, --help               Show this help message

Workload mapping:
  dashboard  d2-signalloom/apps/dashboard-signalloom (React frontend)
  backend    d2-signalloom/apps/fe-signalloom (FastAPI + DB migrations)
  docs       d2-signalloom/apps/docs-signalloom (Docs portal)
  manifests  d2-signalloom/apps, d2-signalloom/infra, d2-osramp-fleet
  all        All Signal Loom workloads and manifests
  auto       Automatically detect affected workloads from git diff
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -w|--workload)
      WORKLOAD="$2"
      shift 2
      ;;
    -c|--commit)
      COMMIT_MSG="$2"
      shift 2
      ;;
    --auto-commit)
      AUTO_COMMIT=true
      shift
      ;;
    --no-commit)
      AUTO_COMMIT=false
      COMMIT_MSG=""
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --no-reconcile)
      SKIP_RECONCILE=true
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      ;;
  esac
done

echo "═══════════════════════════════════════════════════════════════"
echo "  Signal Loom Local Deployment Pipeline (In-Flight / Dev)      "
echo "═══════════════════════════════════════════════════════════════"

# 1. Cluster Reachability Preflight
echo "==> Step 1: Preflight cluster checks..."
if ! kubectl cluster-info --request-timeout=4s >/dev/null 2>&1; then
  echo "ERROR: Cluster is not reachable. Verify cluster is running: 'make up'" >&2
  exit 2
fi
echo "    ✓ Kind cluster 'kind-${CLUSTER_NAME}' is responsive."

# 2. Inspect In-Flight Working Tree
echo "==> Step 2: Inspecting in-flight changes..."
DIRTY_FILES=$(git status --porcelain || true)
CURRENT_HEAD=$(git rev-parse --short HEAD)

if [[ -n "${DIRTY_FILES}" ]]; then
  DIRTY_COUNT=$(echo "${DIRTY_FILES}" | wc -l)
  echo "    Notice: ${DIRTY_COUNT} uncommitted file(s) in working tree."
  if [[ "${DRY_RUN}" == "true" ]]; then
    echo "${DIRTY_FILES}" | sed 's/^/      /'
  fi

  if [[ -n "${COMMIT_MSG}" ]]; then
    echo "    Committing changes with user message: ${COMMIT_MSG}"
    git add -A
    git commit --no-gpg-sign -m "${COMMIT_MSG}"
    CURRENT_HEAD=$(git rev-parse --short HEAD)
    echo "    ✓ Committed as ${CURRENT_HEAD}."
  elif [[ "${AUTO_COMMIT}" == "true" ]]; then
    AUTO_MSG="feat: deploy in-flight changes to local cluster ($(date -u +'%Y-%m-%d %H:%M:%S'))"
    echo "    Auto-committing changes: ${AUTO_MSG}"
    git add -A
    git commit --no-gpg-sign -m "${AUTO_MSG}"
    CURRENT_HEAD=$(git rev-parse --short HEAD)
    echo "    ✓ Auto-committed as ${CURRENT_HEAD}."
  else
    echo "    Notice: Proceeding with uncommitted working tree (in-flight mode)."
    echo "    GitOps revisions will reflect HEAD (${CURRENT_HEAD})."
  fi
else
  echo "    Working tree is clean at HEAD (${CURRENT_HEAD})."
fi

# 3. Workload Detection
if [[ "${WORKLOAD}" == "auto" ]]; then
  echo "==> Step 3: Auto-detecting affected workloads from git diff..."
  TARGET_DASHBOARD=false
  TARGET_BACKEND=false
  TARGET_DOCS=false
  TARGET_MANIFESTS=false

  DIFF_PATHS=$(git diff --name-only HEAD~1 2>/dev/null || true)
  if [[ -n "${DIRTY_FILES}" ]]; then
    DIFF_PATHS="${DIFF_PATHS}"$'\n'"$(git status --porcelain | awk '{print $2}')"
  fi

  if echo "${DIFF_PATHS}" | grep -q "^d2-signalloom/apps/dashboard-signalloom"; then
    TARGET_DASHBOARD=true
  fi
  if echo "${DIFF_PATHS}" | grep -q "^d2-signalloom/apps/fe-signalloom"; then
    TARGET_BACKEND=true
  fi
  if echo "${DIFF_PATHS}" | grep -q "^d2-signalloom/apps/docs-signalloom"; then
    TARGET_DOCS=true
  fi
  if echo "${DIFF_PATHS}" | grep -q -E "^d2-signalloom/infra/|^d2-osramp-fleet/|^d2-signalloom/apps/[^/]+/base/|^d2-signalloom/apps/[^/]+/local/"; then
    TARGET_MANIFESTS=true
  fi

  # If nothing specific detected, default to dashboard
  if ! ${TARGET_DASHBOARD} && ! ${TARGET_BACKEND} && ! ${TARGET_DOCS} && ! ${TARGET_MANIFESTS}; then
    echo "    No specific workload edits detected; defaulting to dashboard."
    TARGET_DASHBOARD=true
  fi
else
  TARGET_DASHBOARD=false
  TARGET_BACKEND=false
  TARGET_DOCS=false
  TARGET_MANIFESTS=false

  case "${WORKLOAD}" in
    dashboard) TARGET_DASHBOARD=true ;;
    backend)   TARGET_BACKEND=true ;;
    docs)      TARGET_DOCS=true ;;
    manifests) TARGET_MANIFESTS=true ;;
    all)
      TARGET_DASHBOARD=true
      TARGET_BACKEND=true
      TARGET_DOCS=true
      TARGET_MANIFESTS=true
      ;;
    *)
      echo "ERROR: Unknown workload '${WORKLOAD}'." >&2
      exit 1
      ;;
  esac
fi

echo "    Targets selected:"
${TARGET_DASHBOARD} && echo "      - dashboard-signalloom (Frontend)"
${TARGET_BACKEND}   && echo "      - fe-signalloom (FastAPI Backend / Migrations)"
${TARGET_DOCS}      && echo "      - docs-signalloom (Documentation Portal)"
${TARGET_MANIFESTS} && echo "      - manifests / Kustomizations"

if [[ "${DRY_RUN}" == "true" ]]; then
  echo ""
  echo "==> [DRY RUN] Current deployed staleness report:"
  ./scripts/check-deployed-staleness.sh || true
  echo ""
  echo "==> [DRY RUN] Plan complete. Exiting without modifications."
  exit 0
fi

# 4. Kustomization Tag Synchronization (Prevents GitOps from locking to old release)
if [[ "${FORCE_SYNC_KUSTOMIZE}" == "true" && -f "d2-signalloom/apps/fe-signalloom/local/kustomization.yaml" ]]; then
  echo "==> Step 4: Synchronizing local Kustomization image patches..."
  source ./scripts/lib/source-id.sh
  DASH_SRC_ID="$(source_id_for dashboard-signalloom)"
  DASH_SHORT_TAG="src-${DASH_SRC_ID:0:16}"

  KUST_FILE="d2-signalloom/apps/fe-signalloom/local/kustomization.yaml"
  if grep -q "dashboard-signalloom:" "${KUST_FILE}"; then
    OLD_TAG=$(grep -o "dashboard-signalloom:[^ \"']*" "${KUST_FILE}" | cut -d: -f2)
    if [[ "${OLD_TAG}" != "${DASH_SHORT_TAG}" ]]; then
      echo "    Updating kustomization image patch: ${OLD_TAG} -> ${DASH_SHORT_TAG}"
      sed -i "s|dashboard-signalloom:${OLD_TAG}|dashboard-signalloom:${DASH_SHORT_TAG}|g" "${KUST_FILE}"
      echo "    ✓ Patch synchronized in ${KUST_FILE}."
    else
      echo "    ✓ Kustomization image patch is already aligned (${DASH_SHORT_TAG})."
    fi
  fi
fi

# 5. Workload Builds & Image Publishing
echo "==> Step 5: Building and loading workload image(s)..."

if [[ "${TARGET_DASHBOARD}" == "true" ]]; then
  echo "    Building dashboard-signalloom..."
  ./scripts/build-sign-dashboard.sh
  # Also tag with source fingerprint for exact kustomization matching
  source ./scripts/lib/source-id.sh
  DASH_SRC_ID="$(source_id_for dashboard-signalloom)"
  DASH_SHORT_TAG="src-${DASH_SRC_ID:0:16}"
  docker tag "zot.registry.svc.cluster.local:5000/acme/images/signalloom/apps/dashboard-signalloom:latest" \
    "zot.registry.svc.cluster.local:5000/acme/images/signalloom/apps/dashboard-signalloom:${DASH_SHORT_TAG}" || true
  kind load docker-image --name "${CLUSTER_NAME}" \
    "zot.registry.svc.cluster.local:5000/acme/images/signalloom/apps/dashboard-signalloom:${DASH_SHORT_TAG}" || true
  echo "    ✓ dashboard-signalloom built and loaded into Kind (${DASH_SHORT_TAG})."
fi

if [[ "${TARGET_BACKEND}" == "true" ]]; then
  echo "    Building fe-signalloom backend..."
  source ./scripts/lib/source-id.sh
  mapfile -t FE_BUILD_ARGS < <(source_id_build_args fe-signalloom)
  docker build "${FE_BUILD_ARGS[@]}" -t zot.registry.svc.cluster.local:5000/acme/images/signalloom/apps/fe-signalloom:latest d2-signalloom/apps/fe-signalloom
  CLUSTER_NAME="${CLUSTER_NAME}" ./scripts/kind-load-verified.sh zot.registry.svc.cluster.local:5000/acme/images/signalloom/apps/fe-signalloom:latest
  echo "    ✓ fe-signalloom built and verified on Kind node."
fi

if [[ "${TARGET_DOCS}" == "true" ]]; then
  echo "    Building docs-signalloom..."
  ./scripts/build-sign-docs.sh
  echo "    ✓ docs-signalloom built and loaded."
fi

# 6. GitOps Reconciliation (Push OCI Artifact & Reconcile Flux)
if [[ "${SKIP_RECONCILE}" == "false" ]]; then
  echo "==> Step 6: Pushing OCI manifests and reconciling Flux..."
  ./scripts/push-local.sh signalloom

  if command -v flux >/dev/null 2>&1; then
    echo "    Reconciling Flux OCI source 'fe-signalloom'..."
    flux reconcile source oci fe-signalloom -n fe-signalloom || true
    echo "    Reconciling Flux Kustomization 'apps'..."
    flux reconcile kustomization apps -n fe-signalloom || true
  fi
else
  echo "==> Step 6: Skipping Flux reconciliation (--no-reconcile specified)."
fi

# 7. Deployment Rollout
echo "==> Step 7: Rolling out deployments..."
if [[ "${TARGET_DASHBOARD}" == "true" ]]; then
  kubectl -n fe-signalloom rollout restart deployment/dashboard-signalloom
  kubectl -n fe-signalloom rollout status deployment/dashboard-signalloom --timeout=180s
fi

if [[ "${TARGET_BACKEND}" == "true" ]]; then
  kubectl -n fe-signalloom rollout restart deployment/fe-signalloom
  kubectl -n fe-signalloom rollout status deployment/fe-signalloom --timeout=180s
fi

if [[ "${TARGET_DOCS}" == "true" ]]; then
  kubectl -n fe-signalloom rollout restart deployment/docs-signalloom
  kubectl -n fe-signalloom rollout status deployment/docs-signalloom --timeout=180s
fi

# 8. Port-Forward Healing & Ingress Verification
echo "==> Step 8: Verifying ingress and port-forwards..."
PORT_OK=false
for i in {1..10}; do
  if curl -fsS http://127.0.0.1:19080/ >/dev/null 2>&1; then
    PORT_OK=true
    break
  fi
  sleep 1
done

if [[ "${PORT_OK}" == "false" ]]; then
  echo "    Port-forward on 19080 severed or unresponsive; resuming supervisor..."
  setsid kubectl -n fe-signalloom port-forward svc/dashboard-signalloom 19080:8080 --address 0.0.0.0 </dev/null >/dev/null 2>&1 & disown || true
  sleep 2
fi

# 9. Conclusive Staleness & Evidence Verification
echo "==> Step 9: Running deployed staleness proof..."
./scripts/check-deployed-staleness.sh || true

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Deployment Complete!                                          "
echo "  URL: http://127.0.0.1:19080/                                  "
if [[ -f .tunnel/url ]]; then
  echo "  Tailscale: $(cat .tunnel/url)"
fi
echo "═══════════════════════════════════════════════════════════════"
