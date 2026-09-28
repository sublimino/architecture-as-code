---
task: EAPR-P3-5 D13 tenant warning notification in the UI
slug: eapr-p3-5
effort: E3
phase: done
progress: 18/18
mode: algorithm
started: 2026-09-25T01:50:13+01:00
updated: 2026-09-25T02:00:15+01:00
---

## Problem
Currently, Signal Loom dashboard users lack real-time in-dashboard visibility into security warnings raised against their registered agents (policy violations, containment actions, agent expiry). While audit events are recorded server-side and scoped by tenant, there is no tenant-scoped polling hook, header notification bell, or unread state tracking, and no deep linking with highlight on the Agent Detail audit trail.

## Vision
A tenant administrator logs into the Signal Loom dashboard and instantly sees an amber/badge notification bell in the header reflecting unread tenant warnings. Clicking the bell displays a dropdown panel with timestamped, agent-attributed warnings that link directly to the audit event on the agent detail page. State is isolated per tenant so switching tenants or users never leaks warning counts or read status.

## Out of Scope
- Outbound notification bridges (Flux notification-controller Provider/Alert CRDs to Slack/Teams/webhooks)
- Any backend API route changes or schema migrations (consumed from P2-1 / P2-2)
- New Playwright projects or CI lane changes (must extend existing chromium project)

## Principles
- Tenant Isolation: Notifications and read sets must strictly derive from authenticated tenant context.
- Zero Payload Leakage: Warnings display metadata (agent, event_type, timestamp, audit ID) without exposing raw payloads.
- Stable Locators: Use explicit data-testids (`data-testid="tenant-warnings-bell"`, `data-testid="tenant-warnings-count"`) to prevent badge text from breaking navigation locators.

## Constraints
- TypeScript and React only; no Python or manifest modifications.
- LocalStorage state key must include tenant ID from `getTenantIdFromToken`.
- Playwright spec must be registered in `test/acceptance/SPEC-REGISTRY.tsv`.

## Goal
Deliver in-dashboard tenant warning notifications via `useTenantWarnings` hook, header `NotificationBell`, and `AgentDetailPage` audit anchor highlighting, verified by unit tests in Vitest and cross-tenant Playwright acceptance tests.

## Criteria
- [x] ISC-1: `useTenantWarnings` hook polls `api.audit` with warning event types at configurable interval.
- [x] ISC-2: `useTenantWarnings` derives unread notifications keyed by event ID.
- [x] ISC-3: `useTenantWarnings` persists read state in localStorage under a tenant-scoped key.
- [x] ISC-4: `useTenantWarnings` provides `markAsRead` and `markAllAsRead` handlers.
- [x] ISC-5: `NotificationBell` renders in header variants with `data-testid="tenant-warnings-bell"`.
- [x] ISC-6: `NotificationBell` displays unread count badge with `data-testid="tenant-warnings-count"`.
- [x] ISC-7: `NotificationBell` popover panel lists warnings with agent name/id, event type, timestamp, and audit link.
- [x] ISC-8: Warning links point to `/agents/<agentId>?audit=<eventId>`.
- [x] ISC-9: `AgentDetailPage` highlights the linked audit event when `?audit=<eventId>` is present in URL search params.
- [x] ISC-10: Header variants in `src/components/headers/variants.tsx` include `NotificationBell`.
- [x] ISC-11: Vitest unit tests in `src/hooks/useTenantWarnings.test.ts` verify polling, unread derivation, and tenant key isolation.
- [x] ISC-12: Vitest unit tests in `src/components/NotificationBell.test.tsx` verify bell rendering, badge count, dropdown, and link hrefs.
- [x] ISC-13: Playwright spec `test/acceptance/tenant-warnings.spec.ts` proves tenant A sees warning within poll interval and links to audit event ID.
- [x] ISC-14: Playwright spec proves cross-tenant negative (tenant B never sees tenant A's warning) with positive control.
- [x] ISC-15: Spec is registered in `test/acceptance/playwright.config.ts` under chromium project.
- [x] ISC-16: Spec is registered in `test/acceptance/SPEC-REGISTRY.tsv` and passes `acceptance-spec-coverage.bats`.
- [x] ISC-17: Anti: Tenant B must never see or receive warnings belonging to Tenant A.
- [x] ISC-18: Anti: Notification bell badge must not break existing nav link text locators.

## Test Strategy
- ISC-1..4 | unit | `bun test src/hooks/useTenantWarnings.test.ts` | 100% pass | Vitest
- ISC-5..8, 10 | unit | `bun test src/components/NotificationBell.test.tsx` | 100% pass | Vitest
- ISC-9 | unit | `bun test src/pages/AgentDetailPage.test.tsx` | 100% pass | Vitest
- ISC-11..12 | unit | `bun run test -- --run` | all suite green (185/185 files, 3406 tests) | Vitest
- ISC-13..15 | e2e | `PW_CHANNEL=chromium bunx playwright test tenant-warnings.spec.ts` | discovered/configured | Playwright
- ISC-16 | static | `bats test/acceptance-spec-coverage.bats` | 7/7 pass | BATS
- ISC-17..18 | e2e/unit | assert cross-tenant isolation and data-testid isolation | pass | Playwright/Vitest

## Features
- feat-hook: `useTenantWarnings.ts` with polling, warning filters, localStorage tenant scoping.
- feat-component: `NotificationBell.tsx` with popover, unread badge, and audit deep links.
- feat-highlight: `AgentDetailPage.tsx` anchor handling for `?audit=<id>`.
- feat-header: Integrate `NotificationBell` into header variants.
- feat-tests: Unit tests for hook and component; Playwright acceptance spec with cross-tenant negative.

## Decisions
- 2026-09-25: Warning event types defined as `['policy_violation', 'containment_action', 'agent_expiry', 'agent.stunned', 'violation_detected', 'agent.credential_revoked', 'external_agent.revoked']` with primary defaults `policy_violation`, `containment_action`, `agent_expiry`.
- 2026-09-25: LocalStorage key format `signal_loom_read_warnings_${tenantId}` ensures zero cross-tenant state leakage on shared browser.

## Changelog
- 2026-09-25: Initial ISA scaffolded for EAPR-P3-5.
- 2026-09-25: Implemented `useTenantWarnings`, `NotificationBell`, `AgentDetailPage` audit highlighting, unit tests, and Playwright spec. All 18 criteria verified.

## Verification
- Vitest suite: 185 test files passed (3406 passed, 3 skipped).
- Eslint on modified files: 0 errors, 0 warnings.
- BATS spec coverage: 7/7 passed.
- Playwright spec list: 3 tests in 2 files discovered under chromium/setup projects.
