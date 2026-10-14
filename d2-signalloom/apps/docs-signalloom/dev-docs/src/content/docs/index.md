---
title: Signal Loom Engineering
description: Start, support, or assess Signal Loom through evidence-led engineering procedures.
---

Signal Loom Engineering serves contributors at `/dev-docs/`. User procedures remain in [Signal Loom user documentation](/docs/).

The engineering portal shares the existing CSS and public assets. Its location does not restrict access.

## Why Signal Loom exists

Signal Loom is an agent governance platform. Its purpose is to make automated work observable, attributable, and subject to operator control.

The aim is not to stop automation. It is to let teams use agents without losing ownership of access, response, and evidence.

AI agents can act across source control, cloud services, ticket systems, secrets stores, and deployment tools. Each connection can extend an agent's effective authority.

This creates operational risk beyond the behaviour of one model or tool. An agent can combine individually valid permissions into an unsafe action path.

Long-lived credentials increase that risk because access can outlive the task that required it. Shared credentials also weaken attribution when several people or agents use them.

Application logs can show what a service reported after an event. They do not necessarily identify the workload, stop execution, revoke access, or preserve reliable evidence.

Signal Loom exists to give operators an ownership model for this problem. It connects observation, workload identity, policy, response, and evidence across agent environments.

The platform does not treat an agent as an isolated process. It treats the agent, its identity, credentials, network paths, host activity, and operator decisions as one system.

## From observation to accountable response

Observation starts the control loop. Sensors and collectors report selected process, network, identity, audit, and policy metadata from the environments that support them.

Identity gives those observations an accountable subject. SPIFFE defines workload identities, and SPIRE issues the identities used by supported services and trust paths.

OpenBao supplies policy-bound credential leases. Short-lived leases reduce exposure, support revocation, and avoid making a static secret the permanent identity of an agent.

Versioned policy turns observations into findings or decisions. Operators can then compare the decision with the agent's approved purpose, owner, and environment.

Fleet Manager coordinates response across the available enforcement planes. These planes can include host freeze, mesh isolation, network controls, OpenBao revocation, SPIRE changes, and admission controls.

No single plane proves complete containment. Each plane returns an outcome, and degraded results expose residual risk for operator review.

The evidence loop records what the platform observed, which policy matched, who acted, and how each response plane behaved. This supports review without treating logs as prevention.

Read [Internal Architecture](/dev-docs/reference/internal-architecture/) for component flows. Read [Architecture diagrams](/dev-docs/reference/architecture-diagrams/) for deployment boundaries and planned targets.

## An illustrative incident

Consider an agent that connects to an unexpected inference endpoint. The observation can identify the destination category and associate it with a workload identity.

A policy can create a finding when the endpoint falls outside the approved set. An operator can then inspect the evidence and request containment.

Fleet Manager can ask available planes to freeze execution, restrict network access, revoke leases, remove identity registration, or block workload admission.

This scenario explains the intended control flow. It does not prove detection coverage for every endpoint, agent tool, host, or deployment environment.

The same boundary applies to a suspected privilege escalation. A Kubernetes audit event or identity event can support a finding only when its collector is active.

Detective controls report evidence and gaps. Preventative controls block or constrain actions, but only within their configured plane and tested environment.

Response reduces harm after a signal or operator decision. It cannot prevent every unsafe action, recover disclosed data, or remove risk from unobserved systems.

See [detection coverage](/docs/operate/detection-coverage/) for active streams and residuals. See the [containment runbook](/docs/operate/containment-runbook/) for response outcomes and degraded states.

## Why the platform uses these components

GitOps keeps desired configuration reviewable and lets Flux reconcile declared state. It also makes manual cluster changes temporary unless the source records them.

SPIFFE and SPIRE bind service communication to workload identity instead of network location alone. OpenBao separates credential leases from application images and static configuration.

Fleet Manager provides one coordination point for multi-plane actions. Host, mesh, network, identity, credential, and admission controls remain separate because each has different failure modes.

This separation also makes partial results visible. A successful network block does not imply successful credential revocation, and a frozen process does not prove network isolation.

The [platform guarantee matrix](/docs/reference/platform-guarantee-matrix/) describes intended layers across environments. Treat each claim according to its cited implementation, tests, and current deployment.

## Deployment and privacy boundaries

This repository provides a demonstration and integration platform. Its current baseline is not the same as independently validated production protection.

Production claims require the target environment, enabled collectors, identities, policies, privileges, storage, and response planes to pass their relevant tests.

The [current limits and roadmap](/docs/reference/roadmap/) separates available demonstration behaviour from planned production work. Missing evidence means unverified, not protected or vulnerable.

The zero-customer-payload design is a collector boundary intent expressed through allowlisted fields, schemas, and tests. It is not a blanket guarantee for every component or environment.

Operational metadata can still reveal sensitive facts. Process timing, tool categories, endpoint names, identities, and relationships can create privacy, employment, or security risk.

Collectors must therefore minimise fields, enforce tenant scope, limit retention, and follow applicable approvals. Teams must check the deployed version and its tests.

Read [zero-customer-payload privacy](/docs/security/zero-customer-payload/) for the stated collector boundary and falsification evidence. Do not extend those results beyond the tested paths.

## Ownership across engineering teams

Developers own component behaviour, contracts, tests, and delivery changes. They must preserve identity, evidence, and policy boundaries when they change a service.

Support engineers own health checks, request tracing, safe evidence collection, and escalation. They should record observed state without exposing credentials or customer payloads.

Security engineers assess identity, policy, data, and containment controls against evidence. Their first assessment must remain read-only so investigation does not alter the state under review.

Remediation follows as separate, approved work. This separation preserves attribution, avoids accidental service impact, and keeps findings distinct from proposed changes.

## Start here

1. Read the [glossary](/dev-docs/reference/glossary/).
2. Choose an [onboarding path](/dev-docs/onboarding/).
3. Check the [documentation rules](/dev-docs/reference/documentation-rules/).

| Reader | Outcome | Guide |
| :--- | :--- | :--- |
| Developer | Start locally, change one item, test it, and prepare delivery. | [Developer](/dev-docs/onboarding/developer/) |
| Support engineer | Check health, trace a failed request, collect safe evidence, and escalate. | [Support engineer](/dev-docs/onboarding/support-engineer/) |
| Security engineer | Assess controls without mutation and prepare findings for later remediation. | [Security engineer](/dev-docs/onboarding/security-engineer/) |

## Boundaries

WARNING: Do not publish credentials, customer payloads, or internal incident details here.
The portal is not an authentication boundary in the current proxy configuration.

Assessment findings describe evidence, not assumed protection. Missing access means **unverified**, not a confirmed gap.

The [assessment template](/dev-docs/reference/security-assessment-template/) separates findings from a later remediation plan.

## Source of truth

The [root guide](https://github.com/controlplaneio-in-toto/osramp-demo/blob/main/AGENTS.md) defines shared lifecycle commands.
The [slice guide](https://github.com/controlplaneio-in-toto/osramp-demo/blob/main/d2-signalloom/AGENTS.md) defines Signal Loom components and tests.
The [portal configuration](https://github.com/controlplaneio-in-toto/osramp-demo/blob/main/d2-signalloom/apps/docs-signalloom/dev-docs/astro.config.mjs) defines the portal base and sidebar.
