---
created: 2026-09-12
reviewers:
  - "#stefan-prodan"
  - "#tom-cope"
capabilities:
  - "#cap-architecture"
  - "#cap-golang"
  - "#cap-kubernetes"
  - "#cap-devops"
  - "#cap-threat-modelling"
  - "#cap-documentation"
practice:
  - Cloud Native Transformation & DevSecOps
  - GitOps & Continuous Delivery
url:
forecastProjectId:
forecastProjectName:
forecastProjectUrl:
obsidianProject: "1. Projects/2026-09-signalloom-feeds-and-frostdb-explorer/"
parentProposal: "[[Proposal — Signal Loom Baseline Integration & 3-Tier Navigation Reconciliation (2026-Q3)]]"
enhancements:
tags:
  - innovation-proposals
  - proposal-2026-q3-signalloom-feeds-and-frostdb-explorer
aliases:
  - "#proposal-2026-q3-signalloom-feeds-and-frostdb-explorer"
---
# Proposal — Signal Loom Feeds & FrostDB Explorer (2026-Q3)

|  |  |
| :---: | :---- |
| Proposer & Date: | AJM (2026-09-12) |
| Reviewer & Date: |  |
| Approver & Date: |  |

## Press Release

ControlPlane today announced the Signal Loom Feeds & FrostDB Explorer, a dedicated administrative discovery, multi-dimensional slicing, and columnar query console for real-time autonomous AI agent telemetry.

Modern autonomous agents generate dense, heterogeneous operational telemetry across disparate infrastructure layers: kernel eBPF socket connections, SPIRE SVID issuances, OpenBao credential access, SaaS workspace actions, and Landlock LSM sandbox syscall denials. In traditional security information architectures, these feeds disappear into opaque relational rows or high-latency log aggregators. Administrators are left asking basic questions: *Which collectors are actually feeding the engine? Where are our structural blind spots? What is the real-time ingress rate across our security layers?*

The Signal Loom Feeds & FrostDB Explorer solves this by giving operators direct discoverability and interactive explorability into the underlying immutable FrostDB columnar store. Rather than inspecting static summaries, administrators can slice and dice millions of observations across 6 signal layers, 4 evidence fidelity tiers (`definitive`, `strong`, `suggestive`, `circumstantial`), and active agent identities. With native FrostDB query pushdown simulation, interactive temporal volume histograms, live SSE stream tailing, and deep Arrow record batch inspection—including cryptographic Witness signatures and Landlock audit hash chains—Signal Loom transforms opaque telemetry into actionable, verifiable governance intelligence.

### Prior art, stated up front

| Source | What it already says |
| :---- | :---- |
| PolarSignals FrostDB | Columnar, append-only store backed by Apache Arrow and Parquet; achieves order-of-magnitude faster scans via projection and predicate pushdown |
| Honeycomb / BubbleUp | High-cardinality exploratory analysis requires interactive multidimensional faceting rather than static pre-computed dashboards |
| Grafana Loki / Live Tail | Real-time SSE streaming of ingested events is essential for operator situational awareness during active debugging or incident triage |
| in-toto Witness Attestation | Stored telemetry segments must be cryptographically attested at write-time to prevent post-hoc tampering |

## Proposal Overview

### Opportunity

**The work relates to the following value area(s):**

- [x] client revenue
- [x] product
- [x] services engineering
- [x] process efficiency
- [x] operational or regulatory internal

**Key Customers (if relevant):**

Enterprise CISOs, SOC leads, and platform administrators governing multi-agent swarms in high-assurance environments (financial services, defence, regulated SaaS).

|  |  |
| :---- | :---- |
| Our *administrators and security analysts* | Enterprise Security Architects and AI Swarm Operators |
| Have the problem/opportunity *…* | Cannot easily discover active data feeds, assess ingestion rates, or explore raw columnar observations to debug agent anomalies or verify evidence fidelity |
| When *…* | Auditing agent behaviour, investigating provisional actors, tuning correlation rules, or inspecting Landlock LSM audit events |

**What’s the urgency of this work (e.g. QX 202X), and does this comprise other subcomponents of projects?**

**Urgent for Q3 2026.** Following the delivery of SFAS Phase 1–4, administrators require visual discoverability and interactive query tools to validate collector outputs and demonstrate governance integrity to enterprise evaluators.

## Scope Summary

Technology Readiness Level Focus: **2 (Alpha)** progressing to **3 (Beta)**. Extends existing `signal-ingest` backend APIs and `SignalStorePage.tsx` into a comprehensive, production-grade exploratory console at `/feeds`.

### In Scope Activities

| Deliverable | Description | Acceptance Criteria (SMART) | Validation Method |
| :---- | :---- | :---- | :---- |
| 1. Feed Catalog & Collector Health Surface | Overview cards for all 6 signal layers and registered collectors (`ebpf`, `spirea`, `baoaudit`, `workspacesaas`, `agentnono`, `gcpaudit`) | Specific: Display mode (`live`/`fixture`/`off`), operational health, ingress rate (eps), total volume, and last ingestion timestamp<br/>Measurable: 100% of registered collectors reflected; coverage blind spots from `/api/v1/coverage` displayed<br/>Attainable: Backed by `GET /api/v1/store/stats` and `/api/v1/coverage`<br/>Realistic: Reuses established DashKit components<br/>Time-Bound: Completed in Sprint 1 | Vitest component test, API integration test |
| 2. Multidimensional Slicing & Dicing | Interactive facet filters and temporal ingestion density histogram | Specific: Filter by layer, fidelity (`definitive` to `circumstantial`), source, actor/agent ID, and time window; interactive time-bucket histogram brushes query bounds<br/>Measurable: Table updates within <100ms on facet toggle; reflects accurate observation counts<br/>Attainable: Client-side URL query state with debounced API queries<br/>Realistic: Standard enterprise log/telemetry UX<br/>Time-Bound: Completed in Sprint 1 | Playwright acceptance spec, user interaction tests |
| 3. FrostDB Columnar Query Workbench | Pushdown query builder and Parquet/Arrow schema inspector | Specific: Interactive UI for projection pushdown (column toggles) and predicate pushdown (`logicalplan.Filter(...)`) with syntax-highlighted Go/Arrow code preview<br/>Measurable: Formulates valid queries passed to `signal-ingest`; displays pushdown efficiency stats<br/>Attainable: Modelled directly on FrostDB's `logicalplan` API<br/>Realistic: Demystifies columnar engine performance for admins<br/>Time-Bound: Completed in Sprint 2 | Automated unit tests, pushdown equivalence tests |
| 4. Columnar Observation Drawer & Live Stream | Tabular observation inspector with slide-out JSON/evidence drawer and SSE live stream toggle | Specific: Connect to `/api/v1/observations/stream` with live pulse; clicking row displays raw evidence ref, Landlock ABI, nono SHA-256 hash chain, and GitOID signature<br/>Measurable: Streams incoming events without memory leaks; renders cryptographic audit proofs<br/>Attainable: Native `EventSource` with reconnect handling<br/>Realistic: Essential for live agent observation<br/>Time-Bound: Completed in Sprint 2 | Playwright SSE stream test, memory leak audit |
| 5. Admin Action Controls | Interactive controls to trigger correlation runs, seed test fixtures, and export datasets | Specific: "Run Correlation Engine" and "Seed Fixtures" action buttons with live status notifications and JSON/CSV export<br/>Measurable: Executes `POST /api/v1/correlate` and `POST /api/v1/collectors/seed` with visual feedback<br/>Attainable: Backed by existing `weaveApi` client methods<br/>Realistic: Vital for demo sandboxes and offline analysis<br/>Time-Bound: Completed in Sprint 2 | Vitest action tests, contract tests |

### Out of Scope

* Writing direct arbitrary SQL against Postgres (queries target FrostDB via `signal-ingest`).
* Modifying eBPF kernel bytecode or Tetragon CRDs.
* Re-implementing FrostDB compaction algorithms in the browser.

### KPIs

| Metric | Current Value | Target Value | Measurement |
| :---- | :---- | :---- | :---- |
| Feed Discoverability | 0 visual feed status indicators | 6 layers + 8 collectors fully visualised | UI collector cards on `/feeds` |
| Filter Latency | Unfilterable (static 50 rows) | <100ms interactive filter latency | DevTools performance recording |
| Evidence Inspection Depth | Truncated description text | Full Landlock digest, GitOID, and labels map | Inspection drawer inspection |
| Stream Ingestion Latency | Manual page refresh | <500ms from ingest to UI stream render | SSE end-to-end telemetry |

### 3rd Party Test Plan and Quality Assurance

| Validation | Method | Owner |
| :---- | :---- | :---- |
| Component Unit Tests | Vitest across `FeedsExplorerPage.test.tsx` (mocking `weaveApi`) | Services Engineering |
| Live Ingestion & Filter Spec | Playwright acceptance spec verifying filtering, histogram brushing, and drawer opening | Quality Assurance |
| Stream Stability & Memory Audit | Chrome DevTools memory leak audit verifying bounded DOM size during SSE streaming | Platform Engineering |
| API Route Liveness | BATS test verifying `/api/signals/observations` and `/api/signals/store/stats` proxying | DevSecOps Lead |

## Technical Overview

#### Technologies

| Technology | Purpose | Alignment |
| :---- | :---- | :---- |
| React 18 & TypeScript 5.6 | Exploratory UI components and typed models | Signal Loom standard |
| PolarSignals FrostDB (Go) | Embedded columnar observation store (Parquet/Arrow) | In-cluster core store |
| Server-Sent Events (SSE) | Real-time observation stream delivery | Lightweight, HTTP/1.1-compatible streaming |
| Apache Arrow Go / Parquet | Columnar memory format and storage persistence | Native FrostDB engine components |

#### Infrastructure and Repositories

| Asset | Location | Notes |
| :---- | :---- | :---- |
| Signal Ingest Service | `d2-signalloom/apps/signal-ingest` | Go service hosting FrostDB and collectors |
| Frontend API Gateway | `d2-signalloom/apps/fe-signalloom` | FastAPI proxying `/api/signals/*` to Go backend |
| Dashboard SPA | `d2-signalloom/apps/dashboard-signalloom` | React SPA hosting the `/feeds` page |

#### Security and Risk

**Threat model for this deliverable:**

| Threat | Impact | Mitigation |
| :---- | :---- | :---- |
| Telemetry Injection / Spoofing | Adversary pushes counterfeit observations to confuse administrator | Layer 4 observations require signed Nono audit session tokens and verified hash chains; L2 requires valid SPIRE SVIDs |
| Stream Exhaustion / Browser Denial-of-Service | High-volume live stream floods browser memory and locks UI thread | UI maintains a bounded ring buffer (e.g. max 500 in-memory streaming events) with virtualised table rendering |
| Information Disclosure via Raw Labels | Observation labels leak sensitive host paths or environment secrets | API filters sensitive tokens; client renders raw evidence in a secure, role-gated admin drawer |

**SWOT:**

| Strengths | Weaknesses |
| :---- | :---- |
| High-performance columnar backend already active; rich collector data models in place | Large volume of streaming events requires strict UI virtualization and state bounding |

| Opportunities | Threats |
| :---- | :---- |
| Differentiates Signal Loom as the premier observable agent governance platform with transparent evidence | Unclear UX if columnar pushdown concepts are not presented with intuitive previews |

## Milestones and Deliverables

| Milestones Committed To | Duration (days) | Consultants | Person-days | Deadline | Capability Mapping |
| :---- | :---- | :---- | :---- | :---- | :---- |
| M1: API Client Extensions (SSE, Range Query, Collector Status) & Feed Catalog Surface |  |  |  |  | #cap-architecture, #cap-golang |
| M2: Multidimensional Slicing & Dicing Workbench with Temporal Histogram |  |  |  |  | #cap-devops, #cap-architecture |
| Mid-project review: demo of live stream, facet filtering, and pushdown query builder | 0.25 | 2 | 0.5 |  | #cap-project-management |
| M3: FrostDB Pushdown Query Workbench & Arrow Record Inspection Drawer |  |  |  |  | #cap-golang, #cap-threat-modelling |
| M4: Acceptance Testing, Performance Profiling, and Monorepo Integration Signoff |  |  |  |  | #cap-devops, #cap-documentation |
| Signoff |  |  |  |  | #cap-architecture |

**Total Estimated Effort**: *to be estimated with team*

**Definition of done:**
* `/feeds` route live and accessible under **View** in the 3-tier sidebar.
* Feed catalog accurately reports status of all 6 layers and registered collectors.
* Administrators can filter by layer, fidelity, source, actor, time range, and free text.
* FrostDB pushdown queries generate valid code previews and pushdown parameters.
* Clicking an observation row reveals the full Arrow record batch metadata, Landlock verification status, and hash chain.
* Live SSE streaming runs smoothly with zero DOM or memory leakage.
* Unit tests (`FeedsExplorerPage.test.tsx`) and Playwright acceptance specs pass 100%.

### Reviews & Collaboration (RACI)

|  |  |
| :---- | :---- |
| Accountable | Lead AI Systems Architect |
| Responsible | Core Dashboard & Telemetry Engineering Team |
| Consulted | Stefan Prodan, Tom Cope |
| Informed | [Andrew Martin](mailto:andy@control-plane.io), [Elena Mikhalina](mailto:elena.mikhalina@control-plane.io) |

## Finances

### Additional costs

| Additional Cost | Estimated Spend | One Off or Recurring | Must-Have or Nice-to-Have |
| :---- | :---- | :---- | :---- |
| Storage volume for FrostDB Parquet persistent bucket | £0 (mounted inside Kind/GCP VM) | Recurring | Must-Have |

# Decision Log

| Date | Decision Makers | Decision and context | Reason | Impact |
| :---- | ----- | ----- | ----- | ----- |
| 2026-09-12 | AJM, Architecture Team | Dedicate `/feeds` as the primary discovery & explorability page; retain `/signal-store` for low-level diagnostics | Clean separation of concerns between operational telemetry exploration and storage engine health | Clear, role-appropriate information architecture |
| 2026-09-12 | AJM, Telemetry Team | Bound client-side streaming buffer to 500 records | Prevents browser UI thread freezing during high-rate eBPF burst ingestion | Guarantees fluid 60fps operator experience |

## Appendix

### A. Useful Links
* [`d2-signalloom/apps/signal-ingest/store/frostdb.go`](file:///home/andy/src/cp/osramp-demo/d2-signalloom/apps/signal-ingest/store/frostdb.go)
* [`d2-signalloom/apps/signal-ingest/api/handlers.go`](file:///home/andy/src/cp/osramp-demo/d2-signalloom/apps/signal-ingest/api/handlers.go)
* [`d2-signalloom/apps/dashboard-signalloom/src/api/weaveApi.ts`](file:///home/andy/src/cp/osramp-demo/d2-signalloom/apps/dashboard-signalloom/src/api/weaveApi.ts)

## Auto Kanban Mission Specifications

### Spec: Shared Patterns — Phase 1

* **SP-1: FrostDB Predicate and Projection Pushdown Filtering**
  All query parameters (`after`, `before`, `layers`, `actor_id`, `limit`) must translate directly into PolarSignals FrostDB `logicalplan.Filter` constraints and projection schemas in `signal-ingest`, avoiding full table scans.
* **SP-2: Resilient SSE Live Streaming with Ring-Buffer Bound**
  Live observation streaming at `/api/v1/observations/stream` connects via browser `EventSource` with exponential backoff on reconnection and `Last-Event-ID` offset resume. The client-side table/buffer is strictly capped at 500 records to prevent memory leaks and maintain 60fps rendering.
* **SP-3: Standard DashKit Visual Language & CSS Custom Properties**
  All card containers, metrics badges, and tables must use declared `--surface`, `--muted`, `--accent`, and `--border` variables without hardcoded hex colors.
* **SP-4: Cryptographic Evidence & Hash Chain Transparency**
  Observation inspection drawer must display complete evidence references: in-toto Witness signatures, Landlock LSM syscall audit digests, GitOIDs, and multi-layer provenance hashes.
* **SP-5: Deep URL Query Synchronization**
  Active filters (layer selection, fidelity tier, actor, time range) are mirrored in URL search parameters (`?layer=...&fidelity=...`) to enable shareable deep links.

### Spec: Capability Plan

| Card ID | Title | Primary Skill | Role | Size | Ceiling | Dependencies |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| `SLFE-P1-PRE` | Preflight Verification & FrostDB Telemetry Contracts | `skills/cp-platform` | Platform Engineer | XS | 15m | None |
| `SLFE-P1-1` | Ingestion Proxy & Backend Stream Extension | `skills/cp-backend` | Backend Engineer | S | 30m | `SLFE-P1-PRE` |
| `SLFE-P1-2` | Feeds & Collector Catalog Health Cards | `skills/cp-frontend` | Frontend Engineer | M | 45m | `SLFE-P1-PRE` |
| `SLFE-P1-3` | Multidimensional Slicing, Dicing & Histogram Filter Bar | `skills/cp-frontend` | UI Architect | L | 60m | `SLFE-P1-2` |
| `SLFE-P1-4` | FrostDB Pushdown Query Workbench & Schema Inspector | `skills/cp-data` | Data Systems Specialist | M | 45m | `SLFE-P1-3` |
| `SLFE-P1-5` | Real-Time SSE Ingestion Stream & Arrow Record Drawer | `skills/cp-frontend` | Real-Time Systems Lead | M | 45m | `SLFE-P1-1`, `SLFE-P1-3` |
| `SLFE-P1-6` | Route, Sidebar & Test Registry Integration | `skills/cp-frontend` | Frontend Engineer | S | 30m | `SLFE-P1-3` |
| `SLFE-P1-GOV` | Whole-Suite Acceptance, Playwright Spec & Memory Leak Audit | `skills/cp-governor` | Quality Governor | M | 45m | `SLFE-P1-4`, `SLFE-P1-5`, `SLFE-P1-6` |

### Spec: Work Decomposition

| ID | Title | Depends on | Tests / evidence | Size | Agent | Result | Est. Cost | Tokens | Elapsed | AI URI |
| :---- | :---- | :---- | :---- | :---- | :---- | :---- | :---- | :---- | :---- | :--- |
| SLFE-P1-PRE | Preflight Verification & FrostDB Telemetry Contracts | | Ingestion endpoints respond with valid schemas; preflight report committed to `docs/signalloom/slfe-preflight-proof.md` | XS | antigravity | complete | $0.02 | 4,200 | 8m | agy://slfe-p1-pre |
| SLFE-P1-1 | Ingestion Proxy & Backend Stream Extension | SLFE-P1-PRE | Query parameters forwarded without truncation; SSE streaming proxy streams events without socket hangup | S | antigravity | complete | $0.05 | 9,800 | 18m | agy://slfe-p1-1 |
| SLFE-P1-2 | Feeds & Collector Catalog Health Cards | SLFE-P1-PRE | Renders status for 6 collectors; visual warning badges for unmonitored layers or blind spots | M | antigravity | complete | $0.08 | 15,200 | 25m | agy://slfe-p1-2 |
| SLFE-P1-3 | Multidimensional Slicing, Dicing & Histogram Filter Bar | SLFE-P1-2 | Filter changes trigger debounced queries; URL search parameters stay synchronized; histogram displays interactive time buckets | L | antigravity | complete | $0.12 | 22,500 | 38m | agy://slfe-p1-3 |
| SLFE-P1-4 | FrostDB Pushdown Query Workbench & Schema Inspector | SLFE-P1-3 | Displays interactive code snippet; verifies pushdown filter syntax; shows scan efficiency telemetry | M | antigravity | complete | $0.08 | 16,100 | 28m | agy://slfe-p1-4 |
| SLFE-P1-5 | Real-Time SSE Ingestion Stream & Arrow Record Drawer | SLFE-P1-1, SLFE-P1-3 | Live stream renders incoming records up to 500-item ring buffer bound without memory leaks; drawer renders full cryptographic proof tree | M | antigravity | complete | $0.09 | 18,400 | 32m | agy://slfe-p1-5 |
| SLFE-P1-6 | Route, Sidebar & Test Registry Integration | SLFE-P1-3 | Route accessible via sidebar and hotkey 5; BATS coverage guard passes 7/7 | S | antigravity | complete | $0.04 | 7,600 | 14m | agy://slfe-p1-6 |
| SLFE-P1-GOV | Whole-Suite Acceptance, Playwright Spec & Memory Leak Audit | SLFE-P1-4, SLFE-P1-5, SLFE-P1-6 | Playwright spec passes; memory profile confirms flat memory usage during 60s stream; Governor sign-off ledger committed | M | antigravity | complete | $0.06 | 12,000 | 22m | agy://slfe-p1-gov |

### Spec: Errata

*(Append-only record of completed cards, deviations, and governor certifications)*

#### Governor Dispatch — SLFE-GOV-INIT
- **Timestamp**: 2026-09-12T13:28:00Z
- **Actor**: Governor (Mission Initialization)
- **Status**: active
- **Digest**: `slfe-feeds-and-frostdb-explorer-init`
- **Inter-Agent Directive**: All task agents must execute under `--agent antigravity`. The live streaming buffer is capped at 500 records (SP-2). All task completions, deviations, and blockers must be recorded in this errata ledger.

#### Governor Dispatch — SLFE-GOV-PASS
- **Timestamp**: 2026-09-12T14:52:00Z
- **Actor**: Governor (Phase 1 Certification)
- **Status**: complete
- **Digest**: `slfe-feeds-and-frostdb-explorer-pass`
- **Certification Verdict**: CERTIFIED_PASS. Feeds & FrostDB Explorer console fully implemented and integrated across frontend (`/feeds`), backend (`/api/signals/observations/stream`), and test suites (162/162 vitest files passed, BATS coverage passed 7/7). Proof committed to `docs/signalloom/slfe-p1-governor-proof.md`.



