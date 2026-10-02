# SLAAT-P1-2 — Rate Limiting & Abuse Resistance Audit

## Current state: no rate limiting anywhere in the application layer

Confirmed by exhaustive search (`rg -ni "ratelimit|rate_limit|slowapi|limiter" **/*.py`)
and by direct inspection of `main.py`'s middleware stack (`app.user_middleware`
contains only `IdentityHeaderStripMiddleware` and, once `install_compatibility_api`
runs, `HostCredentialScopeMiddleware` — no rate limiter, no throttle, no
circuit breaker).

**Test evidence:** `test_adversarial_api_security.py::test_no_rate_limiting_middleware_is_installed`
— 50 rapid identical unauthenticated requests to `/health`, zero 429s.

### What this means concretely

- **Authentication endpoints:** `authenticated_principal`/`validate_jwt` run on
  every request with no attempt-count tracking. A forged-token brute force
  (trying many `sub` values, many `kid` guesses, etc.) has no backstop beyond
  the inherent cost of RSA signature verification itself.
- **Token/enrollment endpoints:** `host_enrollment.py`'s one-time enrollment
  token redemption and `issue_token_handler` rotation have no throttle. The
  CAS/atomicity properties verified in `test_enrollment_cas_race_adversarial.py`
  hold regardless, but an attacker can still hammer the endpoint at whatever
  rate the network allows.
- **Unauthenticated, CPU-bound surfaces:** F3 in the dossier (the currently-
  shadowed `routers.policies` CEL-validate route) would be a direct
  unauthenticated-DoS vector if that shadow ever breaks, precisely because
  there is no rate limiter as a second line of defense.

### Out of scope for this card

Gateway/ingress-level rate limiting is `SLAAT-P1-1`/`SLAAT-P2-1`'s territory
(Envoy Gateway). This audit covers the **application layer** only, per this
card's objective ("Evaluate rate limiting, request throttling, and brute
force defenses across authentication and token refresh endpoints").

### Recommendation for `SLAAT-P2-2`

Add `slowapi` (or equivalent ASGI-level limiter) scoped at minimum to:
`authenticated_principal`'s JWT verification failure path, `/api/v1/external-agents/enroll`,
`/api/v1/external-agents/{agent_id}/token`, and any route identified in F3 as
unauthenticated. Prefer per-IP + per-subject-claim keying so a single forged
token's many redemption attempts cannot bypass an IP-only limit.

## Current state: CORS middleware is declared but not installed

`config.py`'s `Settings.cors_allowed_origins` names two origins
(`https://signal-loom.ai`, `https://dev.signal-loom.ai`), but no
`CORSMiddleware` is ever added to the app
(`test_adversarial_api_security.py::test_cors_allowed_origins_setting_is_not_wired_to_any_middleware`).
See Finding F2 in the dossier for severity and remediation. This is a
configuration-integrity issue (the setting lies about what's enforced), not
by itself a demonstrated cross-origin credential leak — Starlette's default
behaviour with no CORS middleware does not add permissive
`Access-Control-Allow-Origin` headers.
