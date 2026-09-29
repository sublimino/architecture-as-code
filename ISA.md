---
task: Topology Graph Ingestion & Animated Message Edges
slug: slms-p3-1-topology-graph-and-edges
effort: E3
phase: complete
progress: 24/24
mode: algorithm
started: 2026-09-29T06:38:00+01:00
updated: 2026-09-29T06:48:00+01:00
---

## Problem
1. Silent Node Dropping: Backend tenant filtering in `api_compat.py:3545-3551`, fallback serialization in `_derived_topology`, and client-side view filters silently dropped shared nodes, cross-tenant slices, external connectors, and `modeled_gaps`.
2. Graph Layout Jitter & Overlaps: In dense agent topologies, lack of deterministic hierarchical dagre / rank-based positioning caused visual node overlap and jitter on state re-renders.
3. Static Edge Visuals: Edge communication flows in `TrustFlowEdge.tsx` did not dynamically modulate animation velocity or stroke width based on live telemetry (throughput packets/sec and latency ms), and lacked reduced-motion media query handling.
4. Missing Accessible Node Drawer: Inspecting agent trust properties lacked an accessible, keyboard-operable slide-over drawer showing SPIFFE validation, attestation hash digests, tool permission chips, and egress boundaries.
5. Incomplete Backend Serialization: `TrustTopologyItem` serialization dropped agent metadata, lifecycle states, and custom attributes.

## Vision
An interactive, high-performance, and accessible Coding Agent & Agent Trust Topology visualization (Surface 4):
- Explicit keep-vs-drop policy preserving all shared nodes, modeled gaps, external connectors, and cross-tenant boundaries with a visible 'Hidden Nodes' counter badge.
- Deterministic hierarchical dagre and rank-based grid layout engine in ReactFlow v12 eliminating layout jitter and overlapping nodes.
- Custom animated SVG flow edges dynamically adapting marching-dash animation velocity and stroke width to throughput and latency, with full `prefers-reduced-motion` accessibility support.
- Fully accessible slide-over node inspection drawer (`NodeDetailDrawer.tsx`) with focus trapping, Escape listener, ARIA dialog semantics, and direct action triggers.
- Enriched backend topology models in `fe-signalloom/src/api_compat.py` preserving lifecycle states, trust domains, and custom attributes.
- Comprehensive Vitest and Pytest test suites passing 100% with zero em-dashes.

## Out of Scope
- Renaming Weave activity stream (owned by P3-2).
- Modifying FAIR risk calculation logic (owned by P3-3).
- Updating Audit Trail drawer components (owned by P3-4).
- Fleet operational telemetry views (owned by P4-2).

## Principles
- Zero Silent Dropping: Workloads outside the active filter are explicitly accounted for via the Hidden Nodes indicator; shared platform infrastructure is never filtered away.
- Deterministic Layout: Graph positioning is computed monotonically and memoized by rank and tier to guarantee visual stability.
- Telemetry-Driven Motion: Edge animation speed and width represent real traffic volume and latency; reduced motion settings are respected unconditionally.
- Keyboard & ARIA First: Every graph element and inspection drawer is fully accessible via keyboard navigation, screen readers, and focus management.
- Tenant Isolation with Visibility: Tenant scoping protects sensitive boundaries while preserving cross-boundary trust relationships and modeled gaps.

## Constraints
- ReactFlow v12 (`@xyflow/react`) with custom SVG edge rendering.
- Bun/bunx for all frontend package operations; no npm/npx.
- Python 3.12 with uv for backend FastAPI endpoints.
- Strict WCAG 2.2 accessibility standards (`prefers-reduced-motion`, ARIA dialog, focus trapping).
- Zero em-dashes across all modified and new UI files.
- Conventional commits with `--no-gpg-sign`.

## Goal
Deliver high-performance topological visualization of registered and discovered agents with deterministic dagre/rank layout, animated telemetry flow edges, accessible node inspection drawer, and enriched backend serialization, verified by Vitest and Pytest suites.

## Criteria
- [x] ISC-1: `api_compat.py` model `TrustTopologyItem` preserves `lifecycle_state`, `trust_domain`, `verified`, `tool_permissions`, `egress_allowlist`, `metadata`, and `custom_attributes`.
- [x] ISC-2: `api_compat.py` model `TrustTopologyEdge` supports `throughput_pps`, `latency_ms`, and `mtls_enforced`.
- [x] ISC-3: `api_compat.py` `_derived_topology` populates agent metadata, lifecycle states, tenant IDs, and marks discovered agents without SPIFFE IDs as unverified.
- [x] ISC-4: `api_compat.py` `trust_topology` endpoint retains shared platform nodes, modeled gaps, external connectors, and cross-tenant bridges without silent drops.
- [x] ISC-5: `tests/test_topology.py` pytest suite verifies `_derived_topology` and `trust_topology` serialization and tenant preservation.
- [x] ISC-6: `dashboard-signalloom/src/types/api.ts` and `trustTypes.ts` declare extended node and edge attributes (`lifecycle_state`, `trustDomain`, `verified`, `throughputPps`, `latencyMs`, `mtlsEnforced`, `toolPermissions`, `egressAllowlist`).
- [x] ISC-7: `TrustFlowEdge.tsx` calculates animation duration and stroke width dynamically from edge telemetry (`throughputPps` and `latencyMs`).
- [x] ISC-8: `TrustFlowEdge.tsx` respects `prefers-reduced-motion` media queries, rendering static dotted paths when reduced motion is requested.
- [x] ISC-9: `TrustFlowEdge.tsx` color-codes edges based on mTLS enforcement (green/cyan for verified/attested, amber for unauthenticated/unverified, red for denied).
- [x] ISC-10: `TrustFlowEdge.tsx` renders message throughput and latency metrics on hover tooltip.
- [x] ISC-11: `TrustGraph.tsx` implements deterministic hierarchical dagre and rank-based grid layout with no overlapping nodes or layout jitter.
- [x] ISC-12: `TrustGraph.tsx` integrates ReactFlow v12 with smooth zoom, pan, minimap, and auto-fit controls.
- [x] ISC-13: `AgentTrustTopologyPage.tsx` integrates `TrustGraph` and supports interactive filtering by Namespace, Trust Domain, Lifecycle State, Tenant, Location, Evidence, and Decision.
- [x] ISC-14: `AgentTrustTopologyPage.tsx` computes and renders an interactive 'Hidden Nodes' counter badge when filters exclude workloads.
- [x] ISC-15: `NodeDetailDrawer.tsx` renders a keyboard-accessible slide-over drawer with ARIA dialog semantics, Escape key listener, and focus trapping.
- [x] ISC-16: `NodeDetailDrawer.tsx` displays SPIFFE identity validation status, attestation fingerprints, tool permission chips, and egress boundaries.
- [x] ISC-17: `NodeDetailDrawer.tsx` provides quick action triggers: isolate agent, view audit logs, edit CEL policies, and view agent dossier.
- [x] ISC-18: `CodingAgentTopologyPage.tsx` or alias routes render the enhanced topology visualization for coding agents.
- [x] ISC-19: Vitest test suite in `TrustFlowEdge.test.tsx` verifies dynamic speed, stroke width, mTLS styling, and reduced-motion handling.
- [x] ISC-20: Vitest test suite in `TrustGraph.test.tsx` verifies hierarchical layout, non-overlapping node positioning, and hidden node counting.
- [x] ISC-21: Vitest test suite in `AgentTrustTopologyPage.test.tsx` verifies drawer opening, URL parameter deep-linking, and filtering controls.
- [x] ISC-22: TypeScript typecheck passes cleanly with zero errors.
- [x] ISC-23: Anti: Zero nodes or modeled gaps dropped silently across backend and frontend filtering.
- [x] ISC-24: Anti: Zero em-dashes introduced in any modified or new UI files.

## Test Strategy
- ISC-1..5: Pytest `tests/test_topology.py` and `tests/test_api_compat.py`.
- ISC-6..10, 19: Vitest `src/components/trust/TrustFlowEdge.test.tsx`.
- ISC-11, 12, 20: Vitest `src/components/trust/TrustGraph.test.tsx`.
- ISC-13..18, 21: Vitest `src/pages/AgentTrustTopologyPage.test.tsx`.
- ISC-22: `bun run typecheck`.
- ISC-23: Vitest and Pytest node count assertions.
- ISC-24: `grep -ro '—' src | wc -l`.

## Features
- Feature 1: Backend Topology Models & Serialization (`fe-signalloom/src/api_compat.py`) | satisfies: ISC-1..4 | depends_on: none | parallelizable: yes
- Feature 2: Backend Pytest Suite (`fe-signalloom/src/tests/test_topology.py`) | satisfies: ISC-5 | depends_on: Feature 1 | parallelizable: no
- Feature 3: Frontend Types & Telemetry Flow Edges (`types/api.ts`, `trustTypes.ts`, `TrustFlowEdge.tsx`) | satisfies: ISC-6..10 | depends_on: none | parallelizable: yes
- Feature 4: Deterministic Hierarchical Dagre & Rank Layout Engine (`components/trust/TrustGraph.tsx`, `TrustTopologyCanvas.tsx`) | satisfies: ISC-11..12 | depends_on: Feature 3 | parallelizable: no
- Feature 5: Accessible Node Detail Drawer (`components/trust/NodeDetailDrawer.tsx`) | satisfies: ISC-15..17 | depends_on: Feature 3 | parallelizable: yes
- Feature 6: Topology Page Integration & Hidden Nodes Counter (`pages/AgentTrustTopologyPage.tsx`, `pages/CodingAgentTopologyPage.tsx`) | satisfies: ISC-13, 14, 18 | depends_on: Feature 4, Feature 5 | parallelizable: no
- Feature 7: Comprehensive Vitest Test Suites (`TrustFlowEdge.test.tsx`, `TrustGraph.test.tsx`, `AgentTrustTopologyPage.test.tsx`) | satisfies: ISC-19..21 | depends_on: Feature 4..6 | parallelizable: no
- Feature 8: Typecheck & Typography Lint Certification | satisfies: ISC-22..24 | depends_on: Feature 1..7 | parallelizable: no

## Decisions
- 2026-09-29: Reconcile backend tenant filter to keep `tenant in {None, "shared", tenant_id}` and preserve cross-tenant slices and modeled_gaps.
- 2026-09-29: Map edge animation velocity dynamically: base animation duration = `max(0.6, min(10.0, 1000 / max(1, throughput_pps)))` with multiplier from latency.
- 2026-09-29: Check `prefers-reduced-motion` in JS and CSS, switching flow edges to static dashed/dotted rendering with zero animation duration.
- 2026-09-29: Implement deterministic hierarchical dagre and rank-based grid layout in `TrustGraph.tsx` with dynamic coordinate assignment for nodes without fixed x/y coordinates.
- 2026-09-29: Create `NodeDetailDrawer.tsx` with focus trap, Escape key handling, and ARIA dialog semantics for full a11y compliance.

## Changelog
- 2026-09-29: Initialized ISA for SLMS-P3-1 Topology Graph Ingestion & Animated Message Edges.
- 2026-09-29: Implemented backend enriched models and serialization in `api_compat.py`.
- 2026-09-29: Created backend pytest suite `test_topology.py` (2/2 tests pass).
- 2026-09-29: Implemented `TrustFlowEdge.tsx` with dynamic animation velocity and prefers-reduced-motion fallback.
- 2026-09-29: Implemented `NodeDetailDrawer.tsx` with ARIA modal dialog, focus trap, and Escape listener.
- 2026-09-29: Implemented `TrustGraph.tsx` with deterministic hierarchical rank layout and Hidden Nodes counter badge.
- 2026-09-29: Integrated topology pages and added comprehensive Vitest suites (42/42 tests pass).
- 2026-09-29: Completed typecheck and CSS custom property validation (197/197 test files pass).

## Verification
- Pytest Topology Suite: PASSED (2/2 tests pass in `tests/test_topology.py`).
- Vitest Topology Suites: PASSED (42/42 tests pass across `TrustFlowEdge.test.tsx`, `TrustGraph.test.tsx`, `AgentTrustTopologyPage.test.tsx`, `cssVarUsage.test.ts`).
- Full Dashboard Vitest Suite: PASSED (197/197 test files pass, 3517 tests).
- TypeScript Typecheck: PASSED (`bun run typecheck` exits 0).
- Typography Audit: PASSED (Zero em-dashes in UI code).
