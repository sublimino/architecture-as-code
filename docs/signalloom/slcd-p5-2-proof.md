# SLCD-P5-2 — Render Detected Coding Agents in Dashboard Topology and Agent Swarm Views

**Status:** PASS — Phase 5-2 Complete & Verified  
**Certified at:** 2026-09-15 11:40:00+01:00  
**Role:** implementation  
**Task ID:** `c4a71` (`SLCD-P5-2`)  
**Mission:** Signal Loom Coding Agent Telemetry (SLCD)  
**Effort Tier:** E4  

---

## 1. Executive Summary

`SLCD-P5-2` delivers complete dashboard visualization for detected autonomous coding agents across the **Signal Loom Dashboard** (`d2-signalloom/apps/dashboard-signalloom`), bridging external workstation detective telemetry (`agentmaxxing-host-sensor`, `signal-ingest`, `fe-signalloom-api` BFF) into the user interface with zero customer payload exposure.

Prior to `SLCD-P5-2`, the dashboard rendered only in-cluster microservices and governed cloud workloads. With `SLCD-P5-2`, operators gain full observability of active and historical autonomous developer agents (`claude`, `antigravity`, `codex`, `cpai`, `opencode`, `hermes`, `aider`) on workstations with:
1. **Dedicated Coding Agents Tab (`CodingAgentsTab.tsx`)** on `/agents?tab=coding-agents`:
   - Summary stat cards (`Active Coding Agents`, `Total Token Egress`, `Tool Invocations`, `Detected Workstations`).
   - Multi-facet search and filtering by harness, Kanban role (`implementation`, `research`, `testing`, `governor`, `refactor`), and task ID.
   - Real-time live polling (`api.codingAgents.list` and `api.codingAgents.aggregate`).
2. **Rich Coding Agent Telemetry Card (`CodingAgentCard.tsx`)**:
   - Distinct harness badge, icon, and comm/PID tags (`comm: claude (PID: 104231)`).
   - Kanban task integration (task ID, shortcode, role badge, step count, elapsed duration).
   - Token throughput metrics (`tokens_in`, `tokens_out`, combined throughput).
   - Host process resource metrics (formatted memory RSS in MB/GB, CPU ticks).
   - Inferred network egress endpoints (`api.anthropic.com`, `generativelanguage.googleapis.com`, etc.) and bandwidth counters.
   - Proportional stacked tool invocation histogram ratio bar and individual tool counters for 13 standard tool actions (`view_file`, `replace_file_content`, `run_command`, `grep_search`, `list_dir`, etc.).
   - Explicit **"Zero Customer Payload"** assurance chip certifying privacy compliance.
   - Server-side clock skew indicator (`clock_skew_ms`).
3. **Trust Topology Integration (`AgentTrustTopologyPage.tsx`)**:
   - Detected workstation agents modeled as external nodes within the Acme Payments and Acme Risk boundaries (`claude-workstation`, `antigravity-workstation`).
   - Observed detective telemetry edges connected to parent projects with k-anonymity ($k \ge 5$) assurance and Zero Customer Payload proof.
   - Clean separation of the external half-plane band from in-cluster boundaries.
4. **Demo Mode & API Proxy Resilience**:
   - 4 new demo routes in `fakeData.ts` and `fakeCodingAgentData.ts` delivering 7 realistic fixture records spanning all supported harnesses and roles.
   - Full API client methods in `client.ts` (`api.codingAgents.list`, `aggregate`, `ordering`, `ingest`).

---

## 2. Invariant & Privacy Compliance

### 2.1 Zero Customer Payload Invariant
Under no circumstances does the UI render raw code snippets, prompt texts, diff chunks, or memory payloads. The frontend architecture strictly binds to the metadata layer:
- **Process Attributes:** Process name (`comm`), Process ID (`pid`), parent process, and host ID.
- **Resource Footprint:** Resident Set Size (`rss_bytes`), CPU ticks.
- **Execution Telemetry:** Aggregated tool counters (`tool_counts`), step count, token throughput (`tokens_in`, `tokens_out`).
- **Kanban Envelope:** Task ID, role, shortcode, elapsed time.
- **Network Attribution:** Inferred destination domain (e.g. `api.anthropic.com`) and egress bytes.

### 2.2 Visual Consistency & DashKit
All components adopt the standard Signal Loom design system tokens (`var(--cyan)`, `var(--violet)`, `var(--teal)`, `var(--amber)`, `var(--surface)`, `var(--border)`), `StatCard`, `EmptyState`, and `LoadingState` without introducing bespoke or discordant styling.

---

## 3. Test Suite Verification

All unit, contract, integration, and topology tests pass with 100% success rate:

```bash
# 1. Full vitest suite across entire dashboard (182 files, 3389 tests)
bun run test --run
# Result: 182 test files passed, 3389 tests passed (0 failed, 3 skipped)

# 2. Focused Coding Agent Suites
bun run test --run \
  src/components/CodingAgentCard.test.tsx \
  src/components/CodingAgentsTab.test.tsx \
  src/pages/AgentsPage.codingAgents.test.tsx \
  src/api/codingAgentsClient.test.ts \
  src/api/demoMode.test.ts \
  src/pages/AgentTrustTopologyPage.test.tsx \
  src/pages/AgentsPage.test.tsx
# Result: 7 test files passed, 96 tests passed (0 failed)

# 3. TypeScript Typecheck
bun run typecheck (tsc --noEmit)
# Result: Exit 0 (0 errors)

# 4. ESLint Check on Modified & New Files
bunx eslint \
  src/types/codingAgent.ts \
  src/api/fakeCodingAgentData.ts \
  src/api/fakeData.ts \
  src/api/client.ts \
  src/components/CodingAgentCard.tsx \
  src/components/CodingAgentsTab.tsx \
  src/pages/AgentsPage.tsx \
  src/pages/AgentTrustTopologyPage.tsx \
  src/components/CodingAgentCard.test.tsx \
  src/components/CodingAgentsTab.test.tsx \
  src/pages/AgentsPage.codingAgents.test.tsx \
  src/api/codingAgentsClient.test.ts
# Result: Exit 0 (0 errors)
```

---

## 4. Deliverable File Artifacts

| File | Purpose |
|:---|:---|
| `src/types/codingAgent.ts` | Complete TypeScript domain models matching Go schemas (`CodingAgentTelemetry`, `StoredRecord`, `AggregateResult`, etc.) |
| `src/types/api.ts` | Re-exports coding agent domain models for the unified API surface |
| `src/api/fakeCodingAgentData.ts` | 7 realistic demo fixtures spanning all supported harnesses, roles, tool histograms, and network endpoints |
| `src/api/fakeData.ts` | Mock route registrations for `/api/v1/telemetry/coding-agents` |
| `src/api/client.ts` | `api.codingAgents` (`list`, `aggregate`, `ordering`, `ingest`) API client implementation |
| `src/components/CodingAgentCard.tsx` | Visual card component with metrics, tool histograms, Kanban strip, and Zero Customer Payload chip |
| `src/components/CodingAgentsTab.tsx` | Tab component with live polling, stat cards, search filters, and card grid |
| `src/pages/AgentsPage.tsx` | Subnavigation tab switcher ("Governed Workloads" vs "Detected Coding Agents") |
| `src/pages/AgentTrustTopologyPage.tsx` | External workstation node and telemetry edge mapping in Trust Topology graph |
| `src/components/CodingAgentCard.test.tsx` | Unit tests for `CodingAgentCard` across all harnesses |
| `src/components/CodingAgentsTab.test.tsx` | Unit tests for `CodingAgentsTab` filtering, search, and empty states |
| `src/pages/AgentsPage.codingAgents.test.tsx` | Integration test for tab switching and rendering in `AgentsPage` |
| `src/api/codingAgentsClient.test.ts` | API client test for telemetry list, aggregate, and ordering |
| `docs/signalloom/slcd-p5-2-proof.md` | This architectural proof document |
| `ISA.md` | Up-to-date ISA system of record for `SLCD-P5-2` |
