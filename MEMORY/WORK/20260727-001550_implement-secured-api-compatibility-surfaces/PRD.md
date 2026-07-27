---
task: Implement secured API compatibility surfaces with verified evidence
slug: 20260727-001550_implement-secured-api-compatibility-surfaces
effort: advanced
phase: complete
progress: 24/24
mode: interactive
started: 2026-07-27T00:15:50+01:00
updated: 2026-07-27T00:42:55+01:00
---

## Context

Implement card SLDPB25-P2-3 inside the assigned isolated worktree. The result must establish an initial local `/api` compatibility boundary for agents, compliance, audit, and settings; authenticate requests using validated JWTs; map subjects to tenants; return typed response contracts; and avoid leaking internal failures. Unit and contract tests must run without external calls. Repository changes must be committed, while `board.json`, other worktrees, remotes, and pull requests remain untouched. The proposal must receive evidence and a machine-readable `kanban-check` result based strictly on verified outcomes.

### Risks

The integration ref may drift concurrently, invalidating final ancestry despite a passing pre-change gate. Existing dependencies may not offer an offline JWT verifier, so implementation must respect repository package policy before adding anything. Contract shapes must come from local dashboard calls rather than assumptions. Tests must inject local keys and prohibit OIDC or JWKS network discovery. Proposal mutation must use Obsidian's CLI writer to avoid racing the application's in-memory buffer.

### Plan

First verify the required integration ref is an ancestor of task HEAD and inspect working-tree state. Derive endpoint paths and response fields from local dashboard sources. Extend the existing FastAPI service using its established configuration and test patterns, introducing only policy-approved dependencies if unavoidable. Keep authentication deterministic and offline by injecting verification material and a subject-to-tenant map. Exercise focused unit and contract tests, then broader existing checks. Review the diff, commit only scoped files, revalidate ancestry, and append evidence plus the final machine-readable status through the Obsidian CLI.

## Criteria

- [x] ISC-1: Integration branch ancestry passes before implementation files change
- [x] ISC-2: Protected API rejects requests missing bearer authorization tokens
- [x] ISC-3: Protected API rejects structurally malformed bearer authorization tokens
- [x] ISC-4: JWT validation rejects tokens carrying invalid signatures
- [x] ISC-5: JWT validation rejects tokens carrying unexpected issuer claims
- [x] ISC-6: JWT validation rejects tokens carrying unexpected audience claims
- [x] ISC-7: JWT validation rejects tokens carrying expired time claims
- [x] ISC-8: JWT validation rejects tokens missing required subject claims
- [x] ISC-9: Known JWT subjects resolve to deterministic tenant identifiers
- [x] ISC-10: Unknown JWT subjects receive authorization denial responses
- [x] ISC-11: Agents endpoint returns its documented typed response schema
- [x] ISC-12: Compliance endpoint returns its documented typed response schema
- [x] ISC-13: Audit endpoint returns its documented typed response schema
- [x] ISC-14: Settings endpoint returns its documented typed response schema
- [x] ISC-15: Successful responses contain only authenticated tenant-scoped records
- [x] ISC-16: API errors use stable typed JSON response bodies
- [x] ISC-17: Internal exception details never appear in client responses
- [x] ISC-18: Unsupported methods receive stable typed error responses
- [x] ISC-19: Unit tests cover JWT validation security branches
- [x] ISC-20: Unit tests cover subject tenant mapping branches
- [x] ISC-21: Contract tests cover four compatibility endpoint schemas
- [x] ISC-22: Test execution performs zero external network calls
- [x] ISC-23: Scoped repository changes are committed with verified SHA
- [x] ISC-24: Proposal records evidence and machine-readable kanban-check status

## Decisions

Merged `integration/signalloom-d2-v2.5.0` into the isolated task branch only after proving both histories diverged, incoming files had zero overlap with the pre-existing dirty paths, and the merge could preserve prior work. Post-merge ancestry exited zero at `86e6de27ed041ea98d64ece669ce474f4df58d3a` before compatibility implementation files changed.

Reconstructed the API boundary from hard constraints rather than importing a hosted OIDC shape: local deterministic data, offline token verification, explicit tenant mapping, stable schemas, and fail-closed errors. Used the standard library for strict HS256 validation because no third-party JWT dependency was present and external package/network activity was forbidden. Runtime wiring stores the demo secret in the existing demo-only Kubernetes Secret rather than exposing it as ordinary settings data.

## Verification

- ISC-1: `git merge-base --is-ancestor integration/signalloom-d2-v2.5.0 HEAD` exited 0 at pre-implementation HEAD `86e6de27ed041ea98d64ece669ce474f4df58d3a`.
- ISC-2 through ISC-22: hermetic container command using `fe-signalloom:p6-test`, exact pinned application dependencies, `--network none`, read-only source mount, and cached pytest-only tooling exited 0 with `24 passed in 0.41s` across health, adapter, JWT, tenant mapping, four response contracts, OpenAPI typing, unsupported methods, fail-closed configuration, and non-disclosure tests.
- Existing package gate: `make -C d2-signalloom test` exited 0; topology validation, dependency validation, Go proof-helper tests, and 20 BATS assertions passed.
- ISC-23: six scoped files committed as `5609c5f3f055d9d1ebaa7602c5c0b5c079eae466` (`feat(signalloom): add secured API compatibility surface`). Concurrent integration drift was reconciled by merge-only final HEAD `e799fb3c23ee49817b199c607aa8a34a9b577e25`; the scoped diff from feature commit to final HEAD exited 0, proving no implementation mutation.
- ISC-24: Obsidian CLI appended verified errata at proposal lines 525-550. The JSON `kanban-check.v1` and plain marker both record `status=pass proceed=yes blocking_drift=no`, feature commit, final HEAD, integration SHA, ancestry exit, tests, changed files, and prohibited-action evidence.
- Capability audit: FirstPrinciples, Delegation, Engineer, CodeReview, and QATester were each invoked. roborev itself was unavailable; QATester independently inspected the implementation and reran the hermetic suite successfully.
