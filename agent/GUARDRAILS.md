# Agentic remediation guardrails

This document is the operating boundary for the Phase 4 remediation agent. The harness enforces what it can mechanically; everything else is procedure that the audit trail makes checkable.

## What the agent is allowed to do

1. Read the evidence bundle the harness prepares for it: scanner output, SBOMs, VEX status, govulncheck results, and advisory text for one named CVE.
2. Produce a single structured recommendation: either a dependency version bump in one of the demo services, or a VEX `not_affected` proposal with a justification and supporting reasoning.

That is the whole authority. The agent does not push, merge, deploy, sign, or approve anything.

## What the harness enforces

- Sandbox: the agent process runs under [nono](https://nono.sh/) (`nono run --profile ... -- claude ...`), which applies kernel-level restrictions (Landlock): filesystem access limited by profile, network filtered, sensitive paths (SSH keys, cloud credentials, shell configs) blocked by default. The harness refuses to run the agent unsandboxed.
- Secrets: the Anthropic API key is injected at the sandbox boundary by nono's credential proxy and is not exported into the harness environment or written to disk. It never appears in the evidence bundle or the audit trail.
- Approval gate: the default mode stops after the recommendation. Executing a remediation requires an explicit `--approve` from a human who has read the recommendation. There is no auto-approve path.
- Change scope: on approval the harness applies only two change shapes, a `go get <module>@<version>` inside `d2-osramp-apps/apps/<service>` or a `vexctl create` proposal. Anything else in the recommendation is ignored and logged. The result lands on a `remediation/<cve>` branch as a pull request; the agent has no path to `main`.
- Attestation: the analysis run and any applied remediation each execute under `witness run` (steps `agent-analysis` and `agent-remediation`), signed and uploaded to Archivista. The evidence records what the agent read, what it recommended, who approved, and what changed.

## Prohibited autonomous actions

The agent, and the harness acting on its output, must never: merge or push to protected branches, create or modify signing keys or trust anchors, change policy documents or admission rules, modify the harness or guardrails themselves, contact systems other than the Anthropic API, or issue a signed VEX statement without a human signature step. A recommendation that requires any of these is rejected at the gate.

## Validation

Run [sandbox-probe](https://control-plane.io/posts/sandbox-probe-release/) inside the same profile to verify the boundary before trusting a new nono version or profile change:

```bash
nono run --profile "${NONO_PROFILE}" -- sandbox-probe
```

Keep the probe report with the run's audit artifacts.

## Escalation model

Renewals and expansions of agent scope follow the same rule as VEX exceptions: each widening needs a higher approval tier, and the widened scope is recorded in this document by PR, reviewed by the security team.
