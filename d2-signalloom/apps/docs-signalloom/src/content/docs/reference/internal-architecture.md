---
title: Internal Architecture
description: Component-level diagrams of the Signal Loom codebase, generated from the repository with SeeCode.
---

The [Architecture diagrams](/docs/reference/architecture-diagrams/) page shows
where each Signal Loom target platform deploys. This page goes one level
deeper: how the components inside a single deployment call each other, keyed
to the Go, Python, and YAML that implements each call. Every diagram below is
a SeeCode spec checked against the source files it names; a label with no
code behind it was dropped rather than guessed.

## 1. Component flows

Runtime traffic across the core platform: the operator's browser through
Envoy Gateway and the dashboard, the `fe-signalloom` API's calls to
`fleet-manager`, `signal-ingest`, and `policy-engine`, and the identity and
secrets planes each of them depend on. Code roots:
`apps/{fe-signalloom,fleet-manager,signal-ingest,policy-engine,signalloom-warden,dashboard-signalloom}`.

![Signal Loom component flows](/docs/diagrams/internal/01-component-flows.svg)

- Interactive diagram: [01-component-flows.html](/docs/diagrams/internal/01-component-flows.html)
- Diagram source: [01-component-flows.json](/docs/diagrams/internal/01-component-flows.json)

## 2. System context and trust boundaries

The external actors (operators, CI, external audit sources), the
`fe-signalloom` namespace, the `inf-bao` identity namespace, and a remote
pilot cluster, drawn as the trust boundaries between them. Code roots:
`AGENTS.md` namespace table, `infra/agent-swarm/signalloom-warden-overlays/remote-tenant`.

![System context and trust boundaries](/docs/diagrams/internal/02-system-context.svg)

- Interactive diagram: [02-system-context.html](/docs/diagrams/internal/02-system-context.html)
- Diagram source: [02-system-context.json](/docs/diagrams/internal/02-system-context.json)

## 3. Ingress and the auth_request gate

How a browser request to `/fleet-api/` or `/dashboard/` is gated by an nginx
`auth_request` subrequest before it ever reaches `fleet-manager` or
`afm-platform`: reads pass untouched, mutating methods need a superadmin
token. Code root: `apps/dashboard-signalloom/nginx.conf`.

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

The per-node daemon: an eBPF probe feeding a capture and correlator, the
cgroup freezer and `tc` network stun it coordinates, and the poll/report/stun
connection back to `fleet-manager` over the hub's shared trust policy. Code
root: `apps/signalloom-warden/{capture,freezer,network,hubtls,fleetpoll}.go`.

![The warden: per-node enforcement](/docs/diagrams/internal/07-warden-node-enforcement.svg)

- Interactive diagram: [07-warden-node-enforcement.html](/docs/diagrams/internal/07-warden-node-enforcement.html)
- Diagram source: [07-warden-node-enforcement.json](/docs/diagrams/internal/07-warden-node-enforcement.json)

## 8. signal-ingest: external collectors to FrostDB

The named collectors that pull audit and telemetry from outside the cluster
(AWS, GCP, Kubernetes, OpenBao, SPIRE, and a planned Workspace SaaS
collector), through the collector registry and sink into FrostDB. Collector
names match the repository's `DIAGRAMS.md` inclusion list. Code root:
`apps/signal-ingest/collectors/{awslogs,gcpaudit,k8saudit,baoaudit,spirea,workspacesaas}`.

![signal-ingest: external collectors to FrostDB](/docs/diagrams/internal/08-signal-ingest-collectors.svg)

- Interactive diagram: [08-signal-ingest-collectors.html](/docs/diagrams/internal/08-signal-ingest-collectors.html)
- Diagram source: [08-signal-ingest-collectors.json](/docs/diagrams/internal/08-signal-ingest-collectors.json)

## 9. policy-engine: bundles to decisions

CEL rule bundles move from `policy/bundles/` in git, through a generated
ConfigMap, into the `obscel.Evaluator` that `signal-ingest`'s sink runs
in-process. The same evaluator also backs the standalone dry-run API. Code
roots: `policy/bundles/`, `apps/signal-ingest/{main.go,policy}`,
`pkg/obscel/cel_eval.go`.

![policy-engine: bundles to decisions](/docs/diagrams/internal/09-policy-engine-pipeline.svg)

- Interactive diagram: [09-policy-engine-pipeline.html](/docs/diagrams/internal/09-policy-engine-pipeline.html)
- Diagram source: [09-policy-engine-pipeline.json](/docs/diagrams/internal/09-policy-engine-pipeline.json)

## 10. KubeSec-AFM: formal RBAC analysis

The dashboard iframes `afm-platform`'s Next.js frontend same-origin through
the `/_afm_gate`, which forwards to a FastAPI backend running a Z3
bounded-model-checking engine over each imported cluster's RBAC graph. Code
roots: `d2-k8s-afm/apps/afm-platform`, `apps/dashboard-signalloom/nginx.conf`,
`docs/signalloom/kubesec-afm-guide.md`.

![KubeSec-AFM: formal RBAC analysis](/docs/diagrams/internal/10-kubesec-afm-rbac.svg)

- Interactive diagram: [10-kubesec-afm-rbac.html](/docs/diagrams/internal/10-kubesec-afm-rbac.html)
- Diagram source: [10-kubesec-afm-rbac.json](/docs/diagrams/internal/10-kubesec-afm-rbac.json)

## 11. GitOps supply chain

A developer's signed push lands in the in-cluster Zot registry; Flux's
`FluxInstance` reconciles an `OCIRepository` through the kustomize and helm
controllers to the API server, where Kyverno and a
`ValidatingAdmissionPolicy` both verify the image signature on admission.
Code roots: `d2-osramp-fleet/{clusters,tenants}`, `policy/kyverno-verify-images.yaml`.

![GitOps supply chain](/docs/diagrams/internal/11-gitops-supply-chain.svg)

- Interactive diagram: [11-gitops-supply-chain.html](/docs/diagrams/internal/11-gitops-supply-chain.html)
- Diagram source: [11-gitops-supply-chain.json](/docs/diagrams/internal/11-gitops-supply-chain.json)

## 12. Agent discovery and claim

A workload heartbeats with its SPIFFE identity, becomes visible inventory,
and an operator claims it into their tenant; the claim is checked for
cross-tenant conflict before it is granted. Code roots:
`apps/fe-signalloom/src/routers/agents.py`, `apps/fe-signalloom/src/api_compat.py`,
[Claim the two demonstration agents](/docs/agents/dual-agent-onboarding/).

![Agent discovery and claim](/docs/diagrams/internal/12-agent-onboarding-claim.svg)

- Interactive diagram: [12-agent-onboarding-claim.html](/docs/diagrams/internal/12-agent-onboarding-claim.html)
- Diagram source: [12-agent-onboarding-claim.json](/docs/diagrams/internal/12-agent-onboarding-claim.json)

## 13. Stun: multi-plane containment

An operator's stun request fans out across five enforcement planes in
parallel — cgroup freeze, mesh/network, OpenBao, SPIRE, and admission — each
under its own SLA, then records a witnessed attestation before returning.
Code roots: `apps/fleet-manager/cascade.go`,
[Containment & response runbook](/docs/operate/containment-runbook/).

![Stun: multi-plane containment](/docs/diagrams/internal/13-stun-sequence.svg)

- Interactive diagram: [13-stun-sequence.html](/docs/diagrams/internal/13-stun-sequence.html)
- Diagram source: [13-stun-sequence.json](/docs/diagrams/internal/13-stun-sequence.json)

## 14. Remote resume: dual-signed tokens

Two operators each sign a resume request with their own Ed25519 key; once
`fleet-manager` verifies both signatures and the quorum, it mints a fresh
OpenBao lease, re-enters the SPIRE identity, and dispatches the unfreeze to
the remote warden. Code roots:
`apps/fleet-manager/{cmd/resume-token/main.go,remote_stun_requester.go,resume_token.go}`,
`infra/agent-swarm/signalloom-warden-overlays/remote-tenant`.

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

How ownership, attribution, and policy stay separated per tenant: a claim
conflict check establishes ownership, the warden's `SENTINEL_TENANT_MAP`
attributes an observation to a pseudonymised actor, `signal-ingest`'s
evaluator scopes findings by `tenant_id`, and a per-acting-user rate limit
bounds ingest. Code roots: `apps/signal-ingest/policy/convert.go`,
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
`infra/agent-swarm/signalloom-warden-overlays/remote-tenant`.

![Remote tenant path](/docs/diagrams/internal/17-remote-tenant-path.svg)

- Interactive diagram: [17-remote-tenant-path.html](/docs/diagrams/internal/17-remote-tenant-path.html)
- Diagram source: [17-remote-tenant-path.json](/docs/diagrams/internal/17-remote-tenant-path.json)
