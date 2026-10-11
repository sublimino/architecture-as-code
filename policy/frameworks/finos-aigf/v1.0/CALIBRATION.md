# Calibration — `finos-aigf` v1.0.0

One derivation per priced check, keyed by check id.

Read [the calibration statement](../../README.md#the-calibration-statement) and
then [ANCHORS.md](../../ANCHORS.md).

## This is the weakest-anchored pack in the estate

Say it before any figure. `AC-AI-LOSS` is an **empty** anchor class. **No
public or commercial dataset prices prompt injection, model exfiltration or
unauthorised agent action.** Every AI-specific frequency here is judgement
against an empty reference class, at confidence **D**.

The only quantified AI anchor available is `AC-AI-EVENT-COUNT`, about 1,741
incidents in the AI Incident Database. It carries no losses and no denominator,
so it cannot become a rate.

Several checks in this pack are not AI-specific at all. Access control,
encryption at rest and credential exposure are ordinary security controls on an
AI system. Those rows carry the estate's strongest attribution, through
`AC-ATTRIB-CRED`. The table below separates the two populations, because a
reader is entitled to know which figures rest on data.

## Three checks left the technical loss path

`registered-model-registry-entry`, `model-version-pinned` and
`decision-explainability-metadata` carried technical loss frequencies. They are
documentation and governance controls. A missing registry entry does not cause
a technical loss event.

Their technical frequency is now zero and each is declared in
[`../catalogue/unpriced.tsv`](../catalogue/unpriced.tsv) with the reason code
`penalty-path-not-technical`. They have no derivation below, because the figure
they need is a secondary loss the engine does not model. See section 4 of
[the open decisions](../../../../docs/fair-methodology-open-decisions.md).

## What the magnitude is a share of

The event-level figures are the `SCN-*` magnitudes in
[`risk/org/acme.yaml`](../../../../risk/org/acme.yaml).

| Scenario | Mode |
| :--- | ---: |
| `SCN-UNAUTH-CHANGE` | £60,000 |
| `SCN-SECRET-EXFIL` | £180,000 |
| `SCN-INJECTION-ACT` | £110,000 |
| `SCN-SUPPLY-TAMPER` | £250,000 |
| `SCN-TRUST-SUBVERT` | £500,000 |

## The frequency decomposition

`LEF = P_org × S_path × C_check`.

| Term | Basis | Anchor | Confidence |
| :--- | :--- | :--- | :--- |
| `P_org` | Organisation-year base rate of any cyber loss event. | `AC-LEF-ORG-BASE` | **B** |
| `S_path` `cred` | 98 per cent of financial losses from cyber events involve compromise of valid account credentials. Servers are compromised about three times more often than user devices and carry more than ten times the loss. | `AC-ATTRIB-CRED` | **B** |
| `S_path` `supply` | Software and tool supply chain. Qualified by the exploited-vulnerability catalogue, which has no denominator. | `AC-EXPLOIT` | **C** |
| `S_path` `ai` | **Unanchored.** No dataset exists. | `AC-AI-LOSS` | **D** |
| `S_path` `avail` | Availability and cost exhaustion. No published attribution. | none | **D** |
| `C_check` | Judgement on every row. | none | **D** |

## Per-check derivation

| Check | Scenario | `riskTriple` mode | Implied share | Family | `C_check` reasoning | LEF confidence |
| :--- | :--- | ---: | ---: | :--- | :--- | :--- |
| `rag-ingestion-sensitive-data-filtered` | `SCN-SECRET-EXFIL` | 45,000 | 0.25 | `cred` | Unfiltered ingestion places sensitive data inside a retrieval corpus any prompt can reach. A data path, not a model path, so the credential-family attribution applies. | D |
| `prompt-injection-guardrail-active` | `SCN-INJECTION-ACT` | 75,000 | 0.68 | `ai` | The scenario exists for this control. **Flagged below.** | D |
| `output-leakage-filter-active` | `SCN-SECRET-EXFIL` | 50,000 | 0.28 | `ai` | The last gate before data leaves. Inside the AI band read as a share of exfiltration rather than of injection. | D |
| `inference-rate-limit-configured` | `SCN-UNAUTH-CHANGE` | 18,000 | 0.30 | `avail` | Denial of wallet and denial of service. Priced against unplanned outage, which is the closest scenario the org file carries. | D |
| `user-authn-and-rbac-enforced` | `SCN-SECRET-EXFIL` | 40,000 | 0.22 | `cred` | Ordinary access control on an AI system. One of the few rows here with real attribution behind its `S_path`. | D |
| `ai-data-encrypted-at-rest` | `SCN-SECRET-EXFIL` | 38,000 | 0.21 | `cred` | Reduces the magnitude of a storage compromise rather than its frequency, which the engine cannot express. Priced as a share of the event. | D |
| `tool-grants-least-privilege` | `SCN-INJECTION-ACT` | 60,000 | 0.55 | `ai` | Tool scope is what bounds what an induced action can reach. **Flagged below.** | D |
| `mcp-servers-allowlisted` | `SCN-SUPPLY-TAMPER` | 55,000 | 0.22 | `supply` | An unlisted MCP server is a third-party component with execution reach. A supply-chain path, and priced inside that band. | D |
| `no-long-lived-credentials-exposed` | `SCN-SECRET-EXFIL` | 85,000 | 0.47 | `cred` | A long-lived secret in an agent context is the single most directly attributable exposure in the pack. **Flagged below**, marginally. | D |
| `high-impact-actions-human-approved` | `SCN-INJECTION-ACT` | 100,000 | 0.91 | `ai` | The last human gate. **Flagged below**, and the worst outlier in the estate. | D |
| `ai-interaction-audit-logging` | `SCN-TRUST-SUBVERT` | 25,000 | 0.05 | `ai` | Detective. Priced against the evidence-chain scenario because absent logs are what make an incident unprovable. | D |
| `spend-budget-alerting-configured` | `SCN-UNAUTH-CHANGE` | 15,000 | 0.25 | `avail` | Cost exhaustion. Detective sibling of the rate limit. | D |
| `decision-audit-tamper-evident` | `SCN-TRUST-SUBVERT` | 28,000 | 0.06 | `ai` | Tamper evidence over the decision log. Same reasoning as audit logging, priced slightly above it. | D |

## Shares that sit outside their family band

Recorded, not retuned. The AI guardrail band is 0.10 to 0.40, from
[ANCHORS.md](../../ANCHORS.md#family-ranges).

| Check | Band | Implied | Reading |
| :--- | :--- | ---: | :--- |
| `high-impact-actions-human-approved` | 0.10 to 0.40 | **0.91** | The worst outlier in the estate. The triple prices the control at nearly the whole adversarial-actuation scenario, which is a statement that this one gate is the only thing standing between an induced instruction and the full loss. That may even be true, and if it is, the control belongs in a scenario of its own rather than as a 91 per cent share of someone else's. |
| `prompt-injection-guardrail-active` | 0.10 to 0.40 | **0.68** | Same shape. `SCN-INJECTION-ACT` was written for this threat, so a near-total share is close to saying the check *is* the scenario. Either the share or the scenario is wrong, and choosing is a priced-figure decision. |
| `tool-grants-least-privilege` | 0.10 to 0.40 | **0.55** | Above the band. Defensible as the control that bounds blast radius once an injection has succeeded. |
| `no-long-lived-credentials-exposed` | Credential exposure 0.15 to 0.45 | **0.47** | Marginally above. This is the one outlier with published attribution behind it, through `AC-ATTRIB-CRED`, so it is the least troubling of the four. |

Four of thirteen rows sit above their band, and all four are in the families
with the weakest anchors. That correlation is the finding. **Where there is no
data, the estimates drift upward.** No value was changed, so a later retune is
a reviewable diff against this table.
