---
name: cp-sl-pyramid-verify
description: "Scheduled-run offline test pyramid guard. Executes docs-lint across documents. Runs offline tests for Go, Vitest, and Python. Verifies zero schema drift. USE WHEN verify pyramid, test all offline, docs lint test, or on schedule '0 3 * * *'."
---

# cp-sl-pyramid-verify

Scheduled offline test pyramid verification and schema drift guard for the **Signal Loom** (`#partner-signal-loom`) platform.

## Loop Lens & Schedule Contract

- **Cadence**: `0 3 * * *` (Daily at 03:00 UTC, or before branch integration).
- **Trigger**: Cron notification, `/cp-sl-pyramid-verify`, or manual prompt "run test pyramid".
- **Checkpoint**: Push right. Executes the entire offline verification pyramid without requiring a running Kind cluster or cloud connectivity. Emits a clean decision brief.
- **Brief**: Emit a 4-bullet status: (1) Docs lint status, (2) Offline test suite passes, (3) Bootstrap SQL alignment status, (4) Regression count.

---

## Mandate & Non-Negotiable Invariants

1. **Zero External Cluster Dependency**:
   - The offline pyramid MUST pass in a completely airgapped, offline environment without Kind, Docker daemon, or Kubernetes API.

2. **Zero Schema Drift**:
   - `contracts/discovery-portal-bootstrap.sql` must strictly match the output of `generate-bootstrap.py` compiled from `inf-signalloom/base/initdb/` migrations.

3. **Falsifiability & Empirical Mutation**:
   - Added tests must be sensitive to real logic mutations, not trivial tautologies that pass unconditionally.

4. **Markdown Style Enforcement**:
   - All documentation in `docs/` must pass `make docs-lint` (68 automated style, path, diagram, and link checks).

---

## Information Hierarchy

- **Primary Workflow**: [`Workflows/Verify.md`](Workflows/Verify.md)
- **Pyramid Contracts Reference**: [`References/PyramidContracts.md`](References/PyramidContracts.md)
- **Executable Runner**: [`Tools/pyramid-runner.sh`](Tools/pyramid-runner.sh)

---

## Execution Sequence

1. **Documentation Link & Style Lint**:
   - Run `./scripts/docs-lint.sh docs/README.md docs/signalloom/scheduled-skills.md`.

2. **Schema & Bootstrap Sync Audit**:
   - Verify that migrations match `discovery-portal-bootstrap.sql` without drift:
     ```bash
     bash d2-signalloom/test/validate-dependencies.sh
     ```

3. **Dashboard SPA Unit & Typecheck**:
   - Run Vitest suites: `cd d2-signalloom/apps/dashboard-signalloom && bun run test -- --run src/auth/superadmin.test.ts src/api/fleetApi.stun.test.ts src/components/trust/trustTopology.test.ts`.

4. **FastAPI Contract & Invariant Tests**:
   - Run pytest offline contract tests via repo uv environment:
     ```bash
     cd d2-signalloom/apps/fe-signalloom/src && UV_CONFIG_FILE=/dev/null UV_CACHE_DIR=/tmp/uv-cache uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist --with respx --with-requirements requirements.txt python -m pytest tests/test_api_compat.py -q --disable-warnings
     ```

5. **Host Sensor & Landlock Confinement**:
   - Run sensor tests: `cd d2-signalloom/apps/agentmaxxing-host-sensor && python3 -m unittest test_transcript_parser.py -q`.

6. **Go Controller Unit Tests**:
   - Run Go tests inside module:
     ```bash
     cd d2-signalloom/apps/fleet-manager && GONOSUMDB=* GOCACHE=/tmp/gocache GOMODCACHE=/tmp/gomodcache CGO_ENABLED=0 go test ./...
     ```

---

## Completion Criteria

- **Clarity**: 100% test pass record with zero skipped suites and zero doc lint warnings.
- **Demand**: All 6 offline layers executed and logged. Schema diff confirmed zero lines.
