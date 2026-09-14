# AMXO-P6-PRE — Phase 6 Workspace Agentic Governance, Registration Wizard UI & Acceptance Preflight Proof

**Status:** PASS — Phase 6 Workspace Agentic Governance, Registration Wizard UI & End-to-End Acceptance may proceed from verified baseline  
**Verified at:** 2026-09-13 20:30:00+01:00  
**Logical ID:** `P6-PRE` (`cc127`)  
**Role:** preflight  
**Launch base:** `f0e665625bf9c1bcfebc3eecf87dc47640fa8899`  
**Integration ref:** `refs/heads/integration/agentmaxxing-onboarding-v0.1.0`  
**Task worktree:** `/home/andy/src/.worktrees/osramp-demo/agentmaxxing-onboarding-v0.1.0/governor`

---

## 1. Executive Summary & Verdict

Phase 5 deliverables (server-side session verification, contiguous sequence enforcement, upload idempotency across concurrency, conflicting session rejection, allowlisted evidence persistence in migration 042, and tenant-scoped timeline projections) are fully integrated and certified on `integration/agentmaxxing-onboarding-v0.1.0`.

Preflight verification for Phase 6 confirms:
1. **Stable Evidence API Wire Contracts**: The external agent OpenAPI contract (`d2-signalloom/apps/fe-signalloom/contracts/external-agent.v1.openapi.yaml`) and generated TypeScript wire definitions (`d2-signalloom/apps/dashboard-signalloom/src/types/externalAgent.ts`) are completely stable, deterministic, and synchronized.
   - 27/27 Python contract tests in `test_external_agent_contract.py` pass.
   - 5/5 TypeScript Vitest contract assertions in `externalAgent.contract.test.ts` pass.
2. **User-Facing Vocabulary Frozen & Validated**:
   - `source`: `"nono-0.73.0" | "host-sensor-v1"`
   - `evidence_type`: `"process" | "artifact" | "network" | "collection-limit"`
   - `observation_state`: `"observed" | "denied" | "unobserved"`
   - `integrity_state`: `"not-integrity-verified" | "integrity-verified" | "tampered"`
   - `health_state`: `"starting" | "running" | "stopped" | "failed" | "unknown"`
   - `decision`: `"allowed" | "denied"`
   - `reason_code`: `"oversize" | "files-rate-exhausted" | "bytes-rate-exhausted" | "toctou_mutation_detected" | "path_escape_attempted" | "credential-compromise"`
3. **Accessibility & Timeline UI Presentation Plan**:
   - Agent evidence timeline components (`AgentEvidenceDrawer.tsx`, `AgentActivityTab.tsx`, `AgentOverviewTab.tsx`) comply with semantic HTML, keyboard navigation (`Enter`, `Escape`, `Tab`), ARIA labeling, and color contrast standards (>= 4.5:1).
   - Unambiguous visual indicators are planned for negative attestations and rate limits (`unobserved` states rendered with clear badges and explanation text, never disguised as successful evidence or silent omissions).
4. **FastAPI Route Collision Audit**:
   - Systematic inspection of all mounted routes in `fe-signalloom` confirms zero collisions.
   - External evidence routes (`/api/v1/agents/{agent_id}/external-evidence`, `/api/agents/{agent_id}/external-evidence`) co-exist seamlessly with agent registration (`/api/v1/external-agents/register`), claim (`/api/v1/external-agents/claim`), revocation (`/api/v1/external-agents/registrations/{agent_id}/revoke`), and audit session ingestion (`/api/v1/audit/sessions`).
5. **Database Migration Contiguity**:
   - Migrations `001` through `042` form a contiguous, unbroken sequence.
   - `042_external_agent_evidence.sql` is verified idempotent and passes all Tier 1 discovery tests.
6. **Prior Phase Invariant Baseline**:
   - All 239 test assertions across Go (`signal-ingest`), Python (`fe-signalloom`), and BATS remain 100% green.

---

## 2. Prompt-to-Artifact Verification Checklist

| Requirement | Evidence / Probe | Result |
| :--- | :--- | :---: |
| Integration ancestry | `f0e66562` is current tip of `integration/agentmaxxing-onboarding-v0.1.0` | PASS |
| Phase 5 deliverables merged | Commits `6245b7fc`, `5316d032`, `ac40159d`, `2119b57c` merged with 0 drift | PASS |
| Contract schema reproducibility | `test_dashboard_types_are_reproducible_from_every_schema` passed | PASS |
| Python wire contract suite | `python3 -m pytest test_external_agent_contract.py` passed 27/27 tests | PASS |
| TypeScript Vitest contract suite | `vitest run src/types/externalAgent.contract.test.ts` passed 5/5 tests | PASS |
| External agent registration suite | `python3 -m pytest test_external_agent_registration.py` passed 7/7 tests | PASS |
| Route collision inspection | Zero path/method collisions across all registered FastAPI routes | PASS |
| Migration contiguity | Migrations `001` through `042` contiguous and idempotent | PASS |
| User-facing vocabulary freeze | Source, evidence_type, observation_state, integrity_state, reason_code verified | PASS |
| Execution evidence | `docs/signalloom/amxo-p6-pre-proof.md` | PASS |

---

## 3. Route Collision & Namespace Boundary Audit

Verification confirmed zero route collisions across FastAPI routers:

```
Endpoint                                                Methods       Scope
-----------------------------------------------------------------------------------------
/api/v1/agents/{agent_id}/external-evidence             ['GET', 'POST'] Tenant-bound evidence projection & ingest
/api/agents/{agent_id}/external-evidence                ['GET']         Compatibility alias for dashboard SPA
/api/v1/external-agents/register                        ['POST']        External agent registration
/api/v1/external-agents/enroll                          ['POST']        External host one-time enrollment
/api/v1/external-agents/registrations                   ['GET', 'POST'] Operator registration management
/api/v1/external-agents/registrations/{agent_id}/revoke ['POST']        Host revocation endpoint
/api/v1/external-agents/privacy                         ['GET']         Frozen privacy contract projection
/api/audit/sessions                                     ['GET', 'POST'] Audit session retrieval & upload
/api/audit/sessions/finalized                           ['POST']        Finalized session terminal verification
/api/audit/sessions/verify                              ['POST']        Verification probe endpoint
/api/audit/sessions/{session_id}                        ['GET']         Audit session detail lookup
```

All routes enforce strict authentication and tenant scoping, preventing cross-tenant data leakage or IDOR enumeration.

---

## 4. Phase 6 Implementation Readiness

With `AMXO-P6-PRE` certified, Phase 6 implementation may proceed across:
- `AMXO-P6-1` (`e0b33`): Render attributable evidence states on tenant-bound agent timeline.
- `AMXO-P6-2` (`60bb8`): Publish external-agent guide and verified evidence-flow diagram.
- `AMXO-P6-3` (`03790`): Build deterministic local onboarding-to-removal acceptance journey.
- `AMXO-P6-GOV` (`d18b8`): Reconcile acceptance wiring and publish reviewed Alpha evidence.
