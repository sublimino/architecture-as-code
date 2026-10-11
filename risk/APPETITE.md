# Risk appetite — what generalises and what collapses

`risk_load` generalises well. A scalar `tolerance` does not. This page says why
and proposes the backward-compatible fix.

Read [the calibration statement](../policy/frameworks/README.md#the-calibration-statement)
and the `AC-APPETITE` entry in
[ANCHORS.md](../policy/frameworks/ANCHORS.md#ac-appetite). Nothing here is
loaded by any binary.

## `risk_load` is fine

It is a single institutional capital parameter, reviewed annually, and the
organisation file is the right owner. `risk/org/acme.yaml` sets 0.15 and
`risk/org/ludlow-health.yaml` sets 0.25, which is exactly the kind of
divergence the split exists to express.

One thing is missing from it, and it is small. **The basis is not stated.**
`carried` is the tail statistic plus the load, and nothing in the file says
which tail statistic. Write `basis: TVaR95` beside the load, so a reader knows
what is being loaded rather than inferring it from Go.

Note the live inconsistency this makes visible. Three code paths apply 0.10
rather than the 0.15 the only organisation file declares. That is section 5 of
[the open decisions](../docs/fair-methodology-open-decisions.md) and it is
not fixed here.

## A scalar `tolerance` collapses a distribution to a point

This is the real finding. Acme declares `tolerance: 25000`, meaning £25,000 of
annualised expected loss per control.

Consider two postures that both produce an annualised expected loss of £25,000.

| Posture | Shape |
| :--- | :--- |
| A | Frequent small losses. About 25 events a year at about £1,000 each. |
| B | A 2 per cent chance of a single £1,250,000 loss. |

A scalar tolerance cannot tell them apart. **A bank treats them completely
differently.** Posture A is an operating cost and goes in the budget. Posture B
is a capital and solvency question and goes to a board committee.

That distinction is the entire reason the engine runs a Monte Carlo. The
simulation produces a distribution and the appetite statement reads one number
off it. The information the simulation exists to produce is discarded at the
last step.

## The proposed form

A loss exceedance statement, which is the standard FAIR output and the artefact
a risk committee recognises on sight.

```yaml
# PROPOSED. Loaded by nothing.
appetite:
  # The degenerate fallback. Kept so nothing breaks and so the
  # Acme-versus-Ludlow comparison keeps working unchanged.
  tolerance: 25000
  basis: TVaR95

  # The real statement. Read as: the annual loss must not exceed this
  # amount with more than this probability.
  exceedance:
    - probability: 0.20
      amount: 50000
    - probability: 0.05
      amount: 400000
    - probability: 0.01
      amount: 1000000

  # BCBS d515 governance. An appetite statement without an approver
  # is a preference.
  approved_by: "Acme Risk Committee"
  approved_on: 2026-10-11
  review_due: 2027-10-01
```

Posture A and posture B now separate. A breaches no row. B breaches the 1 per
cent row at £1,250,000 against £1,000,000.

### Backward compatibility is the design constraint

`tolerance` stays, and it stays authoritative when no `exceedance` block is
present. The scalar is the degenerate case of the curve, not a competing idea.
Both organisation files keep working untouched, and the
Acme-versus-Ludlow comparison that the demo turns on is unaffected.

Everything needed to evaluate the curve already ships. `Engine.RunDistribution`
returns the sorted vector of simulated annual losses and `fair.Percentile`
reads any level off it. The remaining work is the comparison and the route.
Section 6 of [the open decisions](../docs/fair-methodology-open-decisions.md)
makes the same observation. It calls the exceedance curve the item that buys
the most credibility for the least work.

### The governance fields

Three fields, from `AC-APPETITE`.

| Field | Why |
| :--- | :--- |
| `approved_by` | BCBS d515 expects a named approver for an appetite statement. Without one the number is a preference. |
| `approved_on` | An appetite set before the last two incidents is not the current appetite. |
| `review_due` | Makes staleness detectable rather than arguable. A gate can read it. |

The sources are BCBS d515, <https://www.bis.org/bcbs/publ/d515.htm>, and the
Open FAIR Body of Knowledge, <https://www.opengroup.org/open-fair>. **ISO 31000
is paywalled and was not read.** It may be cited as a convention and must never
be quoted.

## What is not proposed here

No implementation, no loader, no schema change, and no edit to either
organisation file. The organisation-file appetite fields are being extended by
another card, and this design deliberately does not depend on that work.
