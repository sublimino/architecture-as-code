# Calibration — `eu-ai-act` v2.1.0

One derivation per priced check, keyed by check id. The v1.0 and v2.0 packs
carry no frequency triple and are declared in
[`../catalogue/unpriced.tsv`](../catalogue/unpriced.tsv), so they have no
derivation to record.

Read [the calibration statement](../../README.md#the-calibration-statement) and
then [ANCHORS.md](../../ANCHORS.md).

## Five checks left the technical loss path

This is the one category error this pass fixed rather than documented.

`training-data-provenance`, `annex-iv-technical-documentation`,
`automatic-record-keeping`, `user-instructions-transparency` and
`synthetic-content-marking` carried technical loss frequencies.
`annex-iv-technical-documentation` carried a frequency mode of 1.5, which
asserts 1.5 documentation-caused loss events per year. That does not happen.

These five controls defend against a **penalty**, not a breach. Their technical
frequency is now zero and each is declared in
[`../catalogue/unpriced.tsv`](../catalogue/unpriced.tsv) with the reason code
`penalty-path-not-technical`. They have no derivation below, because the number
they need is a secondary loss the engine does not model. See section 4 of
[the open decisions](../../../../docs/fair-methodology-open-decisions.md).

Their statutory ceilings are facts and are tabulated in
[PENALTIES.md](../../PENALTIES.md#eu-ai-act). Art. 99(4) is the applicable row
for a deployer, at €15,000,000 or 3 per cent of worldwide annual turnover,
whichever is higher. Art. 99(6) inverts that to the **lower** of the two for an
SME. A ceiling is a `max` and never a `mode`.

## What the magnitude is a share of

The event-level figures are the `SCN-*` magnitudes in
[`risk/org/acme.yaml`](../../../../risk/org/acme.yaml).

| Scenario | Mode |
| :--- | ---: |
| `SCN-UNAUTH-CHANGE` | £60,000 |
| `SCN-INJECTION-ACT` | £110,000 |
| `SCN-TRUST-SUBVERT` | £500,000 |

## The frequency decomposition

`LEF = P_org × S_path × C_check`.

| Term | Basis | Anchor | Confidence |
| :--- | :--- | :--- | :--- |
| `P_org` | Organisation-year base rate of any cyber loss event. | `AC-LEF-ORG-BASE` | **B** |
| `S_path` `escape` | Host-namespace and container escape, inferred from cluster API-surface exposure. | `AC-PREV-K8S` | **C** |
| `S_path` `ai` | AI-specific threat events. **There is no anchor.** No public or commercial dataset prices prompt injection, model exfiltration or unauthorised agent action. | `AC-AI-LOSS` | **D** |
| `C_check` | Judgement on every row. | none | **D** |

The AI rows are marked `unanchored`. `AC-AI-EVENT-COUNT` records about 1,741
incidents in the AI Incident Database, which is countable and carries no losses
and no denominator. A count is not a rate.

## Per-check derivation

| Check | Scenario | `riskTriple` mode | Implied share | Family | `C_check` reasoning | LEF confidence |
| :--- | :--- | ---: | ---: | :--- | :--- | :--- |
| `container-run-as-non-root` | `SCN-TRUST-SUBVERT` | 50,000 | 0.10 | `escape` | Root in the container is a precondition for most published escapes. Priced identically to the `nist-800-53` v2.1 equivalent on purpose. | D |
| `no-privilege-escalation` | `SCN-TRUST-SUBVERT` | 60,000 | 0.12 | `escape` | One link in an escape chain. | D |
| `block-unauthorized-host-exec` | `SCN-TRUST-SUBVERT` | 80,000 | 0.16 | `escape` | Host execution from an agent is the shortest path from a model decision to a node compromise. Highest `escape` share in this pack. | D |
| `resource-limits-set` | `SCN-UNAUTH-CHANGE` | 40,000 | 0.67 | `harden` | Availability. **Flagged below.** | D |
| `drop-all-capabilities` | `SCN-TRUST-SUBVERT` | 70,000 | 0.14 | `escape` | Defence in depth, priced above the CIS equivalent because this tier governs agent workloads with host reach. | D |
| `deployer-monitoring-active` | `SCN-INJECTION-ACT` | 50,000 | 0.45 | `ai` | Art. 26(5) deployer monitoring. A detective control over an agent's own actions. **Flagged below.** | D |

## Shares that sit outside their family band

Recorded, not retuned. The bands are in
[ANCHORS.md](../../ANCHORS.md#family-ranges).

| Check | Band | Implied | Reading |
| :--- | :--- | ---: | :--- |
| `resource-limits-set` | Kubernetes hardening 0.01 to 0.08 | **0.67** | Eight times the top of its band. The check also carries a frequency mode of 3 per year, the highest in the estate, so it reports about £120,000 of annual expected loss on its own. A missing resource limit is an availability control and `SCN-UNAUTH-CHANGE` is the wrong scenario for it. It needs a scenario of its own, or a retune, and both are priced-figure decisions. |
| `deployer-monitoring-active` | AI guardrails 0.10 to 0.40 | **0.45** | Above the band. Defensible as a detective control over a scenario the pack exists to govern. The engine has no duration term, so a detective control can only be priced as a share of occurrence. |

Neither value was changed. Moving a pinned price is the principal's call. The
point of recording the basis first is that the retune becomes a reviewable diff
against a stated position.
