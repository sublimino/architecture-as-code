# SLER-P2-GOV — Phase 2 Governor Review and Completion Report

> **Card:** `SLER-P2-GOV` — Merge credential revocation and verify authorization rejection
> **Integration branch:** `integration/sler-v0.1.0`
> **Reviewed at:** `4d691f747b72e6812c4a4195efe107771637ca1d`
> **Consumed:** `ebb299e88b298defbe9ace22de113515b025e65d` (SLER-P2-1, OpenBao) · `ff6e7fdea9e4a9d7f01a37b77ec335b25da230a2` (SLER-P2-2, SPIRE)
> **Verdict:** **PASS WITH EXCEPTIONS** — the exceptions carry equal weight to the word PASS and are not footnotes.
>
> | | |
> | :--- | :--- |
> | **Original phase-2 criterion** — *"zero residual token leakage"* | **NOT MET**, and not achievable by construction on either plane |
> | **Substituted criterion** — *active revocation with a published, provenance-labelled residual* | **MET** |
> | **Exception 1** — `bao` guaranteed-denial latency | `mock-derived`. Owner: SLER-P5-2 |
> | **Exception 2** — `spire` guaranteed-denial latency | `unsourced` — **no producing artefact exists**. Prior `< 2.0 ms` **withdrawn**. Owner: SLER-P5-2 |
> | **Exception 3** — published residuals | a **floor**, not a bound. Relying-party validation caching extends real exposure past TTL |
>
> A governor may certify PASS on defects it repaired. It may not certify PASS on criteria it discovered were never measured, and it may not substitute a criterion and then grade against the substitution without showing the substitution. Both numbers in the guaranteed-denial column are unmeasured — that is two of the four headline figures, not one — and the substitution is recorded above so a reader inherits the reasoning rather than a laundered number.

---

## 1. The headline: what this review is for

The card asked whether two revocation clients report *measured* residual-exposure windows. The audit found three things, in ascending order of severity.

1. The published latency figures are not measurements.
2. The SPIRE denial-matrix row has **no producing artefact anywhere in the tree**.
3. **OpenBao revocation was dead code on the production containment path**, and containment was reporting success without it.

The third is a live security defect, not a documentation problem. It is repaired in this card and the repair is falsified, not merely exercised.

---

## 2. Finding G-1 (critical) — OpenBao revocation never executed in production

`k8sclient.go:297` implemented `RevokeCredentials` as an if/else-if chain:

```go
if c.spireClient != nil { … ; return nil }   // unconditional return
if c.baoClient   != nil { … }                // unreachable
```

`newK8sFleetClient` sets `baoClient` unconditionally (`k8sclient.go:53`); `newK8sFleetClientWithSpire` then adds `spireClient`; production wiring is `fleetclient_select.go:282`. Both fields are therefore non-nil in production, the SPIRE branch won, and the OpenBao plane never ran — while the function returned `nil`.

Downstream, `cascade.go` reads that `nil` as `Credential.Succeeded = true` and `classifyOutcome` returns `OutcomeContained`. **The Phase-1 honesty machinery was intact and was faithfully certifying half-revocations as fully contained.** The exact "believable wrong answer to an operator" that SLER-P1-5 existed to remove, resurrected one layer below the fix.

### Why neither card could see it

`git blame` attributes the OpenBao block to the **merge commit `ff6e7fdea9e4a9d7f01a37b77ec335b25da230a2`**, not to either card. SLER-P2-2 branched from `96a3abe1` — before SLER-P2-1 merged — so it rewrote a function body that still read `"not implemented (SLER-P2-1)"`. The merge was resolved by concatenation: both hunks retained, neither's control flow reconciled. It compiled, `go vet` passed, and both suites stayed green.

**A correction to the obvious diagnosis.** It is tempting to say "neither card configured the other's client." That is false, and the false version would produce the wrong fix. Three tests at `spire_client_test.go:737 / 774 / 797` already construct via `newK8sFleetClientWithSpire`, which *does* set both. They stayed blind because each card's **assertion set enumerates only its own plane**. A shared fixture would not have caught this; only a shared assertion would. This is what the new test file does.

### Repair

`k8sFleetClient.RevokeCredentialsPlanes(ctx, agentID) ([]PlaneResult, error)` fans out to every configured plane **concurrently** and returns one `PlaneResult` per plane. `RevokeCredentials(ctx, agentID) error` is retained as an aggregating wrapper, so the `FleetClient` interface in `cascade.go` — a declared shared-file collision risk — is **unchanged and untouched**. `AggregateCredentialOutcome` makes `OutcomePartial` a first-class answer.

### Falsification (this is the part that matters)

A combined test that passes against the broken code proves nothing. The control flow was reverted in place, the test observed failing, and the file restored byte-exactly:

```
mutation applied
--- FAIL: TestCombinedRevocation_BothPlanesFireOnOneDecision (0.00s)
    combined_credential_plane_test.go:181: ISC-24: OpenBao revoke was NEVER called with
    both planes configured — this is the silent fail-open SLER-P2-GOV exists to close
MUTATED_EXIT=1
RESTORED_BYTE_EXACT=YES
ok  github.com/.../fleet-manager  0.009s
```

### Corroborating evidence the defect was live

Repairing the fan-out turned `TestK8sFleetClient_RevokeCredentials_WithSpireClient` **red**, because the bao plane — previously unreachable — now genuinely attempts `openbao.inf-bao.svc.cluster.local:8200` and fails in a unit-test environment. That test's green status was an artefact of the dead branch. Its subject is the SPIRE plane, so it now asserts the SPIRE plane's own `PlaneResult` rather than an aggregate that was silently speaking for two planes while exercising one.

---

## 3. Finding G-2 (critical) — typed-nil `SpireClient` turns "fail closed" into a panic

`NewGRPCSpireClient` returns the concrete `*grpcSpireClient`; on connect failure it returns `(nil, err)`. `fleetclient_select.go:266` logged a warning — *"will fail closed on spire operations"* — and proceeded to assign that nil pointer into a `SpireClient` interface.

That produces a **typed nil**: an interface value whose type word is set and whose data word is nil. `c.spireClient != nil` is therefore **true when SPIRE is unreachable**, so the SPIRE path is taken and `EvictAgent` dereferences a nil receiver at `spire_client.go:398`. The documented behaviour was fail-closed; the actual behaviour was a panic in the enforcer at the exact moment containment was requested.

**Repaired in two places, and the second is the one that matters.** Staging the assignment through an explicitly nil interface variable at `fleetclient_select.go` stops the selector *producing* a typed nil. But a guard at the construction site alone **inherits the very blind spot that caused the defect** — any other construction path reintroduces it.

This was not a hypothetical. `TestCombinedRevocation_TypedNilSpireClientDoesNotPanic` injects `(*grpcSpireClient)(nil)` boxed into the interface and, against the construction-site fix alone, **panicked**:

```
panic: runtime error: invalid memory address or nil pointer dereference
  (*grpcSpireClient).EvictAgent(0x0, …) spire_client.go:406
```

Nil-receiver guards were therefore added at the **dereference** sites — `EvictAgent` and `Health` — where they cannot be routed around. `Health` matters independently: the readiness probe must report unavailable, not crash the process answering it.

---

## 4. Finding G-3 (major) — provenance of every published figure

### 4.1 OpenBao — mock-derived

`sler-p2-1-proof.md:22` states the distribution was *"Executed against active HTTP OpenBao endpoint measuring complete round-trip payload serialization, network transmission, server processing, and deserialization."*

The producing test is `TestOpenBaoClient_LatencyDistribution_Benchmark10x` at `openbao_client_test.go:558`. Its server is `httptest.NewServer`, and its handler's first statement is `time.Sleep(10 * time.Millisecond)` at line 561.

**The 10.29 ms figure is the sleep constant plus loopback jitter.** The min–max spread of 10.19–10.38 ms is the signature. The derived claim — *"reducing the attacker's window of opportunity by 99.996%"* — is arithmetic on a hand-chosen constant.

The only assertion guarding it is `p99 > 2000ms` against a 10 ms sleep: structurally incapable of failing.

### 4.2 SPIRE — unsourced, which is worse than mock-derived

`sler-p2-2-proof.md:111` states the row was *"Measured against the live SPIRE server deployment (`inf-bao/spire-server`) in the Kind cluster."*

Verified independently for this review:

```
$ rg -n -i 'p50|p90|p99|percentile|0\.02|1\.23|77\.56|225\.57' spire_client_test.go
(no matches)
```

**`spire_client_test.go` contains no percentile computation and none of the published numbers.** The in-process row (0.02 / 0.04 / 0.08 / 1.23 ms) has no producer; per the proof's own line 194, the 1.23 ms is the *total elapsed for 50 concurrent goroutines against `mockEntryServer`*, republished as the **p99 of the live control plane** and carried into the denial matrix as `< 2.0 ms`. The kubectl-exec row (77.56 / 90.11 / 142.84 / 225.57 ms) exists **only in the document**; no artefact in the tree produces it.

The gRPC transport under test is `startTestGRPCServer` → `mockEntryServer` over `net.Listen("tcp","127.0.0.1:0")` (`spire_client_test.go:141-150`).

### 4.3 SPIRE residual — upstream default, not measurement

`TestSpireClient_SVIDRejectionWindow_EmpiricalSimulation` (`spire_client_test.go:653`) declares `jwtTTL := 300 * time.Second`, builds a struct, and asserts `at.After(tok.ExpiresAt)`. **It tests Go's `time` package against its own constant.** "Empirical simulation" is a contradiction in terms; the 300 s / 3600 s figures are SPIRE's documented upstream defaults.

They *do* apply — `rg 'default_svid_ttl' d2-signalloom/` returns zero configuration matches — but the correct label is `upstream-default`, not `measured`.

This is not a failure of diligence so much as a category error. **A 3600-second window is not observable inside a unit test.** The right discipline is not to measure it harder but to label its provenance and cite the configuration that sets it.

---

## 5. The published denial matrix — for SLER-P5-2 to consume

Every figure carries its instrument. A number without provenance is a rumour.

| Plane | Guaranteed-denial latency | Provenance | Worst-case residual | Provenance | Config citation |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`bao`** | **≈10.3 ms** (p99 10.38 ms, n=10) | **`mock-derived`** — `httptest` + `Sleep(10ms)`, `openbao_client_test.go:558`. A **lower bound**, not a fleet figure. | **300 000 ms (5 min)** | **`config-derived`** | `openbao-agent-generic-role.yaml:68-69` — `token_ttl: 5m`, `token_max_ttl: 5m` |
| **`spire`** | **UNMEASURED** | **`unsourced`** — no producing artefact exists. The prior `< 2.0 ms` claim is **withdrawn** by this review. | **3 600 000 ms (1 h)** binding; 300 000 ms (5 min) for JWT-SVID | **`upstream-default`** | no `default_svid_ttl` in-repo (0 matches); `ca_ttl` 24 h rotating at 20 h per `spire-openbao-sync-cronjob.yaml:3` |

**Guidance to P5-2:** the `spire` guaranteed-denial cell must be *benchmarked*, not inherited. It is the one number this phase owes you and did not produce. Both residual cells are stable configuration reads and need no re-measurement — but they must be re-derived if `token_ttl` or an SVID TTL is ever set.

**Mission `outOfScope` compliance:** no figure above is presented as a fleet-size measurement. Two are labelled as not measured at all.

---

## 6. The metric restatement — required, and the point of the exercise

Phase 2's stated metric was **"zero residual token leakage."** It is **NOT MET**, and it is **not achievable by construction** on either plane:

- **OpenBao** — revoking a lease deletes it server-side and invalidates future operations on it. It does **not** invalidate a credential already minted from that lease: a database password lives in the database's own auth table, a cached JWT lives to its `exp`. A latency measured at the lease API therefore *understates* real exposure and must never be certified as the exposure window.
- **SPIRE** — SPIFFE has no CRL and no OCSP. Deleting a registration entry stops **re-issuance**; it does not invalidate an SVID already in the workload's memory. **Nothing short of TTL expiry removes a trusted SVID.**

Revocation and expiry are two different clocks, and the security claim belongs to the slower one. "Zero residual" is not an ambitious target phase 2 narrowly missed; it is a claim the first red team to read the SPIFFE specification will falsify.

**Certified language for the KPI table:**

> Active credential revocation across the OpenBao and SPIRE planes, with a published worst-case residual-exposure window of **5 minutes (bao, config-derived)** and **1 hour (spire, upstream X.509-SVID default)**. Residuals are bounded by credential TTL, not by revocation latency, and are reported on every `PlaneResult` and every attested event.

This is the stronger claim. It is auditable, and it survives contact with an adversary.

**Highest-leverage reduction available:** setting `default_x509_svid_ttl` in-repo would cut the binding `spire` residual directly. It is currently unset, so SPIRE's 1-hour default applies by omission rather than by decision. Recommended for P4/P5 consideration — out of scope here.

---

## 7. Structured-logging compatibility for SLER-P5-1

**Was incompatible.** P2-1 hand-marshalled JSON discriminated by an `event` key and carrying `worst_case_residual_ms`. P2-2 emitted `slog` records whose only discriminator was slog's own `msg`, carrying **no residual field at all**. P5-1 ingests both into one Witness-attested pipeline and was not scoped to reconcile two shapes — and that shim would have had to be rewritten for every plane P3 and P4 add.

**Now compatible.** `attestation_event_contract.go` declares the shared vocabulary; both planes emit `event`, `outcome`, `latency_ms`, `worst_case_residual_ms`, and the SPIRE eviction record additionally carries `agent_id` and `idempotency_key`.

`TestAttestationEventShape_BothPlanesShareRequiredKeys` checks both planes by iterating the **same** `SharedAttestationEventKeys` slice. That construction is deliberate: a future card that drops a key from one plane fails that plane's assertion, rather than the test quietly checking a shorter list for it — which is how the shapes diverged in the first place.

**One deliberate exclusion, documented for P5-1:** `error` is tagged `json:"error,omitempty"` on the bao side, so on a successful containment the key is **absent** from the marshalled record. P5-1 must read an absent `error` as "no error", not as a malformed record.

---

## 8. Idempotency — the asymmetry two cards could not see between them

Both cards implemented idempotency independently against the same SLER-P1-2 schema. SPIRE maps `codes.NotFound` → `OutcomeContained`; OpenBao maps `404`/`400 invalid lease` → contained. Both are correct in isolation.

The divergence was in the **key**. `k8sclient.go:328` passed `""` to the bao plane while handing SPIRE a real `contain-<agent>-<nanos>` key — so a retry looked like a replay on one plane and a fresh decision on the other. A single decision-scoped key is now generated once and threaded to both planes.

Proved by **replaying the call**, never by reading the retry code: `TestCombinedRevocation_IdempotentUnderRetry` issues the same decision twice and asserts both planes report contained on both attempts, and that the doubles genuinely saw two calls.

---

## 9. Deadline budget and circuit-breaker interaction

Each card verified its own deadline handling in isolation. A decision containing a slow OpenBao call **and** a slow SPIRE call could serialise their timeouts — 400 ms + 400 ms against a 700 ms decision budget — and each isolated test would still pass.

`TestCombinedRevocation_SharedDeadlineBudgetIsNotSerialised` asserts a **measured wall-clock bound** that a serialised implementation cannot satisfy. `TestCombinedRevocation_CallerDeadlineDominatesClientDefaults` proves a 200 ms decision deadline beats the SPIRE client's own 10 s default.

`TestCombinedRevocation_TrippedBreakerFailsFastAndDoesNotBlockSibling` covers the interaction neither card could test: a tripped OpenBao breaker reports `unavailable` in under 500 ms rather than waiting out the deadline, publishes `circuit_breaker_state: open` **on the `PlaneResult`** (not merely in a log), and leaves the SPIRE plane free to report `contained` — aggregating to `partial`.

---

## 10. Evidence

| Check | Result |
| :--- | :--- |
| `go test ./...` (fleet-manager) | `ok … 2.027s` |
| `go test -race ./...` | green, no data races |
| `go vet ./...` | clean |
| `bash scripts/run-redteam-suite.sh` | **15/15 scenarios PASSED, 0 escapes, 0 leaks** |
| `make demo-signalloom-api-test TIER=contract` | **56 passed** |
| ISC-29 mutation falsification | test **FAILED** against pre-repair flow, passes after; file restored byte-exact |
| `rg 'default_svid_ttl' d2-signalloom/` | 0 configuration matches |

---

## 11. Open items handed forward

1. **Both guaranteed-denial figures are unbenchmarked.** SLER-P5-2 must produce both. Do not inherit `< 2.0 ms` (no producer) and do not inherit `10.3 ms` (a sleep constant).

2. **The published residuals are a FLOOR, not a bound.** Both figures are credential TTLs. They assume a relying party re-validates at expiry. This repository has already been bitten by exactly the opposite — OpenBao's `jwks_url` caches and only refetches on an unknown `kid`. A relying party caching JWKS or validation results extends real exposure **past** the TTL. Either measure the relying-party cache behaviour or state the residual as a floor everywhere it is published. This review states it as a floor.

3. **Concurrent fan-out cannot prevent re-mint, and that is a design property, not a bug to test around.** If the SPIRE identity is what mints the OpenBao credential, then during the fan-out window a subject holding a still-live SVID can mint a *fresh* bao token, and the bao revocation races it. Ordering would be a correctness requirement that a concurrent fan-out structurally cannot provide — but serialising costs the shared-deadline property this card was asked to prove. The trade is real and it is above this card's pay grade. **Proposed probe for SLER-P4-GOV or SLER-P6-1:** attempt a mint during the fan-out window and assert it fails. If it succeeds, the containment ordering needs revisiting regardless of how green the deadline tests are.
4. **`RestoreCredentials` is still a stub** returning `ErrEnforcementUnavailable` and citing SLER-P2-2. Stun is now partially real while un-stun has never been implemented — relevant to SLER-P4-3's governance-gated resume.
5. **Process recommendation (root-cause class, not instance).** Four prior instances of this exact shape are already in this project's memory — emitter/consumer halves green and blind in the same shape; a stub proving only the caller's half; a filter applied by one caller of four. The card is the unit of work, of verification, **and of evidence**, so anything existing only *between* cards has no owner. Two interventions, in priority order:
   - **A board rule:** any card adding a branch to a shared dispatch function ships a mutation proof that deletes the *sibling* branch and observes a test go red. The mechanism already exists — 27 mutation-proof scripts — with no cross-card instance.
   - **A provenance token** on every `ms`/`µs` figure in a proof document, citing an on-disk `file:line`, checked by a guard that fails when the token resolves into a `*_test.go` beneath a sentence containing *live*, *production*, or *cluster*. The provenance already exists in these two documents — both *tables* name the test file honestly; only the *ledes* claimed otherwise. This is a linting job over existing data, not a new measurement programme.

---

*SLER-P2-GOV. Reviewed at `4d691f747b72e6812c4a4195efe107771637ca1d` on `integration/sler-v0.1.0`.*
