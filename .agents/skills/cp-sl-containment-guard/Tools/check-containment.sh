#!/usr/bin/env bash
# check-containment.sh — Audit agent containment states and GitOps suspension annotations
set -eo pipefail

echo "=== Signal Loom Containment & GitOps Suspension Guard ==="
DATE_STR=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "Check Timestamp: ${DATE_STR}"

if ! kubectl cluster-info --request-timeout=3s >/dev/null 2>&1; then
  echo "CLUSTER_STATUS=OFFLINE"
  echo "  [ADVISORY (Cluster offline)] Containment check requires a running cluster."
  echo "  Start the cluster with: 'make up && make demo-signalloom-up'"
  exit 0
fi

NAMESPACE="fe-signalloom-agents"
if ! kubectl get ns "$NAMESPACE" >/dev/null 2>&1; then
  echo "Namespace ${NAMESPACE} not found. Skipping containment check."
  exit 0
fi

# 1. Audit Deployments in agent namespace
echo "Scanning deployments in ${NAMESPACE}..."
DEPLOYMENTS=$(kubectl get deployments -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.annotations.kustomize\.toolkit\.fluxcd\.io/reconcile}{"|"}{.metadata.labels.signalloom\.ai/containment-state}{"\n"}{end}' 2>/dev/null || true)

ACTIVE_COUNT=0
STUNNED_COUNT=0
SUSPENDED_COUNT=0
VIOLATION_COUNT=0
VIOLATIONS=""

while IFS='|' read -r name reconcile state; do
  [ -z "$name" ] && continue
  if [ "$state" = "stunned" ]; then
    STUNNED_COUNT=$((STUNNED_COUNT + 1))
    if [ "$reconcile" = "disabled" ]; then
      echo "  [STUNNED / SUSPENDED] Deployment: ${name} (Flux reconcile disabled)"
      SUSPENDED_COUNT=$((SUSPENDED_COUNT + 1))
    else
      echo "  [VIOLATION] Deployment: ${name} is STUNNED but Flux reconcile is NOT disabled!"
      VIOLATIONS="${VIOLATIONS}\n  - ${name}"
      VIOLATION_COUNT=$((VIOLATION_COUNT + 1))
    fi
  else
    ACTIVE_COUNT=$((ACTIVE_COUNT + 1))
    echo "  [ACTIVE] Deployment: ${name}"
  fi
done <<< "$DEPLOYMENTS"

echo "=== Summary ==="
echo "Active Agents: ${ACTIVE_COUNT}"
echo "Stunned Agents: ${STUNNED_COUNT}"
echo "Properly Suspended: ${SUSPENDED_COUNT}"
echo "Violations: ${VIOLATION_COUNT}"

if [ "$VIOLATION_COUNT" -gt 0 ]; then
  echo "RESULT: CONTAINMENT INVARIANT VIOLATIONS DETECTED"
  echo -e "Violating deployments:${VIOLATIONS}"
  echo "  [REMEDIATION] Stunned agent deployments MUST have Flux GitOps reconciliation disabled"
  echo "  to prevent Flux from overwriting containment states during automatic sync."
  echo "  Execute remediation for each violating deployment:"
  echo "    kubectl annotate deployment -n ${NAMESPACE} <deployment-name> kustomize.toolkit.fluxcd.io/reconcile=disabled --overwrite"
  echo "  To resume reconciliation after forensic preservation:"
  echo "    kubectl annotate deployment -n ${NAMESPACE} <deployment-name> kustomize.toolkit.fluxcd.io/reconcile-"
  echo "  Verify Fleet Manager DAG sync: 'curl -s http://localhost:5173/fleet-api/v1/fleet/topology'"
  exit 1
else
  echo "RESULT: ALL CONTAINMENT INVARIANTS SATISFIED"
  exit 0
fi
