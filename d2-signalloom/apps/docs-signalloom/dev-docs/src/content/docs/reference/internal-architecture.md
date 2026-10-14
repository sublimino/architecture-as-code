---
title: Internal Architecture
description: Component-level diagrams of the Signal Loom codebase, generated from the repository with SeeCode.
---

The [Architecture diagrams](/dev-docs/reference/architecture-diagrams/) page shows
where each Signal Loom target platform deploys. This page shows calls between
components inside one deployment. Go, Python, and YAML sources implement these calls.
Each diagram is a SeeCode spec checked against its named source files.
The diagrams omit labels that have no code rather than guess their meaning.

The abbreviated `apps/` source paths below are relative to `d2-signalloom/`.

## 1. Component flows

The operator's browser sends traffic through Envoy Gateway and the dashboard.
The `fe-signalloom` API calls `fleet-manager`, `signal-ingest`, and `policy-engine`.
These components depend on the identity and secrets planes. Code roots:
`apps/{fe-signalloom,fleet-manager,signal-ingest,policy-engine,signalloom-warden,dashboard-signalloom}`.

![Signal Loom component flows](/docs/diagrams/internal/01-component-flows.svg)

- Interactive diagram: [01-component-flows.html](/docs/diagrams/internal/01-component-flows.html)
- Diagram source: [01-component-flows.json](/docs/diagrams/internal/01-component-flows.json)

## 2. System context and trust boundaries

The diagram shows trust boundaries between external actors, namespaces, and a remote pilot cluster.
External actors include operators, CI, and external audit sources.
The namespaces are `fe-signalloom` and the `inf-bao` identity namespace.
Sources include the namespace table in `AGENTS.md` and the
[remote tenant overlay](https://github.com/controlplaneio-in-toto/osramp-demo/tree/HEAD/d2-signalloom/infra/agent-swarm/signalloom-warden-overlays/remote-tenant).

![System context and trust boundaries](/docs/diagrams/internal/02-system-context.svg)

- Interactive diagram: [02-system-context.html](/docs/diagrams/internal/02-system-context.html)
- Diagram source: [02-system-context.json](/docs/diagrams/internal/02-system-context.json)

## 3. Ingress and the auth_request gate

An nginx `auth_request` subrequest gates browser requests to `/fleet-api/` or `/dashboard/` before they reach `fleet-manager` or `afm-platform`.
Reads pass untouched. Mutating methods need a superadmin token.
Code root: `apps/dashboard-signalloom/nginx.conf`.

![Ingress and the auth_request gate](/docs/diagrams/internal/03-ingress-auth.svg)

- Interactive diagram: [03-ingress-auth.html](/docs/diagrams/internal/03-ingress-auth.html)
- Diagram source: [03-ingress-auth.json](/docs/diagrams/internal/03-ingress-auth.json)

## 4. Identity plane: SPIRE and mTLS

SPIRE Server issuing workload SVIDs to `fleet-manager`, the `signalloom-warden`,
and the `signal-ingest` `spirea` collector, and the mTLS mesh those SVIDs
back. Code roots: `apps/fleet-manager/spire_client.go`,
`apps/signal-ingest/collectors/spirea`.

![Identity plane: SPIRE and mTLS](/docs/diagrams/internal/04-identity-spire.svg)

- Interactive diagram: [04-identity-spire.html](/docs/diagrams/internal/04-identity-spire.html)
- Diagram source: [04-identity-spire.json](/docs/diagrams/internal/04-identity-spire.json)

## 5. Secrets: OpenBao per-plane tokens

How `fleet-manager` sources an OpenBao token from the `openbao-agent` sidecar,
guards calls with a circuit breaker, and revokes or re-mints leases across a
stun/resume cascade. Code root: `apps/fleet-manager/openbao_client.go`.

![Secrets: OpenBao per-plane tokens](/docs/diagrams/internal/05-secrets-openbao.svg)

- Interactive diagram: [05-secrets-openbao.html](/docs/diagrams/internal/05-secrets-openbao.html)
- Diagram source: [05-secrets-openbao.json](/docs/diagrams/internal/05-secrets-openbao.json)

## 6. Fleet-manager control plane

The workload registry and topology feeding the cascade orchestrator, its
fan-out to five enforcement planes, and the dual Ed25519-signed resume token
path that reverses it. Code roots:
`apps/fleet-manager/{workload_registry,cascade,resume_token}.go`.

![Fleet-manager control plane](/docs/diagrams/internal/06-fleet-manager-control-plane.svg)

- Interactive diagram: [06-fleet-manager-control-plane.html](/docs/diagrams/internal/06-fleet-manager-control-plane.html)
- Diagram source: [06-fleet-manager-control-plane.json](/docs/diagrams/internal/06-fleet-manager-control-plane.json)

## 7. The warden: per-node enforcement

The per-node daemon uses an eBPF probe to feed a capture and correlator.
It coordinates the cgroup freezer and `tc` network stun.
Its poll/report/stun connection to `fleet-manager` uses the hub's shared trust policy. Code
root: `apps/signalloom-warden/{capture,freezer,network,hubtls,fleetpoll}.go`.

![The warden: per-node enforcement](/docs/diagrams/internal/07-warden-node-enforcement.svg)

- Interactive diagram: [07-warden-node-enforcement.html](/docs/diagrams/internal/07-warden-node-enforcement.html)
- Diagram source: [07-warden-node-enforcement.json](/docs/diagrams/internal/07-warden-node-enforcement.json)

## 8. signal-ingest: external collectors to FrostDB

Named collectors read audit and telemetry from outside the cluster.
They cover AWS, GCP, Kubernetes, OpenBao, and SPIRE. Workspace SaaS is a planned collector.
The collector registry and sink send this data to FrostDB. Collector
names match the repository's `DIAGRAMS.md` inclusion list. Code root:
`apps/signal-ingest/collectors/{awslogs,gcpaudit,k8saudit,baoaudit,spirea,workspacesaas}`.

![signal-ingest: external collectors to FrostDB](/docs/diagrams/internal/08-signal-ingest-collectors.svg)

- Interactive diagram: [08-signal-ingest-collectors.html](/docs/diagrams/internal/08-signal-ingest-collectors.html)
- Diagram source: [08-signal-ingest-collectors.json](/docs/diagrams/internal/08-signal-ingest-collectors.json)

## 9. policy-engine: bundles to decisions

CEL rule bundles move from `policy/bundles/` in git, through a generated
ConfigMap, into the `obscel.Evaluator` that `signal-ingest`'s sink runs
in-process. The same evaluator also backs the standalone dry-run API. Code
roots: `policy/bundles/`, `apps/signal-ingest/{main.go,policy}`.
The diagram's `pkg/obscel/cel_eval.go` is an example source path, not a file in this tree.

![policy-engine: bundles to decisions](/docs/diagrams/internal/09-policy-engine-pipeline.svg)

- Interactive diagram: [09-policy-engine-pipeline.html](/docs/diagrams/internal/09-policy-engine-pipeline.html)
- Diagram source: [09-policy-engine-pipeline.json](/docs/diagrams/internal/09-policy-engine-pipeline.json)

## 10. KubeSec-AFM: formal RBAC analysis

The dashboard embeds `afm-platform`'s Next.js frontend in a same-origin iframe through `/_afm_gate`.
The gate forwards to a FastAPI backend.
The backend runs a Z3 bounded-model-checking engine over each imported cluster's RBAC graph. Code
roots: `d2-k8s-afm/apps/afm-platform`, `apps/dashboard-signalloom/nginx.conf`,
`docs/signalloom/kubesec-afm-guide.md`.

![KubeSec-AFM: formal RBAC analysis](/docs/diagrams/internal/10-kubesec-afm-rbac.svg)

- Interactive diagram: [10-kubesec-afm-rbac.html](/docs/diagrams/internal/10-kubesec-afm-rbac.html)
- Diagram source: [10-kubesec-afm-rbac.json](/docs/diagrams/internal/10-kubesec-afm-rbac.json)

## 11. GitOps supply chain

A developer's signed push reaches the in-cluster Zot registry.
Flux's `FluxInstance` reconciles an `OCIRepository` through the kustomize and helm controllers to the API server.
The diagram shows Kyverno and a `ValidatingAdmissionPolicy` that both verify the image signature on admission.
Code roots: `d2-osramp-fleet/{clusters,tenants}`.
The diagram's example path is policy/kyverno-verify-images.yaml. It is not a source file in this tree.

![GitOps supply chain](/docs/diagrams/internal/11-gitops-supply-chain.svg)

- Interactive diagram: [11-gitops-supply-chain.html](/docs/diagrams/internal/11-gitops-supply-chain.html)
- Diagram source: [11-gitops-supply-chain.json](/docs/diagrams/internal/11-gitops-supply-chain.json)

## 12. Agent discovery and claim

A workload sends heartbeats with its SPIFFE identity and becomes visible inventory.
An operator claims it into their tenant.
The platform checks for cross-tenant conflict before it grants the claim. Code roots:
`apps/fe-signalloom/src/routers/agents.py`, `apps/fe-signalloom/src/api_compat.py`,
[Claim the two demonstration agents](/docs/agents/dual-agent-onboarding/).

![Agent discovery and claim](/docs/diagrams/internal/12-agent-onboarding-claim.svg)

- Interactive diagram: [12-agent-onboarding-claim.html](/docs/diagrams/internal/12-agent-onboarding-claim.html)
- Diagram source: [12-agent-onboarding-claim.json](/docs/diagrams/internal/12-agent-onboarding-claim.json)

## 13. Stun: multi-plane containment

An operator's stun request reaches five enforcement planes in parallel.
These are cgroup freeze, mesh/network, OpenBao, SPIRE, and admission.
Each plane has its own SLA. The request records a witnessed attestation before it returns.
Code roots: `apps/fleet-manager/cascade.go`,
[Containment & response runbook](/docs/operate/containment-runbook/).

![Stun: multi-plane containment](/docs/diagrams/internal/13-stun-sequence.svg)

- Interactive diagram: [13-stun-sequence.html](/docs/diagrams/internal/13-stun-sequence.html)
- Diagram source: [13-stun-sequence.json](/docs/diagrams/internal/13-stun-sequence.json)

## 14. Remote resume: dual-signed tokens

Two operators each sign a resume request with their own Ed25519 key.
`fleet-manager` verifies both signatures and the quorum.
It then mints a fresh OpenBao lease, re-enters the SPIRE identity, and sends the unfreeze to the remote warden. Code roots:
`apps/fleet-manager/{cmd/resume-token/main.go,remote_stun_requester.go,resume_token.go}`,
[remote tenant overlay](https://github.com/controlplaneio-in-toto/osramp-demo/tree/HEAD/d2-signalloom/infra/agent-swarm/signalloom-warden-overlays/remote-tenant).

![Remote resume: dual-signed tokens](/docs/diagrams/internal/14-remote-resume.svg)

- Interactive diagram: [14-remote-resume.html](/docs/diagrams/internal/14-remote-resume.html)
- Diagram source: [14-remote-resume.json](/docs/diagrams/internal/14-remote-resume.json)

## 15. Agent lifecycle

The `AgentStateValue` enum that `fleet-manager` and the dashboard share:
absent, deploying, active, non-compliant, grace-period, and stunned, with the
transitions between them. Code root: `apps/fleet-manager/topology.go`.

![Agent lifecycle](/docs/diagrams/internal/15-agent-lifecycle-state.svg)

- Interactive diagram: [15-agent-lifecycle-state.html](/docs/diagrams/internal/15-agent-lifecycle-state.html)
- Diagram source: [15-agent-lifecycle-state.json](/docs/diagrams/internal/15-agent-lifecycle-state.json)

## 16. Tenancy isolation

Ownership, attribution, and policy stay separate for each tenant.
A claim conflict check establishes ownership.
The warden's `SENTINEL_TENANT_MAP` attributes an observation to a pseudonymised actor.
The `signal-ingest` evaluator scopes findings by `tenant_id`.
A per-acting-user rate limit bounds ingest. Code roots: `apps/signal-ingest/policy/convert.go`,
`apps/signalloom-warden`, `apps/signal-ingest/api/auth.go`,
[Claim the two demonstration agents](/docs/agents/dual-agent-onboarding/).

![Tenancy isolation](/docs/diagrams/internal/16-tenancy-isolation.svg)

- Interactive diagram: [16-tenancy-isolation.html](/docs/diagrams/internal/16-tenancy-isolation.html)
- Diagram source: [16-tenancy-isolation.json](/docs/diagrams/internal/16-tenancy-isolation.json)

## 17. Remote tenant path

What actually runs on a secondary pilot cluster: only the `signalloom-warden`
DaemonSet and two centrally-minted secrets. Everything else — OpenBao, SPIRE,
`signal-ingest`, `fe-signalloom` — stays central, reached over the two
gateway routes the warden calls. Code root:
[remote tenant overlay](https://github.com/controlplaneio-in-toto/osramp-demo/tree/HEAD/d2-signalloom/infra/agent-swarm/signalloom-warden-overlays/remote-tenant).

![Remote tenant path](/docs/diagrams/internal/17-remote-tenant-path.svg)

- Interactive diagram: [17-remote-tenant-path.html](/docs/diagrams/internal/17-remote-tenant-path.html)
- Diagram source: [17-remote-tenant-path.json](/docs/diagrams/internal/17-remote-tenant-path.json)
