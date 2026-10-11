# `risk/modulation/` — proposed, not loaded

Nothing in this directory is read by any binary. It is a design, written down
so the argument about multipliers happens before a multiplier ships.

The question it answers. A single pack of controls is sold to a UK retailer, a
German bank and a US hospital group. What may legitimately differ between them,
and what would be invention?

Read [the anchor-class registry](../../policy/frameworks/ANCHORS.md) first. The
confidence letters below are from that page.

## The answer in one table

| Dimension | Verdict | Why |
| :--- | :--- | :--- |
| **Revenue band** | **Ship it. The strongest axis there is.** | `AC-LEF-ORG-BASE` is a size effect and nothing else. Firms above $100bn revenue are about 32 times more likely to suffer multiple incidents in a year, and the largest corporations run about 620 times the per-organisation rate. Confidence **B**. |
| **SMB magnitude floor** | Ship it, as a floor. | A small firm's loss does not scale down indefinitely. The researched floor is about 25 per cent of annual revenue. Confidence **C**. |
| **Sector** | Ship it, **bounded at 4×**. | Ordering is healthcare and finance above technology, above public sector, above extractive. Confidence **C**. |
| **Country** | **Refuse.** | There is no evidence that the same incident costs more in France than in Germany, net of regime and sector. A country magnitude multiplier would be invention. |
| **Sector × an unanchored AI family** | **Refuse.** | Two layers of judgement collapsed into one number, where the inner layer is already confidence **D**. |

Revenue band goes ahead of sector. That is the ordering the evidence supports,
and it is the opposite of how the market sells.

## Why the sector multiplier is bounded at 4×, and not 76×

IRIS reports a raw count ratio of about 76 between the most and least affected
sectors. **That figure must not become a multiplier.** It is confounded twice
over, and both confounds push the same way.

- **Organisation count.** A sector with more organisations in the dataset
  produces more incidents in the dataset. The ratio is partly a census.
- **Disclosure duty.** Healthcare over-reports because HIPAA compels it. The
  sector looks worse because it is more honest, which is the opposite of what a
  risk multiplier should reward.

So the ordering survives and the magnitude does not. 4× is a bound, chosen to
keep the ordering visible without letting a census artefact drive a price.

## The sector validation this estate already has

Lead with this rather than with the published sector tables. It is better
evidence and it is already in the repository.

[`risk/org/acme.yaml`](../org/acme.yaml) and
[`risk/org/ludlow-health.yaml`](../org/ludlow-health.yaml) each carry a
`transfer.annual_premium`. That is an underwriter pricing substantially the
same controls, for two institutions in different sectors, with their own money
at stake. A premium differential is a market-tested sector signal. A published
incident count is not.

Acme's note says it plainly. The underwriter prices substantially the same
controls this pack enforces.

The two premiums are £48,000 for Acme, a UK retailer, against £210,000 for
Ludlow, a healthcare provider. That is about 4.4×, and it is a sector signal
priced by someone with money at risk. It also sits close to the 4× bound
proposed above, which was chosen independently. Note what the premium ratio
does **not** isolate. Limit and retention differ too, at £5m against £20m and
£100,000 against £500,000, so the ratio is not a clean sector coefficient. It
is better evidence than a published incident count and it is still not a
measurement of the thing a multiplier would claim.

## What country actually changes

Two things, and neither is a magnitude.

- **Regime selection.** Which of the `regimes` entries applies at all. A UK
  entity faces UK-GDPR and not the EU AI Act deployer obligations, and the
  statutory ceilings in
  [PENALTIES.md](../../policy/frameworks/PENALTIES.md) differ accordingly.
- **Reporting currency.** Which currency the figures are denominated in, which
  this repository already handles through `risk/fx/rates.yaml`.

Both are selection, not scaling. A country field that picks a regime is honest.
A country field that multiplies a loss is not.

## The proposed shape

One file per dimension. Every factor carries four fields, and the fourth is the
one that makes the design work.

```yaml
# risk/modulation/revenue-band.yaml   (PROPOSED — loaded by nothing)
apiVersion: osramp.controlplane.io/v1alpha1
kind: RiskModulation
dimension: revenue-band
factors:
  - key: under-50m
    factor: 0.4
    applies_to: frequency
    anchor: AC-LEF-ORG-BASE
    confidence: B
    note: >-
      Size effect only. IRIS supports the direction and the ordering. It does
      not support this coefficient, which is interpolated.
  - key: over-100bn
    factor: 6.0
    applies_to: frequency
    anchor: AC-LEF-ORG-BASE
    confidence: B
    note: >-
      Damped from the published 32x multiple-incident likelihood. The published
      figure is a likelihood of multiple incidents, not a rate multiplier.
```

| Field | What it carries |
| :--- | :--- |
| `factor` | The multiplier. |
| `applies_to` | `frequency` or `magnitude`. Never both. A factor that claims both is two factors. |
| `anchor` | An anchor class from [ANCHORS.md](../../policy/frameworks/ANCHORS.md), or the literal `none`. |
| `confidence` | One of A, B, C, D. The same vocabulary as the registry. |

## The rule that makes invention machine-checkable

> The engine **refuses** any factor at `confidence: D` unless the organisation
> file opts in to it by name.

That single rule converts "which of these multipliers are invented" from a
documentation question into a test. A D factor is a declared opinion, and
applying a declared opinion to a customer's number should take a signature.
The opt-in belongs in the organisation file, beside the appetite statement,
because it is an institutional decision.

The refusal must be an error and not a skip. A skipped factor and an applied
factor of 1.0 are indistinguishable in the output, which is the same defect as
a zero that means "unknown". That defect is section 2 of
[the open decisions](../../docs/fair-methodology-open-decisions.md).

## What is not proposed here

No implementation. No loader. No schema change. The organisation-file fields
that would carry the opt-in are being added by another card, and this design
deliberately does not depend on them.
