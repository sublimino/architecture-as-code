---
task: Implement Dex OIDC design contract tests errata
slug: 20260727-121600_dex-oidc-design-contract-tests-errata
effort: extended
phase: verify
progress: 18/18
mode: interactive
started: 2026-07-27T12:16:00+01:00
updated: 2026-07-27T12:24:00+01:00
---

## Context

Implement only SLDPB25-P1-3 in the designated integration worktree. The
repository already carries a local Dex manifest and dashboard OIDC environment
contract. This card makes that local replacement explicit, testable, and
traceable without production federation, cluster changes, board edits, proposal
edits, a push, or a pull request. The proposal errata must preserve the source
proposal and record only the local design and deterministic-test boundary.

### Risks

The manifest's static client secret is an intentional demo fixture, so the
design must label it non-production and tests must avoid normalising its reuse.
Dex publishes standard OIDC claims but does not mint a tenant claim; the server
must own the subject-to-tenant mapping and deny a caller-selected tenant. The
existing tests are source-level contracts, so no test result may be described as
a live issuer, JWKS, or browser-flow proof.

## Criteria

- [x] ISC-1: Integration HEAD descends from required base reference.
- [x] ISC-2: Design identifies the local Dex issuer URL.
- [x] ISC-3: Design identifies the OpenID discovery endpoint URL.
- [x] ISC-4: Design identifies the JWKS endpoint URL.
- [x] ISC-5: Design identifies the dashboard client identifier.
- [x] ISC-6: Design identifies the dashboard callback URI.
- [x] ISC-7: Design constrains the client secret to demo use.
- [x] ISC-8: Design identifies the static demo subject identifier.
- [x] ISC-9: Design identifies the static demo email address.
- [x] ISC-10: Design prohibits plaintext demo credential storage.
- [x] ISC-11: Design enumerates required ID-token claims.
- [x] ISC-12: Design defines audience validation for dashboard tokens.
- [x] ISC-13: Design defines subject-to-tenant mapping ownership.
- [x] ISC-14: Design rejects client-supplied tenant selection.
- [x] ISC-15: Unit contract tests verify documented static configuration.
- [x] ISC-16: API contract tests verify accepted token flow.
- [x] ISC-17: API contract tests verify tenant mismatch denial.
- [x] ISC-18: Proposal errata records local-only validation boundary.

## Decisions

The implementation will test checked-in contracts and deterministic local
handlers only. It will not provision Dex, issue a live token, alter production
federation, or introduce credentials outside the existing demo fixture.

## Verification

Ancestry checked at `d51bfc61cde25c155274fabaaf9848b3fa6c5a9c`.
`bats d2-signalloom/test/dex-auth.bats` passed 6/6. Hermetic `uv run`
API suite passed 17 tests. `git diff --check` passed before review.
