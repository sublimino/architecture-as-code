---
task: Define Dex OIDC design and auth test cases
slug: 20260727-142300_dex-oidc-design-auth-tests
effort: extended
phase: complete
progress: 18/18
mode: interactive
started: 2026-07-27T14:23:51+01:00
updated: 2026-07-27T14:40:00+01:00
---

## Context

Implement SLDPB25-P1-3 only in the designated Signal Loom integration
worktree. The required outcome is a local, non-production Dex/OIDC contract
for the dashboard and deterministic tests for the compatibility API. Existing
files may satisfy parts of the card, but every stated artifact and test must be
re-validated against the current integration HEAD before relying on it. The
source proposal must remain unmodified; repository-local errata records the
implemented boundary.

### Risks

The prior local design may be present while its source tests or erratum drift
from current manifests. The design must not imply that API HS256 compatibility
tokens are Dex-issued JWKS tokens. Existing untracked files belong to parallel
card work and must not be staged or committed.

## Criteria

- [x] ISC-1: Integration HEAD descends from required base reference.
- [x] ISC-2: Design specifies the exact local Dex issuer URL.
- [x] ISC-3: Design specifies the discovery endpoint URL.
- [x] ISC-4: Design specifies the JWKS endpoint URL.
- [x] ISC-5: Design specifies the dashboard client identifier.
- [x] ISC-6: Design specifies the dashboard client secret boundary.
- [x] ISC-7: Design specifies the registered dashboard callback URI.
- [x] ISC-8: Design specifies the static demonstration subject identifier.
- [x] ISC-9: Design prohibits plaintext demo password storage.
- [x] ISC-10: Design enumerates mandatory ID-token validation claims.
- [x] ISC-11: Design defines server-owned subject tenant mapping.
- [x] ISC-12: Design rejects caller-controlled tenant selection.
- [x] ISC-13: Unit tests validate static OIDC manifest contract.
- [x] ISC-14: API tests accept mapped valid bearer tokens.
- [x] ISC-15: API tests reject missing required API audiences.
- [x] ISC-16: API tests deny unmapped token subjects.
- [x] ISC-17: API tests ignore forged tenant claims.
- [x] ISC-18: Proposal errata states local-only validation boundary.

## Decisions

Keep the API implementation's explicit local HS256 compatibility boundary.
Add only the missing positive test that binds the documented deployment mapping;
correct the design test-layer label rather than misrepresenting runtime proof.

## Verification

Initial and pre-commit ancestry checks confirm that integration HEAD descends
from `refs/heads/integration/signalloom-d2-v2.5.0`. `make -C d2-signalloom
test` passed topology, dependency, Go, and 29 BATS checks. `PYTHONPATH=. uv
run --with pytest --with-requirements requirements.txt pytest
tests/test_api_compat.py` passed 18 tests. `make test-docker` is not a declared
target; the Docker-sensitive Dex runtime test is already included by
`make test`. `git diff --check` passed. CodeReview was invoked, but roborev is
not installed, so no automated review result is represented as a pass.
Committed remediation SHA: `55a6e79ca2963373a7215cbf6d97ddb752c83f94`.
Post-commit ancestry, diff check, `make test`, and API suite all passed.
