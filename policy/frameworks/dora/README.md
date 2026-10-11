# dora

**This pack assesses nothing. It contains one check, that check is the literal
`false`, and it is never evaluated.**

| Version | Checks | Evaluated | Priced | Divisions cited | Anchored |
|---------|-------:|----------:|-------:|----------------:|----------|
| v1.0    | 1      | 0         | 0      | 2               | yes |

A scan of `dora` returns one row with verdict `not_evaluated`, contributes
nothing to the failed, errored or exposure totals, and prices at £0.00. Zero is
the correct figure here, not a missing one: the check carries an explicit
all-zero `riskTriple` and `freqTriple` precisely so that nobody has to guess
whether the zero means "no risk" or "no data". `compliance_money_test.go`
pins `dora/v1.0` in the all-placeholder group for that reason, separately from
the four packs whose zeros are a genuine finding.

Do not read this pack as DORA coverage. It is a reserved identifier with a
correct citation and no assessment behind it.

## Ground truth

**Regulation (EU) 2022/2554** of the European Parliament and of the Council of
14 December 2022 on digital operational resilience for the financial sector and
amending Regulations (EC) No 1060/2009, (EU) No 648/2012, (EU) No 600/2014,
(EU) No 909/2014 and (EU) 2016/1011 (DORA). OJ L 333/1, 27.12.2022. ELI:
`http://data.europa.eu/eli/reg/2022/2554/oj`.

Anchored against the publisher's own XHTML by
`../cra/catalogue/anchor-test.sh`, using the 64-article extract at
`../cra/catalogue/eu-2022-2554-dora.tsv`. Provenance:
`../cra/catalogue/PROVENANCE.md`. DORA has no annexes.

### Verified citations

| Control | Citation | Heading as published | Verdict |
|---------|----------|----------------------|---------|
| `dora-resilience` | `Article 5` | Governance and organisation | correct |
| `dora-resilience`, `DORA-1.0` | `Article 6` | ICT risk management framework | correct |

`DORA-1.0` is named "ICT Risk Management Framework" and Article 6's published
heading is "ICT risk management framework" — the same scope, so the mapping is
correct and not a near-miss of the kind found in the `nist-800-53` pack. Both
articles sit in Chapter II, "ICT risk management". Article 6(1) requires a
financial entity to have "a sound, comprehensive and well-documented ICT risk
management framework".

No fabricated or mis-numbered citation was found, and none could have been:
before this work the pack carried no citation at all.

## What a user actually sees — and it is not this

**Found, and outside this pack's ownership to fix.** The engine models this
pack honestly and every consumer above it drops the distinction. A user is
shown `dora` as a live, selectable, assessed framework on every surface:

| Surface | What it shows | Evidence |
|---------|---------------|----------|
| fe `GET /compliance/frameworks` | `dora` with `control_count: 1` and an invented control named "Protection and Prevention". `FrameworkResponse` has no `status` field and is `extra="forbid"`, so the flag cannot be carried. | `fe-signalloom/src/api_compat.py` ~6989-7020, 1201-1210 |
| fe `GET /compliance/policy/frameworks` | `dora` as a scanned framework at 0% — `PolicyFrameworkSummaryResponse` has no `notEvaluated` field. | `api_compat.py` ~7060-7090 |
| fe posture score | the unevaluated control lands in the denominator: `calculate_posture_score` accepts a `pending=` argument that the caller never passes. | `routers/compliance.py` ~158-166, `policy_evaluation.py` ~562 |
| dashboard compliance page | a red **`fail`** badge and "0/1 controls passing (0%)", because the status is computed as `passedControls === totalControls ? 'pass' : 'fail'`. | `dashboard-signalloom/src/pages/CompliancePolicyPage.tsx` ~587, 631 |
| dashboard settings | a toggle row reading "DORA Regulation (EU) 2022/2554 — … · 1 controls". | `src/views/Settings.tsx` ~748-750 |
| policy-engine `GET /api/v1/compliance/frameworks` | `map[string][]string` of directories only — a placeholder pack is byte-indistinguishable from a real one, and this is the endpoint the fe proxies. | `compliance.go` ~279-314 |
| demo posture window | **fabricated**: `{ id: "dora", controls: 18, passed: 16, ale: 12400 }` plus four named DORA checks with pass/fail verdicts, against a pack with one never-evaluated check. | `ui/windows/policy-posture.js` ~28, 54-55 |

The scan and summary wire format is the one place that is right:
`ComplianceScanResult.Status` carries `not_evaluated` and `PolicySummaryResponse`
carries `notEvaluated`. The dashboard has no field for it — `rg 'notEvaluated'`
over the dashboard source returns nothing, and `FrameworkSummary` in
`src/types/compliance.ts` has nowhere to put it.

**Not fixed here. All of it is outside `policy/frameworks/**`.** The three
highest-leverage fixes, for whoever owns those files:

1. Add `status` to `FrameworkResponse` and `notEvaluated` to
   `PolicyFrameworkSummaryResponse`, and render an "not assessed" state rather
   than a `fail` badge.
2. Make the policy-engine framework-catalogue endpoint emit each pack's
   `status` — the loader already reads it.
3. Delete the fabricated `dora` row in `ui/windows/policy-posture.js`, or label
   the window as demo data in the UI rather than only in a source comment.

A precedent for the honest version already exists two files away:
`fe-signalloom/src/routers/compliance.py` annotates `soc-2` with "No policy
pack exists for soc-2 … listed for the catalogue only, a scan of it returns
nothing." `dora` and `nis2` are not in `KNOWN_FRAMEWORKS` at all, so they get
neither the annotation nor the catalogue test. Note that
`test_known_frameworks_match_packs.py` only constrains ids already listed
(`if not (PACKS / framework_id).is_dir(): continue`), so the omission is
unpinned in both directions.

## Why there is nothing to check yet

Nothing in DORA Chapter II is observable from a Kubernetes workload or an
agent manifest. Article 6 requires a documented framework, Article 5 an
internal governance and control arrangement; both are organisational facts
about a **financial entity**, evidenced by documents and board minutes, not by
container fields. A check reading `agent.dora_compliant == true` would be a
self-asserted boolean dressed as a regulatory finding — the pattern this
pack's sibling `cra` is criticised for in its own README.

The candidates that could be evidenced honestly, if this pack is ever built
out, are the ones with a technical surface: Article 9(4)(c) and 9(4)(d)
(cryptographic and access controls), Article 10 (anomaly detection), Article 12
(backup and restoration), and Article 17 (ICT incident management process).
None of them is implemented, and none should be added without calibrated risk
and frequency triples — a principal decision, never a pack author's.

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
