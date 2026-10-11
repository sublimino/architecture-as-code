# FAIR methodology: the open decisions

This page records the methodology decisions that are open on the priced-risk
engine. Each one is the principal's call, not an engineering choice, because
each one changes a number a customer may put in front of a regulator.

Read [the calibration statement](../policy/frameworks/README.md#the-calibration-statement)
first. What the tests prove and what they cannot prove is in
[`CONFORMANCE.md`](../policy/frameworks/CONFORMANCE.md#what-the-tests-prove-and-what-they-cannot).

Sections 1 to 8 are not defect reports. The engine does what it says. Each names
a place where the model is thinner than the use the figures are being put to,
states the cheapest remedy, and stops there.

Sections 9 and 10 are different. They record two defects found while writing
this page, with the precision needed to act on them. Neither is fixed here,
because in both cases the remedy changes a figure that is already in front of a
customer.

## 1. The verdict does not select the frequency triple

`fair.Simulate` runs before and regardless of the check verdict, so a `pass` and
a `fail` on one check carry the same four figures. In FAIR terms the engine
reports loss event frequency with no vulnerability term. A control that is in
place and a control that is absent cannot have the same loss event frequency.

The shape for the remedy already exists. `pack.yaml` carries `lef_enforced` and
`lef_audit`, which is exactly the pair FAIR needs. The cheapest remedy is to
select the triple from the verdict at the call site.

**Cost of not doing it:** a scan of a fully compliant workload reports the same
per-check figures as a scan of a non-compliant one. Only the summary differs.

## 2. A missing frequency triple is silent

A check with no `freqTriple`, or an all-zero one, prices at zero however often
it fails. 73 of 134 shipped checks are in that state. Today the loader accepts
this, and the silence is caught after the fact by two tests outside the gate:
`policy/frameworks/nist-800-53/catalogue/pricing-test.sh` asks whether each
unpriced check is declared, and `policy/frameworks/pricing-counts-test.sh` asks
whether each pack page counts them correctly.

The precedent is in the same codebase. `money/money.go` makes a missing exchange
rate an error rather than a zero, for the same reason: a zero that means
"unknown" is indistinguishable from a zero that means "nothing".

The cheapest remedy is a loader error for an undeclared missing triple, with an
explicit `unpriced` status on the check for the deliberate case.

**Cost of not doing it:** the next pack authored to the current instructions
reaches a customer with every figure at zero, and no gate stops it.

## 3. `Simulate` does not draw event counts

The per-check path multiplies a loss magnitude by a *continuous* frequency. The
aggregate path, `Engine.RunDistribution`, draws Poisson event counts, which is
the FAIR model. Two consequences follow from the difference.

- There are no zero-loss years on the per-check path, so `tailDominated` can
  never be true there. The flag is dead code on that path.
- A frequency below one event per year is modelled as a fraction of a loss
  rather than as a chance of a whole loss. That is the common case for a
  regulatory control.

The remedy is about ten lines: have `Simulate` delegate to the distribution
code that is already in the same file and already tested.

**Cost of not doing it:** the per-check tail figures are the wrong shape for
low-frequency controls, and a flag the product displays can never fire.

## 4. There is no secondary loss and no secondary loss event frequency

FAIR splits primary loss from secondary loss, and gates the second on a
secondary loss event frequency. This engine models one loss magnitude.

For the EU AI Act, the Digital Operational Resilience Act, the NIS2 Directive
and the Cyber Resilience Act this is the wrong way round. **The fine is the
secondary loss, and for these frameworks the fine is the product.** A customer
buying priced regulatory risk is buying the number this engine does not model.

The cheapest remedy is a second magnitude triple plus a probability, declared
per check, and summed inside the simulation rather than outside it.

**Cost of not doing it:** the figures understate exactly the exposure the
regulatory packs are sold to quantify, and by an unknown factor.

## 5. The 10 % risk load is hardcoded in three places

`carried` is `tvar` plus a risk load. The load is an institutional capital
parameter. It belongs to the institution, not to the engine, and it is the kind
of number a risk function sets once and reviews annually.

The `riskctl` aggregate path gets this right. It reads `risk_load` from the
organisation file, rejects a value that is not finite or is negative, and prints
the load beside the figure it produced. `risk/org/acme.yaml` sets **0.15**.

Three code paths ignore that file and use **0.10**:

| Site | What it prices |
| :--- | :--- |
| `fair.Simulate`, `fair/fair.go:98` | every per-check figure in a compliance scan |
| `pkg/compliance/fleet_scan.go:252` | a fleet scan row |
| `pkg/compliance/fleet_scan.go:281` | the same, second call site |

So the only organisation file in the repository declares a load the scan path
does not apply, and the two numbers differ by half the load again. The cheapest
remedy is to thread the organisation value through, keeping 0.10 as the fallback
so no figure moves until someone sets one.

**Cost of not doing it:** the `carried` figure a scan reports is not the
`carried` figure the institution's own policy asks for, and nobody reading
either number can tell.

## 6. There is no loss exceedance curve

A loss exceedance curve is the standard FAIR output and the one artefact a risk
committee recognises on sight. It answers "what is the chance of losing more
than X in a year", which is the question a board asks, and it shows the
uncertainty instead of hiding it behind a single number.

Everything needed already ships. `Engine.RunDistribution` returns the sorted
vector of simulated annual losses and `fair.Percentile` reads any level off it.
The remaining work is a route and a chart.

**Judgement, not cost:** of the items on this page, this is the one that buys
the most credibility for the least work. It is listed last because it adds an
output rather than correcting one, and the corrections come first.

## 7. Per-triple provenance, and the `calibrationSource` field

Every scan row carries `calibrationSource`. Until 2026-10-11 it read
`industry-indicative`, which asserted an industry anchor that does not exist. It
now reads `declared-estimate-unanchored`.

The field is still set in Go, by the engine, on every row. It reads the same on
a priced row and on a row that prices at zero, and it cannot distinguish a
triple a risk function signed off from one an engineer typed.

**0 of the 61 priced checks carry any provenance.** The check shape has no field
for provenance, author, date, or anchor class, and the loader uses
`DisallowUnknownFields`, so adding one is a loader change rather than a data
change. A search of the whole tree for the names of the loss datasets a reader
would expect, and for the phrase "expert judgement", returns nothing.

The 73 unpriced checks are declared across three files:
`policy/frameworks/{cra,eu-ai-act,nist-800-53}/catalogue/unpriced.tsv`. Their
reason codes are `no-calibrated-frequency` on 70 and a placeholder reason on 3.
The declarations therefore carry a reason where the priced triples carry none,
which is the wrong way round.

The cheapest remedy is an optional provenance block on the triple, carried
through to the row, with the engine-set tag as the fallback for a triple that
has none.

**Known drift:** the dashboard still shows the string `industry-indicative`,
from its own constants in `supercredProjection.ts`, `fakeComplianceData.ts` and
`RiskExposurePage.tsx`. Those files are outside the ownership of this change.
Until they are updated the dashboard and the engine disagree about the
provenance of the same figure.

## 8. Not in `verify-cel`

Two pack tests run only when someone runs them: `make policy-pricing-counts` and
`policy/frameworks/nist-800-53/catalogue/run-tests.sh`. Both are plain shell and
need no Go toolchain, and both guard a claim the Go harness cannot see.

The cheapest remedy is to add them to the aggregator and to continuous
integration, which needs `jq` on the runner.

**Cost of not doing it:** a pack page can go stale, or a pack can ship with an
undeclared unpriced check, and the gate stays green.

## 9. A live route returns fabricated money

This one is a defect, not a modelling choice, and it is recorded here with
precision because the same figures are quoted in a customer-facing proposal.
**Do not change the code.** The remedy is the principal's decision.

`POST /api/v1/compliance/scan-fleet` is routed at `main.go:219` to
`HandleScanFleet` in `pkg/compliance/fleet_scan.go`. Its risk summary is
`calculateFleetFairRisk`, and that function returns literals.

| Line | What it does |
| :--- | :--- |
| 250 to 252 | builds a loss triple and a frequency triple, calls `fair.SimulateWithLoad`, keeps the result in `sim` |
| 254 to 263 | sets `ale`, `var95` and `carried` to 9800, 11200 and 12400, then tests `if sim.ALE > 0` and assigns **the same three literals again in that branch** |
| 278 to 281 | builds a second pair of triples and calls `fair.SimulateWithLoad`, assigning the result to the blank identifier: `_ = fair.SimulateWithLoad(loss, freq, 99, 0.10)` |
| 283 to 286 | returns 847000 carried, 742000 var95 and 615000 ale |
| both branches | derives `tvar` as `carried / 1.10`, so the tail statistic is read backwards out of the loaded figure |

So the simulation runs, and in neither branch does its output reach the
response. The figure is invariant to the agent count, to which controls failed
and to which packs were loaded. Only the branch depends on the scan, and the
branch has two possible answers.

`allocatePerAgentRisk`, lines 300 to 320, hands out 350000 to the agent whose
`AgentID` is the string `agent-txn-pipeline` and 497000 to
`agent-llm-classifier`. Any other failing agent gets an even share of the
fleet total.

The test does not catch it, because the test asserts the tautology.
`TestFAIR_SimulationConsistency` at `fleet_scan_test.go:129` checks that
`CarriedGBP` equals `TVaR * 1.10`, which is true by construction, since the
code set `tvar := carried / 1.10`. It is named as a FAIR proof and proves
arithmetic on one literal.

**Where the figures already appear:**
`docs/multi-agent-supercred-proposal.md` line 121 states that the engine
"recalculates live" to 847,000 and describes it as "calibrated to industry
benchmarks". Four further lines in the same record quote 12,400 and 847,000 as
calibrated. They are neither calibrated nor computed.

**The correct aggregation is already written, tested, and called by no engine
path.** `fair.Engine.Run` and `fair.Engine.RunDistribution` use 200,000
iterations, draw Poisson event counts, carry an institution-owned risk load, and
offer `Result.SelfCheck` for the ordering invariants. Only `tools/riskctl` calls
them. Replacing the literals with one `Engine.Run` over the failing checks is
the shape of the remedy.

## 10. Three aggregation paths disagree about the same field name

A reader who compares two totals for the same estate can get three answers.

| Path | What it sums into the carried total |
| :--- | :--- |
| the policy-engine scan summary | failing and errored checks |
| the `fe-signalloom` scan summary | every check, including passing ones |
| `GET /compliance/policy/summary` | nothing. All four totals are hardcoded to zero |

So `totalCarried` is a real sum on one route and a literal zero on another, and
the two real sums are over different populations. The cheapest remedy is to pick
one population, name it in the field, and have the `GET` route either compute it
or return no field at all rather than a zero that reads as "no exposure".
