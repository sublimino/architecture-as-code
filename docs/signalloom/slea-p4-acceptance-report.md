# SLEA-P4-2 — kurasi EAP Environment Lifecycle Acceptance Report

- **Card:** SLEA-P4-2 (implementation), base `integration/slea-v0.1.0` @ `8629b5f8`
- **Run date:** 2026-09-23
- **Suite:** `d2-signalloom/apps/fe-signalloom/src/tests/test_kurasi_eap_lifecycle.py` (13 tests)
- **Evidence files:** `slea-p4-2-kurasi-lifecycle-trace.json` (request and response bodies for every lifecycle step, plus the telemetry stream), `slea-p4-2-security-headers.json` (header conformance for 13 response cases)

Run command, from `d2-signalloom/apps/fe-signalloom/src`:

```bash
UV_CACHE_DIR=/home/andy/src/.worktrees/.uvcache \
uv run --python 3.12 --with pytest --with pytest-asyncio \
  --with-requirements requirements.txt python -m pytest -p no:cacheprovider \
  tests/test_kurasi_eap_lifecycle.py -v
```

Set `EAP_LIFECYCLE_TRACE=<path>` and `EAP_HEADER_REPORT=<path>` to re-emit the evidence files. Without them, the files are written under pytest's `tmp_path`.

## What is and is not proven

This suite proves the **engine and REST contract** in-process: FastAPI `TestClient` against the real `main.app`, with a fresh registry per test.

**Tailscale is exercised only in explicitly pinned mock mode** (`TAILSCALE_MOCK=1`, with a private `TAILSCALE_MOCK_DIR` under `tmp_path`). Real-mesh provisioning is **not** proven here, and was deliberately not attempted. The live branch of `scripts/eap/tailscale-eap-env.sh` runs `tailscale up --hostname=sl-eap-<hash>`, and its teardown runs `tailscale serve reset` and `tailscale logout`. Run on the developer workstation (node `fortuna`, tailnet `taild4da3.ts.net`), that would rename the workstation's own node and log it off the tailnet. A real-mesh run needs a disposable node with an ephemeral auth key.

Read-only live probe (`tailscale status --json`): MagicDNS suffix `taild4da3.ts.net`, self `fortuna.taild4da3.ts.net.`. So the contract string `https://sl-eap-6f82ad81.ts.net` is **not** a resolvable MagicDNS FQDN. A real node would be `sl-eap-6f82ad81.taild4da3.ts.net`.

## Prior-work verification

| Artifact | Probe | Result |
| :--- | :--- | :--- |
| `scripts/eap/tailscale-eap-env.sh` | read `calc_hash`, `cmd_provision`, `cmd_teardown`; exercised by suite in mock mode | Hash is identical to the Python engine (`6f82ad81`). Live mode is unsafe on a workstation (see above). Mock mode auto-enables **only** when the `tailscale` binary is absent, so on this host the default is live. |
| `src/environment_routing.py` (520 lines) | read; mutation-tested | Kept. Extended additively (see below). |
| `src/tests/test_environment_routing.py` | `pytest tests/test_environment_routing.py -q` | 15 passed (before and after changes) |
| `scripts/eap/test_tailscale_eap_env.sh` | `bash scripts/eap/test_tailscale_eap_env.sh` | 15 passed, 0 failed |
| `main.py` wiring | `rg install_environment_routing_api main.py` | import at line 15, mounted at line 42 |

## Engine changes (additive)

- `oidc_redirect_uri` (`https://sl-eap-<hash>.tailscale/auth/callback`) in `build_environment_urls`, `EnvironmentResponse` and `DomainResolutionResponse`.
- `expiry_warning` flag: true when less than 30 minutes remain (`EXPIRY_WARNING_THRESHOLD_MINUTES`); never true once terminated.
- `GET /{id}/probe`: returns 200 while serving, 503 while tearing down, 410 once terminated, and 404 for an unknown id.
- Extend on a terminated environment now returns **410 Gone** (was 400).
- A per-environment lifecycle event log (`provisioned`, `ttl_extended`, `teardown_requested`, `terminated`). Teardown now passes through `TEARING_DOWN` before `TERMINATED`. A repeated teardown is a true no-op: no version bump, no new event, and the original reason is kept.
- `WS /{id}/telemetry` streams the event log as JSON frames, then sends `stream_end` and closes with code 1000. It refuses an unknown id with close code 4404.
- Security headers middleware (CSP `default-src 'none'; frame-ancestors 'none'`, HSTS, `X-Frame-Options: DENY`, `nosniff`, `Referrer-Policy: no-referrer`). It is scoped to `/api/v1/environments`, because an app-wide strict CSP would break `/docs`.

## Results

### Lifecycle trace (from `slea-p4-2-kurasi-lifecycle-trace.json`)

| Step | Request | Status | Key assertion |
| :--- | :--- | :-: | :--- |
| 1 | `POST /provision {company_name: kurasi, ttl_minutes: 180}` | 201 | hash `6f82ad81`, `https://sl-eap-6f82ad81.tailscale`, `https://sl-eap-6f82ad81.ts.net`, `expires_at - created_at == 180m` |
| 2a/2b | `POST /resolve-domain` by name, then by hash | 200/200 | identical URL sets, `is_active: true`, same `environment_id` |
| 3 | `GET /{id}` | 200 | state `ready` |
| 3b | `GET /{id}/probe` | 200 | `reachable: true` |
| 4 | `POST /{id}/extend {additional_minutes: 120}` | 200 | new `expires_at − previous == 120m` exactly (04:59:40 → 06:59:40 UTC) |
| 5 | `POST /{id}/teardown {reason: Acceptance test completed}` | 200 | state `terminated` |
| 6 | repeat teardown | 200 | state `terminated`, `expires_at` unchanged |
| 7 | `GET /{id}/probe` | 410 | Gone |
| 8 | `POST /resolve-domain` | 200 | `is_active: false` |
| 9 | `WS /{id}/telemetry` | — | `provisioned, ttl_extended, teardown_requested, terminated, stream_end` |

### Suite (`pytest tests/test_kurasi_eap_lifecycle.py -v`)

```
test_kurasi_full_lifecycle PASSED
test_kurasi_canonical_hash_strict PASSED
test_kurasi_extend_and_teardown PASSED
test_kurasi_teardown_idempotency PASSED
test_kurasi_oidc_redirect_url PASSED
test_kurasi_ttl_expiry_warning PASSED
test_kurasi_post_teardown_cleanup PASSED
test_kurasi_websocket_telemetry_streaming PASSED
test_security_response_headers PASSED
test_kurasi_synthetic_http_client PASSED
test_kurasi_concurrent_provision_race PASSED
test_kurasi_graceful_error_during_teardown PASSED
test_kurasi_chaos_pod_restart_recovery PASSED
13 passed, 1 warning in 1.58s
```

Every required `-k` selector (`full_lifecycle`, `canonical_hash_strict`, `extend_and_teardown`, `teardown_idempotency`, `oidc_redirect_url`, `post_teardown_cleanup`, `websocket_telemetry_streaming`, `security_response_headers`) was run individually. Each gave `1 passed, 12 deselected`, so none of them is a zero-match false green.

### Flakiness: 10 consecutive executions

10/10 runs gave `13 passed`, with wall times between 1.57s and 1.66s. No test sleeps on a TTL: the expiry-warning boundary is driven by setting `expires_at` directly (±1 minute either side of 30), and the extend check compares relative deltas, never wall-clock values.

### Mutation checks (tests must fail when the behaviour is removed)

| Mutation | Tests that went red |
| :--- | :--- |
| Middleware stops setting headers | `test_security_response_headers` |
| Extend-after-teardown returns 400 instead of 410 | `test_kurasi_post_teardown_cleanup`, `test_security_response_headers` |
| `ttl_extended` event not recorded | `test_kurasi_full_lifecycle`, `test_kurasi_websocket_telemetry_streaming` |

The source file was restored from a backup under a trap and confirmed byte-identical with `cmp`.

### Security headers

All 13 cases carry the full header set, including the error paths: `provision-201/409/422`, `resolve-200/400`, `list-200`, `get-200/404`, `probe-200/410`, `extend-200/410`, `teardown-200`. `/health` does not carry the CSP (scoping check). The per-case detail is in `slea-p4-2-security-headers.json`.

### Synthetic users, concurrency, chaos

- **Synthetic client:** 8 virtual users × 10 rounds × (resolve, status, probe) = 240 requests, all 200, p95 latency under 1s. `/docs` (the only HTML fe-signalloom serves) returns 200 with `<title>Signal Loom Discovery Portal`.
- **Provision race:** 6 concurrent `kurasi` provisions produce exactly one 201 and five 409s. 6 distinct tenants get 6 distinct hashes, none equal to `6f82ad81`.
- **Mid-teardown request:** a probe while the environment is `TEARING_DOWN` gets a structured JSON 503, not a crash.
- **Pod-restart chaos:** a probe loop runs while the in-memory registry is swapped out. It only ever sees 200 or 404, never 5xx. The lost environment then reads 404, `resolve-domain` still gives the same URLs with `is_active: false`, and re-provisioning succeeds on the same hash.

### Cleanup

An autouse fixture tears down every non-terminated record and fails the test if any remain, so a test that fails halfway still leaves nothing active. The mock node directory lives in `tmp_path` and is asserted absent after teardown. The shared default `/tmp/tailscale-eap-mock` was compared before and after the 10-run loop and was unchanged.

### Full fe-signalloom suite

`pytest tests -q` gave `2 failed, 1487 passed, 83 skipped`. Both failures **pre-exist on base `8629b5f8`**. This was confirmed by running them against a pristine `git archive HEAD` export:

- `test_audit_provenance::test_every_mutating_route_makes_an_audit_decision`: the four mutating environment routes write no audit event and are not declared exempt.
- `test_tenant_isolation::test_the_route_sweep_covers_every_authenticated_api_route`: the environment routes are in neither `DB_ROUTES` nor `NOT_DATABASE_BACKED`. This card's `GET /{id}/probe` adds one more GET to that list.

Neither was silenced with an exemption. They are real alarms about an unauthenticated, unaudited provisioning API.

## Findings for the next card

1. **Canonical-vector typo in the proposal.** The wire spec says input `kusari` → `6f82ad81`, but `kusari` hashes to `4b53ab6b`. Only `kurasi` produces `6f82ad81`. The suite pins both values.
2. **Unauthenticated, unaudited API.** The proposal specifies `Authorization: Bearer ${OPERATOR_TOKEN}`, but no auth is enforced. This is the source of the two red guards above. Because there are no cookies or tokens on this surface, the cookie/token isolation and mock token-introspection items could not be tested meaningfully and were not faked.
3. **Error details are discarded.** `api_compat`'s `StarletteHTTPException` handler turns every non-404/405 error into `{"error":{"code":"request_error","message":"Request failed"}}`, so clients cannot tell a 409 conflict from a 410 teardown by reading the body, only by the status code.
4. **Provision is not idempotent.** Shared pattern 3 says re-provisioning an active environment should return the existing record. The engine returns 409 instead, and `test_environment_routing.py` asserts that 409. Left unchanged.
5. **State is in memory only.** A pod restart loses every environment record (see the chaos test). The TTL ceiling is 72h / 1440m initial in code, against 480m / 8h in threat T4.
6. **No real cluster resources** (namespace, HTTPRoute, Dex lease) are created or deleted by this engine. "Resources deleted post-teardown" is therefore asserted for the registry and the mock mesh node only.
7. **Live-mode hazard** in `tailscale-eap-env.sh`, described above.
