# Signalloom Phase 2 pre-flight retry

Created: 2026-07-27 07:25:00+01:00  
Claimed fixed commit: `e799fb3c23ee49817b199c607aa8a34a9b577e25`  
Task worktree: detached at `e799fb3`

## Qualified gate result

**`status=fail proceed=no blocking_drift=yes`**

The claimed commit has a green Phase 1 repository baseline, but the named local
integration refs do not match the claimed state: `integration/signalloom-d2-v2.5.0`
resolves to `d6da1e7`, `integration/signalloom-d2-v2.0.0` resolves to `346e830`,
and those refs are not ancestors of one another. The fixed commit exists and is
an ancestor of the v2.5 ref, but the asserted ref equality is not verifiable in
this worktree.

## Checks

```text
git merge-base --is-ancestor e799fb3 integration/signalloom-d2-v2.5.0  # 0
git merge-base --is-ancestor integration/signalloom-d2-v2.5.0 \
  integration/signalloom-d2-v2.0.0                                      # 1
env LC_ALL=C LANG=C make signalloom-check                               # 0
env LC_ALL=C LANG=C bats test/signalloom-local-lifecycle.bats \
  test/signalloom-preflight.bats                                        # 0 (8/8)
env LC_ALL=C LANG=C make -C d2-signalloom test                          # 0 (20/20)
bash -n scripts/signalloom-contract-check.sh scripts/signalloom-preflight.sh \
  scripts/signalloom-local.sh scripts/signalloom-up.sh \
  scripts/signalloom-down.sh agent/harness.sh                          # 0
python3 -m pytest -q d2-signalloom/apps/fe-signalloom/src/tests/test_api_compat.py # 1 (pytest unavailable)
bunx --package=@playwright/test playwright test \
  test/acceptance/dashboard-journey.spec.ts                             # 1 (CLI unknown command)
```

## Phase 2 review

- The claimed commit adds `api_compat.py`, four typed `/api` routes, tenant
  mapping, HS256 JWT validation, and focused API contract tests.
- `dashboard-journey-matrix.md` covers routes, API journeys, auth/error states,
  fake interactions, and baseline coverage.
- A complete Dex/OIDC provider contract remains absent: no client registration,
  discovery/JWKS flow, redirect URI, logout, or browser login/expiry test was
  found. The API config only names a Dex issuer while validating locally issued
  HS256 tokens.
- The two Signalloom ResourceSet files remain byte-identical duplicates with
  SHA-256 `3ad16a83a0fba0ca7c652c0813d656817232736e6271b209e41cdf7e0a2d3e1e`.
- The dependency expression remains `status.observedGeneration >= 0`, which
  does not establish the dependency's Ready condition.

Phase 2 implementation remains blocked pending named-ref reconciliation, a
complete Dex/OIDC browser contract, canonical ResourceSet ownership, and
installable focused API/browser test runners.

## SLDPB25-P1-3 local Dex/OIDC design erratum

<!-- machine-tag: SLDPB25-P1-3-DEX-OIDC-ERRATA-2026-07-27T12:20:00+01:00 -->
<!-- scope: local-demo-design-and-deterministic-contracts-only -->

`docs/signalloom/dex-oidc-design.md` now records the checked-in local Dex
issuer, discovery/JWKS endpoints, dashboard client, callback, static demo
subject, credential-verifier boundary, claims, and server-owned tenant mapping.
This corrects the historical observation at lines 42-45: local client
registration, redirect URI, discovery, and JWKS configuration now exist.

The material limitation remains: the compatibility API validates a separate
HS256 bearer-token contract and does not validate a Dex-issued token through
JWKS. The design therefore explicitly separates dashboard OIDC metadata from
API bearer acceptance and adds deterministic source/API tests for that boundary.
It does not claim browser login, callback, logout, token exchange, production
federation, external Auth0 connectivity, a deployed cluster, or a production
tenant-isolation approval. The source proposal was not modified.
