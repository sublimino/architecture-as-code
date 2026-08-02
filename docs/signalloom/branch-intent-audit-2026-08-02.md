# Branch intent audit — 2026-08-02

Before advancing `feat/signal-loop-and-bootstrap-refactor` for the five dashboard feature tracks,
every branch carrying commits not on the feature branch was assessed. The question asked was **not**
"can this merge cleanly" but **"is the intent of this code already on the feature branch"** —
because two of these branches conflict, and force-merging a stale branch reverts newer work.

## Merged

| Branch | Commit | Result |
| --- | --- | --- |
| `feat/signalloom-onboarding-api` | `4b16840` onboarding status and wizard-state API | Merged cleanly (605 insertions) |
| `task/signalloom-d2-v2.5.0-retest-1` | `fda939c` record bounded security validation | Merged cleanly |

## Not merged — intent already present

Four branches conflicted or were stale. Each was verified by comparing capability, not commits.

### `task/sldpb25-p2-1-dex` (27 Jul) — "complete local Dex OIDC proof"

Conflicts in `dex.yaml`, `dex-auth.bats`, `dex-runtime.bats`. **Intent present.** The feature branch
carries the identical test surface:

```
branch: @test "Dex serves discovery and JWKS from its local issuer"
        @test "Dex issues a signed ID token for the deterministic demo user"
FB:     @test "Dex serves discovery and JWKS from its local issuer"
        @test "Dex issues a signed ID token for the deterministic demo user"
```

The feature branch's `dex-runtime.bats` is 122 lines to the branch's 116, and five later Dex commits
sit on top (`34852b6` URL migration + public-client token exchange, `66aa347` issuer/test URL
unification, `360bb29` gateway E2E + Dex OIDC + SPIRE proof convergence). Merging would revert them.

### `task/sldpb25-p2-3` (27 Jul) — "validate Dex JWTs through JWKS"

Conflicts in `api_compat.py`, `deployment.yaml`, `dex.yaml`, acceptance specs. **Intent present.**
The feature branch's `api_compat.py` already implements exactly what this branch introduces:

```python
def _jwk_client(jwks_url: str) -> jwt.PyJWKClient:
    return jwt.PyJWKClient(jwks_url, cache_keys=True)

def validate_jwt(token: str) -> dict[str, Any]:
    """Validate a Dex RS256 ID token against the configured JWKS endpoint."""
```

Same helper, same signature, same docstring, same `PyJWKClient(cache_keys=True)`, same
malformed-JWT guard. A naive line-by-line diff reported 22% coverage; that was a false negative from
formatting and import-position drift, not missing capability.

### `integration/signalloom-d2-v2.0.0-p2-8-morning` (26 Jul)

**Intent present and extended.** The feature branch's `test/demo-lifecycle.bats` is a strict superset
— it contains all five of the branch's tests plus five more (foundation-only startup, demo help,
control panel, Signal Loom health check, inactive ResourceSet defaults). 157 lines to the branch's
62. `docs/signalloom/P2-8-morning-debugging-appraisal.md` is present.

### `main` (`54ac3dc`) — "sync worktree test files + fix CI Playwright environment"

**Intent present and extended.** `test/acceptance/helpers.ts` exists on the feature branch at 246
lines against main's 164, and exports `login` and `loginExpectingDex` — the later, richer version.

## Deliberately excluded

`origin/dependabot/go_modules/.../go_modules-19eec7a033` — bumps the go_modules group across four
directories (`go 1.23.0` → `1.25.0`, `pgx/v5 5.7.6` → `5.9.2`, plus `golang.org/x/crypto`,
`x/sync`, `x/sys`, `x/text`). Legitimate and worth taking, including for the `x/crypto` update, but
it is a cross-cutting toolchain and dependency change with its own build risk. It does not belong
folded into feature work and should land as its own reviewed change.

## Method note

Exact-line matching is necessary but not sufficient for this question. It reported 3–47% coverage
across these branches while capability-level inspection showed 100%. Where a branch is old and the
target has been refactored since, the literal lines diverge even when the behaviour is identical —
so every "absent" result was checked against the actual implementation before drawing a conclusion.
Line matching finds candidates; it does not settle intent.
