# Workflow: Signal Loom Agent Stun & Containment Integrity Guard

Execute on a scheduled cadence (`*/15 * * * *`) or after triggering containment drills in AgentMaxxing or SuperCred demos.

## Steps

### Step 1: Discover Stunned Agent Workloads
```bash
STUNNED_AGENTS=$(kubectl get deployments -n fe-signalloom-agents -l "signalloom.ai/containment-state=stunned" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
echo "Discovered stunned deployments: ${STUNNED_AGENTS:-None}"
```

### Step 2: Enforce GitOps Suspension
For every stunned deployment discovered:
```bash
for deploy in $STUNNED_AGENTS; do
  SUSPENDED=$(kubectl get deployment "$deploy" -n fe-signalloom-agents -o jsonpath='{.metadata.annotations.kustomize\.toolkit\.fluxcd\.io/reconcile}' 2>/dev/null || echo "")
  if [ "$SUSPENDED" != "disabled" ]; then
    echo "VIOLATION: Deployment $deploy is stunned but lacks Flux suspension annotation. Applying..."
    kubectl annotate deployment "$deploy" -n fe-signalloom-agents "kustomize.toolkit.fluxcd.io/reconcile=disabled" --overwrite
  else
    echo "PASS: Deployment $deploy has valid Flux suspension annotation."
  fi
done
```

### Step 3: Probe Fleet Manager In-Memory DAG
Query Fleet Manager topology to confirm DAG state synchronization:
```bash
if kubectl get svc fleet-manager -n fe-signalloom >/dev/null 2>&1; then
  POD_NAME=$(kubectl -n fe-signalloom get pods -l app=dashboard-signalloom -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
  if [ -n "$POD_NAME" ]; then
    TOPOLOGY_JSON=$(kubectl -n fe-signalloom exec "$POD_NAME" -- curl -s http://localhost:8080/fleet-api/v1/fleet/topology 2>/dev/null || echo "{}")
    echo "Topology status queried from Fleet Manager."
  fi
fi
```

### Step 4: Verify Observability Agent Immunity
Confirm `agent-monitor` is not in a stunned or quarantined state:
```bash
MONITOR_STATE=$(kubectl get deployment agent-monitor -n fe-signalloom-agents -o jsonpath='{.metadata.labels.signalloom\.ai/containment-state}' 2>/dev/null || echo "not_found")
if [ "$MONITOR_STATE" = "stunned" ]; then
  echo "FATAL: agent-monitor is stunned! Observability isolation violation!"
else
  echo "PASS: agent-monitor immunity preserved."
fi
```
