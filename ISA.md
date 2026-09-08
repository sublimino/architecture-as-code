---
task: "Signal Loom in-cluster agent discovery and autoclaim demonstration"
slug: 20260908-signalloom-agent-discovery-autoclaim
project: osramp-demo
effort: advanced
effort_source: explicit
phase: plan
progress: 0/36
mode: interactive
started: 2026-09-08T19:00:00Z
updated: 2026-09-08T19:05:00Z
---

## Problem

Discovered agents running in the Kubernetes cluster (such as Kagent declarative agents or autonomous pods in `fe-signalloom-agents`) are detected by `fake-integration-proxy` and surfaced on `GET /api/agents`, but remain permanently classified as `record_class="discovered"`, `is_registry_linked=false`, displaying "Registry not linked", "Not assessed", and zero compliance controls. There is no implemented backend claim endpoint (calls to `/api/v1/agents/claim` 404 despite references in `cardvault-agent/autoclaim.go`, `agentClaim.ts`, and `scripts/lib/agent-auto-claim.sh`), no auto-claim reconciler or batch auto-claim API, no UI auto-claim action, and no automated demo target to prove discovering and claiming an external agent into Signal Loom governance.

## Vision

An operator or demo instructor can deploy an autonomous agent via Kagent or a bare Kubernetes manifest in an agent namespace, open Signal Loom, and immediately see the discovered workload flagged as "Discovered (Unclaimed)". With one click in the UI or an automated hook/reconciler (`make demo-signalloom-autoclaim`), the workload is auto-claimed into Signal Loom: bound to a tenant, issued cryptographic SPIFFE origin verification, enrolled in `agent_registry`, evaluated against initial security/compliance policies (generating real posture metrics), and logged to the immutable audit trail (`agent.claimed`). The UI live-updates to show the agent as "Registered / Resolved", with active governance controls, SPIFFE linkage, and posture score.

## Out of Scope

- **No custom out-of-tree OpenBao plugins.** Standard OpenBao JWT auth with glob-bound claims and KV secrets mounts are used.
- **No changes to Kagent upstream CRDs or controller binaries.** Kagent `Agent.kagent.dev` CRs are treated as declarative carriers to discover and claim.
- **No modifications to Envoy Gateway ingress routing definitions.** All communications use existing service and same-origin proxy paths.
- **No bypass of tenant authentication or JWT verification.** Privileged claim operations enforce tenant authorization and record caller identity.

## Principles

- **Discovery before claim.** Workload reality in the cluster is the ground truth; discovery identifies what exists, claim governs it.
- **Zero-unassessed governance.** Claiming an agent is not just a database row insert; it establishes identity linkage (SPIFFE), tenant assignment, baseline policy evaluation, and audit attribution.
- **Idempotent and resilient.** Claiming an already-claimed agent is safe (200 OK / updated), and releasing or unlinking a claim detaches governance without destroying the underlying cluster workload.
- **Provenance over fabrication.** Never invent synthetic attestation or audit history; record verified cluster facts (pod UID, node, namespace, service account, SVID).

## Constraints

- Pure Python (FastAPI/asyncpg) matching `d2-signalloom/apps/fe-signalloom/src/api_compat.py` conventions and error response formats.
- Pure TypeScript/React matching `d2-signalloom/apps/dashboard-signalloom` standards (`bun run build` and `bun test` clean).
- Backward compatibility with existing `/api/agents` and `/supercred-api/agents` contracts.
- All unit and BATS tests must be deterministic and runnable in both fixture and live-cluster environments.

## Goal

Implement and demonstrate end-to-end agent discovery and auto-claim in Signal Loom: create the `/api/v1/agents/claim`, `/api/v1/agents/{id}/claim`, and `/api/v1/agents/autoclaim-discovered` endpoints in `api_compat.py`; wire the UI "Auto-Claim" actions on `/agents` and `/agents/:id`; implement initial compliance evaluation and audit logging on claim; and deliver `make demo-signalloom-autoclaim` with comprehensive BATS and unit tests verifying discovery and autoclaim of running Kagent and cluster workloads.

## Criteria

### Backend & API Claim Contracts

- [ ] ISC-1: `POST /api/v1/agents/claim` accepts `AgentClaimRequest` payload and returns `201 Created` with `AgentClaimResponse`.
- [ ] ISC-2: `POST /api/v1/agents/claim` creates or updates row in `agent_registry` with `lifecycle_state = 'active'` and `status = 'active'`.
- [ ] ISC-3: `POST /api/v1/agents/claim` records SPIFFE identity, namespace, service account, and origin verification metadata.
- [ ] ISC-4: `POST /api/v1/agents/claim` assigns a default or requested token budget limit and binds eBPF sentinel flag.
- [ ] ISC-5: `POST /api/v1/agents/{agent_id}/claim` allows one-click claim of an already-discovered workload by its discovered ID.
- [ ] ISC-6: `POST /api/v1/agents/autoclaim-discovered` batch-claims all discovered unclaimed agents in target namespaces.
- [ ] ISC-7: `GET /api/v1/agents/claims` lists all active claims for the authenticated tenant.
- [ ] ISC-8: `GET /api/v1/agents/claim/{claim_id}` returns detail for a specific claim record.
- [ ] ISC-9: `DELETE /api/v1/agents/claim/{claim_id}` releases a claim and records transition in `audit_events`.
- [ ] ISC-10: Claim endpoints enforce Bearer authentication and reject requests missing valid tenant context.

### Database Schema & Governance Wiring

- [ ] ISC-11: Claiming an agent inserts an immutable `agent.claimed` event into `audit_events` with principal actor attribution.
- [ ] ISC-12: Claiming an agent seeds baseline compliance control results in `agent_compliance_results` so the agent is immediately assessed.
- [ ] ISC-13: Claiming an agent updates `compliance_posture` score in `agent_registry` to reflect initial evaluation.
- [ ] ISC-14: Claiming an agent creates an entry in `agent_origin_verifications` with `origin_type = 'kubernetes_workload'`.
- [ ] ISC-15: Claiming an agent records a transition in `lifecycle_transitions` from `discovered` to `active`.
- [ ] ISC-16: `agent_registry.name` uniqueness is preserved without collisions when claiming workloads.
- [ ] ISC-17: Claiming is idempotent: re-claiming an already-claimed agent updates metadata without 500 error or duplicate rows.

### Agent List & Discovery Reconciliation

- [ ] ISC-18: Discovered workload matching an `agent_registry` row returns with `record_class = 'resolved'` and `is_registry_linked = true`.
- [ ] ISC-19: Claimed agent in `GET /api/agents` displays populated owner/team, active lifecycle state, and compliance summary.
- [ ] ISC-20: Unclaimed discovered agent continues to return `record_class = 'discovered'` with `is_registry_linked = false`.
- [ ] ISC-21: Discovery metadata (namespace, node, pod_uid, framework, model, service_account) is preserved on claimed agents.
- [ ] ISC-22: `fake-integration-proxy` continues to serve discovered pods and Kagent CRs without disruption.

### Dashboard UI Integration

- [ ] ISC-23: `/agents` table renders an "Auto-Claim" action button for any row where `recordClass === 'discovered'`.
- [ ] ISC-24: Clicking "Auto-Claim" triggers the claim API call with loading indicator and visual feedback.
- [ ] ISC-25: Upon successful claim, the table row transitions to "Resolved / Registered" without full page reload.
- [ ] ISC-26: `AgentOverviewTab` and `AgentAccessTab` display "Claim Agent" action when viewing an unclaimed discovered dossier.
- [ ] ISC-27: Claimed agent displays truthful posture score (e.g. percentage) and "Assessed" badge instead of "Not assessed".
- [ ] ISC-28: Claimed agent displays SPIFFE linked status and verified workload origin in `AgentIdentityTab`.
- [ ] ISC-29: `bun run build` in `dashboard-signalloom` passes with zero TypeScript or bundling errors.

### Demonstration & Automation

- [ ] ISC-30: Script `scripts/demo-agent-autoclaim.sh` implements an automated interactive CLI demo.
- [ ] ISC-31: Makefile target `make demo-signalloom-autoclaim` runs the end-to-end discovery and claim demo.
- [ ] ISC-32: Demo finds a live running Kagent agent (e.g. `kagent-k8s-reader`), shows it unclaimed, claims it, and verifies governance.
- [ ] ISC-33: Demo supports deploying an ephemeral shadow agent pod, finding it, and auto-claiming it.
- [ ] ISC-34: BATS test suite `test/signalloom-autoclaim.bats` covers the complete claim lifecycle against live cluster or mock.

### Anti-Criteria

- [ ] ISC-35: Anti: Re-submitting a claim for an already-registered agent must NOT create a duplicate record or return 500.
- [ ] ISC-36: Anti: Claiming an agent under Tenant A must NOT allow Tenant B to read or modify the claimed agent record.

## Test Strategy

```yaml
- isc: ISC-1
  type: functional
  check: POST /api/v1/agents/claim endpoint response
  threshold: HTTP 201 with claim_id, status=granted
  tool: pytest d2-signalloom/apps/fe-signalloom/src/tests/test_agent_claim.py

- isc: ISC-5
  type: functional
  check: POST /api/v1/agents/{id}/claim one-click claim
  threshold: HTTP 200 with agent record linked
  tool: pytest d2-signalloom/apps/fe-signalloom/src/tests/test_agent_claim.py

- isc: ISC-11
  type: data-integrity
  check: audit_events row created on claim
  threshold: event_type = agent.claimed with actor
  tool: psql SELECT COUNT(*) FROM audit_events WHERE event_type = 'agent.claimed'

- isc: ISC-18
  type: contract
  check: GET /api/agents reflects claimed agent as resolved
  threshold: record_class = resolved, is_registry_linked = true
  tool: curl /api/agents with Bearer token

- isc: ISC-29
  type: build
  check: Dashboard TypeScript build
  threshold: bun run build exit 0
  tool: bun run build in d2-signalloom/apps/dashboard-signalloom

- isc: ISC-31
  type: e2e
  check: Makefile demo-signalloom-autoclaim target
  threshold: exits 0 with verified claim evidence
  tool: make demo-signalloom-autoclaim

- isc: ISC-34
  type: regression
  check: BATS test suite
  threshold: 100% tests pass
  tool: bats test/signalloom-autoclaim.bats

- isc: ISC-35
  type: anti-criterion
  check: Duplicate claim idempotency
  threshold: HTTP 200/201, single database row
  tool: pytest d2-signalloom/apps/fe-signalloom/src/tests/test_agent_claim.py

- isc: ISC-36
  type: security
  check: Multi-tenant isolation on claim
  threshold: HTTP 403 / tenant isolation enforced
  tool: pytest d2-signalloom/apps/fe-signalloom/src/tests/test_agent_claim.py
```

## Features

| Feature | Satisfies | Depends On | Parallelizable |
|---------|-----------|------------|----------------|
| Claim API models & endpoints (`api_compat.py`) | ISC-1, ISC-4, ISC-5, ISC-6, ISC-7, ISC-8, ISC-9, ISC-10 | none | yes |
| Database claim transaction & governance seeding | ISC-2, ISC-3, ISC-11, ISC-12, ISC-13, ISC-14, ISC-15, ISC-16, ISC-17 | Claim API models | no |
| Discovery-to-Registry reconciliation & overlay | ISC-18, ISC-19, ISC-20, ISC-21, ISC-22 | Database claim | no |
| Dashboard UI Auto-Claim buttons & state update | ISC-23, ISC-24, ISC-25, ISC-26, ISC-27, ISC-28, ISC-29 | Claim endpoints | yes |
| CLI Demo Runner (`scripts/demo-agent-autoclaim.sh`) & Makefile | ISC-30, ISC-31, ISC-32, ISC-33 | UI & API | no |
| Automated BATS and Pytest test suites | ISC-34, ISC-35, ISC-36 | all above | no |

## Decisions

- 2026-09-08: Selected `POST /api/v1/agents/claim` as canonical endpoint matching `agent-auto-claim.sh`, `cardvault-agent/autoclaim.go`, and `agentClaim.ts`.
- 2026-09-08: Added `POST /api/v1/agents/{agent_id}/claim` to enable simple one-click claim from the UI using discovered workload ID.
- 2026-09-08: Added `POST /api/v1/agents/autoclaim-discovered` to allow bulk automated reconciliation of all discovered agents in an agent namespace.
- 2026-09-08: Initial governance on claim automatically seeds 6 standard compliance controls (`POL-SEC-01` through `POL-SEC-06`) and assigns initial posture score to avoid leaving newly claimed agents as "Not assessed".

## Changelog

- 2026-09-08: Initialized ISA for Signal Loom in-cluster agent discovery and autoclaim demonstration.

## Verification

*(Pending execution after plan approval)*
