# `risk/` — policy as versioned code, priced in pounds

> "What does a breach actually cost you? Not a red, amber, green dot on a dashboard — a number in
> pounds. Most governance ignores that. Compliant or not: a green tick that prices nothing and moves
> nothing. A binary lie."

This directory makes the platform's controls **priceable**. It baselines an AI agent's compliance
posture against a versioned policy pack and this institution's risk posture, and emits a
reproducible cash value of the residual risk exposure.

Design, phasing and platform integration: [`docs/policy-as-versioned-code/INTEGRATION.md`](../docs/policy-as-versioned-code/INTEGRATION.md).
The thesis it obeys: [`docs/breach-cost-talk/TALK.md`](../docs/breach-cost-talk/TALK.md).

## Quick start

```bash
go build -C tools/riskctl -o "$PWD/tools/riskctl/riskctl" .

# Which controls does this agent actually meet, and what proves it?
./tools/riskctl/riskctl baseline --agent agent-remediation --pack 2.0.0 --org acme

# What does that posture cost Acme Co. per year?
./tools/riskctl/riskctl risk     --agent agent-remediation --pack 2.0.0 --org acme

# The estate moved to 2.1.0. What does the laggard cost now?
./tools/riskctl/riskctl risk     --agent agent-remediation --pack 2.1.0 --org acme

# Same agent, same pack, two institutions.
./tools/riskctl/riskctl compare  --agent agent-olly-sentinel --pack 2.1.0 --org acme --with ludlow-health
```

No cluster. No network. No API key. Fixed seed — the same inputs reproduce the same pounds.

## Layout

| Path | What it is |
| --- | --- |
| `packs/agent-policy/<semver>/pack.yaml` | A complete versioned policy pack — what a signed semver git tag resolves to. Controls, rationale, risk triples, enforcement actions, conditional branches, cage tiers. |
| `packs/agent-policy/<semver>/cel/` | Kyverno CEL `ValidatingPolicy` bodies, including the conditional-autonomy branch. No bespoke DSL. |
| `posture/agent-*.yaml` | What is actually true about a named agent, each assertion citing the repository artefact that evidences it. |
| `org/*.yaml` | An institution's loss magnitude per scenario, risk appetite, risk load and insurance position. |
| `out/` | Generated report. Committed so the number is reviewable in a diff; regenerable with `make risk-report`. |

## The one idea

```
pack  -> loss event FREQUENCY   (a property of the control environment)
org   -> loss MAGNITUDE         (a property of the institution)
```

Because frequency and magnitude live in different files, one identical control run against two
institutions produces different enforcement **arithmetically**. Nobody has an opinion. The pounds
decide.

## What the numbers mean

| Figure | Meaning |
| --- | --- |
| **ALE** | Mean of the aggregate annual-loss distribution — the average year. |
| **VaR₉₅** | 95th percentile — the bad year. |
| **TVaR** | Mean of the tail beyond VaR₉₅ — the tail your board actually fears. |
| **carried** | `TVaR × (1 + risk load)`. Never charge the mean. |
| **TCoR** | `residual + cost of controls (incl. cage run-cost) + risk transferred`. |
| **buys/yr** | `ALE_now − ALE_if_this_control_were_met`. What tightening a control is worth. |

A control whose `buys/yr` exceeds the institution's tolerance band is flagged for promotion from
`audit` to `deny`. That flag is **proposed, never applied** — it becomes a reviewed pull request.

## Two things that will surprise you, and should

**Tightening a non-dominant control buys nothing.** Several controls defend the same loss scenario;
an attacker needs one way in, so the scenario's frequency is set by its *weakest* control. Fixing a
second-weakest control shows `£0` until the weakest is fixed. That is a true statement about defence
in depth, and the report shows it rather than flattering you.

**A well-governed agent produces `VaR₉₅ = 0` with `ALE > 0`.** Once more than 5% of simulated years
contain no loss event, the 95th percentile falls to zero while the mean stays positive, carried
entirely by rare severe years. The report calls this **tail-dominated** and says what it implies: of
the four risk-financing moves — avoid, reduce, transfer, retain — you have reached the regime where
*transfer* starts to beat further control spend. That is the shape an underwriter prices.

## Honesty

Every triple in `org/*.yaml` is a **calibrated estimate against a named anchor class**, not a
published figure used verbatim, and every one carries a `provenance` string so it can be argued
with. The loader refuses a magnitude with no provenance and a posture assertion with no evidence
path. Re-calibrate against real incident history before any board, external or underwriter use.

The apparatus is real and reproducible. The inputs are illustrative until someone signs them off.
