# Framework Pack Conformance Contract

Every CEL check in a framework pack is proven by fixtures. A check is
"correct" when a fixture that should fail it fails, a fixture that should
pass it passes, and the test that says so is shown to bite by mutation.

The harness is `d2-signalloom/apps/policy-engine/frameworks_conformance_test.go`.
Run it with:

```bash
cd d2-signalloom/apps/policy-engine && go test -run 'TestConformance' -v .
```

## Input bindings

The policy engine evaluates every check against three CEL variables. A check
may read any of them. Fixtures supply them under `input`.

| Variable  | Shape | Source in production |
|-----------|-------|----------------------|
| `object`  | A Kubernetes **Pod-shaped** object: `{"apiVersion","kind","metadata":{...},"spec":{...}}`. Checks read `object.spec.*` and `object.metadata.*`. A caller may send a workload controller instead — **the engine normalises it itself** (see below) and copies the workload's namespace into `object.metadata.namespace`, because a pod template carries none of its own. Controller-level facts (`replicas`, update strategy, PDBs) are **not** in this object: a check that needs them is not evaluable from a pod and is marked `status: placeholder` in its pack (it reports `not_evaluated`). | The workload's pod spec. Scan field `object` (alias `manifest`). An empty `object` (`{}`) is treated as absent, so it never masks a non-empty `manifest`. |
| `agent`   | The **agent context document**: governance facts about the AI agent the workload runs. Field paths are owned by the pack that reads them and documented in that pack's `AGENT-CONTEXT.md`. | Assembled by fe-signalloom from the agent registry. Scan field `agent`. |
| `request` | A runtime request context (tool call, peer identity, network). | Scan field `request`. |

`manifest` is bound to the same value as `object` for backward compatibility.
Unbound variables are bound to an empty map, never left undeclared.

### Input shape: a non-pod object is `error`, never `pass`

Pack checks read containers as
`(has(object.spec.containers) ? object.spec.containers : []) + initContainers + ephemeralContainers`,
so an **absent** container list is the empty list and `.all()` over it is
**vacuously true**. On a workload controller the containers live at
`spec.template.spec`, so an unguarded engine would report `pass` on a hostile
Deployment. Measured before the guard landed: a maximally hostile
`kind: Deployment` scored 14 of 17 CIS checks `pass`.

The engine therefore guards the shape of `object` at the scan boundary
(`d2-signalloom/apps/policy-engine/workload_shape.go`), in this order:

1. An **absent or empty** object stays absent. A scan with no object at all
   (an agent-only AIGF scan) is unaffected.
2. A supported **workload controller kind** is unwrapped by the engine to its
   pod template: `Deployment`, `StatefulSet`, `DaemonSet`, `ReplicaSet`,
   `ReplicationController`, `Job` (at `spec.template`) and `CronJob` (at
   `spec.jobTemplate.spec.template`). `apiVersion`/`kind` are synthesised as
   `v1`/`Pod` and the workload's `metadata.namespace` is copied into the pod's
   metadata. A controller with no pod template, or a template with no `spec`
   object, is refused. fe-signalloom unwraps the same kinds before calling
   (`fe-signalloom/src/policy_scan.py`), so the two agree and a direct API
   caller is judged the same way.
3. Any **other `kind`** that is not `Pod` is refused. The engine has no
   normalisation for it and must not pretend to judge it.
4. `kind` absent or `Pod` is pod-shaped, **except** that a `spec` which is
   PRESENT must be an object carrying a `containers` list — `spec.containers`
   is required by the Pod schema, and a present spec without it is the shape
   that makes every per-container check vacuously true. A **wholly absent**
   `spec` is allowed: it evidences nothing, packs fail closed on it, and
   `cis-kubernetes/fixtures/unit/malformed-no-spec.json` pins that (16 `fail`,
   not 16 `error`). An empty `containers` list is a caller asserting there are
   no containers, and is judged as such.

A refused object makes every **object-reading** check report `error` with the
shape message. Object-reading is decided by one helper, `readsObject`: an
identifier match on `object` **or** `manifest` — both, because `manifest`
aliases the same value. Agent-only and request-only checks are unaffected.

**Controller-wrapping invariance is a tested property.** Every CIS fixture with
a pod-shaped `input.object` is scanned bare and wrapped in each of the seven
kinds, and the verdict vectors must be identical
(`workload_shape_invariance_test.go`; 77 fixtures × 7 kinds). A pack author
adding a fixture gets the property for free.

Numbers arrive as JSON numbers decoded by Go's `encoding/json` (float64). Write
numeric comparisons that hold for both int and double (`c.securityContext.runAsUser > 0`
is fine; test it with a fixture).

## Verdicts

| Verdict | Meaning |
|---------|---------|
| `pass`  | The expression evaluated to `true`. |
| `fail`  | The expression evaluated to `false`. |
| `error` | The expression could not evaluate (missing key, type error, non-bool), **or** the check reads `object`/`manifest` and the input object is not pod-shaped (see above). |
| `not_evaluated` | The check (or its framework) has `status: placeholder`. The expression is never run; `passed` is `false` and there is no `error`. The summary counts it in `totalControls` and `notEvaluated` only, never in `failed`, `errored` or exposure. |

**`error` is never a `fail`.** A check that errors on an ordinary, valid input
is a defect in the check: guard optional fields with `has()` and decide the
absent-field semantics explicitly (e.g. absent `automountServiceAccountToken`
means the Kubernetes default `true`, so the CIS check fails, not errors).

## Fixtures

Location: `policy/frameworks/<framework-id>/<version>/fixtures/**/*.json`.
One fixture per file. Schema:

```json
{
  "name": "pod-container-runs-as-root",
  "level": "unit",
  "description": "One container sets runAsUser 0 with no runAsNonRoot.",
  "input": {
    "object":  { "apiVersion": "v1", "kind": "Pod", "metadata": {"name": "x"}, "spec": {"containers": []} },
    "agent":   {},
    "request": {}
  },
  "expect": {
    "<check-id>": "fail"
  }
}
```

Rules the harness enforces:

1. `name` is unique within the pack and equals the file's basename without `.json`.
2. `level` is `unit` or `integration`.
3. `expect` is non-empty and every key is a check ID that exists in the pack.
4. A `level: integration` fixture lists an expectation for **every** check in the
   pack (the complete verdict vector), so one realistic input pins all checks at once.
5. Every check whose `status` is not `placeholder` has at least one `pass` and
   at least one `fail` expectation across the pack's fixtures (coverage gate).
   A pack with any non-placeholder check and no fixtures at all fails the gate.
   A placeholder check's expectation must be `not_evaluated`, and only a
   placeholder check may expect `not_evaluated`.
6. An `error` expectation is allowed only for deliberately malformed input and
   the fixture's `description` must say why.
7. Every check expression compiles.
8. A scan at `policyVersion` = a pack's own `version` returns exactly that
   directory's checks carrying that version, each once
   (`TestConformance_VersionSelection`, through the real `handleScan`).

Unit fixtures are minimal: change one fact relative to a compliant baseline so
the expectation is attributable to that fact. Integration fixtures are
realistic: multi-container workloads, real Helm-chart-shaped pods, a fully
described agent.

## Pinning money

Every check carries a `riskTriple` (loss magnitude) and a `freqTriple` (events
per year). A scan reports four figures per check: `ale`, `var95`, `tvar` and
`carriedGbp`. **Those figures are part of the contract, not decoration.** The
product sells *priced* risk, and a figure nobody checked is worse than no
figure.

The money is a **pure function of `(check ID, riskTriple, freqTriple)`**. The
simulation seed is `fnv64a(check.ID)`, and nothing from the scanned object
enters it. So a *passing* row still carries a full-size figure. It is the
**summary** that excludes passing rows from exposure. The figure is therefore a
per-check constant, pinned per pack rather than per fixture.

### What the tests prove, and what they cannot

Read [the calibration statement](README.md#the-calibration-statement) with any
figure out of this engine. Everything below is about the arithmetic over the
declared inputs. **Nothing below tests that any number is the right number**,
and nothing can: calibration is an expert-judgement input, not a computable
property of the code. The table separates the two so neither can be mistaken for
the other.

| Claim | How it is held | Strength |
| :--- | :--- | :--- |
| `ale` is `E[freq] x E[loss]` for the declared triples | Closed form derived from the beta-PERT definition, not from `fair.go`, in `compliance_money_oracle_test.go`. Tolerance is 5 standard errors of the engine's own estimator. Worst observed over the priced checks: **2.71 sigma**, 1.87 % relative, `cis-kubernetes/v1.8 no-host-ports`. | Independent of the implementation |
| `var95`, `tvar`, `carried` are the figures this engine produced | The per-pack golden files only, plus the closed-form support bounds `[min_f x min_l, max_f x max_l]` and the ordering identities. | **Pinned, not verified.** Three of the four figures the product quotes |
| `tvar >= var95`, `tvar >= ale`, `carried >= tvar`, all finite and non-negative | `TestConformance_MoneyFigureOrdering` | Property over every shipped check |
| `carried` is exactly `tvar` plus 10 % of the unrounded tail mean | same test | Property |
| `tailDominated` is true if and only if `var95 < ale` | `TestConformance_MoneyTailDominatedFlagIsExact`, both directions, plus a reachability sweep | Property, with the sweep pinned at zero |
| raising `riskTriple.mode` never lowers `carried` | `TestConformance_MoneyExposureMonotoneInRiskMode` | Monotonicity |
| the same check ID with the same triples prices identically in every pack, and a rename moves every figure | `TestConformance_MoneySeedDerivedFromCheckID` | Determinism |
| a `not_evaluated` row keeps its figure and adds nothing to summary exposure | `TestConformance_MoneyNotEvaluatedFigureExcludedFromExposure` | Property |
| `GBP` is the reporting currency and `money` refuses to add across denominations | `TestConformance_MoneyReportingCurrencyIsPinned` | Property |
| a pack with no frequency triple prices every check at zero | `TestConformance_MoneyPacksWithoutFreqTriplePriceAtZero` | Property, keeps the two zero groups apart |
| each pack page states its own priced and unpriced counts correctly | `policy/frameworks/pricing-counts-test.sh`, run by `make policy-pricing-counts` | Generated from `framework.json`, fails on one character of drift |
| **that a triple is the correct estimate for its control** | **nothing** | **No test exists, and none is possible** |
| **that a magnitude and a frequency were not transposed** | the golden files only. The analytic anchor is blind to it, because `E[F] x E[M]` and the support product are both symmetric in their arguments | Golden-only |

`tailDominated` is **unreachable on the per-check `fair.Simulate` path**, so the
flag is dead code there. `alpha + beta` is fixed at 6, which bounds the
attainable skew. `Simulate` also multiplies a *continuous* frequency instead of
drawing Poisson event counts, so there are no zero-loss years. `P(L <= E[L])`
sits at about 0.63 to 0.69 across the family, against the 0.95 needed to invert
the inequality. The signal is live only on the aggregate `Engine.Run` and
`Engine.RunDistribution` path, which does draw Poisson counts.

The normative Open Group FAIR texts (O-RT 3.0.1 and O-RA 2.0.1) sit behind
registration and **were not read**. Do not cite them here as if they were. The
model steward is the FAIR Institute, and the distribution mathematics is
standard beta-PERT, for which Vose is the usual reference.

### Not additive: never sum `var95`, `tvar` or `carried`

Means add. Percentiles do not. `ale` is an expectation, so the sum over checks
is the expectation of the total. `var95`, `tvar` and `carried` are tail
statistics of separate marginal distributions. Adding them assumes the losses
are perfectly correlated, which overstates the tail, and the result is not the
95th percentile of anything.

A portfolio figure needs **one joint run**. `fair.Engine.RunDistribution`
already does this, returns the sorted vector of simulated annual losses, and is
tested in `fair/distribution_test.go`. Take the quantile of the aggregate with
`fair.Percentile`. The aggregate path is also the better FAIR model. It draws
Poisson event counts and carries an institution-owned risk load. The per-check
path does neither.

Two live call sites in the dashboard sum the per-check quantiles. They are a
**known defect**, recorded here so the pattern is not copied, and they are
outside the ownership of this directory:

- `d2-signalloom/apps/dashboard-signalloom/src/api/supercredProjection.ts`
  lines 319 to 320, `totalVar95` and `totalTvar`, each a `reduce` over the
  per-check figure.
- `d2-signalloom/apps/dashboard-signalloom/src/api/fakeComplianceData.ts`
  lines 248 to 250, `totalVar95`, `totalTvar` and `totalCarried`, each a
  `sumMoney` over the per-check figure.

### Golden files

```
d2-signalloom/apps/policy-engine/testdata/money-golden/<framework-id>@<version>.json
```

One file per pack, covering **every** check in it — not a sample. Each row
records the check ID, the seed, both triples, the four figures, the engine's
`tailDominated` flag, and the analytic anchor (`analyticAle`, `aleSigma`).

Regenerate and re-verify:

```bash
make verify-cel-money-golden      # pin NEW checks, then assert
make verify-cel-money             # assert only (also runs inside verify-cel-conformance)

# move an ALREADY-PINNED price deliberately:
make verify-cel-money-golden-acknowledged REASON="recalibrated CRA-1.1 after the 2026 loss study" CHECKS=1
```

A triple edit is then a reviewable diff of exactly the prices it moved. Change
`riskTriple.mode` on one check, regenerate, and four figures plus one sigma move
on that one row. **Review that diff.** It is every price the product quotes for
that control.

#### Update mode cannot absorb an engine regression

`MONEY_GOLDEN=update` used to rewrite **every** row from whatever the engine
currently produced, with no control but a comment saying "review the diff". An
adversarial audit changed one character in `fair.go` —
`percentile(annualLosses, 0.95)` to `0.94`, a plausible off-by-one — and the
path was: the money test fails correctly, update mode absorbs it, **the full
suite goes green**, and **64 priced figures across 5 packs have moved 4–5 %**.
The goldens were regenerated three times in one session, which is exactly the
condition under which a reviewer stops reading 64 numbers.

So update mode is now split by whether a check is already pinned:

| Case | Behaviour |
|---|---|
| check **absent** from the golden | pinned freely — one command, no ceremony |
| check **gone** from the pack | row dropped freely, listed in the log |
| check **already pinned**, figures identical | nothing to do |
| check **already pinned**, any figure moved | **REFUSED**: delta table printed, **no file written at all** |

A refused run writes nothing anywhere, so there is never a half-updated set. To
move a pinned price you must state the movement:

```
MONEY_GOLDEN_MOVE_REASON="<why these prices moved>"
MONEY_GOLDEN_MOVE_CHECKS=<exact number of checks expected to move>
```

The **count** is what defeats the attack: laundering that one-character change
requires typing `64` beside a written reason, and both are recorded into each
affected golden's `lastMovement` block, so the claim lands in the commit as a
sentence rather than as drift buried in digits. A stale acknowledgement with
nothing moving is also refused, so it cannot sit pre-authorising the next run.

The run additionally separates movements whose **triples and seed are
identical** — meaning the *engine* moved, with no pack edit in the diff to
explain the new numbers — from movements that follow an input change.

#### Delta tables

Any movement, in update mode **or** on an assert failure, prints per figure:
check, figure, old, new, percentage, closing with a median-and-range summary.
The summary is the load-bearing part. A uniform drift across dozens of checks
has a *tight* percentage range — the signature of an engine change — and that is
exactly what a diff of 64 JSON rows hides. The audit's mutation prints as
`64 numeric figure(s) moved; median -4.27%, range -5.24% .. -3.06%`.

Comparison is **exact**. `fair.Simulate` is a seeded Monte Carlo over a PCG
generator consumed in a fixed order. For a given `(triple, triple, seed)` it is
deterministic to the bit. There is no sampling tolerance to allow for, and
allowing one would hide the drift the goldens exist to catch.

### The analytic anchor

A golden regenerated from the engine and asserted against the engine is
circular. The anchor is a **closed form**, derived from the distribution's
definition rather than from `fair.go`, in
`d2-signalloom/apps/policy-engine/compliance_money_oracle_test.go`. The sampler
draws `X = min + span·B`, `B ~ Beta(α, β)` with `α = 1 + 4(mode−min)/span` and
`β = 1 + 4(max−mode)/span`, so **α+β ≡ 6** for every triple and

| Quantity | Closed form |
|---|---|
| `E[X]` | `(min + 4·mode + max) / 6` (the PERT mean) |
| `Var[X]` | `span² · α·β / 252` (252 = 6²·7) |
| `E[L]` for `L = F·M` | `E[F] · E[M]` — independent draws |
| `Var[L]` | `(Var[F]+E[F]²)(Var[M]+E[M]²) − (E[F]·E[M])²` |
| standard error of `ALE` | `sqrt(Var[L] / 10000)` |

So the tolerance on `ALE` is **5 standard errors of its own estimator**, not a
percentage pulled from the air. Worst observed across the estate: **2.71 σ**
(1.87 % relative), `cis-kubernetes/v1.8 no-host-ports`. A line-by-line port of
`fair.go` would have agreed by construction and anchored nothing.

**`var95`, `tvar` and `carried` are NOT independently pinned. They are pinned
only by the golden files**, plus the closed-form support
`[min_f·min_l, max_f·max_l]` that every figure must lie inside and the ordering
properties below. That is three of the four figures the product quotes, and it
is an admitted gap rather than an assurance. The guard on *how* a golden may be
rewritten (above) is what makes the remaining gate worth anything.

The gap is not laziness, and it is **quantified**. An optional non-gating tier
gives the quantiles the only independent treatment available:

```bash
make verify-cel-money-independent   # needs NumPy; statistical, not part of verify-cel
```

It no longer uses a hand-picked relative tolerance. For `var95` the engine's
figure is the order statistic at rank `ceil(0.95·10000) = 9500`; the probability
level such an order statistic attains is `Beta(k, n−k+1)`-distributed — a
distribution-free fact about sampling, true of **any** correct implementation —
with standard deviation `sqrt(p(1−p)/n) = 0.00218`. A 4.5 σ window therefore
spans levels **0.9402 – 0.9598**, and the admissible value window is that
window mapped through the script's own independently-estimated quantile
function. For `tvar` the figure is the mean of the 500 draws above that order
statistic, so its standard error is the independently-estimated tail deviation
over `sqrt(500)`, unioned with the tail means at both level bounds.

Measured on this estate: the Go oracle's algebra agrees with a 1 000 000-sample
estimate to **0.19 %**; `var95` sits within **2.58 %** of the independent point
estimate and `tvar` within **2.89 %**; and the derived admissible window is up
to **±5.42 %** for `var95` and **±4.09 %** for `tvar`.

**That window is the honest limit, and it is wider than the defect.** The
audit's one-rank percentile shift moves these figures by 3.06–5.24 %, which is
the same order as the sampling noise any correct 10 000-iteration implementation
must be allowed. It lands inside the statistical envelope, so **no point-estimate
comparison at the engine's sample size can separate the two** — whether an
individual check happens to trip is luck, not detection. Raising the sample
count does not help, because the noise being absorbed is the *engine's*, not the
oracle's. This tier catches an order-of-magnitude error, a lost scale factor, a
changed PERT λ, a figure read from the wrong triple, or a quantile taken at the
wrong end. It does **not** catch a one-rank percentile shift, and nothing
statistical can. The deterministic goldens plus `TestWriteMoneyGolden`'s refusal
are the only instruments that do.

**Known blind spot of the analytic tier**, found by mutation. It cannot see
frequency and magnitude **transposed**, because `E[F]·E[M]` and the support
product are both symmetric in their arguments. That mutation is caught by the
golden files instead — the two triples are consumed in a fixed draw order, so
`var95` and `tvar` move. The analytic tier conversely catches what a golden
cannot: a sampler change whose author regenerates the golden. Mutating the PERT
λ from 4 to 2 and regenerating leaves every golden green and moves the analytic
anchor by **35–43 σ**. Neither tier is sufficient alone. That is why both exist.

### Properties, and one that is deliberately absent

| Property | Where |
|---|---|
| `tvar >= var95`, `tvar >= ale`, `carried >= tvar`, all four finite and non-negative | `TestConformance_MoneyFigureOrdering` |
| `carried` is exactly `tvar + 10 %` of the **unrounded** tail mean | same |
| `tailDominated` **iff** `var95 < ale`, in both directions, plus a reachability sweep | `TestConformance_MoneyTailDominatedFlagIsExact` |
| raising `riskTriple.mode` never lowers `carried` | `TestConformance_MoneyExposureMonotoneInRiskMode` |
| the same check ID with the same triples prices identically in every pack, and renaming it moves every figure | `TestConformance_MoneySeedDerivedFromCheckID` |
| a `not_evaluated` row keeps its own figure but contributes nothing to summary exposure | `TestConformance_MoneyNotEvaluatedFigureExcludedFromExposure` |
| `GBP` is hardcoded, and `money` still refuses to add across denominations | `TestConformance_MoneyReportingCurrencyIsPinned` |

**`ale <= var95` is NOT asserted, deliberately.** An earlier revision of
`fair.Simulate` clamped `VaR95` up to `ALE`. The clamp was removed because
`VaR95 >= ALE` is not a property of loss distributions. For a rare-but-severe
risk most simulated years cost nothing, so the 95th percentile sits below the
mean. The clamp then "silently reported a bad year equal to the average year",
in precisely the well-governed case a client most wants to see. See the note on
`fair.Simulate` and `fair/regression_test.go`. Asserting the ordering here would
re-introduce that defect as a test. The honest relation is asserted instead: the
`tailDominated` biconditional.

### Two findings pinned by these tests

1. **73 of 134 checks price at £0.00, so only 61 are priced at all.** The live
   counts are in the generated block on each pack page and on
   [`README.md`](README.md#pricing-coverage-across-the-estate), which
   `make policy-pricing-counts` keeps honest. Four shipped packs —
   `eu-ai-act/v1.0`, `eu-ai-act/v2.0`, `nist-800-53/v1.0`, `nist-800-53/v2.0` —
   declare a
   `riskTriple` but **no `freqTriple` at all**. `fair.Simulate` short-circuits an
   all-zero frequency to a zero result. So every check in those packs reports
   `0.00`, and a scan of them reports **zero total exposure however many controls
   fail**. `dora/v1.0` and `nis2/v1.0` also price at zero. They are
   all-placeholder packs, so for them zero is correct. Three further checks in
   `nist-800-53/v2.1` are unpriced and are declared as such in
   `nist-800-53/catalogue/unpriced.tsv`.
   `TestConformance_MoneyPacksWithoutFreqTriplePriceAtZero` keeps the two groups
   apart and pins both. Adding a `freqTriple` turns the golden red, and the new
   figures must then be proved.
2. **Tail dominance is unreachable on the `Simulate` path**, so `tailDominated`
   is dead code there. `α+β ≡ 6` bounds the attainable skew. `Simulate` also
   multiplies a *continuous* frequency instead of drawing Poisson event counts,
   so there are no zero-loss years. An independent derivation puts
   `P(L <= E[L])` at about 0.63–0.69 across the extremes of the family, against
   the 0.95 needed to invert. Zero-loss years only appear on the aggregate
   `Engine.Run` path, which does draw Poisson. The reachability sweep is pinned
   at zero, so a sampler change or Poisson counts on this path surface at once.

**A new check, or a new triple on an existing check, must land with its golden
row regenerated in the same commit.** A pack whose golden file is missing or
incomplete fails `TestConformance_MoneyGoldenMatchesEngine` by name.

## Proving a test bites

For every new check or fixture, record in the commit body or the worker report:

- **mutation**: the change made to the CEL (or fixture) and the failing harness
  line it produced;
- **fix**: the restoration and the passing run.

Restore mutated files from an explicit backup copy (`cp f /tmp/f.bak` ...
`cp /tmp/f.bak f`), never from the git index.

## Pack ownership

| Pack | Owner of field paths |
|------|----------------------|
| `cis-kubernetes` | `object` only |
| `finos-aigf` | `agent` paths listed in `finos-aigf/v1.0/AGENT-CONTEXT.md` |
| others | as written in each pack; `agent`/`request` paths documented in the pack's `AGENT-CONTEXT.md` when added |

Field paths already shipped are frozen: extend, never rename.
