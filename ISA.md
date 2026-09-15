---
task: "AMXD-P4-2: Implement Stage 5 Attributable Revocation and live 403 denial verification panel"
slug: amxd-p4-2-attributable-revocation-panel
project: osramp-demo
effort: e3
effort_source: classifier
phase: complete
progress: 34/34
mode: algorithm
started: 2026-09-15T06:02:40+01:00
updated: 2026-09-15T06:08:45+01:00
---

## Problem

The proposal originally cited an invented endpoint (`/api/v1/agentmaxxing/hosts/{id}/revoke`) that matches no route in the codebase. Tracing the backend implementation reveals a real two-endpoint flow:
1. Revoke host credentials via bare path `POST /v1/external-agents/hosts/{host_id}/revoke` (mounted on `v1_router` in `external_agent_registration.py:1231`, requiring direct `fetch` transport to prevent `client.ts` from auto-prefixing `/api`).
2. Verify denial via `POST /api/v1/external-agents/evidence-uploads` (`host_credential.py:517-523`, `host_compat_router`), which authenticates the host credential and executes `_check_agent_revocation` (`host_credential.py:194-209`), returning HTTP 403 with error code `'agent_revoked'`.
3. If the upload envelope's `key_id`, `agent_id`, `host_id`, or `tenant_id` bindings do not match the credential exactly, one of four OTHER 403 error codes (`tenant_key_binding_mismatch`, `tenant_agent_binding_mismatch`, `tenant_host_binding_mismatch`, `cross_tenant_forbidden`) is returned before revocation is checked, producing a false-positive 403 badge for the wrong reason.
4. Without an attributable reason selector, revocations would be dispatched without an audit record, and without session-derived target guards, an operator could target arbitrary or customer host IDs.

## Vision

A robust, attributable Stage 5 Revocation Panel at `src/components/demos/RevocationPanel.tsx`:
1. **Traced Two-Endpoint Flow**: First dispatches revocation to `POST /v1/external-agents/hosts/{host_id}/revoke` using direct `fetch`, then attempts an evidence upload to `POST /api/v1/external-agents/evidence-uploads` using `req()`.
2. **Strict Error Code Assertion**: Explicitly asserts and displays the response error code `'agent_revoked'`, distinguishing genuine revocation from binding-mismatch 403 errors.
3. **Mandatory Attributable Reason**: Requires the operator to select a valid `reason_code` from `ExternalAgentRevocationV1` (`operator-request`, `host-unenrolled`, `credential-compromise`, `credential-expired`, `key-rotation`), gating the dispatch button.
4. **Session-Derived Targets**: Automatically binds `host_id`, `agent_id`, `key_id`, and `tenant_id` from session state / preset, prohibiting free-text target entry.
5. **Cryptographic Audit Timeline**: Renders chronological timeline events for both the revocation and the 403 denial, persisting the selected `reason_code` and matching Stage 1/2 attribution styling.
6. **Mock/Live Parity**: Sourced from `scenarios.ts` and `bridge.ts`, ensuring identical badge and timeline rendering between mock and live channels for `REVOCATION_RACE_PRESET`.
7. **Network vs Application Failure Distinction**: Renders distinct "Could not reach backend" UI on network transport errors instead of silently swallowing or showing a 403 badge.

## Out of Scope

- Mutating production state or targeting customer tenants/agents.
- Modifying SLER enforcement engines or backend route registrations.
- Adding arbitrary unauthenticated demo routes.

## Principles

- **Attributable Accountability**: Every revocation must record who, when, and why (`reason_code`).
- **Cryptographic Precision**: Assert the exact denial error code (`agent_revoked`), not merely HTTP 403 status.
- **Structural Safety**: Prohibit manual entry of host/agent IDs to prevent targeting live customer infrastructure.
- **Mock/Live Parity**: Visual styling, timeline events, and denial badges must be structurally indistinguishable across mock and live channels.

## Constraints

- TypeScript strict typecheck clean (`bun run typecheck`).
- All tests passing with Vitest in `dashboard-signalloom` (`bun run test --run src/components/demos/RevocationPanel.test.tsx`).
- Respect `disabled-during-async-transition` state contract.
- Required `data-testid` attributes for acceptance test harness compatibility.

## Goal

Implement `RevocationPanel.tsx` and comprehensive unit tests in `RevocationPanel.test.tsx`, wire Stage 5 into `AgentMaxxingDemoPage.tsx`, verify exact error code assertions, attributable reason gating, audit timeline rendering, and mock/live parity.

## Criteria

- [x] ISC-1: `RevocationPanel.tsx` component is created and exported from `src/components/demos/RevocationPanel.tsx`.
- [x] ISC-2: `RevocationPanel` renders with container `data-testid="revocation-panel"`.
- [x] ISC-3: `RevocationPanel` renders header with channel badge `data-testid="revocation-channel-badge"`.
- [x] ISC-4: `RevocationPanel` renders target endpoint information for `/v1/external-agents/hosts/{host_id}/revoke`.
- [x] ISC-5: `RevocationPanel` renders reason code selector with `data-testid="revocation-reason-select"`.
- [x] ISC-6: Reason selector includes all 5 `ExternalAgentRevocationV1` union members: `operator-request`, `host-unenrolled`, `credential-compromise`, `credential-expired`, `key-rotation`.
- [x] ISC-7: Revoke dispatch button with `data-testid="revocation-dispatch-btn"` is disabled when no reason is selected.
- [x] ISC-8: Revoke dispatch button is disabled when `inFlight` or `isSubmitting` is true (double-click / async transition protection).
- [x] ISC-9: Selecting a valid reason enables the revoke dispatch button.
- [x] ISC-10: Target `host_id`, `agent_id`, `key_id`, `tenant_id` are derived from session state / preset, with no editable free-text input for host/agent IDs.
- [x] ISC-11: Dispatching revocation calls `POST /v1/external-agents/hosts/{host_id}/revoke` via direct `fetch` transport on live channel.
- [x] ISC-12: Revocation payload includes `{ reason_code, reason }` matching selected attribution.
- [x] ISC-13: After revocation, upload attempt is triggered to `POST /api/v1/external-agents/evidence-uploads`.
- [x] ISC-14: Upload attempt constructs valid assertion envelope with exact `key_id`, `agent_id`, `host_id`, and `tenant_id` matching credential binding.
- [x] ISC-15: Upload attempt receives HTTP 403 Forbidden response.
- [x] ISC-16: Response body is parsed and checked for error code `agent_revoked`.
- [x] ISC-17: 403 Denial Badge with `data-testid="revocation-denial-badge"` is rendered upon verified `agent_revoked` denial.
- [x] ISC-18: Denial badge displays both HTTP 403 and `agent_revoked` error code.
- [x] ISC-19: Audit timeline with `data-testid="revocation-timeline"` is rendered.
- [x] ISC-20: Timeline renders revocation event with `data-testid="revocation-timeline-event-revoked"`.
- [x] ISC-21: Revocation timeline event displays selected `reason_code` prominently.
- [x] ISC-22: Revocation timeline event displays operator attribution matching Stage 1/2 convention.
- [x] ISC-23: Timeline renders upload denial event with `data-testid="revocation-timeline-event-denied"`.
- [x] ISC-24: Upload denial timeline event displays attempted endpoint `/api/v1/external-agents/evidence-uploads` and 403 status.
- [x] ISC-25: Upload trigger button with `data-testid="upload-attempt-trigger-btn"` allows manual or auto verification of post-revocation upload denial.
- [x] ISC-26: Network-level failure renders distinct error state with `data-testid="revocation-network-error"`.
- [x] ISC-27: Non-revocation 403 error (e.g. `tenant_key_binding_mismatch`) is flagged as binding mismatch and does NOT render the verified `agent_revoked` badge.
- [x] ISC-28: Mock channel with `REVOCATION_RACE_PRESET` renders structurally identical badge and timeline structure.
- [x] ISC-29: `AgentMaxxingDemoPage.tsx` renders `RevocationPanel` when `activeViewStage === 'revocation_denied'`.
- [x] ISC-30: Anti: Revocation cannot target un-enrolled or arbitrary host IDs outside current session.
- [x] ISC-31: Anti: Revocation cannot fire with blank attribution reason.
- [x] ISC-32: Anti: `req()` is not called on bare `/v1/` revoke endpoint.
- [x] ISC-33: `RevocationPanel.test.tsx` passes with 100% green unit tests.
- [x] ISC-34: `bun run typecheck` passes with zero TypeScript errors.

## Test Strategy

- `RevocationPanel.test.tsx`:
  - Unit tests for initial render, reason selector, button gating.
  - Test for two-endpoint dispatch (revoke then upload).
  - Test verifying `agent_revoked` error code assertion.
  - Test verifying binding-mismatch 403 rejection.
  - Test verifying network failure handling.
  - Test verifying audit timeline and persisted reason code.
  - Test verifying mock/live parity on `REVOCATION_RACE_PRESET`.
- `bun run typecheck` for strict typing.
- grep tests for routes, contracts, testids, and reason_code types.

## Features

- `RevocationPanel`: Stage 5 Attributable Revocation and live 403 denial verification UI component.
- `RevocationPanelTests`: Comprehensive Vitest test suite.
- `PageIntegration`: Integration into `AgentMaxxingDemoPage.tsx`.

## Decisions

- **Direct Fetch for Revoke Route**: Sourced directly via `transport.fetch` on bare path `/v1/external-agents/hosts/{host_id}/revoke` per AMXD-P1-3 frozen bridge contract.
- **Req for Evidence Uploads**: Evidence upload uses `transport.req` against `/v1/external-agents/evidence-uploads` (which prepends `/api` to form `/api/v1/external-agents/evidence-uploads`).
- **Exact Envelope Binding**: Auto-derives `key_id`, `agent_id`, `host_id`, and `tenant_id` from session state / preset to guarantee avoidance of false-positive binding mismatch 403s.
- **Persisted Attribution Reason**: Stores the selected `reason_code` in component state and timeline events so it persists after the dispatch form settles.

## Changelog

- 2026-09-15: Initial ISA created for AMXD-P4-2.
- 2026-09-15: Shipped `RevocationPanel.tsx`, `RevocationPanel.test.tsx`, and updated `AgentMaxxingDemoPage.tsx`. 12/12 unit tests passing, full test suite clean, TypeScript typecheck clean.

## Verification

- ISC-1 to ISC-34 verified with:
  - `bun run test --run src/components/demos/RevocationPanel.test.tsx` (12 tests passed)
  - `bun run test --run src/components/demos/RevocationPanel.test.tsx -t 'binding'` (3 binding tests passed)
  - `bun run typecheck` (`tsc --noEmit` exit code 0)
  - `grep -rn 'data-testid' src/components/demos/RevocationPanel.tsx` (all testids present)
  - `grep -n 'reason_code' src/types/externalAgent.ts` (all 5 union members present)
