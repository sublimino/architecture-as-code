# Calibration — `cra` v1.0.0

One derivation per priced check, keyed by check id.

Read [the calibration statement](../../README.md#the-calibration-statement) and
then [ANCHORS.md](../../ANCHORS.md).

## This pack should price at zero today

Before any derivation below is read, the statutory fact. The Cyber Resilience
Act's general obligations do not apply until **11 December 2027** under
Art. 71. The three checks here price to £256,514.43 of annual expected loss
between them.

That figure is wrong by statute rather than by calibration. The derivations
below are the basis the figures will need **once the regime applies**. They are
not a defence of charging for it now. The citations and the staged dates are in
[PENALTIES.md](../../PENALTIES.md#cyber-resilience-act).

## What the magnitude is a share of

A `riskTriple` here is the attributable share of one loss event assigned to one
failed control. All three checks are supply-chain controls and are priced as a
share of `SCN-SUPPLY-TAMPER`, whose mode is £250,000 in
[`risk/org/acme.yaml`](../../../../risk/org/acme.yaml).

## The frequency decomposition

`LEF = P_org × S_path × C_check`.

| Term | Basis | Anchor | Confidence |
| :--- | :--- | :--- | :--- |
| `P_org` | Organisation-year base rate of any cyber loss event. Shared by every check in every pack. A property of the institution. | `AC-LEF-ORG-BASE` | **B** |
| `S_path` | Share of loss events running through the software supply chain. No published attribution figure for this share was verified. The researched family band is 0.10 to 0.30. | `AC-EXPLOIT` | **C** |
| `C_check` | Conditional contribution of this one missing control. Judgement. | none | **D** |

`AC-EXPLOIT` contributes a qualifier and not a rate. The CISA Known Exploited
Vulnerabilities catalogue held 1,739 entries at catalogue version 2026.10.08.
It has no denominator, so it cannot produce a frequency.

## Per-check derivation

| Check | Scenario | `riskTriple` mode | Implied share | `C_check` reasoning | LEF confidence |
| :--- | :--- | ---: | ---: | :--- | :--- |
| `default-secure-configuration` | `SCN-SUPPLY-TAMPER` | 40,000 | 0.16 | An insecure default ships to every deployment of the product, so one authoring error is many exposures. Priced below provenance because it is a weakness rather than a tampering path. | D |
| `sbom-verified-provenance` | `SCN-SUPPLY-TAMPER` | 65,000 | 0.26 | Absent provenance is what makes a tampered artefact undetectable, which is the whole magnitude of the scenario. Highest share of the three, at the top of the researched band. | D |
| `signed-cryptographic-updates` | `SCN-SUPPLY-TAMPER` | 50,000 | 0.20 | An unsigned update channel is a direct path to production, but it is a narrower path than the build chain. | D |

All three shares fall inside the researched supply-chain band of 0.10 to 0.30.
See [ANCHORS.md](../../ANCHORS.md#family-ranges).

## What this pack's figures do not include

The CRA penalty ceilings are **not** in any triple here, and must not be.
Art. 64 reaches €15,000,000 or 2.5 per cent of worldwide annual turnover. A
ceiling is a `max` and never a `mode`, and the penalty is a secondary loss that
this engine does not model. See section 4 of
[the open decisions](../../../../docs/fair-methodology-open-decisions.md).
