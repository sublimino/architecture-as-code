#!/usr/bin/env bash
# scripts/kagent-agents.sh — Kagent Declarative Agents Lifecycle (Demo 5)
# Deploys all 5 Kagent agent types to fe-signalloom-agents.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/wait.sh
source "${REPO_ROOT}/scripts/lib/wait.sh"

KUBECONFIG_PATH="${KUBECONFIG:-${REPO_ROOT}/.kind/kubeconfig}"
if [ -f "${KUBECONFIG_PATH}" ]; then
  export KUBECONFIG="${KUBECONFIG_PATH}"
fi

AGENTS_NS="fe-signalloom-agents"
ACTION="${1:-deploy}"

case "${ACTION}" in
  deploy)
    echo "==> Ensuring target agents namespace '${AGENTS_NS}' exists..."
    kubectl create namespace "${AGENTS_NS}" --dry-run=client -o yaml | kubectl apply -f -

    # The swarm's RemoteMCPServer, BEFORE any agent that references it.
    #
    # Ordering is the point. Every Agent CR below names kagent-tool-server, and
    # an agent applied before it exists compiles to
    # `RemoteMCPServer.kagent.dev "kagent-tool-server" not found` and reports
    # Accepted=False. The controller does re-reconcile, so this is eventually
    # self-correcting — which is exactly why it needs to be ordered rather than
    # left to luck: a transient Accepted=False on a fresh cluster is
    # indistinguishable at a glance from the permanent one this replaced, and
    # that ambiguity is what cost this repo a working demo for a fortnight.
    echo "==> Applying shared agent-swarm prerequisites (namespace, RBAC, tool server)..."
    kubectl apply -k "${REPO_ROOT}/d2-signalloom/infra/agent-swarm"
    wait_k8s_exists remotemcpserver kagent-tool-server -n "${AGENTS_NS}" 60

    echo "==> Deploying Agent 1: K8s Resource Reader Agent..."
    kubectl apply -k "${REPO_ROOT}/d2-signalloom/infra/agent-swarm/kagent-k8s-reader"
    wait_k8s_exists agent kagent-k8s-reader -n "${AGENTS_NS}" 30

    echo "==> Deploying Agent 2: Commit Summariser Agent..."
    kubectl apply -k "${REPO_ROOT}/d2-signalloom/infra/agent-swarm/kagent-commit-summariser"
    wait_k8s_exists agent kagent-commit-summariser -n "${AGENTS_NS}" 30

    echo "==> Deploying Agent 3: Security Analyst Agent..."
    kubectl apply -k "${REPO_ROOT}/d2-signalloom/infra/agent-swarm/kagent-security-analyst"
    wait_k8s_exists agent kagent-security-analyst -n "${AGENTS_NS}" 30

    echo "==> Deploying Agent 4: Network Auditor Agent..."
    kubectl apply -k "${REPO_ROOT}/d2-signalloom/infra/agent-swarm/kagent-network-auditor"
    wait_k8s_exists agent kagent-network-auditor -n "${AGENTS_NS}" 30

    echo "==> Deploying Agent 5: Incident Responder Agent..."
    kubectl apply -k "${REPO_ROOT}/d2-signalloom/infra/agent-swarm/kagent-incident-responder"
    wait_k8s_exists agent kagent-incident-responder -n "${AGENTS_NS}" 30

    echo "==> Deploying Agent 6: Compliance Checker Agent..."
    kubectl apply -k "${REPO_ROOT}/d2-signalloom/infra/agent-swarm/kagent-compliance-checker"
    wait_k8s_exists agent kagent-compliance-checker -n "${AGENTS_NS}" 30

    echo "==> Deploying Agent 7: FinOps Optimizer Agent..."
    kubectl apply -k "${REPO_ROOT}/d2-signalloom/infra/agent-swarm/kagent-finops-optimizer"
    wait_k8s_exists agent kagent-finops-optimizer -n "${AGENTS_NS}" 30

    echo "==> Deploying Agent 8: Chaos Prober Agent..."
    kubectl apply -k "${REPO_ROOT}/d2-signalloom/infra/agent-swarm/kagent-chaos-prober"
    wait_k8s_exists agent kagent-chaos-prober -n "${AGENTS_NS}" 30

    echo "==> All 8 Kagent agents deployed to namespace '${AGENTS_NS}':"
    kubectl get agents,modelconfigs,remotemcpservers -n "${AGENTS_NS}"
    ;;

  destroy)
    echo "==> Removing Kagent agents from namespace '${AGENTS_NS}'..."
    kubectl delete -k "${REPO_ROOT}/d2-signalloom/infra/agent-swarm/kagent-chaos-prober" --ignore-not-found --timeout=30s || true
    kubectl delete -k "${REPO_ROOT}/d2-signalloom/infra/agent-swarm/kagent-finops-optimizer" --ignore-not-found --timeout=30s || true
    kubectl delete -k "${REPO_ROOT}/d2-signalloom/infra/agent-swarm/kagent-compliance-checker" --ignore-not-found --timeout=30s || true
    kubectl delete -k "${REPO_ROOT}/d2-signalloom/infra/agent-swarm/kagent-incident-responder" --ignore-not-found --timeout=30s || true
    kubectl delete -k "${REPO_ROOT}/d2-signalloom/infra/agent-swarm/kagent-network-auditor" --ignore-not-found --timeout=30s || true
    kubectl delete -k "${REPO_ROOT}/d2-signalloom/infra/agent-swarm/kagent-security-analyst" --ignore-not-found --timeout=30s || true
    kubectl delete -k "${REPO_ROOT}/d2-signalloom/infra/agent-swarm/kagent-commit-summariser" --ignore-not-found --timeout=30s || true
    kubectl delete -k "${REPO_ROOT}/d2-signalloom/infra/agent-swarm/kagent-k8s-reader" --ignore-not-found --timeout=30s || true
    echo "==> Kagent agents removed."
    ;;

  status)
    echo "=== Kagent Agents Status in ${AGENTS_NS} ==="
    if kubectl get namespace "${AGENTS_NS}" >/dev/null 2>&1; then
      kubectl get agents,modelconfigs,remotemcpservers -n "${AGENTS_NS}" || true
    else
      echo "Namespace '${AGENTS_NS}' does not exist."
    fi
    ;;

  *)
    echo "Usage: $0 [deploy|destroy|status]" >&2
    exit 1
    ;;
esac
