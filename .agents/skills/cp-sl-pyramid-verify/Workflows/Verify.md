# Workflow: Signal Loom Offline Test Pyramid Verification

Executes on scheduled cadence (`0 3 * * *`) or before submitting branch merges.

## Steps

### Step 1: Documentation Quality Bar
```bash
REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")}"
cd "${REPO_ROOT}"

echo "Stage 1: Running docs-lint on core documents..."
./scripts/docs-lint.sh docs/README.md docs/signalloom/scheduled-skills.md
```

### Step 2: Bootstrap SQL Alignment
Verify that no developer committed a migration without recompiling the bootstrap SQL:
```bash
echo "Stage 2: Verifying bootstrap SQL sync..."
bash d2-signalloom/test/validate-dependencies.sh
```

### Step 3: Frontend Unit Tests
```bash
echo "Stage 3: Running Vitest test suites..."
(cd d2-signalloom/apps/dashboard-signalloom && bun run test -- --run src/auth/superadmin.test.ts src/api/fleetApi.stun.test.ts src/components/trust/trustTopology.test.ts)
```

### Step 4: Python Contract & Go Controller Tests
```bash
echo "Stage 4a: Running Python contract tests..."
(cd d2-signalloom/apps/fe-signalloom/src && UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=/tmp/uv-cache uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist --with respx --with-requirements requirements.txt python -m pytest tests/test_api_compat.py -q --disable-warnings)

echo "Stage 4b: Running Go Fleet Manager tests..."
(cd d2-signalloom/apps/fleet-manager && GONOSUMDB=* GOCACHE=/tmp/gocache GOMODCACHE=/tmp/gomodcache CGO_ENABLED=0 go test ./...)
```

### Step 5: Format Final Brief
Output summary of test execution, timing, and artifact status.
