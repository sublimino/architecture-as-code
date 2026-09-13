# AMXO-P5-3 Verification Evidence

**Recorded:** 2026-09-13T20:20:00+01:00  
**Scope:** Persist allowlisted evidence and expose tenant-scoped projections; strict allowlist enforcement dropping prohibited/raw memory/command fields; zero cross-tenant data leak / IDOR protection across projection endpoints; dual persistence (PostgreSQL migration 042 + in-memory store); automated evidence extraction from ingested audit sessions.

## Test Ledger

| Command | Outcome | Skips | Evidence |
| :--- | :--- | :--- | :--- |
| `make demo-signalloom-api-test TIER=contract` | 56 passed | 0 | FastAPI Tier 1 contract tests and numbered migration sequence validation (including migration 042 discovery and idempotency) |
| `pytest d2-signalloom/apps/fe-signalloom/src/tests/test_audit_ingest.py -k "test_tenant_projections or test_prohibited_fields or test_external_evidence"` | 3 passed | 0 | Pytest assertions for tenant-scoped projections, prohibited field sanitization, query filtering, and pagination |
| `make demo-agentmaxxing-ingest-test` | 29 Go tests + 12 Pytest tests passed | 0 | Integrated AgentMaxxing audit session ingest, deduplication, and verification test target |
| `make demo-agentmaxxing-host-test` | 70 passed | 0 | 38 unittest + 6 pytest + 26 BATS tests asserting nono profile, anti-escape, and TOCTOU hasher integrity |
| Full `test_audit_ingest.py` suite | 37 passed | 0 | Complete FastAPI ingest, session verification, deduplication, and evidence projections suite |

## Invariants & Architecture Enforcement

1. **Database Migration 042 (`042_external_agent_evidence.sql`)**:
   - Creates `public.external_agent_evidence` with columns `id`, `tenant_id`, `agent_id`, `session_id`, `evidence_type`, `digest`, `observed_at`, `attributes`, and `created_at`.
   - Adds indexes: `idx_ext_agent_evidence_tenant_agent`, `idx_ext_agent_evidence_session`, and `idx_ext_agent_evidence_type`.
   - Adheres strictly to repository migration standards: idempotent DDL (`IF NOT EXISTS`), numeric sequential naming, and zero side-effects.

2. **Storage Boundary Field Allowlist & Sanitization**:
   - `sanitize_evidence_attributes` enforces a strict allowlist per evidence type (`process`, `artifact`, `network`, `environment`, `quarantine`).
   - Automatically drops `PROHIBITED_FIELD_NAMES`: `payload`, `raw_payload`, `memory_dump`, `command_text`, `argv_raw`, `stdin`, `stdout`, `stderr`, `buffer`, `raw_bytes`, `secret`, `token`, `password`, `key`.
   - Safely preserves unobserved execution states (`unobserved`, `skipped_by_policy`, `toctou_quarantined`) for verifiable negative-attestation.

3. **Tenant-Scoped Projections & IDOR Prevention**:
   - Endpoints:
     - `GET /api/v1/agents/{agent_id}/external-evidence`
     - `GET /api/agents/{agent_id}/external-evidence`
     - `POST /api/v1/agents/{agent_id}/external-evidence`
   - Tenant isolation is strictly enforced against `current_tenant.id` / `X-Scope-OrgID`.
   - Querying another tenant's agent returns HTTP 404 (or empty results if agent does not belong to caller), eliminating cross-tenant visibility or enumerability.

4. **Automated Audit Event Ingestion Hook**:
   - Upon successful verification of signed/finalized audit sessions in `audit_ingest.py`, events containing structured attributes (`process`, `artifact`, `network`, etc.) are automatically sanitized and persisted into the evidence projections table.
   - Dual persistence handles both live PostgreSQL and fallback in-memory state for contract testing.

## Delivery Boundaries

- Executed on task branch `feat/amxo-p5-3-evidence-projections`.
- Clean unsigned commits (`git commit --no-gpg-sign`).
- Obsidian proposal file NOT touched or committed to git.
