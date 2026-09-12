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

The following press release describes the intended state after acceptance. It
does not describe the current implementation.

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

| Deliverable | Atomic acceptance criterion | Validation method |
| :--- | :--- | :--- |
| Operator sign-in | One individually identified AgentMaxxing operator can sign in. | Identity-provider audit and browser sign-in test. |
| Shared identity rejection | A shared operator identity cannot complete onboarding. | Negative identity-policy test. |
| Operator removal | Removing the operator prevents a later sign-in. | Identity-removal integration test. |
| Agent registration | One external Linux agent record is tenant-bound before enrollment. | API contract test. |
| Duplicate agent claim | A duplicate external-agent identity claim is rejected. | Conflict and tenant-isolation test. |
| Nono runtime | systemd starts the agent only through the approved nono 0.73.0 profile. | Service command-line and executable-digest test. |
| Filesystem confinement | The nono profile denies one unapproved filesystem access. | Seeded filesystem-denial probe. |
| Network confinement | The nono profile denies one unapproved network destination. | Seeded network-denial probe. |
| Host credential scope | Enrollment produces an audit-only host credential. | Authorization-policy test. |
| Host binding | The enrolled host identity binds to one tenant-bound agent. | Enrollment API integration test. |
| Enrollment replay | Reusing the one-time enrollment token is rejected. | Token-replay test. |
| Host revocation | Revoking host enrollment prevents a later upload. | Revocation integration test. |
| Valid session ingestion | One finalized session is accepted after audit-chain verification. | Valid-session integration test. |
| Duplicate session ingestion | Replaying an accepted session creates no duplicate evidence. | Idempotency integration test. |
| Incomplete session rejection | An incomplete nono session is rejected. | Negative ingestion test. |
| Tampered session rejection | A nono session with a broken audit chain is rejected. | Tamper fixture test. |
| Process health | The host sensor records the process health state. | Host-sensor fixture test. |
| CPU metadata | The host sensor records bounded CPU usage metadata. | Host-sensor fixture test. |
| Memory metadata | The host sensor records usage totals without reading memory contents. | Host-sensor privacy test. |
| Exit metadata | The host sensor records the process exit status. | Controlled-exit fixture test. |
| Restart metadata | The host sensor records the systemd restart count. | Controlled-restart fixture test. |
| Eligible artifact hash | One changed regular file beneath an approved writable root receives a digest. | Positive filesystem fixture. |
| Symbolic-link rejection | A symbolic-link path produces no artifact digest. | Symbolic-link escape fixture. |
| Hard-link rejection | A file with multiple hard links produces no artifact digest. | Hard-link escape fixture. |
| Mount-crossing rejection | A path crossing the approved mount produces no artifact digest. | Bind-mount escape fixture. |
| Non-regular rejection | A non-regular file produces no artifact digest. | Device, socket, pipe, and directory fixtures. |
| Replacement-race rejection | A file changed during hashing produces no accepted digest. | Concurrent-replacement fixture. |
| Evidence source | Each displayed evidence item names its collection source. | Browser assertion against seeded evidence. |
| Evidence timestamp | Each displayed evidence item includes its observed timestamp. | Browser assertion against seeded evidence. |
| Integrity state | Each displayed evidence item shows its integrity result. | Browser assertion against seeded evidence. |
| Collection limit | Each displayed evidence item states its observation limit. | Browser assertion against seeded evidence. |
| Operator documentation | The external-agent page builds without diagnostics. | Astro check and build. |
| Evidence diagram | The external-agent evidence flow renders as an SVG. | Browser rendering assertion. |

### Evidence Contract

Nono provides command and session metadata, executable SHA-256, audit-chain
integrity, network-proxy events, and optional pre/post Merkle roots for tracked
writable paths. A Merkle root is not evidence of individual file reads or
individual file writes.

The additional host sensor can hash an individual disk artifact only when the
artifact:

1. was created or changed during the bounded observation window;
2. opens descriptor-relative from a pinned approved-root descriptor;
3. opens through `openat2()` using `RESOLVE_BENEATH`,
   `RESOLVE_NO_SYMLINKS`, and `RESOLVE_NO_XDEV`;
4. is a regular file on the approved mount;
5. has one hard link;
6. remains within configured size and rate limits; and
7. retains the same inode, mount ID, link count, size, and mutation timestamps
   before and after hashing.

The sensor must hash only through the validated descriptor. It must use `fstat`
and `statx(STATX_MNT_ID)` before reading. It must repeat identity and mutation
checks after reading, before accepting the digest. Signal Loom must reject
symbolic links, hard-link escapes, mount crossings, non-regular files, and
replacement races without first reading an escaped target.

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
| Filesystem | Use descriptor-relative `openat2()` beneath a pinned root; hash only the validated descriptor. | Symlink, hard-link, bind-mount, non-regular, and replacement fixtures are rejected before escaped bytes are read. |
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
- A changed regular file inside the approved root receives a digest.
- A symbolic-link path produces no digest.
- A multiply linked file produces no digest.
- A path crossing a bind mount produces no digest.
- A non-regular file produces no digest.
- A file replaced during hashing produces no accepted digest.
- One filesystem denial appears as denied evidence.
- One unapproved network destination is blocked.
- Memory and streamed data appear as unobserved.
- Revoking host enrollment prevents a later upload.
- Removing the operator prevents a later sign-in.
- The external-agent guide builds without diagnostics.
- The external-agent evidence diagram renders as an SVG.

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

## Appendix

### Spec: Shared Patterns

#### Mission identity

| Field | Contract |
| :--- | :--- |
| Repository | `/home/andy/src/cp/osramp-demo` |
| Shortcode | `AMXO` |
| Integration branch | `integration/agentmaxxing-onboarding-v0.1.0` |
| Integration owner | Governor worktree only |
| Current state | Bootstrap draft; no implementation work has started |
| Approval state | Unapproved until Andrew explicitly signs off this Appendix |

#### Architectural constitution

- Phase 1 freezes named partner decisions before implementation begins. Placeholder values never satisfy its Governor.
- Go `signal-ingest/collectors/agentnono` is the session-integrity authority. FastAPI remains the tenant-facing identity, registration, authorization, audit, and read plane. Implementors must not create a second independent audit-chain verifier.
- External host identity always binds to one pre-registered tenant-agent pair. Tenant scope comes from authenticated server-side identity, never request-supplied tenant fields.
- Enrollment tokens are single-use and atomically consumed. Resulting credentials are audit-upload-only and independently revocable from operator identity.
- Host evidence is assertion data with explicit source provenance. Ingestion acceptance is recorded separately as a server-observed audit event.
- The host sensor opens eligible artifacts descriptor-relative beneath pinned approved-root descriptors using `openat2()` with `RESOLVE_BENEATH`, `RESOLVE_NO_SYMLINKS`, and `RESOLVE_NO_XDEV`.
- Artifact identity is checked before and after hashing. Changed inode, mount ID, link count, size, or mutation timestamps invalidate the digest.
- Collection uses a field-level export allowlist. Raw nono records, commands, paths, URLs, errors, file contents, memory contents, and payload contents are not exported unless the frozen contract names a safe field explicitly.
- `observed`, `denied`, `unobserved`, and `integrity-verified` are distinct states. Integrity never implies completeness or a trustworthy host.
- Database migrations follow the existing numbered migration pattern. Composition roots, registries, manifests, route wiring, and acceptance registries are reconciled only by the phase Governor where parallel-card collisions exist.

#### Canonical locations

| Concern | Canonical location |
| :--- | :--- |
| Operator records | `d2-signalloom/apps/fe-signalloom/src/db/migrations/008_platform_users.sql` |
| Authentication and tenant authorization | `d2-signalloom/apps/fe-signalloom/src/api_compat.py` |
| Agent claim lifecycle | `d2-signalloom/apps/fe-signalloom/src/agent_claim.py` and migrations `035`–`036` |
| Existing signed-session model | `d2-signalloom/apps/fe-signalloom/src/audit_ingest.py` and migration `037_signed_audit_sessions.sql` |
| Nono wire types and verifier | `d2-signalloom/apps/signal-ingest/collectors/agentnono/` |
| Nono ingestion HTTP boundary | `d2-signalloom/apps/signal-ingest/api/handlers.go` |
| Shared Signal evidence type | `d2-signalloom/apps/signal-ingest/model/signal.go` |
| New Linux host component | `d2-signalloom/apps/agentmaxxing-host-sensor/` |
| Dashboard API types | `d2-signalloom/apps/dashboard-signalloom/src/types/api.ts` |
| Agent evidence timeline | `d2-signalloom/apps/dashboard-signalloom/src/pages/AgentDetailPage.tsx` |
| External-agent documentation | `d2-signalloom/apps/docs-signalloom/src/content/docs/start/external-linux-agent.mdx` |
| Acceptance registry | `test/acceptance/SPEC-REGISTRY.tsv` |

#### Testing standards

- Test contracts precede implementations in each phase and fail for the expected missing behavior before implementation proceeds.
- Security boundaries require positive and negative tests. Error status alone is insufficient where escaped bytes or prohibited metadata might already have been read.
- Concurrency tests cover token redemption, duplicate upload, and interrupted-transaction retry.
- Filesystem tests use real Linux syscalls and independently prove escaped targets were never read.
- Browser tests use Playwright web-first assertions and register exactly once in `test/acceptance/SPEC-REGISTRY.tsv`.
- BATS and shell workflows source `scripts/lib/wait.sh`; fixed sleeps are prohibited.
- Cluster-dependent, browser-dependent, network-dependent, and partner-dependent evidence is labelled explicitly in Errata.
- A passing generic suite never substitutes for a proposal-specific assertion. Governors report skips and require zero unexpected skips.
- Final acceptance remains Alpha evidence and cannot claim production, multi-region, or general-availability readiness.

#### Approved acceptance command set proposed for sign-off

```bash
make demo-agentmaxxing-contract-test
make demo-agentmaxxing-host-test
make demo-agentmaxxing-ingest-test
make demo-agentmaxxing-ui-test
make demo-agentmaxxing-docs-test
make demo-agentmaxxing-acceptance-test
bats test/acceptance-spec-coverage.bats
```

These targets are part of the reviewed deliverable and do not exist yet. Their creation is explicitly assigned below. No target may contact production or require an external AgentMaxxing host. The final partner review is recorded evidence, not an automated command.

#### Anti-patterns

- Do not accept tenant, actor, integrity, or audit outcome fields as client authority.
- Do not extend both FastAPI and Go chain verifiers independently.
- Do not equate UI hiding with authorization enforcement.
- Do not treat an audit-chain match as host trust or observation completeness.
- Do not follow paths from strings after validating a different path object.
- Do not hash symlinks, multiply linked files, mount crossings, or non-regular files.
- Do not export raw records first and redact them after persistence.
- Do not label absent evidence successful, unchanged, compliant, or verified.
- Do not edit shared composition roots from parallel implementation cards.
- Do not run production deploys, destructive cleanup, or external partner actions autonomously.

### Spec: Capability Plan

| Logical ID | Selected skills | Agent role | Size | Ceiling | CPAI agent | Rationale |
| :--- | :--- | :--- | :--- | ---: | :--- | :--- |
| P0 | ajm-auto-kanban; ripwire-before-you-build | Harness engineer | S | 45m | fast | Prove mission tooling, repository identity, and read-only baseline. |
| P1-PRE | FirstPrinciples; ripwire-before-you-build | Contract architect | S | 45m | daily | Inventory unresolved decisions and existing dual-ingestion ownership. |
| P1-1 | FirstPrinciples; Agents | Partner decision facilitator | M | 90m | daily | Freeze attributable operator, identity source, authorization, and ownership decisions. |
| P1-2 | FirstPrinciples; Security | Security architect | M | 90m | daily | Freeze host paths, network destinations, limits, retention, and threat assumptions. |
| P1-3 | ripwire-before-you-build; Security | Integration architect | L | 150m | deep | Publish versioned enrollment, upload, evidence, privacy, and service-ownership contracts. |
| P1-GOV | CodeReview; ripwire-change-check | Architecture Governor | M | 90m | deep | Reject placeholders and approve the frozen implementation boundary. |
| P2-PRE | ripwire-before-you-build; ripwire-write-tests | Identity pre-flight engineer | S | 45m | daily | Confirm reusable identity and claim seams after contract merge. |
| P2-1 | ripwire-write-tests; Security | Identity engineer | L | 150m | daily | Implement attributable operator lifecycle and shared-identity rejection. |
| P2-2 | ripwire-write-tests; ripwire-security-scan | Backend engineer | L | 150m | daily | Implement tenant-bound external-agent registration and duplicate-claim rejection. |
| P2-GOV | CodeReview; ripwire-change-check | Identity Governor | M | 90m | deep | Merge identity work and prove server-side authorization boundaries. |
| P3-PRE | ripwire-before-you-build; ripwire-write-tests | Enrollment pre-flight engineer | S | 45m | daily | Revalidate identity contracts and OpenBao/SPIFFE integration seams. |
| P3-1 | ripwire-write-tests; ripwire-security-scan | Enrollment engineer | L | 150m | daily | Implement atomically consumed one-time host enrollment. |
| P3-2 | ripwire-write-tests; Security | Authorization engineer | L | 150m | daily | Implement audit-only credential matrix and tenant-agent binding. |
| P3-3 | ripwire-write-tests; Security | Revocation engineer | M | 90m | daily | Implement independent host revocation and denied subsequent upload. |
| P3-GOV | CodeReview; ripwire-change-check | Enrollment Governor | M | 90m | deep | Merge enrollment work and falsify token or credential overreach. |
| P4-PRE | ripwire-before-you-build; ripwire-reuse-first | Linux pre-flight engineer | S | 45m | daily | Confirm kernel, nono, systemd, and accepted upload contracts. |
| P4-1 | ripwire-write-tests; ripwire-security-scan | Linux confinement engineer | L | 150m | daily | Build pinned nono profile, systemd service, and digest gate. |
| P4-2 | ripwire-write-tests; Security | Host telemetry engineer | M | 90m | daily | Emit bounded process health, CPU, memory-use, exit, and restart metadata. |
| P4-3 | ripwire-write-tests; ripwire-security-scan | Filesystem security engineer | L | 150m | deep | Implement descriptor-relative eligibility and pre-read escape rejection. |
| P4-4 | ripwire-write-tests; ripwire-security-scan | Filesystem race engineer | L | 150m | deep | Implement bounded hashing, post-read validation, and replacement-race rejection. |
| P4-GOV | CodeReview; ripwire-change-check | Host Governor | L | 150m | deep | Merge host work and prove confinement plus no escaped reads. |
| P5-PRE | ripwire-before-you-build; ripwire-write-tests | Ingestion pre-flight engineer | S | 45m | daily | Confirm host fixtures and single integrity-authority ownership. |
| P5-1 | ripwire-write-tests; ripwire-security-scan | Go ingestion engineer | L | 150m | daily | Accept only finalized correctly bound audit-chain sessions. |
| P5-2 | ripwire-write-tests; Security | Reliability engineer | L | 150m | daily | Enforce replay idempotency, concurrent duplicates, and transactional retries. |
| P5-3 | ripwire-write-tests; Security | Data-contract engineer | L | 150m | daily | Persist allowlisted evidence and expose tenant-scoped read projections. |
| P5-GOV | CodeReview; ripwire-change-check | Ingestion Governor | L | 150m | deep | Merge ingestion work and prove privacy plus integrity semantics. |
| P6-PRE | ripwire-before-you-build; Browser | Experience pre-flight engineer | S | 45m | daily | Freeze accepted API projection and UI evidence vocabulary. |
| P6-1 | Browser; ripwire-write-tests | React evidence engineer | L | 150m | daily | Render source, timestamp, integrity, limit, and unobserved states accessibly. |
| P6-2 | Drawio; Browser | Documentation engineer | M | 90m | daily | Complete external-agent guide and verified SVG evidence diagram. |
| P6-3 | Browser; ripwire-write-tests | Acceptance engineer | L | 150m | deep | Build deterministic end-to-end fixtures for enrollment through removal. |
| P6-GOV | CodeReview; Browser; ripwire-change-check | Acceptance Governor | L | 150m | deep | Run proposed command set and publish Alpha partner evidence. |

### Spec: Work Decomposition

| Logical ID | Role | Atomic task | Depends on | Exact tests or evidence | Size | Agent | Result / metric |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| P0 | preflight | Validate AMXO harness identity and collision-free bootstrap baseline | None | `kanban-check.sh --repo /home/andy/src/cp/osramp-demo --shortcode AMXO doctor`; repository and board evidence only | S | fast | Pending |
| P1-PRE | preflight | Inventory unresolved kickoff decisions and canonical integration seams | P0 | Proposal gate inventory; `ripwire /home/andy/src/cp/osramp-demo --pack-task="external Linux agent onboarding"` | S | daily | Pending |
| P1-1 | implementation | Record approved operator identity authorization and removal decisions | P1-PRE | Named approver evidence for operator, identity source, matrix, removal owner | M | daily | Pending |
| P1-2 | implementation | Record approved host policy privacy limits and lifecycle decisions | P1-PRE | Named approver evidence for paths, destinations, limits, retention, deletion, host owner | M | daily | Pending |
| P1-3 | implementation | Freeze versioned architecture wire contracts and service ownership | P1-1, P1-2 | Contract schemas; threat assumptions; FastAPI/Go ownership decision; privacy allowlist | L | deep | Pending |
| P1-GOV | governor | Approve decision freeze and reject unresolved placeholders | P1-1, P1-2, P1-3 | Proposal review; zero unresolved kickoff gates; architecture and security sign-off | M | deep | Pending |
| P2-PRE | preflight | Confirm identity and claim seams against frozen contracts | P1-GOV | Focused existing identity tests; collision and migration-number checks | S | daily | Pending |
| P2-1 | implementation | Implement attributable operator lifecycle and shared-identity rejection | P2-PRE | `make demo-agentmaxxing-contract-test`; removed-user and shared-identity negatives | L | daily | Pending |
| P2-2 | implementation | Implement tenant-bound registration and duplicate agent-claim rejection | P2-PRE | `make demo-agentmaxxing-contract-test`; cross-tenant and conflict tests | L | daily | Pending |
| P2-GOV | governor | Merge identity registration work and verify authorization isolation | P2-1, P2-2 | `make demo-agentmaxxing-contract-test`; `make demo-signalloom-api-test TIER=contract` | M | deep | Pending |
| P3-PRE | preflight | Confirm approved identity contracts and enrollment integration seams | P2-GOV | Enrollment schema review; OpenBao role and policy inventory | S | daily | Pending |
| P3-1 | implementation | Implement atomic one-time external host enrollment exchange | P3-PRE | `make demo-agentmaxxing-contract-test`; concurrent redemption test | L | daily | Pending |
| P3-2 | implementation | Implement audit-only credential scope and tenant-agent binding | P3-PRE | `make demo-agentmaxxing-contract-test`; denied non-upload action matrix | L | daily | Pending |
| P3-3 | implementation | Implement independent host revocation enforcement | P3-PRE | `make demo-agentmaxxing-contract-test`; post-revocation upload denial | M | daily | Pending |
| P3-GOV | governor | Merge enrollment work and verify credential least privilege | P3-1, P3-2, P3-3 | `make demo-agentmaxxing-contract-test`; security review evidence | M | deep | Pending |
| P4-PRE | preflight | Confirm Linux kernel nono systemd and upload prerequisites | P3-GOV | Kernel capability probe; pinned nono version and digest evidence; fixture plan | S | daily | Pending |
| P4-1 | implementation | Build fail-closed nono profile systemd unit and digest gate | P4-PRE | `make demo-agentmaxxing-host-test`; filesystem and network denial probes | L | daily | Pending |
| P4-2 | implementation | Emit bounded allowlisted process lifecycle metadata | P4-PRE | `make demo-agentmaxxing-host-test`; CPU, memory-use, exit, restart fixtures | M | daily | Pending |
| P4-3 | implementation | Enforce descriptor-relative artifact eligibility before reading bytes | P4-PRE | `make demo-agentmaxxing-host-test`; symlink, hard-link, mount, non-regular no-read proofs | L | deep | Pending |
| P4-4 | implementation | Enforce bounded hashing and post-read identity validation | P4-PRE | `make demo-agentmaxxing-host-test`; replacement, oversize, rate, metadata-change fixtures | L | deep | Pending |
| P4-GOV | governor | Merge host components and falsify confinement escape paths | P4-1, P4-2, P4-3, P4-4 | `make demo-agentmaxxing-host-test`; zero unexpected skips; security review | L | deep | Pending |
| P5-PRE | preflight | Confirm accepted host fixtures and integrity ownership boundary | P4-GOV | Fixture digest; Go verifier ownership check; database migration collision check | S | daily | Pending |
| P5-1 | implementation | Verify finalized sessions and reject invalid audit chains | P5-PRE | `make demo-agentmaxxing-ingest-test`; valid, incomplete, altered, reordered, forged fixtures | L | daily | Pending |
| P5-2 | implementation | Enforce upload idempotency across concurrency and interrupted retries | P5-PRE | `make demo-agentmaxxing-ingest-test`; duplicate, concurrent, retry transaction tests | L | daily | Pending |
| P5-3 | implementation | Persist allowlisted evidence and expose tenant-scoped projections | P5-PRE | `make demo-agentmaxxing-ingest-test`; prohibited-field and cross-tenant negatives | L | daily | Pending |
| P5-GOV | governor | Merge ingestion work and verify privacy-preserving evidence semantics | P5-1, P5-2, P5-3 | `make demo-agentmaxxing-ingest-test`; API content-type and audit attribution checks | L | deep | Pending |
| P6-PRE | preflight | Confirm stable evidence API and user-facing vocabulary | P5-GOV | Contract snapshot; accessibility test plan; route collision check | S | daily | Pending |
| P6-1 | implementation | Render attributable evidence states on tenant-bound agent timeline | P6-PRE | `make demo-agentmaxxing-ui-test`; source, timestamp, integrity, limit, unobserved assertions | L | daily | Pending |
| P6-2 | implementation | Publish external-agent guide and verified evidence-flow diagram | P6-PRE | `make demo-agentmaxxing-docs-test`; Astro diagnostics and SVG browser assertion | M | daily | Pending |
| P6-3 | implementation | Build deterministic local onboarding-to-removal acceptance journey | P6-PRE | `make demo-agentmaxxing-acceptance-test`; enrollment, upload, denial, revocation, removal | L | deep | Pending |
| P6-GOV | governor | Reconcile acceptance wiring and publish reviewed Alpha evidence | P6-1, P6-2, P6-3 | Six proposed `make demo-agentmaxxing-*-test` targets; `bats test/acceptance-spec-coverage.bats`; partner review record | L | deep | Pending |

### Spec: Errata

No work has started. Runtime cards append sequential completion and Governor evidence here only after explicit proposal sign-off, preparation, digest approval, and mission launch.
