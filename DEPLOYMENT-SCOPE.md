# Release qualification and production deployment — discussion draft

Status: proposed delivery scope; not implementation authorization.
Created: 2026-09-05.

This technical scope captures the deployment discussion. It is not a resourced commercial proposal, a claim of production readiness, or permission to provision infrastructure. No deployment automation or external adversarial repository is created by this document.

## 1. Agreed direction

- Focus on GCP initially. Azure and other deployment profiles are future work.
- Retain Kind-on-GCP CI and demo as the complete, self-contained reference deployment.
- Add dedicated pre-production qualification for production deployment profiles, starting with GKE.
- Production serves one customer in a single-tenant installation.
- Qualify both clean installation and in-place upgrade.
- Allow a short scheduled maintenance window; its numerical budget remains to be agreed.
- Do not require blue/green deployment or a hot spare initially.
- Reference an independently governed adversarial test suite in a future repository; do not create that repository now.

Kind proves the declared reference installation can work as a whole. It does not independently prove sovereignty, GKE compatibility, durable recovery, or production readiness.

## 2. Target release flow

1. Local development or agent worktree produces a GitHub Enterprise pull request.
2. Unprivileged checks validate code, contracts, dependencies and affected components.
3. A trusted workflow builds the actual merged release candidate once, signs it, and records its immutable identity.
4. Kind qualification verifies clean installation and an upgrade from the accepted baseline.
5. The candidate is promoted to demo for product acceptance and observation.
6. GKE pre-production qualifies the production deployment profile: clean installation, populated-baseline upgrade, recovery, and security invariants.
7. An authorized human approves production promotion against the recorded evidence.
8. Flux reconciles the approved release; post-deployment checks and an observation period determine operational acceptance.

Qualification work may run in parallel to reduce latency, but production authorization requires all mandatory evidence for the selected deployment profile. Demo success never substitutes for GKE qualification.

An observation period is a bounded acceptance stage, not an arbitrary sleep: duration, probes, thresholds and stop conditions must be defined.

## 3. Environment responsibilities

| Environment | Responsibility | Persistence and isolation |
|---|---|---|
| CI / Kind | Fast checks and whole-system reference qualification | Disposable estate where practical; caches are not required state |
| Demo / Kind | Stable demonstrations and product acceptance | Existing supported lane; not the authoritative upgrade baseline |
| Pre-production / GKE | Qualification of the intended production topology | Dedicated GCP project and identities; disposable clean installs plus a reproducible populated upgrade baseline |
| Production / GKE | Customer service | Dedicated single-tenant boundary, production identities and durable state |

Dedicated pre-production means a dedicated security and administrative boundary, not necessarily an always-running cluster. Cluster lifetime and cost limits are implementation decisions. A maintained baseline can support soak testing, but must be reproducible from declared release/configuration inputs.

Tests use synthetic customer-like records, identities and events. No live customer data or reusable production credentials enter CI, demo or pre-production.

## 4. First milestone: compatibility and production posture

Investigate GKE Standard first. This is a proposed target for qualification, not a statement that compatibility is established. Do not select Autopilot without proving its permitted workload model supports the platform's required host access.

Repository inspection identified these planning constraints:

| Area | Existing assumption / evidence | Required decision or proof |
|---|---|---|
| Sentinel | `d2-signalloom/infra/agent-swarm/signalloom-stun-sentinel/daemonset.yaml` uses host namespaces, writable cgroup access, node capabilities and `imagePullPolicy: Never`; `scripts/sentinel-preflight.sh` probes Linux-specific facilities | Supported GKE node image/kernel/runtime and remote image delivery; prove freeze, network containment, recovery and negative cases |
| Network enforcement | `docs/signalloom/stun-containment-implementation-options.md` distinguishes Kind proof from cloud portability; TC attachment and CNI coexistence need qualification | Select the GKE networking profile and prove both prohibited and allowed traffic, including established connections and rollout transitions |
| Identity | SPIRE/OpenBao manifests under `d2-signalloom/infra/inf-bao/` include node-local state and demo-mode assumptions | Production OpenBao operation, key custody, workload attestation, trust continuity, restart and node-replacement behavior |
| Database | `d2-signalloom/infra/inf-signalloom/controllers/base/dependencies.yaml` describes disposable demo PostgreSQL | Select production persistence, backups, restore, migration and connection behavior; Cloud SQL is a candidate, not yet an approved choice |
| Artifacts | `d2-osramp-fleet/local/zot.yaml` and Kind image-loading scripts assume the local estate | Select authenticated remote artifact distribution and production signing custody; verify signatures at the destination if artifacts are copied |
| Environment model | `terraform/environments/variables.tf` and `terraform/ISA.md` target existing CI/demo lanes, not production GKE | Add a separate supported profile without silently redefining existing lanes |
| GitHub execution | Existing workflows assume hosted Ubuntu runners and/or VM-based GCP orchestration | Confirm GitHub Enterprise Cloud versus Server, runner capacity, protected execution and available federation features |

Exit condition: one documented production profile with measured compatibility evidence and explicit unresolved blockers. If the sentinel cannot run safely, stop and choose a supported design; do not disable its enforcement and call the profile equivalent.

Existing demo identity/database configuration must not become production configuration simply because the manifests apply successfully.

## 5. Release identity and evidence

Introduce a small release record rather than a new general-purpose deployment framework. It binds:

- Source revision of the actual candidate, not an obsolete pre-merge PR head.
- Container and OCI artifact digests, signatures and build provenance.
- Manifest/chart and deployment-profile revisions.
- Migration identifiers and supported starting release(s).
- Baseline release and relevant configuration identity for upgrade tests.
- Test-suite and trusted workflow revisions.
- Qualification results, evidence locations and observation timestamps.
- Approval identity, destination and any explicit exception records.

Secrets are never embedded in this record. Configuration identity uses safe versioned references and metadata, not secret values or low-entropy secret hashes.

Application artifacts are built once. Environment/profile configuration may differ, but must be versioned and validated. Changes to candidate artifacts or material profile configuration invalidate the affected qualification; promotion cannot reuse unrelated evidence.

Eligibility is per profile and upgrade path. Passing Kind does not authorize GKE. Future AKS qualification does not block a GKE-only release unless a coordinated release policy explicitly requires it.

## 6. Deployment test contract

| Test class | Starting state | Required observations |
|---|---|---|
| Clean installation | Empty workload infrastructure within a declared bootstrap boundary | Provisioning, artifact trust, reconciliation, authentication, authorization, real event ingestion, audit persistence and complete cleanup |
| Upgrade | Current accepted/production release with synthetic populated state and active work | Data and identity continuity, migrations, permitted component overlap, collection loss/duplication accounting, readiness and completed user journeys |
| Recovery | Injected failure at defined upgrade boundaries | Service stays closed where necessary; documented rollback or restore succeeds; data-loss and recovery-time bounds are measured |
| Steady-state resilience | Qualified installation | Pod restart, node replacement and dependency outage behavior; required state survives and enforcement does not fail open |
| Post-production deployment | Newly reconciled production release | Low-impact synthetic checks, observed running digests, identity, service health and audit evidence; no destructive fault injection |

Initially support one upgrade path: current production release to candidate. Before the first production release, use the previous accepted candidate as the rehearsal baseline. Supporting several historical releases is future scope.

The bootstrap boundary must name resources that a clean installation does not create, such as the GCP organization/project prerequisites, CI federation, externally held signing keys and artifact repository. Those are explicit prerequisites, not invisible leftovers.

Every test stage reports passed, failed, blocked, or not implemented. Required tests cannot silently disappear through skips, empty discovery, or fixture substitution. Registry checks must prove the declared suites are invoked.

## 7. Maintenance and recovery contract

For changes requiring maintenance:

1. Confirm the observed starting release and supported migration path.
2. Acquire a per-environment deployment lock and reject a superseded candidate or conflicting operator action.
3. Announce maintenance, block new writes where necessary and drain/quiesce background work.
4. Verify a usable recovery point and the compatible recovery procedure; record any migration point of no return.
5. Apply migration and workload changes in the declared order, coordinating with Flux so reconciliation cannot fight the maintenance sequence.
6. Run acceptance probes against the updated system while access remains restricted as required.
7. Reopen service only after mandatory checks pass, then observe.
8. On failure, keep the safe maintenance state and execute the applicable rollback or restore procedure.

Application rollback, database recovery and identity recovery are different operations. Reverting Git is not a universal rollback. Use expand-and-contract migrations where feasible and avoid destructive changes while old versions remain part of the recovery path.

Agree separately before implementation: planned maintenance duration, recovery-time objective, recovery-point objective, observation period and escalation ownership. Do not promise zero downtime or zero data loss without tests supporting those commitments.

## 8. Future independent adversarial suite

Reserved gate name: `independent-adversarial-qualification`.

This work defines its interface and references it in clean-install and upgrade deployment tests. It does not create the repository, write its suite, assign a fictitious URL, or claim the gate exists.

The future suite owns foundational observable guarantees, not platform implementation details. Examples: identity authenticity, privilege boundaries, network isolation, signature enforcement, audit integrity, secret handling, persistent state, fail-closed behavior and distinguishing live ingestion from fixtures.

| Contract field | Requirement |
|---|---|
| Suite authority | Independently approved protected repository/workflow; platform PRs cannot weaken the mandatory suite selection |
| Inputs | Immutable release identity, target profile, upgrade baseline where applicable and narrowly scoped test credentials |
| Revision | Approved pinned suite revision selected by trusted policy, not an arbitrary value in the platform PR |
| Outputs | Verdict and diagnostic evidence bound to suite, release and profile identities |
| Adapters | Deployment-specific setup/probes with common invariants; unsupported checks are explicit blockers, not passes |
| Execution boundary | Disposable pre-production resources for destructive tests; separate least-privilege test and provisioning identities |
| Integrity | Evidence collection and final verdict are outside the platform's control; the target cannot self-attest success |

Until implemented, this gate reports `not implemented`. CI/demo development may continue. First customer production requires a passing implemented gate or an explicitly approved, scoped, expiring risk exception. No default bypass and no placeholder green result.

## 9. Agentic development and GitHub Enterprise security

- Agents may produce code, proposed tests and release changes; their summaries do not authorize production.
- PR execution is untrusted, including PR-edited workflows and test scripts. Do not expose cloud deployment or production credentials to it.
- Trusted qualification code executes from a protected revision. Candidate workloads run inside constrained test environments and must be treated as potentially malicious.
- Separate build, qualification, promotion and runtime identities. Use short-lived federation where the selected Enterprise deployment supports it.
- Restrict federation claims to approved repositories, workflows, refs/environments and audiences; avoid broad organization-wide trust.
- Protect release policy, suite ownership and production configuration changes with independent review.
- Keep privileged deployment runners separate from untrusted PR runners. Do not run arbitrary candidate scripts in the privileged orchestrator's context.
- Preserve SBOM, dependency/security scan results, signatures and provenance. Define severity thresholds and exception policy rather than assuming scanning alone is a gate.
- Enforce per-environment concurrency, stale-candidate checks and explicit failure states. Workflow cancellation must not reopen a half-upgraded service.

## 10. Phased work decomposition

| Phase | Deliverable | Acceptance boundary |
|---|---|---|
| A: Baseline and feasibility | Current delivery inventory, release/profile contract and GKE compatibility experiments | Agreed GKE posture; critical node/identity/storage constraints measured; no unsupported compatibility claims |
| B: Reference release qualification | Protected GitHub Enterprise candidate workflow using existing Kind lifecycle tools | Exact candidate passes fresh installation and populated upgrade, with real ingestion and registered tests |
| C: GKE pre-production | Dedicated project/identities and reproducible production-like profile | Same candidate passes GKE clean/upgrade/recovery checks; no inherited demo secrets or disposable production state |
| D: Promotion and operations | Protected demo/production release references, approval and maintenance/recovery runbooks | Wrong/stale/failed candidates are refused; successful deployment records running digests and acceptance evidence |
| E: First-customer readiness review | Production profile, ownership, budgets, recovery rehearsal and adversarial-gate status | Human go/no-go supported by evidence and explicit unresolved risks; customer deployment separately authorized |

The independent adversarial repository is a separately delivered dependency, not hidden inside Phase C or E. Its interface can be tested with contract fixtures, but fixture success must never satisfy the real adversarial gate.

Reuse `scripts/gcp-tf/demo-pipeline.sh`, existing slice lifecycle commands, test registry conventions and Terraform patterns where their assumptions hold. Treat `scripts/ci/vm-pipeline.sh` as a reference subject to its frozen legacy policy. Do not simply add GKE flags to Kind-specific image loading or bootstrap code.

The first code should be a small release/evidence validator and supported lifecycle adapters after the contract is approved. It must reject missing evidence, changed digests, wrong profiles, stale baselines, skipped required tests and unauthorized exceptions. Avoid building a dashboard or a general workflow engine.

## 11. Explicit exclusions

- Migrating existing Kind CI/demo to GKE.
- Azure/AKS implementation or qualification now.
- Blue/green, hot-spare or multi-region failover automation.
- Multi-customer shared-tenancy production.
- Creation of the independent adversarial repository.
- Automatic production approval by an agent.
- Guaranteed zero downtime or unmeasured recovery promises.
- A new general-purpose provisioning framework or deployment UI.

## 12. Open decisions before implementation

1. Confirm GKE Standard as the compatibility investigation target and choose node/network profiles based on measured sentinel behavior.
2. Select database and identity production posture, including external dependencies versus self-contained components.
3. Confirm GitHub Enterprise Cloud or Server and the available runner/federation model.
4. Agree maintenance, RTO, RPO, observation and ephemeral-resource cost/TTL budgets.
5. Assign release approval, incident response, recovery and independent-suite ownership.
6. Decide which baseline needs to remain running for soak tests and which environments can be created on demand.

These are decision gates, not a request to resolve every detail before validating the highest-risk compatibility assumptions. No cloud resources should be provisioned until the investigation scope and its budget are approved.
