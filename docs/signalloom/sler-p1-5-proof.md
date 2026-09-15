# SLER-P1-5 — Stop the cascade fabricating success

**Card:** SLER-P1-5 · **Phase:** 1 · **Integration branch:** `integration/sler-v0.1.0`
**Package:** `d2-signalloom/apps/fleet-manager`
**Depends on:** SLER-P1-2 (`PlaneResult` / `PlaneOutcome`, merged at `4a70a293`)

---

## 1. The defect, exactly as it stood

Four lines in `cascade.go`, plus one omission in `main.go`, combined to make a
wholly failed containment byte-indistinguishable from a wholly successful one.

Quoted from `4a70a293:d2-signalloom/apps/fleet-manager/cascade.go`:

```go
 86	for _, id := range targets {
 87		agent := o.dag.GetAgent(id)
 88		if agent == nil {
 89			continue                                          // (0) silent drop
 90		}
 ...
 93		currentState, err := o.client.GetPodState(ctx, agent.Namespace, id)
 94		if err != nil {
 95			slog.Warn("failed to read pod state", "agent", id, "error", err)
 96			currentState = StateRunning                       // (1) fabricated reading
 97		}
 98
 99		// Revoke credentials
100		if err := o.client.RevokeCredentials(ctx, id); err != nil {
101			slog.Warn("failed to revoke credentials", ...)     // (2) swallowed
102		}
103
104		// Update pod label to stunned
105		if err := o.client.SetPodState(ctx, agent.Namespace, id, StateStunned); err != nil {
106			slog.Warn("failed to set pod state", ...)          // (3) swallowed
107		}
108
109		result.Events = append(result.Events, StateChangeEvent{
110			AgentID:   id,
111			FromState: currentState,
112			ToState:   StateStunned,                           // (4) asserted regardless
113			...
114			Success:   true,                                   // (5) asserted regardless
115		})
```

and from `main.go:120-128`, `handleStun` had no `WriteHeader` call on any path,
so every outcome fell through to an implicit `200 OK`. `handleRecover:159-167`
carried the identical omission on the mirror-image operation.

**The composite failure.** An agent whose credential revoke was refused by
OpenBao and whose pod label write was refused by the apiserver was reported to
the operator as `from_state: running → to_state: stunned`, `success: true`,
`HTTP 200`. Nothing had been contained. The agent was still running, still
holding live credentials, and the only record that anything had gone wrong was
two `slog.Warn` lines in a log nobody was reading during an incident.

This is worse than a 500. A 500 is a question; a 200 is an answer, and this one
was wrong.

**Why SLER-P1-1 does not fix it.** The defect is in the orchestrator's
swallow-and-continue logic, not in the client. `noopFleetClient` never returns
an error, so it never reaches lines 96/101/106 at all. A *real* client that
returns these same errors hits those three lines completely unchanged. Retiring
the noop client changes which errors arrive; it does not change the fact that
they were discarded on arrival.

---

## 2. What changed

### 2.1 `cascade.go`

| Defect line | Before | After |
| :--- | :--- | :--- |
| `:88-89` | bare `continue` — target vanishes from the result | records `TargetOutcome{Outcome: OutcomeNotFound}` |
| `:96` | `currentState = StateRunning` | `currentState = StateUnknown`, with `StateRead.Error` carried on the result |
| `:100-102` | `slog.Warn` then continue | `Credential.Succeeded = false` + error recorded on the result |
| `:105-107` | `slog.Warn` then continue | `StateWrite.Succeeded = false` + error recorded on the result |
| `:112` | `ToState: StateStunned` unconditionally | `ToState = StateStunned` **iff** the label write succeeded, else the state actually read |
| `:114` | `Success: true` unconditionally | `Success = (Outcome == OutcomeContained)` |

New types: `StepResult` (`Attempted` / `Succeeded` / `Error`), `TargetOutcome`
(per-target verdict plus all three step results), `CascadeResult.Targets`,
`CascadeResult.FailedTargets()`, `CascadeResult.NotFoundTargets()`.
`StateUnknown = "unknown"` is deliberately not a member of the dashboard's state
union, so it cannot be mistaken for a live state.

### 2.2 Per-target verdict rule (`classifyOutcome`)

```
revoke OK && write OK && read OK   → contained
revoke FAIL && write FAIL          → unavailable      (zero containment achieved)
anything else                      → partial
```

The two enforcement steps decide the verdict; the state read only degrades it.
Reading a label contains nothing, so a target whose read succeeded while both
enforcement steps failed reports **unavailable**, not partial. Conversely a
target whose enforcement both succeeded but whose state could not be read is
**partial** — contained in every way that matters, except that we cannot say
what it was before, and we no longer pretend we can.

### 2.3 `schema.go` — the fourth outcome

`OutcomeNotFound = "not_found"` added to `PlaneOutcome`, admitted by `IsValid()`,
and given an **explicit arm** in `AggregateOutcome` rather than falling through
the `default:` into `unavailableCount`. That fall-through is precisely the
coercion this card forbids: *unavailable* sends an operator to check plane
connectivity, *not found* sends them to check their targeting, and during an
active containment being sent to the wrong one is expensive.

Aggregation rules added:

| Set | Result | Reasoning |
| :--- | :--- | :--- |
| all `not_found` | `not_found` | nothing to contain, so nothing failed |
| `not_found` + `unavailable` | `unavailable` | zero containment achieved — must not read as partial |
| `not_found` + `contained` | `partial` | some containment happened |

All four pre-existing `TestAggregateOutcome` cases are unchanged and still pass.

### 2.4 `main.go` — the HTTP surface, symmetrically

`cascadeStatusCode` + `writeCascadeResult`, applied to **both** `handleStun` and
`handleRecover`:

| Overall outcome | Status | Says to the operator |
| :--- | :--- | :--- |
| `contained` | `200 OK` | every target contained |
| `partial` | `207 Multi-Status` | some containment achieved, something failed |
| `not_found` | `404 Not Found` | your target IDs are stale — not a plane problem |
| `unavailable` | `500 Internal Server Error` | nothing was contained anywhere |
| *(unrecognised)* | `500` | fail closed on the unknown, never 200 |

The full body is written on every code. An operator handed a 500 still needs the
per-target breakdown to know which plane failed on which agent.

### 2.5 Single-observation binding for a concurrently mutated DAG

Each target resolves `agent.Namespace` **once**, and that snapshot is used for
both the `GetPodState` and the `SetPodState`. The lookup and the writes are not
atomic with respect to a fleet topology refresh, so a second
`o.dag.GetAgent(id)` at the write site could send the read and the write to two
different namespaces and report the result of one as the result of the other.
Mutation **M6** below proves this guard is load-bearing.

---

## 3. Evidence

### 3.1 Required commands

| Command | Result |
| :--- | :--- |
| `cd d2-signalloom/apps/fleet-manager && go test ./...` | **ok** — 0.007s, 0 failures |
| `grep -n 'assume running' .../cascade.go` | **exit 1, zero matches** — the fabrication and its comment are gone |
| `grep -n 'StateStunned' .../cascade.go` | 5 matches, all guarded or documentary (`:14` const, `:55`/`:404` comments, `:325` the write call, `:336` inside `if outcome.StateWrite.Succeeded`) |
| `bash scripts/run-redteam-suite.sh` | exit 0, 15/15 — **but see the caveat below: this command is non-discriminating and is not evidence for this card** |
| `grep -n 'func.*handleRecover' .../main.go` | `main.go:170` — present and carrying the same status mapping |

**The red-team suite proves nothing about this change, and saying otherwise
would repeat the exact defect this card removes.** `scripts/run-redteam-suite.sh:25`
opens `cat <<JSON > "$EVIDENCE_FILE"` and writes
`docs/signalloom/evidence/adversarial-redteam-proof.json` **entirely from
hardcoded literals** — `scenarios_passed: 15`, `scenarios_failed: 0`,
`process_escapes: 0`. The only interpolated value is `$TIMESTAMP`, which is why
the tree goes dirty on every run. There is no loop, no `kubectl`, no write to
`/sys/fs/cgroup`; the fifteen "scenarios" are fifteen JSON objects with
`"status": "PASS"` typed in. `test/crkc-adversarial-redteam.bats:10` then points
`EVIDENCE` at that same fabricated file and asserts against it. The suite is
structurally incapable of failing and would pass on a cluster with no
enforcement at all. (Established at SLER-P0, `843fea40`; remediation is owned by
P6-1.)

It is reported here because the card lists it as a required command and it ran
clean — **not** because exit 0 discriminates between the pre-fix and post-fix
cascade. It does not: it never invokes the fleet-manager at all. The evidence
that actually discriminates is §3.3, where each defect was reintroduced and the
tests had to fail.

The suite's timestamp rewrite of the CRKC-P4-1 artefact was reverted rather than
committed under this card; its verdict fields were unchanged.

### 3.2 Test inventory

69 tests pass in the package, 0 fail. New in this card
(`cascade_honesty_test.go`, 19 tests):

| Test | What it pins |
| :--- | :--- |
| `TestStun_UnreadableState_ReportsUnknownNotRunning` | swallow point 1 — state reported unknown, never the fabricated `running` |
| `TestStun_UnreadableStateOnly_IsPartialNotContained` | read fails, both enforcement steps succeed → **partial**, not collapsed either way |
| `TestStun_RevokeFailure_IsRecordedNotSwallowed` | swallow point 2 — recorded on the result, not a bare log line |
| `TestStun_SetStateFailure_DoesNotReportStunned` | swallow point 3 — `to_state` stays at the read value |
| `TestStun_AllThreeFailuresInjected_ReportsTotalFailure` | **the exact defect** — all three injected → `unavailable`, `success: false`, HTTP 500, all 3 errors retrievable |
| `TestStun_ReadSucceedsButBothEnforcementStepsFail_IsNeverContained` | the inverse — read OK, zero containment → `unavailable` |
| `TestStun_TargetMissingFromDAG_ReportsNotFound` | `not_found` distinct from success, from `unavailable` and from `partial` |
| `TestPlaneOutcome_NotFoundIsADistinctValidValue` | enum + aggregation, no coercion |
| `TestStun_RetryOnAlreadyStunnedTarget_ReportsNoSpuriousFailure` | idempotency under retry (mission `stopAndReport` invariant) |
| `TestStun_DAGMutatedMidCascade_BindsToASingleObservation` | read and write bound to one DAG observation |
| `TestHandleStun_RevokeFailure_DoesNotReturn200` | 207, with per-target detail in the body |
| `TestHandleStun_TotalFailure_Returns500` | 500, no wire event claiming success or `stunned` |
| `TestHandleRecover_RestoreFailure_DoesNotReturn200` | the symmetric fix on recovery |
| `TestHandleRecover_TotalFailure_Returns500` | ditto |
| `TestRecover_DoesNotAssertFromStateStunned` | recovery reads the pre-state instead of asserting it |
| `TestRecover_SetStateFailure_DoesNotReportRunning` | recovery `to_state` not fabricated *(added because mutation M7 survived — see 3.3)* |
| `TestRecover_UnreadableState_ReportsUnknownNotStunned` | recovery-side read fabrication *(added for M9)* |
| `TestCascadeStatusCode_Mapping` | all four codes plus fail-closed default |
| `TestHonestyFix_IsIndependentOfTheClientImplementation` | same orchestrator, same interface: contained on success, unavailable on failure |

**`TestStun_ClientErrors_AreTolerated` was rewritten**, not extended. Its comment
read *"client failures are logged but tolerated"* and it asserted only that the
cascade returned no error and emitted one event — both of which a wholly-failed
containment also does. **It was green throughout the entire lifetime of the
bug.** It is now `TestStun_ClientErrors_AreRecordedNotTolerated`, keeping the
contract worth keeping (one target's failure must not abort the cascade for the
others) and adding the one that was missing (that is not the same as tolerating
it).

### 3.3 Mutation falsification — 12/12 killed

A green suite is not evidence that it asserts anything. Each defect was
reintroduced into the **fixed** code, one at a time, and the corresponding tests
must fail. The harness asserts each anchor matches exactly once before writing,
refuses to score a run in which the `-run` regex matched zero tests, refuses to
score a mutation that failed to compile, and restores the originals from a
`mktemp` backup on `EXIT INT TERM`.

| # | Mutation | Verdict |
| :--- | :--- | :--- |
| M1 | stun: unreadable state fabricated as `running` | **KILLED** (2 tests) |
| M2 | stun: `RevokeCredentials` failure swallowed | **KILLED** (3) |
| M3 | stun: `to_state` hard-coded to `stunned` | **KILLED** (2) |
| M4 | `not_found` coerced into `unavailable` | **KILLED** (1) |
| M5 | every outcome answers HTTP 200 | **KILLED** (4) |
| M6 | namespace re-resolved at the write site | **KILLED** (1) |
| M7 | recover: `to_state` hard-coded to `running` | **KILLED** (1) |
| M8 | recover: `from_state` asserted as `stunned` | **KILLED** (1) |
| M9 | recover: unreadable state fabricated as `stunned` | **KILLED** (1) |
| M10 | zero-containment target reported as `partial` | **KILLED** (3) |
| M11 | unresolvable target silently dropped | **KILLED** (1) |
| M12 | dashboard event `success` hard-coded `true` | **KILLED** (4) |

**M7 and M9 survived the first sweep.** The recovery path was covered only by
status-code tests, and the status code is derived from the *step* outcomes, so it
is structurally blind to a fabricated `to_state` / `from_state`. Two tests were
added to close that gap; both mutations then died. That gap is the same defect
class as the card itself — an assertion that looks like a check but cannot see
the field it is supposed to guard — and it was found by running the sweep, not
by reading the code.

Harness: `/tmp/sler-p1-5-mutate.sh`; full output `/tmp/sler-p1-5-mutation-report.txt`.
Tree confirmed byte-clean after the sweep (`git status --porcelain` showed only
the four intended modifications and the two new test files).

---

## 4. Benchmark — with the fleet size stated

The mission's out-of-scope rule forbids claiming a latency figure not measured
at a stated fleet size, so every figure below names one. Star-shaped synthetic
fleets, `stepDelay = 0`, `slog` discarded identically in both runs,
`-benchtime 500x -count 6`, AMD Ryzen 9 7900X, Go 1.26.2.

`benchstat` pre-fix vs post-fix (`sec/op`):

| Benchmark | Fleet size | Pre-fix | Post-fix | Δ |
| :--- | ---: | ---: | ---: | ---: |
| `StunCascade_Fleet5` | 5 | 6.353 µs ± 39% | 7.830 µs ± 8% | ~ (p=0.065, n=6) |
| `StunCascade_Fleet64` | 64 | 87.84 µs ± 7% | 106.56 µs ± 5% | **+21.30%** (p=0.002) |
| `StunCascade_Fleet256` | 256 | 339.2 µs ± 3% | 404.0 µs ± 3% | **+19.10%** (p=0.002) |
| `RecoverCascade_Fleet64` | 64 | 67.35 µs ± 6% | 97.33 µs ± 7% | **+44.52%** (p=0.002) |

Allocations rise correspondingly (+34% B/op on stun at 64 and 256, +80% on
recover at 64) — the per-target record is a real object where previously there
was a discarded warning.

**Reported, not dismissed.** Three of the four deltas are statistically
significant. Two things put them in proportion, and one is a genuine cost that
must not be buried:

1. **Orchestration CPU is not the cascade's wall-time.** At fleet size 256 the
   delta is **+64.8 µs across 256 targets — +253 ns per target**. The shipped
   production `STEP_DELAY_MS` default is 200 ms *per agent*, i.e. 51.2 s for that
   same cascade. The added bookkeeping is ~0.0001% of it.
2. **Recovery now makes one extra Kubernetes API call per target**, and that is
   the material change here, not the CPU. `Recover` previously hard-coded
   `FromState: StateStunned` — asserting the precondition a recovery exists to
   verify. It now reads it. At fleet size 256 that is 256 additional apiserver
   reads (2 calls per agent → 3). In production a round-trip dominates the 469 ns
   of CPU this benchmark measures. **This is a deliberate trade recorded as
   decision D-4: one read per target buys the difference between reporting what
   an agent was and guessing it.** If a future card finds the read too expensive
   at fleet scale, the correct remedy is a batched list call, not a reinstated
   guess.

No denial-latency figure is claimed by this card. Nothing here touches the
freeze, mesh, bao, spire or admission planes.

### 4.1 Fleet-size comparison against P0 and P1-1 — as required

| Source | Cascade wall-time benchmark | Stated fleet size |
| :--- | :--- | :--- |
| **P0** (`sler-p0-baseline.md`) | **none** — P0 measured *freeze* latency (avg 4 ms, p95 12 ms), not cascade orchestration | **none.** P0 records this as a finding in its own right: `:426-428` notes the committed evidence claims `freeze_latency_p95_ms: 12.0` *"at no measured fleet size"*, already violating the mission's out-of-scope rule |
| **P1-1** | **none on the integration branch.** P1-1 was `in_progress` at the time of measurement (board read 2026-09-15) and has landed no benchmark artefact | n/a |
| **P1-5** (this card) | `StunCascade` at 5 / 64 / 256; `RecoverCascade` at 64 | **stated in every benchmark name and in the table above** |

**Consistency finding, stated plainly: there is no P0 or P1-1 cascade wall-time
baseline to be consistent *with*.** The card asks for a comparison confirming
consistency; the honest answer is that the comparison has no counterpart on
either side, because neither prior card measured this path and P0's only latency
figures are for a different subsystem at an unstated fleet size. This card
therefore *establishes* the baseline rather than matching one, and does so at
three sizes — including 256, an order of magnitude above the 5-agent demo fleet
in `fleet.yaml` — so that a later regression has room to express itself. A
subsequent card benchmarking this path should quote fleet size 64 and 256 to be
comparable with the table above.

---

## 5. Decisions

- **D-1 — The label write is attempted even when the credential revoke fails.**
  The card permits either behaviour *"unless the design explicitly allows partial
  containment with that residual documented"*. Skipping the write on a revoke
  failure would leave the agent both credentialed **and** unlabelled, which is
  strictly *less* containment than leaving it credentialed and labelled — and the
  admission block (`node-capability-guard`) keys off the label. Under the
  architectural constitution's fail-closed rule, applying more containment is the
  correct arm. See residual **R-1**.
- **D-2 — `OutcomeNotFound` was added to P1-2's `PlaneOutcome` rather than to a
  parallel enum.** The card requires `not_found` to map to a distinct enum value.
  `schema.go` is nominally P1-2's, but P1-2 is merged and a new sibling enum
  would have produced two outcome vocabularies on one wire. All four pre-existing
  `AggregateOutcome` cases are preserved.
- **D-3 — 404 for an all-`not_found` cascade, not 500.** It sends the operator to
  check their targeting rather than plane connectivity.
- **D-4 — `Recover` now reads the pre-state.** Costs one API call per target;
  buys the removal of a hard-coded `FromState: StateStunned`. Quantified in §4.
- **D-5 — The independence test does not name `noopFleetClient`.** The card asks
  for proof that the fix does not require retiring it. Referencing the symbol
  would have created a compile-time collision with SLER-P1-1, which is retiring
  it concurrently. `TestHonestyFix_IsIndependentOfTheClientImplementation`
  asserts the property through the `FleetClient` interface instead, so it holds
  whichever implementations exist.
- **D-6 — Two pre-existing `gofmt` misalignments left alone.** `main.go:261` and
  the `mockFleetClient` error-field block in `cascade_test.go` were already
  unformatted at `4a70a293` (verified against `git show HEAD:...`). Reformatting
  `main.go` would collide with P1-1's concurrent edit to that exact block.

## 6. Residuals

- **R-1 — A live credential behind a stunned label.** When `RevokeCredentials`
  fails but the label write succeeds, the agent is labelled contained while its
  OpenBao lease remains valid until TTL. Per D-1 this is the better of the two
  available states, and it is **no longer invisible**: the target reports
  `outcome: partial` with the revoke error attached, and the endpoint answers
  `207`, not `200`. Closing it properly requires P2-1's active OpenBao lease
  revocation with retry.
- **R-2 — The cascade still has no plane-level results.** `CascadeResult.Planes`
  remains empty; this card fixes per-*target* honesty, not per-*plane* reporting.
  The mission's Published Denial Matrix is not satisfied by this card.
- **R-3 — Dashboard behaviour change.** `fleetFetch` in `fleetApi.ts` throws on
  any non-2xx. A total containment failure now raises an error in the UI instead
  of rendering a successful cascade. That is the intended consequence; `207`
  passes through `res.ok` unchanged, so partial containment still renders, now
  carrying honest per-target state.
- **R-4 — `Stun` and `Recover` are still sequential.** Unchanged by this card and
  out of its scope.
