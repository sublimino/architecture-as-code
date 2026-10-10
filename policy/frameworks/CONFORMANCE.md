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
per year), and a scan reports four figures per check: `ale`, `var95`, `tvar` and
`carriedGbp`. **Those figures are part of the contract, not decoration** — the
product sells *priced* risk, and a figure nobody checked is worse than no
figure.

The money is a **pure function of `(check ID, riskTriple, freqTriple)`**. The
simulation seed is `fnv64a(check.ID)` and nothing from the scanned object enters
it, so a *passing* row still carries a full-size figure; it is the **summary**
that excludes passing rows from exposure. The figure is therefore a per-check
constant, and it is pinned per pack rather than per fixture.

### Golden files

```
d2-signalloom/apps/policy-engine/testdata/money-golden/<framework-id>@<version>.json
```

One file per pack, covering **every** check in it — not a sample. Each row
records the check ID, the seed, both triples, the four figures, the engine's
`tailDominated` flag, and the analytic anchor (`analyticAle`, `aleSigma`).

Regenerate and re-verify:

```bash
make verify-cel-money-golden      # rewrite the goldens, then assert them
make verify-cel-money             # assert only (also runs inside verify-cel-conformance)
```

A triple edit is then a reviewable diff of exactly the prices it moved: change
`riskTriple.mode` on one check and `make verify-cel-money-golden` shows four
figures and one sigma moving on that one row. **Review that diff.** It is every
price the product quotes for that control.

Comparison is **exact**. `fair.Simulate` is a seeded Monte Carlo over a PCG
generator consumed in a fixed order, so for a given `(triple, triple, seed)` it
is deterministic to the bit. There is no sampling tolerance to allow for, and
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

**`var95` and `tvar` are not analytically pinned**, because a quantile of a
product of two Beta variates has no comparable closed form. They are held by
(a) the golden diff, (b) the closed-form support `[min_f·min_l, max_f·max_l]`,
which every figure must lie inside, and (c) the ordering properties below. The
limitation is stated rather than hidden behind a loose tolerance. An optional
non-gating tier compares them to an independent NumPy derivation:

```bash
make verify-cel-money-independent   # needs NumPy; statistical, not part of verify-cel
```

Observed there: the Go oracle's algebra agrees with a 1 000 000-sample estimate
to **0.19 %**; `var95` to **2.58 %** and `tvar` to **2.89 %**, which is the
expected quantile noise at the engine's 10 000 iterations.

**Known blind spot of the analytic tier**, found by mutation: it cannot see
frequency and magnitude **transposed**, because `E[F]·E[M]` and the support
product are both symmetric in their arguments. That mutation is caught by the
golden files instead — the two triples are consumed in a fixed draw order, so
`var95` and `tvar` move. The analytic tier conversely catches what a golden
cannot: a sampler change whose author regenerates the golden. Mutating the PERT
λ from 4 to 2 and regenerating leaves every golden green and moves the analytic
anchor by **35–43 σ**. Neither tier is sufficient alone; that is why both exist.

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
`fair.Simulate` clamped `VaR95` up to `ALE`; the clamp was removed because
`VaR95 >= ALE` is not a property of loss distributions — for a rare-but-severe
risk most simulated years cost nothing, the 95th percentile sits below the mean,
and the clamp "silently reported a bad year equal to the average year" in
precisely the well-governed case a client most wants to see (see the note on
`fair.Simulate` and `fair/regression_test.go`). Asserting the ordering here
would re-introduce that defect as a test. The honest relation — the
`tailDominated` biconditional — is asserted instead.

### Two findings pinned by these tests

1. **66 of 127 checks price at £0.00.** Four shipped packs — `eu-ai-act/v1.0`,
   `eu-ai-act/v2.0`, `nist-800-53/v1.0`, `nist-800-53/v2.0` — declare a
   `riskTriple` but **no `freqTriple` at all**. `fair.Simulate` short-circuits an
   all-zero frequency to a zero result, so every check in those packs reports
   `0.00` and a scan of them reports **zero total exposure however many controls
   fail**. `dora/v1.0` and `nis2/v1.0` also price at zero, but they are
   all-placeholder packs and that is correct;
   `TestConformance_MoneyPacksWithoutFreqTriplePriceAtZero` keeps the two groups
   apart and pins both, so adding a `freqTriple` turns the golden red and the new
   figures must be proved.
2. **Tail dominance is unreachable on the `Simulate` path**, so `tailDominated`
   is dead code there. `α+β ≡ 6` bounds the attainable skew, and `Simulate`
   multiplies a *continuous* frequency instead of drawing Poisson event counts,
   so there are no zero-loss years — an independent derivation puts
   `P(L <= E[L])` at about 0.63–0.69 across the extremes of the family, against
   the 0.95 needed to invert. Zero-loss years only appear on the aggregate
   `Engine.Run` path, which does draw Poisson. The reachability sweep is pinned
   at zero so a sampler change, a different λ, or Poisson counts on this path
   surface immediately.

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
