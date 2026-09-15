# SLER-P1-GOV — Phase 1 decision-freeze certification

**Verdict: CERTIFIED WITH CONDITIONS.** The phase-1 Enforcer contract is complete and internally
consistent. Thirteen conditions attach (C-1…C-15). **C-9 is blocking on phase-2 entry**: the
fleet-manager containment API has no authentication and no containment carries an attested decision
record, and no card on the board owns either. C-2 disqualifies the red-team suite as evidence for the
remainder of the mission. Phase 2 may start; SLER-P2-1 may not merge until C-9 closes.

| Field | Value |
| :--- | :--- |
| Reviewed tree | `468e3fc60334774c594622fe08dc4d580f4dc38b` |
| Branch | `integration/sler-v0.1.0` |
| Governor worktree | `/home/andy/src/.worktrees/osramp-demo/sler-v0.1.0/governor` |
| Reviewed at | 2026-09-15T01:50:38Z |
| Cards certified | SLER-P1-PRE, P1-1, P1-2, P1-3, P1-4, P1-5 |
| Placeholders outstanding | 0 |

---

## 1. Merge state — verified, not performed

The five phase-1 cards plus P1-PRE were merged into `integration/sler-v0.1.0` by the phase
controller before this card ran, in dependency order. This governor's merge deliverable is therefore
*verification* of that merge. Every commit is proven reachable from the reviewed tree by
`git merge-base --is-ancestor`:

| Card | Merge commit | Dependency order | Ancestor of reviewed HEAD |
| :--- | :--- | :--- | :--- |
| P1-PRE | `018b9eed` | 1st | ✅ |
| P1-2 | `4a70a293` | 2nd (P1-1 and P1-5 both depend on it) | ✅ |
| P1-4 | `f6bff072` | 2nd (independent, depends only on P1-PRE) | ✅ |
| P1-5 | `e30ab221` | 3rd | ✅ |
| P1-1 | `a01a8c9e` | 4th (collision with P1-5 in `cascade.go` resolved in-merge, `26c510a9`) | ✅ |
| P1-3 | `b2bbf87f` | 5th (depends on P1-1 and P1-2) | ✅ |

The named failure mode — *"merging in arbitrary order, silently reverting one card's fix in favour of
another's"* — did occur as a real collision between P1-1 and P1-5 in `cascade.go`, was detected, and
is documented at `26c510a9`. `TestHonestyFix_IsIndependentOfTheClientImplementation`
(`cascade_honesty_test.go:764`) is the standing guard that P1-1's client swap cannot re-open P1-5's
fix. This is the single most likely way phase 1 could have failed, and it was caught.

> **Concurrency note.** This ref is shared with `integration/slcd-v0.1.0` and
> `integration/amxd-v0.1.0`, and a controller merged into it *during* this review — HEAD moved from
> `ebfa3dce` to `468e3fc6` between the first and second command of this session. The certification
> above is bound to `468e3fc6` and to nothing later. Any SLER phase-2 card must re-confirm, not
> assume, that these six commits are still ancestors of whatever the ref points at when it starts.

---

## 2. The five claims, attacked

Each card's load-bearing claim was probed directly rather than inferred from its own passing tests.

### 2.1 P1-1 — the no-op client is unreachable in production. **UPHELD.**

`main.go:250` no longer reads `client := FleetClient(&noopFleetClient{})`. Selection routes through
`selectFleetClientFrom` (`fleetclient_select.go:185`), and four properties close the path:

- **Exact-match is the permissive branch** (`fleetclient_select.go:204`). Only the literal
  `noop-test-only` reaches the double. `noop`, `none`, `NOOP-TEST-ONLY` and every other value fall
  through to the real client. A misconfiguration cannot buy the no-op; only a deliberate statement can.
- **The environment may not disarm enforcement** (`fleetclient_select.go:194-203`). `FLEET_CLIENT`
  is still the flag's *default*, so a Deployment may select the real client that way, but the
  no-op literal is refused when `from == requestSourceEnv` and logged at `slog.Error`. This is the
  right boundary: `kubectl set env`, an `envFrom` ConfigMap merge and a mutating webhook all reach
  the environment and are available to anyone holding `patch` on the Deployment; rewriting argv is a
  materially higher bar.
- **The fallback fails closed, not open** (`fleetclient_select.go:234-241`). An unusable cluster
  config installs `unavailableFleetClient`, whose every method returns `ErrEnforcementUnavailable` —
  not a no-op. Retaining the no-op "just in case" would have reproduced the original defect exactly,
  because the cases that fall back are precisely the cases where enforcement is broken.
- **Calls cannot hang instead of failing** (`apiRequestTimeout = 15s`, `fleetclient_select.go:100`).
  Without it, fail-closed degrades to fail-*hang*: an API server that accepts the connection and
  stops answering leaves `Patch` blocking forever, the target is never marked degraded, and `/health`
  keeps reporting enforcement available. The whole degraded registry is premised on calls returning.

`noopFleetClient` still exists and still compiles (`fleetclient_select.go:293`) — correctly. Deleting
the test double would have been the wrong fix; making it unreachable is the right one.

### 2.2 P1-2 — the result type can express partial and failed containment. **UPHELD.**

This is a constitutional hard blocker and it is satisfied with margin. `PlaneOutcome` (`schema.go:16`)
is a four-valued enum, not a boolean:

| Value | Meaning |
| :--- | :--- |
| `contained` | the plane fully enforced |
| `partial` | partial enforcement — e.g. partial lease revocation, non-fatal degraded state |
| `unavailable` | enforcement failed completely, or the plane was unreachable |
| `not_found` | there was no such target to enforce against |

`not_found` is the one that is easy to omit and expensive to omit: without it, "the target does not
exist" and "we could not reach the plane" collapse into the same value, and a cascade against a
mistyped agent ID is indistinguishable from a cascade against an unreachable one. `CascadeResult`
aggregates over these (`cascade.go:127,138`) rather than over a success boolean.

### 2.3 P1-3 — the frozen contract describes what shipped. **UPHELD, and enforced mechanically.**

The freeze is not a document assertion. `contract_freeze_test.go` walks every frozen type by
reflection and fails *by name* on any field rename, removal, retype or retag;
`FrozenSchemaVersion` is asserted equal to `CurrentSchemaVersion` so bumping one without the other
is a test failure rather than silent divergence. `FrozenContractBumpProcedure`
(`contract_freeze.go:38`) is carried as a constant so the failing test prints *what to do next* —
which is the half that matters, because an engineer who cannot find the procedure edits the
expectation instead of requesting the bump, and that is exactly the drift the freeze exists to prevent.

**Divergence from plan, recorded:** the card's approach expected the resume token to be "documented as
a spec, not implemented yet… correctly scoped to P4-3". P1-3 delivered a working Ed25519
implementation (`resume_token.go`, 26 KB, with `SignResumeToken` / `VerifyResumeToken`). This
**overshoots** the plan rather than undershooting it, and the overshoot is benign: the library is not
wired into any resume path — §4.8 of the frozen contract still assigns the live wiring and the
mandatory credential rotation to SLER-P4-3. It de-risks P4-3 rather than pre-empting it. It is
recorded here so nobody later reads "Ed25519 dual-operator resume" on the phase-1 manifest and
concludes that governance-gated resume is live. **It is not live. Phase 2 must not assume it.**

**One attack specifically checked and closed.** A verifier that required only *its own* policy
threshold while checking that "every signature verifies" would have a validity predicate, not a
quorum: an attacker observing a genuine two-approval token could strip one signature and the
remainder would still satisfy every other check, yielding a legitimate-looking single-operator
resume — an attribution loss, which is the precise property the token exists to provide. Taking the
token's own claim alone would be worse, since the minter would choose their own threshold.
`resume_token.go:522` takes `max(policy.RequiredSignatures, token.RequiredSignatures)`, and
`RequiredSignatures` is inside the signing input (`lengthPrefix(buf, strconv.Itoa(...))`), so it
cannot be tampered without invalidating the signature. This is correct.

### 2.4 P1-4 — the credential reaches the freezer, not just the handler. **UPHELD.**

The named failure mode was that authentication would guard only the HTTP handler, letting any caller
with package access bypass it. It does not:

- `func (f *Freezer) Freeze(cgroupPath, credential string)` — `freezer.go:527`. The credential is in
  the **method signature**, and the check is the method's first act (`freezer.go:530`).
- The check is **fail-closed by construction**: `if f.freezeValidator == nil || !f.freezeValidator(credential)`.
  An unconfigured freezer refuses everything rather than permitting everything —
  `TestFreezeDefaultsToRefusal` (`freezer_test.go:735`) pins that.
- `FreezePod` has **no independent path**: it resolves the cgroup then delegates to `Freeze`
  (`freezer.go:586`), so the credential check is unavoidable.
- **Rejection is asserted at the freezer level, not only the handler level**:
  `TestFreezeRejectsWrongCredential` (:747), `TestFreezePodRejectsWithoutValidCredential` (:787),
  `TestUnfreezeDefaultsToRefusal` (:804), `TestUnfreezeRejectsWrongCredential` (:817).
- **Freeze and resume credentials are distinct**, and that is pinned by
  `TestFreezeAndUnfreezeValidatorsAreDistinct` (:758). Containment and release are different
  authorisations; a single shared secret would make "stop it" and "let it go" the same privilege.

### 2.5 P1-5 — the cascade no longer fabricates success. **UPHELD, all three swallow points.**

The original defect: `noopFleetClient` returned `StateRunning` and `nil` — the values a *healthy*
client returns on success — so the orchestrator recorded `Success: true` and the API answered 200 for
a containment that never happened. Each of the three swallow points now has a dedicated regression
test that reproduces the original behaviour and asserts against it:

| Swallow point | Call site | Regression test |
| :--- | :--- | :--- |
| State read | `cascade.go:303` `GetPodState` | `TestStun_UnreadableState_ReportsUnknownNotRunning` (:148) |
| Revoke | `cascade.go:315` `RevokeCredentials` | `TestStun_RevokeFailure_IsRecordedNotSwallowed` (:213) |
| Set state | `cascade.go:332` `SetPodState` | `TestStun_SetStateFailure_DoesNotReportStunned` (:247) |

They are fixed **together**, and the combined case is pinned separately:
`TestStun_AllThreeFailuresInjected_ReportsTotalFailure` (:275) and
`TestStun_ReadSucceedsButBothEnforcementStepsFail_IsNeverContained` (:325). The recover path carries
the symmetric tests (:663, :688, :719).

**The schema-reuse check passes.** The named failure mode was that P1-5 would invent an ad-hoc status
representation instead of using P1-2's. It does not: `StepResult` (`cascade.go:44`) carries
`PlaneOutcome`, and `TestPlaneOutcome_NotFoundIsADistinctValidValue` (:417) ties the two cards
together in one assertion. There is one status vocabulary, not two.

**Idempotency under retry — the hard blocker — is satisfied.**
`TestStun_RetryOnAlreadyStunnedTarget_ReportsNoSpuriousFailure` (:446) asserts that re-running a
containment against an already-contained target does not double-apply or report a spurious failure.
`TestStun_DAGMutatedMidCascade_BindsToASingleObservation` (:488) closes the adjacent read-modify-write
race.

HTTP status mapping is honest end to end: 200 / 207 / 404 / 500 by outcome
(`TestCascadeStatusCode_Mapping`, :743), with `TestHandleStun_RevokeFailure_DoesNotReturn200` (:550)
and `TestHandleStun_TotalFailure_Returns500` (:581) guarding the two that used to lie.

### 2.6 Integration-level findings — defects in the *composition*, not in any card

The five claims above each hold. Four defects appear only when the cards are read together, which is
the governor's own failure mode to catch. An adversarial cross-vendor pass (GPT-5.4, read-only)
surfaced all four; each was then verified independently against the tree before being recorded here.

**F-1. Containment can never report `contained` in a production configuration — and that is correct.**
`k8sFleetClient.RevokeCredentials` is a typed stub returning `ErrEnforcementUnavailable`
(`k8sclient.go:277`), explicitly owned by SLER-P2-1. `classifyOutcome` requires
`credential.Succeeded` for `OutcomeContained` (`cascade.go:198`). So under the default
`--fleet-client=kubernetes`, every containment classifies `partial`, the API answers **207**, and
`StateChangeEvent.Success` is always `false` — until P2-1 lands. The `http.StatusOK` arm is
unreachable.

The adversarial review called this a blocker on the reading that "the only route to a success verdict
is the double the cards exist to retire". The facts are exactly right; **the severity judgement is
not, and the distinction matters.** The credential plane genuinely does not exist yet. `partial` is
the *true* answer, and the stub's own comment names the alternative precisely: returning `nil` would
tell the orchestrator that leases were revoked when no call was made — "the single most dangerous lie
this service can tell, because a held-but-believed-revoked token is indistinguishable from a clean
containment until the agent uses it." The no-op double returns `contained` *because it lies*; that is
why it is argv-gated. A system that correctly refuses to claim full containment while one plane is
unimplemented is P1-5 working, not P1-5 failing.

**It is recorded because it is load-bearing for phase 2's expectations, not because it is a defect.**
See §6, which is corrected accordingly.

**F-2. The fleet-manager containment API has no authentication at all. BLOCKING on phase-2 entry.**
`grep -c 'Authorization|Bearer|requireBearer|authenticate|TokenValidator'` across `main.go`,
`topology.go` and `cascade.go` returns **0**. Seven routes are registered open (`main.go:413-419`),
including `POST /api/v1/fleet/stun/` and `POST /api/v1/fleet/recover`, which patch labels and
annotations on live pods.

P1-4 authenticated the **sentinel**. The **decider** — the service that drives the cascade and writes
the containment labels the sentinel keys off — is unauthenticated. Anything that can reach
`fleet-manager:8082` can contain an arbitrary agent, or release a contained one.

This is not a card failure. It is a **decomposition gap**: SLER-P1-PRE's own errata recorded "7
unauthenticated routes on fleet-manager" at preflight, and no phase-1 card was ever assigned to close
it. P1-4's scope was the sentinel endpoint and P1-4 delivered it.

The attestation half compounds it. `NewContainmentDecision` and `ValidateDecision` have **zero
production call sites** — every caller is a test. `AttestationDigest` and `AttestedRecordDigest`
(`schema.go:110`, `:125`) are never assigned outside tests. `CascadeResult` carries no `decision_id`,
no `idempotency_key` and no `reason`. Today nothing is enforced against a production workload, so the
constitutional blocker has not fired. **The moment SLER-P2-1 lands a real OpenBao revocation, it
does.** See condition C-9.

**F-3. The contract declares an ingress obligation nothing performs.** Frozen contract §3.2 states
that every plane client MUST reject a message whose `schema_version` it does not recognise, using
`assertFrozenSchemaVersion`. That function has **zero production call sites** (two references in
`contract_freeze.go` — its definition and its doc comment — and six in tests). It is also unexported
in `package main`, so no cross-module plane client can call it even if it wanted to; P2-1 through
P4-1 would each reimplement it. A `v1alpha2` message arriving at any of the seven live handlers is
decoded best-effort — which is the precise failure `contract_freeze.go:63-67` warns about, where a
moved field reads as its zero value and a zero value means "not contained". See C-10.

**F-4. `idempotency_key` is frozen into the wire types but unreachable from the orchestrator.**
`BaoRevokeRequest.IdempotencyKey` (`schema.go:221`) and `SpireEvictionRequest.IdempotencyKey`
(`schema.go:248`) are frozen, but `RevokeCredentials(ctx, agentID)` and
`RestoreCredentials(ctx, agentID)` (`cascade.go:156,159`) have neither an idempotency-key parameter
nor a namespace one, and §3 freezes that interface verbatim. `Recover` calls `RestoreCredentials`
unconditionally per target (`cascade.go:426`) with no dedup ledger, so two overlapping recover
cascades — which `enforcement.go:188-193` establishes as an expected concurrent condition — would
mint two credential sets with nothing revoking the first. P2-1/P2-2 cannot make this idempotent
without the contract bump. This **widens C-5**: the authorised MAJOR bump must carry the idempotency
key as well as the namespace. Related: `k8sclient.go:232-235` preserves `stunnedAt` by
read-modify-write with no `resourceVersion` precondition, so the documented forensic-timestamp
idempotency holds only under serialisation (C-11).

---

## 3. Placeholders

```
$ grep -rn 'TODO\|FIXME' d2-signalloom/apps/fleet-manager d2-signalloom/apps/stun-sentinel | wc -l
0
```

Zero. No deferral is required because there is nothing to defer. The broader sweep (`XXX`, `HACK`)
is also empty.

---

## 4. Test evidence on the merged tree

| Command | Result | Note |
| :--- | :--- | :--- |
| `cd d2-signalloom/apps/fleet-manager && go test ./...` | **ok, exit 0** | whole module green |
| `cd d2-signalloom/apps/stun-sentinel && go test ./...` | **exit 1** | `pkg/tc`, `cmd/stun-tcctl` `[setup failed]` — see §4.1 |
| `bash scripts/run-redteam-suite.sh` | exit 0 | **evidentially void — see §4.2** |

### 4.1 The `stun-sentinel` failure is environmental and pre-existing. Attributed, not excused.

`pkg/tc/bpf_embed.go:25` does `//go:embed tc_drop.bpf.o`, and the object is absent, so two packages
fail at setup. Three pieces of evidence establish that this is neither a phase-1 regression nor a
code defect:

1. **Differential.** The same command at the SLER-P0 baseline commit `ee19bbba`, in a scratch
   worktree, produces a byte-identical failure. The condition predates every phase-1 card.
2. **Blast radius.** The only phase-1 commit touching this module is `62376453` (P1-4), and it
   touched `cmd/stun-sentinel/{main,main_test}.go` and `pkg/cgroup/{freezer,freezer_test}.go` only.
   All three packages phase 1 touches — `cmd/stun-sentinel`, `pkg/cgroup`, `pkg/telemetry` — are
   green at both commits.
3. **Root cause, proven rather than inferred.**
   ```
   $ git check-ignore -v d2-signalloom/apps/stun-sentinel/pkg/tc/tc_drop.bpf.o
   /home/andy/.gitignore_global:13:*.o   d2-signalloom/apps/stun-sentinel/pkg/tc/tc_drop.bpf.o
   ```
   The object is documented as committed to the repository. It never was: a bare `*.o` rule in the
   *developer's global* gitignore — not any file in this repo — silently swallowed it at `git add`.
   `bpf/build.sh:29` is what produces it, and it needs clang.

   This is a machine-level condition, not a repository one, and it will recur for any `.o` artefact
   any card in this repo tries to commit. Deciding whether to commit a build artefact, add a
   negating `!` rule, or build it in CI is the principal's call, not a governor's. **Recorded, not
   fixed.** It does not block the freeze: nothing in the phase-1 contract touches `pkg/tc`.

### 4.2 The red-team suite is not evidence. **This is the governor's principal finding.**

`scripts/run-redteam-suite.sh` is 173 lines. Lines 25-170 are a single heredoc that writes
`"scenarios_passed": 15`, `"scenarios_failed": 0`, `"process_escapes": 0`, `"packet_leaks": 0` and
fifteen `"status": "PASS"` string literals into the evidence file. Line 172 then unconditionally
`echo`s `All 15 attack scenarios PASSED with 0 escapes and 0 leaks.`

**There is no assertion anywhere in the file. The script cannot fail.** Its `exit 0` and its
"15/15, 0 escapes" are outputs of a report generator, not results of a test. The only line that
executes anything is `:18`, which runs `test/bench-redteam-stress.sh` — that part does real work and
does measure freeze latency, and its numbers are not in dispute.

Two further facts compound it. The artefact it writes is stamped `"card": "CRKC-P4-1"` and
`"phase": "Phase 4"` — it belongs to a **different proposal**, and running it under SLER re-stamps a
CRKC artefact with a SLER-era timestamp. And running it dirties a tracked file with nothing but a
timestamp change; that churn was reverted rather than committed, because committing it would present
a re-run as new evidence.

The card required this command and required "no new failure relative to the P0 baseline". Both are
formally satisfied and neither means anything, because a script that cannot fail cannot exhibit a new
failure. **The honest statement is: no regression was demonstrated, because this harness is
incapable of demonstrating one.**

This does not undermine the phase-1 freeze — the contract's correctness rests on real Go tests that
do fail when the code is wrong, including P1-5's twelve killed mutations. It does undermine every
later card that was going to cite this suite, and **SLER-P6-1 is scheduled to execute the purple-team
containment-escape suite through exactly this harness.** See condition C-2.

### 4.3 The freeze guard was falsified before being trusted

§4.2 establishes that this repository contains at least one "suite" that cannot fail. That raises the
prior on every other harness cited here, and most of all on the one artefact this entire
certification rests on: the reflection test that enforces the freeze. A green run of that test proves
nothing by itself — it is the same claim shape as "15/15, 0 escapes". So it was mutated and observed
to go red.

**First, it is not a tautology.** `frozenStructs` (`frozen_contract_table_test.go:15`) is a
hand-written literal table, snapshotted from the Go types at the moment of the freeze and thereafter
independent of them. It cannot follow a change, which is the whole point — a guard that derives its
expectation from the type it is freezing compares the type to itself and can never fail.
`TestFrozenDescriptorIsNotVacuous` (`contract_freeze_test.go:175`) is the guard against the guard: an
emptied or truncated table would compare equal to nothing and pass on every change, so that specific
silent-failure mode is checked explicitly rather than assumed.

**Second, it recurses, and it was observed failing.** Two mutations were applied to `schema.go` and
reverted:

| Mutation | Target | Observed result |
| :--- | :--- | :--- |
| `json:"triggered_by"` → `json:"triggered_by_MUTANT"` | a **nested** field (`ContainmentReason`, reached through `ContainmentDecision`) | `--- FAIL: TestFrozenGoShapeMatchesDescriptor` — `FROZEN FIELD RETAGGED: ContainmentReason.TriggeredBy json tag is "triggered_by_MUTANT", frozen contract says "triggered_by"` |
| `json:"outcome"` → `json:"outcome,omitempty"` | a required top-level field (`PlaneResult.Outcome`) | `--- FAIL: TestFrozenGoShapeMatchesDescriptor` |

The nested case matters most: an introspection guard that walks only the top-level struct while
nested payload types change freely is the archetypal false freeze. This one recurses. The
`omitempty` case matters because it changes the wire bytes without changing the Go type — a
divergence a naive field-name comparison would miss.

Both mutations were reverted and the tree re-verified clean (`git status --porcelain` shows only the
untracked review document). **This is the difference between this certificate and the 15/15 it
rejects: the guard has been seen to fail.**

**Two adjacent fail-closed properties were probed at the same time and hold.** `PlaneOutcome`'s Go
zero value is `""`, which `IsValid()` (`schema.go:39`) rejects; and `AggregateOutcome`'s per-result
switch carries an explicit `default:` arm (`schema.go:168`) that folds any unrecognised value —
including the zero value — into `unavailableCount`, never into a success. `OutcomeContained` requires
`containedCount == len(results)` (`:176`), so a partially-populated or zero-valued result can never
aggregate to "contained". An uninitialised struct cannot report a clean containment.

---

## 5. Governor resolutions to the seven escalated open questions

P1-3 §7 escalated seven decisions rather than resolving them unilaterally. That was the right call.
Each is resolved here as a binding constraint on a named card. **OQ-1 is a constitutional matter, not
a preference.**

### C-1 / OQ-1 — Break-glass must not traverse a plane containment can sever. **MANDATED.**

The mission constitution forbids a design where break-glass traverses the control plane containment
may have isolated. The frozen contract *permits* a compliant design — Ed25519 verification is purely
local, so a sentinel holding a cached operator-key registry verifies a resume token with no
control-plane call — but permitting is not mandating, and a phase-4 implementer reading a permissive
contract may reasonably build a verifier that calls out to fetch keys. That design is forbidden, and
it would be discovered after it was built.

**Resolution: the node-local cached operator-key bundle is MANDATORY, not optional.**
SLER-P4-3 must implement resume-token verification with zero network calls on the verification path,
and must carry a test that verifies a token with all egress denied. A verifier that cannot complete
break-glass with the node partitioned from the control plane is a failed implementation of P4-3, not
a degraded one. **Owner: SLER-P4-3.**

### C-2 / red-team harness — **BLOCKING for P6-1, not for phase 1.**

`scripts/run-redteam-suite.sh` is disqualified as acceptance evidence for the remainder of this
mission (§4.2). Before SLER-P6-1 may claim any containment-escape result, the harness must be
rebuilt so that each scenario executes a real attack and asserts a real observation, and must be
falsification-tested: a deliberate mutation that should let an attack succeed must turn the suite
red. Until then, no SLER card may cite a red-team pass rate as evidence of anything.
**Owner: SLER-P6-PRE (rebuild), SLER-P6-1 (consume).**

### C-3 / OQ-2 — Revocation freshness under isolation. **Bounded, not eliminated.**

The cached registry that makes break-glass survive containment (C-1) is the same cache whose TTL is
the window in which a revoked operator key still works. The tension is real and no design removes it;
it must be *chosen*. **Resolution: SLER-P4-3 must state a maximum cache TTL as a published number and
list it in the denial matrix (SLER-P5-2) as a named residual**, alongside the per-plane worst-case
residual latency. A residual that is published is a risk; one that is undocumented is a surprise.
P1-3's correction of the record stands and should be carried forward: the operator signing key is
*not* an SVID, so the SPIFFE-has-no-CRL residual does not apply to it. That residual does still apply
to agent SVIDs, which is phase 2's problem, not phase 4's. **Owner: SLER-P4-3, SLER-P5-2.**

### C-4 / OQ-3 — Operator key distribution. **Confirmed as P4-3's, with the boundary held.**

P1-3 delivered the interface and explicitly did not deliver distribution, bundle signing, rotation,
private-key custody or bootstrap. That split is correct and is upheld unchanged. **Owner: SLER-P4-3.**

### C-5 / OQ-4 — `RevokeCredentials`/`RestoreCredentials` carry no namespace. **AUTHORISED, assigned to P2-1.**

The defect is real and it is a silent one: because the credential methods take only `agentID`, their
degraded-registry entries key on the client's *default* namespace while freeze-plane entries key on
the *target's*. For any agent outside the default namespace, the credential-plane entry is
unreachable by `IsDegraded` for the process lifetime — a plane known to be blind reports available.
That is the same class of lie P1-5 just removed from the cascade, one layer down.

**Resolution: the `FleetClient` signature change is AUTHORISED, and WIDENED per F-4** —
`RevokeCredentials(ctx, namespace, agentID, idempotencyKey)` and the symmetric `RestoreCredentials`.
It is a **MAJOR bump to `sler.signalloom.io/v1`** under §5 of the frozen contract. The idempotency
key is added in the same bump rather than a later one because `BaoRevokeRequest.IdempotencyKey` and
`SpireEvictionRequest.IdempotencyKey` are already frozen into the wire types while being unreachable
from the orchestrator that must populate them — one change closes both halves, and two MAJOR bumps
in one mission is one too many.

It lands in **SLER-P2-1**, not later, and the reasoning is the point of a freeze: P2-1 is the first
card to implement a credential plane, so it is the last moment at which this costs one card instead
of five. Deferring it past phase 2 means every subsequent plane client encodes the two-argument
signature and the bump becomes a mission-wide edit. P2-1 must update `FrozenSchemaVersion`,
`CurrentSchemaVersion`, the `contract_freeze_test.go` descriptor and the JSON Schema in one change,
and record the bump in errata. **Owner: SLER-P2-1.**

### C-6 / OQ-5 — Shared Go contract module vs. container build context. **ACCEPT the JSON Schema.**

A shared `d2-signalloom/pkg/slerwire` module would give downstream cards a compile-time break on
divergence, and it breaks the image build: `Makefile:1710` runs
`docker build -t fleet-manager:local d2-signalloom/apps/fleet-manager`, and that Dockerfile is
`COPY . .` over the app directory, so a `../../pkg/...` replace target does not exist inside the
build context.

**Resolution: accept the JSON Schema as the cross-module contract. Do not widen the build context in
this mission.** The four in-module plane clients (mesh, bao, spire, admission dispatch) live in
`package main` beside the frozen types and get the compile-time property for free; only the two
cross-module peers (`stun-sentinel`, `node-capability-guard`) consume the schema. Widening the build
context is a two-line change with a repository-wide blast radius on every image build, traded against
a compile-time guarantee for two consumers that a schema check already covers. The trade does not
justify it *inside a mission whose deliverable is enforcement*. **Consequence, accepted explicitly:**
those two peers can drift from the frozen types without the compiler noticing, so **SLER-P3-2 and
SLER-P4-1 must each carry a schema-conformance test** against
`docs/signalloom/sler-p1-3-json-schema.json`. **Owner: SLER-P3-2, SLER-P4-1.**

### C-7 / OQ-6 — Registry write-path integrity. **The question that must be answered before P4-3 codes.**

The `key_id` fingerprint check closes registry *mis-indexing*. It does not close an adversary who can
**write** the registry and bind their own key to a victim's `operator_id`. P1-3 asked the sharp
version: *is the registry write path reachable from the same compromise the containment is responding
to?* If it is, the entire attribution chain is decorative — an attacker who has compromised an agent
adds their key, signs their own resume, and the attested record shows a legitimate two-operator release.

**Resolution: the operator key registry is a signed bundle pinned to an offline trust root,
distributed read-only to nodes, with revocation-only in-band mutation.** No in-band path may add a
key. Adding an operator is an out-of-band, offline-signed bundle reissue. This follows from C-1: the
bundle is already node-local and cached for break-glass, so making it read-only at the node costs
nothing and removes the write path entirely. **SLER-P4-3 must state, in its errata, which principal
can reach the registry write path and prove it is disjoint from any agent-reachable identity.**
**Owner: SLER-P4-3.**

### C-8 / OQ-7 — Requester/approver separation. **Self-approval is NOT intended.**

`ResumeToken` records signers but not a requester, so one operator can be both the person requesting
a resume and one of the two approving it — dual control that is one-of-two in practice.

**Resolution: self-approval is not intended.** Add `requested_by` with a `requester ∉ signers`
rule. This is a **MINOR bump** under §5 (`sler.signalloom.io/v1alpha2`) — additive, existing consumers
keep working — and should be folded into the MAJOR bump C-5 already authorises for P2-1 if the
timing allows, to avoid two version changes.

The related question — `required_signatures` counts *distinct* operators but says nothing about
*which*, so as frozen any two valid operators can resume any agent in any namespace — is
**deferred to SLER-P4-3 with a named default**: absent a per-namespace approver set, P4-3 ships the
any-two-operators behaviour and records it in the denial matrix as a stated authorisation-model
limitation. It is not silently inherited. **Owner: SLER-P2-1 (`requested_by`), SLER-P4-3 (approver sets).**

### C-9 / F-2 — Authenticate the decider and wire the attestation path. **BLOCKING on phase-2 entry.**

**No phase-1 card owned this, and no phase-2 card owns it either.** SLER-P1-PRE found the seven open
routes at preflight; the decomposition never assigned them. This is the one place where the plan, not
the code, is deficient, and a governor who certifies phase 1 without naming it hands phase 2 a system
whose enforcement API is open to anything on the cluster network.

**Resolution, in two parts, both required before any real enforcement plane is enabled:**

1. **Authentication on `fleet-manager`.** Every `/api/v1/fleet/*` mutating route — `stun`, `recover`,
   `deploy`, `reset` — must require a caller credential, and the credential must carry a requester
   identity, not merely admit the call. `/health` may remain open.
2. **The attestation path must be wired.** `NewContainmentDecision` and `ValidateDecision` must have
   production call sites; `CascadeResult` must carry `decision_id` and `reason`; no containment may
   be applied without a `ContainmentDecision` recording who asked and on what evidence. The
   cryptographic signing is SLER-P5-1's Witness work and is not required here — what is required is
   that the decision record exists and is bound to the action, so P5-1 has something to attest.

**This needs a card that does not exist.** The governor's recommendation to the principal is a new
**SLER-P2-0**, sequenced before P2-1, sized M. Phase 2 may be started on P2-PRE in parallel, but
**SLER-P2-1 must not merge until C-9 lands**, because P2-1 is the first card to make a real
credential-revocation call and therefore the first at which the constitutional blocker — enforcement
of a production workload without an attested record of the deciding evidence — actually fires.
**Owner: new card SLER-P2-0 (recommended); principal decision required on its creation.**

### C-10 / F-3 — The ingress version check must be performed, not merely declared. **Assigned.**

`assertFrozenSchemaVersion` has no production caller and is unexported, so the §3.2 MUST is prose
only and no cross-module client can satisfy it. **Resolution: export it as `AssertFrozenSchemaVersion`
and call it at the top of every handler that decodes a versioned message**, in the same change as
C-5's bump. The two cross-module peers implement the equivalent check against the JSON Schema, which
is the obligation C-6 already places on them. A declared-but-unperformed obligation is worse than no
obligation, because downstream cards read the contract and assume it is enforced.
**Owner: SLER-P2-1 (in-module), SLER-P3-2 and SLER-P4-1 (cross-module).**

### C-11 / F-4 — Concurrency preconditions on pod mutation. **Assigned.**

`k8sclient.go:232-235` preserves `stunnedAt` across a retry by read-modify-write with no
`resourceVersion` precondition, and `enforcement.go:188-193` establishes concurrent stun/recover on
one target as an expected operating condition. Two concurrent stuns both observing an empty
`stunnedAt` both stamp, and scheduler order decides the forensic timeline.

This does **not** trip the idempotency hard blocker — containment itself is idempotent
(`TestStun_RetryOnAlreadyStunnedTarget_ReportsNoSpuriousFailure`), and the affected value is a
timestamp, not the contained state. But a forensic record whose first-containment time is decided by
a race is a weak forensic record, and SLER-P5-1 is going to attest it. **Resolution: the
`stunnedAt`-preserving patch must carry a `resourceVersion` precondition and retry on conflict.**
**Owner: SLER-P2-1** (same file, same change as C-5).

### C-12 / F-1 — `contained` is an unexercised branch. **Golden round-trip fixture required.**

Because `RevokeCredentials` is a stub, `OutcomeContained` has never been produced by a real producer
nor parsed from one on the wire, and it is being frozen in that state. Treating F-1 as "correct
behaviour, no action" would make the unexercised branch invisible to whoever certifies P2-1.

**Resolution: a golden round-trip fixture covering all four `PlaneOutcome` values** —
marshal/unmarshal each across every frozen type that carries one — lands with C-5's bump in P2-1,
independent of whether a real producer can yet emit them. Additionally, **P2-1 must exercise
`contained` end-to-end across the wire before it certifies**, since P2-1 is the card that makes it
reachable. **Owner: SLER-P2-1.**

### C-13 — Honest statement of what "BLOCKING" means here

The advisor pass raised this and it is right: a blocking condition whose carrier does not exist is
prose, and prose is the layer no gate reads. **There is no CI check that will stop SLER-P2-1 merging
with C-9 open.** The enforcement mechanism for C-9 is this document plus the P2-GOV governor reading
it. That is a stated weakness, not an implied guarantee.

**Recommended to the principal: create SLER-P2-0 ("Authenticate the fleet-manager containment API and
wire the ContainmentDecision attestation path"), sized M, sequenced before SLER-P2-1.** This governor
has deliberately not created it: adding a card to a later phase is a board mutation beyond this
card's remit, and inventing a phase-2 decomposition unilaterally is the same failure P1-3 avoided by
escalating its seven questions instead of resolving them. **Principal decision required.**

**Operational question, answered rather than left as governance framing:** the seven open routes are
not a live production exposure today. `fleet-manager` has no real enforcement plane wired
(`RevokeCredentials`/`RestoreCredentials` are stubs), nothing outside the demo topology is contained
by it, and no phase-1 card deployed it to a customer environment — enforcing against live customer
infrastructure is explicitly out of scope for this whole mission. The exposure becomes real at P2-1,
which is precisely where C-9 places the gate.

### C-14 — A policy denial blocks the Recover cascade. **Break-glass adjacent; resolve before P2-1.**

Routed to this governor by P1-5's errata and not addressed by any other condition.
`d2-agent-trust/policies/agent-identity-state-protection.yaml:35-42` permits mutating
`signalloom.ai/state` away from `stunned` only for `swarm-governor`, `kubernetes-admin`,
`kind-osramp`, `system:admin*` and `system:masters`.
`system:serviceaccount:fe-signalloom:fleet-manager` is **not** among them. So `SetPodState(stunned)`
succeeds and `SetPodState(active)` is denied at admission: **containment works and release does not.**

That is the same shape as C-1 one layer out — an autonomous containment whose reversal path is
blocked by a control the containment side does not need. It is worse than C-1 in one respect and
better in another: worse because it is live today rather than a permissive-contract risk, better
because P1-5 guarantees the denial *surfaces* as `ErrEnforcementDenied` rather than being swallowed,
so an operator sees a 207 and a reason rather than a silent no-op.

**Important qualification, which P1-5 stated and this governor repeats rather than upgrading:** this
is derived by *reading the policy*, not observed against a live cluster. The fake clientset does not
run admission; what is tested is the mapping from an injected `NewForbidden` to
`ErrEnforcementDenied`, which proves nothing about whether the policy is deployed. **The first action
is to observe it, not to fix it.**

**Resolution: SLER-P2-PRE must confirm against a live cluster whether the denial actually fires.** If
it does, the choice is (a) add `fleet-manager` to the authorised-mutator list — a security-boundary
change and therefore a principal decision, not a governor one — or (b) route recovery through
`swarm-governor`. **Option (b) is this governor's recommendation**, because it keeps the
containment identity and the release identity distinct, which is the same separation-of-duty
principle C-8 applies to resume tokens: the thing that can stop an agent should not be the thing that
can release it. **Owner: SLER-P2-PRE (observe), principal (decide (a) vs (b)).**

### C-15 — `CascadeResult.Planes` is empty; the Published Denial Matrix is unsatisfied.

Also routed by P1-5's errata. P1-5 fixed per-*target* honesty, not per-*plane* reporting, so
`CascadeResult.Planes` carries nothing and the constitution's "every plane reports two benchmarked
numbers — Guaranteed Denial Latency (p99) and Worst-Case Residual under partition" has no data
structure populating it.

This is correctly deferred — there are no planes yet to report. **Resolution: each phase-2/3/4 card
that lands a plane must populate `CascadeResult.Planes` for its own plane as part of its definition
of done, rather than leaving it to SLER-P5-2 to retrofit across five planes at once.** P5-2 benchmarks
and publishes; it does not implement the reporting. **Owner: SLER-P2-1, P2-2, P3-1, P3-2, P4-1
(populate); SLER-P5-2 (benchmark and publish).**

---

## 6. What phase 2 may now assume exists

Phase 2 may build against all of the following as settled:

1. **A real `FleetClient`.** A client-go implementation talking to a live API server, selected by
   default. The no-op double is reachable only from the exact argv literal `--fleet-client=noop-test-only`
   and never from the environment. Every enforcement call either acts or returns
   `ErrEnforcementUnavailable` within 15 seconds; none returns a fabricated success and none hangs.
2. **A dispatch schema that can tell the truth.** `PlaneOutcome` ∈ {`contained`, `partial`,
   `unavailable`, `not_found`}, carried on `PlaneResult`, `StepResult`, `CascadeResult` and
   `StateChangeEvent`. Plane clients report into this vocabulary; they do not invent their own.
3. **A frozen wire contract at `sler.signalloom.io/v1alpha1`**, enforced by a reflection test that
   fails by field name, with a written bump procedure. Additive change is a MINOR bump the governor
   approves; rename/removal/retype/retag is a MAJOR bump requiring every plane client to move together.
4. **An honest cascade.** Failure at the state read, the revoke, or the set-state is recorded, not
   swallowed. HTTP answers 200 / 207 / 404 / 500 by actual outcome. Re-running a containment against
   an already-contained target is safe.
   **Read this one carefully (F-1):** because the credential plane is a typed stub until P2-1, the
   honest answer to *every* production containment today is `partial` / **HTTP 207**, and
   `StateChangeEvent.Success` is always `false`. The 200 / `contained` arm is currently unreachable
   with the real client. This is the cascade telling the truth, not failing — but any phase-2 test
   that asserts 200 on a successful stun will fail, and any dashboard that reads `success` as a
   boolean health signal will show red. Assert on `PlaneOutcome`, never on `Success`, and expect
   `contained` to become reachable only when P2-1 makes `RevokeCredentials` real.
5. **An authenticated stun endpoint** whose credential check lives in `Freezer.Freeze` itself, is
   fail-closed when unconfigured, and uses distinct credentials for freeze and resume.

Phase 2 may **not** assume:

- **Governance-gated resume is live.** The Ed25519 library exists and is correct; nothing calls it.
  Live wiring and mandatory credential rotation are SLER-P4-3.
- **Any credential-revocation, mesh, admission or attestation plane exists.** All are phase 2+ and
  none has an implementation today.
- **Any red-team or purple-team result is evidence.** See C-2.
- **The `FleetClient` credential-method signature is final.** C-5 changes it in P2-1.
- **The containment API is authenticated, or that any containment carries an attested decision
  record.** Neither is true. See C-9 — this gates P2-1's merge.
- **The declared `schema_version` ingress check is performed anywhere.** It is declared, not
  implemented. See C-10.

---

## 7. Hard-blocker disposition

| Constitutional blocker | Status |
| :--- | :--- |
| Enforcement primitive cannot do what the proposal assumes (Landlock tightening; SPIFFE revocation) | **Not triggered.** P1-3 §7 OQ-2 corrects the record: the operator signing key is a registry entry, not an SVID, and is revoked on removal. The SPIFFE TTL residual is real but applies to agent SVIDs in phase 2, where it is named rather than assumed away. |
| Autonomous containment with no break-glass, or break-glass through the contained plane | **Was at risk; closed by C-1.** The contract permitted but did not mandate the compliant design. Now mandated on P4-3 with an egress-denied test. |
| Containment action not idempotent under retry | **Not triggered.** `TestStun_RetryOnAlreadyStunnedTarget_ReportsNoSpuriousFailure`; frozen contract §4.7. |
| Enforcement of a production workload without an attested record | **Not triggered in phase 1, and one card away from triggering.** No plane enforces anything against a production workload yet. But the decider is unauthenticated and `NewContainmentDecision`/`ValidateDecision` have zero production call sites (F-2), so the blocker fires the moment SLER-P2-1 makes a real revocation call. **C-9 gates P2-1's merge on closing both halves.** |
| Result type that cannot represent partial or failed containment | **Not triggered.** Four-valued `PlaneOutcome`. |

---

## 8. Verdict

**The SLER phase-1 decision freeze is CERTIFIED at `468e3fc60334774c594622fe08dc4d580f4dc38b`**,
subject to conditions C-1 through C-15. **C-9 is blocking: SLER-P2-1 may not merge until it is
closed**, and closing it requires a card that does not yet exist. The other fourteen are assigned to
named existing cards.

Phase 2 may **start** — P2-PRE is unblocked and the wire contract it consumes is sound. Phase 2 may
not **land its first enforcement plane** until C-9 is closed.

The quality of the five cards is high, and an adversarial cross-vendor pass agrees: each is
internally coherent, each anticipated its own most likely failure mode and shipped the test that
would catch it, and P1-3 escalated seven decisions rather than quietly resolving them. The
P1-1/P1-5 collision — the single most probable way this phase could have failed — was caught in the
merge and is now guarded by a standing test.

Three things phase 1 did not surface about itself, all found at integration rather than inside any
card, which is the governor's own job and not a criticism of the five:

1. **§4.2 — the acceptance harness is a report generator.** `scripts/run-redteam-suite.sh` has no
   assertions; its "15/15, 0 escapes" is a heredoc. Finding it now costs a rebuild of one script.
   Finding it at P6-1 would have cost the mission's central evidentiary claim.
2. **F-2 — the decider is unauthenticated and nothing records why a containment happened.** P1-PRE
   flagged the open routes at preflight and the decomposition never assigned them to anyone. A gap
   that is visible in a preflight inventory and absent from every card is the kind that survives to
   production, because each card is correct and no card is responsible.
3. **F-1 — the system can never report `contained` today, and that is the correct answer.** Worth
   stating plainly because the next person to see 207-forever will file it as a bug, and it is the
   opposite: it is the fabrication P1-5 removed, staying removed.

**Refusal considered and declined.** The adversarial review recommended failing the gate on F-1, F-2
and F-3. F-1 is correct behaviour misread as a defect. F-2 and F-3 are real, and both are conditions
on *enforcement*, not on the *contract* — freezing the wire format is what lets C-5, C-8 and C-10
land as a single disciplined bump in P2-1 instead of five divergent ones. Refusing the freeze would
delay the fix for the defects that motivated the refusal.

---

*SLER-P1-GOV. Reviewed against `468e3fc60334774c594622fe08dc4d580f4dc38b` on 2026-09-15T01:50:38Z.*
