---
task: Cross-Surface Multi-Domain UI and Protocol Remediation
slug: slms-cross-surface-multi-domain-remediation
effort: E4
phase: build
progress: 0/32
mode: algorithm
started: 2026-09-29T19:55:00+01:00
updated: 2026-09-29T19:55:00+01:00
---

## Problem
1. Discovery Attention Selection: In `DiscoveryPage.tsx`, the 'Attention Required' panel and header lack selection action binding, and the 'unowned' alert click clears filters rather than selecting unowned workloads requiring attention.
2. Coding Agents Error State: When querying host detective coding agent telemetry against live clusters without active agentmaxxing sensor data, the component does not surface the standardized inline error code banner (`Failed 8s ago:Request failed with status code 404 Retry`) with truthful relative timestamps and retry handling.
3. Trust Topology Live Visualization and Interactive Cards: The StatCards on `AgentTrustTopologyPage.tsx` do not filter or interact with the React Flow canvas diagram, and live topology nodes are placed with naive coordinate wrapping that leads to visual collisions and unreadable diagrams.
4. Activity View Naming: 'The Weave' terminology in sidebar navigation, route maps, page headings, and links departs from the canonical user-facing label 'Activity'.
5. Regulatory Policy Bundles and FAIR Risk: FAIR Risk and Policy pages only expose baseline claim facts and an incomplete framework set, omitting full regulatory bundles and realistic CEL rules for EU AI Act, NIST SP 800-53, Cyber Resilience Act (CRA), and FINOS AI Governance Framework (AIGF).
6. Agent Super Filter Table Missing: No unified, reusable design system table exists with standardized filter facets (search, lifecycle state, source connector, namespace, attention required) and sortable columns including sortable 'last assessed' with full timestamps and sortable 'lifecycle'.
7. RBAC Analysis Iframe Loading Failure: Navigating to `/rbac-analysis` fails to display the embedded AFM dashboard due to server-wide `X-Frame-Options: DENY` and CSP `frame-ancestors 'none'` response headers blocking same-origin iframe rendering.
8. AFM Scan Trigger 405 Method Not Allowed: Triggering a collusion and privilege escalation scan via `triggerCollusionScan` issues a `POST` request to `/afm/clusters/{cluster_id}/jobs`, which KubeSec-AFM rejects with HTTP 405 Method Not Allowed because its escalation trigger endpoint is `/clusters/{cluster_id}/analysis/escalation`.
9. Federated Services Authentication Redirect: Navigating to `/federated-services` in live mode triggers an unexpected redirect to sign-in because `useFederatedServices` uses a fallback `'demo-token'` instead of calling `useAuth0().getAccessTokenSilently()`, causing HTTP 401 Unauthorized and Axios redirect interception.

## Vision
A completely reconciled, bulletproof Signal Loom multi-surface experience where:
- All 13 delivery surfaces communicate consistently with authoritative live backend services and offline demo mode fixtures.
- The 'Attention Required' panel in Discovery directly selects and isolates workloads requiring security review.
- Coding Agents error state truthfully displays exact upstream status codes, live relative elapsed timestamps, and working retry affordances.
- Topology StatCards reactively filter and highlight canvas elements with clean hierarchical DAG layout across both demo fixtures and live cluster data.
- 'Activity' is canonically restored across navigation, routes, and page typography.
- EU AI Act, NIST SP 800-53, CRA, and FINOS AIGF regulatory bundles offer rich, realistic CEL policies and full population filtering across FAIR Risk and Policy views.
- A unified Agent Super Filter Table component powers Discovery, Agents, FAIR Risk, and Policy posture with synchronized filtering, column sorting, and full timestamp visibility.
- `/rbac-analysis` seamlessly renders the embedded AFM console without CSP or X-Frame-Options blocking.
- Collusion and privilege escalation scans trigger successfully against AFM via `/analysis/escalation` without 405 errors.
- `/federated-services` authenticates cleanly using real OIDC bearer tokens without redirecting to login.

## Out of Scope
1. Rewriting the internal Next.js application of KubeSec-AFM itself.
2. Modifying the core FrostDB columnar storage engine in `signal-store`.
3. Creating new third-party identity providers outside Entra ID, Okta, and Dex.
4. Upgrading Dex or SPIRE cryptographic signing algorithms outside existing SPIFFE standards.

## Principles
1. Truth in UI: The frontend must never claim an agent is governed or an AFM scan is queued when the underlying API refused the call or returned 404/405.
2. Zero Em-Dash Mandate: Strictly no em-dashes (`—`) or en-dashes (`–`) in any user-facing code, typography, comments, or commit messages.
3. Separation of Concerns: Reusable design system primitives (such as the Agent Super Filter Table) must separate data fetching from presentation and filtering mechanics.
4. Two Data Planes, One Experience: Seamless operation across offline demo mode fixtures and live cluster API endpoints.
5. Falsifiability: Every test must assert specific, meaningful conditions that fail if the bug is present and pass when resolved.

## Constraints
1. TypeScript and Bun: All frontend code, components, and unit tests must execute with `bun` and Vitest (no `npm` or `npx`).
2. Git Hygiene: Commit with `git commit --no-gpg-sign` using conventional commit prefixes.
3. Worktree Isolation: Any background or isolated code development must reside under `~/src/.worktrees/<repo>/<branch>/`.
4. Browser Acceptance: Browser tests must use Playwright and web-first assertions without arbitrary `page.waitForTimeout()` calls.

## Goal
Deliver complete, verified cross-surface fixes across Discovery, Agents, Topology, Activity, FAIR Risk, Policy, RBAC Analysis, Collusion & Access, and Federated Services, validated by targeted Vitest and Playwright test suites.

## Criteria
- [ ] ISC-1: In `DiscoveryPage.tsx`, clicking the 'Attention Required' banner header or badge filters/selects workloads that require attention.
- [ ] ISC-2: In `DiscoveryPage.tsx`, clicking the 'unowned' alert in `AttentionPanel` filters to unowned workloads rather than resetting filters.
- [ ] ISC-3: In `CodingAgentsTab.tsx`, when the telemetry list API returns 404, the inline error banner displays `Failed <n>s ago:Request failed with status code 404 Retry`.
- [ ] ISC-4: In `CodingAgentsTab.tsx`, clicking 'Retry' on the 404 error banner re-invokes `fetchTelemetry`.
- [ ] ISC-5: In `AgentTrustTopologyPage.tsx`, clicking the 'Runtime-observed' StatCard filters the diagram to observed evidence nodes and edges.
- [ ] ISC-6: In `AgentTrustTopologyPage.tsx`, clicking the 'Modeled items' StatCard filters the diagram to modeled evidence nodes and edges.
- [ ] ISC-7: In `AgentTrustTopologyPage.tsx`, clicking the 'Fixture-tested items' StatCard filters the diagram to fixture-tested evidence nodes and edges.
- [ ] ISC-8: In `TrustGraph.tsx` and `toTrustTopology`, hierarchical DAG rank positioning is applied to live topology nodes preventing coordinate collision.
- [ ] ISC-9: In `Sidebar.tsx`, the navigation entry for `/activity` or `/weave` displays the label 'Activity' instead of 'The Weave'.
- [ ] ISC-10: In `App.tsx`, route titles for `/activity` and `/weave` are set to 'Activity'.
- [ ] ISC-11: In `WeavePage.tsx`, the page heading and breadcrumb render 'Activity'.
- [ ] ISC-12: In `AgentsPage.tsx`, the navigation action button displays 'View Activity'.
- [ ] ISC-13: In `RiskExposurePage.tsx`, `DEFAULT_VERSIONS` includes active versions for EU AI Act, NIST 800-53, Cyber Resilience Act (CRA), and FINOS AIGF.
- [ ] ISC-14: In `CompliancePolicyPage.tsx`, `DEFAULT_BUNDLES` includes realistic CEL rules for EU AI Act, NIST 800-53, CRA, and FINOS AIGF.
- [ ] ISC-15: Author new reusable component `components/AgentSuperFilterTable.tsx` providing search, lifecycle state, connector source, namespace, and attention filters.
- [ ] ISC-16: In `AgentSuperFilterTable.tsx`, columns for `last_assessed` and `lifecycle` are sortable.
- [ ] ISC-17: In `AgentSuperFilterTable.tsx`, `last_assessed` displays full timestamps with tooltip or formatted date-time.
- [ ] ISC-18: Integrate `AgentSuperFilterTable` into `DiscoveryPage.tsx`.
- [ ] ISC-19: Integrate `AgentSuperFilterTable` into `AgentsPage.tsx`.
- [ ] ISC-20: Integrate `AgentSuperFilterTable` into `RiskExposurePage.tsx` population breakdown table.
- [ ] ISC-21: In `nginx.conf`, configure `location /dashboard/` with `X-Frame-Options: SAMEORIGIN` and CSP `frame-ancestors 'self'`.
- [ ] ISC-22: Verify `/rbac-analysis` loads the embedded AFM iframe without CSP or X-Frame-Options blocking.
- [ ] ISC-23: In `afmApi.ts`, update `triggerCollusionScan` to POST to `/clusters/{cluster_id}/analysis/escalation` instead of `/jobs`.
- [ ] ISC-24: In `afmApi.ts`, parse `job_id` from the 202 response of `/clusters/{cluster_id}/analysis/escalation`.
- [ ] ISC-25: In `FederatedServicesPage.tsx`, replace `localStorage.getItem('token') || 'demo-token'` with `useAuth0().getAccessTokenSilently()`.
- [ ] ISC-26: Verify navigating to `/federated-services` in authenticated live mode does not redirect to login or sign-in.
- [ ] ISC-27: Vitest: author and pass unit tests for `AgentSuperFilterTable.test.tsx`.
- [ ] ISC-28: Vitest: author and pass unit tests in `afmApi.test.ts` verifying `triggerCollusionScan` endpoint and payload parsing.
- [ ] ISC-29: Vitest: author and pass unit tests in `CodingAgentsTab.test.tsx` for 404 error rendering and retry.
- [ ] ISC-30: Vitest: run all dashboard vitest suites and confirm 100% pass rate.
- [ ] ISC-31: Playwright: author or update browser acceptance tests verifying AFM scan trigger and iframe embedding.
- [ ] ISC-32: Anti: Zero em-dashes (`—`) or en-dashes (`–`) introduced across all modified source code, templates, and tests.

## Test Strategy
- ISC-1..2: Vitest in `DiscoveryPage.test.tsx` verifying 'Attention Required' filtering.
- ISC-3..4: Vitest in `CodingAgentsTab.test.tsx` simulating 404 API error and retry.
- ISC-5..8: Vitest in `AgentTrustTopologyPage.test.tsx` and `TrustGraph.test.tsx` asserting StatCard click filter state and node layout coordinates.
- ISC-9..12: Vitest in `Sidebar.test.tsx` and `WeavePage.test.tsx` verifying 'Activity' title and link.
- ISC-13..14: Vitest in `RiskExposurePage.test.tsx` and `CompliancePolicyPage.test.tsx` asserting 4 regulatory frameworks.
- ISC-15..20: Vitest in `AgentSuperFilterTable.test.tsx` asserting filter facets, sorting on last_assessed (with timestamps) and lifecycle.
- ISC-21..22: Nginx config curl test and Playwright browser iframe check on `/rbac-analysis`.
- ISC-23..24: Vitest in `afmApi.test.ts` asserting `/analysis/escalation` route and `job_id` normalization.
- ISC-25..26: Vitest in `FederatedServicesPage.test.tsx` asserting token acquisition and zero unexpected signin redirects.
- ISC-27..30: Full Vitest suite run (`bun run test --run` in `dashboard-signalloom`).
- ISC-31: Playwright acceptance run (`./scripts/acceptance-test.sh`).
- ISC-32: Automated regex sweep `grep -rn '[—–]'` on modified files.

## Features
- Feature 1: Protocol & Security Fixes (AFM Escalation Endpoint, Nginx Iframe CSP, Federated Services Auth) | satisfies: ISC-21, 22, 23, 24, 25, 26, 28
- Feature 2: Design System Agent Super Filter Table (`AgentSuperFilterTable.tsx`) | satisfies: ISC-15, 16, 17, 27
- Feature 3: Cross-Surface Integration of Super Filter Table (Discovery, Agents, FAIR Risk) | satisfies: ISC-1, 2, 18, 19, 20
- Feature 4: Regulatory Policy Bundles & FAIR Risk Expansion (EU AI Act, NIST, CRA, FINOS) | satisfies: ISC-13, 14
- Feature 5: Topology Interactive StatCards & Hierarchical Layout | satisfies: ISC-5, 6, 7, 8
- Feature 6: Activity Navigation Rename & Coding Agents 404 Error State | satisfies: ISC-3, 4, 9, 10, 11, 12, 29
- Feature 7: Comprehensive Test Pyramid, Cluster Rebuild & Acceptance Verification | satisfies: ISC-30, 31, 32

## Decisions
- 2026-09-29: Root cause for `/rbac-analysis` failure identified as Nginx `X-Frame-Options: DENY` and `frame-ancestors 'none'`. Resolved by configuring `SAMEORIGIN` and `frame-ancestors 'self'` on `location /dashboard/`.
- 2026-09-29: Root cause for AFM scan 405 identified as `afmApi.ts` calling `/clusters/{cluster_id}/jobs` instead of `/clusters/{cluster_id}/analysis/escalation`. Resolved by repointing to `/analysis/escalation` and parsing `job_id`.
- 2026-09-29: Root cause for `/federated-services` sign-in redirect identified as hardcoded fallback to `'demo-token'`, prompting Axios 401 response interceptor. Resolved by using `useAuth0().getAccessTokenSilently()`.
- 2026-09-29: Design System Agent Super Filter Table designed as a reusable generic container standardizing filter facets and sortable timestamps across Discovery, Agents, and Risk views.

## Changelog
- 2026-09-29: Initialized ISA for SLMS cross-surface multi-domain UI and protocol remediation.

## Verification
- Pending execution.
