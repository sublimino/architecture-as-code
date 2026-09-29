---
task: Agents Page Governance State Consolidation
slug: slms-p1-3-agent-lifecycle
effort: E3
phase: complete
progress: 36/36
mode: algorithm
started: 2026-09-29T04:15:14+01:00
updated: 2026-09-29T04:26:40+01:00
---

## Problem
Operational status terminology across the Signal Loom agent governance platform is fragmented:
1. The database stores legacy status strings ('registered', 'enrolled', 'active', 'suspended', 'stunned', 'revoked', 'decommissioned').
2. The UI and API responses expose disjoint terminology instead of the canonical 3-stage governance lifecycle: 'Governed', 'Suspended' (including Stunned), and 'Revoked'.
3. Unclaimed shadow discovery records risk leaking into operational inventory tables if not strictly filtered.
4. Suspended and Stunned agents lack clear, accessible Sentinel eBPF kernel enforcement indicators (cgroup process freeze, network drop) on their status badges.
5. User-facing strings in `AgentsPage.tsx` contain em-dashes violating repository typography rules.

## Vision
A unified, consistent 3-stage governance lifecycle ('Governed', 'Suspended', 'Revoked') across the TypeScript type contract, backend serializers, frontend operational views, and status badge components:
- Pure read-time serialization mapping without mutating stored database values.
- Strict isolation ensuring zero shadow discovery records appear in the operational table.
- Accessible eBPF kernel containment indicators on suspended/stunned agents.
- 100% clean test execution across Pytest and Vitest suites with zero em-dashes.

## Out of Scope
- Modifying discovery table columns or auto-claim actions in `pages/DiscoveryPage.tsx` (owned by P1-2).
- Updating FAIR risk exposure calculations in `pages/RiskExposurePage.tsx` (reserved for P3-3).
- Altering eBPF kernel sensor probe logic in `agentmaxxing-host-sensor`.
- Mutating stored PostgreSQL database records or executing SQL schema migrations.

## Principles
- Read-Time Governance Mapping: Database historical states remain immutable in PostgreSQL; serializers provide deterministic projection into canonical lifecycle states.
- Canonical 3-Stage Governance: Only 'Governed', 'Suspended', and 'Revoked' exist on the operational surface.
- Strict Operational Isolation: Unclaimed discovery workloads belong exclusively in `/discovery`, never in `/agents`.
- Multi-Layer Verification: TypeScript typecheck, adversarial contract tests, React Testing Library component tests, and Pytest serializer tests must all pass.
- Strict Typography Discipline: Zero em-dashes in user-facing UI text strings.

## Constraints
- TypeScript always, Bun/Bunx for frontend testing and builds.
- Conventional Commits (`feat(signalloom): consolidate agent lifecycle states`) with `--no-gpg-sign`.
- No modifications to external discovery routes or unassigned phase tasks.
- Respect all PAI, nono sandbox, and workspace boundaries.

## Goal
Deliver end-to-end agent lifecycle state consolidation across `types/api.ts`, `api_compat.py`, `AgentsPage.tsx`, `views/Agents.tsx`, and `StatusBadge.tsx`, verified with comprehensive Vitest and Pytest suites, zero em-dashes, and verified Proposal Errata.

## Criteria
- [x] ISC-1: `src/types/api.ts` exports `AgentLifecycleState = 'Governed' | 'Suspended' | 'Revoked'`.
- [x] ISC-2: `src/types/api.ts` `AgentResponse.lifecycle_state` uses `AgentLifecycleState`.
- [x] ISC-3: `src/types/api.ts` `SentinelKernelTelemetry` interface is fully typed.
- [x] ISC-4: `api_compat.py` `_agent_response_from_row` maps `'registered'` to `'Governed'`.
- [x] ISC-5: `api_compat.py` `_agent_response_from_row` maps `'enrolled'` to `'Governed'`.
- [x] ISC-6: `api_compat.py` `_agent_response_from_row` maps `'active'` to `'Governed'`.
- [x] ISC-7: `api_compat.py` `_agent_response_from_row` maps `'suspended'` to `'Suspended'`.
- [x] ISC-8: `api_compat.py` `_agent_response_from_row` maps `'stunned'` to `'Suspended'`.
- [x] ISC-9: `api_compat.py` `_agent_response_from_row` maps `'revoked'` to `'Revoked'`.
- [x] ISC-10: `api_compat.py` `_agent_response_from_row` maps `'decommissioned'` to `'Revoked'`.
- [x] ISC-11: `api_compat.py` does not mutate underlying database records during serialization.
- [x] ISC-12: `api_compat.py` includes Sentinel eBPF freeze telemetry when agent is suspended or stunned.
- [x] ISC-13: `api_compat.py` GET `/agents` endpoint filters correctly by canonical lifecycle states.
- [x] ISC-14: `api_compat.py` GET `/agents` endpoint handles missing or unknown state gracefully.
- [x] ISC-15: `pages/AgentsPage.tsx` defines `LIFECYCLE_OPTIONS` as `['all', 'Governed', 'Suspended', 'Revoked']`.
- [x] ISC-16: `pages/AgentsPage.tsx` defines `LIFECYCLE_LABELS` mapping canonical states to display labels.
- [x] ISC-17: `pages/AgentsPage.tsx` filters out discovery / shadow records (`record_class === 'discovered' | 'discovery'`) from operational table.
- [x] ISC-18: `pages/AgentsPage.tsx` renders Governed status with emerald/teal token.
- [x] ISC-19: `pages/AgentsPage.tsx` renders Suspended status with amber token and Sentinel eBPF freeze indicators.
- [x] ISC-20: `pages/AgentsPage.tsx` renders Revoked status with error/red token.
- [x] ISC-21: `pages/AgentsPage.tsx` zero em-dash count verified by grep.
- [x] ISC-22: `views/Agents.tsx` defines `LIFECYCLE_OPTIONS` or consumes canonical state definitions.
- [x] ISC-23: `components/StatusBadge.tsx` `LIFECYCLE` color map supports `'Governed'` (teal/emerald).
- [x] ISC-24: `components/StatusBadge.tsx` `LIFECYCLE` color map supports `'Suspended'` (amber).
- [x] ISC-25: `components/StatusBadge.tsx` `LIFECYCLE` color map supports `'Revoked'` (error/red).
- [x] ISC-26: `components/StatusBadge.tsx` supports eBPF lock icon / freeze indicator rendering for Suspended / Stunned states.
- [x] ISC-27: `components/StatusBadge.test.tsx` passes vitest suite with Governed/Suspended/Revoked assertions.
- [x] ISC-28: `tests/test_agent_lifecycle.py` unit tests map all 6 legacy DB values to 3 canonical states.
- [x] ISC-29: `tests/test_agent_lifecycle.py` unit tests verify eBPF telemetry inclusion for stunned/suspended agents.
- [x] ISC-30: `src/pages/AgentsPage.test.tsx` passes vitest suite with canonical lifecycle filtering.
- [x] ISC-31: `src/types/lifecycle-contract.adversarial.test.ts` exists and asserts TypeScript and runtime state invariants.
- [x] ISC-32: Anti: `_agent_response_from_row` does NOT emit legacy strings ('active', 'enrolled', 'registered') in `lifecycle_state`.
- [x] ISC-33: Anti: `AgentsPage.tsx` table does NOT render unclaimed shadow discovery workloads.
- [x] ISC-34: Anti: Zero em-dashes in `pages/AgentsPage.tsx`.
- [x] ISC-35: Vitest test suite passes with `bun run test -- --run`.
- [x] ISC-36: Pytest test suite passes with `pytest tests/test_agent_lifecycle.py`.

## Test Strategy
- ISC-1..3: TypeScript compiler `bun run typecheck`.
- ISC-4..14: Pytest suite in `apps/fe-signalloom/src/tests/test_agent_lifecycle.py`.
- ISC-15..21, 30: Vitest in `apps/dashboard-signalloom/src/pages/AgentsPage.test.tsx`.
- ISC-23..27: Vitest in `apps/dashboard-signalloom/src/components/StatusBadge.test.tsx`.
- ISC-31: Vitest in `apps/dashboard-signalloom/src/types/lifecycle-contract.adversarial.test.ts`.
- ISC-21, 34: `grep -ro '—' src/pages/AgentsPage.tsx | wc -l`.
- ISC-35: `bun run test -- --run` across all dashboard tests.
- ISC-36: `uv run python -m pytest tests/test_agent_lifecycle.py -q`.

## Features
- Feature 1: Canonical Type Definition (`types/api.ts`) | satisfies: ISC-1, ISC-2, ISC-3 | depends_on: none | parallelizable: yes
- Feature 2: Backend Serializer Mapping & Telemetry (`api_compat.py`) | satisfies: ISC-4..14, ISC-32 | depends_on: none | parallelizable: yes
- Feature 3: StatusBadge Component Enhancement (`StatusBadge.tsx`) | satisfies: ISC-23..26 | depends_on: Feature 1 | parallelizable: yes
- Feature 4: Agents Table View & Page Refactor (`AgentsPage.tsx`, `views/Agents.tsx`) | satisfies: ISC-15..22, ISC-33, ISC-34 | depends_on: Feature 1, Feature 3 | parallelizable: no
- Feature 5: Test Suites Authoring & Verification (`AgentsPage.test.tsx`, `lifecycle-contract.adversarial.test.ts`, `test_agent_lifecycle.py`, `StatusBadge.test.tsx`) | satisfies: ISC-27..31, ISC-35, ISC-36 | depends_on: Feature 1..4 | parallelizable: no

## Decisions
- 2026-09-29: Map legacy DB values ('registered', 'enrolled', 'active') to 'Governed', ('suspended', 'stunned') to 'Suspended', ('revoked', 'decommissioned') to 'Revoked' in serializer without database migration.
- 2026-09-29: Exclude `record_class === 'discovered' | 'discovery'` from the operational `/agents` table; shadow records belong exclusively in `/discovery`.
- 2026-09-29: Add optional `lockIcon` and `ebpfEnforced` props / indicators to StatusBadge for accessible visualization of Sentinel containment.

## Changelog
- 2026-09-29: Initialized ISA for SLMS-P1-3 Agent Lifecycle State Consolidation.
- 2026-09-29: Completed all 36 ISCs across types, serializers, views, status badges, and test suites.

## Verification
- TypeScript Typecheck: Passed `bun run typecheck` (0 errors)
- Vitest Suite: 193/193 test files passed (3465 passed, 3 skipped)
- Pytest Suite: 33/33 tests passed (`tests/test_agent_lifecycle.py`)
- Em-dash Grep: 0 em-dashes found in `src/pages/AgentsPage.tsx`

