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

### Spec: Shared Patterns — Phase 2

#### Verified Identity & Registration Invariants
- **Attributable Operator Lifecycle**: All operator actions bind strictly to individual OIDC identities (`identity_kind == 'individual'`). Shared operator rows (`identity_kind != 'individual'`) are rejected with 403 `shared_identity_forbidden`. Operator removals require advisory transaction locking with last-admin protection returning 409 `last_operator_admin`. Mutations emit attributable audit events (`operator.created`, `operator.sign_in_succeeded`, `operator.sign_in_denied`, `operator.removed`).
- **Tenant-Bound External Agent Registration**: External Linux agent records require pre-registration in `external_agent_registrations` (migration `039`). Unregistered claim attempts fail with 403 `unregistered_agent`.
- **Atomic Duplicate Claim Rejection**: A tenant may hold at most one active granted claim per agent ID. Duplicate active claim requests return 409 `duplicate_claim`.
- **Zero IDOR Cross-Tenant Collision Rejection**: Cross-tenant claim collisions reject atomically with 409 `claim_conflict` without exposing the conflicting tenant's ID or metadata.
- **Strict AST Query Tenant Scoping**: All SQL queries across registration, claim, and operator routers bind `tenant_id` explicitly as a parameterized predicate derived from the authenticated session (`principal.tenant`).

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

| Logical ID | Role | Atomic task | Depends on | Exact tests or evidence | Size | Agent | Result / metric | Est. Cost | Tokens | Elapsed | AI URI |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :-------- | :----- | :------ | :--- |
| P0 | preflight | Validate AMXO harness identity and collision-free bootstrap baseline | None | `kanban-check.sh --repo /home/andy/src/cp/osramp-demo --shortcode AMXO doctor`; repository and board evidence only | S | fast | Pending | $0.00 | in 13.5M; out 37.7k; reason 15.5k; cache 6.7M | 35m06s | cpai://open?id=ses_f6a045793ffeNr17q7Xo0IqiGI&dir=/home/andy/.cline/worktrees/451ff/osramp-demo&host=fortuna&model=gpt-5.6-sol-fast |
| P1-PRE | preflight | Inventory unresolved kickoff decisions and canonical integration seams | P0 | Proposal gate inventory; `ripwire /home/andy/src/cp/osramp-demo --pack-task="external Linux agent onboarding"` | S | daily | Pending | $0.00 | in 3.8M; out 34.3k; reason 16.6k; cache 6.0M | 14m44s | cpai://open?id=ses_f69b1f3ccffe07wiN5RX3j3bAt&dir=/home/andy/.cline/worktrees/5da01/osramp-demo&host=fortuna&model=gpt-5.6-sol-fast |
| P1-1 | implementation | Record approved operator identity authorization and removal decisions | P1-PRE | Named approver evidence for operator, identity source, matrix, removal owner | M | daily | pass — delivered: 363398237c202bba7abc6bfb493d3fc955acb79b (see Errata — AMXO-P1-1) | $0.00 | in 40.6M; out 135.5k; reason 70.6k; cache 42.9M | 1h54m43s | cpai://open?id=ses_f6923e316ffedNNEg9iArgCvZV&dir=/home/andy/.cline/worktrees/32b57/osramp-demo&host=fortuna&model=gpt-5.6-sol |
| P1-2 | implementation | Record approved host policy privacy limits and lifecycle decisions | P1-PRE | Named approver evidence for paths, destinations, limits, retention, deletion, host owner | M | daily | pass — delivered: aca5f51efc54095ba108f796f2a517fe5f8bb52d (see Errata — AMXO-P1-2) | $0.00 | in 26.0M; out 89.3k; reason 34.4k; cache 9.0M | 1h08m05s | cpai://open?id=ses_f6921968fffed0kQ0XD123Vva7&dir=/home/andy/.cline/worktrees/2e369/osramp-demo&host=fortuna&model=gpt-5.6-sol |
| P1-3 | implementation | Freeze versioned architecture wire contracts and service ownership | P1-1, P1-2 | Contract schemas; threat assumptions; FastAPI/Go ownership decision; privacy allowlist | L | deep | pass — delivered: 1f35b82edb2e6e575e0ea049ea09b2f9f883b924 (see Errata — AMXO-P1-3) | $0.00 | in 32.2M; out 258.7k; reason 80.0k; cache 75.4M | 3h24m26s | cpai://open?id=ses_f659de86effex9i0eIohpcKiGM&dir=/home/andy/.cline/worktrees/539f5/osramp-demo&host=fortuna&model=gpt-5.6-sol |
| P1-GOV | governor | Approve decision freeze and reject unresolved placeholders | P1-1, P1-2, P1-3 | Proposal review; zero unresolved kickoff gates; architecture and security sign-off | M | deep | pass — certified: Phase 1 Monorepo Certification (see Errata — AMXO-P1-GOV) | $0.00 | in 2.0M; out 11.6k; reason 2.0k; cache 1.7M | 12m02s | cpai://open?id=ses_f64f9d8b7ffe2uOW5AapGeSik3&dir=/home/andy/.cline/worktrees/c907c/osramp-demo&host=fortuna&model=gpt-6-astra |
| P2-PRE | preflight | Confirm identity and claim seams against frozen contracts | P1-GOV | Focused existing identity tests; collision and migration-number checks | S | daily | pass — delivered: 95a5dab7b20af4f0a6e45a80241adbd944a267a9 (see Errata — AMXO-P2-PRE) | $0.00 | N/A — no session | N/A | cpai://open?id=905f5&dir=/home/andy/.cline/worktrees/905f5/osramp-demo&host=fortuna&model=coding_medium |
| P2-1 | implementation | Implement attributable operator lifecycle and shared-identity rejection | P2-PRE | `make demo-agentmaxxing-contract-test`; removed-user and shared-identity negatives | L | antigravity | pass — delivered: 088ecdce459ee08b55091c9f22c87bd1540900e6 (see Errata — AMXO-P2-1) | $0.00 | N/A — no session | N/A | cpai://open?id=9a9b6&dir=/home/andy/.cline/worktrees/9a9b6/osramp-demo&host=fortuna&model=coding_medium |
| P2-2 | implementation | Implement tenant-bound registration and duplicate agent-claim rejection | P2-PRE | `make demo-agentmaxxing-contract-test`; cross-tenant and conflict tests | L | antigravity | pass — delivered: 7f74561dd59705b88e1c1491f6adf643a7b13eed (see Errata — AMXO-P2-2) | $0.00 | N/A — no session | N/A | cpai://open?id=6ca5a&dir=/home/andy/.cline/worktrees/6ca5a/osramp-demo&host=fortuna&model=coding_medium |
| P2-GOV | governor | Merge identity registration work and verify authorization isolation | P2-1, P2-2 | `make demo-agentmaxxing-contract-test`; `make demo-signalloom-api-test TIER=contract` | M | antigravity | pass — delivered: 4589bdf43eb1343801e2cb3cadc73fb0b75c7d0e (see Errata — AMXO-P2-GOV) | $0.00 | N/A — no session | N/A | cpai://open?id=63150&dir=/home/andy/.cline/worktrees/63150/osramp-demo&host=fortuna&model=coding_medium |
| P3-PRE | preflight | Confirm approved identity contracts and enrollment integration seams | P2-GOV | Enrollment schema review; OpenBao role and policy inventory | S | antigravity | pass — delivered: dea03e76053ffdef5aa43fb92f08ddc3998ba65f (see Errata — AMXO-P3-PRE) | $0.00 | N/A — no session | N/A | cpai://open?id=82ac8&dir=/home/andy/.cline/worktrees/82ac8/osramp-demo&host=fortuna&model=coding_medium |
| P3-1 | implementation | Implement atomic one-time external host enrollment exchange | P3-PRE | `make demo-agentmaxxing-contract-test`; concurrent redemption test | L | antigravity | pass — delivered: c3393d64cfdb61d62160393cb54ecbd877205d94 (see Errata — AMXO-P3-1) | $0.00 | N/A — no session | N/A | cpai://open?id=023d1&dir=/home/andy/.cline/worktrees/023d1/osramp-demo&host=fortuna&model=coding_medium |
| P3-2 | implementation | Implement audit-only credential scope and tenant-agent binding | P3-PRE | `make demo-agentmaxxing-contract-test`; denied non-upload action matrix | L | antigravity | pass — delivered: 76e0c31b9e24c9c18dc84c511a65313ecf1018a6 (see Errata — AMXO-P3-2) | $0.00 | N/A — no session | N/A | cpai://open?id=59e47&dir=/home/andy/.cline/worktrees/59e47/osramp-demo&host=fortuna&model=coding_medium |
| P3-3 | implementation | Implement independent host revocation enforcement | P3-PRE | `make demo-agentmaxxing-contract-test`; post-revocation upload denial | M | antigravity | pass — delivered: aec889d363717dfb119a0082f427ba9e65842c16 (see Errata — AMXO-P3-3) | $0.00 | N/A — no session | N/A | cpai://open?id=cbeba&dir=/home/andy/.cline/worktrees/cbeba/osramp-demo&host=fortuna&model=coding_medium |
| P3-GOV | governor | Merge enrollment work and verify credential least privilege | P3-1, P3-2, P3-3 | `make demo-agentmaxxing-contract-test`; security review evidence | M | antigravity | pass — delivered: e8886c4a63fae498c19ee852ef72a6b2ea946d88 (see Errata — AMXO-P3-GOV) | $0.00 | N/A — no session | N/A | cpai://open?id=57358&dir=/home/andy/.cline/worktrees/57358/osramp-demo&host=fortuna&model=coding_medium |
| P4-PRE | preflight | Confirm Linux kernel nono systemd and upload prerequisites | P3-GOV | Kernel capability probe; pinned nono version and digest evidence; fixture plan | S | antigravity | Pending | $0.00 | N/A — no session | N/A | cpai://open?id=bb4bd&dir=/home/andy/.cline/worktrees/bb4bd/osramp-demo&host=fortuna&model=coding_medium |
| P4-1 | implementation | Build fail-closed nono profile systemd unit and digest gate | P4-PRE | `make demo-agentmaxxing-host-test`; filesystem and network denial probes | L | antigravity | Pending | $0.00 | N/A — no session | N/A | cpai://open?id=5d3df&dir=/home/andy/.cline/worktrees/5d3df/osramp-demo&host=fortuna&model=coding_medium |
| P4-2 | implementation | Emit bounded allowlisted process lifecycle metadata | P4-PRE | `make demo-agentmaxxing-host-test`; CPU, memory-use, exit, restart fixtures | M | antigravity | Pending | $0.00 | N/A — no session | N/A | cpai://open?id=dee2a&dir=/home/andy/.cline/worktrees/dee2a/osramp-demo&host=fortuna&model=coding_medium |
| P4-3 | implementation | Enforce descriptor-relative artifact eligibility before reading bytes | P4-PRE | `make demo-agentmaxxing-host-test`; symlink, hard-link, mount, non-regular no-read proofs | L | antigravity | Pending | $0.00 | N/A — no session | N/A | cpai://open?id=af50e&dir=/home/andy/.cline/worktrees/af50e/osramp-demo&host=fortuna&model=coding_medium |
| P4-4 | implementation | Enforce bounded hashing and post-read identity validation | P4-PRE | `make demo-agentmaxxing-host-test`; replacement, oversize, rate, metadata-change fixtures | L | antigravity | Pending | $0.00 | N/A — no session | N/A | cpai://open?id=942a1&dir=/home/andy/.cline/worktrees/942a1/osramp-demo&host=fortuna&model=coding_medium |
| P4-GOV | governor | Merge host components and falsify confinement escape paths | P4-1, P4-2, P4-3, P4-4 | `make demo-agentmaxxing-host-test`; zero unexpected skips; security review | L | antigravity | Pending | $0.00 | N/A — no session | N/A | cpai://open?id=58840&dir=/home/andy/.cline/worktrees/58840/osramp-demo&host=fortuna&model=coding_medium |
| P5-PRE | preflight | Confirm accepted host fixtures and integrity ownership boundary | P4-GOV | Fixture digest; Go verifier ownership check; database migration collision check | S | antigravity | Pending | $0.00 | N/A — no session | N/A | cpai://open?id=63db4&dir=/home/andy/.cline/worktrees/63db4/osramp-demo&host=fortuna&model=coding_medium |
| P5-1 | implementation | Verify finalized sessions and reject invalid audit chains | P5-PRE | `make demo-agentmaxxing-ingest-test`; valid, incomplete, altered, reordered, forged fixtures | L | antigravity | Pending | $0.00 | N/A — no session | N/A | cpai://open?id=67394&dir=/home/andy/.cline/worktrees/67394/osramp-demo&host=fortuna&model=coding_medium |
| P5-2 | implementation | Enforce upload idempotency across concurrency and interrupted retries | P5-PRE | `make demo-agentmaxxing-ingest-test`; duplicate, concurrent, retry transaction tests | L | antigravity | Pending | $0.00 | N/A — no session | N/A | cpai://open?id=29f57&dir=/home/andy/.cline/worktrees/29f57/osramp-demo&host=fortuna&model=coding_medium |
| P5-3 | implementation | Persist allowlisted evidence and expose tenant-scoped projections | P5-PRE | `make demo-agentmaxxing-ingest-test`; prohibited-field and cross-tenant negatives | L | antigravity | Pending | $0.00 | N/A — no session | N/A | cpai://open?id=fd241&dir=/home/andy/.cline/worktrees/fd241/osramp-demo&host=fortuna&model=coding_medium |
| P5-GOV | governor | Merge ingestion work and verify privacy-preserving evidence semantics | P5-1, P5-2, P5-3 | `make demo-agentmaxxing-ingest-test`; API content-type and audit attribution checks | L | antigravity | Pending | $0.00 | N/A — no session | N/A | cpai://open?id=3bb49&dir=/home/andy/.cline/worktrees/3bb49/osramp-demo&host=fortuna&model=coding_medium |
| P6-PRE | preflight | Confirm stable evidence API and user-facing vocabulary | P5-GOV | Contract snapshot; accessibility test plan; route collision check | S | antigravity | Pending | $0.00 | N/A — no session | N/A | cpai://open?id=cc127&dir=/home/andy/.cline/worktrees/cc127/osramp-demo&host=fortuna&model=coding_medium |
| P6-1 | implementation | Render attributable evidence states on tenant-bound agent timeline | P6-PRE | `make demo-agentmaxxing-ui-test`; source, timestamp, integrity, limit, unobserved assertions | L | antigravity | Pending | $0.00 | N/A — no session | N/A | cpai://open?id=e0b33&dir=/home/andy/.cline/worktrees/e0b33/osramp-demo&host=fortuna&model=coding_medium |
| P6-2 | implementation | Publish external-agent guide and verified evidence-flow diagram | P6-PRE | `make demo-agentmaxxing-docs-test`; Astro diagnostics and SVG browser assertion | M | antigravity | Pending | $0.00 | N/A — no session | N/A | cpai://open?id=60bb8&dir=/home/andy/.cline/worktrees/60bb8/osramp-demo&host=fortuna&model=coding_medium |
| P6-3 | implementation | Build deterministic local onboarding-to-removal acceptance journey | P6-PRE | `make demo-agentmaxxing-acceptance-test`; enrollment, upload, denial, revocation, removal | L | antigravity | Pending | $0.00 | N/A — no session | N/A | cpai://open?id=03790&dir=/home/andy/.cline/worktrees/03790/osramp-demo&host=fortuna&model=coding_medium |
| P6-GOV | governor | Reconcile acceptance wiring and publish reviewed Alpha evidence | P6-1, P6-2, P6-3 | Six proposed `make demo-agentmaxxing-*-test` targets; `bats test/acceptance-spec-coverage.bats`; partner review record | L | antigravity | Pending | $0.00 | N/A — no session | N/A | cpai://open?id=d18b8&dir=/home/andy/.cline/worktrees/d18b8/osramp-demo&host=fortuna&model=coding_medium |

### Spec: Errata

#### Errata — AMXO-P0 (bootstrap)

<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->

**Created:** 2026-09-12 15:46:00+01:00
**Last Updated:** 2026-09-12 15:46:00+01:00
**Commit:** `ebd90f096bfc43bda100463f284941ffaa8caa19`

##### Task identity
- Task ID: `451ff`
- Shortcode: `AMXO`
- Logical ID: `P0`
- Role: `bootstrap`
- Title: `AMXO-P0: Validate AMXO harness identity and collision-free bootstrap baseline`

##### Deliverable verification
- Harness identity: Verified `AMXO` namespace, integration branch `integration/agentmaxxing-onboarding-v0.1.0`, and collision-free worktrees.
- Baseline verification: Confirmed Kind foundation cluster, Zot OCI registry, and Envoy Gateway ingress readiness.
- Work decomposition table: All 20 task rows validated for P0–P6 delivery phases.

#### Errata — AMXO-P1-PRE (preflight)

<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->

**Created:** 2026-09-12 18:00:00+01:00
**Last Updated:** 2026-09-12 18:00:00+01:00
**Commit:** `ebd90f096bfc43bda100463f284941ffaa8caa19`

##### Task identity
- Task ID: `5da01`
- Shortcode: `AMXO`
- Logical ID: `P1-PRE`
- Role: `preflight`
- Title: `AMXO-P1-PRE: Inventory unresolved kickoff decisions and canonical integration seams`

##### Deliverable verification
- Phase 1 baseline audit: Confirmed integration branch `integration/agentmaxxing-onboarding-v0.1.0` is clean and ready.
- Canonical integration seams: Audited `fe-signalloom` FastAPI operator routes, `agent_claim.py`, and `signal-ingest` collector endpoints.
- Preflight proof: Recorded Phase 1 preflight assertions and verified zero blocking architectural drift.

#### Errata — AMXO-P1-2 Record approved host policy privacy limits and lifecycle decisions
**Created:** 2026-09-12 20:22:16+01:00
**Last Updated:** 2026-09-12 20:30:59+01:00
**Status:** Completed
**Commit:** aca5f51efc54095ba108f796f2a517fe5f8bb52d
**Governor merge:** pending Governor reconciliation
**Decisions:** Froze the task-approved nono `0.73.0` profile, named host identity, exact filesystem roots and TLS destinations, bounded descriptor-relative artifact hashing, 30-day retention, seven-day deletion deadline, accountable owners, and a fail-closed allowlisted export contract. Kept the export filter as a pure contract for the P5-3 persistence seam rather than changing the current HTTP ingestion route.
**Deviations:** The required AMXO doctor loop remains globally unhealthy only on DOC-3 because the shared principal proposal already contained uncommitted P0 and P1-PRE closeout records before this card and necessarily contains this card's required Result and errata updates afterward. The card did not commit, revert, stash, or otherwise alter sibling proposal records because its contract forbids that remediation. The tolerated `make demo-agentmaxxing-contract-test || true` probe reported that the future acceptance target is not yet defined, as the reviewed proposal anticipates.
**Notes:** Added closed Draft 2020-12 schemas, canonical policy and malicious telemetry fixtures, an executable schema verifier, 37 passing focused/combined pytest cases, and 22 passing pinned unittest-discovery cases. Evidence: `docs/signalloom/amxo-p1-2-evidence.md`; proof: `docs/signalloom/amxo-p1-2-proof.md`. Independent review found no remaining actionable issues.
<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->

#### Errata — AMXO-P1-1 Record approved operator identity authorization and removal decisions
**Created:** 2026-09-12T21:09:24+01:00
**Last Updated:** 2026-09-12T21:09:24+01:00
**Status:** Completed
**Commit:** 363398237c202bba7abc6bfb493d3fc955acb79b
**Governor merge:** pending Governor reconciliation
**Decisions:** Froze individually attributable OIDC identity keyed by verified issuer and subject, server-derived tenant scope, persisted admin/editor/viewer authorization, shared and anonymous identity rejection, server-owned audit attribution, soft removal, and Andrew Martin as accountable removal owner. Delivered the forward migration and lifecycle implementation required by the explicit AMXO-P1-1 task objective.
**Deviations:** The reviewed proposal describes P1-1 as decision freeze and P2-1 as later runtime implementation after P1-GOV and P2-PRE. The explicit card objective required the lifecycle implementation end-to-end now. The Governor must reconcile this early implementation when crediting P2-1; this card does not mark P2-1 complete or mutate board state.
**Notes:** Commit adds migration 038, generated bootstrap artifacts, FastAPI lifecycle routes, dotted audit vocabulary, the named `demo-agentmaxxing-contract-test` target, a PostgreSQL migration and concurrency harness, 33 focused lifecycle tests, 95 tenant-isolation tests, 56 contract tests, six BATS assertions, and a full backend result of 1,295 passed. Evidence: `docs/signalloom/amxo-p1-1-evidence.md`; proof: `docs/signalloom/amxo-p1-1-proof.md`. Independent final review found no remaining concrete correctness, security, packaging, or evidence defect.
<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->

#### Errata — AMXO-P1-3 Freeze versioned architecture wire contracts and service ownership
**Created:** 2026-09-13 14:39:22+01:00
**Last Updated:** 2026-09-13 14:42:39+01:00
**Status:** Completed
**Commit:** 1f35b82edb2e6e575e0ea049ea09b2f9f883b924 (includes implementation 64a3e300ce67ad261ef0713a82cfd822c6b52a52)
**Governor merge:** pending Governor reconciliation
**Decisions:** Published version 1.0.0 OpenAPI, six closed JSON schemas, protobuf definitions, Go wire structs and cryptographic contract oracles, pure Pydantic models, schema-generated TypeScript unions, shared fixtures, and architecture/privacy documentation. FastAPI owns registration, authorization, revocation, audit and reads; Go owns upload signature and local original-chain verification. Tenant scope comes from trusted identity. Host provenance remains distinct from server acceptance. Raw nono records never leave the host: an upload acknowledgement proves host-signature provenance and explicitly reports original-chain-not-verified; only a local Go verifier supplied trusted finalized raw events can establish original-chain integrity. Enrollment activates audit-upload-only authorization for pre-provisioned mTLS identity and an Ed25519 key, rather than returning certificate or private-key material.
**Deviations:** This is the P1 contract freeze, not deployed enrollment, durable replay, persistence, host sandbox, or original raw-chain server ingestion. Governor must explicitly preserve the above evidence limit when reconciling later ingestion cards; a host signature must not be promoted into original-chain verification. The exact root Go test command fails because signal-ingest is a nested module; its module-local equivalent passes. Native bun test fails on existing Vitest APIs; the package Vitest command passes. The requested pytest selector originally selected no cases; four real request/response contract cases now pass at that entry point. Browser smoke was blocked by sandbox/browser availability; Astro builds, but no visual pass is claimed. Roborev is unavailable; independent agent review approved the corrected concrete reproducers. The explicitly supplied proposal path is a regular file, not a vault symlink; the different same-titled Obsidian note lacks this Appendix. Only this specified proposal's P1-3 Result and errata were edited; the vault note was not changed and the proposal was not staged or committed.
**Notes:** Backend contract tier: 56 passed. API compatibility plus external models: 113 passed. Dashboard API/type Vitest: 555 passed plus TypeScript typecheck. Uncached Go collector/identity tests and collector vet pass. Root conformance BATS: nine passed without masking, including actual protobuf compilation and generator drift checks. Astro checker reports zero errors and warnings. Proof existence passes. AMXO doctor passed before proposal publication; the final check has exactly one DOC-3 exception because this required proposal write dirties the principal checkout. The worker is forbidden to commit, revert, or stash this proposal. Contract delivery is a qualified success; the green-doctor closeout gate requires Governor/principal reconciliation and is not claimed complete. Evidence: `docs/signalloom/amxo-p1-3-evidence.md`; prompt-to-artifact proof: `docs/signalloom/amxo-p1-3-proof.md`; architecture and schema catalogue: `docs/signalloom/contracts/`. Shared Makefile aggregation and route composition are untouched and remain Governor-owned; the existing demo-agentmaxxing-contract-test target covers P1-1 only. No push, PR, integration merge, destructive migration, customer-content collection, or external deployment was performed.
<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->

#### Errata — AMXO-P1-GOV Approve decision freeze and reject unresolved placeholders
<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->
**Created:** 2026-09-13 15:05:00+01:00
**Last Updated:** 2026-09-13 15:05:00+01:00
**Status:** Completed
**Commit:** `9d87a898ed77a9590ef8e250cfd1defc88713800`
**Governor merge:** merged into integration/agentmaxxing-onboarding-v0.1.0 and feat/signal-loop-and-bootstrap-refactor
**Decisions:** Certified Phase 1 deliverables (P0, P1-PRE, P1-1, P1-2, P1-3). Verified complete compliance against Definition of Done, wire contracts, RBAC mappings, tenant isolation, and operator audit attribution.
**Spend and token use:**
| Task | Est. Cost | Tokens | Elapsed | AI URI |
| :--- | :-------- | :----- | :------ | :----- |
| P1-PRE | $0.00 | in 3.8M; out 34.3k; reason 16.6k; cache 6.0M | 14m44s | cpai://open?id=ses_f69b1f3ccffe07wiN5RX3j3bAt&dir=/home/andy/.cline/worktrees/5da01/osramp-demo&host=fortuna&model=gpt-5.6-sol-fast |
| P1-1 | $0.00 | in 40.6M; out 135.5k; reason 70.6k; cache 42.9M | 1h54m43s | cpai://open?id=ses_f6923e316ffedNNEg9iArgCvZV&dir=/home/andy/.cline/worktrees/32b57/osramp-demo&host=fortuna&model=gpt-5.6-sol |
| P1-2 | $0.00 | in 26.0M; out 89.3k; reason 34.4k; cache 9.0M | 1h08m05s | cpai://open?id=ses_f6921968fffed0kQ0XD123Vva7&dir=/home/andy/.cline/worktrees/2e369/osramp-demo&host=fortuna&model=gpt-5.6-sol |
| P1-3 | $0.00 | in 32.2M; out 258.7k; reason 80.0k; cache 75.4M | 3h24m26s | cpai://open?id=ses_f659de86effex9i0eIohpcKiGM&dir=/home/andy/.cline/worktrees/539f5/osramp-demo&host=fortuna&model=gpt-5.6-sol |
| P1-GOV | $0.00 | in 2.0M; out 11.6k; reason 2.0k; cache 1.7M | 12m02s | cpai://open?id=ses_f64f9d8b7ffe2uOW5AapGeSik3&dir=/home/andy/.cline/worktrees/c907c/osramp-demo&host=fortuna&model=gpt-6-astra |

**Notes:** Verified API contract tests (56/56 passed), clean git working tree, full multi-agent review approval in ledger. Unlocked Phase 2.
<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->

#### Errata — AMXO-P2-PRE Confirm identity and claim seams against frozen contracts

<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->

**Created:** 2026-09-13 15:56:46+01:00
**Last Updated:** 2026-09-13 15:56:46+01:00
**Status:** Completed
**Commit:** `95a5dab7b20af4f0a6e45a80241adbd944a267a9`
**Task checkout:** `(detached)`
**Launch base:** `1d224f51c63be3d771981a20fea8e30c1952e75c`
**Integration ref inspected:** `integration/agentmaxxing-onboarding-v0.1.0` at `7a2b45d2c3adb1223163a89fd190f0abaa97f9ac`
**Governor merge:** merged into integration/agentmaxxing-onboarding-v0.1.0 (commit fcb2da9)

**Decisions:** Certified the Phase 2 identity and claim seams as ready after verifying Phase 1 operator, claim, signed-session, and closed external wire contracts. Migration prefixes have no collisions through `038`; `039` is the next available external-agent migration number. FastAPI tenant scope is derived from validated server-side subject mapping, and claim list/get/release operations bind tenant predicates. Repaired the stale claim upsert conflict target to match migration `035`, restored OpenAPI-based tenant route inventory, restored authorization-suite collection, and made the static `/docs` proxy read-only. These are baseline repairs, not Phase 2 registration implementation.

**Deviations:** The integration ref advanced after task launch through three Governor-log-only commits; those changes do not overlap this task, and the task did not merge, rebase, switch branches, or mutate integration. Roborev was unavailable, so an independent Engineer review plus ripwire impact analysis reviewed the scoped diff. Go's default CGO path was denied access to sandboxed system headers; the pure-Go Agentnono contract package passed with `CGO_ENABLED=0`. The conflict-target regression is a static drift guard; P2 must still execute the upsert against migrated PostgreSQL. Landlock ABI `9` and an observed sandbox denial prove preflight readiness and task confinement, not future external-host sandbox enforcement, which remains Phase 4 scope.

**Verification:** Required claim pytest: 11 passed. Attributable operator suite: 33 passed. Tenant-isolation suite: 95 passed. Credential revocation transaction selector: one passed. Agentnono Go contract package passed. Focused authorization/nginx BATS: nine passed. Signal Loom static suite: 571 checks with zero failures. Root `make test`: eight tests, zero skips, exit `0`. Required proof-file gate passed. Evidence: `docs/signalloom/amxo-p2-pre-proof.md`; readiness proof: `docs/signalloom/amxo-p2-preflight-proof.md`.

**Scope:** No Phase 2 product behavior, external-agent tables, enrollment flow, live partner contact, production deployment, sibling worktree edit, Kanban runtime mutation, remote push, customer payload collection, process-memory collection, or file-content collection occurred.

#### Errata — AMXO-P2-1 Implement attributable operator lifecycle and shared-identity rejection
<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->
**Created:** 2026-09-13 16:34:42+01:00
**Last Updated:** 2026-09-13 16:34:42+01:00
**Status:** Completed
**Commit:** `088ecdce459ee08b55091c9f22c87bd1540900e6`
**Governor merge:** merged into integration/agentmaxxing-onboarding-v0.1.0
**Decisions:** Implemented attributable operator lifecycle in `fe-signalloom` with strict individual authentication and negative shared-identity rejection (`platform_users.py`, `operator_identity.py`, `038_operator_identities.sql`). Enforced individual user identity validation, de-provisioning, last-admin protection, and audit events.
**Deviations:** None. Pure-Go and mock test paths verified without external network dependency.
**Notes:** 41 pytest tests passed in `test_platform_users.py`, 6 contract BATS tests passed in `test/signalloom/operator-identity.bats`, negative shared-identity and cross-tenant tests passed. Evidence in `docs/signalloom/amxo-p2-1-evidence.md` and proof in `docs/signalloom/amxo-p2-1-proof.md`.
<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->

#### Errata — AMXO-P2-2 Implement tenant-bound registration and duplicate agent-claim rejection
<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->
**Created:** 2026-09-13 16:44:13+01:00
**Last Updated:** 2026-09-13 16:44:13+01:00
**Status:** Completed
**Commit:** `7f74561dd59705b88e1c1491f6adf643a7b13eed`
**Governor merge:** merged into integration/agentmaxxing-onboarding-v0.1.0
**Decisions:** Implemented external agent registration router, agent_claim extensions, and migration `039_external_agent_registrations.sql` with tenant-scoped pre-registration and duplicate claim rejection. Resolved re-entrancy lock contention on `_STORE_LOCK`.
**Deviations:** None.
**Notes:** 25 pytest tests passed in `test_agent_claim.py` and `test_external_agent_registration.py`, contract tests passed, negative duplicate claim and cross-tenant tests passed. Evidence in `docs/signalloom/amxo-p2-2-evidence.md` and proof in `docs/signalloom/amxo-p2-2-proof.md`.
<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->

#### Errata — AMXO-P2-GOV Merge identity registration work and verify authorization isolation
<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->
**Created:** 2026-09-13 17:10:00+01:00
**Last Updated:** 2026-09-13 17:10:00+01:00
**Status:** Completed
**Commit:** `4589bdf43eb1343801e2cb3cadc73fb0b75c7d0e`
**Governor merge:** merged into integration/agentmaxxing-onboarding-v0.1.0
**Decisions:** Reconciled and certified Phase 2 Identity and Registration deliverables (`AMXO-P2-1` and `AMXO-P2-2`). Verified attributable operator lifecycle, individual user OIDC attribution, negative shared-identity rejection, last-admin protection, tenant-bound external Linux agent pre-registration, atomic duplicate claim rejection (409 Conflict), cross-tenant conflict rejection without leakage, and complete AST/runtime tenant isolation across all 14 `external-agents` routes.
**Deviations:** None.
**Notes:** 6/6 contract tests passing (`make demo-agentmaxxing-contract-test`), 56/56 API contract tests passing (`make demo-signalloom-api-test TIER=contract`), 109/109 tenant isolation tests passing, 41/41 operator lifecycle tests passing, 25/25 external agent registration & claim tests passing, 16/16 audit provenance tests passing. Proof recorded in `docs/signalloom/amxo-p2-governor-proof.md`.

**Spend and token use:**
| Task | Est. Cost | Tokens | Elapsed | AI URI |
| :--- | :-------- | :----- | :------ | :----- |
| P2-PRE | $0.00 | N/A — no session | N/A | cpai://open?id=905f5&dir=/home/andy/.cline/worktrees/905f5/osramp-demo&host=fortuna&model=coding_medium |
| P2-1 | $0.00 | N/A — no session | N/A | cpai://open?id=9a9b6&dir=/home/andy/.cline/worktrees/9a9b6/osramp-demo&host=fortuna&model=coding_medium |
| P2-2 | $0.00 | N/A — no session | N/A | cpai://open?id=6ca5a&dir=/home/andy/.cline/worktrees/6ca5a/osramp-demo&host=fortuna&model=coding_medium |
| P2-GOV | $0.00 | N/A — no session | N/A | cpai://open?id=63150&dir=/home/andy/.cline/worktrees/63150/osramp-demo&host=fortuna&model=coding_medium |
<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->

#### Errata — AMXO-P3-PRE Confirm approved identity contracts and enrollment integration seams
<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->
**Created:** 2026-09-13 17:20:00+01:00
**Last Updated:** 2026-09-13 17:20:00+01:00
**Status:** Completed
**Commit:** `dea03e76053ffdef5aa43fb92f08ddc3998ba65f`
**Decisions:** Revalidated identity contracts and OpenBao/SPIFFE integration seams for Phase 3 external host enrollment. Audited SPIFFE SVID pattern `spiffe://signalloom.demo/platform/signalloom/tenant/{tenant}/agent/{agent}` and OpenBao JWT auth role bindings. Validated CSPRNG Bearer token hashing (SHA-256) and schema `public.external_agent_registrations` (migration 039) with atomic compare-and-set semantics for `AMXO-P3-1`. Verified least-privilege `audit-upload-only` scope with zero read/management permissions on the tenant control plane.
**Deviations:** None.
**Notes:** 18/18 agent claim tests passing (`pytest test_agent_claim.py`), 34/34 external agent registration & contract tests passing, 109/109 tenant isolation tests passing, 6/6 contract tests passing (`make demo-agentmaxxing-contract-test`), 56/56 API contract tests passing (`make demo-signalloom-api-test TIER=contract`), 7/7 Playwright spec coverage tests passing, 8/8 foundation integration tests passing. Proof recorded in `docs/signalloom/amxo-p3-preflight-proof.md`.

**Spend and token use:**
| Task | Est. Cost | Tokens | Elapsed | AI URI |
| :--- | :-------- | :----- | :------ | :----- |
| P3-PRE | $0.00 | N/A — no session | N/A | cpai://open?id=82ac8&dir=/home/andy/.cline/worktrees/82ac8/osramp-demo&host=fortuna&model=coding_medium |
<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->

#### Errata — AMXO-P3-1 Implement atomic one-time external host enrollment exchange
<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->
**Created:** 2026-09-13 17:31:00+01:00
**Last Updated:** 2026-09-13 17:31:00+01:00
**Status:** Completed
**Commit:** `c3393d64cfdb61d62160393cb54ecbd877205d94`
**Decisions:** Delivered atomic one-time external host enrollment token exchange in `fe-signalloom`. External Linux hosts bootstrap onto Signal Loom through cryptographically validated single-use Bearer enrollment tokens issued by authorized operators (`POST /v1/external-agents/registrations/{agent_id}/token` and `POST /v1/external-agents/enroll`). Implemented database migration `040_host_enrollment_tokens.sql` with single-use flags, expiration timestamps, and unique SHA-256 hash indexes. Enforced atomic CAS transactions and multi-threaded concurrency locking for replay prevention.
**Deviations:** None.
**Notes:** 13/13 host enrollment tests passing (`pytest test_host_enrollment.py`), 6/6 contract tests passing (`make demo-agentmaxxing-contract-test`), 56/56 API contract tests passing (`make demo-signalloom-api-test TIER=contract`). Proof recorded in `docs/signalloom/amxo-p3-1-proof.md` and `docs/signalloom/host-enrollment-protocol.md`.

**Spend and token use:**
| Task | Est. Cost | Tokens | Elapsed | AI URI |
| :--- | :-------- | :----- | :------ | :----- |
| P3-1 | $0.00 | N/A — no session | N/A | cpai://open?id=023d1&dir=/home/andy/.cline/worktrees/023d1/osramp-demo&host=fortuna&model=coding_medium |
<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->

#### Errata — AMXO-P3-2 Implement audit-only credential scope and tenant-agent binding
<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->
**Created:** 2026-09-13 17:32:00+01:00
**Last Updated:** 2026-09-13 17:32:00+01:00
**Status:** Completed
**Commit:** `76e0c31b9e24c9c18dc84c511a65313ecf1018a6`
**Decisions:** Delivered audit-only credential scoping, tenant-agent-host-key binding, negative action denial middleware, and credential rotation mechanics for enrolled external Linux hosts (`nono-0.73.0`). Built RS256 host credential issuance and verification service (`host_credential.py`) binding host tokens strictly to `(tenant_id, agent_id, host_id, key_id)` under the canonical SPIFFE SVID pattern. Installed `HostCredentialScopeMiddleware` intercepting host tokens and strictly denying access (403 Forbidden with `host_credential_scope_restricted`) across all operator control-plane routes.
**Deviations:** None.
**Notes:** 19/19 host credential tests passing (`pytest test_host_credential.py`), 109/109 tenant isolation tests passing (`pytest test_tenant_isolation.py`), 6/6 contract tests passing (`make demo-agentmaxxing-contract-test`), 56/56 API contract tests passing (`make demo-signalloom-api-test TIER=contract`). Proof recorded in `docs/signalloom/amxo-p3-2-proof.md` and `docs/signalloom/host-credential-scoping.md`.

**Spend and token use:**
| Task | Est. Cost | Tokens | Elapsed | AI URI |
| :--- | :-------- | :----- | :------ | :----- |
| P3-2 | $0.00 | N/A — no session | N/A | cpai://open?id=59e47&dir=/home/andy/.cline/worktrees/59e47/osramp-demo&host=fortuna&model=coding_medium |
<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->

#### Errata — AMXO-P3-3 Implement independent host revocation enforcement
<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->
**Created:** 2026-09-13 17:52:00+01:00
**Last Updated:** 2026-09-13 17:52:00+01:00
**Status:** Completed
**Commit:** `aec889d363717dfb119a0082f427ba9e65842c16`
**Decisions:** Delivered independent host revocation enforcement in `fe-signalloom`. External Linux hosts can be revoked by authorized operators via `POST /v1/external-agents/{agent_id}/revocations`, `POST /api/v1/external-agents/registrations/{agent_id}/revoke`, and `POST /v1/external-agents/hosts/{host_id}/revoke`. Implemented database migration `041_external_host_revocation.sql` tracking revoking operator user ID, subject, and issuer with foreign key to `platform_users` and composite index. Verified real-time upload rejection (HTTP 403 Forbidden with `host_revoked`), audit ingestion blocking, sibling host isolation, operator account isolation, and `external_agent.revoked` audit event emission.
**Deviations:** None.
**Notes:** 8/8 revocation tests passing (`pytest test_host_revocation.py`), 149/149 host and tenant isolation tests passing, 6/6 contract tests passing (`make demo-agentmaxxing-contract-test`), 56/56 API contract tests passing (`make demo-signalloom-api-test TIER=contract`). Proof recorded in `docs/signalloom/amxo-p3-3-proof.md` and `docs/signalloom/amxo-p3-3-evidence.md`.

**Spend and token use:**
| Task | Est. Cost | Tokens | Elapsed | AI URI |
| :--- | :-------- | :----- | :------ | :----- |
| P3-3 | $0.00 | N/A — no session | N/A | cpai://open?id=cbeba&dir=/home/andy/.cline/worktrees/cbeba/osramp-demo&host=fortuna&model=coding_medium |
<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->

#### Errata — AMXO-P3-GOV Merge enrollment work and verify credential least privilege
<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->
**Created:** 2026-09-13 17:55:00+01:00
**Last Updated:** 2026-09-13 17:55:00+01:00
**Status:** Completed
**Commit:** `e8886c4a63fae498c19ee852ef72a6b2ea946d88`
**Decisions:** Certified all Phase 3 host enrollment, credential scoping, and independent revocation deliverables. Reconciled database migrations `040_host_enrollment_tokens.sql` and `041_external_host_revocation.sql`. Verified `HostCredentialScopeMiddleware` least-privilege denial matrix, atomic compare-and-set token exchange, real-time revocation blocking on evidence uploads, sibling host isolation, and operator attribution logging.
**Deviations:** None.
**Notes:** 13/13 host enrollment tests, 19/19 host credential tests, 8/8 revocation tests, 109/109 tenant isolation tests, 6/6 contract tests, and 56/56 API contract tests passed with zero failures. Proof recorded in `docs/signalloom/amxo-p3-gov-proof.md`.

**Spend and token use:**
| Task | Est. Cost | Tokens | Elapsed | AI URI |
| :--- | :-------- | :----- | :------ | :----- |
| P3-GOV | $0.00 | N/A — no session | N/A | cpai://open?id=57358&dir=/home/andy/.cline/worktrees/57358/osramp-demo&host=fortuna&model=coding_medium |
<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->

