# The anchor-class registry

Every priced check in this tree names the anchor classes its triples were
calibrated against. This page is the registry of those classes. It is the
answer to one question a reviewer asks about any figure the engine prints.
What published thing is this number standing next to, and what does that
published thing actually say?

Read [the calibration statement](README.md#the-calibration-statement) first.
Nothing on this page changes it. An anchor class is a reference class the
estimate can be argued with. It is not a claim that a published figure was
used verbatim.

## Why this file is here and not in `risk/`

The anchor classes are cited from three places. The `derivation` block on each
priced check in `policy/frameworks/*/v*/framework.json`, the pack pages beside
those files, and the `provenance` prose in `risk/org/acme.yaml`.

`risk/` holds institution-owned data. One file per organisation, loaded by
`tools/riskctl`. An anchor class is estate-wide and is loaded by nothing. A new
anchors directory under `risk/` would read as engine input. It would invite a
loader that does not exist. So the registry sits beside the packs that cite it,
as Markdown, and the pack data carries the class name as a string.

## The confidence vocabulary

Four letters. Use these and no others. A derivation that omits a confidence
letter is unfinished.

| Letter | Meaning |
| :--- | :--- |
| **A** | Primary legislative text. A fact, not an estimate. A fine ceiling or an applicability date read from the regulation. |
| **B** | A published empirical loss or frequency dataset. Real incidents, counted or priced by someone who saw them. |
| **C** | A prevalence proxy. The source measures how often the misconfiguration is present, not how often it causes a loss. |
| **D** | No dataset exists. Judgement only. The figure is review-bait and nothing more. |

The letter grades the **weakest** link in the derivation, never the strongest.
A frequency built from a B base rate and a D conditional factor is D.

## What a priced triple actually claims

This is the single most important statement on this page. Read it before
quoting any pack figure next to any published loss figure.

The pack `riskTriple` modes run from about £5,000 to about £120,000. Published
single-event loss medians are one to two orders of magnitude above that. The
Cyentia IRIS 2022 study puts the typical single event at about $266,000 and the
top five per cent above $52,000,000. IRIS 2025 reports the median moving from
about $190,000 to about $3,000,000 over fifteen years.

A pack mode of £25,000 is therefore **not** a loss event. It is the
**attributable share of one loss event assigned to one failed control**. The
event-level figures in this estate are the `SCN-*` magnitudes in
`risk/org/acme.yaml`, which run from £60,000 to £4,000,000. Those are the loss
events. The pack triples are slices of them.

Nothing in the repository stated this before 2026-10-11. A reviewer comparing a
pack mode against an IRIS median reads a hundred-fold error. The error is in
the comparison, not in the figure. Both numbers are defensible. They are
answers to different questions.

Two rules follow, and both are testable by reading the data.

- A pack `riskTriple` must name which `SCN-*` scenario it is a share of.
- A pack `riskTriple` mode must be smaller than that scenario's mode. A share
  cannot exceed its whole.

## The frequency decomposition

A bare loss event frequency cannot be argued with. A reviewer who disagrees
with 1.5 events per year has to re-litigate the whole estimate. So record each
priced frequency as a product with one isolated judgement factor.

```
LEF = P_org × S_path × C_check

  P_org    org-year base rate of any cyber loss event    AC-LEF-ORG-BASE    B
  S_path   share of loss events running through this
           control's attack surface                      AC-ATTRIB-*        B
  C_check  conditional contribution of THIS
           misconfiguration, informed by prevalence      AC-PREV-*          D
```

`C_check` is the judgement. It is the only term a reviewer needs to attack, and
attacking it does not require disputing the base rate. That separation is the
whole defensibility gain. It costs three lines of data per check.

The product is not reconciled against the shipped `freqTriple` values in this
change. Documenting the basis comes first, so a later retune is a reviewable
diff against a stated position rather than a fresh set of round numbers.

## The classes

### AC-LEF-ORG-BASE

| | |
| :--- | :--- |
| **Covers** | The organisation-year base rate of any cyber loss event. The `P_org` term. |
| **Source** | Cyentia IRIS 2022, <https://www.cyentia.com/iris-2022/>, and IRIS 2025, <https://www.cyentia.com/iris-2025/> |
| **Supports** | That the base rate scales hard with organisation size. Firms above $100bn revenue are about 32 times more likely to suffer multiple incidents in a year. The largest corporations run about 620 times the per-organisation rate. Annual likelihood has nearly quadrupled since 2008. |
| **Does not support** | A base rate for any named organisation. It does not support a per-control frequency, and it does not support a sector rate. The multipliers are relative, not absolute. |
| **Confidence** | **B** |

### AC-MAG-EVENT

| | |
| :--- | :--- |
| **Covers** | Event-level loss magnitude. The `SCN-*` triples in `risk/org/acme.yaml`. |
| **Source** | Cyentia IRIS 2022, <https://www.cyentia.com/iris-2022/>, and IRIS 2025, <https://www.cyentia.com/iris-2025/> |
| **Supports** | A typical single event near $266,000 and a top-five-per-cent tail above $52,000,000 for the 2022 population. A median moving from about $190,000 to about $3,000,000 across fifteen years in the 2025 edition. |
| **Does not support** | Mixing the two editions. The $266,000 and the $3,000,000 are different statistics over different populations and different periods. Quoting them in one sentence is a methodology error. It also does not support a per-control magnitude, which is the attribution question above. |
| **Confidence** | **B** |

### AC-MAG-ANTI-PATTERN

This class exists to record a method that must **not** be used. It is listed
as an anchor class so that a derivation can point at it and say what it avoided.

| | |
| :--- | :--- |
| **Covers** | Per-record cost multiplication. Records breached times a published cost per record. |
| **Source** | Cyentia, *Exaggeration per record*, <https://www.cyentia.com/exaggeration-per-record/> |
| **Supports** | That a single per-record cost figure carries about a 74 per cent chance of being wrong by a factor of two or more, and about a 37 per cent chance of being wrong by a factor of ten or more. Those odds hold **inside the range the figure was drawn from**, which is the part people skip. |
| **Does not support** | Any use of a per-record cost. The IBM and Ponemon per-record figures are cited here only as the method to avoid, never as an input. |
| **Confidence** | **B** on the error rates. The method it describes is not usable at any confidence. |

### AC-ATTRIB-CRED

The strongest published attribution evidence in the registry, and the reason
the credential-exposure family is the template for every other family.

| | |
| :--- | :--- |
| **Covers** | The `S_path` term for credential-exposure controls. |
| **Source** | Cyentia IRIS Risk Retina threat-event analysis, <https://www.cyentia.com/press-release-information-risk-insights-study-iris-risk-retina-threat-event-analysis/> |
| **Supports** | That 98 per cent of financial losses from cyber events involve compromise of valid account credentials. That servers are compromised about three times more often than user devices and carry more than ten times the loss. |
| **Does not support** | A share for any one credential control. "Credentials were involved" is not "this service-account token was the path". The step from 98 per cent to a single check is `C_check`, and that step is judgement. |
| **Confidence** | **B** |

### AC-ATTRIB-ENTRY

| | |
| :--- | :--- |
| **Covers** | The `S_path` term for initial-access and entry-vector controls. |
| **Source** | Verizon DBIR, 2026 edition. |
| **Supports** | The **ordering** of entry vectors only. |
| **Does not support** | Any percentage. **The 2026 DBIR percentages are rendered as images in the report and were NOT verified in this work.** No figure from that edition is quoted anywhere in this repository, and none may be added without reading the source. |
| **Confidence** | **D** as used here, because only an unquantified ordering survives verification. |

### AC-PREV-K8S

| | |
| :--- | :--- |
| **Covers** | The prevalence input to `C_check` for Kubernetes and cloud misconfiguration controls. |
| **Source** | Datadog, State of Cloud Security, October 2025, <https://www.datadoghq.com/state-of-cloud-security/> |
| **Supports** | That 39 per cent of EKS, 34 per cent of AKS and 54 per cent of GKE clusters expose the API server. That 13 per cent of EKS clusters carry a dangerous node role. That 39 per cent of organisations still use long-lived IAM users. |
| **Does not support** | **A loss-event rate.** Prevalence counts how often a weakness is present, not how often it costs money. It also does not support a pod-spec conclusion. These measurements are of cloud IAM and cluster endpoints, and most checks in this estate read pod-template fields instead. |
| **Confidence** | **C** |

### AC-EXPLOIT

| | |
| :--- | :--- |
| **Covers** | Whether a weakness class is known to be exploited in the wild. A qualifier on `C_check`, never a frequency. |
| **Source** | CISA Known Exploited Vulnerabilities catalogue, <https://www.cisa.gov/known-exploited-vulnerabilities-catalog> |
| **Supports** | That 1,739 entries were in the catalogue at catalogue version 2026.10.08. |
| **Does not support** | A rate. The catalogue has no denominator and no per-organisation exposure. Presence in it is a binary fact about a vulnerability, not a probability about an estate. |
| **Confidence** | **B** for the count. **D** for any frequency derived from it. |

### AC-AI-EVENT-COUNT

| | |
| :--- | :--- |
| **Covers** | Countable AI incidents. The only quantified AI anchor available. |
| **Source** | AI Incident Database, <https://incidentdatabase.ai/> |
| **Supports** | That about 1,741 incidents are recorded. |
| **Does not support** | **Any price, and any rate.** The database carries no losses and no denominator. There is no population of AI deployments to divide by, so a count cannot become a frequency. |
| **Confidence** | **C** for the count. Unusable for magnitude. |

### AC-AI-LOSS

This class is deliberately **empty**. It is registered so that a derivation can
cite the absence rather than leave a gap a reader fills in.

| | |
| :--- | :--- |
| **Covers** | Loss magnitude and frequency for AI-specific threat events. Prompt injection, model exfiltration, unauthorised agent action. |
| **Source** | None. |
| **Supports** | Nothing. **No public or commercial dataset prices these events.** |
| **Does not support** | Every AI-guardrail triple in this estate. Each one is judgement against an empty reference class. |
| **Confidence** | **D**, and that letter is the whole content of the class. |

### AC-STAT-\*

The statutory-penalty classes. One per regime, all of them read from primary
legislative text, all of them confidence **A**. They are tabulated with their
article citations in [PENALTIES.md](PENALTIES.md), which also carries the one
modelling rule that matters. **A statutory ceiling is a `max`, never a `mode`.**

| Class | Regime | Where |
| :--- | :--- | :--- |
| `AC-STAT-AI-ACT` | EU AI Act Art. 99 and Art. 101 | [PENALTIES.md](PENALTIES.md#eu-ai-act) |
| `AC-STAT-NIS2` | NIS2 Directive Art. 34 | [PENALTIES.md](PENALTIES.md#nis2-directive) |
| `AC-STAT-DORA` | DORA Art. 50 and Art. 35 | [PENALTIES.md](PENALTIES.md#dora) |
| `AC-STAT-CRA` | Cyber Resilience Act Art. 64 | [PENALTIES.md](PENALTIES.md#cyber-resilience-act) |

### AC-REG-OBSERVED

| | |
| :--- | :--- |
| **Covers** | Observed regulatory fines, as distinct from statutory ceilings. |
| **Source** | GDPR Enforcement Tracker, <https://www.enforcementtracker.com/>, read live on 2026-10-11. |
| **Supports** | 3,313 recorded cases totalling about €7.56bn across 32 countries. The largest single fine is €1.2bn against Meta Platforms Ireland. The most active authority by case count is Spain, with 1,079. |
| **Does not support** | A central estimate. **The median and the per-country breakdown are loaded by the site's API and were NOT obtained in this work.** The €2.28m arithmetic mean implied by the totals is the wrong central measure for a distribution containing a €1.2bn outlier, and must not be used. |
| **Confidence** | **B** for the four counted facts. The absent median is the figure a model would actually want. |

### AC-APPETITE

| | |
| :--- | :--- |
| **Covers** | Risk-appetite and governance convention. The `appetite` and `risk_load` blocks in `risk/org/acme.yaml`. |
| **Source** | BCBS d515, <https://www.bis.org/bcbs/publ/d515.htm>. Open FAIR Body of Knowledge, <https://www.opengroup.org/open-fair>. |
| **Supports** | That a governed appetite statement carries an approver, an approval date and a review date. That FAIR's standard output is a loss exceedance curve rather than a scalar. |
| **Does not support** | Any number. **ISO 31000 is paywalled and was not read in this work.** It may be cited as a convention and must never be quoted. |
| **Confidence** | **A** for the two readable sources, as convention rather than as measurement. |

## Family ranges

Researched attribution shares and loss event frequencies per control family.
These are recorded as the stated basis for a later retune. **No shipped triple
value was changed to match them in this change**, apart from the AI
governance and documentation family described below.

| Family | Attribution share | LEF | Anchors | Confidence |
| :--- | :--- | :--- | :--- | :--- |
| Kubernetes hardening | 0.01 to 0.08 | 0.3 to 2.0 | `AC-PREV-K8S`, `AC-LEF-ORG-BASE` | C |
| Host-namespace and container escape | 0.10 to 0.35 | 0.1 to 1.5 | `AC-PREV-K8S`, `AC-EXPLOIT` | C |
| **Credential exposure** | **0.15 to 0.45** | **0.5 to 4.0** | `AC-ATTRIB-CRED`, `AC-LEF-ORG-BASE` | **B** |
| Supply chain | 0.10 to 0.30 | 0.2 to 3.5 | `AC-EXPLOIT`, `AC-LEF-ORG-BASE` | C |
| AI guardrails | 0.10 to 0.40 | `unanchored` | `AC-AI-LOSS`, `AC-AI-EVENT-COUNT` | D |

Credential exposure is the only family with strong published attribution, and
it is therefore the stated template for the others. `sa-token-automount-disabled`
in the `cis-kubernetes` pack already carries a frequency triple of 0.5, 1.5 and
4.0. That is the right shape and it sits inside the researched range. Every
other family should be retuned toward that pattern rather than away from it.

The AI guardrail frequencies are marked `unanchored` with confidence D. There
is no dataset. A number there is a declared opinion, and the derivation says so.

## AI governance and documentation is not on this path

One family was moved rather than documented, because its placement was a
category error rather than a calibration disagreement.

Eight controls carried technical loss frequencies. Annex IV technical
documentation, training-data provenance, automatic record keeping,
user-instruction transparency, synthetic-content marking, model registry entry,
model version pinning and decision explainability metadata.
`annex-iv-technical-documentation` carried a
frequency mode of 1.5, which asserts 1.5 documentation-caused loss events per
year. That is not a thing that happens.

These eight controls defend against a **penalty**, not against a breach. The
penalty path needs the secondary-loss model described in section 4 of
[the open decisions](../../docs/fair-methodology-open-decisions.md), which this
engine does not have. Until it does, the honest figure for them on the
technical path is zero, declared rather than implied. Each is now listed in its
pack's `catalogue/unpriced.tsv` with the reason code
`penalty-path-not-technical`.

Their statutory ceilings are facts and are recorded in
[PENALTIES.md](PENALTIES.md). A ceiling is a `max`. Writing one into a `mode`
would price every documentation gap at the worst case the law allows.

## Open questions

Carried verbatim from the research pass. Every item here is **unverified** and
must stay marked until someone reads the source.

| Item | State |
| :--- | :--- |
| A "$10M" per-record overstatement figure attributed to Cyentia in an earlier brief | **Not Cyentia's published framing and could not be found.** Their published form is the 74 per cent and 37 per cent error-probability pair in `AC-MAG-ANTI-PATTERN`. The "$10M" figure is withdrawn. |
| Verizon DBIR 2026 entry-vector percentages | **Unverified.** Rendered as images in the report. Ordering only. |
| Whether any EU AI Act fine has yet been issued | **Unverified.** Nine mutually contradictory secondary sources were found, several of them apparently machine-generated, none official. |
| The Digital Omnibus delay of high-risk obligations to 2 December 2027 | **Unverified.** Treat the dates in [PENALTIES.md](PENALTIES.md) as the citable ones. |
| ISO 31000 text | **Not read.** Paywalled. Cite as convention, never quote. |
| The GDPR fine median and the per-country breakdown | **Not obtained.** Loaded by the enforcement tracker's API. The arithmetic mean is not a substitute. |

## Related

- [The calibration statement](README.md#the-calibration-statement)
- [PENALTIES.md](PENALTIES.md), the statutory-penalty table
- [FAIR methodology: the open decisions](../../docs/fair-methodology-open-decisions.md)
- [`risk/README.md`](../../risk/README.md), the institution side of the split
