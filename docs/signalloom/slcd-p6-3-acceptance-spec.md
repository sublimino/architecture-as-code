# SLCD-P6-3 — coding-agent topology acceptance spec

`test/acceptance/coding-agent-topology.spec.ts`, and the cluster-free harness it
drives. Written to be handed directly to **SLCD-P6-4**, whose `SPEC-REGISTRY.tsv`
row and `Makefile` target must describe what this card actually built rather than
what the proposal originally imagined.

---

## 1. What it covers

Eight tests, all against the **real** `CodingAgentsTab` (P5-2) and the **real**
`api/client.ts`, in a real browser.

| # | Test | States proved |
|---|------|---------------|
| 1 | the tab reaches the harness over real HTTP, not `api/fakeData.ts` fixtures | request actually crossed the wire; no demo-mode interception; no unmatched paths |
| 2 | a detected agent renders a card whose session metadata matches the seeded record exactly | detection rendering; task id, shortcode, role, elapsed, step count, `comm`/PID, host, inference endpoint, egress, tool histogram + total, zero-payload chip, toolbar count |
| 3 | a known harness and an unclassified one render as distinct, semantically labelled cards | classification: `data-harness="claude"` vs `data-harness="unknown"`; the two really differ |
| 4 | the anonymity cohort is reported when the server computes it and withheld when it refuses | `5 entities` / `avg skew 17.5ms` vs `Withheld` / `below k=5 anonymity floor`; P5-GOV's client-side-count regression asserted as an absence |
| 5 | a tenant with no telemetry renders the empty state, not an empty grid | empty kicker + unfiltered body, grid element **absent**, `Showing 0 of 0`, no alert |
| 6 | a failing telemetry call renders the error state, and Retry does not fabricate success | `role="alert"`, `data-status="error"`, verbatim reason carrying the status code, grid absent, Retry-while-broken stays broken, recovery after heal |
| 7 | neither tenant's browser ever renders the other tenant's coding-agent card | cross-tenant isolation **in the rendered DOM**, two browser contexts, presence asserted before absence, full-document string checks |
| 8 | harness state does not survive a reset, so repeated runs cannot accumulate cards | fixture cleanup, proved from both the control plane and the browser; seeding is replace-not-append |

### Deviation from the card's wording: "confidence-scored status badge"

The card asks for a badge with a treatment for *a verified detection, a
low-confidence detection, and an unknown classification*. **P5-2 ships no
confidence badge.** `types/codingAgent.ts` has no confidence field on
`CodingAgentTelemetry` or `StoredRecord`; `OrderingVerdict` /
`OrderingConfidence` exist but are rendered nowhere in the dashboard tree, and
`CodingAgentCard.tsx` renders no such element.

Rather than invent a component to test — which would be P5-2's work, out of
scope here — the three states were mapped onto the semantics P5-2 **does**
publish:

| Card's wording | What this spec asserts | Where |
|---|---|---|
| verified detection | `data-harness` equals a member of the closed harness enum (`claude`) | test 3 |
| unknown classification | `data-harness="unknown"`, the literal label `unknown`, `none` endpoint, `0 B egress` | test 3 |
| low-confidence | the server **refused** to compute the cohort (HTTP 422, under k=5) and the card reads `Withheld` rather than substituting a count | test 4 |

If a real confidence score lands later, tests 3 and 4 are where it attaches.

---

## 2. Precondition

**No Kind cluster. No Gateway. No Dex. No GCP. No port-forwards. No
`make demo-signalloom-*`.** The spec spawns its own harness on `--port 0`.

What it *does* need, exhaustively:

1. **`bun` on `PATH`.** The harness is a Bun process (`Bun.serve`, `Bun.build`);
   the Playwright runner is Node.
2. **`test/acceptance/node_modules`** with `react` and `react-dom` — already in
   `test/acceptance/package.json` (`^18.3.1`, added for the streaming harness).
   `bun install --frozen-lockfile`.
3. **A Chromium Playwright can launch.** On a machine where
   `/opt/google/chrome/chrome` is not executable from the shell — which is the
   case in this repository's sandboxed shells — the launch fails with
   `browserType.launch: Failed to launch: Error: spawn /opt/google/chrome/chrome
   EACCES` before a single assertion. **`PW_CHANNEL=chromium`** selects
   Playwright's bundled build and is the documented escape. A CI image needs
   `bunx playwright install chromium`.

There is **no `test.skip` anywhere in this spec**, deliberately. A spec that
skips on an unmet readiness guard reads as a pass and proves nothing. If the
harness cannot start, every test fails and the failure names the harness.

### Run it

```bash
cd test/acceptance
bun install --frozen-lockfile
PW_CHANNEL=chromium bunx playwright test \
  --config=playwright.config.ts --project=coding-agent-topology
```

To poke at the page by hand:

```bash
cd test/acceptance
bun harness/coding-agents-server.ts --port 8792 --seed
# then open http://127.0.0.1:8792/?tenant=tenant-acme
#        and http://127.0.0.1:8792/?tenant=tenant-globex
```

---

## 3. Why a harness rather than the demo cluster

Six states are in scope. Five cannot be produced against the shared estate
without mutating it — empty, error, the 422 refusal, an `unknown`
classification, and a second tenant — and every project that touches that estate
already sets `retries: 0` because a retry would resume against its own
leftovers.

The sixth would not work either. `make demo-signalloom-up` deploys the
**published** dashboard image. `SPEC-REGISTRY.tsv`'s row for
`agentmaxxing-demo-console.spec.ts` records that trap measured on 2026-09-15: the
served bundle carried **0 matches** for a page `App.tsx:436` registers in source,
because the image predates it. `CodingAgentsTab` is newer than that page.

So the split is: **real component tree, scripted far end of the wire.** Only two
things are replaced, and both sit outside the component under test — the OIDC
token (`harness/coding-agents-auth-stub.tsx`) and signal-ingest
(`harness/coding-agents-server.ts`). Everything else is the shipping code,
including `api/client.ts`'s `/api` prefixing, its Bearer header, its in-flight
GET coalescing, the 2500 ms poll from `api/pollInterval.ts`, and the app's own
`styles/global.css`.

This is the same shape as `supercred-log-streaming-harness.spec.ts`, one file
over, and for the same reason.

### What it adds over what already exists

- `CodingAgentsTab.test.tsx` (vitest) does `vi.mock('../api/client')`. It asserts
  the component against a **mock of its own data layer** — no HTTP, no `/api`
  prefix, no Bearer header, no real CSS, one tenant.
- P5-1 proves tenant scoping **at the API layer**, which structurally cannot see
  a client-side state-sharing bug.

Test 7 runs two real browser **contexts** — separate storage, separate JS realms
— precisely to cover that gap.

---

## 4. The assertion that keeps the rest honest

`api/fakeData.ts:927-928` registers fake routes for **both** telemetry paths. If
demo mode were on in the harness bundle, `req()` would short-circuit to those
fixtures and issue **no HTTP request at all** — and because the fixtures are
populated and plausible, every card assertion would still pass. The suite would
be green and would prove nothing about the wire.

Demo mode is off because one string in one `define` reads `development` rather
than `demo` (`api/demoMode.ts` only defaults the toggle on when `SL_ENV` is
exactly `demo`). That is silently reversible, so test 1 asserts against
`GET /harness/requests` that the harness process really received the list call,
the aggregate call, and a call carrying this tenant's token — and that no
requested path went **unmatched**.

---

## 5. Falsification

Green is the suspicious state for a new suite, so each assertion group was
falsified by mutating the thing it claims to watch and requiring the test to go
red. Every mutation was applied with a "must match exactly once" assertion,
reverted immediately, and the tree re-checked afterwards.

| Mutation | Target | Test | Result |
|---|---|---|---|
| M1 `VITE_SL_ENV: 'development'` → `'demo'` | harness bundle | 1 | **killed** |
| M2 `{kanban.task_id}` → `{kanban.shortcode}` | `CodingAgentCard.tsx` | 2 | **killed** |
| M3 list returns every tenant's records | harness | 7 | **killed** — `toHaveCount` expected 2, received 3 |
| M4 `'Withheld'` → `` `${stats.totalSessions} sessions` `` | `CodingAgentsTab.tsx` | 4 | **killed** |
| M5 `filteredRecords.length === 0 ? (` → `false ? (` | `CodingAgentsTab.tsx` | 5 | **killed** |
| M6 `setError(…message…)` → `setError(null)` | `CodingAgentsTab.tsx` | 6 | **killed** |
| M7 `data-harness={harness}` → `data-harness="claude"` | `CodingAgentCard.tsx` | 3 | **killed** |
| M8 `tenants.clear()` → `void 0` | harness reset | 8 | **killed** |

**M3's first result was a false kill and is recorded because the mechanism
generalises.** Its `-g` filter was `"never renders the other"`; the test is
titled `"neither tenant's browser ever renders the other tenant's…"`, so the
pattern selected **zero** tests. Playwright exits non-zero on "No tests found",
which a harness reading only the exit status scores as a kill. Every filter was
then run through a positive control (`--list | grep -c`, each must select exactly
one test) before the sweep was trusted; M3 was re-run with `"other tenant"` and
killed for real.

**Five of the eight mutations landed in shipping dashboard source** — M2 and M7
in `CodingAgentCard.tsx`, M4, M5 and M6 in `CodingAgentsTab.tsx` — and all five
killed. That is what earns the "real component tree" claim empirically rather
than by assertion, and it also disposes of the stale-bundle question: a cached
build could not have propagated a source edit into the DOM, so the harness
demonstrably rebuilds from source at boot. `git diff -- d2-signalloom` is empty
at the committed SHA; every mutation was reverted and the tree re-checked.

**Each kill was confirmed by an observed assertion failure, not by exit status.**
All eight logs carry an `N failed` line plus the failing `expect(...)` output,
and none contains `No tests found`. Playwright exits non-zero for at least five
distinct reasons — no tests found, config error, bundle build failure, harness
spawn failure, worker crash — so a sweep that scores only the exit code cannot
tell a kill from a broken harness.

**Exactly one project claims the spec.** `--list` across all projects returns 8
occurrences, every one under `[coding-agent-topology]` — including with
`DOCS_BASE_URL` and `AMXD_DEMO_CONSOLE` set, which enables the two opt-in
projects. A second claiming project would run these tests again under one
carrying `storageState` and `dependencies: ["setup"]`, i.e. cluster-gated, which
would falsify §7's non-gated claim in the lane P6-4 is about to wire.

**The baseline is `8 passed`, not exit 0.** There is no `test.skip` anywhere in
the file (0 occurrences), so an environment that cannot meet the precondition
cannot go green and empty.

No mutation targets a colour, a pixel or a snapshot, because no assertion reads
one. Every assertion reads a `data-testid`, a `data-*` attribute, an ARIA role,
or rendered text, so a style change cannot redden this spec and a missing task id
must.

---

## 6. Measured runtime

`PW_CHANNEL=chromium`, 24-core host, one worker (estate-wide `workers: 1`).

| Condition | Wall clock | Result |
|---|---|---|
| load average ≈ 5–6 (machine's resting state), run 1 | **3.51 s** | 8 passed |
| same, run 2 | **3.58 s** | 8 passed |
| same, run 3 | **3.59 s** | 8 passed |
| via `--project=coding-agent-topology` (no file filter) | **3.74 s** | 8 passed |
| **24 additional saturating busy loops, load average 7.45 and climbing** | **9.75 s** | 8 passed |

The contended figure is the one to budget against: **9.75 s, a 2.8× inflation**
over the resting measurement, still 8/8 green. Measuring only on an idle machine
would have understated the CI impact by nearly threefold.

Not included, because they are one-time image costs rather than per-run costs:
`bun install --frozen-lockfile` and `bunx playwright install chromium`.

**Against the budget:** the project's own timeout is 3 min (180 s), so the
contended run uses 5.4 % of it. Its cluster-driving siblings carry 15-minute and
30-minute project timeouts and stage 8 is held to ~25 minutes of cluster work.
At ~10 s this spec is cheaper than the `supercred-log-streaming-harness`
precedent (~25 s) and belongs in the same cheap-guard position, beside CI stages
1b/1c and **ahead of** the expensive cluster stages — it can fail a P5-2
regression before a lane spends 25 minutes standing an estate up.

---

## 7. Placement decision

Per the P6-PRE inventory of `playwright.config.ts`:

- **A dedicated project, `coding-agent-topology`**, `testMatch:
  /coding-agent-topology\.spec\.ts/`. It does **not** fit the existing
  catch-all: `smoke` is for specs that drive the dashboard through the Gateway
  and log themselves in via `helpers.ts login()`. This one boots a Bun server
  and points a browser at `127.0.0.1`, so it shares none of that project's
  preconditions and would inherit only ones it cannot meet.
- **`timeout: 3 * 60_000`.** A cold worker pays `Bun.build` over the real
  component tree once inside the worker-scoped harness fixture, and Playwright
  charges fixture setup to the first test that uses it. The global 30 s would be
  tight on a cold, contended machine.
- **`retries: 0`** — not for the shared-cluster reason its neighbours give, since
  this project touches no cluster, but so a flake is reported as a flake. State
  is reset and the reset is asserted in `beforeEach`, so a retry could only mask
  a real ordering defect.
- **No `storageState`, no `dependencies: ["setup"]`.** The setup project drives
  Dex through the Gateway; depending on it would hand this project the cluster
  requirement it exists to avoid, and `test-results/.auth-state.json` does not
  exist on a machine that has never run against a cluster — which Playwright
  reports as a project-level **failure**, not a skip.
- **No `launchOptions`.** Playwright merges `use` shallowly per key, so
  re-declaring it would **replace** the top-level `--host-resolver-rules` and its
  `--no-sandbox` / `--disable-gpu` siblings. This project never resolves
  `dashboard.osramp.acme.local`, but it does need the sandbox and GPU flags in a
  container.
- **NOT env-gated**, and that is the deliberate difference from `docs`
  (`DOCS_BASE_URL`) and `agentmaxxing-demo-console` (`AMXD_DEMO_CONSOLE`). Those
  are gated because their preconditions are *not* met in the lane
  `scripts/acceptance-test.sh` runs, so an unconditional project would redden
  `make acceptance-test` for reasons unrelated to any assertion in them. This
  project's precondition — `bun` plus the `node_modules` this directory already
  installs — is met wherever Playwright is being run at all. Gating it would only
  hide it, which is the defect `SPEC-REGISTRY.tsv` exists to prevent.

**Proved in both directions.** Per-project `--list` counts on `HEAD`'s config
versus this one: `Total: 137 tests in 29 files` → `Total: 145 tests in 30
files`, and the per-project diff is exactly one line, `+8
[coding-agent-topology]`. No other project's selection changed.

---

## 8. Hand-off to SLCD-P6-4

This card added **one** `SPEC-REGISTRY.tsv` row, because a spec with no row
fails CI stage 1c (`test/acceptance-spec-coverage.bats`) immediately and in both
directions — leaving the tree red is not an option, and the row is the minimum
that keeps it green. **P6-4 owns everything else**, and should treat the row as a
draft to be corrected if it wires a lane:

- **Current row:** `coding-agent-topology.spec.ts` · `suite-only` · precondition
  and P6-4 hand-off in the reason column.
- **What P6-4 must decide:** whether to move it to `ci:<stage>` by adding a
  `run_stage` in `scripts/ci/vm-pipeline.sh` beside stage 1b/1c, and/or to
  `make:<target>` by adding a Makefile recipe. The guard asserts the row against
  the Makefile recipe and the `vm-pipeline.sh` stage command, so the row must be
  updated in the same commit as either.
- **What such a lane needs:** `bun` on the image, `bunx playwright install
  chromium`, and `PW_CHANNEL=chromium` exported. Nothing else — no cluster, no
  port-forwards, no `demo-signalloom-up`.
- **Suggested target name:** `demo-signalloom-coding-agent-topology`, mirroring
  `demo-signalloom-supercred-stream-harness`.
- **This card did not touch the root `Makefile`.** P6 cards serialise on it and
  P6-4 owns it.

---

## 9. Files

| Path | Role |
|---|---|
| `test/acceptance/coding-agent-topology.spec.ts` | the spec — 8 tests |
| `test/acceptance/harness/coding-agents-server.ts` | Bun harness: bundles the real tree, serves the telemetry routes, control plane under `/harness/*` |
| `test/acceptance/harness/coding-agents-entry.tsx` | `createRoot` of the real `CodingAgentsTab` + a tenant banner |
| `test/acceptance/harness/coding-agents-auth-stub.tsx` | the one replaced boundary: a frozen, module-scope, tenant-carrying `getAccessTokenSilently` |
| `test/acceptance/harness/coding-agents-fixtures.ts` | seeded records, typed against `types/codingAgent.ts` |
| `test/acceptance/playwright.config.ts` | `coding-agent-topology` project |
| `test/acceptance/SPEC-REGISTRY.tsv` | one row (draft for P6-4) |

---

## 10. Scope limits, stated

- **A full `make acceptance-test` was not run to green.** It runs
  `scripts/acceptance-test.sh`, which stands up shared port-forwards, tears them
  down in an `EXIT` trap, and drives suites that **mutate the one shared demo
  estate** (`supercred-ui-lifecycle` alone carries a 30-minute timeout and the
  AgentMaxxing live block revokes a host). **SLCD-P6-1 was in progress
  concurrently** on the same repository at the time of writing, so running it
  would have risked exactly the cross-card interference the board warns about.
  Substituted evidence: the per-project `--list` diff above, which shows the
  change adds 8 tests under a new project and perturbs no other project's
  selection; plus a green run through the project-selection path
  (`--project=coding-agent-topology`, no file filter) that
  `scripts/acceptance-test.sh:288` reaches. **P6-GOV should run the full suite**
  once the phase is quiet.
- **The spec has not been run against a live merged P5-GOV pipeline.** It cannot
  be: the dashboard image on the demo cluster predates the component (see §3).
  Proving the live path needs a dashboard image built from this branch, which is
  a lane concern, not a spec concern.
- **The spec has not been run under the CI image's exact browser version.** It
  was run under Playwright's bundled Chromium via `PW_CHANNEL=chromium`; the CI
  image needs `bunx playwright install chromium` before it can run at all, and
  P6-4 owns that. Every assertion here is text- and attribute-based, which is the
  class least sensitive to a browser version difference, but that is a mitigation
  and not a proof.
- **"Cross-tenant isolation" here means the client half, not the server half.**
  The tenancy filter the spec drives lives in **this card's harness**, a fixture
  written alongside the assertions, so test 7 cannot and does not vouch for
  signal-ingest's own scoping — that is P5-1's, at the API layer. What test 7
  proves is the part P5-1 structurally cannot see: that the client sends the
  correct identity per context, and that two browser contexts do not bleed
  rendered state into one another. Both halves are needed; neither substitutes
  for the other.
- **`data-harness` is the record's `harness` field, rendered verbatim.** Tests 3
  and 19/20 therefore prove the card *faithfully surfaces the classification the
  server assigned* and that its `unknown` branch — the fallback icon, colour,
  `none` endpoint and `0 B egress` — is exercised. They do **not** prove any
  client-side classification logic, because there is none. M7 (pinning the
  attribute to a constant) killing is what makes the pass-through claim
  load-bearing rather than incidental.
- **The fixtures' type binding is compile-time only.** `bunx playwright test`
  transpiles rather than typechecks, so a divergence from `types/codingAgent.ts`
  bites under `tsc` and in an editor, not at run time. The run-time half of the
  guarantee is that the harness serves those objects verbatim and the spec
  asserts the DOM against the same literals.
