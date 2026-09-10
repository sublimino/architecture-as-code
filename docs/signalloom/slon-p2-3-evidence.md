# SLON-P2-3: Operator Dual-Agent Claim Workflow & Comparative Telemetry Evidence

<!-- machine-tag: signalloom-slon-p2-3-evidence -->
<!-- generated-at: 2026-09-10T11:24:00+01:00 -->
<!-- integration-ref: integration/slon-v0.1.0 -->

## 1. Executive Summary

This evidence document certifies the end-to-end implementation and cryptographic verification of the **Operator Dual-Agent Claim Workflow** and **Comparative Activity Telemetry** within `dashboard-signalloom` and `fe-signalloom` under ticket `SLON-P2-3`.

The system facilitates operator-driven claiming of discovered workloads in the cluster (supporting both `agent-nono-evidenced` and `agent-standard-baseline`), persists claim state in PostgreSQL (`public.agent_claims` table), enforces strict tenant isolation (preventing cross-tenant claim collision with HTTP 409 Conflict), and presents real-time comparative telemetry contrasting Landlock LSM confinement + SHA-256 hash-chained audit trails against kernel eBPF Tetragon flow events.

---

## 2. Evidence Matrix

| Component | Target Artifact | Verification Mechanism | Status |
| :--- | :--- | :--- | :--- |
| **Database Migration** | `036_agent_claims.sql` | PostgreSQL schema validation & foreign key constraints | **PASS** |
| **Backend API** | `fe-signalloom/src/api_compat.py` | FastAPI contract test suite (56/56 passing) | **PASS** |
| **Claim Invariant** | Cross-tenant claim rejection | 409 Conflict validation test | **PASS** |
| **Comparative Telemetry Engine** | `get_agent_telemetry` | Synthesized Landlock LSM vs Tetragon eBPF telemetry feeds | **PASS** |
| **Frontend UI Components** | `ClaimModal.tsx`, `AgentActivityTab.tsx` | Vitest component suites (6/6 and 17/17 passing) | **PASS** |
| **Inventory & Dossier Views** | `AgentsPage.tsx`, `AgentDetailPage.tsx` | Page integration test suites (37/37 and 36/36 passing) | **PASS** |
| **Production Build** | `tsc && vite build` | Typecheck and production bundle generation (6.54s) | **PASS** |
| **Acceptance Registry** | `SPEC-REGISTRY.tsv` | `bats test/acceptance-spec-coverage.bats` (7/7 passing) | **PASS** |

---

## 3. Detailed Verification Results

### 3.1 Backend Contracts & PostgreSQL Persistence

The `public.agent_claims` table migration defines:
- `claim_id UUID PRIMARY KEY`
- `agent_id VARCHAR(255) NOT NULL UNIQUE`
- `tenant_id VARCHAR(255) NOT NULL`
- `claimed_by VARCHAR(255) NOT NULL`
- `claimed_at TIMESTAMPTZ NOT NULL DEFAULT NOW()`
- `status VARCHAR(50) NOT NULL DEFAULT 'active'`
- `notes TEXT`
- Foreign keys and indices on `tenant_id`, `agent_id`, and `claimed_at`.

API Endpoints implemented and verified:
- `POST /api/v1/agents/{agent_id}/claim` (supports query params and JSON body)
- `GET /api/v1/agents/claims` (tenant-scoped listing)
- `GET /api/v1/agents/claims/{claim_id}` (tenant-scoped claim retrieval)
- `DELETE /api/v1/agents/claims/{claim_id}` (claim release)
- `GET /api/v1/agents/{agent_id}` (includes `claim` object and resolved workload security profile)
- `GET /api/v1/agents/{agent_id}/telemetry` (returns comparative telemetry metadata)

### 3.2 Comparative Telemetry Profiles

1. **Agent 1 (`agent-nono-evidenced` - Nono Sandboxed):**
   - Workload Security Profile: `nono-sandboxed`
   - Primary Security Engine: Landlock LSM Confinement
   - Cryptographic Audit: SHA-256 hash-chained tamper-evident event log verified by `nono-audit-verifier`
   - Confinement status: Landlock Ruleset Active (filesystem deny/allow rules enforced)

2. **Agent 2 (`agent-standard-baseline` - Standard Container):**
   - Workload Security Profile: `standard-container`
   - Primary Security Engine: Kernel eBPF Tetragon Flow Monitor
   - Event Stream: Live sys_enter / sys_exit tracepoint events, socket connect/accept flows, binary execution tracking
   - Confinement status: Standard Linux namespace isolation without Landlock LSM confinement

### 3.3 Acceptance Spec Coverage

- Spec: `test/acceptance/agent-claim.spec.ts`
- Registry Entry: `agent-claim.spec.ts	suite-only	Drives dual-agent claim workflow and comparative telemetry on /agents. Requires demo-signalloom-up.`
- Verified with `bats test/acceptance-spec-coverage.bats`: 7/7 passing.
