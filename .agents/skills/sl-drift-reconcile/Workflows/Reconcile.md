# Workflow: Signal Loom GitOps & Cluster Drift Reconciliation

This workflow executes on a scheduled cadence (`*/30 * * * *`) or on-demand to ensure the Signal Loom cluster runtime matches git source of truth.

## Steps

### Step 1: Probe Cluster Availability
```bash
if ! kubectl cluster-info --request-timeout=5s >/dev/null 2>&1; then
  echo "CLUSTER_OFFLINE: Kind cluster is not reachable. Skipping reconciliation cycle."
  exit 0
fi
```

### Step 2: Run Automated Drift Audit Tool
```bash
TOOL_PATH="$(dirname "$0")/../Tools/drift-audit.sh"
if [ -x "$TOOL_PATH" ]; then
  "$TOOL_PATH"
else
  bash "${TOOL_PATH}"
fi
```

### Step 3: Evaluate Audit Output
The audit script outputs machine-readable key-value pairs:
- `FLUX_STATUS`: `READY` | `DEGRADED` | `NOT_FOUND`
- `GIT_REVISION_MATCH`: `MATCH` | `DRIFT`
- `PATCH_INDEX_STATUS`: `VALID` | `CORRUPTED`
- `UNRESOLVED_VARS`: Integer count of `${VAR}` occurrences

### Step 4: Decision Tree & Remediation
- **Case 1: Clean**: All checks pass. Log timestamp and settle silently.
- **Case 2: Safe Drift (Unreconciled Source)**: If `FLUX_STATUS == READY` but `GIT_REVISION_MATCH == DRIFT`:
  ```bash
  flux reconcile kustomization tenants -n flux-system --with-source
  ```
- **Case 3: Unresolved Variables**: If `UNRESOLVED_VARS > 0`:
  Verify `flux-runtime-info` ConfigMap exists:
  ```bash
  kubectl get configmap flux-runtime-info -n flux-system -o yaml
  ```
- **Case 4: Corrupted Patch Indexes**:
  Stop immediately and raise alert: "Index drift detected in `tenants/local/kustomization.yaml`. Do not insert resources before existing indexed patches. Append to the end instead."

### Step 5: Final Brief Generation
Generate concise brief:
```markdown
### Signal Loom GitOps Reconciliation Brief
- **Timestamp**: YYYY-MM-DD HH:MM:SS UTC
- **Cluster**: Kind / osramp
- **Flux Status**: <HEALTHY|DRIFT_RECONCILED|ALERT>
- **Git Commit**: <SHORT_SHA>
- **Action Taken**: <NONE|RECONCILED|ALERT_RAISED>
```
