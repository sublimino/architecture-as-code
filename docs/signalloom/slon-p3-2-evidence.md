# SLON-P3-2 — Adversarial boundary testing: evidence report

**Card:** SLON-P3-2 — Execute adversarial tests asserting tenant isolation during onboarding and claim tampering rejection
**Base ref:** `integration/slon-v0.1.0`
**Base commit:** `06c6c429b920d1124a7362f8ba3f39510f9f66d9`
**Base tree hash:** `9581a042ed58c3d2ebb3fe7e31aa5031e0343328`
**Run window:** 2026-09-10 12:28:48+01:00 → 2026-09-10 12:30:28+01:00
**Host:** Linux 7.1.3+deb13-amd64, Python 3.12.8 via `uv`, Bats 1.13.0

---

## 1. Summary

Two adversarial suites were authored and run against the onboarding, agent-claim
and Nono audit-ingest surfaces. **87 pytest assertions and 16 BATS probes pass.**
One boundary defect was found and fixed under the card's mitigation clause; four
further observations are recorded without code change.

The card's declared STOP condition — *"severe vulnerability allowing cross-tenant
data leakage or unauthenticated admin elevation"* — **was not met.** No path was
found by which one tenant reads or writes another tenant's data, and no
unauthenticated path reaches a mutation. The one defect found (F-1) is a
low-severity metadata disclosure in a refusal message, well below that bar, and
it is fixed.

| Deliverable | Path | Object hash |
|---|---|---|
| pytest suite | `d2-signalloom/apps/fe-signalloom/src/tests/test_adversarial_onboarding.py` | `70bdae74a5389b36e56abfbfb9e0a6a53471ce7f` |
| BATS suite | `test/signalloom/adversarial-boundaries.bats` | `28006c987e9b5bc63fbabc4ce138f30e77d4ec28` |
| BATS ASGI bootstrap | `test/signalloom/adversarial_boot.py` | `b7a5411e0fd6200100d7db52bba417ec7f6867bb` |
| mutation registry (extended) | `d2-signalloom/apps/fe-signalloom/src/tests/mutation_probe.sh` | `1a16d66c3d8376867eba417eebb86d03f305dd64` |
| mitigation patch | `d2-signalloom/apps/fe-signalloom/src/api_compat.py` | `07cfc76889eccdef50c3b32ca8433bf4efdfa01a` |

Hashes are `git hash-object` values for the files as run. The BATS file's hash
predates the final guard-15 correction recorded in §4; the committed hash is in
the errata.

---

## 2. Structured verification record

| # | Command | Exit | Result |
|---|---|---|---|
| V-1 | `pytest tests/test_adversarial_onboarding.py -q` | `0` | `87 passed, 1 warning in 1.00s` |
| V-2 | `bats test/signalloom/adversarial-boundaries.bats` | `0` | `16/16 ok`; `1..16` declared = 16 executed |
| V-3 | `pytest tests -q` (full suite, with this card's file) | `1` | `14 failed, 1233 passed, 83 skipped` |
| V-4 | `pytest tests -q` (full suite, this card's file removed) | `1` | `14 failed, 1146 passed, 83 skipped` |
| V-5 | `comm -23 <failures-with> <failures-without>` | `0` | **empty — zero regressions introduced** |
| V-6 | `git diff --stat` after all mutation runs | `0` | only intended files modified; `HEAD` unchanged at `06c6c429` |

**Arithmetic check on V-3 / V-4.** 1233 − 1146 = 87, exactly the count this card
adds. The failure *sets* are byte-identical, not merely equal in count — the 14
failures are pre-existing on the base commit and are enumerated in O-3.

**Declared-versus-executed check.** The pytest file declares 47 `def test_`
functions, which expand to 87 executed assertions under `pytest.mark.parametrize`.
The BATS file declares `1..16` and executes 16. Neither suite silently dropped a
test — a suite that fails to load reports success with a shorter tally, so the
count is checked, not just the pass/fail.

---

## 3. Adversarial probe log

### 3.1 The two probes the card declared

The card names two `curl` probes against `http://localhost:8080`. Run verbatim at
the start of this card:

```
$ curl -sS -X POST http://localhost:8080/api/onboarding/state \
    -H 'Authorization: Bearer invalid-token' -o /dev/null -w '%{http_code}'
curl: (7) Failed to connect to localhost port 8080 after 0 ms: Could not connect to server
000
exit=7

$ curl -sS -X POST http://localhost:8080/api/audit/sessions \
    -H 'Content-Type: application/json' -d '{"corrupted": true}' -o /dev/null -w '%{http_code}'
curl: (7) Failed to connect to localhost port 8080 after 0 ms: Could not connect to server
000
exit=7

$ ss -lnt | grep -w 8080
(no listener on 8080)
```

Nothing listens on 8080 in this environment. Recording `curl: (7)` as a pass
would be recording the *absence of a server* as the *presence of a boundary*, so
`adversarial-boundaries.bats` boots the real FastAPI application under uvicorn on
an ephemeral port and runs both probes against it. BATS test 1 asserts the server
answers `200` on `/health` **and** explicitly asserts the code is not `000`, so a
regression to the dead-port condition cannot pass as a refusal.

Executed against the live server:

| Card probe | Actual | Interpretation |
|---|---|---|
| `POST /api/onboarding/state` + invalid bearer | **405** `method_not_allowed` | The route is **PUT**-only. Starlette resolves routing before the auth dependency, so the method check fires first. |
| `PUT /api/onboarding/state` + invalid bearer | **401** `authentication_required` | The card's intent, on the route's real verb. |
| `POST /api/audit/sessions` + `{"corrupted": true}`, no auth | **401** `authentication_required` | Exactly as the card intended. |

The 405 is asserted exactly rather than as "4xx": a change from 405 to 401 and a
change from 405 to 200 mean very different things, and only one of them is about
the auth boundary.

### 3.2 Authentication precedes body validation

`POST /api/audit/sessions` with a malformed body and no credential returns **401**,
never 422. This matters beyond tidiness: a 422 would be an oracle, letting an
unauthenticated attacker map the request schema one field at a time by watching
which fields the validator complains about. Asserted in both suites
(`test_authentication_precedes_body_validation`, BATS 5), including negative
assertions that no schema field name (`session_id`, `root_hash`) appears in the body.

### 3.3 Coverage by surface

| Surface | Attack | Expected | Result |
|---|---|---|---|
| Onboarding | anonymous GET/POST/PUT across the protected routes | 401 | pass |
| Onboarding | 7 malformed `Authorization` headers | 401 | pass |
| Onboarding | garbage / expired / attacker-signed / `alg:none` / HS256-confusion tokens | 401 | pass |
| Onboarding | wrong `aud`, `iss`, `azp`, unknown `kid` | 401 | pass |
| Onboarding | subject with no tenant mapping | **403 `tenant_forbidden`** | pass |
| Onboarding | forged `tenant_id` JWT claim | ignored; write bound to configured tenant | pass |
| Onboarding | tenant A writes wizard state, tenant B reads | no leakage | pass |
| Onboarding | tenant A completes, tenant B status | stays `pending` | pass |
| Onboarding | SQL statement sweep across 5 routes | every statement binds caller's tenant | pass |
| Claim | tenant B claims tenant A's pod | **409 `claim_conflict`** | pass |
| Claim | renamed pod carrying the same `agent_id` | 409 | pass |
| Claim | same-tenant re-claim (positive control) | 200, idempotent | pass |
| Claim | released claim re-claimed by another tenant | 200 | pass |
| Claim | claim detail / list read by another tenant | 404 / excluded | pass |
| Audit | 5 hash-chain tampers (entry hash, linkage, payload, root, truncation) | **400 `hash_chain_verification_failed`** | pass |
| Audit | 5 signature tampers incl. transplant and genuine-ECDSA-over-wrong-data | **400 `signature_verification_failed`** | pass |
| Audit | is rejected evidence retrievable afterwards? | 404, absent from list | pass |
| Audit | body-supplied `tenant_id` | overwritten by token tenant | pass |
| Concurrency | 16 interleaved two-tenant onboarding writes | partitioning preserved | pass |
| Concurrency | two tenants racing one pod | exactly one owner | pass |

Every rejection group carries a **positive control** — a valid token that gets
200, a well-formed session that gets 201, a same-tenant re-claim that does not
409, a genuine ECDSA signature over the right data that is accepted. Without
these, a service that refused every request would satisfy the whole table.

---

## 4. Falsification — the part that decides whether any of this is real

A passing authorization test whose control has been silently deleted is the
defect shape this repository has already shipped once: on base `675772a`,
removing `AND tenant_id = $2` from six queries left the suite green at
`676 passed, 83 skipped`. Every SQL-level and boundary assertion in this card was
therefore run against a **mutation** of the control it guards. A test that stays
green under its own mutation is worthless and was repaired.

Ten mutations were added to `tests/mutation_probe.sh` (16 pre-existing → 26).
The harness asserts its substitution applied exactly once before running, so a
no-op mutation cannot report "the test survived".

| Mutation | Control removed | Verdict |
|---|---|---|
| `onboarding_terminal_tenant_filter` | tenant predicate on the terminal-transition UPDATE | **RED** — 1 failed |
| `onboarding_wizard_write_tenant_filter` | tenant predicate on the wizard-state UPDATE | **RED** — 2 failed |
| `audit_session_detail_tenant_filter` | tenant predicate on session detail SELECT | **RED** — 1 failed |
| `audit_session_memory_key` | tenant prefix on the in-memory session key | **RED** — 1 failed |
| `audit_session_list_memory_scope` | tenant prefix filter on session list | **RED** — 1 failed |
| `audit_session_body_tenant_override` | server overwrite of the body's `tenant_id` | **RED** — 1 failed *(after repair)* |
| `claim_conflict_tenant_scope` | `tenant_id != $3` on the conflict lookup | **RED** — 1 failed |
| `claim_detail_tenant_filter` | tenant predicate on claim detail SELECT | **RED** — 2 failed *(after repair)* |
| `claim_memory_cross_tenant_guard` | in-memory cross-tenant conflict guard | **RED** — 4 failed |
| `claim_conflict_discloses_owner` | the F-1 mitigation | **RED** — 1 failed |
| `subject_tenant_map` *(pre-existing)* | server-side subject→tenant lookup | **RED** — 1 failed |

**Two assertions initially survived their mutation and were repaired**, which is
the falsification pass doing its job:

- `audit_session_body_tenant_override` survived because the test asserted on the
  *response envelope*, which is built from the dependency-resolved tenant and so
  reads correctly even when the persisted record does not. The test now re-reads
  the stored session and asserts *its* `tenant_id`.
- `claim_detail_tenant_filter` survived because the cross-tenant claim test runs
  on the in-memory `_CLAIMS` store, which is keyed by tenant and therefore holds
  regardless of what the SQL says. A `RecordingPool` statement sweep over the
  four claim-read routes was added.

**A third vacuous assertion was caught by a sibling test rather than by mutation.**
`OnboardingWizardState` declares `step_index` / `selected_provider_ids` /
`provider_run_state`, and pydantic drops unknown keys in silence. The first draft
of the cross-tenant leak test wrote a camelCase payload (`currentStep`) that
round-tripped as an empty state, then asserted `.get("currentStep") != 7` — which
is trivially true when the key never exists. The concurrency test, which asserts
a value rather than an inequality, failed and exposed it. The leak test now
asserts the write round-trips **before** asserting the other tenant cannot see it,
and BATS 14 fails if a camelCase payload ever reappears in the file.

**A fourth was caught in the BATS guards themselves.** Guard 15 originally counted
`grep -c 'already claimed by another tenant'` and expected 2. It got 3: a
pre-existing *comment* at `api_compat.py:3734` reads "Check cross-tenant conflict:
if already claimed by another tenant". A prose-matching guard counts a comment as
a code site — and would stay green if a raise site were deleted and only the
comment remained. The guard is now anchored on the f-string form.

### 4.1 A test that is real but not falsifiable here

`test_alg_none_token_is_refused` and `test_hs256_algorithm_confusion_is_refused`
do **not** go red under any mutation of this repository — including a double
mutation that disables the header algorithm check (`if False`) *and* widens the
decode list to `["RS256", "HS256", "none"]` simultaneously. That is a finding
rather than a gap, and it was measured rather than assumed:

```
alg:none:        rejected by JWTValidationError: invalid Dex JWT
                   underlying: JWTValidationError: malformed JWT
HS256-confusion: rejected by JWTValidationError: invalid Dex JWT
                   underlying: TypeError: Expected a string value
```

Both attacks fail inside PyJWT, upstream of the application's algorithm policy:
an empty signature segment fails structurally, and `_jwk_client` hands
`jwt.decode` an `RSAPublicKey` **object**, which PyJWT's HMAC path refuses as a
secret. The assertions are genuine; the control enforcing them lives in the
dependency. See O-2 for why that is worth writing down.

Note also that both tokens are hand-assembled from base64 segments rather than
minted with `jwt.encode`. PyJWT refuses to *mint* an HS256 token from an
asymmetric key, and an attacker is not using PyJWT — a test that relied on that
refusal would be testing the test.

---

## 5. Finding

### F-1 — Cross-tenant identifier disclosure in the claim-conflict refusal *(fixed)*

**Severity:** low. **Status:** fixed in this card, under the card's clause
*"Mitigation patches if any boundary leakage is identified during testing."*

`_execute_claim` refused a cross-tenant claim with:

```python
f"Agent '{body.pod_name}' is already claimed by tenant '{conflict_row['tenant_id']}'"
```

An authenticated caller attempting to claim a workload they do not own learned
**the identifier of the tenant that does own it**. The caller has no relationship
with that tenant. Worse than the single disclosure, it turns a pod-name guessing
loop into a tenant enumerator: guess workload names, harvest owning-tenant
identifiers one 409 at a time.

Present on **both** branches — the database path (`api_compat.py:3747`) and the
in-memory path (`api_compat.py:3884`) — so fixing one would have moved the
disclosure to whichever branch happened to be live.

**Fix.** Both sites now read `already claimed by another tenant`. The pod name is
retained so the refusal stays actionable; the conflict row is unchanged and
remains available server-side for support. No response model, status code, or
error code changed — `409 claim_conflict` is unaltered, and `grep` across the
test suites, the dashboard client and the fixtures confirms nothing asserted on
the old wording.

**Proof it is not a vacuous fix.** `test_claim_conflict_does_not_name_the_owning_tenant`
asserts the tenant identifier is absent, *and* asserts the pod name and the phrase
"another tenant" are present — so a message stripped to nothing would fail too.
Mutation `claim_conflict_discloses_owner` restores the original message and turns
the test red.

**Why the existing suite did not catch it.** `test_adversarial_leakage.py` sweeps
error responses for stack traces, SQL and connection strings. A tenant identifier
is none of those; it is legitimate application data being shown to the wrong reader.

---

## 6. Observations recorded without code change

**O-1 — The audit hash chain does not commit to the session identifier.**
`compute_expected_entry_hash` takes `prev_hash` and the event body only; the
`session_id` is not an input. Two sessions with identical event content therefore
terminate in the identical `root_hash`, and — because the SPIFFE signature is
computed over `root_hash:spiffe_id` — carry an identical valid signature. So a
signature is replayable between sessions whose contents are byte-identical.
Impact is limited (identical content means the evidence is the same evidence
under a different name) and it is not exploitable for forging *different*
evidence, which `test_signature_transplanted_from_another_session_is_rejected`
confirms. Recorded because it is a design property worth deciding on deliberately
rather than discovering later; binding `session_id` into the genesis hash would
close it. This surfaced as a test failure — the first version of the transplant
test compared a signature to itself and passed for the wrong reason.

**O-2 — RS256→HS256 confusion is currently blocked by the JWKS plumbing, not by
the application's algorithm list.** As measured in §4.1, the effective control is
that `_jwk_client` passes `jwt.decode` a key *object*. A future refactor that
passes PEM *text* instead would silently remove that control and leave
`algorithms=["RS256"]` as the sole defence — and the test would keep passing
throughout, because the attack would still fail. The dependency is named
explicitly in the test docstring so the next reader knows which layer is
load-bearing.

**O-3 — Four pre-existing failures in `test_tenant_isolation.py` are false
positives, not a leak.** `test_every_database_statement_is_bound_to_the_callers_tenant`
fails on `POST /api/agents/claim` and `POST /api/agents/autoclaim-discovered`
(both `/api` and `/api/v1`). The flagged statement is:

```sql
SELECT claim_id, tenant_id FROM public.agent_claims
 WHERE (agent_id = $1 OR pod_name = $2) AND tenant_id != $3
   AND status = 'granted' AND released_at IS NULL
```

This is the cross-tenant **conflict lookup**. Being unscoped to the caller is its
entire purpose — it exists to find claims held by *other* tenants — and it does
bind the caller's tenant, as `$3` in a `!=` predicate. That helper's
`unscoped_statements` only recognises `tenant_id = $N`, so a `!=` predicate is
invisible to it and a correct probe reads as a leak. Not fixed here: it is a
false positive in a pre-existing test this card does not own, and the four
failures are present on the base commit with or without this card's work (V-4).
Teaching the helper to accept a `!=` predicate whose bound argument is the
caller's tenant would clear all four.

The other ten pre-existing failures (`test_api_compat.py` ×2,
`test_audit_event_types.py` ×3, `test_audit_provenance.py` ×3,
`test_dashboard_audit_vocabulary.py` ×1, `test_tenant_isolation.py::test_the_route_sweep_covers_every_authenticated_api_route`)
are likewise present on the base commit and untouched by this card.

**O-4 — `demo_runner` is a fourth module binding `_get_pool` at import time.**
`onboarding`, `audit_ingest` and `demo_runner` all do
`from api_compat import _get_pool`, so patching `api_compat._get_pool` alone
leaves their routes on the in-memory fixture path while a test believes it is
driving a database. `demo_runner` was found by the suite's own harness self-check
(`test_pool_patch_reaches_every_module_that_imported_get_pool`), not by
inspection; that check derives the importer list from the source tree, so a fifth
importer will fail it rather than escape it.

---

## 7. Deviations from the card

**D-1 — "Assert HTTP 403 on tenant mismatch" is not literally reachable, and the
substitute is stronger.** No onboarding, claim, or audit route accepts a tenant
identifier from the caller. `authenticated_tenant` resolves the tenant from
`settings.api_subject_tenants[claims["sub"]]` — server-side config — so there is
no parameter to mismatch and no IDOR surface in the usual sense.

Both halves are covered:

- 403 `tenant_forbidden` **is** asserted where it genuinely exists — a subject
  with no tenant mapping (`api_compat.py:1503`), swept across five routes.
- For the IDOR cases the suite asserts the stronger property: a caller-supplied
  tenant identifier is **never honoured**, whether it arrives as a JWT claim
  (`test_forged_tenant_claim_in_the_token_is_ignored`) or a request-body field
  (`test_audit_session_body_cannot_choose_its_own_tenant`), plus a route-table
  walk proving no such parameter is accepted anywhere
  (`test_no_route_accepts_a_caller_supplied_tenant`). That last test fails the
  moment somebody adds `/api/onboarding/{tenant_id}/status`, which is exactly
  when it should.

**D-2 — Cross-tenant reads return 404, not 403.** Deliberate and correct: a 403
would confirm the identifier exists, which is an enumeration oracle. Asserted as
404 rather than "fixed" to match the card's wording.

**D-3 — The card's curl probes were executed against a server this suite boots.**
See §3.1. `test/signalloom/adversarial_boot.py` uses the documented
`set_pool_for_testing` seam rather than setting a fake `DATABASE_URL`, because a
fake DSN makes `asyncpg.create_pool` attempt a real connection and fail. The app
itself is imported unchanged.

**D-4 — `tests/mutation_probe.sh` was extended, additively.** Ten new entries; no
existing entry altered. It was not listed as a shared-file collision risk, and
the concurrent sibling (SLON-P3-1) is documentation-only.

**D-5 — No subagents were spawned.** The Algorithm auto-includes Forge at E3 for
coding work, but this session carries a standing instruction not to invoke the
Agent tool unless asked. What Forge would have contributed is adversarial review
of the suite's own assertions; the mutation matrix in §4 is a strictly stronger
version of that, falsifying each assertion by experiment rather than by a second
model's opinion — and it caught two vacuous assertions that a review pass might
have missed.

---

## 8. Reproduction

```bash
cd d2-signalloom/apps/fe-signalloom/src
export UV_CACHE_DIR=/home/andy/src/.worktrees/.uvcache   # the shared uv cache is unusable on this host

# The pytest suite
uv run --python 3.12 --with pytest --with pytest-asyncio --with pytest-xdist \
  --with-requirements requirements.txt python -m pytest tests/test_adversarial_onboarding.py -q

# Any single mutation — the test it guards must go RED
./tests/mutation_probe.sh onboarding_wizard_write_tenant_filter \
  tests/test_adversarial_onboarding.py -q

# The BATS suite (boots its own server on an ephemeral port)
cd - && bats test/signalloom/adversarial-boundaries.bats
```
