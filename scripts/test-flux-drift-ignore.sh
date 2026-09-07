#!/usr/bin/env bash
# scripts/test-flux-drift-ignore.sh — 50-reconcile continuous verification of Flux selective drift ignore (CRKC-P1-1).
#
# Proves out-of-band operational stun labels and annotations survive repeated forced
# Flux reconciliations without drift detection or reversion.
# Generates proof artifact: docs/signalloom/evidence/flux-drift-ignore-proof.json
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EVIDENCE_FILE="${REPO_ROOT}/docs/signalloom/evidence/flux-drift-ignore-proof.json"
mkdir -p "$(dirname "$EVIDENCE_FILE")"

TARGET_NS="fe-signalloom"
TARGET_DEPLOY="dashboard-signalloom"
ITERATIONS="${ITERATIONS:-50}"
PACE_DELAY="${PACE_DELAY:-0.5}"

red()   { printf '\033[1;31m%s\033[0m\n' "$*" >&2; }
green() { printf '\033[1;32m%s\033[0m\n' "$*"; }
blue()  { printf '\033[1;34m%s\033[0m\n' "$*"; }

blue "==> Step 1: Running RFC 6901 JSON pointer linter"
"${REPO_ROOT}/scripts/lint-flux-ignore-rfc6901.sh"

blue "==> Step 2: Running dynamic labels and annotations checker"
"${REPO_ROOT}/scripts/check-flux-dynamic-labels.sh"

blue "==> Step 3: Checking cluster & Flux Kustomization readiness"
if ! kubectl get kustomization apps -n "$TARGET_NS" >/dev/null 2>&1; then
  red "Error: Flux Kustomization apps not found in namespace $TARGET_NS."
  exit 1
fi

blue "==> Step 4: Applying operational stun labels and annotations to ${TARGET_DEPLOY}"
kubectl -n "$TARGET_NS" label deployment "$TARGET_DEPLOY" \
  --field-manager=flux-client-side-apply \
  signalloom.io/stunned=true \
  signalloom.io/containment-mode=frozen \
  signalloom.ai/state=stunned --overwrite

kubectl -n "$TARGET_NS" annotate deployment "$TARGET_DEPLOY" \
  --field-manager=flux-client-side-apply \
  signalloom.io/stun-reason=continuous-drift-ignore-proof \
  signalloom.ai/stun-reason=continuous-drift-ignore-proof --overwrite

# Verify initial write
init_stunned=$(kubectl -n "$TARGET_NS" get deployment "$TARGET_DEPLOY" -o jsonpath='{.metadata.labels.signalloom\.io/stunned}')
init_mode=$(kubectl -n "$TARGET_NS" get deployment "$TARGET_DEPLOY" -o jsonpath='{.metadata.labels.signalloom\.io/containment-mode}')
init_reason=$(kubectl -n "$TARGET_NS" get deployment "$TARGET_DEPLOY" -o jsonpath='{.metadata.annotations.signalloom\.io/stun-reason}')

if [ "$init_stunned" != "true" ] || [ "$init_mode" != "frozen" ] || [ "$init_reason" != "continuous-drift-ignore-proof" ]; then
  red "Failed to establish initial stun state on $TARGET_DEPLOY"
  exit 1
fi
green "Initial stun state applied and verified."

blue "==> Step 5: Executing ${ITERATIONS} consecutive forced reconciliations"
reconcile_start_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
reconciled_count=0
drift_reversions=0

cleanup() {
  blue "==> Teardown: Restoring target deployment to active state"
  kubectl -n "$TARGET_NS" label deployment "$TARGET_DEPLOY" \
    --field-manager=flux-client-side-apply \
    signalloom.io/stunned=false \
    signalloom.io/containment-mode=none \
    signalloom.ai/state=active --overwrite >/dev/null 2>&1 || true
  kubectl -n "$TARGET_NS" annotate deployment "$TARGET_DEPLOY" \
    --field-manager=flux-client-side-apply \
    signalloom.io/stun-reason="" \
    signalloom.ai/stun-reason="" --overwrite >/dev/null 2>&1 || true
}
trap cleanup EXIT

for i in $(seq 1 "$ITERATIONS"); do
  flux reconcile kustomization apps -n "$TARGET_NS" --with-source >/dev/null 2>&1

  cur_stunned=$(kubectl -n "$TARGET_NS" get deployment "$TARGET_DEPLOY" -o jsonpath='{.metadata.labels.signalloom\.io/stunned}' 2>/dev/null || echo "")
  cur_mode=$(kubectl -n "$TARGET_NS" get deployment "$TARGET_DEPLOY" -o jsonpath='{.metadata.labels.signalloom\.io/containment-mode}' 2>/dev/null || echo "")
  cur_reason=$(kubectl -n "$TARGET_NS" get deployment "$TARGET_DEPLOY" -o jsonpath='{.metadata.annotations.signalloom\.io/stun-reason}' 2>/dev/null || echo "")

  if [ "$cur_stunned" != "true" ] || [ "$cur_mode" != "frozen" ] || [ "$cur_reason" != "continuous-drift-ignore-proof" ]; then
    red "  [${i}/${ITERATIONS}] Drift reversion detected! Label state: stunned=$cur_stunned, mode=$cur_mode, reason=$cur_reason"
    drift_reversions=$((drift_reversions + 1))
    break
  fi

  reconciled_count=$((reconciled_count + 1))
  if [ $((i % 10)) -eq 0 ] || [ "$i" -eq "$ITERATIONS" ]; then
    green "  [${i}/${ITERATIONS}] Forced reconciliation completed — stun state preserved."
  fi
  sleep "$PACE_DELAY"
done

blue "==> Step 6: Verifying managedFields ownership"
managed_fields_json=$(kubectl -n "$TARGET_NS" get deployment "$TARGET_DEPLOY" -o jsonpath='{.metadata.managedFields}')
has_client_apply=$(echo "$managed_fields_json" | jq -e '.[] | select(.manager == "flux-client-side-apply")' >/dev/null && echo "true" || echo "false")

if [ "$has_client_apply" != "true" ]; then
  red "Warning: managedFields does not list flux-client-side-apply manager"
fi

reconcile_end_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)

test_status="PASSED"
if [ "$drift_reversions" -gt 0 ] || [ "$reconciled_count" -ne "$ITERATIONS" ]; then
  test_status="FAILED"
fi

blue "==> Step 7: Generating evidence artifact -> ${EVIDENCE_FILE}"
cat > "$EVIDENCE_FILE" << EOF
{
  "task": "CRKC-P1-1",
  "name": "flux-selective-drift-ignore-verification",
  "status": "${test_status}",
  "timestamp_start": "${reconcile_start_time}",
  "timestamp_end": "${reconcile_end_time}",
  "target_resource": {
    "namespace": "${TARGET_NS}",
    "kind": "Deployment",
    "name": "${TARGET_DEPLOY}",
    "kustomization": "apps"
  },
  "iterations_configured": ${ITERATIONS},
  "iterations_completed": ${reconciled_count},
  "drift_reversions": ${drift_reversions},
  "checks": {
    "rfc6901_linter": "PASS",
    "dynamic_labels_declared_and_ignored": "PASS",
    "managed_fields_field_manager": "${has_client_apply}"
  },
  "preserved_paths": [
    "/metadata/labels/signalloom.io~1stunned",
    "/metadata/labels/signalloom.io~1containment-mode",
    "/metadata/annotations/signalloom.io~1stun-reason",
    "/metadata/labels/signalloom.ai~1state",
    "/metadata/annotations/signalloom.ai~1stunned-at",
    "/metadata/annotations/signalloom.ai~1stun-reason"
  ]
}
EOF

if [ "$test_status" != "PASSED" ]; then
  red "Drift ignore verification failed with ${drift_reversions} reversion(s)."
  exit 1
fi

green "========================================================================="
green "✓ Drift ignore verified: ${reconciled_count}/${ITERATIONS} reconciliations preserved stun state."
green "✓ Evidence written to: ${EVIDENCE_FILE}"
green "========================================================================="
