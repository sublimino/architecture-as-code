# SLER-P1-1 — Proof: real FleetClient, no-op silent fallback retired

**Card:** SLER-P1-1 · Unify Enforcer interface and eliminate `noopFleetClient` silent fallback
**Base:** `integration/sler-v0.1.0` @ `4a70a293`
**Module:** `d2-signalloom/apps/fleet-manager`

---

## 1. The defect, stated precisely

`noopFleetClient` was not merely "doing nothing". Its return values were the values a
healthy real client returns on **success**:

```go
func (n *noopFleetClient) GetPodState(...) (string, error) { return StateRunning, nil }
func (n *noopFleetClient) SetPodState(...) error           { return nil }
func (n *noopFleetClient) RevokeCredentials(...) error     { return nil }
func (n *noopFleetClient) RestoreCredentials(...) error    { return nil }
```

So `CascadeOrchestrator.Stun` recorded `Success: true` for every target and `handleStun`
answered HTTP 200. **A failed containment was indistinguishable from a successful one at
every layer above the client**, which is strictly worse than having no client at all: it
manufactures the single value an operator would act on.

It was selected unconditionally at `main.go:250` — no flag, no env var, no cluster probe,
no log line.

---

## 2. Before / after grep counts

All counts taken with the literal commands named in the card's Required Tests.
"Before" is read from git (`git show integration/sler-v0.1.0:<path>`), not from memory.

| Probe | Before | After |
|---|---|---|
| `grep -c noopFleetClient main.go` | **7** | **0** |
| `grep -n noopFleetClient main.go` exit status | 0 (matches) | **1 (no matches)** |
| `grep -c 'InClusterConfig\|BuildConfigFromFlags' main.go` | 0 | 0 — *see note* |
| `grep -rn 'InClusterConfig\|BuildConfigFromFlags' *.go` (module-wide) | **0 occurrences, 0 files** | **3 occurrences in `fleetclient_select.go`** (`:86`, `:88`, `:105`) |
| `go test ./...` | `ok` (green while enforcing nothing) | `ok` — **81 pass, 0 fail** |
| `go vet ./...` | clean | clean |

**Note on the third row.** The card's Required Test greps `main.go` for the client
construction. After the refactor `main.go` delegates to `selectFleetClient(...)` and the
`rest.InClusterConfig` / `clientcmd.BuildConfigFromFlags` calls live in
`fleetclient_select.go`, so the count in `main.go` is 0 **by design**. The command as
literally written measures the wrong file once the selection is extracted; the
module-wide count is the meaningful probe and it moved 0 → 3. Reported both ways rather
than silently substituting a probe that passes.

**Note on the first row.** After the edit, `main.go` initially still matched once — on a
*comment* explaining the line that had been removed. A guard that a comment can satisfy
is not a guard (this repo has been bitten by exactly that shape before), so the comment
was reworded to never spell the identifier. The count is now genuinely 0, and
`main.go:302-312` says so explicitly. The type itself is documented at length in
`fleetclient_select.go:206-233`, where it belongs.

Remaining `noopFleetClient` references, by file — every one is either the definition, the
single flag-gated selection, a test, or prose:

```
fleetclient_select.go:142   Client: &noopFleetClient{}   <- the ONLY construction, inside the exact-literal branch
fleetclient_select.go:223   type noopFleetClient struct{}
fleetclient_select.go:225-233  interface assertion + methods
k8sclient_test.go:499,517   negative and positive selection assertions
health_test.go:102          /health naming test
enforcement.go:15,54,113    prose explaining the defect
```

---

## 3. What was built

| File | Purpose |
|---|---|
| `enforcement.go` (new) | `ErrEnforcementUnavailable`, `ErrTargetNotFound`, `StateUnknown`, the six-field label/annotation contract, `PodStateLabelValue`, the `degradedRegistry`, `classifyAPIError`, and `unavailableFleetClient` |
| `k8sclient.go` (new) | `k8sFleetClient` — client-go backed `GetPodState` / `SetPodState` / `Health`, pod resolution with selector fallback, typed credential stubs |
| `fleetclient_select.go` (new) | `selectFleetClient` (the gate), `defaultRestConfigLoader` (in-cluster → KUBECONFIG), and the demoted `noopFleetClient` |
| `k8sclient_test.go` (new) | 30 tests against the fake clientset, fail-closed path first-class |
| `health_test.go` (new) | `/health` enforcement reporting and the break-glass invariant |
| `main.go` | flag parsing, gated selection, startup health probe, `/health` enforcement fields |
| `cascade.go` | **one block only**: `Health(ctx) error` added to the `FleetClient` interface |
| `cascade_test.go` | `mockFleetClient` gained `Health` |
| `base/rbac.yaml` | the verb contract, derived from the call sites |
| `base/deployment.yaml` | `FLEET_CLIENT` / `AGENT_NAMESPACE` stated explicitly |
| `go.mod` / `go.sum` | client-go **v0.31.0**, pinned to match `apps/signalloom-stun-sentinel` |

### The three-valued contract

The old code projected a three-valued space onto a boolean. A plane request has three
outcomes, and the third is the one it could not express:

| Outcome | Meaning | Return |
|---|---|---|
| known-contained | the plane answered "done" | `nil` |
| known-not-contained | the plane answered "absent" / "refused" | `ErrTargetNotFound` |
| **unknown** | the plane did not answer at all | `ErrEnforcementUnavailable` + degraded record |

A Forbidden (RBAC-denied) response maps to **unavailable**, not to a verdict: a client
denied the verb cannot enforce and must say so rather than report a conclusion it never
obtained.

### The gate

```
--fleet-client=noop-test-only   EXACT literal — the only route to the double, logs WARN
--fleet-client=kubernetes       real client
--fleet-client=auto | <empty>   same as kubernetes (the default)
--fleet-client=<anything else>  logged at ERROR, then treated as auto
```

The permissive branch is the exact-match branch. A typo (`noop`, `NOOP-TEST-ONLY`,
`no-op-test-only`, trailing space) falls to the real client and then, if that cannot be
built, to `unavailableFleetClient` — which fails closed. **A misconfiguration can never
silently buy you the no-op.** Thirteen near-miss values are asserted in
`TestSelectFleetClientNeverDefaultsToNoop`.

`unavailableFleetClient` is the fallback rather than `os.Exit(1)` deliberately: a
crash-looping fleet-manager during an API-server outage makes break-glass traverse the
very plane that just failed, which is a hard blocker named by this card.

---

## 4. Test evidence

`go test ./...` → **81 pass, 0 fail**. `go vet ./...` → clean.

### Mutation falsification

A green suite whose whole point is a failure path is the suspicious state, so the suite
was falsified by mutating the implementation and confirming named tests die. Every
mutation was reverted from a `/tmp` backup under an `EXIT` trap, and the tree was
confirmed clean afterwards.

| # | Mutation | Result |
|---|---|---|
| M1 | failed read returns `StateRunning` again (the original defect) | killed — `TestK8sGetPodStateUnavailableFailsClosed`, `TestK8sMissingPodIsNotFoundNotUnavailable`, `TestK8sAmbiguousTargetFailsClosed` |
| M2 | `RevokeCredentials` returns `nil` | killed — `TestK8sCredentialStubsFailClosed` |
| M3′ | containment-mode stuck at `frozen` (restore never thaws) | killed — `TestK8sRestoreClearsEveryContainmentTerm` |
| M4 | `StateRunning` written verbatim to the label | killed — `TestK8sRestoreWritesALabelValueTheVocabularyAdmits` |
| M5 | unreachable cluster falls back to the no-op | killed — `TestSelectFleetClientUnconfiguredFailsClosedNotNoop` |
| M6′ | stun-reason never blanked on restore | killed — `TestK8sRestoreClearsEveryContainmentTerm` |
| M7 | `stunned` label never set true | killed — `TestK8sSetPodStateWritesBothLabels`, `…IsIdempotent`, `…WritesAllThreeSentinelTerms` |
| M8 | Forbidden collapsed into NotFound | killed — `TestK8sForbiddenMapsToUnavailable` |
| M9 | degraded registry never records | killed — 7 tests |
| M10 | degraded registry keyed by target only (the defect found in review) | killed — `TestDegradedRegistryIsKeyedPerPlane`, `TestDegradedSnapshotDistinguishesPlanes` |
| M11 | Forbidden no longer separable from a transient failure | killed — `TestK8sForbiddenMapsToUnavailable` |
| M12 | every API error classified as a permanent denial (the inverse) | killed — `TestK8sTransientFailureIsNotReportedAsDenial` |
| M13 | the sentinel-watched check removed | killed — `TestK8sRefusesPodTheSentinelDoesNotWatch` |
| M14 | a retry restamps the containment timestamp | killed — `TestK8sRetryPreservesTheContainmentTimestamp` |
| M15 | caller cancellation reported as plane blindness | killed — `TestK8sCallerCancellationIsNotPlaneUnavailability` |
| M16 | error cause flattened with `%v` instead of a second `%w` | killed — `TestK8sErrorChainPreservesTheCause` |
| M17 | the environment can disarm enforcement | killed — `TestSelectFleetClientRefusesTheNoopFromTheEnvironment` |
| M18 | a stale `clear` can erase a fresher `mark` | killed — `TestDegradedRegistryRejectsStaleVerdicts` |

**18/18 killed.** Also run under `go test -race`: clean (the degraded registry is written
from concurrent HTTP handlers, so `go test ./...` alone would not have exercised it).
`gofmt -l` clean on every file this card touches — `topology.go` was already unformatted
on the base ref and was not touched.

Three attempts were discarded as **inconclusive rather than counted as kills**:

- Two early mutations (deleting a line from the patch map) produced a failure with *no*
  `--- FAIL:` line. That is a **compile error** — the deletion orphaned a variable — not a
  test kill. Re-run as M3′/M6′ with mutations that compile. A harness that scores a build
  failure as a kill overstates its own coverage, so the runner now classifies that case
  explicitly.
- One M12 attempt reported "EDIT DID NOT APPLY" from a `grep` **regex error**
  (`ugrep: invalid repeat`), not from a real result. Re-run with fixed-string matching. A
  zero-match from a broken pattern is indistinguishable from a surviving mutation unless
  the two cases are separated.

### One test-harness trap found and documented

`cs.ReactionChain = nil` does **not** "turn a fault off" on a fake clientset — it removes
the default object reaction too, so every later call returns an empty object with a nil
error. The suite then reads green for a client that was never exercised. Replaced with a
switchable `outage` helper (`k8sclient_test.go`), with the reasoning written next to it.

### Required-test results

| Command | Result |
|---|---|
| `cd d2-signalloom/apps/fleet-manager && go test ./...` | **ok** — 81/0 |
| `cd d2-signalloom/apps/fleet-manager && go vet ./...` | **clean** |
| `grep -n 'noopFleetClient' main.go` | **no matches** (exit 1) — intended after-state |
| `grep -c 'InClusterConfig\|BuildConfigFromFlags' main.go` | 0 in `main.go`; **3 module-wide** — see §2 |
| `bash scripts/run-redteam-suite.sh` | **exit 0**, 15/15 — *but see the caveat below* |

> **The red-team suite proves nothing about this card, and would pass against an
> unenforced cluster.** `scripts/run-redteam-suite.sh:25` writes
> `docs/signalloom/evidence/adversarial-redteam-proof.json` entirely from hardcoded
> literals (`scenarios_passed: 15`, `process_escapes: 0`, …); `$TIMESTAMP` is the only
> interpolated value, which is why the run dirties the tree. `test/crkc-adversarial-redteam.bats`
> then asserts against that same file. It is structurally incapable of failing. It was run
> because the card requires it, it exits 0, and the single-line timestamp change it made was
> reverted (`git checkout --`). It is recorded here as a **known pre-existing defect owned by
> P6-1**, not as evidence for P1-1. The evidence for this card is §4's mutation table.

---

## 4a. Defects found in review and fixed before commit

An adversarial review at the commitment boundary found one defect that would have
shipped, and one improvement. Both are now implemented, tested, and mutation-falsified
(M10–M12 above).

### R1 — the degraded registry lied by construction (FIXED)

The registry was keyed by target alone: `degradedKey(namespace, agentID)`.

`RevokeCredentials` is a typed P2-1 stub that **always** fails, so every contained target
was permanently degraded. Then the next successful `SetPodState` — which proves something
only about the **freeze** plane — called `clear()` on the same key and retracted a record
whose subject was the **bao** plane and which was still true. `DegradedTargets()` would
report a credential plane known to be broken as available. One plane's partial success
vouching for its siblings.

**Fix:** the key is now `(plane, namespace, agentID)`. `clear()` can only ever retract a
claim about the plane that just answered. `isDegraded` reports degradation on *any* plane
(fail-closed: a target unreachable on one plane is not fully contained); a narrower
`isDegradedOnPlane` answers the per-plane question for callers deciding what to retry.
`TestDegradedRegistryIsKeyedPerPlane` asserts a freeze-plane success does not erase a
bao-plane failure.

This is the defect class the card's own Deliverables warn about — a result type that
cannot represent a partial failure — reintroduced one level down inside the mechanism
built to prevent it.

### R2 — `ErrEnforcementDenied` separates permanent from transient (ADDED)

A 403 is not "the plane could not answer". The plane answered, authoritatively and
permanently, *no*. Collapsing it into `ErrEnforcementUnavailable` leaves a caller or
operator backoff loop retrying a decision that will never change.

`ErrEnforcementDenied` now **wraps** `ErrEnforcementUnavailable`, so
`errors.Is(err, ErrEnforcementUnavailable)` still holds and every fail-closed path is
unchanged, while the permanent case is separable. Asserted in both directions:
`TestK8sForbiddenMapsToUnavailable` (a denial is a denial) and
`TestK8sTransientFailureIsNotReportedAsDenial` (a connection failure is not).

### R3 — two review findings assessed and deliberately NOT actioned

**"Map every unrecognised label to `StateUnknown` on read, never pass through."**
Declined, because it inverts on the actual consumer. `GetPodState`'s return flows to
`StateChangeEvent.FromState` (`cascade.go:100`) and onto the wire the dashboard renders,
which speaks the **label** vocabulary — `idle` is a meaningful value there. Mapping it to
`unknown` would make every idle agent render as unknown: information destroyed, not
gained. Verified that no code compares `GetPodState`'s result to a Go state constant
(`grep -n '== StateRunning' *.go` → one match, inside the write-mapper itself). The
asymmetry is deliberate and now documented at the function.

**"`SetPodState(StateRunning)` on a pod that was `idle` fabricates `active`."**
Correct, and acknowledged as a real limitation rather than fixed here. The pre-stun value
is destroyed by the stun and the client cannot recover it. The obvious fix — capture it in
a new annotation — is **unreliable under Flux**: `.spec.ignore` preserves only paths the
desired object declares, so a key not in the manifest is stripped on the next reconcile
(the same mechanism as F3). Writing `active` matches every other un-stun path in the repo
(`scripts/supercred-fleet-demo.sh:404`, `scripts/swarm-fleet-demo.sh:288`). Recorded here
rather than hidden; a faithful restore needs the annotation added to the manifests' ignore
surface first, which is a Flux change outside this card.

### R4 — second review round (six further defects, all fixed)

A second adversarial pass found six more. Note the reviewer's own disclosure: it ran
**Claude-family, not cross-vendor**, because `codex` was rate-limited and the pinned
`gpt-5.4` is rejected on this account — so the independent-lineage blind-spot coverage
that routing to Forge normally buys was **not** obtained on this card. Recorded rather
than glossed.

| # | Defect | Fix |
|---|---|---|
| R4.1 | **A stun could land on a pod the sentinel does not watch.** Neither resolution path required `signalloom.ai/agent=true`, but the sentinel's informer is filtered to it. Patching such a pod writes all three containment labels and returns `nil` — full success — for a workload that will never be frozen. Registry clean, `/health` zero degraded, dashboard shows contained, agent running at full privilege. The original no-op defect reached sideways. | `requireSentinelWatched` refuses and marks degraded. Labelling a pod is not containing it. |
| R4.2 | **`SetPodState` was not idempotent**, and its own doc comment claimed it was. `stunned-at` came from wall-clock time, so a retry overwrote "when was this contained" with "when did someone last press the button" — destroying the value an incident timeline and P3's attested record are built on. Containment idempotency under retry is a hard blocker named by this card. | Preserve an existing timestamp; stamp only a genuinely new containment. Clock injected so the assertion is about the code, not about how fast the test ran. |
| R4.3 | **Caller cancellation reported as plane unavailability.** An operator navigating away mid-cascade cancels `r.Context()`; the in-flight request returns `context.Canceled` and was classified as blindness. The plane was healthy — *we* hung up, and the patch may well have applied. The same category collapse this file guards against, in reverse. | Cancellation is classified separately and never marks a target degraded. |
| R4.4 | **`"%w: %v"` flattened the cause**, destroying `errors.Is` for everything underneath — `context.DeadlineExceeded`, `IsTooManyRequests`, `IsConflict`, `IsTimeout`. A caller could not tell a rate-limit from a dead API server. `go.mod` is go 1.24, so the single-verb form was a choice. | Two `%w` verbs. |
| R4.5 | **`FLEET_CLIENT` was a second, undefended route to the no-op.** The env var is the flag's default, so it reached the gate verbatim — and the contract claimed the flag was "the only path". `kubectl set env`, an `envFrom` merge, or a mutating webhook all disarm enforcement fleet-wide without touching argv. | The double is honoured from argv and **refused** from the environment, loudly, then treated as `auto` so the process still comes up enforcing. |
| R4.6 | **No client-side timeout: fail-closed became fail-HANG.** An API server that accepts the connection then stops answering leaves `Patch` blocking forever — request never returns, target never marked degraded, `/health` still reporting zero. The whole registry is premised on calls returning. (`http.Server.WriteTimeout` does not cancel `r.Context()`.) | `cfg.Timeout` set on both config paths. |

Three further items, all fixed: `/health` re-probes live rather than echoing the boot-time
verdict forever (a process that lost its API server an hour ago was reporting
`enforcement: available` indefinitely, because `degraded_targets` only moves when an
operation is *attempted* and a quiet fleet attempts none); `snapshot()` deep-copies
`Details` (a shallow copy shares the `map[string]any` header, so a caller could write
through it into the live registry while `/health` ranges over it — a Go runtime throw, not
a benign race); and `flag.ContinueOnError` replaces the default `ExitOnError`, which would
have let one typo'd argument `os.Exit(2)` before the listener binds — a startup crash-loop
through the back door, contradicting this card's own break-glass design.

`mark`/`clear` now carry a monotonic sequence ticket taken **before** the API call and
compared under the lock. The mutex alone was not enough: the *decision* to mark or clear is
made outside it, at call-return time, and HTTP handlers are concurrent over one shared
client. A stun and a recover in flight against the same target resolved by scheduler
order — half the time leaving spurious blindness, half the time reporting a target healthy
that genuinely could not be enforced.

### R5 — two review findings assessed and NOT actioned, with reasons

**`cascade.go` hardcodes `Success: true` and swallows every client error.** Both reviews
raised this as critical, and both are right that it makes everything in `enforcement.go`
and `k8sclient.go` invisible above the client boundary: with the fail-closed client
installed, `POST /api/v1/fleet/stun/...` still answers **HTTP 200** with
`{"success":true}` and no error key, byte-identical to a real containment. Specifically
`cascade.go:100-104` (an unreadable state is overwritten with `StateRunning`, discarding
the `StateUnknown` the client went to lengths to return), `:107`/`:113` (warn-and-continue
past revoke and set failures), `:116-122` and `:172-178` (`Success: true` literal;
`StateChangeEvent.Error` is never assigned anywhere in the file).

**This is SLER-P1-5, explicitly and by name.** Its row in the Work Decomposition reads:
*"cascade.go:90-91 treats an unreadable pod state as running, :96 and :101 continue past
revoke and set failures, then :107 unconditionally reports StateStunned with a 200. The
defect is in the orchestrator, so retiring noopFleetClient per P1-1 does not fix it."*
Fixing it here would take a shared file another card owns and is mid-work on. What P1-1
delivers is that the client's half is now honest and the orchestrator has something true
to read; the `[x]` on this card does not claim the HTTP surface is fixed.

**`CascadeResult.Planes` and `OverallOutcome` are declared and never populated.** Both are
`omitempty`, so they vanish from the response — a consumer sees an absent field, not a
degraded one. The client now produces exactly that data via `DegradedTargets()` and
nothing carries it to the wire. This is the field that would make the defect above visible
without changing `Success`. Also `cascade.go`, also P1-5, and it is the concrete
suggestion to hand that card.

**One limitation left standing, deliberately.** `RevokeCredentials`/`RestoreCredentials`
take no namespace parameter, so their degraded records key on the client's default
namespace while freeze-plane records key on the target's. For an agent configured into a
non-default namespace the credential-plane entry is unreachable by `IsDegraded` for the
process lifetime. Fixing it requires a `FleetClient` signature change, which is P1-3's
contract freeze, not this card's. Flagged there.

---

## 5. Findings surfaced beyond the card's scope

An independent derivation of the label contract (run against the manifests rather than
against my own fixtures) produced seven disagreements between sources of truth. Three
changed this implementation; four are recorded for other owners.

### Folded into this card

**F1 — `StateRunning = "running"` is not a legal label value.** `cascade.go:12` defines it
and `Recover` writes it (`cascade.go:161`). `"running"` appears in **zero** manifests and
is not a member of `AgentStateValue` — this module's own contract test enumerates the
client-known values at `contract_test.go:153-156`. Under the no-op the value never left
the process. Writing it to a live pod makes the dashboard's `derivePhase` switch fall to
its default arm and report the agent as `deployed` — a believable wrong answer.
**Mitigation:** `PodStateLabelValue` maps it to `"active"` (what every other un-stun path
in the repo writes) at the client boundary, on WRITE only. Reads return the label
verbatim, because the pod's value is what the dashboard and the sentinel consume. Fixing
the constant belongs to P1-5, which owns the orchestrator; this boundary keeps the
corruption off pods meanwhile.

**F2 — the sentinel ORs three terms, not one.**
`apps/signalloom-stun-sentinel/main.go:31-43`: a pod is stunned if
`signalloom.ai/state == "stunned"` **OR** `signalloom.io/stunned == "true"` **OR**
`signalloom.io/containment-mode == "frozen"`. Writing only the state label is enough to
**freeze** a pod but not enough to **thaw** one: a stale `containment-mode=frozen` keeps
the OR true, so the workload stays frozen while the dashboard reports it healthy — a
split brain in the direction that lies reassuringly. `SetPodState` now writes all three in
one patch. `TestK8sRestoreClearsEveryContainmentTerm` mirrors the sentinel's own
predicate.

**F3 — no writer in the repo clears the provenance annotations on recover.** Every stun
writer sets `signalloom.ai/stunned-at`, `signalloom.ai/stun-reason` and
`signalloom.io/stun-reason`; none clears them, so a recovered agent carries
`state=active` beside a stale stun reason. `SetPodState` now blanks all three on restore.
They are set to `""` and **never removed**: Flux's `.spec.ignore` preserves a path only if
the desired object declares it, so a removal drops the key from the ignore surface and
the next reconcile wipes it for good (measured and documented at
`apps/fe-signalloom/base/agents-cardvault.yaml:32-41`).

Related: the patch carries `FieldManager: "flux-client-side-apply"`, matching every other
writer of these fields (the three demo scripts and the integration proxy) — a convention
`test/flux-drift-ignore.bats:54-65` asserts on. Without it this client would be the first
deviant writer, outside what the drift-ignore mechanism was validated against.

### Recorded for other owners — NOT actioned here

**F4 (blocking for the Recover path) — the CEL policy denies fleet-manager the un-stun.**
*Derived by reading the policy source, NOT observed against a live cluster.* No test in
this card can have seen it: the fake clientset does not run admission, and this card
contacts no cluster. What is tested is the **mapping** — an injected `NewForbidden`
becomes `ErrEnforcementDenied` — which proves the client handles a 403 correctly and
proves nothing about whether the policy is deployed anywhere. Stated plainly because an
inferred denial reported as an observed one is the fabrication class this whole card is
about.
`d2-agent-trust/policies/agent-identity-state-protection.yaml:35-42` permits mutating
`signalloom.ai/state` away from `stunned` only for `swarm-governor`, `kubernetes-admin`,
`kind-osramp`, `system:admin*` or `system:masters`. **`system:serviceaccount:fe-signalloom:fleet-manager`
is not on that list**, and the binding Denies in `fe-signalloom-agents` (`:77-83`) — the
namespace the fleet config targets. So wherever that policy is live, `SetPodState(stunned)`
succeeds and `SetPodState(active)` is **403 at admission**, making
`CascadeOrchestrator.Recover` unimplementable as written.

This card does **not** widen the policy. Silently adding `fleet-manager` to an
authorised-mutator list is a security-boundary change, and the correct resolution
(amend `isGovernorOrAdmin`, or route recovery through `swarm-governor`) is P1-GOV's call.
What this card does guarantee is that the denial is **visible**: a 403 becomes
`ErrEnforcementUnavailable`, the target is marked degraded, and `/health` reports it —
rather than being swallowed. Asserted by `TestK8sForbiddenMapsToUnavailable`.

**F5 — four of five fleet agents would be denied at CREATE.** The same policy (`:43-55`,
`:62-66`) requires every pod labelled `signalloom.ai/agent=true` to carry a valid
`signalloom.ai/framework`. `agent-cardvault` and `agent-sir-lancelot` have it;
`agent-txn-pipeline`, `agent-llm-classifier`, `agent-api-gateway` and `agent-monitor` do
not. They are applied by `kubectl apply -k` rather than by Flux, which is probably why
this has never fired.

**F6 — `agent-cardvault` exists in two incompatible shapes.** A bare `Pod` at
`apps/fe-signalloom/base/agents-cardvault.yaml:10-12` (wired up, carries the six
containment fields) and a `Deployment` at
`infra/agent-swarm/agent-cardvault/deployment-overlay.yaml:3-5` (not in that directory's
`kustomization.yaml`, so dormant, and carrying none of the state labels). If the dormant
one is ever applied, name-based `Get` misses and the selector `List` returns two objects.
This client treats a multi-match as **unavailable** rather than picking the first —
acting on the wrong pod is worse than declining to act
(`TestK8sAmbiguousTargetFailsClosed`).

**F7 — drift protection is inconsistent per agent.** `agent-cardvault` is protected by
`.spec.ignore`; `agent-sir-lancelot` is a documented KNOWN GAP
(`d2-osramp-fleet/tenants/local/signalloom.yaml:695-708` — *"the gap is currently
unreachable. It stops being unreachable the moment anyone stuns one"*); the four
`fleet-agents` pods are outside Flux entirely and so are safe by accident. A client that
listed by selector rather than by fleet-config id could reach the sir-lancelot gap. This
one resolves targets from the fleet config, so it cannot — today.

---

## 6. RBAC

The authoritative Role is `fleet-manager-pod-reader`, namespace `fe-signalloom-agents`,
at `d2-osramp-fleet/tenants/local/signalloom.yaml:1007-1039`. It grants
`["get","list","patch"]` on `pods`.

Checked against the real client's complete call list:

| Verb | Call site | Needed? |
|---|---|---|
| `get` | `resolvePod` — Pod by name | yes |
| `list` | `resolvePod` selector fallback; `Health` `Limit:1` probe | yes |
| `patch` | `SetPodState` strategic merge on labels + annotations | yes |

**Exactly sufficient, and not one verb wider. SLER-P1-1 widened nothing.** `watch` is not
granted (the client polls; it builds no informer), and `update` is not granted (`patch`
already covers strategic-merge, JSON-merge, JSON-patch and server-side apply — `update` is
a full-object replace that would let a compromised fleet-manager rewrite an agent's spec
rather than only its containment labels). `create` and `delete` are not granted:
containment freezes and labels workloads, it never creates or destroys them.

### Deviation: where the verbs are documented

The card says to update `d2-signalloom/apps/fleet-manager/base/rbac.yaml` with the
minimum verbs. **On disk that file holds only the ServiceAccount**, and it carries a
27-line comment giving two independent reasons a Role there breaks Flux:

1. The `signalloom-apps` Kustomization sets `targetNamespace: fe-signalloom`, which
   overrides a manifest's declared namespace — so a Role written for
   `fe-signalloom-agents` lands in `fe-signalloom` instead, cleanly and with Flux
   reporting Ready, while fleet-manager holds no grant in the namespace the agents
   actually run in.
2. `signalloom-apps` reconciles as the namespace-scoped `flux` ServiceAccount, which
   holds `ClusterRole/admin` but not `escalate` on roles. Creating a RoleBinding makes
   the API server resolve its `roleRef` to run the privilege-escalation check, and
   kustomize-controller server-dry-runs the entire object set before applying any of it —
   so the lookup fails against a Role that was never persisted and the whole set aborts.
   That deadlock previously left `fe-signalloom` empty for six reconciles.

So the Role was **not** duplicated. Instead the existing Role's verbs were verified
minimal against the call sites, and the verb contract — including the explicit
not-granted list and the two limits RBAC cannot express (namespace scoping, and the CEL
policy of F4) — was written into `base/rbac.yaml`, which is the file the card names.

### Correction to the card's premise on the label

The card says to implement pod state "against the same pod-state label
node-capability-guard's `ValidatePod` (handler.go:99-109) checks". **`ValidatePod` reads
no state label.** `pkg/webhook/handler.go:84-86` checks agent *identity* labels, and
`:99-109` checks the `node.signalloom.ai/{cgroup-v2,landlock}` nodeSelector. The actual
shared contract is `signalloom.ai/state`, which twelve agent manifests carry and which
`infra/agent-swarm/ebpf-sentinel-rbac.yaml:5` documents as the PATCH target for
`=stunned`. That is what was implemented, exported as constants so P2/P3 consume one
symbol rather than re-deriving the strings.

---

## 7. Scope held

Not touched, and why:

- **`cascade.go`'s swallow-and-continue defect** (`:93-107` — an unreadable state becomes
  `StateRunning`, revoke and set failures are logged and stepped past, then `Success: true`
  is recorded unconditionally). P1-5 owns it explicitly and its row states that retiring
  the no-op does not fix it. The client's half is now honest; the orchestrator's half is
  not yet, and the `[x]` on this card does not claim otherwise.
- **`Contain` / `Resume` / `Plane()`** on the constitution's `Enforcer` interface — P1-3
  owns the contract freeze. Only `Health(ctx) error` was added, which this card's
  Deliverables name explicitly. Inventing plane semantics here would give P1-3 something
  to undo.
- **OpenBao lease revocation and SPIRE entry eviction** — P2-1 / P2-2. Shipped as typed
  stubs that return `ErrEnforcementUnavailable`, never `nil`.
- **No live cluster was contacted.** Every probe runs against client-go's fake clientset.
