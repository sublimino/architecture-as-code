# Workflow: Signal Loom EAP Compliance Evidence Sweep

Execute on scheduled cadence (`0 6 * * *`) or before generating partner delivery packs.

## Steps

### Step 1: Scan Evidence Directories
```bash
REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")}"
cd "${REPO_ROOT}"

echo "Step 1: Auditing evidence file presence..."
ls -la docs/signalloom/evidence/ docs/signalloom/evidence-fe/ 2>/dev/null || true
```

### Step 2: Run Automated Evidence Sweeper
```bash
TOOL_PATH="$(dirname "$0")/../Tools/evidence-sweep.sh"
if [ -x "$TOOL_PATH" ]; then
  "$TOOL_PATH"
else
  bash "${TOOL_PATH}"
fi
```

### Step 3: Run Supply Chain BATS Test
```bash
if [ -f "d2-signalloom/test/dashboard-supplychain.bats" ]; then
  echo "Step 3: Running supply chain BATS test..."
  bats d2-signalloom/test/dashboard-supplychain.bats || true
fi
```

### Step 4: Audit Database Telemetry Activity
If PostgreSQL container is alive:
```bash
if kubectl get svc postgres -n inf-signalloom >/dev/null 2>&1; then
  echo "Step 4: Querying audit_events table..."
  ROW_COUNT=$(kubectl exec -n inf-signalloom deploy/postgres -- psql -U postgres -d signalloom -t -c "SELECT COUNT(*) FROM audit_events;" 2>/dev/null | tr -d ' ' || echo "0")
  echo "CURRENT_AUDIT_ROW_COUNT=${ROW_COUNT}"
fi
```

### Step 5: Deliver Executive Brief
Deliver diligence readiness score and hash ledger.
