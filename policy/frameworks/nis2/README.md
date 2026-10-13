# nis2

**This pack assesses nothing. It contains one check, that check is the literal
`false`, and it is never evaluated.**

| Version | Checks | Evaluated | Priced | Divisions cited | Anchored |
|---------|-------:|----------:|-------:|----------------:|----------|
| v1.0    | 1      | 0         | 0      | 2               | yes |

A scan of `nis2` returns one row with verdict `not_evaluated`. It contributes
nothing to the failed, errored or exposure totals, and prices at £0.00. Zero is
the correct figure, not a missing one. The check carries an explicit all-zero
`riskTriple` and `freqTriple` so the zero cannot be mistaken for "no risk".
`compliance_money_test.go` pins `nis2/v1.0` in the all-placeholder group,
separately from the packs whose zeros are a genuine finding.

Do not read this pack as NIS2 coverage. It is a reserved identifier with a
correct citation and no assessment behind it.

## Ground truth

**Directive (EU) 2022/2555** was adopted by the European Parliament and the
Council on 14 December 2022. It sets measures for a high common level of
cybersecurity across the Union. It amends Regulation (EU) No 910/2014 and Directive (EU)
2018/1972, and repeals Directive (EU) 2016/1148 (NIS 2 Directive). OJ L 333/80,
27.12.2022. ELI: `http://data.europa.eu/eli/dir/2022/2555/oj`.

Anchored against the publisher's own XHTML by
`../cra/catalogue/anchor-test.sh`, using the 49-division extract (46 articles,
3 annexes) at `../cra/catalogue/eu-2022-2555-nis2.tsv`. Provenance:
`../cra/catalogue/PROVENANCE.md`.

### Verified citations

| Control | Citation | Heading as published | Verdict |
|---------|----------|----------------------|---------|
| `nis2-cybersecurity`, `NIS2-1.0` | `Article 21` | Cybersecurity risk-management measures | correct |
| `NIS2-1.0` | `Article 22` | Union level coordinated security risk assessments of critical supply chains | correct |

`NIS2-1.0` is named "Cybersecurity Risk Management Measures", while Article 21's
published heading is "Cybersecurity risk-management measures". They have the
same scope, so the mapping is correct. The difference is capitalisation and
hyphenation. The anchor test holds the README to the published spelling exactly
so a real scope drift could not hide behind a cosmetic one.

The check id `nis2-supply-chain-risk` is also accurate. **Article 21(2)(d)**
requires measures covering "supply chain security, including security-related
aspects concerning the relationships between each entity and its direct
suppliers or service providers". Furthermore, Article 21(3) requires entities to take
into account the coordinated risk assessments of critical supply chains
carried out under **Article 22(1)**.

No fabricated or mis-numbered citation was found, and none could have been:
before this work the pack carried no citation at all. Note the trap avoided:
NIS2's own **Annex III is a correlation table** full of "Article N" strings. A
text-pattern extraction of this act therefore finds 73 apparent articles where
there are 46. The catalogue keys on the publisher's `oj-ti-art` markup instead, which
is why the extract says 46.

## A NIS2 finding is a claim about 27 national regimes

NIS2 is a **Directive**, not a Regulation. It does not bind entities directly.
Instead, it obliges Member States to impose measures. The binding obligation on
any given entity is the one in its Member State's transposing law (transposition
deadline 17 October 2024, Article 41). Article 21(1) is addressed to Member
States — "Member States shall ensure that essential and important entities take
appropriate and proportionate … measures". Article 21(5) leaves the
technical and methodological detail to Commission implementing acts for some
sectors.

So a product line reading "NIS2: compliant" is asserting something about
27 national regimes that may each differ in detail. Moreover, the proportionality
test in Article 21(1) turns on the entity's size, exposure and risk profile.
This is worth stating because, unlike the `cra` pack, a future `nis2` pack
cannot be made true by reading the Directive alone.

## What a user actually sees — and it is not this

**Found, and outside this pack's ownership to fix.** Identical to the `dora`
case. The detail and file references are in `../dora/README.md` under "What a
user actually sees". In summary a user is shown `nis2` as:

- a framework with `control_count: 1` and an invented control named
  "Cybersecurity Risk Management Measures"
  (`fe-signalloom/src/api_compat.py` ~7006-7015).
- a red **`fail`** badge at "0/1 controls passing (0%)"
  (`dashboard-signalloom/src/pages/CompliancePolicyPage.tsx` ~631), because
  `passedControls === totalControls` is false for a never-evaluated check.
- a toggleable row in the settings framework picker
  (`src/views/Settings.tsx` ~748-750).
- a directory entry indistinguishable from a real pack on the policy-engine
  framework-catalogue endpoint (`compliance.go` ~279-314).

Neither `FrameworkResponse` nor `PolicyFrameworkSummaryResponse` has a field
that could carry `status: placeholder` or `notEvaluated`, and both are
`extra="forbid"`. The dashboard has no such field either. The engine's scan and
summary wire format is correct and is where the honest value already exists.

Not fixed here, all of it being outside `policy/frameworks/**`. Unlike `dora`,
`nis2` has no fabricated demo row in `ui/windows/policy-posture.js`.

## Why there is nothing to check yet

Article 21(2) is a list of ten management-system obligations. These cover risk analysis
policies, incident handling, business continuity, supply chain security, and
secure acquisition and development. They also cover effectiveness assessment, cyber hygiene
and training, cryptography policy, HR security and access control, and MFA.
Nine of the ten are organisational facts evidenced by policy documents, not by
anything a cluster scan can observe. The proportionality test also means the
right answer for a given entity is not derivable from a manifest.

The one with a real technical surface is Article 21(2)(j), "the use of
multi-factor authentication or continuous authentication solutions". It is not
implemented. The `nist-800-53` pack records the trap waiting for anyone who
implements it: its `mfa-spiffe-svid-required` check evaluates a single credential
(`svid_presented == true`) and calls it multifactor. Do not repeat that here.

Nothing should be added without calibrated risk and frequency triples, which
are a principal decision and never a pack author's.

## Conformance

Three integration fixtures exist and each expects `not_evaluated` for the one
check, which is the only expectation the harness permits for a placeholder
(`frameworks_conformance_test.go`, `validatePack`). The coverage gate correctly
does not demand pass and fail fixtures for an all-placeholder pack.

## Pricing coverage

The table below is produced from `framework.json`. It is not typed by hand.
`make policy-pricing-counts` fails if it drifts from the packs.

A check is priced when its `freqTriple` has a non-zero `min`, `mode`, or `max`.
A check with no frequency triple, or an all-zero one, is unpriced. An unpriced
check contributes GBP 0.00 to every reported total however often it fails. That
state is allowed, because a loss magnitude with no calibrated frequency is not a
price. It is not a small-print detail, because a reader who adds up a scan gets
a total over the priced checks only.

### The NIS2 amounts are a floor, not a ceiling

This pack holds one placeholder check and prices at zero. Zero is correct
rather than missing.

NIS2 Art. 34(4) requires **at least** €10,000,000 or 2 per cent of total
worldwide annual turnover for an essential entity, and Art. 34(5) at least
€7,000,000 or 1.4 per cent for an important entity. The turnover base is the
**group** turnover, not the entity's own. The directive sets a floor, so a
national implementation may go higher. Citations are in
[PENALTIES.md](../PENALTIES.md#nis2-directive).

A floor is an unusual shape for a `max` and must be stated wherever the figure
is used. The anchor-class registry is [ANCHORS.md](../ANCHORS.md).

Read [the calibration statement](../README.md#the-calibration-statement) before you quote
any figure in this table or any figure the engine produces from this pack.

<!-- pricing-counts:begin -->
| Version | Checks | Priced | Unpriced | Placeholder |
| :--- | ---: | ---: | ---: | ---: |
| `v1.0.0` | 1 | 0 | 1 | 1 |
| **Pack total** | **1** | **0** | **1** | **1** |

An unpriced check contributes GBP 0.00 to every total however often it
fails. Of 1 check(s) on this page, 0 are priced and 1 are not.
Written by `policy/frameworks/pricing-counts-test.sh`. Do not edit by hand.
<!-- pricing-counts:end -->
