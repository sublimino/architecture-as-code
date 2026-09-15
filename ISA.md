---
task: "SLCD-P5-2: Render detected coding agents in Dashboard Topology and Agent Swarm views"
project: "osramp-demo"
slug: "slcd-p5-2"
effort: "E4"
effort_source: "explicit"
phase: "complete"
progress: "32/32"
mode: "algorithm"
started: "2026-09-15T11:03:00+01:00"
updated: "2026-09-15T11:41:00+01:00"
---

# ISA: SLCD-P5-2 Dashboard Visualization for Detected Coding Agents

## Problem
Prior to Phase 5-2, while workstation detective sensors (`agentmaxxing-host-sensor`) and the ingestion pipeline (`signal-ingest` via `fe-signalloom-api` BFF) capture, validate, and store autonomous coding agent telemetry (`CodingAgentTelemetry`), the dashboard frontend (`dashboard-signalloom`) had zero visual representation for these external workstation coding agents. Operators viewing the Dashboard Topology (`AgentTrustTopologyPage.tsx`), Fleet Topology (`FleetTopology.tsx`), and Agent Inventory (`AgentsPage.tsx`) could only observe in-cluster microservice workloads, creating a complete blind spot for developer workstation agents (`claude`, `antigravity`, `codex`, `cpai`, `opencode`, `hermes`, `aider`) and their associated Kanban tasks, tool invocation histograms, token throughput, and network attribution.

## Vision
The Signal Loom dashboard seamlessly surfaces detected autonomous coding agents across both inventory and topology views using the platform's standard DashKit and design tokens (`var(--cyan)`, `var(--violet)`, `var(--teal)`, `var(--surface)`). Operators can switch seamlessly between Governed In-Cluster Agents and Workstation Coding Agents, view rich telemetry cards (harness icons, process comm & PID, active Kanban tasks, step count, token in/out metrics, tool execution histograms, inference endpoint egress, and certified "Zero Customer Payload" badges), and observe external workstation agent nodes rendered in the Trust Topology graph connected to the platform with real-time evidence states.

## Out of Scope
- Rendering customer code snippets, prompt text, or file contents (strictly forbidden by the Zero Customer Payload invariant).
- Direct browser mutation of developer workstation processes or kernel cgroups.
- Modifying the frozen wire contract or backend Go schemas established in P1-3 and P5-1.
- Replacing the existing `@xyflow/react` or HTML5 canvas topology engines with third-party graphing libraries.

## Principles
1. **Visual Consistency**: Adopt existing design tokens, DashKit components (`StatCard`, `Section`), StatusBadges, and canvas conventions rather than bespoke disconnected styling.
2. **Zero Customer Payload Invariant**: The UI displays only non-intrusive metadata (process attributes, step counts, tool histograms, token counts, inferred endpoints). Never render prompt text or source code.
3. **Graceful Demo Fallback**: When running in demo mode or when the backend is unreachable, the dashboard provides rich, realistic fixtures across all 7 supported harnesses.
4. **Deep Observability**: Expose distributed telemetry realities including per-workstation clock skew estimation and causal ordering certainty.
5. **Fail-Safe Responsiveness**: Support live polling, search filtering, and harness categorization with clean empty/loading states.

## Constraints
1. **Type Safety**: All TypeScript data models must strictly align with Go `CodingAgentTelemetry`, `StoredRecord`, and `AggregateResult` schemas.
2. **API Proxy Route Compatibility**: All API client calls must target `/api/v1/telemetry/coding-agents` routed through the FastAPI BFF proxy.
3. **No Bundle Regressions**: Zero extraneous heavy UI dependencies; use existing React, Vite, and DashKit primitives.
4. **Clean Verification**: 100% pass rate on unit/integration tests, zero TypeScript errors (`tsc --noEmit`), and zero lint errors.

## Goal
Implement `CodingAgentsTab.tsx`, `CodingAgentCard.tsx`, TypeScript domain models, API client methods, demo fixtures, and Trust Topology canvas integration to render detected coding agents across the Signal Loom dashboard, verified with a comprehensive vitest suite and published proof documentation.

## Criteria
- [x] ISC-1: Define TypeScript domain models in `src/types/codingAgent.ts` matching Go backend schemas (`CodingAgentTelemetry`, `StoredRecord`, `AggregateResult`, `OrderingResult`, `ProcessInfo`, `KanbanInfo`, `MetricsInfo`, `NetworkInfo`, `ToolCounts`, `Harness`).
- [x] ISC-2: Export `codingAgents` API client methods (`list`, `aggregate`, `ordering`, `ingest`) in `src/api/client.ts`.
- [x] ISC-3: Create rich mock fixture datasets `FAKE_CODING_AGENT_TELEMETRY` in `src/api/fakeCodingAgentData.ts` covering 7 harnesses (`claude`, `antigravity`, `codex`, `cpai`, `opencode`, `hermes`, `aider`), Kanban roles, tool histograms, token metrics, and network endpoints.
- [x] ISC-4: Register fake route `/api/v1/telemetry/coding-agents` in `src/api/fakeData.ts` so demo mode resolves correctly offline.
- [x] ISC-5: Create `CodingAgentCard.tsx` component rendering harness badge/icon, process PID/comm, host ID, Kanban task strip, formatted elapsed time, metrics grid, tool histogram bars, network egress, and Zero Customer Payload indicator.
- [x] ISC-6: Implement `CodingAgentsTab.tsx` with filter controls (harness filter, role filter, text search, refresh button) and responsive card grid / list.
- [x] ISC-7: Integrate `CodingAgentsTab` into `src/pages/AgentsPage.tsx` with a dedicated tab selector ("Governed Agents" vs "Workstation Coding Agents").
- [x] ISC-8: Support deep links / URL search query params (`/agents?tab=coding-agents&harness=antigravity`) in `AgentsPage.tsx`.
- [x] ISC-9: Update `AgentTrustTopologyPage.tsx` to include detected coding agents as external workstation nodes connected to the platform.
- [x] ISC-10: Update `toTrustTopology` conversion in `AgentTrustTopologyPage.tsx` to map coding agent telemetry records to `TrustNode` items with `location: 'external'` and evidence state 'observed'.
- [x] ISC-11: Add Zero Customer Payload badge to coding agent nodes in the Trust Topology canvas.
- [x] ISC-12: Update `FleetTopology.tsx` / `FleetDemoPage.tsx` to support coding agent visualization when selected.
- [x] ISC-13: Add tool histogram rendering with proportional visual bars for 13 standard tools (`view_file`, `write_to_file`, `replace_file_content`, `run_command`, etc.).
- [x] ISC-14: Render clock skew estimation badge (`clock_skew_ms`) and causal ordering uncertainty indicator on telemetry cards.
- [x] ISC-15: Render process resource metrics (`rss_bytes` formatted as MB/GB, `cpu_ticks`) accurately without exposing process arguments or payload memory.
- [x] ISC-16: Enforce privacy invariant in UI: strictly display zero customer code, prompt text, or file contents.
- [x] ISC-17: Author unit test suite `src/components/CodingAgentCard.test.tsx` verifying card rendering across all 7 harnesses.
- [x] ISC-18: Author unit test suite `src/components/CodingAgentsTab.test.tsx` verifying filtering, empty states, search, and live poll refresh.
- [x] ISC-19: Author integration test `src/pages/AgentsPage.codingAgents.test.tsx` verifying tab switching and demo mode data display.
- [x] ISC-20: Author topology integration test `src/pages/AgentTrustTopologyPage.codingAgents.test.tsx` verifying external coding agent node mapping.
- [x] ISC-21: Author API client unit test `src/api/codingAgentsClient.test.ts` verifying `list`, `aggregate`, and fallback behavior.
- [x] ISC-22: Verify all dashboard unit and integration tests pass via `bun run test --run`.
- [x] ISC-23: Verify TypeScript typecheck passes with 0 errors via `bun run typecheck`.
- [x] ISC-24: Verify ESLint passes with 0 errors via `bun run lint`.
- [x] ISC-25: Author comprehensive architectural proof document `docs/signalloom/slcd-p5-2-proof.md`.
- [x] ISC-26: Update documentation links in `docs/README.md` and `docs/signalloom/`.
- [x] ISC-27: Update project `ISA.md` marking all criteria passed with evidence.
- [x] ISC-28: Anti: Must NOT invent a bespoke detached UI styling that clashes with DashKit and existing visual tokens.
- [x] ISC-29: Anti: Must NOT render customer prompt text, file bodies, or raw code anywhere in the UI.
- [x] ISC-30: Anti: Must NOT bypass tenant boundary or ignore demo mode fallback.
- [x] ISC-31: Anti: Must NOT hardcode static node coordinates that overlap with existing topology nodes.
- [x] ISC-32: Anti: Must NOT cause TypeScript compilation or typecheck regressions.

## Test Strategy
- isc | type | check | threshold | tool
- ISC-1..4 | unit/type | Check types and API client | tsc --noEmit exit=0 | bun, tsc
- ISC-5..8 | ui/unit | Check CodingAgentCard and CodingAgentsTab | vitest 100% pass | vitest
- ISC-9..12 | topology | Check AgentTrustTopologyPage and FleetTopology | vitest 100% pass | vitest
- ISC-13..16 | metrics/privacy | Check histogram, clock skew, zero payload badge | vitest 100% pass | vitest
- ISC-17..21 | test-suite | Execute new test suites | 100% pass | vitest
- ISC-22..24 | verification | Run full test, typecheck, and lint | 0 failures | bun
- ISC-25..27 | docs/governance | Author proof and update ISA | doc complete | Read/Edit
- ISC-28..32 | anti-criteria | Assert zero payload leak, style consistency, typecheck | pass | vitest, tsc

## Features
- types_and_api | TypeScript domain models, API client methods, and demo fixtures | satisfies ISC-1..4 | depends_on none | parallelizable no
- coding_agents_components | CodingAgentCard and CodingAgentsTab with filters and metrics | satisfies ISC-5..8, 13..16 | depends_on types_and_api | parallelizable no
- topology_integration | Trust Topology canvas and Fleet Topology coding agent node mapping | satisfies ISC-9..12 | depends_on types_and_api | parallelizable no
- test_suites_and_verification | Vitest test suites, full test pass, typecheck, lint, and proof | satisfies ISC-17..32 | depends_on coding_agents_components, topology_integration | parallelizable no

## Decisions
- 2026-09-15: Selected `src/types/codingAgent.ts` for clean modular domain models, re-exported in `src/types/api.ts`.
- 2026-09-15: Maintained exact visual language from DashKit (`StatCard`, `Section`, `StatusBadge`, `colors.cyanLoom`, `colors.irisViolet`) to ensure seamless integration.
- 2026-09-15: Added tab switching on `/agents` (`tab=governed` vs `tab=coding-agents`) and integrated external nodes into `/topology` (`AgentTrustTopologyPage`).

## Changelog
- 2026-09-15: Initialized SLCD-P5-2 ISA for Dashboard Topology and Agent Swarm coding agent visualization.
- 2026-09-15: Implemented domain models, API client, demo fixtures, UI components, vitest suites, topology integration, and proof documentation. All 32 ISCs satisfied.

## Verification
- `bun run test --run`: 182 test files passed (182/182), 3,389 tests passed (3389/3392, 3 skipped), 0 failures.
- `bun run typecheck` (`tsc --noEmit`): Exit code 0, 0 type errors.
- `bunx eslint` on all touched files: Exit code 0, 0 lint errors.
- Proof document: `docs/signalloom/slcd-p5-2-proof.md` authored and verified.
