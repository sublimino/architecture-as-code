# Calibration — `nist-800-53` v2.1.0

One derivation per priced check, keyed by check id. The v1.0 and v2.0 packs
carry no frequency triple and are declared in
[`../catalogue/unpriced.tsv`](../catalogue/unpriced.tsv), so they have no
derivation to record.

Read [the calibration statement](../../README.md#the-calibration-statement) and
then [ANCHORS.md](../../ANCHORS.md).

## What the magnitude is a share of

A `riskTriple` here is the **attributable share of one loss event assigned to
one failed control**. The event-level figures are the `SCN-*` magnitudes in
[`risk/org/acme.yaml`](../../../../risk/org/acme.yaml). The implied share is
this check's `riskTriple` mode over that scenario's mode.

| Scenario | Mode |
| :--- | ---: |
| `SCN-UNAUTH-CHANGE` | £60,000 |
| `SCN-SECRET-EXFIL` | £180,000 |
| `SCN-SUPPLY-TAMPER` | £250,000 |
| `SCN-TRUST-SUBVERT` | £500,000 |

## The frequency decomposition

`LEF = P_org × S_path × C_check`.

### `P_org`

Organisation-year base rate of any cyber loss event. Anchor
`AC-LEF-ORG-BASE`, confidence **B**. Shared by every check in every pack, and a
property of the institution rather than of this pack.

### `S_path`, by control family

| Family | Basis | Anchor | Confidence |
| :--- | :--- | :--- | :--- |
| `cred` | 98 per cent of financial losses from cyber events involve compromise of valid account credentials. Servers are compromised about three times more often than user devices and carry more than ten times the loss. This is the strongest published attribution in the registry. | `AC-ATTRIB-CRED` | **B** |
| `escape` | Host-namespace and container escape. Inferred from cluster API-surface exposure, with no published attribution. | `AC-PREV-K8S` | **C** |
| `harden` | Defence in depth with no attributable path of its own. | `AC-PREV-K8S` | **C** |
| `supply` | Software supply chain. Qualified by the exploited-vulnerability catalogue, which carries no denominator. | `AC-EXPLOIT` | **C** |
| `evidence` | Audit and detection controls. These defend the evidence chain rather than the asset, which is why they are priced against `SCN-TRUST-SUBVERT`. No published attribution exists for the share of losses that turn on absent evidence. | none | **D** |

### `C_check`

Judgement on every row, **confidence D**. `AC-PREV-K8S` measures cloud IAM and
cluster endpoints. Most of these checks read pod-template and SPIFFE fields
instead, so the prevalence input is itself a proxy.

## Per-check derivation

| Check | Scenario | `riskTriple` mode | Implied share | Family | `C_check` reasoning | LEF confidence |
| :--- | :--- | ---: | ---: | :--- | :--- | :--- |
| `no-automount-sa-token` | `SCN-SECRET-EXFIL` | 25,000 | 0.14 | `cred` | **The estate's stated template.** An auto-mounted token is a usable credential at rest in every pod, and credential exposure is the only family with strong published attribution. Its 0.5/1.5/4.0 frequency sits inside the researched band. | D |
| `spiffe-peer-authorization` | `SCN-SECRET-EXFIL` | 45,000 | 0.25 | `cred` | Absent peer authorisation means any workload identity is accepted, which converts one compromised pod into estate-wide credential reach. | D |
| `cross-namespace-egress-authorization` | `SCN-SECRET-EXFIL` | 35,000 | 0.19 | `cred` | Lateral reach across tenancy boundaries. Narrower than peer authorisation because it bounds the blast radius rather than the trust decision. | D |
| `container-run-as-non-root` | `SCN-TRUST-SUBVERT` | 50,000 | 0.10 | `escape` | Root in the container is a precondition for most published escapes. | D |
| `no-privilege-escalation` | `SCN-TRUST-SUBVERT` | 70,000 | 0.14 | `escape` | One link in an escape chain, priced above the CIS equivalent because this tier applies it to agent workloads. | D |
| `no-privileged-mode` | `SCN-TRUST-SUBVERT` | 90,000 | 0.18 | `escape` | A privileged container is a node compromise. | D |
| `immutable-audit-sink` | `SCN-TRUST-SUBVERT` | 30,000 | 0.06 | `evidence` | **The check reads a logging-enabled boolean and cannot observe immutability.** The share is priced for the weaker fact the expression actually tests, not for the control the id names. | D |
| `read-only-rootfs` | `SCN-TRUST-SUBVERT` | 25,000 | 0.05 | `harden` | Raises the cost of persistence inside a container. No attributable path. | D |
| `mfa-spiffe-svid-required` | `SCN-SECRET-EXFIL` | 50,000 | 0.28 | `cred` | A short-lived verifiable identity is the control that makes a stolen credential useless. Top of the researched `cred` band, which the published attribution supports. | D |
| `drop-all-capabilities` | `SCN-TRUST-SUBVERT` | 40,000 | 0.08 | `harden` | Defence in depth. Narrower checks already cover the capabilities that matter most. | D |
| `network-boundary-enforcement` | `SCN-SECRET-EXFIL` | 42,000 | 0.23 | `cred` | Egress control is the last gate before exfiltration, so it is priced on the credential path. | D |
| `anomaly-detection-telemetry` | `SCN-TRUST-SUBVERT` | 30,000 | 0.06 | `evidence` | A detective control. It changes the duration of a loss rather than its occurrence, which this engine has no term for. | D |
| `image-digest` | `SCN-SUPPLY-TAMPER` | 45,000 | 0.18 | `supply` | A mutable tag is the mechanism by which a tampered artefact reaches production unnoticed. | D |
| `trusted-registry` | `SCN-SUPPLY-TAMPER` | 50,000 | 0.20 | `supply` | Registry provenance bounds which artefacts can be pulled at all. | D |

## Shares that sit outside their family band

Every row in this pack falls inside its researched family band. See
[ANCHORS.md](../../ANCHORS.md#family-ranges).

The `evidence` family has no band, because it has no published attribution and
no anchor class. Its two rows are the weakest derivations in the pack, and the
reason is structural. A detective control reduces the **duration** of a loss,
and the engine models occurrence and magnitude only. Pricing detection as a
share of occurrence is the best available approximation and it is an
approximation.
