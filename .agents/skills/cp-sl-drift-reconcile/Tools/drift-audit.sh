#!/usr/bin/env bash
# drift-audit.sh — Automated GitOps & Cluster Drift Auditor for Signal Loom
set -eo pipefail

echo "=== Signal Loom GitOps Drift Audit ==="
DATE_STR=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "Audit Timestamp: ${DATE_STR}"
FAIL_COUNT=0

# 1. Static Git & Patch Index Audit (always runs offline or online)
REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")}"
if [ -n "$REPO_ROOT" ] && [ -f "${REPO_ROOT}/d2-signalloom/test/fleet-patch-indexes.bats" ]; then
  echo "Running fleet-patch-indexes.bats..."
  if bats "${REPO_ROOT}/d2-signalloom/test/fleet-patch-indexes.bats" >/dev/null 2>&1; then
    echo "PATCH_INDEX_INTEGRITY=PASS"
  else
    echo "PATCH_INDEX_INTEGRITY=FAIL"
    echo "  [REMEDIATION] Kustomize JSON6902 patch index drift detected in d2-osramp-fleet/tenants/local/kustomization.yaml."
    echo "  Run: bats d2-signalloom/test/fleet-patch-indexes.bats"
    echo "  Ensure patch indices (/spec/resources/N/spec/verify) target OCIRepositories."
    echo "  Do NOT insert resources before existing indexed patches; append new items to the end."
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
else
  echo "PATCH_INDEX_INTEGRITY=SKIPPED (repo root or test file not found)"
fi

# 2. Cluster connectivity check
if ! kubectl cluster-info --request-timeout=4s >/dev/null 2>&1; then
  echo "CLUSTER_STATUS=OFFLINE"
  echo "Reason: Cannot connect to Kubernetes API server"
  echo "  [ADVISORY (Cluster offline)] To run cluster drift audits, bring up the cluster:"
  echo "  make up && make demo-signalloom-up"
  echo "=== Audit Completed (Static Only) ==="
  if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
  fi
  exit 0
fi
echo "CLUSTER_STATUS=ONLINE"

# 3. Flux Kustomization status
FLUX_KUST=$(kubectl get kustomization -n flux-system -o json 2>/dev/null || true)
if [ -z "$FLUX_KUST" ]; then
  echo "FLUX_STATUS=NOT_FOUND"
  echo "  [REMEDIATION] Flux Kustomizations not found in namespace flux-system."
  echo "  Verify Flux Operator installation: 'kubectl get pods -n flux-system'"
  echo "  Re-bootstrap Flux control plane: 'make up'"
  FAIL_COUNT=$((FAIL_COUNT + 1))
else
  READY_COUNT=$(echo "$FLUX_KUST" | jq -r '[.items[] | select(.status.conditions[]? | select(.type=="Ready" and .status=="True"))] | length' 2>/dev/null || echo "0")
  TOTAL_COUNT=$(echo "$FLUX_KUST" | jq -r '.items | length' 2>/dev/null || echo "0")
  echo "FLUX_KUSTOMIZATIONS_READY=${READY_COUNT}/${TOTAL_COUNT}"
  
  # Check for error conditions
  FAILURES=$(echo "$FLUX_KUST" | jq -r '.items[] | select(.status.conditions[]? | select(.type=="Ready" and .status=="False")) | .metadata.name + ": " + (.status.conditions[] | select(.type=="Ready") | .message)' 2>/dev/null || true)
  if [ -n "$FAILURES" ]; then
    echo "FLUX_FAILURES_DETECTED=YES"
    echo "$FAILURES"
    echo "  [REMEDIATION] Flux Kustomization reconciliation failure detected."
    echo "  Inspect controllers: 'flux get kustomizations -n flux-system'"
    echo "  Inspect error logs: 'flux logs --level=error -n flux-system'"
    echo "  Force reconciliation with git source:"
    echo "    flux reconcile kustomization tenants -n flux-system --with-source"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  else
    echo "FLUX_FAILURES_DETECTED=NO"
  fi
fi

# 4. Scan for unresolved ${VAR} tokens in applied Signal Loom deployments
UNRESOLVED_COUNT=0
UNRESOLVED_DETAILS=""
for ns in fe-signalloom inf-signalloom; do
  if kubectl get ns "$ns" >/dev/null 2>&1; then
    MATCHES=$(kubectl get deployments,services,configmaps -n "$ns" -o yaml 2>/dev/null | grep -E '\$\{[A-Za-z0-9_]+\}' || true)
    if [ -n "$MATCHES" ]; then
      LINE_COUNT=$(echo "$MATCHES" | wc -l)
      UNRESOLVED_COUNT=$((UNRESOLVED_COUNT + LINE_COUNT))
      UNRESOLVED_DETAILS="${UNRESOLVED_DETAILS}\nNamespace $ns has unresolved variables:\n${MATCHES}"
    fi
  fi
done

if kubectl get ns inf-bao >/dev/null 2>&1; then
  MATCHES=$(kubectl get deployments,services -n inf-bao -o yaml 2>/dev/null | grep -E '\$\{[A-Za-z0-9_]+\}' || true)
  if [ -n "$MATCHES" ]; then
    LINE_COUNT=$(echo "$MATCHES" | wc -l)
    UNRESOLVED_COUNT=$((UNRESOLVED_COUNT + LINE_COUNT))
    UNRESOLVED_DETAILS="${UNRESOLVED_DETAILS}\nNamespace inf-bao has unresolved variables in deployments/services:\n${MATCHES}"
  fi
fi

echo "UNRESOLVED_VARIABLE_TOKENS=${UNRESOLVED_COUNT}"
if [ "$UNRESOLVED_COUNT" -gt 0 ]; then
  echo -e "$UNRESOLVED_DETAILS"
  echo "  [REMEDIATION] Unresolved \${VAR} expressions found in applied cluster objects."
  echo "  1. Check 'postBuild.substituteFrom' in d2-osramp-fleet/clusters/<env>/tenants.yaml"
  echo "  2. Confirm ConfigMap 'flux-runtime-info' exists in namespace flux-system:"
  echo "     kubectl get configmap flux-runtime-info -n flux-system -o yaml"
  echo "  3. Re-reconcile to re-expand variables:"
  echo "     flux reconcile kustomization tenants -n flux-system --with-source"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

echo "=== Audit Completed ==="
if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "RESULT: ${FAIL_COUNT} DRIFT / INTEGRITY VIOLATION(S) DETECTED"
  exit 1
else
  echo "RESULT: ALL DRIFT INVARIANTS PASS"
  exit 0
fi
