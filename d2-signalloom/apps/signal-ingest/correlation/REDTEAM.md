# Adversarial Resolution Red-Team Corpus & Resolution Ceiling

## Overview

This directory contains the adversarial resolution red-team suite and labelled fixture corpus (`SFDP-P4-2`). The suite stresses the deterministic identity resolver (`correlation.Engine` and `correlation.Resolve`) against three mandatory attack classes to establish a falsifiable, machine-auditable resolution ceiling.

The hard gate for the resolution spine is:
$$\text{false-merge} == 0$$

## Attack Classes & Resolution Invariants

| Attack Class | Injected Invariant | Expected Resolution | False-Merge Condition |
| :--- | :--- | :--- | :--- |
| **`hidden-alias`** | A single principal deliberately operating under $\ge 2$ aliases joined by a verified deterministic edge (SPIFFE SVID, K8s ServiceAccount, or GCP ServiceAccount). | Joined into **exactly 1 actor** containing all injected observations in its evidence chain. | N/A (failure to join is a miss, not a false merge). |
| **`split-human`** | Two distinct principals sharing only a NAT gateway / egress IP (e.g. `198.51.100.42`, `203.0.113.50`) with no shared deterministic identity edge. | Kept as **exactly 2 distinct actors**. Shared source IP is circumstantial and must never authorize an identity merge. | Collapsing the two principals into 1 actor is a **false merge** and fails the suite. |
| **`shadow-agent`** | An autonomous script or tool execution presenting no SPIFFE SVID or authenticated identity credentials. | Surfaces as an **unresolved/provisional actor** (`status: provisional`, observation-scoped ID). | Merging the unauthenticated action into an existing authenticated actor or elevating it to actionable status is a **false merge**. |

---

## Denominator Manifest ($N = 18$)

The labelled adversarial corpus contains $N = 18$ distinct cases authored as table tests extending the symmetric-discriminator pattern. Every fixture is constructed using real collector observation shapes via `collectors/fixtures.go` additive seed helpers.

| Attack Class | Count ($N$) | Case IDs | Description |
| :--- | :---: | :--- | :--- |
| `hidden-alias` | 6 | `ADV-HA-01` .. `ADV-HA-06` | Cross-service SPIFFE SVID, GCP SA, K8s SA, multi-region SPIFFE, coordinator session, and cross-layer joins. |
| `split-human` | 6 | `ADV-SH-01` .. `ADV-SH-06` | Google Workspace NAT, K8s APIServer office NAT, node egress IP, VPN NAT, ISP NAT, and telemetry egress IP non-collapse. |
| `shadow-agent` | 6 | `ADV-SA-01` .. `ADV-SA-06` | eBPF unauthenticated egress, anonymous K8s probe, unauthenticated Workspace export, OpenBao probe, container trace, and KAgent tool span. |

---

## Published Resolution Ceiling

The current evaluated ceiling is published in `redteam_ceiling.json`:

$$\text{Resolution Ceiling} = 18/18 \text{ caught} \quad (100.0\%)$$
$$\text{False Merges} = 0 \quad (\text{Target: } 0)$$

---

## Deterministic Reproduction

To reproduce the resolution ceiling and execute the red-team suite:

```bash
cd d2-signalloom/apps/signal-ingest
env LC_ALL=C LANG=C go test -v ./correlation -run TestAdversarialResolution
```

To run the entire Go test suite including the red-team regression:

```bash
make test-signal-ingest
```
