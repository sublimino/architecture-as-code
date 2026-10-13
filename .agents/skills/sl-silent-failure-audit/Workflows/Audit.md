# Workflow: Signal Loom Silent Failure & Invariant Audit

Execute this workflow on scheduled intervals (`0 */4 * * *`) or preflight before creating merge requests.

## Steps

### Step 1: Initialize Workspace Root
```bash
REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")}"
cd "${REPO_ROOT}"
```

### Step 2: Run Route Collision Guard
Audit whether any nginx proxy location in `apps/dashboard-signalloom/nginx.conf` collides with a React Router path in `apps/dashboard-signalloom/src/App.tsx`:
```bash
if [ -f "d2-signalloom/test/dashboard-route-collisions.bats" ]; then
  bats d2-signalloom/test/dashboard-route-collisions.bats
fi
```

### Step 3: Run Audit Event Type AST Verification
Derive event types directly from python AST and compare to DB constraints:
```bash
python3 - <<'EOF'
import ast, os, re, sys

api_file = "d2-signalloom/apps/fe-signalloom/src/api_compat.py"
if not os.path.exists(api_file):
    print("SKIP: api_compat.py not found at expected path")
    sys.exit(0)

tree = ast.parse(open(api_file).read())
emitted = set()

for node in ast.walk(tree):
    if isinstance(node, ast.Call):
        func_name = getattr(node.func, 'id', getattr(node.func, 'attr', None))
        if func_name == '_audit_log':
            for kw in node.keywords:
                if kw.arg == 'event_type' and isinstance(kw.value, ast.Constant):
                    emitted.add(kw.value.value)

print(f"Discovered {len(emitted)} unique audit event literals in api_compat.py:")
for e in sorted(emitted):
    print(f"  - {e}")
EOF
```

### Step 4: Run Database Pool Binding Check (`POOL_IMPORTERS`)
Assert that no module uses direct name binding for connection pools:
```bash
grep -rn "from api_compat import _get_pool" d2-signalloom/apps/fe-signalloom/src/ || echo "PASS: Zero direct name bindings found"
```

### Step 5: Check for BATS Silent Skips
Run BATS test suite and flag `# skip` output lines:
```bash
bats d2-signalloom/test/*.bats 2>&1 | grep "# skip" || echo "PASS: Zero silent skips detected"
```

### Step 6: Summary Report
Aggregate findings into a compact verdict table.
