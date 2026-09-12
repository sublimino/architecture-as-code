# SLON-P2-3: Technical Design — Operator Dual-Agent Claim Workflow & Comparative Telemetry

<!-- machine-tag: signalloom-slon-p2-3-technical-design -->
<!-- generated-at: 2026-09-10T11:25:00+01:00 -->
<!-- integration-ref: integration/slon-v0.1.0 -->

## 1. Overview & Architecture Goals

The SLON-P2-3 mission introduces an enterprise-grade operator dual-agent claiming and comparative telemetry mechanism to Signal Loom. It enables operators to identify discovered agent workloads (specifically `agent-nono-evidenced` and `agent-standard-baseline`), transition them into tenant governance via an authenticated claim transaction, persist their governance state in PostgreSQL, and evaluate their real-time comparative security posture across two distinct isolation paradigms:

1. **Nono Sandboxed Agent (`agent-nono-evidenced`):** Linux Landlock LSM kernel confinement combined with cryptographically signed, SHA-256 hash-chained tamper-evident audit trails.
2. **Standard Container Agent (`agent-standard-baseline`):** Standard unconfined Linux container namespaces with Tetragon eBPF kernel flow tracepoint telemetry.

---

## 2. Database Design & Persistence

### 2.1 Schema: `public.agent_claims`

The PostgreSQL migration `036_agent_claims.sql` defines:

```sql
CREATE TABLE IF NOT EXISTS public.agent_claims (
    claim_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    agent_id VARCHAR(255) NOT NULL UNIQUE,
    tenant_id VARCHAR(255) NOT NULL,
    claimed_by VARCHAR(255) NOT NULL,
    claimed_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    status VARCHAR(50) NOT NULL DEFAULT 'active',
    notes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT fk_agent_claims_tenant FOREIGN KEY (tenant_id)
        REFERENCES public.tenants(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_agent_claims_tenant_id ON public.agent_claims(tenant_id);
CREATE INDEX IF NOT EXISTS idx_agent_claims_agent_id ON public.agent_claims(agent_id);
CREATE INDEX IF NOT EXISTS idx_agent_claims_claimed_at ON public.agent_claims(claimed_at);
```

### 2.2 Strict Tenant Isolation & Conflict Semantics

- **Conflict Detection (HTTP 409):** If an agent is already claimed by another tenant, any subsequent claim request from a different tenant is rejected with `HTTP 409 Conflict` and message: `"Agent '<id>' is already claimed by another operator tenant."`
- **Idempotency:** If the claiming tenant already holds the active claim, the endpoint returns the existing claim record with `HTTP 200 OK`.

---

## 3. Backend Implementation (`fe-signalloom`)

### 3.1 REST API Routes

- `POST /api/v1/agents/{agent_id}/claim`: Creates or returns an active claim for `agent_id`.
- `GET /api/v1/agents/claims`: Returns a list of active claims filtered by the caller's tenant.
- `GET /api/v1/agents/claims/{claim_id}`: Retrieves claim details by claim UUID.
- `DELETE /api/v1/agents/claims/{claim_id}`: Releases/revokes the claim association.
- `GET /api/v1/agents/{agent_id}`: Returns agent detail, attaching `claim` and `workload_security_profile`.
- `GET /api/v1/agents/{agent_id}/telemetry`: Synthesizes comparative telemetry streams based on the workload security profile.

---

## 4. Frontend UI Implementation (`dashboard-signalloom`)

### 4.1 Claim Modal (`src/components/agents/ClaimModal.tsx`)

- Modal dialog adhering to design tokens and accessibility standards (`aria-modal="true"`, `aria-labelledby`, `aria-describedby`).
- Displays workload security profile badges:
  - Green teal badge for `Nono Sandboxed` (`profile: 'nono-sandboxed'`).
  - Cyan badge for `Standard Container` (`profile: 'standard-container'`).
- Auto-populates pod name, namespace, SPIFFE ID, harness/framework, model, and token budget limit.
- Handles submission, loading spinner, and graceful error presentation (including cross-tenant 409 Conflict).

### 4.2 Comparative Activity Telemetry (`src/components/AgentActivityTab.tsx`)

- Dedicated banner `security-profile-telemetry-banner` presenting comparative telemetry summary.
- For Nono agents: Renders Landlock LSM confinement status and SHA-256 hash-chained tamper-evident audit verifier badges.
- For Standard Container agents: Renders Tetragon eBPF kernel flow monitors, sys_enter/sys_exit tracepoints, and network connect/accept telemetry streams.

### 4.3 Inventory & Dossier Integration (`AgentsPage.tsx` & `AgentDetailPage.tsx`)

- `AgentsPage.tsx`: Adds workload security profile tags and Claim Agent action triggers in table rows.
- `AgentDetailPage.tsx`: Displays workload security profile badges in `DossierHeader` and integrates the Claim button & modal.

---

## 5. Security & Verification Invariants

1. **Zero Mock Fallback:** In live execution, telemetry and claim contracts query the underlying PostgreSQL and discovered agent infrastructure without mock fallbacks.
2. **Deterministic Isolation:** Prevents multi-tenant claim race conditions via atomic database transactions and unique constraints.
