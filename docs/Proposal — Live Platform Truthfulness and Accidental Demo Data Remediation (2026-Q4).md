# Proposal — Live Platform Truthfulness and Accidental Demo Data Remediation (2026-Q4)

**Mission:** Live Platform Truthfulness & Accidental Demo Data Remediation  
**Repository:** `/home/andy/src/cp/osramp-demo`  
**Integration Branch:** `integration/slsi-v0.1.0`  
**Shortcode:** `LIVETRUTH`  
**Status:** APPROVED — In Execution  
**Created:** 2026-10-13  

---

## Executive Summary

Signal Loom separates live production operations from synthetic demo simulations. Demo data must remain behind explicit demo gates. Live database paths must report truthful state.

A platform audit identified five defects where demo data and synthetic fallbacks leak into live systems:

1. **Accidental Demo NHI Account Injection in Live DB Mode (`api_compat.py:9883–9918`):** In `list_discovery_workloads`, when connected to PostgreSQL, an empty tenant triggers `_ensure_seeded(tenant_id)`. It synthesizes three mock accounts from in-memory fixtures. An empty live inventory is a legitimate answer. It must never backfill with demo data.
2. **Accidental Demo Agent Synthesis in Live Trust Topology (`api_compat.py:5206–5212`):** In `trust_topology`, when the collector is unreachable, derived topology triggers `_ensure_seeded(tenant_id)` for empty tenants. This populates fake agents in live database mode.
3. **External Agent Host Enrollment Hardcoded Demo Tenant & SPIFFE Mismatch (`external_agent_registration.py:1130–1132, 1204`):** In `enroll_external_agent_handler`, `credential_ref` hardcodes `"tenant-demo"` before resolving `principal.tenant`. In `upload_external_agent_telemetry_handler`, `agent_id` defaults to `"agent-maxxing-linux-01"`.
4. **Dead Ghost Identity Synthesis Function (`api_compat.py:4127–4138`):** Uncalled residual function `_synth_agent` remains in the codebase.
5. **Un-gated Demo NHI Fallback and Hardcoded Tenant in DiscoveryPage (`DiscoveryPage.tsx:785–808, 678, 1004`):** In `DiscoveryPage.tsx`, the workloads catch block queries demo NHI endpoints unconditionally. Workload tenant ID defaults to `'tenant-demo'` and SPIFFE IDs use demo domain names.

---

## Architectural Invariants

* **Empty Estate Invariant:** An empty estate is an honest answer. A query against a live database with 0 records must return an empty collection, never synthetic demo fixtures.
* **Hermetic Demo Isolation:** Fixture seeding (`_ensure_seeded`) is strictly confined to memory-only test fixtures (`pool is None` AND demo mode).
* **Tenant Scoping Fidelity:** Workload credentials, SPIFFE IDs, and enrollment references must dynamically bind to the authenticated caller's tenant, never defaulting to `'tenant-demo'`.

---

## Acceptance Commands

```bash
# 1. FastAPI Contract and Discovery Suite
pytest d2-signalloom/apps/fe-signalloom/src/tests/test_discovery.py d2-signalloom/apps/fe-signalloom/src/tests/test_trust_topology.py

# 2. External Agent Host Registration Suite
pytest d2-signalloom/apps/fe-signalloom/src/tests/test_external_agent_*.py

# 3. Dashboard Discovery Page Suite
(cd d2-signalloom/apps/dashboard-signalloom && bunx vitest run src/pages/DiscoveryPage.test.tsx)

# 4. Live Figure Sweep Invariant Suite
(cd d2-signalloom/apps/dashboard-signalloom && bunx vitest run src/api/liveFigureSweep.test.ts)
```
