# Statutory penalties

Facts read from primary legislative text, with the article and the URL. These
are the `AC-STAT-*` anchor classes in [ANCHORS.md](ANCHORS.md#ac-stat-).
Confidence **A** throughout, because a fine ceiling written into a regulation
is a fact rather than an estimate.

Read [the calibration statement](README.md#the-calibration-statement) first.

## The one modelling rule

> **A statutory ceiling is a `max`. It is never a `mode`.**

A ceiling is the worst outcome the law permits, applied to the worst conduct
the law contemplates. Writing €35,000,000 into a `mode` prices the typical
breach of a documentation obligation at the maximum fine for a prohibited
practice. Every figure on this page belongs in the third slot of a triple and
in no other slot.

Two further rules follow from the dates column. A regime whose penalties have
not commenced cannot price above zero today, and the applicability date is the
citable reason why. A regime that sets a floor rather than a ceiling has no
usable `max` at European level at all.

## EU AI Act

Source: <https://artificialintelligenceact.eu/article/99/> and
<https://artificialintelligenceact.eu/article/101/>

| Provision | Ceiling | What it covers |
| :--- | :--- | :--- |
| Art. 99(3) | €35,000,000 or 7 per cent of worldwide annual turnover, whichever is higher | Prohibited practices under Art. 5 |
| Art. 99(4) | €15,000,000 or 3 per cent, whichever is higher | Most operator obligations, including **Art. 26 deployer obligations** and Art. 50 transparency |
| Art. 99(5) | €7,500,000 or 1 per cent, whichever is higher | Supplying incorrect, incomplete or misleading information |
| Art. 99(6) | The **lower** of the two figures, not the higher | Small and medium enterprises, including start-ups. The test inverts. |
| Art. 101 | 3 per cent of worldwide annual turnover or €15,000,000 | General-purpose AI model providers |

Art. 99(4) is the row that matters for this estate. The packs evaluate
deployer-side obligations, so the applicable ceiling is €15,000,000 or 3 per
cent, and not the headline €35,000,000 figure.

The Art. 99(6) inversion is the trap. For an SME the ceiling is the **lower**
of the absolute amount and the percentage. A model that always takes the higher
figure overstates the exposure of every small customer.

**Penalties apply from 2 August 2025.**

## NIS2 Directive

Source: <https://www.nis-2-directive.com/NIS_2_Directive_Article_34.html>

| Provision | Amount | What it covers |
| :--- | :--- | :--- |
| Art. 34(4) | **At least** €10,000,000 or 2 per cent of total worldwide annual turnover, whichever is higher | Essential entities |
| Art. 34(5) | **At least** €7,000,000 or 1.4 per cent, whichever is higher | Important entities |

Two features of this article change how it may be modelled.

The turnover base is the **group** turnover of the undertaking the entity
belongs to, not the entity's own. A subsidiary is priced on its parent.

The directive sets a **floor**, not a ceiling. Member States must provide for
at least these amounts, so a national implementation may be higher. The figures
above are therefore a lower bound on the `max`, which is an unusual shape and
must be stated wherever the figure is used.

## DORA

Source: <https://www.dora-info.eu/dora/article-35/>

| Who | Amount |
| :--- | :--- |
| Financial entities | **No European-level monetary ceiling.** Art. 50 leaves administrative penalties to Member States. |
| Critical ICT third-party service providers | Up to 1 per cent of average daily worldwide turnover, charged **daily for up to six months** |

This is the most frequently invented figure in the regulatory-risk market. **A
DORA fine figure for a deployer is an invention** unless the author read a
specific national implementation and cited it. There is no number to quote at
European level for a financial entity.

The critical-provider penalty is a daily periodic charge rather than a single
sum. A model that treats it as one fine understates it by up to the number of
days it ran.

The `dora` pack in this tree carries one placeholder check and prices at zero.
Given the above, zero is the correct figure rather than a gap.

## Cyber Resilience Act

Source: Regulation (EU) 2024/2847, Art. 64 and Art. 71. The pack's own
extraction of the text is in `policy/frameworks/cra/catalogue/`.

| Provision | Ceiling | What it covers |
| :--- | :--- | :--- |
| Art. 64 | €15,000,000 or 2.5 per cent of worldwide annual turnover, whichever is higher | Essential cybersecurity requirements and manufacturer obligations |
| Art. 64 | €10,000,000 or 2 per cent, whichever is higher | Other obligations |
| Art. 64 | €5,000,000 or 1 per cent, whichever is higher | Incorrect, incomplete or misleading information |

### The dates make the CRA pack's present pricing wrong

| Provision | Applies from |
| :--- | :--- |
| Ch. IV, notified bodies | 11 June 2026 |
| Art. 14, reporting obligations | 11 September 2026 |
| General application | **11 December 2027** |

Art. 71 carries the staged dates. The general obligations the `cra` pack
evaluates do not apply until 11 December 2027.

The three `cra` checks currently price to £256,514.43 of annual expected loss
between them, read from the pinned money golden.
**That is wrong by statute, not by calibration.** No penalty
attaches to those obligations today. The figure is recorded here rather than
changed, because moving it is a priced-figure decision and belongs to the
principal. The fix is a commencement date per regime, applied as a gate on the
secondary-loss term described in section 4 of
[the open decisions](../../docs/fair-methodology-open-decisions.md).

**This page does not implement that gate.** The dates above are the statutory
facts and nothing more. The enforcement mechanism is the date-gated
applicability metadata being added to the pack schema by a separate card. With
it in place, a regime whose obligations have not commenced prices at zero
because the data says so rather than because a document says so. These two
changes are one story. Read them together.

## UK regimes

`risk/org/acme.yaml` names UK-GDPR and PCI-DSS as its own regimes. UK-GDPR
administrative fines reach the higher of £17,500,000 or 4 per cent of global
annual turnover. PCI-DSS carries contractual scheme fines rather than statutory
ones, so it has no legislative ceiling to cite.

## Unverified rows

These are claims the research pass could not confirm. They stay marked.

| Claim | State |
| :--- | :--- |
| Whether any EU AI Act fine has yet been issued | **Unverified.** Nine mutually contradictory secondary sources, several apparently machine-generated, none official. No figure may be built on this. |
| The Digital Omnibus delay of high-risk obligations to 2 December 2027 | **Unverified.** The dates in the tables above are the citable ones until this is read from an official source. |
| Observed fine levels, as opposed to ceilings | **Partly unobtained.** See `AC-REG-OBSERVED` in [ANCHORS.md](ANCHORS.md#ac-reg-observed). The GDPR median and per-country breakdown were not retrieved. |

## Related

- [ANCHORS.md](ANCHORS.md), the anchor-class registry
- [The calibration statement](README.md#the-calibration-statement)
- [FAIR methodology: the open decisions](../../docs/fair-methodology-open-decisions.md)
