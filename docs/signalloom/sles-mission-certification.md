# SLES v0.1.0 — Final Mission Certification

**Verdict: NOT CERTIFIED for production.** SLES is accepted as an **engineering-integrated demonstration build**. It passes its own test surface. It fails invariants the proposal itself sets for production: authentication, tenant-scoped history, tenant-key validation, schema conformance, signed attestation, workload identity, and deterministic generation. It is also missing two lifecycle behaviours (auto-seed on init and expunge on reap). Each blocker below has captured evidence, and seven of them are pinned by strict-xfail tests.

| Field | Value |
|---|---|
| Card | `SLES-P4-GOV` (Governor, band L) |
| Integration branch | `refs/heads/integration/sles-v0.1.0` |
| Base at start of this run | `c5711d7fca01150c87893b80d92c33357465172c` |
| Reviewed tip | the commit that adds this revision (see errata); code reviewed at `5c74d7b9` plus the Cato follow-up commit |
| Reviewed | 2026-09-23 03:41 +01:00 |
| Reviewer | SLES-P4-GOV governor session (single governor; no other phase governor signed — see §7) |

## 1. What was on the branch versus what the board claimed

The board reported 16/17 cards `done`. When this run started, the integration branch held **one** SLES commit, `c5711d7f`, containing the engine, the router mount and 8 tests. The following was found:

| Card | Board | Committed work found | Action |
|---|---|---|---|
| P0, P1-1, P2-1, P2-2, P3-1 | done | Inside `c5711d7f` (engine, 4 archetypes, API) | Kept, re-verified |
| P1-2 auto-seed on init | done | **None**: nothing in `environment_lifecycle.py` references the scenario engine | Blocker B7 |
| P3-2 SSE streaming | done | **None** | Implemented here (`5c74d7b9`) |
| P4-PRE | done | `55b9b0f4`, not merged | Merged, `2217d058` |
| P4-1 kurasi journey suite | done | **None** | Implemented here (`5c74d7b9`) |
| P4-2 concurrency stress | done | `ec4d6559`, not merged | Merged, `b884bd92` |
| Prior P4-GOV attempt | — | `a0996f39` (council-rejected) | Not merged |

## 2. Prior-work verification

| Artifact | Probe | Result |
|---|---|---|
| `src/scenario_seeding.py` (12729 B at base) | full read; `rg install_scenario_seeding_api` | PASS: model, 4 archetypes, `RLock` manager, router at `:325` |
| `src/main.py` wiring | `rg -n scenario_seeding main.py` | PASS: import `:20`, mount `:50` |
| `src/tests/test_scenario_seeding.py` at base | `pytest -v --cov=scenario_seeding` | PASS: 8 passed, 99 % line coverage, 1 third-party warning |
| Canonical pilot hash | `derive_customer_hash()` | `kurasi` → `6f82ad81`; `kusari` → `4b53ab6b` (see B10) |
| `MultiPlaneAuditEvent` | `rg -n MultiPlaneAuditEvent` repo-wide | **Absent from code**; only prose in `scripts/eap/build_sles_specs.py` |
| SSE / concurrency / kurasi suites | `rg` for stream, ThreadPoolExecutor, journey | Absent at base, which confirms the council's gap list |

## 3. Test execution

All commands run from `d2-signalloom/apps/fe-signalloom/src` with
`UV_CACHE_DIR=/home/andy/src/.worktrees/.uvcache uv run --python 3.12 --with pytest --with pytest-asyncio --with-requirements requirements.txt python -m pytest -p no:cacheprovider`.

| Suite | Tip | Result |
|---|---|---|
| `tests/test_scenario_seeding.py` | after Cato fixes | **27 passed, 7 xfailed** (strict, `raises=AssertionError`), 1 warning, exit 0 |
| same, `--cov=scenario_seeding` | after Cato fixes | 151 statements, 1 missed, **99 %** (the unreachable `else` branch in `execute_scenario`) |
| blockers `--runxfail` | after Cato fixes | all 7 fail on their stated assertion. `raises=AssertionError` now enforces this on every run |
| full `tests/` | `5c74d7b9` working tree | **1 failed, 1415 passed, 83 skipped, 6 xfailed, 3 warnings** (217 s) |
| `tests/test_audit_provenance.py` | `c5711d7f` (temporary detached worktree) | 1 failed, 15 passed: the failure **predates this board's last change** |

The one full-suite failure is `test_audit_provenance::test_every_mutating_route_makes_an_audit_decision`. It lists `scenario_seeding.py:api_execute_scenario (POST /execute)` among several unaudited mutating routes. **"100 % pass with zero warnings" is therefore not true of the monorepo suite, and this document does not claim it.** The recurring warning is third-party: `starlette/testclient.py:40` uses the deprecated `anyio.abc.BlockingPortal`.

**Mutation checks on the new SSE code** (source restored and `cmp`-verified after each):

| Mutant | Result |
|---|---|
| M1 stream returns every tenant's events | killed (2 failed). It **survived** the first fixture version because dict insertion order put the target tenant first, so both fixtures now seed the foreign tenant first |
| M2 `asyncio.sleep` → `time.sleep` (blocks the loop) | killed (2 failed) |
| M3 `replay=False` ignored | killed (1 failed) |
| M4 server-side hash derivation bypassed | killed (journey + concurrency tests) |
| M5 traversal BLOCK downgraded to INTERCEPT | killed (journey test) |
| M6 `Last-Event-ID` ignored | killed (1 failed) |

**Performance** (from the merged P4-2 transcript, not re-benchmarked here): 20 tenants × 50 iterations had max execution 3.90 ms against a 50 ms budget. **Above card scale** (100 × 200) it breaks the budget at 105–151 ms because of gen-2 GC pauses with unbounded retention. Live SSE delivery in `test_sse_live_delivery_is_sub_second_and_tenant_isolated` is asserted under 1 s. At the 50 ms poll interval the expected latency is at most about 50 ms.

## 4. Certification blockers

| ID | Invariant (proposal source) | Evidence | Pinned by |
|---|---|---|---|
| **B1** | No unauthenticated scenario triggering (Out of scope) | `POST /execute` with no credentials returns 201. The router has no `Depends`. `api_compat.py` already provides `authenticated_tenant`, which its own `/audit/stream` SSE route uses | `test_blocker_execute_requires_authentication` |
| **B2** | No cross-customer event visibility | `GET /history` returned executions for `6f82ad81` **and** `0badf00d`. Because `/history` discloses every tenant's hash, and `/events/{hash}` and `/stream` are keyed only by that hash, **B1 + B2 together give full unauthenticated cross-tenant read, including live streaming**. Each open stream also polls 20 times a second with no cap on concurrent streams | `test_blocker_history_is_tenant_scoped` |
| **B3** | Events conform to `MultiPlaneAuditEvent` (Shared Pattern 3) | The schema does not exist in code. `SyntheticAuditEvent` lacks `event_type`, `source_agent` and `target_resource`, and `plane`/`verdict` are free strings | `test_blocker_event_schema_matches_multiplane_audit_event` |
| **B4** | Compliance proofs signed via OpenBao transit | `generate_compliance_proof_events` emits a `key_mount` and an `algorithm` label. No transit call is made and no `vault:v1:` signature exists | `test_blocker_compliance_proof_is_signed` |
| **B5** | Canonical SPIFFE ID on every seeded action | Only 2 of 9 events carry `spiffe_id`. ruff `F841` confirms `spiffe` is computed and discarded in the injection and traversal generators | `test_blocker_every_event_carries_spiffe_identity` |
| **B6** | Events expunged on reap (Shared Pattern 4) | `ScenarioManager` has no delete/expunge method (`rg` exit 1). `environment_lifecycle.py` has 0 references to it. Retention is unbounded (P4-2: about 110 MiB per 20,000 executions) | `rg` probe (no test: there is no API to call) |
| **B7** | Auto-seed on environment init (P1-2) | `rg -c scenario environment_lifecycle.py environment_routing.py tenant_isolation.py webhook_triggers.py` exits 1 | `rg` probe |
| **B8** | Deterministic seeds from the customer hash (Shared Pattern 2) | Two generations for the same hash differ (`uuid4`, `now()`) | `test_blocker_generation_is_deterministic` |
| **B9** | Mutating routes make an audit decision | `test_audit_provenance` fails at base and at tip on `POST /execute` | existing test |
| **B10** | One canonical pilot identity | Shared Patterns say `kusari`/`6f82ad81`, but `derive_customer_hash("kusari")` is `4b53ab6b`. Code, cards and tests use `kurasi` | `derive_customer_hash` probe |
| **B13** | One definition of a valid tenant key | `/stream` enforces `^[0-9a-f]{8}$`, but `ExecuteScenarioRequest.customer_hash` only checks length: `POST /execute` with `ZZ/..zz!` returns 201 and stores the key. Such events are readable via `/events` but can never be streamed | `test_blocker_execute_rejects_non_hex_customer_hash` |
| **B11** | SLES suite runs in PR validation | `signalloom-ci.yaml` triggers only on `workflow_dispatch` and a nightly cron, and `vm-pipeline.sh` builds images rather than running pytest. Only `terraform-validate.yaml` runs on `pull_request`. The suite runs only via local `make test-all-offline` | workflow read |

B1, B2, B4, B5 and B13 are security findings. B1 plus B2 means any network client that reaches the portal can generate events for any tenant, enumerate every tenant's hash from `/history`, and stream that tenant's events live.

## 5. Security review

| Check | Result |
|---|---|
| Secrets in SLES files | `trivy fs --scanners secret d2-signalloom/apps/fe-signalloom/src`: **0 findings**. The regex sweep matched only prose ("tokens") |
| Event-loop blocking | SSE uses `asyncio.sleep`; mutant M2 proves the test detects a blocking sleep. `execute_scenario` is synchronous but CPU-trivial (P4-2: p99 1.86 ms) |
| Input validation | `extra="forbid"` on request and event models. Unknown scenario type or extra field returns 422. On `/stream`, a malformed hash or `Last-Event-ID` returns 422. **The execute request does not validate the hash's shape** (B13) |
| Authentication / authorisation | **FAIL** (B1, B2) |
| Cryptographic attestation | **FAIL** (B4): there is no signature to verify |
| Workload identity | **FAIL** (B5) |
| Card tooling | `scripts/eap/build_sles_specs.py` sets `KANBAN_BYPASS_GOV_WORKTREE=1` when creating cards, and reads the proposal from a repo path (`docs/Proposal — …`) rather than the vault note |

## 6. Prompt-contract floor compliance (17 cards)

Measured with `prompt-contract.py` `validate_card_specification` against `~/.cline/kanban/card-specs/SLES/*.v1.json`, using each card's real role and band. Floors: S 250/20/4/3, M 450/35/5/4, L 700/50/6/5 (words/lines/deliverables/tests; tests are exempt for preflight and governor). Minimum distinct-line ratio is 0.65.

| Card | Role | Band | Words | Lines | Deliv. | Tests | Distinct ratio | Floor |
|---|---|---|---|---|---|---|---|---|
| P0 | implementation | S | 296 | 28 | 4 | 3 | 1.0 | PASS |
| P1-PRE | preflight | S | 283 | 24 | 4 | 2 | 1.0 | PASS |
| P1-1 | implementation | M | 475 | 44 | 8 | 4 | 1.0 | PASS |
| P1-2 | implementation | M | 473 | 44 | 8 | 4 | 1.0 | PASS |
| P1-GOV | governor | M | 453 | 42 | 7 | 2 | 1.0 | PASS |
| P2-PRE | preflight | S | 277 | 24 | 4 | 2 | 1.0 | PASS |
| P2-1 | implementation | L | 719 | 62 | 10 | 5 | 1.0 | PASS |
| P2-2 | implementation | L | 708 | 64 | 10 | 5 | 1.0 | PASS |
| P2-GOV | governor | M | 463 | 43 | 8 | 2 | 1.0 | PASS |
| P3-PRE | preflight | S | 267 | 24 | 4 | 2 | 1.0 | PASS |
| P3-1 | implementation | L | 701 | 63 | 10 | 5 | 1.0 | PASS |
| P3-2 | implementation | L | 715 | 64 | 10 | 5 | 1.0 | PASS |
| P3-GOV | governor | M | 454 | 41 | 8 | 2 | 1.0 | PASS |
| P4-PRE | preflight | S | 456 | 23 | 5 | 3 | 1.0 | PASS |
| P4-1 | implementation | L | 726 | 62 | 10 | 5 | 1.0 | PASS |
| P4-2 | implementation | L | 891 | 62 | 11 | 6 | 1.0 | PASS |
| P4-GOV | governor | L | 899 | 53 | 9 | 4 | 1.0 | PASS |

**17/17 PASS, and every distinct-line ratio is 1.0 (at least 0.65).** Floor compliance measures the *specification*, not the delivery: P1-2, P3-2 and P4-1 pass their floors and had no committed work.

## 7. Governance sign-off

The deliverable "signed by all phase governors" **cannot be produced**. The 2026-09-22 council reset removed the P1–P3 governor errata as unevidenced, because those sessions produced no output. No phase-governor signature exists to collect, and fabricating one is out of the question. This document is signed by the P4 governor alone.

## 8. Code quality and conventions

| Check | Result |
|---|---|
| ruff on `scenario_seeding.py` + test file | 30 findings at tip versus 31 at base: **no new findings from this run**. The rest are pre-existing (UP006/UP035 typing style, 3× F841, F401, one F821 false positive in a passing test) |
| Pydantic v2 validation of every emitted event | `model_validate_json` round-trip for all 9 kurasi events: PASS |
| OpenAPI | `/execute`, `/events/{hash}` and `/history` carry request/response `$ref` models; `/stream` documents the `customer_hash` pattern and its `replay`/`limit` parameters |
| Commit conventions `8629b5f8..HEAD` | 11 commits, 0 signed (the branch practice is unsigned). **2 carry scopes**: `9f5c5755 test(sles):` and `ec4d6559 docs(sles):` from P4-2. They were not rewritten, since rewriting another card's merged history is not a governor action |
| Bun-only JS tooling | **FAIL, monorepo-wide and not SLES-caused**: `package-lock.json` is tracked beside `bun.lock` in `dashboard-signalloom` and `docs-signalloom` (plus vendored `bats-assert`) |
| Temporary artifacts | Test runs write nothing to the repo. `git status --porcelain` is empty after commit |

## 9. Cross-vendor audit (Cato)

Cato (GPT-5.4, read-only) returned **concerns**. It confirmed the NOT CERTIFIED verdict and the SLES test counts, and it independently checked B1, B3, B4, B5 and B8. Its findings were addressed as follows:

| Cato finding | Resolution |
|---|---|
| Strict xfails with no `raises=` would stay xfailed if a fix broke the probe | `raises=AssertionError` on all blocker xfails; the B2 probe asserts 200 first |
| Malformed-hash test accepted 404, so it would pass with the route deleted | now asserts 422 only, on inputs that reach the route |
| Execute accepts non-hex tenant keys | recorded as B13 with a strict-xfail probe |
| SSE ids emitted but `Last-Event-ID` ignored | honoured, pattern-validated, and tested; mutant M6 killed |
| B2 understated the exposure | reworded: history discloses the hashes, so this is full cross-tenant live read |
| SPIFFE probe hardcoded a trust domain | now compares against `get_tenant_spiffe_id()` |

Cato did not independently check B6, B7, B9, B10, B11, the §6 floor table or the full-suite counts. The governor's evidence for those is in §2–§6.

## 10. Executive briefing

**For Signal Loom EAP engineering and product leadership.**

SLES does what a demo needs. A kurasi evaluator's environment can run all four scenarios (baseline agent work, a caught prompt injection, a blocked lateral move, and a compliance proof) and watch them arrive live over SSE, with tenants kept apart by index key under 1,000-execution concurrency. That is 27 green tests and 6 killed mutants. A reconnecting browser resumes from `Last-Event-ID` without duplicates.

It is not production software, and it must not be shown to a prospect as one. The attestation is a label, not a signature. Any client can trigger scenarios, and the history endpoint shows every tenant's activity. The "multi-plane audit schema" that every card cites does not exist in code. Nothing is cleaned up when an environment is reaped. And the board reported all of this work as done while three cards had no code behind them.

To reach production sign-off, fix in this order:

1. B1/B2: put the router behind `authenticated_tenant` and scope every read to the caller's tenant.
2. B3: define `MultiPlaneAuditEvent` once and make `SyntheticAuditEvent` conform to it.
3. B4/B5: sign compliance proofs through OpenBao transit off the event loop, and attach SPIFFE to every event.
4. B6/B7: wire seeding and expunge into the lifecycle state machine.
5. B8–B11 and B13: determinism, the audit-provenance decision for `POST /execute`, the `kusari`/`kurasi` naming, PR-triggered CI, and one tenant-key pattern shared by every route and model.

Each strict-xfail test turns red when its fix lands, so the markers cannot rot silently.
