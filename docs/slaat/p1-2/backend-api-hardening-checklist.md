# SLAAT-P1-2 → SLAAT-P2-2 Handoff: Backend API Hardening Checklist

Mirrors the fix/advisory/backlog/clean structure of `docs/slaat/p1-1/network-hardening-checklist.md`.

## Fix (Phase 2, `SLAAT-P2-2`)

- [ ] **F1 — No rate limiting.** Add an ASGI rate limiter (e.g. `slowapi`),
  scoped at minimum to JWT-verification-failure paths and the external-agent
  enrollment/token endpoints. See `rate-limiting-and-cors-audit.md`.
- [ ] **F3 — `routers.policies`'s own routes have no auth dependency.**
  Either delete the dead code (`validate_policy_expression`, `evaluate_policies`,
  `register_bundle`, `rollback_bundle` as directly-mounted routes — they are
  only reachable today via `routers.policy_engine`'s internal function calls)
  or add explicit `Depends(authenticated_tenant)` so correctness does not
  depend on `main.py`'s `install_*_api` call order. A regression test
  (`test_policies_router_own_routes_are_unreachable_dead_code`) will fail
  loudly if the shadow ever breaks before this is fixed — treat that failure
  as a live incident, not a flake.

## Advisory (Phase 2, lower priority)

- [ ] **F2 — Dead `cors_allowed_origins` setting.** Decide: wire
  `CORSMiddleware` using the existing setting, or remove it if CORS is
  intentionally handled at the Gateway (coordinate with `SLAAT-P2-1`).
- [ ] **F4 — Inconsistent error-message hygiene.** `routers/discovery.py`'s
  broad `except Exception as exc: ... f"...{exc}"` pattern should route
  through `api_compat.install_api_exception_handlers`'s generic envelope
  instead of including raw exception text. Grep for the same pattern in other
  ad-hoc handlers while in this area.
- [ ] **F5 — `threading.Lock` across an `await`.** Replace
  `host_enrollment._HOST_ENROLL_LOCK` with an `asyncio.Lock` for the
  in-memory fallback path, or add an explicit assertion/comment that nothing
  inside the critical section may ever perform a real suspending `await`.

## Backlog (design question, not a defect)

- [ ] **Agent-transition synthesize-on-miss semantics.**
  `routers/agents.py`'s transition handler creates a new local agent record
  when the caller's tenant has no existing record for the referenced
  `agent_id`, rather than 404ing. Not a leak (verified: never touches another
  tenant's actual record), but worth an explicit product decision on whether
  "touch to create" is the intended contract for this endpoint.

## Clean (verified, no action needed)

- [x] SQL injection: all six dynamic-WHERE-clause f-string sites verified
  safe (placeholders/identifiers only); SQL-injection-shaped values confirmed
  inert as ordinary data across connector, agent-ID, and search inputs.
  Regression-guarded by `test_known_fstring_sql_site_only_interpolates_safelisted_names`.
- [x] JWT/OIDC verification: alg confusion (`none`, HS256-with-RSA-pubkey),
  kid substitution/omission, signature stripping, payload tampering,
  duplicate-key/non-object/JSON-constant payloads, expired/not-yet-valid,
  wrong aud/iss/azp, and forged tenant claims all fail closed.
- [x] Cross-tenant IDOR/BOLA across connectors, agents, external-agent
  registration, and host enrollment — all isolated correctly.
- [x] Enrollment CAS/replay: true `asyncio`-concurrency race (16 tasks),
  single winner, no deadlock; token bit-flip tampering rejected without
  burning the real token; cross-agent token binding enforced.
- [x] No unauthenticated mutation path returns anything but 401/403/404/422,
  and no error response leaks a stack trace, SQL text, or exception repr,
  across the full fuzz/forged-signature sweep of all 8 newly-swept routers.
