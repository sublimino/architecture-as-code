---
task: SLCD-P5-GOV
phase: 5
role: governor
date: 2026-09-15
verdict: CERTIFIED WITH FINDINGS — end-to-end ingestion-to-render proven against the real merged pipeline at 30x inside the <3s KPI; one privacy-control defect found in the merged UI and fixed; two inherited breaches (CPU overhead KPI, Phase 4 BLOCKED status) remain open and are NOT cleared by this card
---

# SLCD-P5-GOV — Phase 5 Governor Certification

> **Verdict.** The Phase 5 ingestion-to-render path is proven end to end against the
> real merged pipeline, not a mock: a realistic `CodingAgentTelemetry` record posted
> over real HTTP to the real `ProtectedRouter` reaches the real `CodingAgentsTab` DOM
> in **84–94 ms**, roughly **30× inside** the proposal's 3 s KPI, reproducibly across
> three runs and 20 samples per run. Tenant isolation holds under a forged-header
> attack at both the backend and the rendered UI. Schema conformance is traced for a
> single record from ingestion payload to rendered DOM.
>
> **One defect was found and fixed.** The merged UI re-disclosed a cohort size that
> `signal-ingest` had just refused to disclose on k-anonymity grounds. Neither card's
> own suite could see it, because it only exists where the two halves meet. It is
> fixed, and the falsification test is committed.
>
> **Two inherited breaches are NOT cleared by this card:** the combined-subsystem CPU
> overhead KPI remains breached ~36×, and SLCD-P4-GOV's verdict was `BLOCKED`. Phase 5
> did not cause either and cannot certify them away.

## 1. What this card actually had to do

The card is titled "merge P5-1 and P5-2". **Both were already merged before this card
ran**, by the phase controller, and this was confirmed rather than assumed:

| Commit | Role | Ancestor of `integration/slcd-v0.1.0`? |
| :--- | :--- | :--- |
| `014effd562d783607f6969b975a7a70f6abb24b9` | SLCD-P5-1 ingestion pipeline | YES |
| `bc23ab5d3acbd46574fe59833bb6a2073e1953c3` | SLCD-P5-1 integration merge | YES |
| `36652a050bf4edd1e153bf84aa8996de21ddb325` | SLCD-P5-2 dashboard rendering | YES |
| `3cb06e28734d9832c74c03a11bed7146ca492193` | SLCD-P5-2 integration merge | YES |

So no merge was performed and no conflict was resolved; there was nothing to resolve.
The risk the card names — "a conflict resolution that silently reverts P5-1's
tenant-context wiring to an earlier, less strict draft" — is therefore vacuous by
construction, and the tenant-context wiring was re-verified post-merge anyway (§5).

The real work was the half that had never been done: **joining the two halves and
testing the join.**

## 2. The gap this card found first

`CodingAgentsTab.test.tsx` — P5-2's suite, 4 tests, all passing — opens with:

```tsx
vi.mock('../api/client', () => ({ api: { codingAgents: {
  list: (token: string) => mockList(token),
  aggregate: (token: string) => mockAggregate(token),
} } }))
```

and resolves both from `fakeCodingAgentData.ts`. It proves the component renders a
fixture. **No byte of it ever reaches the Go service.** P5-1's Go suite is the mirror
image: it proves ingestion, and never renders anything.

Between them sat an untested seam, and `d2-signalloom/test/coding-agent-telemetry.bats`
— named in the phase constitution as the integration suite that would have covered it —
**does not exist**. Confirmed positively rather than by a failed search: `test -e`
returns 1, `git ls-files` shows no tracked match, and 59 other `.bats` files are
tracked in that same directory, so the directory is readable and populated.

Certifying a latency KPI against either of those suites would have measured a mock.

## 3. The harness: how the seam is actually tested

`apps/signal-ingest/api/e2e_harness_test.go` starts the **real** `ProtectedRouter` —
the same router, the same `authorize()` path, the same handlers and the same
`codingagent` store that `main.go` wires — on a **real TCP listener**.
`apps/dashboard-signalloom/src/components/CodingAgentsTab.e2e.test.tsx` then drives the
**real** `api/client.ts` over **real HTTP** into the **real** component.

Nothing on the data path is mocked. The only stub is
`useAuth0().getAccessTokenSilently`, which mints the bearer token: there is no IdP in a
test process, and token minting is not part of the path being certified.

**The harness cannot ship.** It authenticates from a static token→Principal map, which
is an authentication bypass by construction. It therefore lives in a `_test.go` file,
which the Go toolchain excludes from `go build`, from the Dockerfile and from every
production binary — structurally, not by a flag someone has to remember. A `cmd/`
binary behind a build tag would have relied on the tag being passed. `go test ./...`
skips it (`SLCD_E2E_HARNESS_ADDR` unset), so the required test command is unchanged.

### 3.1 Two ways this proof could have silently lied, both closed

**Demo mode.** `client.ts:232` short-circuits every call to local fixtures when
`isDemoMode()` is true, and `demoMode.ts:16` defaults `SL_ENV` to `'demo'`, which
defaults the toggle **ON**. A suite that missed this would have passed brilliantly
while never opening a socket — the exact "mocked shortcut" the card warns about, in a
form that looks like a live test. Closed three ways: the runner sets `VITE_SL_ENV=ci`,
the suite asserts `isDemoMode() === false` before any test runs, and every assertion is
on a probe marker (`SLCD-PROBE-E2E`, `SLCD-SCHEMA-TRACE`) that only the live server can
produce.

**Base URL not propagating.** If `VITE_API_BASE_URL` failed to reach
`import.meta.env`, axios would issue same-origin requests into jsdom and every call
would fail. The suite asserts the base URL is non-empty in `beforeAll`.

## 4. End-to-end latency against the <3 s KPI

`t0` is the moment the sensor emits the event (the POST is issued); `t1` is the moment
that event is legible on screen (the record's task ID is present in the DOM). The span
covers real TCP, real JSON encode/decode, the real authorize path, the real store, the
real GET, and a real React render.

Three independent runs, 20 samples each, plus a single cold sample:

| Run | Cold sample | p50 | p95 | max | KPI |
| :--- | ---: | ---: | ---: | ---: | :--- |
| 1 | 83.7 ms | 42.4 ms | 86.7 ms | 86.7 ms | < 3000 ms |
| 2 | 84.2 ms | 41.9 ms | 97.9 ms | 97.9 ms | < 3000 ms |
| 3 | 94.2 ms | 46.8 ms | 88.7 ms | 88.7 ms | < 3000 ms |

**Worst observed: 97.9 ms — 30.6× inside the KPI.** The multi-sample form is
deliberate: the card flags "treating a single latency sample as proof", and a KPI is a
statement about variance, not about one lucky observation. The assertion is on `max`,
not on the mean.

**Stated honestly:** this is an in-process loopback measurement against an in-memory
store. It excludes the FastAPI BFF hop, Kubernetes networking, TLS termination and
Postgres-backed persistence. It is a **floor**, not a production figure. What it
establishes is that the merged application code contributes ~90 ms against a 3000 ms
budget, leaving ~2.9 s of headroom for the infrastructure it does not cover. A
production number needs a deployed estate and is out of this card's scope.

## 5. Tenant isolation under a forged header — holds

A record was POSTed with `X-Tenant-ID: tenant-attacker`, `X-SignalLoom-Tenant:
tenant-attacker` and `X-Tenant: tenant-attacker`, authenticated as `tenant-alpha`.

- Backend: stored under `tenant-alpha`. `tenant-attacker` holds zero records.
- **UI:** `tenant-beta` wrote a record marked `SLCD-BETA-CONFIDENTIAL`. Rendering the
  merged `CodingAgentsTab` as `tenant-alpha`, and waiting for the settled state (not
  the loading state), that marker appears **nowhere in `document.body.textContent`**.

The second half is the one P5-1's backend test could not give: it is the claim that no
client-side cache or shared state in the merged UI leaks the row. Tenant attribution is
taken from the credential, never from a header, so no client-side manipulation reaches
it. Unauthenticated requests fail closed with 401.

**One adjacent observation, not a finding.** `client.ts` coalesces concurrent GETs in
`inflightGets`, keyed on URL alone and **not** on the bearer token. In a browser a tab
holds one principal, so this is not exploitable today. It becomes a cross-tenant leak
the moment two principals share one client instance. Flagged for P6, not fixed here —
it is outside this card's scope and changing it unilaterally would be the "while-I'm-
here" edit the plan forbids.

## 6. DEFECT FOUND AND FIXED — the k-anonymity guard re-disclosed what the server refused

This is the finding that justifies the card.

`signal-ingest` enforces a k-anonymity floor of k=5 (`codingagent/store.go:268`) and
returns **HTTP 422** rather than disclose an aggregate over a cohort too small to be
safe. That control is correct and was verified live.

`CodingAgentsTab.fetchTelemetry()` uses `Promise.allSettled`, so that refusal arrives
as a rejected promise which sets `aggregate` to `null` **and sets no error**. The stat
card then read, at `CodingAgentsTab.tsx:186`:

```tsx
value={aggregate?.group_size ? `${aggregate.group_size} entities` : `${stats.totalSessions} sessions`}
```

The fallback is a **client-side count of the rows already in hand**. So when the server
refused to disclose a cohort size *because it was below the re-identification floor*,
the UI computed that very figure locally and displayed it — under a banner reading
"k-Anonymity (k ≥ 5) Guaranteed".

This is worse than the crash the card told me to look for. A crash is visible. This
silently answers the question the privacy control exists to refuse, while asserting the
control is active.

**Both halves are asserted, not just the UI's.** The committed test pins the server's
refusal specifically — HTTP **422** with an error matching `k-anonymity floor` — before
it looks at the DOM. An earlier draft asserted only that the promise rejected, which a
connection failure or a timeout would also satisfy; that would have proved the caller's
half ("the UI stopped inventing a number") while leaving the half that actually carries
the privacy claim ("the server declined to disclose") untested.

**Proven live, not by inspection.** Against a tenant holding 2 sessions and a confirmed
422 from the aggregate endpoint, the rendered card read:

```
Anonymity Cohort2 sessionsclock skew bounded
```

and the committed test failed with:

```
AssertionError: Anonymity Cohort card disclosed a sub-k cohort size of 2 after the
server refused the aggregate on k=5 grounds.
```

**Fix** (`CodingAgentsTab.tsx`): when `aggregate` is absent the figure is withheld,
never substituted.

```tsx
value={aggregate ? `${aggregate.group_size} entities` : 'Withheld'}
sub={aggregate ? (...) : 'below k=5 anonymity floor'}
```

Post-fix the same card renders `Anonymity CohortWithheldbelow k=5 anonymity floor`, the
e2e suite is 6/6 green, and P5-2's own 8 tests still pass — the happy path, where
`aggregate` is non-null, is untouched.

### 6.1 Two ways this test nearly passed while blind

Recorded because the near-misses are more instructive than the fix, and because a green
adversarial suite is the suspicious state:

1. **Asserting the loading state.** The first version checked the cohort card as soon
   as the tab mounted, read the pre-fetch placeholder `"0 sessions"`, and passed. It
   was asserting against a component that had not yet received data. Fixed by waiting
   for a record to be visible before reading the card.
2. **A regex that could not match.** The second version used
   `/\b[1-4]\s+sessions\b/`. `textContent` concatenates sibling nodes with no
   separator, producing `"Anonymity Cohort2 sessionsclock skew bounded"` — there is no
   word boundary between `Cohort` and `2`, nor between `sessions` and `clock`, so the
   pattern reported no disclosure on a card that was plainly disclosing one. Fixed by
   parsing the number out instead of pattern-matching the rendered string, and by
   adding a positive control asserting the card text is non-empty first, so a selector
   that matches nothing can no longer satisfy the check vacuously.

Both failure modes produce a green test that proves nothing. The defect was only caught
because the suite was assumed to be lying until it demonstrated it could fail.

## 7. Clock-skew guard — renders, does not crash

A record timestamped 45 minutes behind the server was ingested; the store computed the
skew (`clock_skew_ms`) and the record was accepted. The merged tab rendered it and the
rest of the estate without crashing. The skew subtitle degrades to a non-numeric string
rather than formatting a bogus figure when no aggregate is available.

## 8. Schema conformance, traced end to end

Not spot-checked across fields on different records — one record traced the whole way,
which is what the card asked for. A record was POSTed with `harness: antigravity`,
`role: research`, `step_count: 33`, `session_id` per the frozen 64-hex contract, then
retrieved over real HTTP and compared field by field (`harness`, `session_id`,
`metrics.step_count`, `kanban.shortcode`, `tenant_id`), and finally asserted present in
the rendered DOM. Closed-world decoding still rejects unlisted keys (P5-1's suite).

## 9. Routing decision: documented vs actually deployed

The card warns that "a documented decision and a deployed configuration can diverge",
so the deployed configuration was read rather than the documentation trusted.

SLCD-P5-PRE and SLCD-P5-1 record **Option 1 — FastAPI BFF proxy**, with Option 2 (a
dedicated nginx `location` block) **explicitly rejected** because
`allow-signal-ingest-ingress` does not admit `dashboard-signalloom` to `signal-ingest`.

Verified in the merged tree:

| Claim | Evidence | Verdict |
| :--- | :--- | :--- |
| No nginx telemetry block (Option 2 rejected) | no `telemetry`/`coding` match in `dashboard-signalloom/nginx.conf` | MATCHES |
| BFF router exists | `fe-signalloom/src/coding_agent_telemetry.py:20` mounts the prefix | MATCHES |
| BFF router actually installed | `fe-signalloom/src/main.py:39` calls `install_coding_agent_telemetry_api(app)` | MATCHES |
| Proxies to signal-ingest | `_SIGNAL_INGEST_URL = os.getenv("SIGNAL_INGEST_URL", "http://signal-ingest:8082")` | MATCHES |
| Routes registered under auth | `api/auth.go:325-329`, five routes via `routeDefinitions` | MATCHES |

The absence of an nginx block is the **correct** state here, not a gap — worth stating
plainly, because "the telemetry route is missing from nginx.conf" reads like a defect
until you read the decision it implements. `dashboard-route-collisions.bats` passes
10/10.

## 10. Inherited breaches this card does NOT clear

**CPU overhead KPI, still breached.** The host-sensor suite reports 2 failures in
434 tests:

- `test_p3_governor_integration` — combined duty-cycle CPU **28.17%** vs **< 1.0%** KPI
- `test_p4_governor_integration` — four-subsystem duty-cycle CPU **36.44%** vs **< 1.0%** KPI

These are **not** Phase 5 regressions, and that was established by measurement rather
than assumption: the same two tests were run at the pre-Phase-5 baseline
(`1aac3c2482d17d1794c82c89522b3b447fa2f172`, the SLCD-P4-GOV tip) in an isolated
detached worktree, giving **28.64%** and **36.34%**. Merged-tree figures are within
noise of baseline, so Phase 5 adds nothing measurable to the breach. SLCD-P4-GOV
already recorded it (§7 of `slcd-p4-governor-proof.md`, "KPI BREACHED, 36×").

**The meter demonstrably moves, so "identical to baseline" is a measurement and not a
stuck constant.** Worth stating, because a baseline comparison that agrees perfectly is
equally consistent with an instrument reporting a fixed number. It discriminates on
both axes here: across subsystem count within one tree (28.17% for P2+P3 vs 36.44% for
four subsystems, the +8.4 point Phase 4 apportionment P4-GOV recorded), and across
trees for the same test (28.17 vs 28.64; 36.44 vs 36.34). Different inputs produce
different readings, so the agreement is informative.

**Attribution is not conformance, and this card does not pretend otherwise.** "Phase 5
did not cause it" answers causation; "36× over KPI" is a conformance failure whoever
caused it. The distinction matters because the two claims are easy to blur into a
dismissal. This breach is *not* among SLCD-P5-GOV's required tests (which are the
kanban doctor, `go test ./...`, the `CodingAgentsTab` vitest suite and
`dashboard-route-collisions.bats`) — it belongs to Phase 3/4 scope, and this card has
no authority to close it. It is therefore reported as **open and uncleared**, not as
resolved, and §13 hands it forward explicitly.

**A `proceed=no` gate is open upstream at Phase 2, and three phases have passed it.**
Surfaced by grepping the board's own machine-readable markers rather than reading
prose. Across the whole proposal there are 22 `status=pass proceed=yes`, 3
`status=blocked proceed=yes`, and **2 `status=fail proceed=no blocking_drift=yes`** —
and both of the latter belong to **SLCD-P2-GOV** (its errata block spans lines 681–722;
the markers sit at 682 and 721). Phases 3, 4 and 5 all proceeded regardless.

This matters for reading the rest of this document: the three `blocked` markers
(including SLCD-P4-GOV's) carry **`proceed=yes`**, so the board explicitly sanctions
continuing past them — which is why a qualified pass here is a defensible verdict
rather than an evasion. `proceed=no` is a different instrument and it is **not**
satisfied. SLCD-P5-GOV has no authority to close a Phase 2 gate and does not attempt
to; it records that the gate is open so the decision to continue is taken knowingly
rather than by default. **P6-PRE should resolve or explicitly waive it before starting.**

**Phase 4's verdict was `BLOCKED`.** SLCD-P4-GOV did not certify, citing the overhead
breach, an unresolved lawful basis, and the zero-payload invariant not being proven
through storage and query. Phase 5 nevertheless proceeded and merged. Phase 5's own
deliverables are sound on their own terms, but **Phase 6 should not read this
certification as clearing Phase 4.** The lawful-basis gate in particular remains the
declared blocker for enabling workstation collection, and nothing in Phase 5 changes
it — collection remains gated off in code.

## 11. Test evidence

| Suite | Command | Result |
| :--- | :--- | :--- |
| Ingestion (P5-1) | `go test ./...` in `apps/signal-ingest` | **PASS**, all packages, rc=0 |
| UI unit (P5-2) | `bunx vitest run CodingAgentsTab.test.tsx CodingAgentCard.test.tsx` | **PASS** 8/8 |
| Dashboard full | `bunx vitest run` | **PASS** 182 files, 3389 passed, 3 skipped |
| Routing collisions | `bats d2-signalloom/test/dashboard-route-collisions.bats` | **PASS** 10/10 |
| **End-to-end (new)** | `d2-signalloom/scripts/slcd-p5-e2e.sh` | **PASS** 6/6 |
| Host sensor | `python3 -m unittest discover -p 'test_*.py'` | **2 FAIL** / 434 — inherited CPU KPI, §10 |
| Kanban doctor | `scripts/kanban-check.sh doctor` | **UNHEALTHY** — pre-existing, §12 |

The e2e suite is excluded from the default `vitest run` lane (`vite.config.ts`
`test.exclude`) and included only by `vitest.e2e.config.ts`: it spawns a Go process and
binds a socket, so running it by accident where no Go toolchain exists would report
infrastructure as product failure.

## 12. Environment and concurrency notes

- **The integration branch moved under this card.** It was `0fbfb54c` at OBSERVE and
  `45467d811295e40ea98c4a6ff8da80f7da050a61` by VERIFY — a fast-forward to
  "docs: record Controller Tick #137 in governor log" from a concurrent controller.
  Benign (docs only, `HEAD == ref`, tree consistent), but recorded because a shared
  integration branch moving mid-card is exactly how a certification ends up describing
  a tree that no longer exists.
- **`kanban-check.sh doctor` is UNHEALTHY** with one exception: "29 task(s) finished
  suspiciously fast (< 5.0s)". These are historical runtime records spanning several
  shortcodes and test cards; none is an SLCD-P5 card. It was already failing at
  OBSERVE, before any change here. Remediation would require editing board/runtime
  state directly, which the governor role forbids.
- **`go test` mutates a tracked fixture.**
  `correlation/redteam_cascade_ceiling.json` is rewritten on every run with fresh
  timestamps and latency figures. Its verdict fields were checked first (24/24 caught,
  0 missed, `resolution_rate: 1`, `false_merges: 0` — all unchanged) and the file was
  then reverted, so it is deliberately absent from this card's commit.
- **The two proposal copies have diverged and need controller reconciliation.** The
  principal checkout at `/home/andy/src/cp/osramp-demo/docs/` is write-denied
  (`EACCES`, Landlock — `test -w` reports writable because it checks POSIX mode only),
  so errata are written to the worktree copy and left uncommitted, as SLCD-P4-GOV also
  recorded. The copies are no longer byte-identical: the **worktree** copy holds the
  SLCD-P4-GOV errata, the **principal** copy holds the SLCD-P5-1 errata, and neither
  holds both. The principal copy also still contains 1 committed conflict marker. This
  card appended only its own block and altered no prior entry, per the shared-file
  rule; reconciling the two is handed to the controller.
- **`kanban-check.sh cost` is broken by E2BIG.** The mandated invocation dies with
  `/usr/bin/python3: Argument list too long`: line 2772 passes the whole board's card
  JSON to the Python heredoc via the environment (`COST_BOARD_CARDS`), and envp is
  bound by the same 131,072-byte `MAX_ARG_STRLEN` per-entry kernel limit as argv. The
  figures were obtained from a patched private copy passing it via a file; the shared
  skill was not modified, being outside this repo and shared with every other board.
- Go 1.26.2, vitest 3.2.7, Linux.

## 13. What P6 inherits

1. The k-anonymity fallback defect is **fixed**, with a committed falsification test.
2. `inflightGets` is keyed on URL, not on token (§5) — benign today, a cross-tenant
   leak if a client instance is ever shared between principals.
3. `d2-signalloom/test/coding-agent-telemetry.bats` still does not exist; the phase
   constitution names it. The e2e suite now covers that ground from the vitest side,
   so P6-4 should either create the bats file or amend the constitution to point at
   `scripts/slcd-p5-e2e.sh`.
4. The CPU overhead KPI breach and the Phase 4 `BLOCKED` verdict remain open (§10).
5. The e2e suite is not yet wired into `SPEC-REGISTRY.tsv` or the root Makefile —
   deliberately, since P6 cards serialise on those files and this card must not edit
   them.
