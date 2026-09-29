---
task: Federated Services Demo Data Hardening & Cofide Interceptor
slug: slms-p4-1-federated-services-and-cofide-interceptor
effort: E3
phase: complete
progress: 24/24
mode: algorithm
started: 2026-09-29T07:16:00+01:00
updated: 2026-09-29T07:27:50+01:00
---

## Problem
1. Illustrative Disclaimer & Placeholder Copy: `FederatedServicesPage.tsx` lines 520-526 contain explicit references to "illustrative mock data" and line 577 renders an "Illustrative" disclaimer badge with static text stating "no trust zone, federation or SVID below was observed".
2. Hardcoded Static Fixtures: `TRUST_ZONES`, `FEDERATIONS`, `FEDERATED_SERVICES`, `POLICIES`, `SPIFFE_IDS`, and `FEDERATION_EVENTS` were defined as raw array literals in `FederatedServicesPage.tsx`, bypassing the standard `isDemoMode()` toggle and preventing live API connectivity.
3. Missing Server-Side Cofide Attestation Interceptor: `apps/signal-ingest` lacked an HTTP middleware interceptor implementing Cofide Go SDK contracts to validate inbound SPIFFE SVID bundles, check cryptographic signatures, parse ASN.1 DER certificate sequences, and enforce trust domain federation boundaries.
4. Missing Reverse Proxy for Federation Endpoints: `fe-signalloom/src/api_compat.py` lacked proxy routes under `/api/v1/federation/*` forwarding to `signal-ingest:8082` with authenticated tenant scoping and SPIFFE credential forwarding.
5. Incomplete Test Coverage: No table-driven tests existed in `apps/signal-ingest` for Cofide SVID validation scenarios, no Vitest suite existed for `FederatedServicesPage.tsx`, and no Pytest suite existed for federation proxy routes.

## Vision
A hardened, production-grade Federated Services surface (Surface 11) backed by an interactive `useFederatedServices` client hook, unified `fakeData.ts` fixture integration, robust server-side Go Cofide SVID interceptor in `signal-ingest`, FastAPI reverse proxying in `fe-signalloom`, and comprehensive test suites:
- Production-ready `FederatedServicesPage.tsx` free of illustrative disclaimers or placeholder warning badges.
- Seamless dual-mode operation: live mode fetches from `/api/v1/federation/*` with loading and error boundaries; demo mode serves hardened fixtures from `fakeData.ts` with simulated latency.
- Cryptographically sound `CofideInterceptor` in `apps/signal-ingest/api/cofide_interceptor.go` verifying SVID bundles, X.509 chains, ASN.1 DER encoding, RSA/ECDSA signatures, and SPIFFE trust domain matching (`spiffe://signalloom.demo/`).
- Multi-tenant reverse proxy in `fe-signalloom/src/api_compat.py` preserving caller tenancy (`X-Tenant-ID`) and forwarding SVID credentials.
- Table-driven Go unit tests validating valid SVIDs (200), forged signatures (401), expired certificates (401), untrusted trust domains (403), and malformed ASN.1 payloads (400).
- Vitest suite testing `FederatedServicesPage.tsx` rendering in both demo and live modes with zero "illustrative" strings.
- Pytest suite in `fe-signalloom` verifying tenant isolation and proxy forwarding.
- Strict zero em-dash compliance across all modified frontend and backend code.

## Out of Scope
- Fleet operational telemetry streaming (owned by P4-2).
- Collusion Access typography rewrite (owned by P4-3).
- Settings connector synchronization (owned by P5-1).
- Direct SPIRE server gRPC management (handled by spire_client).

## Principles
- Production Posture: The UI must present a professional, production-grade posture without draft disclaimers or placeholder markers.
- Defense in Depth: SVID attestation bundle verification is enforced cryptographically at the Go ingest gateway with strict trust domain boundaries.
- Multi-Tenant Isolation: Reverse proxy strictly derives tenant context from verified session state, never blindly trusting client headers.
- Transparent Fail-Closed: Invalid, expired, or tampered credentials fail closed with structured HTTP status codes (400, 401, 403) and audit logging.
- Deterministic Dual-Mode: Demo mode provides high-fidelity simulations of all six federation entities; live mode operates against live endpoints.

## Constraints
- TypeScript / React with Bun for frontend components and Vitest tests; no npm/npx.
- Go 1.26+ with `CGO_ENABLED=0` and temporary cache paths in `/tmp`.
- Python 3.12 with FastAPI and `uv` for `fe-signalloom`.
- Zero em-dashes (`—`) in all user-facing UI text and component strings.
- Conventional commits with `--no-gpg-sign`.

## Goal
Harden `FederatedServicesPage.tsx` by removing illustrative disclaimers and badges, moving fixtures to `api/fakeData.ts` behind `isDemoMode()` with live API integration, implementing the Cofide Go SDK SVID interceptor in `apps/signal-ingest/api/cofide_interceptor.go` with table tests, and proxying federation routes in `fe-signalloom/src/api_compat.py` with Pytest coverage.

## Criteria
- [x] ISC-1: `FederatedServicesPage.tsx` removes illustrative disclaimer text at lines 520-526 and placeholder disclaimer badge at line 577.
- [x] ISC-2: `FederatedServicesPage.tsx` replaces static banner with an environment indicator and live/demo mode status.
- [x] ISC-3: `TRUST_ZONES`, `FEDERATIONS`, `FEDERATED_SERVICES`, `POLICIES`, `SPIFFE_IDS`, and `FEDERATION_EVENTS` are exported from `api/fakeData.ts` and `api/fakeFederationData.ts`.
- [x] ISC-4: `fakeData.ts` demo route table registers routes for `/federation/summary`, `/federation/zones`, `/federation/federations`, `/federation/services`, `/federation/policies`, `/federation/identities`, and `/federation/events`.
- [x] ISC-5: `types/api.ts` declares complete TypeScript interfaces for `TrustZone`, `Federation`, `FederatedService`, `AttestationPolicy`, `SpiffeIdentity`, `FederationEvent`, and `FederationSummaryResponse`.
- [x] ISC-6: `api/client.ts` implements `getFederationSummary()`, `getFederatedZones()`, `getFederations()`, `getFederatedServices()`, `getAttestationPolicies()`, `getSpiffeIdentities()`, and `getFederationEvents()`.
- [x] ISC-7: `FederatedServicesPage.tsx` uses `useFederatedServices()` hook to fetch data in live mode and resolve fixtures in demo mode.
- [x] ISC-8: `FederatedServicesPage.tsx` renders loading state and error alert boundary on API failure in live mode.
- [x] ISC-9: `FederatedServicesPage.tsx` retains full `DataTable` filtering across all six tables with zero regressions.
- [x] ISC-10: `apps/signal-ingest/api/cofide_interceptor.go` implements HTTP middleware interceptor `CofideInterceptor` wrapping `http.Handler`.
- [x] ISC-11: `CofideInterceptor` extracts SPIFFE SVID from `X-SPIFFE-SVID` header or `Authorization: Bearer` token.
- [x] ISC-12: `CofideInterceptor` parses and decodes ASN.1 DER X.509 certificate bundles and extracts SPIFFE URI SANs.
- [x] ISC-13: `CofideInterceptor` enforces cryptographic signature validation using SHA-256 with trusted RSA/ECDSA trust bundle keys.
- [x] ISC-14: `CofideInterceptor` verifies certificate expiration and rejects expired certificates with 401 Unauthorized.
- [x] ISC-15: `CofideInterceptor` enforces trust domain matching (`spiffe://signalloom.demo/` or configured federated domains) and rejects untrusted domains with 403 Forbidden.
- [x] ISC-16: `CofideInterceptor` rejects malformed ASN.1 payload with 400 Bad Request.
- [x] ISC-17: `apps/signal-ingest/api/cofide_interceptor_test.go` implements table-driven tests verifying all 5 SVID scenarios.
- [x] ISC-18: `fe-signalloom/src/api_compat.py` implements reverse-proxy endpoints under `/api/v1/federation/*` forwarding to `signal-ingest` with `X-Tenant-ID` injection.
- [x] ISC-19: `fe-signalloom/src/tests/test_federation.py` pytest suite validates federation proxying, tenant header injection, and SVID forwarding.
- [x] ISC-20: `dashboard-signalloom/src/pages/FederatedServicesPage.test.tsx` vitest suite verifies rendering in demo and live modes.
- [x] ISC-21: Vitest suite asserts that no "illustrative" string exists in the rendered DOM of `FederatedServicesPage`.
- [x] ISC-22: `bun run typecheck` passes cleanly with zero TypeScript errors.
- [x] ISC-23: Anti: Zero occurrences of "illustrative" text or placeholder disclaimer badges in `FederatedServicesPage.tsx`.
- [x] ISC-24: Anti: Zero em-dashes (`—`) in modified UI components.

## Test Strategy
- ISC-1, 2, 23: Grep and AST inspection of `FederatedServicesPage.tsx`.
- ISC-3..6: Typecheck and `demoMode.test.ts` / fake route resolution tests.
- ISC-7..9, 20, 21: Vitest `src/pages/FederatedServicesPage.test.tsx`.
- ISC-10..17: Go table tests in `apps/signal-ingest/api/cofide_interceptor_test.go`.
- ISC-18, 19: Pytest `tests/test_federation.py` in `fe-signalloom`.
- ISC-22: `bun run typecheck`.
- ISC-24: `grep -rn '—' src/pages/FederatedServicesPage.tsx`.

## Features
- Feature 1: TypeScript Types & Client API Methods (`types/api.ts`, `api/client.ts`) | satisfies: ISC-5, 6 | status: done
- Feature 2: Demo Fixtures & Fake Route Handlers (`api/fakeFederationData.ts`, `api/fakeData.ts`) | satisfies: ISC-3, 4 | status: done
- Feature 3: UI Hardening & FederatedServicesPage Refactor (`pages/FederatedServicesPage.tsx`) | satisfies: ISC-1, 2, 7, 8, 9, 23, 24 | status: done
- Feature 4: Server-Side Cofide Go SVID Interceptor (`signal-ingest/api/cofide_interceptor.go`) | satisfies: ISC-10..16 | status: done
- Feature 5: Go Table-Driven Unit Tests (`signal-ingest/api/cofide_interceptor_test.go`) | satisfies: ISC-17 | status: done
- Feature 6: FastAPI Reverse Proxy Routes (`fe-signalloom/src/api_compat.py`, `fe-signalloom/src/routers/federation.py`) | satisfies: ISC-18 | status: done
- Feature 7: Pytest Federation Test Suite (`fe-signalloom/src/tests/test_federation.py`) | satisfies: ISC-19 | status: done
- Feature 8: Vitest Suite & Frontend Verification (`pages/FederatedServicesPage.test.tsx`) | satisfies: ISC-20, 21, 22 | status: done

## Decisions
- 2026-09-29: Define `fakeFederationData.ts` to isolate federation data fixtures and avoid bloat in `fakeData.ts`, then re-export and register in `ROUTES`.
- 2026-09-29: Build `CofideInterceptor` in `apps/signal-ingest/api/cofide_interceptor.go` supporting both raw X.509 DER bundles (base64/PEM) and JWT-SVID tokens with SPIFFE URI SAN validation.
- 2026-09-29: Cleanse all em-dashes (`—`) in `FederatedServicesPage.tsx` and replace with colons or parentheses according to PAI platform rules.

## Changelog
- 2026-09-29: Initialized ISA for SLMS-P4-1 Federated Services Demo Data Hardening & Cofide Interceptor.
- 2026-09-29: Completed all frontend fixtures, API types, UI cleansing, Go SVID interceptor, table tests, FastAPI proxy, and Pytest verification.

## Verification
- Go interceptor tests: 100% pass (`TestCofideInterceptor_TableDriven`, `TestCofideInterceptor_PublicKeyValidation`).
- Frontend vitest tests: 100% pass (`FederatedServicesPage.test.tsx` 8/8, `demoMode.test.ts` 24/24).
- TypeScript check: `bun run typecheck` 0 errors.
- Python pytest tests: 100% pass (`test_federation.py` 8/8).
- Typography & Anti-patterns: 0 occurrences of "illustrative", 0 em-dashes.
