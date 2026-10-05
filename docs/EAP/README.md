# Kusari pilot: Enterprise Access Preview documentation

This directory is the user documentation for the Kusari Enterprise Access
Preview (EAP) pilot of Signal Loom. The reader is a Kusari engineer who
onboards from zero. The pages describe the tree at commit `02d18d07` on branch
`feat/signal-loop-and-bootstrap-refactor`. Each page names the proposal or
record it derives from.

Signal Loom is the product in this repository that observes AI agents on
Kubernetes, records what they do, and contains one that misbehaves. The pilot
has two clusters. Signal Loom runs on the central cluster, which ControlPlane
operates. Kusari's own cluster is the secondary cluster. It runs one
Signal Loom component, the `signalloom-warden` DaemonSet, and forwards its
records to the central cluster over HTTPS.

The architecture decisions that define this shape are ADR-11 to ADR-14 in
[the Spireless Token-Based Agent Identity Migration proposal](../Proposal%20—%20Signal%20Loom%20Spireless%20Token-Based%20Agent%20Identity%20Migration%20%282026-Q4%29.md).

## What Kusari gets

| Capability | Where | Status at `02d18d07` |
| :--- | :--- | :--- |
| A login to the Signal Loom dashboard, bound to tenant `kusari` | `https://dashboard.osramp.acme.local:30754` | Works with the pilot identity `kusari-operator`. See [onboarding](onboarding.md). |
| A list of the agents that Signal Loom observes, with a dossier per agent | `/agents`, `/agents/:id` | Works. The list is not filtered by tenant. See [pages](pages.md#agents). |
| Live signal observations from the warden | `/weave` | Works for observations the central signal-ingest accepts. |
| Audit trail of every action in the tenant | `/audit` | Works. |
| Kernel-level containment of an agent that reads a sensitive file | The warden on each node of the Kusari cluster | Freeze works locally. The resume path does not reach a remote cluster. See [enforcement](enforcement.md). |
| RBAC and collusion analysis of the Kusari cluster | `/rbac-analysis`, `/collusion-access` | Roadmap. The exporter CronJob and import route exist. No key or cluster id is set for a remote cluster. See [faq-and-limits](faq-and-limits.md). |
| AWS CloudTrail ingest and a policy engine | Not in the dashboard yet | Pipeline and policy bundles work and are tested end to end offline; nothing surfaces in the dashboard. Both bundles are in `shadow`. See [kusari-e2e](kusari-e2e.md) and the SLAWS proposal below. |

## Reading order

1. [onboarding.md](onboarding.md). Get in, see your tenant, find your agents.
2. [pages.md](pages.md). One section per dashboard page you will use.
3. [secondary-cluster.md](secondary-cluster.md). What runs on the Kusari cluster, what the hub needs first, and how to check each step.
4. [enforcement.md](enforcement.md). What the warden does when an agent misbehaves, how it is recorded, and what the forensic bundle holds.
5. [faq-and-limits.md](faq-and-limits.md). Known limits and what to do when something is not there.
6. [kusari-e2e.md](kusari-e2e.md). The AWS signal path: how to run its tests, read the per-rule table, add a signal or a rule, and replay a window. Two known defects are named there.

## Source records

These records are the ground truth that the pages above derive from.

| Record | Use it for |
| :--- | :--- |
| [Spireless Token-Based Agent Identity Migration (2026-Q4)](../Proposal%20—%20Signal%20Loom%20Spireless%20Token-Based%20Agent%20Identity%20Migration%20%282026-Q4%29.md) | ADR-03, ADR-07, ADR-11 to ADR-14. The named static keys, the warden rename, and the secondary-cluster shape. |
| [AWS Telemetry Ingest and Multilayer Policy Engine Beta (2026-Q3)](../Proposal%20—%20Signal%20Loom%20AWS%20Telemetry%20Ingest%20%26%20Multilayer%20Policy%20Engine%20Beta%20%282026-Q3%29.md) | SLAWS. The AWS pilot, in flight. Kusari is the first AWS pilot customer. |
| [Forensic bundle specification](../eap/FORENSIC-BUNDLE-SPECIFICATION.md) | What a signed evidence bundle contains and how to check one. |
| [Five-step containment verification](../eap/SLDC-P5-1-E2E-CONTAINMENT.md) | The live status of the containment chain on 2026-10-02. |
| [Dual cluster topology](../eap/SLDC-P2-DUAL-CLUSTER.md) | The local two-cluster lab that stands in for the pilot topology. |
| [SLDC mission certification](../eap/SLDC-MISSION-CERTIFICATION.md) | The governor verdict on the pilot mission. Read this, not the final report, for the current state. |
| [Kusari agent stub](../../d2-signalloom/apps/kusari-agent/README.md) | The demo workload that provokes a detection on request. |
| [AWS trust policy template](../signalloom/slaws-kusari-trust-policy.md) | The read-only cross-account role for the AWS pilot. |

NOTE: The repository holds two certification records for the same mission
with opposite verdicts. [`FINAL-MISSION-CERTIFICATION-REPORT.md`](../eap/FINAL-MISSION-CERTIFICATION-REPORT.md)
says `100% PASS`. [`SLDC-MISSION-CERTIFICATION.md`](../eap/SLDC-MISSION-CERTIFICATION.md)
says `NOT CERTIFIED`. The second one records the live runs and is the one that
matches the code. These pages follow the second one.

## Terms

| Term | Meaning on these pages |
| :--- | :--- |
| **central cluster** | The cluster that runs Signal Loom: the dashboard, the portal API (`fe-signalloom`), `signal-ingest`, `fleet-manager`, Dex, OpenBao, and SPIRE. ControlPlane operates it. In the local lab it is `kind-osramp`. |
| **secondary cluster** | Kusari's cluster. It runs the warden DaemonSet and Kusari's workloads. In the local lab it is `kind-signalloom-hub`. |
| **warden** | The `signalloom-warden` DaemonSet. It was named `stun-sentinel` before ADR-07. The source directories and some Secret names still carry the old name. |
| **named key** | A static bearer token with a name, minted by a script on the central cluster. The warden holds two: one for `signal-ingest` and one for `fleet-manager`. |
| **tenant** | The string `kusari`. Workloads declare it with the label `signalloom.ai/tenant`. The portal maps the pilot login to it. |
| **stun** | The record that an agent is contained. The warden posts it to `fleet-manager`. |
| **freeze** | The kernel action: the warden writes `1` to the pod's cgroup v2 `cgroup.freeze` file. |
