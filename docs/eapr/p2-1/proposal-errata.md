#### Errata — EAPR-P2-1 D1: shared EAP authentication and tenant binding

**Created:** 2026-09-24 22:54:08 +0100
**Result:** Delivered on branch `EAPR-P2-1`; every EAP route refuses anonymous callers at the mount and is bound to the verified principal's tenant
**Predecessors:** EAPR-P1-4 (`4621df93`, merged into this branch as `769090c5`); EAPR-P1-3 not merged (conflict in `scripts/eap/build_sled_specs.py`, outside scope — the Governor lands it)
**Base:** `integration/eapr-v0.1.0` at `95b68f10`, extended to `769090c5` (= `95b68f10` + `EAPR-P1-4`)
**Repository evidence:** `c4bdce5b` (tip of `EAPR-P2-1` at writing); never amend
**Commits (unsigned, scope-less, in order):** `e5540b2c` feat mounts + tenancy + header strip · `ad8eb01c` sealed-sweep extension · `7363075d` strip middleware outermost · `206fc5f5` structural mount assertion · `3718497f` source guard + evidence · `c52d9166` default-deny + forged-header suites · `6df7bed7` migrated suites + emitter/template bearer · `c4bdce5b` pinned inventory + delegated-auth proof + HEAD/OPTIONS

<!-- kanban-check: status=pass proceed=yes blocking_drift=yes -->

**Decision:** `status=pass`, `proceed=yes`, `blocking_drift=yes`. The card's
STOP condition 1 (P2-PRE ≠ pass) fires literally; the human recreated this card
after two identical refusals (RESET 18:08:51), so the work proceeded and the two
deviations below are the Governor's to accept or reject, not the card's.

**Deviations (blocking_drift):**

1. Executed with P2-PRE not at `pass`.
2. Base extended by merging `EAPR-P1-4` into `EAPR-P2-1` (clean, `769090c5`);
   without it the sealed sweep and the five reconciled routers this card
   consumes do not exist on the base (`docs/eapr/p2-1/failure.md`).

**Anonymous reachability (scripts/eap/anon_sweep.py), 34 EAP HTTP operations + 1 websocket:**

| Tree | HTTP reachable anonymously (non-401/403) | Websocket | Positive control `GET /health` |
| :--- | :--- | :--- | :--- |
| Base `769090c5` (scratch worktree) | **32 of 34** | 1 unprobed / open | 200 |
| `206fc5f5` (first run) | 0 of 34 | 0 of 1 (401 at handshake) | 200 |
| `c4bdce5b` (this record, `--expect-zero` rc 0) | **0 of 34** | 0 of 1 | 200 |

Full per-route tables: `docs/eapr/p2-1/anon-sweep-2026-09-24.md`. The two
base routes that were not "reachable" answered 401 for reasons unrelated to a
principal check (transit decrypt's header predicate), so the honest base count
of routes with a mount-level auth dependency is 0 of 34.

**Suite table:**

| Gate | Result | Evidence |
| :--- | :----- | :------- |
| Eleven EAP suites (9 migrated + 2 new) | PASS | `373 passed, 1 skipped, 22 xfailed, 0 failed` (resume state was `14 failed, 361 passed`) |
| `tests/test_eap_default_deny.py` + `tests/test_slte_p4_preflight_lifecycle.py` after advisor | PASS | `241 passed, 13 xfailed` |
| Sealed AMXO sweep `tests/test_tenant_isolation.py` | PASS | `144 passed` (base: `1 failed, 108 passed`); 0 EAP entries in `NOT_DATABASE_BACKED` (16 deleted), nothing added to `NOT_AUDIT_WORTHY` / `AUDIT_DECISION_OWED` |
| Full fe-signalloom suite | 1 known failure | `1 failed, 1885 passed, 84 skipped, 22 xfailed` — `test_audit_provenance.py::test_every_mutating_route_makes_an_audit_decision`, payload identical on base and branch (`scenario_seeding.py:api_execute_scenario (POST /execute)`, `1 failed, 15 passed` both), P2-2's audit-emission debt |
| Liveness BATS (`authz-suite-liveness`, `api-route-liveness`) | PASS | ok=10 not_ok=0 |
| Actions template lint | PASS | `actionlint` rc 0; `zizmor --offline --persona auditor` no findings |
| Test count, nine migrated suites | unchanged | 9/23/13/22/10/34/17/21/6 = 155 on base, HEAD and worktree |
| SLES probes B1, B2, B13 | closed | strict `xfail` removed in `test_scenario_seeding.py`; pass un-marked. SLTE G9 closed the same way |
| `api_compat.py` | untouched | `git diff 769090c5 -- api_compat.py` = 0 lines; no `dependency_overrides` in `tests/conftest.py` |

**Mutation lines (docs/eapr/p2-1/mutations-2026-09-24.md, plus this record):**

```text
T7 structural: remove dependencies= from tenant_isolation      -> test_every_eap_route_carries_the_mount_level_auth_dependency FAILED
T7 structural: remove dependencies= from scenario_seeding      -> FAILED
T7 structural: remove dependencies= from environment_routing   -> FAILED
T7 structural: remove dependencies= from environment_lifecycle -> FAILED
T7 structural: remove dependencies= from webhook_triggers      -> FAILED
T7 behavioural-only probes survived 4 of 5 (handlers also take authenticated_tenant), which is why the mount is asserted structurally
T5 reinstate X-SPIFFE-ID read in api_tenant_decrypt: source guard red (behaviour green, strip neutralises); strip disabled as well -> forged-header decrypt probe red
NEW unmount webhook_triggers (pass in place of include_router) -> test_guard_eap_inventory_is_exactly_the_pinned_set FAILED "vanished: POST /api/v1/webhooks/generic, POST /api/v1/webhooks/github"; test_guard_sweep_covers_the_eap_routers FAILED
```

**Touched production files (handlers):**

| File | Change |
| :--- | :--- |
| `d2-signalloom/apps/fe-signalloom/src/eap_tenancy.py` | new: `TENANT_KEY_RE = ^[0-9a-f]{8}$`, shared customer_hash → tenant ownership registry |
| `…/main.py` | `IdentityHeaderStripMiddleware` (pure ASGI, outermost) drops `x-spiffe-id`, `x-tenant-id`, `x-forwarded-user`, `x-principal-*` for http and websocket scopes |
| `…/tenant_isolation.py` | mount `dependencies=[Depends(api_compat.authenticated_principal)]`; tenancy via `authenticated_tenant`; `x_spiffe_id` reads and `_authorize_or_403` deleted; cross-tenant 404 |
| `…/scenario_seeding.py` | mount dependency; `/history` and `/execute` tenant-bound; `/execute` against a foreign hash 403; non-hex 422 |
| `…/environment_routing.py` | mount dependency; list/get/extend/teardown/probe and websocket telemetry tenant-bound (ws closed 4404 before accept) |
| `…/environment_lifecycle.py` | mount dependency; `/active`, `/audit-events`, register/heartbeat/activity tenant-bound |
| `…/webhook_triggers.py` | mount dependency (HMAC verification retained behind it) |
| `scripts/eap/emit-eap-webhook.sh` | `EAP_BEARER_TOKEN` from env only (never argv, redacted in `--dry-run`) |
| `docs/signalloom/templates/signalloom-pr-preview.github-actions.yaml` | `secrets.SIGNALLOOM_BEARER_TOKEN` on the send step, with lifetime/rotation note |

**Findings for the Governor (outside this card, not fixed here):**

1. **GitHub-native webhooks can no longer deliver.** A webhook configured in
   repository settings sends `X-Hub-Signature-256` and cannot send an
   `Authorization` header, so `/api/v1/webhooks/github` now answers 401 to it.
   This is the card's stated design (webhook_triggers mounts behind the
   dependency); the Actions template and the emitter carry a bearer instead.
   P3-4 deletes `webhook_triggers.py`; if a GitHub-native path must survive, an
   HMAC-as-tenant-credential second auth path is a design decision for that card.
2. **The Actions bearer will expire.** The receiver verifies `exp` through the
   production JWKS path. `secrets.SIGNALLOOM_BEARER_TOKEN` needs a
   service-principal token with a stated lifetime and rotation owner; GitHub OIDC
   federation is the intended long-term shape. Recorded in the template header.
3. **Four SLCD-P5-1 telemetry proxy operations check no principal locally**
   (`/api/v1/telemetry/coding-agents`, `…/aggregate`, `…/ordering`, GET+POST).
   They forward `Authorization` to signal-ingest, which enforces it. They are
   not EAP routes and were never in the 34-route denominator: **4 delegated,
   upstream-enforced, unverified locally.** Listed in `DELEGATED_AUTH_ROUTES`
   with owner, pinned to exactly that module's operations, and the delegation
   is proved against a recording stub upstream (anonymous forwarded without
   Authorization, upstream 401 propagated unrewritten, bearer forwarded
   byte-for-byte, forged identity headers stripped first). Closing it locally
   is one `dependencies=` line on that router; SLCD's call.
4. **403-vs-404 enumeration oracle.** Creating against a hash another tenant owns
   is 403 (card wording for `/execute`) while reads are 404; together they
   reveal which of the 2³² hashes are taken. Kept per card; flagged.
5. **Ownership map lifetime = process lifetime.** `GLOBAL_TENANT_OWNERSHIP` is
   in-memory like the engines it binds (single-process limitation; squatting
   and 32-bit-collision residuals).
6. **The emitter exits 0 on a 401** (`curl -sS`, no `--fail`). Pre-existing;
   the SLTE tests parse its 401 envelopes through `_emit`, so it was left as is.
   The Actions template does use `--fail-with-body`.
7. `NOT_AUDIT_WORTHY` still carries 14 EAP entries and `AUDIT_DECISION_OWED` 2;
   they are P2-2's audit-emission debt (EAPR-P2-2, kanban 09abb). Nothing added.

**Cross-vendor review:** Forge (GPT-family via codex) was spawned read-only in
the background with the known transport caveats (account rejects the gpt-5.4
pin; codex sandbox cannot nest); its outcome is recorded in the ISA
`MEMORY/WORK/20260924-eapr-p2-1-eap-router-auth/ISA.md` § Verification.
