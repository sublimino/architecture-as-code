---
name: sl-silent-failure-audit
description: "Scheduled-run silent failure and invariant sentinel for #partner-signal-loom. Audits the 17 cataloged silent failure patterns across runtime and contracts. USE WHEN silent failures, audit invariants, verify signal loom invariants, check silent bugs, sl-silent-failure-audit, or on schedule '0 */4 * * *'."
---

# sl-silent-failure-audit

Scheduled invariant audit and silent failure detector for the **Signal Loom** (`#partner-signal-loom`) platform.

## Loop Lens & Schedule Contract

- **Cadence**: `0 */4 * * *` (Every 4 hours, or during preflight / post-merge verification).
- **Trigger**: Cron notification, `/sl-silent-failure-audit`, or manual prompt "audit silent failures".
- **Checkpoint**: Push right. Perform exhaustive static and cluster invariant verification. Report concise findings table with actionable patch targets.
- **Brief**: Emit a 4-bullet executive status: (1) Total invariants checked, (2) Invariants passed, (3) Silent regressions discovered, (4) Direct remediation file/line targets.

---

## Mandate & Non-Negotiable Invariants

1. **Two Things That Must Agree (Derive, Never Restate)**:
   - Every invariant check must derive both sides dynamically (AST parsing, CRI query, filesystem scan). Never hardcode expected lists that go stale.

2. **CRI Layer Truth**:
   - `ctr -n k8s.io images ls` lists image metadata even when layer blobs are missing. Only `crictl images` reflects what the container runtime can actually execute. Image presence checks MUST inspect `crictl`.

3. **Audit Trail Schema Agreement**:
   - PostgreSQL `audit_events.event_type` CHECK constraints must permit 100% of event literals emitted by API call sites (`api_compat.py`). A product selling regulatory compliance cannot silently drop audit records.

4. **Nginx SPA Shadowing Prevention**:
   - Nginx proxy prefixes must never collide with or shadow client-side React routes declared in `App.tsx`.

5. **No Silent BATS Skips**:
   - A BATS suite with a dead dependency outputs `ok ... # skip` which reads as green. BATS runs must assert 0 unintended skips.

---

## Information Hierarchy

- **Primary Workflow**: [`Workflows/Audit.md`](Workflows/Audit.md)
- **17 Failure Patterns Catalog**: [`References/FailureCatalog.md`](References/FailureCatalog.md)
- **Executable Auditor**: [`Tools/audit-invariants.sh`](Tools/audit-invariants.sh)

---

## Execution Sequence

1. **Route Collision Audit**:
   - Parse all `<Route path="..." />` strings from `apps/dashboard-signalloom/src/App.tsx`.
   - Parse all `location ^~ /prefix/` directives from `apps/dashboard-signalloom/nginx.conf`.
   - Assert intersection is empty (excluding intentional backend API prefixes).

2. **Audit Event Type AST Agreement**:
   - Run Python AST parser over `apps/fe-signalloom/src/api_compat.py` to extract all `_audit_log(..., event_type="...")` literals.
   - Query or inspect `inf-signalloom/base/initdb/` SQL constraints.
   - Assert all code literals belong to allowed SQL enum set.

3. **Database Pool Importer Invariant (`POOL_IMPORTERS`)**:
   - Assert no application module imports `_get_pool` via direct name binding (`from api_compat import _get_pool`).
   - Confirm modules resolve through module object (`pool = await api_compat._get_pool()`).

4. **BATS Test Suite Silent Skip Sweep**:
   - Run test suites and inspect outputs for `# skip`.
   - Distinguish intentional environment gates from severed test harnesses.

5. **Container Image CRI Layer Verification**:
   - If running on Kind node, execute `crictl images` to verify layers are mounted, not just listed in containerd metadata.

---

## Completion Criteria

- **Clarity**: Unambiguous PASS/FAIL on all 17 invariants with zero uninvestigated warnings.
- **Demand**: All derivation tests executed. Zero AST discrepancies and zero route collisions found.
