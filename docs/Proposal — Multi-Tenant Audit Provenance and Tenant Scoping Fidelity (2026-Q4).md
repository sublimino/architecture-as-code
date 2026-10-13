# Proposal — Multi-Tenant Audit Provenance and Tenant Scoping Fidelity (2026-Q4)

**Mission:** Multi-Tenant Audit Provenance & Tenant Scoping Fidelity  
**Repository:** `/home/andy/src/cp/osramp-demo`  
**Integration Branch:** `integration/slsi-v0.1.0`  
**Shortcode:** `AUDITFIDELITY`  
**Status:** APPROVED — In Execution  
**Created:** 2026-10-13  

---

## Executive summary

Signal Loom enforces strict multi-tenant isolation across all data planes.
Every audit trail record must honestly identify the responsible tenant.
Live audit records must never default to demo fixtures.

A security audit identified four defects in signal-ingest audit logging:

1. **Accidental Demo Tenant in Correlation Runs (`api/handlers.go`):** In `handleCorrelate`, `audit.EventCorrelationRun` hardcodes `TenantID: "tenant-demo"`. A multi-tenant run records correlation events under the demo tenant.
2. **Accidental Demo Tenant in Actor Creation (`api/handlers.go`):** In `handleCorrelate`, newly correlated provisional actors emit `audit.EventActorCreated` with hardcoded `TenantID: "tenant-demo"`.
3. **Accidental Demo Tenant in Collector Runs (`api/handlers.go`):** In `handleSeed`, `audit.EventCollectorRun` hardcodes `TenantID: "tenant-demo"`.
4. **Accidental Demo Tenant in Actor Promotion (`api/promote.go`):** In `handlePromote`, the highest-stakes lifecycle promotion records `audit.EventActorPromoted` with hardcoded `TenantID: "tenant-demo"`.
5. **Missing Tenant Field in Discovery Workload Interface (`types/api.ts`):** `DiscoveryWorkload` omitted `tenant_id`. This required unsafe type assertions in frontend components.

---

## Architectural invariants

* **Tenant Scoping Fidelity:** Every audit event must bind to the authenticated caller or observation tenant. An audit event must never default to `'tenant-demo'`.
* **Audit Trail Integrity:** High-stakes lifecycle promotions and correlation runs must attribute actions to the verified tenant.
* **Strict Type Safety:** Frontend models must explicitly declare backend fields without resorting to unsafe type casting.

---

## Acceptance commands

```bash
# 1. Signal Ingest Go Unit and Handler Audit Suite
(cd d2-signalloom/apps/signal-ingest && env GOPATH=/tmp/gopath GOCACHE=/tmp/gocache GOMODCACHE=/tmp/gomodcache CGO_ENABLED=0 go test ./api -v -run 'Test(Correlate|Seed|Promote)')

# 2. Frontend Dashboard Types and Discovery Suite
(cd d2-signalloom/apps/dashboard-signalloom && bunx vitest run src/pages/DiscoveryPage.test.tsx)
```
