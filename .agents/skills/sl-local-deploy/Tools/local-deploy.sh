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

# Injectable tool binaries for testing and custom environments
DOCKER_BIN="${DOCKER_BIN:-docker}"
KUBECTL_BIN="${KUBECTL_BIN:-kubectl}"
KIND_BIN="${KIND_BIN:-kind}"
MAKE_BIN="${MAKE_BIN:-make}"
CURL_BIN="${CURL_BIN:-curl}"
CHECK_STALENESS_BIN="${CHECK_STALENESS_BIN:-./scripts/check-deployed-staleness.sh}"
SIGNAL_INGEST_TAG_BIN="${SIGNAL_INGEST_TAG_BIN:-./scripts/signal-ingest-image-tag.sh}"
BUILD_DASHBOARD_BIN="${BUILD_DASHBOARD_BIN:-./scripts/build-sign-dashboard.sh}"
BUILD_DOCS_BIN="${BUILD_DOCS_BIN:-./scripts/build-sign-docs.sh}"
KIND_LOAD_VERIFIED_BIN="${KIND_LOAD_VERIFIED_BIN:-./scripts/kind-load-verified.sh}"
PUSH_LOCAL_BIN="${PUSH_LOCAL_BIN:-./scripts/push-local.sh}"
FLUX_BIN="${FLUX_BIN:-flux}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Fast, observable developer deployment pipeline for in-flight changes.

Options:
  -w, --workload <name>    Workload to deploy: dashboard, backend, docs, ingest, fleet, warden, supercred-runner, manifests, all, auto (default: auto)
  -c, --commit <msg>       Commit in-flight changes with conventional commit message (--no-gpg-sign)
  --auto-commit            Automatically commit dirty files before deploying
  --no-commit              Proceed without committing
  --dry-run                Inspect state and plan deployment without making changes
  --no-reconcile           Skip Flux OCI push and reconcile; rollout local Kind images directly
  --env, --remote <lane>   Deploy to remote GCP VM lane (e.g. demo-1, demo-2, ci-1, ci-2)
  -h, --help               Show this help message

Workload mapping:
  dashboard         d2-signalloom/apps/dashboard-signalloom (React frontend)
  backend           d2-signalloom/apps/fe-signalloom (FastAPI + DB migrations)
  docs               d2-signalloom/apps/docs-signalloom (Docs portal)
  ingest             d2-signalloom/apps/signal-ingest (Signal Fusion Ingest Service)
  fleet              d2-osramp-fleet (fleet ResourceSets; push + reconcile Kustomization 'tenants')
  warden             signalloom-warden DaemonSet (sentinel image publish)
  supercred-runner   supercred-demo-runner image (SuperCred/Signal Fusion/Distance Latency demo API)
  manifests          d2-signalloom/apps, d2-signalloom/infra
  all                All Signal Loom workloads and manifests, including fleet, warden, supercred-runner
  auto               Automatically detect affected workloads from git diff
EOF
  exit 0
}

ENV_KEY="${ENV:-}"

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
    --env|--remote)
      ENV_KEY="$2"
      shift 2
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

# If remote environment is specified, dispatch execution to the target VM
if [[ -n "${ENV_KEY:-}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
  HANDOFF="${REPO_ROOT}/deploy/gcp/${ENV_KEY}.handoff.json"

  if [[ ! -f "$HANDOFF" ]]; then
    echo "ERROR: Environment handoff file not found: $HANDOFF" >&2
    exit 2
  fi

  PROJECT_ID=$(jq -r '.project_id' "$HANDOFF")
  ZONE=$(jq -r '.zone' "$HANDOFF")
  INSTANCE_NAME=$(jq -r '.instance_name' "$HANDOFF")
  OPERATOR_SA=$(jq -r '.operator_sa' "$HANDOFF")

  echo -e "\033[1;36mℹ\033[0m Dispatching local-deploy to remote VM ${INSTANCE_NAME} (${ENV_KEY})..."

  "${REPO_ROOT}/scripts/gcp-tf/signalfusion-targeted-apply.sh" "${ENV_KEY}"
  exit $?
fi

echo "═══════════════════════════════════════════════════════════════"
echo "  Signal Loom Local Deployment Pipeline (In-Flight / Dev)      "
echo "═══════════════════════════════════════════════════════════════"

# 1. Cluster Reachability Preflight
echo "==> Step 1: Preflight cluster checks..."
if ! "${KUBECTL_BIN}" cluster-info --request-timeout=4s >/dev/null 2>&1; then
  echo "ERROR: Cluster is not reachable. Verify cluster is running: 'make up'" >&2
  exit 2
fi
echo "    ✓ Kind cluster 'kind-${CLUSTER_NAME}' is responsive."

# 2. Inspect In-Flight Working Tree
echo "==> Step 2: Inspecting in-flight changes..."
DIRTY_FILES=$(git status --porcelain || true)
CURRENT_HEAD=$(git rev-parse --short HEAD 2>/dev/null || echo "0000000")

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

# Helpers for Image Preflight & Flux Configuration Inspection
check_image_on_node() {
  local img="$1"
  # 1. Direct crictl inspecti inside the kind control plane node container
  if "${DOCKER_BIN}" exec "${CLUSTER_NAME}-control-plane" crictl inspecti "${img}" >/dev/null 2>&1; then
    return 0
  fi
  # 2. Direct host crictl if accessible
  if command -v crictl >/dev/null 2>&1; then
    if crictl inspecti "${img}" >/dev/null 2>&1; then
      return 0
    fi
  fi
  # 3. Fallback: parse crictl images table
  local listing
  listing="$("${DOCKER_BIN}" exec "${CLUSTER_NAME}-control-plane" crictl images 2>/dev/null || true)"
  if [[ -n "${listing}" ]]; then
    local canonical="${img}"
    if [[ "${img}" != *"/"* ]]; then
      canonical="docker.io/library/${img}"
    fi
    if echo "${listing}" | awk -v want="${canonical}" '$1":"$2 == want { found = 1 } END { exit !found }'; then
      return 0
    fi
    if echo "${listing}" | awk -v want="${img}" '$1":"$2 == want { found = 1 } END { exit !found }'; then
      return 0
    fi
  fi
  return 1
}

extract_deployment_images() {
  local target_dep="$1"
  local kustomize_dirs=(
    "d2-signalloom/apps/fe-signalloom/local"
    "d2-signalloom/infra/kagent/local"
  )
  for kd in "${kustomize_dirs[@]}"; do
    if [[ -d "$kd" ]]; then
      "${KUBECTL_BIN}" kustomize "$kd" 2>/dev/null | sed \
        -e "s|\${IMAGE_BASE}|${IMAGE_BASE:-zot.registry.svc.cluster.local:5000/acme/images}|g" \
        -e "s|\${ARTIFACT_TAG}|${ARTIFACT_TAG:-latest}|g" \
        -e "s|\${REGISTRY_BASE}|${REGISTRY_BASE:-zot.registry.svc.cluster.local:5000/acme}|g" | awk -v dep="$target_dep" '
        /^kind: Deployment$/ { in_deploy=1; deploy_name="" }
        in_deploy && /^  name: / && deploy_name=="" {
          deploy_name=$2
          gsub(/["'\'' ]/, "", deploy_name)
        }
        in_deploy && deploy_name == dep && /image: / {
          img=$NF
          gsub(/["'\'' ]/, "", img)
          if (img != "" && img !~ /^\$\{/) print img
        }
        /^---$/ { in_deploy=0 }
      '
    fi
  done
}

# Reuse scripts/lib/source-id.sh's derivation of "which files does this
# Dockerfile COPY" for auto-detecting warden and supercred-runner changes, so
# the detection glob cannot drift from the same COPY-source parsing that
# scripts/sentinel-image-tag.sh (warden) and scripts/supercred-images.sh
# (supercred-runner) already use for their own build-input/dirty-check sets.
# shellcheck source=scripts/lib/source-id.sh
source ./scripts/lib/source-id.sh

# The sentinel Dockerfile's build context is d2-signalloom/apps (see
# d2-signalloom/Makefile's swarm-stun-sentinel-image), so its COPY sources are
# context-relative and must be re-rooted at the repo root.
warden_input_paths() {
  local dockerfile="d2-signalloom/apps/signalloom-stun-sentinel/Dockerfile"
  [[ -f "${dockerfile}" ]] || return 0
  source_id_copied_paths "${dockerfile}" "signalloom-stun-sentinel/Dockerfile" | sed 's|^|d2-signalloom/apps/|'
}

# supercred-demo-runner's build context is the repo root (scripts/supercred-images.sh
# DEMO_IMAGES entry "supercred-demo-runner:local|.|..."), so its COPY sources
# are already repo-root-relative.
supercred_runner_input_paths() {
  local dockerfile="d2-signalloom/apps/supercred-demo-runner/Dockerfile"
  [[ -f "${dockerfile}" ]] || return 0
  source_id_copied_paths "${dockerfile}" "${dockerfile}"
}

# True if $1 is exactly one of the remaining args, or lives under one of them.
path_under_any() {
  local path="$1"
  shift
  local p
  for p in "$@"; do
    [[ -z "$p" ]] && continue
    if [[ "$path" == "$p" || "$path" == "$p"/* ]]; then
      return 0
    fi
  done
  return 1
}

# 3. Workload Detection
TARGET_DASHBOARD=false
TARGET_BACKEND=false
TARGET_DOCS=false
TARGET_INGEST=false
TARGET_MANIFESTS=false
TARGET_FLEET=false
TARGET_WARDEN=false
TARGET_SUPERCRED_RUNNER=false
DYNAMIC_APPS=()

if [[ "${WORKLOAD}" == "auto" ]]; then
  echo "==> Step 3: Auto-detecting affected workloads from git diff..."

  if [[ -n "${OVERRIDE_DIFF_PATHS:-}" ]]; then
    DIFF_PATHS="${OVERRIDE_DIFF_PATHS}"
  else
    DIFF_PATHS=""
    if git rev-parse --verify HEAD~1 >/dev/null 2>&1; then
      DIFF_PATHS="$(git diff --name-only HEAD~1 2>/dev/null || true)"
    fi
    DIFF_PATHS="${DIFF_PATHS}"$'\n'"$(git diff --name-only HEAD 2>/dev/null || true)"
    DIFF_PATHS="${DIFF_PATHS}"$'\n'"$(git diff --name-only --cached 2>/dev/null || true)"
    if [[ -n "${DIRTY_FILES}" ]]; then
      DIFF_PATHS="${DIFF_PATHS}"$'\n'"$(echo "${DIRTY_FILES}" | awk '{print $NF}')"
    fi
  fi

  DIFF_PATHS="$(echo "${DIFF_PATHS}" | sed '/^$/d' | sort -u || true)"

  mapfile -t WARDEN_INPUT_PATHS < <(warden_input_paths)
  mapfile -t RUNNER_INPUT_PATHS < <(supercred_runner_input_paths)

  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    if [[ "$path" =~ ^d2-signalloom/apps/([^/]+) ]]; then
      app="${BASH_REMATCH[1]}"
      case "$app" in
        dashboard-signalloom) TARGET_DASHBOARD=true ;;
        fe-signalloom)        TARGET_BACKEND=true ;;
        docs-signalloom)      TARGET_DOCS=true ;;
        signal-ingest)        TARGET_INGEST=true ;;
        # stun-sentinel, signalloom-stun-sentinel and supercred-demo-runner are
        # deliberately NOT named here: their TARGET_WARDEN/TARGET_SUPERCRED_RUNNER
        # assignment comes only from the Dockerfile-derived WARDEN_INPUT_PATHS/
        # RUNNER_INPUT_PATHS check below, via path_under_any -- a hand-written
        # app-name list here would be the second declaration of "what belongs to
        # this image" the SKILL's own reasoning (scripts/lib/source-id.sh) warns
        # against, and it would silently stop matching the day a COPY line moves.
        stun-sentinel|signalloom-stun-sentinel|supercred-demo-runner) ;;
        *)
          if [[ -d "d2-signalloom/apps/${app}" ]]; then
            DYNAMIC_APPS+=("${app}")
            TARGET_MANIFESTS=true
          fi
          ;;
      esac
    elif [[ "$path" =~ ^d2-signalloom/pkg/obscel ]]; then
      TARGET_INGEST=true
    elif [[ "$path" =~ ^d2-signalloom/infra/ ]]; then
      TARGET_MANIFESTS=true
    elif [[ "$path" =~ ^d2-osramp-fleet/ ]]; then
      TARGET_FLEET=true
    fi

    # Warden and supercred-runner build inputs span multiple top-level trees
    # (apps/, scripts/, infra/), derived straight from their Dockerfiles'
    # COPY lines (see warden_input_paths/supercred_runner_input_paths above),
    # so they are checked independently of the primary category above rather
    # than folded into the if/elif chain -- a single path (e.g. a
    # fe-signalloom/src edit) can affect more than one workload.
    if path_under_any "$path" "${WARDEN_INPUT_PATHS[@]}"; then
      TARGET_WARDEN=true
    fi
    if path_under_any "$path" "${RUNNER_INPUT_PATHS[@]}"; then
      TARGET_SUPERCRED_RUNNER=true
    fi
  done <<< "${DIFF_PATHS}"

  if [[ ${#DYNAMIC_APPS[@]} -gt 0 ]]; then
    mapfile -t DYNAMIC_APPS < <(printf '%s\n' "${DYNAMIC_APPS[@]}" | sort -u)
  fi

  # If nothing specific detected, default to dashboard
  if ! ${TARGET_DASHBOARD} && ! ${TARGET_BACKEND} && ! ${TARGET_DOCS} && ! ${TARGET_INGEST} && ! ${TARGET_MANIFESTS} \
     && ! ${TARGET_FLEET} && ! ${TARGET_WARDEN} && ! ${TARGET_SUPERCRED_RUNNER} && [[ ${#DYNAMIC_APPS[@]} -eq 0 ]]; then
    echo "    No specific workload edits detected; defaulting to dashboard."
    TARGET_DASHBOARD=true
  fi
else
  case "${WORKLOAD}" in
    dashboard) TARGET_DASHBOARD=true ;;
    backend)   TARGET_BACKEND=true ;;
    docs)      TARGET_DOCS=true ;;
    ingest|signal-ingest) TARGET_INGEST=true ;;
    fleet) TARGET_FLEET=true ;;
    warden|sentinel|signalloom-warden) TARGET_WARDEN=true ;;
    supercred-runner|supercred_runner|supercred-demo-runner) TARGET_SUPERCRED_RUNNER=true ;;
    manifests) TARGET_MANIFESTS=true ;;
    all)
      TARGET_DASHBOARD=true
      TARGET_BACKEND=true
      TARGET_DOCS=true
      TARGET_INGEST=true
      TARGET_MANIFESTS=true
      TARGET_FLEET=true
      TARGET_WARDEN=true
      TARGET_SUPERCRED_RUNNER=true
      ;;
    *)
      if [[ -d "d2-signalloom/apps/${WORKLOAD}" ]]; then
        DYNAMIC_APPS+=("${WORKLOAD}")
        TARGET_MANIFESTS=true
      else
        echo "ERROR: Unknown workload '${WORKLOAD}'." >&2
        exit 1
      fi
      ;;
  esac
fi

echo "    Targets selected:"
${TARGET_DASHBOARD} && echo "      - dashboard-signalloom (Frontend)"
${TARGET_BACKEND}   && echo "      - fe-signalloom (FastAPI Backend / Migrations)"
${TARGET_DOCS}      && echo "      - docs-signalloom (Documentation Portal)"
${TARGET_INGEST}    && echo "      - signal-ingest (Signal Fusion Ingest Service)"
${TARGET_WARDEN}    && echo "      - signalloom-warden (Sentinel DaemonSet)"
${TARGET_SUPERCRED_RUNNER} && echo "      - supercred-demo-runner (Demo Runner Image)"
for dapp in "${DYNAMIC_APPS[@]:-}"; do
  [[ -n "$dapp" ]] && echo "      - ${dapp} (Discovered App)"
done
${TARGET_MANIFESTS} && echo "      - manifests / Kustomizations"
${TARGET_FLEET}     && echo "      - fleet (d2-osramp-fleet ResourceSets)"

if [[ "${DRY_RUN}" == "true" ]]; then
  echo ""
  echo "==> [DRY RUN] Current deployed staleness report:"
  "${CHECK_STALENESS_BIN}" || true
  echo ""
  echo "==> [DRY RUN] Plan complete. Exiting without modifications."
  exit 0
fi

# 4. Kustomization Tag Synchronization & Deployment Pinning
if [[ "${FORCE_SYNC_KUSTOMIZE}" == "true" ]]; then
  echo "==> Step 4: Synchronizing local Kustomization image patches and deployment pins..."

  if [[ ("${TARGET_DASHBOARD}" == "true" || "${TARGET_MANIFESTS}" == "true") && -f "d2-signalloom/apps/fe-signalloom/local/kustomization.yaml" ]]; then
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

  if [[ "${TARGET_INGEST}" == "true" ]]; then
    echo "    Synchronizing signal-ingest deployment pin..."
    INGEST_TAG_OUTPUT=""
    if ! INGEST_TAG_OUTPUT="$("${SIGNAL_INGEST_TAG_BIN}" 2>&1)"; then
      echo "ERROR: signal-ingest refused to generate image tag due to uncommitted changes in inputs:" >&2
      echo "${INGEST_TAG_OUTPUT}" >&2
      echo "" >&2
      echo "signal-ingest requires a clean source tree to generate an immutable image tag." >&2
      echo "Please commit your changes ('git commit' or 'local-deploy.sh -c \"...\"') or re-run with '--auto-commit'." >&2
      exit 1
    fi
    INGEST_TAG="${INGEST_TAG_OUTPUT}"
    "${MAKE_BIN}" -C d2-signalloom signal-ingest-image-pin
    echo "    ✓ signal-ingest deployment pinned to :${INGEST_TAG}."
  fi
fi

# 5. Workload Builds & Image Publishing
echo "==> Step 5: Building and loading workload image(s)..."

if [[ "${TARGET_DASHBOARD}" == "true" ]]; then
  echo "    Building dashboard-signalloom..."
  "${BUILD_DASHBOARD_BIN}"
  # Also tag with source fingerprint for exact kustomization matching
  source ./scripts/lib/source-id.sh
  DASH_SRC_ID="$(source_id_for dashboard-signalloom)"
  DASH_SHORT_TAG="src-${DASH_SRC_ID:0:16}"
  "${DOCKER_BIN}" tag "zot.registry.svc.cluster.local:5000/acme/images/signalloom/apps/dashboard-signalloom:latest" \
    "zot.registry.svc.cluster.local:5000/acme/images/signalloom/apps/dashboard-signalloom:${DASH_SHORT_TAG}" || true
  "${KIND_BIN:-kind}" load docker-image --name "${CLUSTER_NAME}" \
    "zot.registry.svc.cluster.local:5000/acme/images/signalloom/apps/dashboard-signalloom:${DASH_SHORT_TAG}" || true
  echo "    ✓ dashboard-signalloom built and loaded into Kind (${DASH_SHORT_TAG})."
fi

if [[ "${TARGET_BACKEND}" == "true" ]]; then
  echo "    Building fe-signalloom backend..."
  source ./scripts/lib/source-id.sh
  mapfile -t FE_BUILD_ARGS < <(source_id_build_args fe-signalloom)
  "${DOCKER_BIN}" build "${FE_BUILD_ARGS[@]}" -t zot.registry.svc.cluster.local:5000/acme/images/signalloom/apps/fe-signalloom:latest d2-signalloom/apps/fe-signalloom
  CLUSTER_NAME="${CLUSTER_NAME}" "${KIND_LOAD_VERIFIED_BIN}" zot.registry.svc.cluster.local:5000/acme/images/signalloom/apps/fe-signalloom:latest
  echo "    ✓ fe-signalloom built and verified on Kind node."
fi

if [[ "${TARGET_DOCS}" == "true" ]]; then
  echo "    Building docs-signalloom..."
  "${BUILD_DOCS_BIN}"
  echo "    ✓ docs-signalloom built and loaded."
fi

if [[ "${TARGET_INGEST}" == "true" ]]; then
  if [[ -z "${INGEST_TAG:-}" ]]; then
    INGEST_TAG_OUTPUT=""
    if ! INGEST_TAG_OUTPUT="$("${SIGNAL_INGEST_TAG_BIN}" 2>&1)"; then
      echo "ERROR: signal-ingest refused to generate image tag due to uncommitted changes in inputs:" >&2
      echo "${INGEST_TAG_OUTPUT}" >&2
      echo "" >&2
      echo "signal-ingest requires a clean source tree to generate an immutable image tag." >&2
      echo "Please commit your changes ('git commit' or 'local-deploy.sh -c \"...\"') or re-run with '--auto-commit'." >&2
      exit 1
    fi
    INGEST_TAG="${INGEST_TAG_OUTPUT}"
  fi
  echo "    Building and publishing signal-ingest..."
  if ! "${MAKE_BIN}" -C d2-signalloom signal-ingest-image-publish CLUSTER_NAME="${CLUSTER_NAME}"; then
    echo "ERROR: Failed to build and publish signal-ingest image." >&2
    exit 1
  fi
  echo "    ✓ signal-ingest built, verified on Kind, and published to Zot."
fi

if [[ "${TARGET_WARDEN}" == "true" ]]; then
  echo "    Building and publishing signalloom-warden (sentinel)..."
  if ! "${MAKE_BIN}" -C d2-signalloom sentinel-image-publish CLUSTER_NAME="${CLUSTER_NAME}"; then
    echo "ERROR: Failed to build and publish signalloom-warden (sentinel) image." >&2
    exit 1
  fi
  echo "    ✓ signalloom-warden built, verified on Kind, and published to Zot."
fi

if [[ "${TARGET_SUPERCRED_RUNNER}" == "true" ]]; then
  echo "    Building and loading supercred-demo-runner..."
  if ! "${MAKE_BIN}" demo-signalloom-supercred-runner-image CLUSTER_NAME="${CLUSTER_NAME}"; then
    echo "ERROR: Failed to build and load supercred-demo-runner image." >&2
    exit 1
  fi
  echo "    ✓ supercred-demo-runner built and verified on Kind."
fi

# 6. GitOps Reconciliation (Push OCI Artifact & Reconcile Flux)
if [[ "${SKIP_RECONCILE}" == "false" ]]; then
  echo "==> Step 6: Pushing OCI manifests and reconciling Flux..."
  "${PUSH_LOCAL_BIN}" signalloom

  if command -v "${FLUX_BIN}" >/dev/null 2>&1; then
    echo "    Reconciling Flux OCI source 'fe-signalloom'..."
    "${FLUX_BIN}" reconcile source oci fe-signalloom -n fe-signalloom || true
    echo "    Reconciling Flux Kustomization 'apps'..."
    "${FLUX_BIN}" reconcile kustomization apps -n fe-signalloom || true
  fi

  if [[ "${TARGET_FLEET}" == "true" ]]; then
    echo "    Pushing fleet artifact (d2-osramp-fleet)..."
    "${PUSH_LOCAL_BIN}" fleet
    if command -v "${FLUX_BIN}" >/dev/null 2>&1; then
      echo "    Reconciling Flux Kustomization 'tenants'..."
      "${FLUX_BIN}" reconcile kustomization tenants -n flux-system --with-source || true
    fi
    echo "    ✓ fleet pushed and tenants Kustomization reconciled."
  fi
else
  echo "==> Step 6: Skipping Flux reconciliation (--no-reconcile specified)."
fi

# 7. Node CRI Image Preflight Check & Deployment Rollout
echo "==> Step 7: Preflight CRI image verification on Kind node..."

TARGET_DEPLOYMENTS=()
if [[ "${TARGET_DASHBOARD}" == "true" ]]; then
  TARGET_DEPLOYMENTS+=("dashboard-signalloom")
fi
if [[ "${TARGET_BACKEND}" == "true" ]]; then
  TARGET_DEPLOYMENTS+=("fe-signalloom")
fi
if [[ "${TARGET_DOCS}" == "true" ]]; then
  TARGET_DEPLOYMENTS+=("docs-signalloom")
fi
if [[ "${TARGET_INGEST}" == "true" ]]; then
  TARGET_DEPLOYMENTS+=("signal-ingest")
fi
if [[ "${TARGET_SUPERCRED_RUNNER}" == "true" ]]; then
  TARGET_DEPLOYMENTS+=("supercred-demo-runner")
fi
for dapp in "${DYNAMIC_APPS[@]:-}"; do
  [[ -n "$dapp" ]] && TARGET_DEPLOYMENTS+=("$dapp")
done

ALL_IMAGES_TO_VERIFY=()
for dep in "${TARGET_DEPLOYMENTS[@]}"; do
  dep_images=()
  while IFS= read -r img; do
    [[ -n "$img" ]] && dep_images+=("$img")
  done < <(extract_deployment_images "$dep")

  if [[ ${#dep_images[@]} -eq 0 ]]; then
    case "$dep" in
      dashboard-signalloom)
        source ./scripts/lib/source-id.sh
        dash_id="$(source_id_for dashboard-signalloom)"
        dep_images+=("zot.registry.svc.cluster.local:5000/acme/images/signalloom/apps/dashboard-signalloom:src-${dash_id:0:16}")
        ;;
      fe-signalloom)
        dep_images+=("zot.registry.svc.cluster.local:5000/acme/images/signalloom/apps/fe-signalloom:latest")
        ;;
      docs-signalloom)
        dep_images+=("zot.registry.svc.cluster.local:5000/acme/images/signalloom/apps/docs-signalloom:latest")
        ;;
      signal-ingest)
        tag="${INGEST_TAG:-}"
        if [[ -z "$tag" && -f "d2-signalloom/apps/signal-ingest/base/deployment.yaml" ]]; then
          tag="$(grep -o "signal-ingest:src-[0-9a-f]*" d2-signalloom/apps/signal-ingest/base/deployment.yaml | cut -d: -f2 || true)"
        fi
        tag="${tag:-latest}"
        dep_images+=("zot.registry.svc.cluster.local:5000/acme/images/signalloom/apps/signal-ingest:${tag}")
        ;;
      supercred-demo-runner)
        dep_images+=("supercred-demo-runner:local")
        ;;
      *)
        if [[ -f "d2-signalloom/apps/${dep}/base/deployment.yaml" ]]; then
          while IFS= read -r raw_img; do
            [[ -n "$raw_img" ]] && dep_images+=("$raw_img")
          done < <(grep "image:" "d2-signalloom/apps/${dep}/base/deployment.yaml" | awk '{img=$NF; gsub(/["'\'' ]/, "", img); if (img !~ /^\$\{/) print img}')
        fi
        ;;
    esac
  fi

  for img in "${dep_images[@]}"; do
    ALL_IMAGES_TO_VERIFY+=("$img")
  done
done

# Dedup images to verify
if [[ ${#ALL_IMAGES_TO_VERIFY[@]} -gt 0 ]]; then
  mapfile -t UNIQUE_IMAGES < <(printf '%s\n' "${ALL_IMAGES_TO_VERIFY[@]}" | sort -u)
else
  UNIQUE_IMAGES=()
fi

for img in "${UNIQUE_IMAGES[@]}"; do
  echo "    Verifying image presence on Kind node: ${img}..."
  if ! check_image_on_node "${img}"; then
    echo "ERROR: Image '${img}' is missing from cluster node. Build and load it first." >&2
    exit 1
  fi
  echo "    ✓ Image verified on node: ${img}"
done

echo "    ✓ All required images verified on Kind node."

echo "==> Rolling out deployments..."
if [[ "${TARGET_DASHBOARD}" == "true" ]]; then
  "${KUBECTL_BIN}" -n fe-signalloom rollout restart deployment/dashboard-signalloom
  "${KUBECTL_BIN}" -n fe-signalloom rollout status deployment/dashboard-signalloom --timeout=180s
fi

if [[ "${TARGET_BACKEND}" == "true" ]]; then
  "${KUBECTL_BIN}" -n fe-signalloom rollout restart deployment/fe-signalloom
  "${KUBECTL_BIN}" -n fe-signalloom rollout status deployment/fe-signalloom --timeout=180s
fi

if [[ "${TARGET_DOCS}" == "true" ]]; then
  "${KUBECTL_BIN}" -n fe-signalloom rollout restart deployment/docs-signalloom
  "${KUBECTL_BIN}" -n fe-signalloom rollout status deployment/docs-signalloom --timeout=180s
fi

if [[ "${TARGET_INGEST}" == "true" ]]; then
  "${KUBECTL_BIN}" -n fe-signalloom rollout restart deployment/signal-ingest
  "${KUBECTL_BIN}" -n fe-signalloom rollout status deployment/signal-ingest --timeout=180s
fi

if [[ "${TARGET_SUPERCRED_RUNNER}" == "true" ]]; then
  "${KUBECTL_BIN}" -n fe-signalloom rollout restart deployment/supercred-demo-runner
  "${KUBECTL_BIN}" -n fe-signalloom rollout status deployment/supercred-demo-runner --timeout=180s
fi

if [[ "${TARGET_WARDEN}" == "true" ]]; then
  "${KUBECTL_BIN}" -n inf-signalloom-warden rollout restart daemonset/signalloom-warden
  "${KUBECTL_BIN}" -n inf-signalloom-warden rollout status daemonset/signalloom-warden --timeout=180s
fi

for dapp in "${DYNAMIC_APPS[@]:-}"; do
  [[ -z "$dapp" ]] && continue
  if "${KUBECTL_BIN}" -n fe-signalloom get deployment/"$dapp" >/dev/null 2>&1; then
    echo "    Rolling out deployment/${dapp}..."
    "${KUBECTL_BIN}" -n fe-signalloom rollout restart deployment/"$dapp"
    "${KUBECTL_BIN}" -n fe-signalloom rollout status deployment/"$dapp" --timeout=180s
  fi
done

# 8. Port-Forward Healing & Ingress Verification
echo "==> Step 8: Verifying ingress and port-forwards..."
PORT_OK=false
for i in {1..10}; do
  if "${CURL_BIN:-curl}" -fsS http://127.0.0.1:19080/ >/dev/null 2>&1; then
    PORT_OK=true
    break
  fi
  sleep 1
done

if [[ "${PORT_OK}" == "false" ]]; then
  echo "    Port-forward on 19080 severed or unresponsive; resuming supervisor..."
  setsid "${KUBECTL_BIN}" -n fe-signalloom port-forward svc/dashboard-signalloom 19080:8080 --address 0.0.0.0 </dev/null >/dev/null 2>&1 & disown || true
  sleep 2
fi

# 9. Conclusive Staleness & Evidence Verification
echo "==> Step 9: Running deployed staleness proof..."
STALENESS_RC=0
"${CHECK_STALENESS_BIN}" || STALENESS_RC=$?

if [[ ${STALENESS_RC} -ne 0 ]]; then
  echo "ERROR: Deployed staleness proof failed with exit code ${STALENESS_RC}." >&2
  echo "       Cluster workloads are not running the current working tree." >&2
  exit "${STALENESS_RC}"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Deployment Complete!                                          "
echo "  URL: http://127.0.0.1:19080/                                  "
if [[ -f .tunnel/url ]]; then
  echo "  Tailscale: $(cat .tunnel/url)"
fi
echo "═══════════════════════════════════════════════════════════════"
