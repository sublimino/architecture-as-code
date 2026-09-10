---
created: 2026-09-10T09:06:00+01:00
reviewers:
  - "#stefan-prodan"
  - "#fabian-kammel"
capabilities:
  - "#cap-architecture"
  - "#cap-frontend"
  - "#cap-golang"
  - "#cap-linux"
  - "#cap-security"
  - "#cap-spiffe-openbao"
  - "#cap-testing-pyramid"
  - "#cap-documentation"
practice:
  - AI & Data Security
  - Cloud Native Transformation & DevSecOps
tags:
  - innovation-proposals
  - proposal-2026-q3-agentmaxxing-signalloom-onboarding
  - partner-agentmaxxing
  - signal-loom
aliases:
  - "#proposal-2026-q3-agentmaxxing-signalloom-onboarding"
updated: 2026-09-10T09:06:00+01:00
shortcode: AMXO
---

# Proposal — AgentMaxxing Signal Loom User and External Agent Onboarding (2026-Q3)

| | |
| :--- | :--- |
| Proposer & Date | AJM, 2026-09-10 |
| Design partner | AgentMaxxing Incorporated |
| Reviewer & Date | To be assigned |
| Approver & Date | To be assigned |

## Press Release

**Signal Loom today onboarded AgentMaxxing Incorporated's first attributable
operator and first externally hosted Linux agent, producing integrity-checked
execution evidence without collecting customer data contents.**

AgentMaxxing can now demonstrate who operated its agent, which approved runtime
profile governed it, when it executed, where it connected, and which approved
disk artifacts changed. Signal Loom presents these observations on one agent
timeline and clearly marks evidence that the integration cannot observe.

The initial delivery uses nono 0.73.0 as the Linux sandbox and execution-audit
foundation. A dedicated host integration enrolls the external process, verifies
finalized nono sessions, and collects bounded process and disk metadata. It does
not inspect memory, streamed payloads, file contents, or payload contents.

## Proposal Overview

### Opportunity

**The work relates to the following value areas:**

- [x] client revenue
- [x] product
- [x] services engineering
- [x] operational or regulatory internal
- [ ] marketing

**Key customer:** AgentMaxxing Incorporated, the first named Signal Loom design
partner for this external-agent onboarding path.

| | |
| :--- | :--- |
| AgentMaxxing needs | One attributable user and one Linux-hosted agent enrolled into Signal Loom. |
| Current evidence gap | Signal Loom does not ingest nono sessions from an external Linux host. |
| Agent behaviour | The process reads approved filesystem data, synthesizes results, and sends results over the network. |
| Desired outcome | Signal Loom shows trustworthy metadata while preserving explicit privacy boundaries. |

**Urgency:** 2026-Q3. The work converts the existing demonstration into a
design-partner onboarding path and tests whether Signal Loom's evidence model
extends safely beyond Kubernetes.

## Scope Summary

**Technology Readiness Level:** 2 (Alpha) to 3 (validated Alpha).

### In Scope Activities

| Deliverable | Acceptance criteria | Validation method |
| :--- | :--- | :--- |
| Attributable user provisioning | One individually identified AgentMaxxing operator signs in; shared credentials are rejected; access removal prevents a later sign-in. | Identity-provider audit, browser test, and removal test. |
| External agent registration | One external Linux agent record is tenant-bound before host enrollment; duplicate identity claims are rejected. | API contract and tenant-isolation tests. |
| Nono runtime profile | The agent starts only through the approved nono 0.73.0 profile; unapproved filesystem access and network destinations are denied. | Seeded positive and negative execution probes. |
| External-host enrollment | One-time enrollment produces an audit-only host identity bound to one tenant and one agent. | Enrollment, replay, and unenrollment tests. |
| Finalized-session ingestion | Signal Loom idempotently accepts a finalized session only after its audit chain verifies. | Valid, duplicate, incomplete, and tampered-session tests. |
| Process metadata sensor | Signal Loom records process health, CPU, memory usage, exit status, and restart count without reading process memory. | Host fixture and API integration tests. |
| Bounded disk-artifact hashing | The sensor hashes only regular files created or changed inside approved writable roots. | Filesystem boundary test matrix. |
| Evidence presentation | The agent timeline displays evidence source, timestamp, integrity state, and collection limit. | Browser assertions against seeded evidence. |
| Operator documentation | The documentation describes onboarding, evidence boundaries, removal, and recovery. | Astro build and documentation BATS tests. |

### Evidence Contract

Nono provides command and session metadata, executable SHA-256, audit-chain
integrity, network-proxy events, and optional pre/post Merkle roots for tracked
writable paths. A Merkle root is not evidence of individual file reads or
individual file writes.

The additional host sensor can hash an individual disk artifact only when the
artifact:

1. was created or changed during the bounded observation window;
2. remains beneath an approved writable root;
3. is a regular file on the approved mount;
4. has one hard link;
5. retains the same device and inode before and after hashing; and
6. remains within configured size and rate limits.

Signal Loom must reject symbolic links, hard-link escapes, mount crossings,
non-regular files, and replacement races.

### Privacy Boundary

The initial integration must not collect:

- read-only input-file digests;
- file contents;
- process memory contents;
- in-memory synthesis contents;
- streamed payload digests;
- streamed payload contents; or
- network payload contents.

The product must present absent evidence as **unobserved**, not as successful,
unchanged, or compliant.

### Out of Scope

- Supporting non-Linux agent hosts.
- Running the first AgentMaxxing agent inside Kubernetes.
- Inspecting process memory.
- Capturing filesystem or network payload contents.
- Hashing every file that the agent reads.
- Reconstructing memory-only or streamed synthesis results.
- Production multi-region enrollment.
- Mandating nono for unrelated Signal Loom agents.

## Technical Overview

### Proposed Evidence Path

1. systemd starts one dedicated service.
2. nono supervises the agent under one approved profile.
3. nono writes an integrity-protected audit session.
4. The host sensor emits bounded process and disk metadata.
5. The ingestion API verifies source identity and session integrity.
6. Signal Loom stores idempotent evidence against the registered agent.
7. The dashboard renders observations and explicit collection limits.

### Security Boundaries

| Boundary | Required control | Negative test |
| :--- | :--- | :--- |
| User identity | Individual identity with attributable audit events. | Shared or removed identity cannot sign in. |
| Tenant authorization | Derive tenant scope from authenticated identity. | Cross-tenant agent claim returns a denial. |
| Host enrollment | Single-use token producing an audit-only credential. | Enrollment-token replay is rejected. |
| Ingestion | Verify host binding and finalized audit-chain integrity. | Tampered or incomplete session is rejected. |
| Filesystem | Pin the approved root and refuse unsafe file identities. | Symlink, hard-link, mount, and race fixtures are rejected. |
| Network | Allow only named destinations through the nono proxy. | One unapproved destination is blocked. |
| Supply chain | Pin and verify the nono binary and host-sensor artifact. | Unapproved digest prevents service startup. |
| Removal | Revoke operator and host identities independently. | Removed host cannot upload another session. |

### Supporting Documentation

| Journey | Evidence source |
| :--- | :--- |
| Current implemented first-agent demonstration | [`d2-signalloom/apps/docs-signalloom/src/content/docs/start/first-agent.md`](../d2-signalloom/apps/docs-signalloom/src/content/docs/start/first-agent.md) |
| Planned AgentMaxxing external Linux integration | [`d2-signalloom/apps/docs-signalloom/src/content/docs/start/external-linux-agent.mdx`](../d2-signalloom/apps/docs-signalloom/src/content/docs/start/external-linux-agent.mdx) |
| Existing first-user evidence analysis | [`docs/FIRST-USER-ONBOARDING-PROPOSAL.md`](FIRST-USER-ONBOARDING-PROPOSAL.md) |

## Milestones and Deliverables

Durations, staffing, deadlines, and person-days remain uncommitted until the
kickoff gates below close.

| Milestone | Outcome | Capability mapping |
| :--- | :--- | :--- |
| M1: Contract and identity | Named operator, selected identity source, tenant binding, agent record, and approved authorization matrix. | #cap-architecture, #cap-security, #cap-frontend |
| M2: Nono host enrollment | Pinned nono profile, systemd unit, one-time enrollment, audit-only host credential, and revocation path. | #cap-linux, #cap-security, #cap-spiffe-openbao |
| M3: Evidence ingestion | Verified finalized-session ingestion, replay protection, external-host identity, and process metadata. | #cap-golang, #cap-security, #cap-testing-pyramid |
| M4: Disk evidence | Bounded per-file hashing for approved writable roots and the complete anti-escape test matrix. | #cap-linux, #cap-security, #cap-testing-pyramid |
| M5: Partner acceptance | Documentation, browser journey, seeded denials, evidence-limit display, recovery, and removal tests. | #cap-documentation, #cap-frontend, #cap-testing-pyramid |

**Total estimated effort:** to be estimated with the delivery team after kickoff
gates close.

### Kickoff Gates

- Name the AgentMaxxing operator.
- Select the operator identity source.
- Approve the route and action authorization matrix.
- Confirm the executable path and systemd service owner.
- Approve readable roots, writable roots, and network destinations.
- Set artifact-hash size and rate limits.
- Name user-removal and host-unenrollment owners.
- Set evidence-retention and deletion periods.

### Definition of Done

- The named operator completes sign-in through an individual identity.
- The registered agent starts only through the approved nono profile.
- Signal Loom receives one verified session without manual import.
- Process metadata appears on the correct tenant-bound agent timeline.
- Changed disk-artifact hashes pass every filesystem boundary check.
- One filesystem denial appears as denied evidence.
- One unapproved network destination is blocked.
- Memory and streamed data appear as unobserved.
- Revoking host enrollment prevents a later upload.
- Removing the operator prevents a later sign-in.
- The external-agent guide builds and renders its evidence diagram.

## Decision Log

| Date | Decision | Reason |
| :--- | :--- | :--- |
| 2026-09-10 | Use AgentMaxxing Incorporated as the named design partner. | The initial path requires a concrete customer boundary. |
| 2026-09-10 | Limit the initial agent host to Linux. | Nono 0.73.0 supplies the selected confinement foundation. |
| 2026-09-10 | Hash only created or changed disk files. | Native nono evidence does not expose every input digest. |
| 2026-09-10 | Exclude contents, memory, and streamed payloads. | Metadata proves the control path without collecting customer data. |
| 2026-09-10 | Keep estimates uncommitted before kickoff. | Host paths, identity choice, retention, and limits remain undecided. |

## Risks

| Risk | Impact | Mitigation |
| :--- | :--- | :--- |
| Evidence overclaim | Operators infer observation that never occurred. | Display source and collection limit on each evidence item. |
| Tenant identity mismatch | Evidence appears against the wrong customer or agent. | Enforce authenticated tenant and pre-registered agent bindings. |
| Filesystem escape | Hashing reads data outside the approved root. | Use pinned roots, no-follow opens, mount checks, and identity revalidation. |
| Credential exposure | Agent execution exposes long-lived secrets. | Use brokered credentials and an audit-only host identity. |
| Unbounded hashing | Large or frequent changes degrade the host. | Enforce approved roots, size limits, rate limits, and telemetry. |
| Premature production claim | Design-partner validation is presented as general availability. | Retain Alpha status until acceptance evidence passes. |

## Review and Acceptance

The architecture reviewer validates identity, tenancy, ingestion, and evidence
semantics. The security reviewer validates nono policy, anti-escape handling,
credential use, revocation, and supply-chain controls. AgentMaxxing validates
the approved host paths, destinations, operator journey, collection limits, and
deletion expectations before implementation begins.
