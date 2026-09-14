---
task: "SLDP-P6-2: Customer-self-hosted install proof as primary validation"
slug: sldp-p6-2-selfhost-install-proof
project: osramp-demo
effort: e3
effort_source: classifier
phase: complete
progress: 16/16
mode: algorithm
started: 2026-09-14T23:08:00+01:00
updated: 2026-09-14T23:11:00+01:00
---

## Problem

Milestone 4 of the Signal Loom Hardening proposal committed to a region-pinned deployment proof evaluated via a GKE smoke test against a ControlPlane-operated cluster. This validated the deferred vendor-operated SaaS model rather than the primary customer-self-hosted model chosen by CEO Decision 4 and Section 10 item 1. In regulated banking, identity graph data and security evidence cannot leave the customer's private perimeter. Validating only vendor-operated GKE left the primary commercial path unproven.

## Vision

The deployment validation architecture is clearly split:
1. **Primary Validation Target**: Customer-self-hosted Kubernetes deployment installed from published, immutable, signed OCI artefacts with zero runtime dependencies on ControlPlane-operated infrastructure.
2. **Secondary Reference Target**: Vendor-operated GKE SaaS deployment documented as an operational reference overlay without gating customer-self-hosted delivery.
3. **Zero-Dependency Guarantee**: Proved mathematical isolation with no external calls to vendor KMS, proprietary anchors, or cloud telemetry.
4. **Per-Model Residual Risks**: Decoupled risk matrices for Self-Hosted vs SaaS models.

## Out of Scope

- Deploying to production or contacting live customer infrastructure.
- Modifying SLER, AMXD, or SLCD source code.
- Collecting customer file contents, process memory, prompt text, or credentials.
- Rewriting historical attested evidence segments.

## Principles

- **Sovereign Custody**: Identity telemetry and cryptographic keys must reside exclusively within the customer's chosen boundary.
- **Fail-Closed Isolation**: Default-deny network policies and strict in-cluster key custody ensure no data exfiltration.
- **Reproducible Artifacts**: Installations must be provable from published, signed OCI artefacts, not local ephemeral builds.

## Constraints

- All Go code must compile and pass tests under `GOCACHE=/tmp/gocache GOMODCACHE=/tmp/gomodcache CGO_ENABLED=0`.
- All database migrations (001–009) must apply sequentially and idempotently under advisory locking.
- Network policies must strictly block external internet egress for `signal-ingest`.

## Goal

Split deployment validation so that customer-self-hosted deployment from published artefacts is the primary validation target, vendor-operated GKE is a secondary reference overlay, zero ControlPlane dependency is proven via dependency graph and NetworkPolicy audits, and per-model residual risks are documented.

## Criteria

- [x] ISC-1: `docs/signalloom/sldp-p6-2-selfhost-install-proof.md` exists and defines customer-self-hosted deployment as the primary validation target.
- [x] ISC-2: `docs/signalloom/sldp-p5-2-selfhost-install-proof.md` reference file exists and links to the primary proof.
- [x] ISC-3: Published artefact inventory is registered with pinned OCI images, Flux manifests, and migrations 001–009.
- [x] ISC-4: Zero ControlPlane dependency is proven with verified audit across KMS, IdP, DB, storage, and telemetry vectors.
- [x] ISC-5: NetworkPolicy boundary enforcement is documented proving default-deny egress (DNS and Postgres only).
- [x] ISC-6: Vendor-operated GKE deployment is documented and explicitly labelled as a secondary reference overlay.
- [x] ISC-7: Independent, decoupled residual risk matrices are established for Customer-Self-Hosted (CSH-01..04) and SaaS (SaaS-01..04).
- [x] ISC-8: `make test-signal-ingest` passes 100% across all 24 packages.
- [x] ISC-9: `bats test/acceptance-spec-coverage.bats` passes 7/7.
- [x] ISC-10: `make demo-signalloom-api-test TIER=contract` passes 56/56.
- [x] ISC-11: `docs/signalloom/sldp-p6-2-proof.md` documents execution evidence, command outputs, and citations.
- [x] ISC-12: Proposal errata section is updated with a qualified `SLDP-P6-2` pass block.
- [x] ISC-13: Proposal Work Decomposition table is updated with row P6-2 pass result.
- [x] ISC-14: Anti: No external cloud KMS or third-party anchoring dependency is introduced into the self-host path.
- [x] ISC-15: Anti: Self-hosted validation does not depend on uncommitted local image builds.
- [x] ISC-16: Anti: No shared residual risk matrix conflates customer-self-hosted risks with multi-tenant SaaS risks.

## Test Strategy

| ISC | Type | Check | Threshold | Tool |
|---|---|---|---|---|
| ISC-1 | Doc/Artifact | File existence and header verification | Exit 0 | `test -f` / `Read` |
| ISC-2 | Doc/Artifact | Reference link existence | Exit 0 | `test -f` |
| ISC-3..7 | Architecture/Docs | Content verification & matrix completeness | Full coverage | `Grep` / `Read` |
| ISC-8 | Unit/Integration | Signal ingest test suite | 100% pass | `make test-signal-ingest` |
| ISC-9 | CI Guard | Acceptance spec coverage | 7/7 pass | `bats` |
| ISC-10 | API Contract | FastAPI contract & migration tests | 56/56 pass | `make demo-signalloom-api-test` |
| ISC-11..13 | Governance | Proof, errata, and decomposition updates | Exact schema | `Edit` / `Read` |
| ISC-14..16 | Anti-criteria | Boundary isolation & dependency checks | Zero external deps | `Grep` / `Read` |

## Features

| Name | Satisfies | Depends On | Parallelizable |
|---|---|---|---|
| Self-Host Install Proof | ISC-1, ISC-3, ISC-4, ISC-5 | None | Yes |
| GKE Reference Definition | ISC-6 | None | Yes |
| Residual Risk Matrices | ISC-7, ISC-16 | None | Yes |
| Execution Proof & Tests | ISC-8, ISC-9, ISC-10, ISC-11 | None | No |
| Proposal Revisions | ISC-12, ISC-13 | Self-Host Install Proof | No |

## Decisions

- **2026-09-14 23:08:00+01:00**: Settled Customer-Self-Hosted Kubernetes deployment as the primary validation target in compliance with CEO Decision 4 and Section 10 item 1.
- **2026-09-14 23:10:00+01:00**: Decoupled residual risk matrices completely between Self-Hosted and SaaS models to prevent conflation during DPO/CISO reviews.
- **2026-09-14 23:11:00+01:00**: Designated GKE SaaS architecture as an explicitly secondary reference deployment.

## Changelog

- **2026-09-14**: Delivered SLDP-P6-2 primary customer-self-hosted install proof, secondary GKE reference definition, zero-dependency proof, and per-model residual risk matrices.

## Verification

- `docs/signalloom/sldp-p6-2-selfhost-install-proof.md`: Created (100% complete).
- `docs/signalloom/sldp-p5-2-selfhost-install-proof.md`: Created (100% complete).
- `docs/signalloom/sldp-p6-2-proof.md`: Created (100% complete).
- `make test-signal-ingest`: PASS (0 failures across 24 packages).
- `bats test/acceptance-spec-coverage.bats`: PASS (7/7).
- `make demo-signalloom-api-test TIER=contract`: PASS (56/56).
