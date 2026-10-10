#!/usr/bin/env bash
ZSH_VERSION=${ZSH_VERSION:-}
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MANIFEST_DIR="$SCRIPT_DIR/manifests"
NAMESPACE="${NAMESPACE:-fe-signalloom-agents}"
export KUBECONFIG="${KUBECONFIG:-/tmp/osramp-kubeconfig.yaml}"

usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [options]

Signal Loom Generative Adversarial Hostile Agent Suite

Commands:
  generate          Generate all 5 hostile agent vectors and compliant baseline manifests
  up                Deploy hostile agent manifests to fe-signalloom-agents namespace
  down              Delete hostile agent pods from fe-signalloom-agents namespace
  list              List hostile agent pods and their status in fe-signalloom-agents
  evaluate          Evaluate generated vectors against CEL policies (asserting FAIL on all 5)
  test-admission    Run admission webhook guard verification against hostile vectors
  test              Execute complete end-to-end proof: generate, admission test, evaluate, up, list, down
  help              Display this help message

Options:
  NAMESPACE         Target Kubernetes namespace (default: fe-signalloom-agents)
  KUBECONFIG        Kubeconfig path (default: /tmp/osramp-kubeconfig.yaml)

Examples:
  ./scripts/hostile-agents/hostile-agents.sh generate
  ./scripts/hostile-agents/hostile-agents.sh evaluate
  ./scripts/hostile-agents/hostile-agents.sh up
  ./scripts/hostile-agents/hostile-agents.sh list
  ./scripts/hostile-agents/hostile-agents.sh down
  ./scripts/hostile-agents/hostile-agents.sh test
EOF
}

cmd_generate() {
  echo "=== Generating Hostile Agent Suite Manifests ==="
  python3 "$SCRIPT_DIR/generate_hostile_agents.py" \
    --out-dir "$MANIFEST_DIR" \
    --namespace "$NAMESPACE"
  echo "✓ Manifests generated in $MANIFEST_DIR"
}

cmd_up() {
  echo "=== Deploying Hostile Agents to Namespace '$NAMESPACE' ==="
  if [ ! -f "$MANIFEST_DIR/all-hostile-agents.yaml" ]; then
    cmd_generate
  fi

  if ! kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
    echo "Creating namespace $NAMESPACE..."
    kubectl create namespace "$NAMESPACE"
  fi

  echo "Applying manifests..."
  kubectl apply -f "$MANIFEST_DIR/all-hostile-agents.yaml" -n "$NAMESPACE"
  echo "✓ Hostile agent pods applied to $NAMESPACE"
}

cmd_down() {
  echo "=== Tearing Down Hostile Agents in Namespace '$NAMESPACE' ==="
  if [ -f "$MANIFEST_DIR/all-hostile-agents.yaml" ]; then
    kubectl delete -f "$MANIFEST_DIR/all-hostile-agents.yaml" -n "$NAMESPACE" --ignore-not-found=true --wait=false || true
  fi
  kubectl delete pods -n "$NAMESPACE" -l app.kubernetes.io/managed-by=hostile-agents-suite --ignore-not-found=true --wait=false || true
  echo "✓ Hostile agent pods deleted"
}

cmd_list() {
  echo "=== Hostile Agent Pods in '$NAMESPACE' ==="
  kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/managed-by=hostile-agents-suite -o wide || true
  echo ""
  echo "=== Compliant Baseline Pods in '$NAMESPACE' ==="
  kubectl get pods -n "$NAMESPACE" -l signalloom.ai/agent-name=compliant-baseline -o wide || true
}

cmd_evaluate() {
  echo "=== Evaluating Hostile Agents against CEL Policies ==="
  python3 "$SCRIPT_DIR/generate_hostile_agents.py" --evaluate
}

cmd_test_admission() {
  echo "=== Running Admission Webhook Guard Test ==="
  "$REPO_ROOT/scripts/test-admission-guard.sh"
}

cmd_test() {
  echo "=================================================================="
  echo "  Signal Loom Hostile Agent & CEL Admission Proof Suite"
  echo "=================================================================="

  echo -e "\n[Step 1/6] Generating hostile agent manifests..."
  cmd_generate

  echo -e "\n[Step 2/6] Verifying Admission Webhook Guard (403 Rejections)..."
  cmd_test_admission

  echo -e "\n[Step 3/6] Evaluating CEL Policies (100% Hostile Detection Rate)..."
  cmd_evaluate

  echo -e "\n[Step 4/6] Deploying Hostile Agents to cluster namespace '$NAMESPACE'..."
  cmd_up

  echo -e "\n[Step 5/6] Listing active hostile agent workloads in cluster..."
  sleep 2
  cmd_list

  echo -e "\n[Step 6/6] Cleaning up hostile agent workloads..."
  cmd_down

  echo -e "\n=================================================================="
  echo "✓ ALL PROOFS PASSED: Hostile Agent Suite verified end-to-end."
  echo "=================================================================="
}

main() {
  local cmd="${1:-help}"
  shift || true

  case "$cmd" in
    generate)
      cmd_generate "$@"
      ;;
    up)
      cmd_up "$@"
      ;;
    down)
      cmd_down "$@"
      ;;
    list)
      cmd_list "$@"
      ;;
    evaluate)
      cmd_evaluate "$@"
      ;;
    test-admission|admission)
      cmd_test_admission "$@"
      ;;
    test|e2e)
      cmd_test "$@"
      ;;
    help|--help|-h)
      usage
      ;;
    *)
      echo "Unknown command: $cmd" >&2
      usage
      exit 2
      ;;
  esac
}

main "$@"
