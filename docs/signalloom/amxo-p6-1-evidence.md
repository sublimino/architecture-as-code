# AMXO-P6-1 — Render Attributable Evidence States on Tenant-Bound Agent Timeline

**Status:** PASS — Attributable evidence states and cryptographic verification rendering certified on agent timeline  
**Completed at:** 2026-09-13 20:30:00+01:00  
**Task ID:** `e0b33` (`AMXO-P6-1`)  
**Role:** implementation  
**Branch:** `feat/amxo-p6-1-agent-timeline`  
**Base:** `c1362c7bd8f178b851590573c0843633405609b6`  

---

## 1. Executive Summary & Verification Verdict

`AMXO-P6-1` renders attributable external agent evidence states, cryptographic hash chains, and security profile attestations directly within the Signal Loom Dossier Activity Timeline (`AgentActivityTab.tsx`), backed by client projections (`client.ts`) and loaded in the canonical agent dossier (`AgentDetailPage.tsx`).

### Core Features Implemented:
1. **Client API & Typed Projections**:
   - Added `ExternalEvidenceItem` and `ExternalEvidenceResponse` to `d2-signalloom/apps/dashboard-signalloom/src/types/api.ts`.
   - Wired `api.agents.externalEvidence(token, agentId, params)` in `d2-signalloom/apps/dashboard-signalloom/src/api/client.ts`.
   - Updated `AgentDetailPage.tsx` to load `externalEvidence` concurrently with audit, violations, and telemetry in `Promise.allSettled`, passing evidence into `<AgentActivityTab />`.
2. **Attributable Timeline Rendering in `AgentActivityTab.tsx`**:
   - Merged `external_evidence` items into the unified chronological activity timeline alongside audit events, policy violations, and telemetry observations.
   - **Visual Integrity & State Borders**:
     - Green (`var(--teal)` / `colors.tealLoom`) for `integrity-verified` records.
     - Red (`var(--error)` / `colors.red`) for `tampered` or `denied` states.
     - Amber (`var(--amber)` / `colors.amber`) for `unobserved` or `not-integrity-verified` records.
   - **Header Badges**:
     - Evidence type tag: `EVIDENCE: {evidence_type}`.
     - Source tag: `Source: {source}` (`nono-0.73.0`, `host-sensor-v1`).
     - Observation state badge: `OBSERVED`, `DENIED`, `UNOBSERVED`.
     - Cryptographic integrity badge: `INTEGRITY VERIFIED`, `TAMPERED HASH CHAIN`, `UNVERIFIED`.
     - Truncated session ID badge: `Session: {session_id.slice(0, 8)}…`.
   - **Attributable Metadata per Evidence Type**:
     - `process`: Health status, CPU %, memory RSS (MB), process exit code.
     - `artifact`: Workspace root path, truncated SHA-256 digest, byte size, modification timestamp.
     - `network`: Destination socket (IP:Port), decision (`allowed` vs `blocked`).
     - `collection-limit`: Reason code (`RATE_LIMIT_EXCEEDED`, `toctou_mutation_detected`, etc.), evaluation window.
     - Cryptographic provenance: hash chain digest, Linux Landlock ABI level (`v3`), SPIFFE ID.
   - **Allowlisted Attributes Viewer**:
     - Interactive toggle button (`toggle-external-evidence-detail-${ev.id}`) revealing JSON payload (`activity-external-evidence-payload-${ev.id}`).
   - **Interactive Filtering & Search**:
     - Type filtering: `evidence`, `evidence:process`, `evidence:artifact`, `evidence:network`, `evidence:collection-limit`.
     - Source filtering: `nono-0.73.0`, `host-sensor-v1`.
     - Free-text search: matches across evidence type, source, session ID, hash chain digest, SPIFFE ID, and allowlisted attribute fields.
     - Summary StatCard 1: total recorded events count correctly reflects external evidence items alongside audit, violations, and telemetry.
3. **Automated Verification Suite**:
   - Extended `src/components/AgentActivityTab.test.tsx` with 5 new unit and integration tests covering rendering, integrity borders, badges, metadata, toggle viewers, type filtering, source filtering, and text search.
   - Added `demo-agentmaxxing-ui-test` to `Makefile`.
   - Verified 100% PASS across 22/22 vitest tests in `AgentActivityTab.test.tsx` and 38/38 vitest tests in `AgentDetailPage.test.tsx`.

---

## 2. Verification Command Output

### 2.1 UI Evidence Timeline Suite (`make demo-agentmaxxing-ui-test`)
```
cd d2-signalloom/apps/dashboard-signalloom && bun x vitest run src/components/AgentActivityTab.test.tsx

 ✓ src/components/AgentActivityTab.test.tsx (22 tests) 380ms
   ✓ AgentActivityTab — Tab 5 (Activity & Attributable Timeline) > renders all 4 summary StatCards with accurate counts and status
   ✓ AgentActivityTab — Tab 5 (Activity & Attributable Timeline) > renders attributable events with separation of identity planes (authorizer vs workload)
   ✓ AgentActivityTab — Tab 5 (Activity & Attributable Timeline) > renders truthful empty state "No activity recorded" when 0 events exist without synthesizing fake records
   ✓ AgentActivityTab — Tab 5 (Activity & Attributable Timeline) > renders truthful degraded state "Source unavailable" when sourceHealth is unavailable
   ✓ AgentActivityTab — Tab 5 (Activity & Attributable Timeline) > filters timeline items by Event Type
   ✓ AgentActivityTab — Tab 5 (Activity & Attributable Timeline) > filters timeline items by Identity Plane (human authorizers vs workload)
   ✓ AgentActivityTab — Tab 5 (Activity & Attributable Timeline) > filters timeline items by text search across rationale, actor, and payload
   ✓ AgentActivityTab — Tab 5 (Activity & Attributable Timeline) > toggles live SSE streaming mode and calls callback
   ✓ AgentActivityTab — Tab 5 (Activity & Attributable Timeline) > handles violation acknowledgment action cleanly
   ✓ AgentActivityTab — Tab 5 (Activity & Attributable Timeline) > renders scoped deep-link buttons to Audit Trail, Signal Fusion, and Weave
   ✓ AgentActivityTab — Tab 5 (Activity & Attributable Timeline) > expands and displays JSON payload detail on toggle
   ✓ AgentActivityTab — Tab 5 (Activity & Attributable Timeline) > filters activity timeline items from URL search params
   ✓ AgentActivityTab — Tab 5 (Activity & Attributable Timeline) > renders correlated telemetry observations with layer, source, confidence, and payload toggle
   ✓ AgentActivityTab — Tab 5 (Activity & Attributable Timeline) > filters telemetry observations by layer and source filters
   ✓ AgentActivityTab — Tab 5 (Activity & Attributable Timeline) > reflects telemetry observations in summary StatCard count
   ✓ AgentActivityTab — Tab 5 (Activity & Attributable Timeline) > renders comparative telemetry banner with Nono cryptographic audit trails for nono-sandboxed agent
   ✓ AgentActivityTab — Tab 5 (Activity & Attributable Timeline) > renders comparative telemetry banner with Tetragon eBPF flow stream for standard baseline agent
   ✓ AgentActivityTab — Tab 5 (Activity & Attributable Timeline) > External Agent Evidence Projections (AMXO-P6-1) > renders external evidence items with type, source, observation state, integrity badge, and attributable metadata
   ✓ AgentActivityTab — Tab 5 (Activity & Attributable Timeline) > External Agent Evidence Projections (AMXO-P6-1) > toggles allowlisted attributes payload JSON viewer
   ✓ AgentActivityTab — Tab 5 (Activity & Attributable Timeline) > External Agent Evidence Projections (AMXO-P6-1) > filters external evidence by type filter options
   ✓ AgentActivityTab — Tab 5 (Activity & Attributable Timeline) > External Agent Evidence Projections (AMXO-P6-1) > filters external evidence by source filter options
   ✓ AgentActivityTab — Tab 5 (Activity & Attributable Timeline) > External Agent Evidence Projections (AMXO-P6-1) > searches external evidence by session ID, hash digest, or attributes

 Test Files  1 passed (1)
      Tests  22 passed (22)
   Duration  1.22s
```

### 2.2 Dossier Page Suite
```
cd d2-signalloom/apps/dashboard-signalloom && bun x vitest run src/pages/AgentDetailPage.test.tsx

 Test Files  1 passed (1)
      Tests  38 passed (38)
   Duration  2.15s
```

---

## 3. Changed Files

| File | Nature of Change |
| :--- | :--- |
| `d2-signalloom/apps/dashboard-signalloom/src/types/api.ts` | Added `ExternalEvidenceItem` and `ExternalEvidenceResponse` interface contracts |
| `d2-signalloom/apps/dashboard-signalloom/src/api/client.ts` | Added `api.agents.externalEvidence` endpoint client method |
| `d2-signalloom/apps/dashboard-signalloom/src/components/AgentActivityTab.tsx` | Implemented evidence item rendering, integrity borders, badges, metadata, toggle, filters, search |
| `d2-signalloom/apps/dashboard-signalloom/src/pages/AgentDetailPage.tsx` | Bound `externalEvidence` loading into dossier and passed to `AgentActivityTab` |
| `d2-signalloom/apps/dashboard-signalloom/src/components/AgentActivityTab.test.tsx` | Added mock helpers and 5 comprehensive external evidence test cases |
| `Makefile` | Added `demo-agentmaxxing-ui-test` target |
| `docs/signalloom/amxo-p6-1-evidence.md` | Verification and architecture proof artifact |
