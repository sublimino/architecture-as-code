---
task: "SLMS-P5-1: Settings Reconciliation & Connector Synchronization"
slug: "slms-p5-1"
effort: "E3"
phase: "observe"
progress: "0%"
mode: "algorithm"
started: "2026-09-29T10:14:04+01:00"
updated: "2026-09-29T10:18:00+01:00"
---

## Problem
In fe-signalloom, `routers/connectors.py` is absent despite frontend client references in `api/connectorsClient.ts`. The administrative Settings view in `views/Settings.tsx` and `pages/SettingsPage.tsx` requires reconciliation to support connector status, toggling with audit logging, and discovery synchronization. Disabling a connector must dynamically purge its unmanaged workloads from the discovery aggregation table (`/discovery/workloads`). The legacy `/connectors` redirect to `/federated-services` is removed. It now routes directly to Settings. Compliance framework toggles are harmonized across all six frameworks. A CEL policy editor link to `/policies` is mounted in Settings.

## Vision
Administrators navigating to Settings or `/connectors` see an interactive connector management interface. It supports AWS, GCP, Azure, K8s, and GitHub with instant toggle capability. Toggling a connector emits a structured `CONNECTOR_STATUS_CHANGED` audit event. It synchronizes with Discovery to purge unmanaged workloads and recompute risk totals. Framework toggles accurately control all active frameworks. Finally, the CEL policy editor entry point provides clear navigation to Policy-as-Code.

## Out of Scope
- Rewriting em-dashes platform-wide (owned by P5-2)
- Full Playwright acceptance journey (owned by P5-3)
- Modifying other unrelated views or non-connector routers

## Principles
- Zero em-dashes (`—`) in all newly authored or modified user-facing UI text strings.
- Pure tenant isolation derived strictly from `authenticated_tenant` (no client-asserted header trusts).
- Deterministic discovery synchronization: state change in connectors immediately reflects in discovery queries.
- Modular FastAPI router design avoiding circular imports.

## Constraints
- FastAPI router `routers/connectors.py` must register in `main.py` under prefix `/api/v1/connectors` and `/api/connectors` with authenticated tenant dependency.
- Immediate audit event emission on connector toggle with `eventType: CONNECTOR_STATUS_CHANGED`.
- Harmonize `PATCH /tenant/settings/frameworks` to accept EU AI Act, NIST SP 800-53, CRA, FINOS AIGF, DORA, and NIS2.
- All test suites must pass: pytest `tests/test_connectors.py`, vitest `Settings.test.tsx`, vitest `SettingsPage.test.tsx`, and `bun run typecheck`.

## Goal
Implement `fe-signalloom/src/routers/connectors.py` with full CRUD and status endpoints. Register it in `main.py` and update discovery filtering. Deliver passing pytest and vitest suites.

## Criteria
- [ ] ISC-1: `fe-signalloom/src/routers/connectors.py` exists and defines `router = APIRouter(tags=["connectors"])`
- [ ] ISC-2: `GET /api/v1/connectors` returns list of configured connectors for the authenticated tenant
- [ ] ISC-3: `GET /api/v1/connectors/providers` returns available connector providers (AWS, GCP, Azure, K8s, GitHub, etc.)
- [ ] ISC-4: `POST /api/v1/connectors/{id}/toggle` enables or disables a connector for the tenant
- [ ] ISC-5: `POST /api/v1/connectors/{id}/toggle` emits a structured audit event `CONNECTOR_STATUS_CHANGED`
- [ ] ISC-6: `GET /api/v1/connectors/status` returns synchronization health and last scan timestamps
- [ ] ISC-7: `fe-signalloom/src/main.py` imports and installs the connectors router
- [ ] ISC-8: `main.py` protects connectors router with `authenticated_tenant` dependency
- [ ] ISC-9: `api_compat.py` discovery aggregation filters out workloads from disabled connectors
- [ ] ISC-10: `api_compat.py` discovery aggregation dynamically recomputes unmanaged risk totals when connectors are disabled
- [ ] ISC-11: `api_compat.py` `PATCH /tenant/settings/frameworks` supports EU AI Act (`eu-ai-act`)
- [ ] ISC-12: `api_compat.py` `PATCH /tenant/settings/frameworks` supports NIST SP 800-53 (`nist-800-53`)
- [ ] ISC-13: `api_compat.py` `PATCH /tenant/settings/frameworks` supports Cyber Resilience Act (`cyber-resilience-act`)
- [ ] ISC-14: `api_compat.py` `PATCH /tenant/settings/frameworks` supports FINOS AIGF (`finos-ai-governance-framework`)
- [ ] ISC-15: `api_compat.py` `PATCH /tenant/settings/frameworks` supports DORA placeholder (`dora`)
- [ ] ISC-16: `api_compat.py` `PATCH /tenant/settings/frameworks` supports NIS2 placeholder (`nis2`)
- [ ] ISC-17: `api/connectorsClient.ts` exports `toggleConnector` method in `connectorsApi`
- [ ] ISC-18: `api/connectorsClient.ts` mock implementation supports `toggleConnector` and status inspection
- [ ] ISC-19: `views/Settings.tsx` displays connector cards with connection health indicators
- [ ] ISC-20: `views/Settings.tsx` shows last sync / last tested timestamps for connectors
- [ ] ISC-21: `views/Settings.tsx` provides interactive enable/disable switches calling `toggleConnector`
- [ ] ISC-22: `views/Settings.tsx` contains Policy-as-Code card directing administrators to CEL Policy Editor
- [ ] ISC-23: `views/Settings.tsx` Policy-as-Code card links/navigates to `/policies`
- [ ] ISC-24: `pages/SettingsPage.tsx` exports the reconciled Settings component
- [ ] ISC-25: `App.tsx` routes `/connectors` without legacy redirect to `/federated-services`
- [ ] ISC-26: `fe-signalloom/src/tests/test_connectors.py` exists with complete pytest coverage
- [ ] ISC-27: `test_connectors.py` verifies `GET /api/v1/connectors` lists tenant connectors
- [ ] ISC-28: `test_connectors.py` verifies `POST /api/v1/connectors/{id}/toggle` mutates status and emits audit log
- [ ] ISC-29: `test_connectors.py` verifies disabling connector purges workloads from discovery
- [ ] ISC-30: `dashboard-signalloom/src/views/Settings.test.tsx` passes with 100% green
- [ ] ISC-31: `dashboard-signalloom/src/pages/SettingsPage.test.tsx` exists and passes 100% green
- [ ] ISC-32: `bun run typecheck` in `dashboard-signalloom` passes with exit code 0
- [ ] ISC-33: Anti: No em-dashes (`—`) introduced in modified UI components
- [ ] ISC-34: Anti: No circular imports between `main.py` and `routers/connectors.py`

## Features
| Feature | Satisfies | Depends On | Parallelizable |
|---------|-----------|------------|----------------|
| Backend Connectors Router | ISC-1..8, 26..28 | None | Yes |
| Discovery Aggregation & Frameworks Sync | ISC-9..16, 29 | Backend Router | No |
| Frontend Connectors Client & Settings UI | ISC-17..25, 33 | None | Yes |
| Test Suites (Pytest + Vitest) | ISC-30..32, 34 | All | No |

## Test Strategy
| ISC | Type | Check | Threshold | Tool |
|-----|------|-------|-----------|------|
| ISC-1..8, 26..29 | Unit/API | Pytest `tests/test_connectors.py` | 100% pass | pytest |
| ISC-17..25, 30..31 | UI Unit | Vitest `Settings.test.tsx`, `SettingsPage.test.tsx` | 100% pass | vitest |
| ISC-32 | Static | `tsc --noEmit` | Clean 0 exit | bun run typecheck |
| ISC-33 | Lint | Grep em-dash in modified files | 0 matches | grep |
| ISC-34 | Import | Python module import | Clean 0 exit | python |

## Decisions
- 2026-09-29T10:18:00+01:00: Initialized ISA for SLMS-P5-1 covering full backend router, discovery aggregation synchronization, framework toggles, Settings UI refactor, routing update, and test suites.

## Verification
(Pending execution)
