# `risk/` — policy as versioned code, priced in pounds

> "What does a breach actually cost you? Not a red, amber, green dot on a dashboard — a number in
> pounds. Most governance ignores that. Compliant or not: a green tick that prices nothing and moves
> nothing. A binary lie."

This directory makes the platform's controls **priceable**. It baselines an AI agent's compliance
posture against a versioned policy pack and this institution's risk posture, and emits a
reproducible cash value of the residual risk exposure.

Design, phasing and platform integration: [`docs/policy-as-versioned-code/INTEGRATION.md`](../docs/policy-as-versioned-code/INTEGRATION.md).
The thesis it obeys: [`docs/breach-cost-talk/TALK.md`](../docs/breach-cost-talk/TALK.md).

## Quick start

```bash
go build -C tools/riskctl -o "$PWD/tools/riskctl/riskctl" .

# Which controls does this agent actually meet, and what proves it?
./tools/riskctl/riskctl baseline --agent agent-remediation --pack 2.0.0 --org acme

# What does that posture cost Acme Co. per year?
./tools/riskctl/riskctl risk     --agent agent-remediation --pack 2.0.0 --org acme

# The estate moved to 2.1.0. What does the laggard cost now?
./tools/riskctl/riskctl risk     --agent agent-remediation --pack 2.1.0 --org acme

# Same agent, same pack, two institutions.
./tools/riskctl/riskctl compare  --agent agent-olly-sentinel --pack 2.1.0 --org acme --with ludlow-health
```

No cluster. No network. No API key. Fixed seed — the same inputs reproduce the same pounds.

## Layout

| Path | What it is |
| --- | --- |
| `packs/agent-policy/<semver>/pack.yaml` | A complete versioned policy pack — what a signed semver git tag resolves to. Controls, rationale, risk triples, enforcement actions, conditional branches, cage tiers. |
| `packs/agent-policy/<semver>/cel/` | Kyverno CEL `ValidatingPolicy` bodies, including the conditional-autonomy branch. No bespoke DSL. |
| `posture/agent-*.yaml` | What is actually true about a named agent, each assertion citing the repository artefact that evidences it. |
| `org/*.yaml` | An institution's loss magnitude per scenario, risk appetite, risk load and insurance position. |
| `out/` | Generated report. Committed so the number is reviewable in a diff; regenerable with `make risk-report`. |

## The one idea

```
pack  -> loss event FREQUENCY   (a property of the control environment)
org   -> loss MAGNITUDE         (a property of the institution)
```

Because frequency and magnitude live in different files, one identical control run against two
institutions produces different enforcement **arithmetically**. Nobody has an opinion. The pounds
decide.

## What the numbers mean

| Figure | Meaning |
| --- | --- |
| **ALE** | Mean of the aggregate annual-loss distribution — the average year. |
| **VaR₉₅** | 95th percentile — the bad year. |
| **TVaR** | Mean of the tail beyond VaR₉₅ — the tail your board actually fears. |
| **carried** | `TVaR × (1 + risk load)`. Never charge the mean. |
| **TCoR** | `residual + cost of controls (incl. cage run-cost) + risk transferred`. |
| **buys/yr** | `ALE_now − ALE_if_this_control_were_met`. What tightening a control is worth. |

A control whose `buys/yr` exceeds the institution's tolerance band is flagged for promotion from
`audit` to `deny`. That flag is **proposed, never applied** — it becomes a reviewed pull request.

## Two things that will surprise you, and should

**Tightening a non-dominant control buys nothing.** Several controls defend the same loss scenario;
an attacker needs one way in, so the scenario's frequency is set by its *weakest* control. Fixing a
second-weakest control shows `£0` until the weakest is fixed. That is a true statement about defence
in depth, and the report shows it rather than flattering you.

**A well-governed agent produces `VaR₉₅ = 0` with `ALE > 0`.** Once more than 5% of simulated years
contain no loss event, the 95th percentile falls to zero while the mean stays positive, carried
entirely by rare severe years. The report calls this **tail-dominated** and says what it implies: of
the four risk-financing moves — avoid, reduce, transfer, retain — you have reached the regime where
*transfer* starts to beat further control spend. That is the shape an underwriter prices.

## Honesty

Every triple in `org/*.yaml` is a **calibrated estimate against a named anchor class**, not a
published figure used verbatim, and every one carries a `provenance` string so it can be argued
with. The loader refuses a magnitude with no provenance and a posture assertion with no evidence
path. Re-calibrate against real incident history before any board, external or underwriter use.

The apparatus is real and reproducible. The inputs are illustrative until someone signs them off.

## Denomination: every amount carries its own currency

Amounts used to be bare numbers with the currency welded into the field *name* —
`annual_cost_gbp`, `tolerance_gbp`, `per_deny_control_gbp`. A name does not survive a wire, a
database column or a chart axis, so nothing downstream could convert, and a UI defaulting to USD
over GBP source data would **relabel** a figure rather than convert it.

Every amount is now `money.Money`, carrying its denomination as data. Each file declares its
currency once; an individual amount may override it:

```yaml
currency: GBP                                   # document default
appetite:
  tolerance: 25000                              # inherits GBP
transfer:
  annual_premium: { amount: 60000, currency: EUR }   # explicitly denominated
```

Rules that make this safe rather than decorative:

- **A document containing money must declare a currency.** A bare amount with no default is a load
  error, never a guess.
- **The old `*_gbp` keys are rejected at load, by name and line.** `yaml.v3` silently ignores keys
  a struct does not declare, so an unmigrated file would otherwise load every cost as **zero** and
  understate the figure with no warning.
- **A missing rate is an error naming the pair**, never a silent `1.0`. A conversion that quietly
  passes a number through is the failure mode that puts a wrong figure on a slide.
- **Adding or comparing two denominations is refused**, not merely discouraged. A tolerance test
  across currencies produces a wrong *verdict*, not just a wrong number.

### Rates: checked in, dated, offline

`risk/fx/rates.yaml` carries an `as_of` date and a base of USD. Same reasoning as the pinned Monte
Carlo seed: *a number nobody can reproduce is not evidence*. A live FX lookup would make every
historical report irreproducible and put a network dependency on the critical path of a board
figure. Updating rates is a reviewed pull request that re-versions the money alongside the policy.

### Rounding, decided once

**Nothing is rounded until it is displayed.** Conversion is a scalar multiply applied across a
200,000-iteration simulation; rounding inside that loop accumulates and makes two views of the same
report disagree. Magnitudes are converted **once**, before sampling; presentation rounds **once**,
at the end, half away from zero, to the currency's minor unit (2 for GBP/USD/EUR, 0 for JPY).

Half away from zero — not Go's default half-to-even — because a compliance figure should match what
a reader gets with a calculator.

### Where the conversion actually bites

Total Cost of Risk sums control costs (from the **pack**) with residual and premium (from the
**org**). Those two files can legitimately be denominated differently, so the report resolves
everything into the institution's own reporting currency *first*. Every threshold test and the tier
selection are ratios in that one currency, so **no verdict depends on the display currency**:

```bash
riskctl risk --org acme                  # figures in GBP, the institution's own
riskctl risk --org acme --currency USD   # same verdicts, converted at the last step
```

## Territory: a scenario need not be global

A UK-GDPR administrative fine is not a loss a US provider can incur, and pricing it into their
exposure inflates the number in a way an informed reader will catch. A scenario may scope itself to
jurisdictions, matched against the institution's existing `metadata.jurisdiction`:

```yaml
scenarios:
  - id: SCN-UNAUTH-CHANGE
    title: Agent lands an unreviewed change in production
    territories: ["UK"]                  # omit the field, or use ["*"], for global
    territory_note: UK-GDPR administrative exposure.
```

Omitting `territories` means **global**, which is what every scenario in the shipped packs is — so
this axis moves no existing figure until someone deliberately scopes one.

Filtering is **visible, not just applied**. The report prints every scenario with whether it counted
and *why*, because a total that silently omits scenarios is unexplainable — a reader cannot tell a
deliberate jurisdictional exclusion from a typo in a scenario ID:

```
  SCENARIO               COUNTS     TERRITORIES            CONTROLS
  UNAUTH-CHANGE          NO         [UK]                   AGT-003 AGT-004 AGT-005

  1 of 5 scenarios excluded from the exposure:
    SCN-UNAUTH-CHANGE — EXCLUDED: institution jurisdiction US is not within the
      scenario's territories [UK]
```

Out-of-territory controls are still evaluated for compliance — a control can be unmet whether or not
the loss it defends can happen locally — but they contribute no money and generate no deltas. An
institution matching *nothing* is reported explicitly, because a bare zero exposure otherwise reads
as "no risk" when it means "this pack prices nothing that can happen here".
