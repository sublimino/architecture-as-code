---
created: 2026-10-01
reviewers:
  - "#vicente-herrera"
  - "#francesco-beltramini"
capabilities:
  - "#cap-architecture"
  - "#cap-kubernetes"
  - "#cap-security"
  - "#cap-threat-modelling"
  - "#cap-testing-pyramid"
  - "#cap-supply-chain-security"
  - "#cap-policy-as-code"
  - "#cap-gitops"
practice:
  - AI & Data Security
  - Cyber Resilience & Threat Assurance
  - Cloud Native Transformation & DevSecOps
url:
forecastProjectId:
forecastProjectName:
forecastProjectUrl:
obsidianProject: "1. Projects/2026-10-slaat-whole-system-adversarial-testing/"
parentProposal:
enhancements:
tags:
  - innovation-proposals
  - proposal-2026-q4-slaat-whole-system-adversarial-testing
aliases:
  - "#proposal-2026-q4-slaat-whole-system-adversarial-testing"
---
# Proposal - SLAAT Whole-System Autonomous Adversarial Testing (2026-Q4)

|  |  |
| :---: | :---- |
| Proposer & Date: | AJM (2026-10-01) |
| Reviewer & Date: |  |
| Approver & Date: |  |

## Press Release

**ControlPlane announces SLAAT: Whole-System Autonomous Adversarial Testing for Signal Loom**

ControlPlane introduces SLAAT (Signal Loom Autonomous Adversarial Testing). This framework executes systematic adversarial verification across the entire OSRAMP and Signal Loom platform. SLAAT probes five attack surfaces: Ingress gateway routing, backend API token boundaries, SPIFFE workload identities, OpenBao secrets access, and kernel agent sandboxing. SLAAT runs in three distinct stages: whole-system adversarial probing, a fail/fix remediation stage, and a final re-test verification pass. The result gives operators provable confidence in platform isolation and tenant safety.

## Proposal Overview

### Opportunity

**The work relates to the following value area(s):**

- [ ] client revenue
- [ ] marketing
- [x] product
- [x] services engineering
- [ ] cost avoidance
- [ ] process efficiency
- [x] operational or regulatory internal

**Key Customers (if relevant):**

Regulated enterprises, financial services institutions, and security auditors who evaluate Signal Loom and OSRAMP for AI agent governance.

|  |  |
| :---- | :---- |
| Our *platform architects, CISOs, and security auditors* | need automated proof that agent governance boundaries resist active attack. |
| Have the problem/opportunity *...* | complex multi-layer distributed systems accumulate subtle boundary drift across gateway routing, token validation, and sandboxing. |
| When *...* | deploying autonomous AI agents in production environments with untrusted code execution. |

**What is the urgency of this work (e.g. QX 202X), and does this comprise other subcomponents of projects?**

Urgency: Q4 2026. The platform prepares for external partner onboarding and third-party penetration testing. The entire attack surface must pass automated adversarial validation first.

## Scope Summary

Technology readiness level: 3 (Beta). This mission tests and hardens all platform layers through automated adversarial tooling.

### In Scope Activities

| Deliverable | Description | Acceptance Criteria (SMART) | Validation Method |
| :---- | :---- | :---- | :---- |
| D1: Adversarial Attack & Boundary Probing | Subject all platform boundaries to automated adversarial attack probing. | Execute port scans, route traversal, token forgery, IDOR fuzzing, and sandbox escapes. | Automated attack probe suites and vulnerability findings report. |
| D2: Fail/Fix Remediation | Remediate all vulnerabilities and boundary failures discovered during probing. | Patch discovered routing gaps, token flaws, and sandbox confinement bypasses. | Code inspection, unit tests, and contract verification tests. |
| D3: Final Re-Test & Certification | Replay 100% of adversarial attacks against hardened system to prove defenses hold. | Zero attack probes succeed on re-test. Full regression test pyramid passes cleanly. | Adversarial replay test suite and whole-platform regression run. |

### Out of Scope

- Physical datacenter security testing.
- Hypervisor zero-day exploits.
- Volumetric denial of service floods.
- Altering core cryptographic ciphers.

### KPIs

| Metric | Current Value | Target Value | Measurement |
| :---- | :---- | :---- | :---- |
| Successful adversarial probe bypasses on final re-test | Unknown | 0 | Automated attack replay suite |
| Unauthenticated API mutation paths | 0 | 0 | API contract audit |
| Platform regression test pass rate | 100% | 100% | `make test-all-offline` and smoke suites |

## Proposed Solution

SLAAT executes a three-phase closed-loop adversarial lifecycle:
1. **Phase 1: Whole-System Adversarial Attack & Boundary Probing**: Automated probes test ingress routing, API authorization, SPIFFE tokens, and kernel containment.
2. **Phase 2: Adversarial Vulnerability Remediation & Fail/Fix**: Engineers triage failures and implement targeted defense hardening across all affected layers.
3. **Phase 3: Final Re-Test & Mission Certification**: Replay all attack vectors against the hardened platform and confirm complete defense.

### Technical Architecture

- **Mission Shortcode:** `SLAAT`
- **Repository Root:** `/home/andy/src/cp/osramp-demo`
- **Integration Branch:** `refs/heads/integration/slaat-whole-system-adversarial`
- **Scheduled Cadence:** `*/5 * * * *`
- **Acceptance Commands:**
  - `make test-all-offline`
  - `make test-eap-offline`
  - `make healthcheck`
  - `make test-postgres-persistence`
  - `make test-zot-cache`

# Decision Log

| Date | Decision Makers | Decision and context | Reason | Impact |
| :---- | ----- | ----- | ----- | ----- |
| 2026-10-01 | AJM | Structure SLAAT into 3 distinct phases: Attack, Fail/Fix, and Final Re-Test. | Matches user request for explicit fail/fix and re-test stages. | Provides clean separation between vulnerability discovery and patch verification. |
| 2026-10-01 | AJM | Enforce automated regression test replay in Phase 3. | Proves that all discovered defects are permanently closed. | Guarantees zero residual vulnerabilities. |

## Appendix

### A. Useful Links

* `AGENTS.md` - Platform architecture and operational rules.
* `TESTING.md` - Diagnostic verification runbook and test suites.
* `docs/signalloom/host-enrollment-protocol.md` - External agent enrollment and token protocol.
* `d2-agent-trust/AGENTS.md` - SPIFFE identity hierarchy and OpenBao JWT roles.

### Spec: Shared Patterns - Phase 1

This architectural constitution defines the baseline patterns for the SLAAT mission:

- **Adversarial Integrity:** All attack probes must report objective findings without silent swallows or masking.
- **Fail-Closed Boundaries:** Any invalid token, corrupted SVID, or unauthorized tenant request must fail closed with HTTP 401 or 403.
- **Microsegmentation Rule:** Workload ingress must route strictly through Envoy Gateway or explicit peer NetworkPolicies.
- **Containment Rule:** Agent processes must run under strict Landlock LSM confinement and cgroup freeze controls.
- **Evidence Verification:** Every remediation must provide a matching test proof demonstrating the attack vector is neutralized.

### Spec: Capability Plan

| Logical ID | Selected Skills & Agents | Size Band | Wall-Clock Ceiling | CPAI Agent ID | Rationale |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `SLAAT-P1-PRE` | `research`, `bash` | S | 30m | `daily` | Pre-flight environment check, baseline test execution, and attack tooling verification. |
| `SLAAT-P1-1` | `kubernetes`, `security`, `bash` | M | 60m | `daily` | Ingress gateway routing, TLS validation, and NetworkPolicy boundary attack probing. |
| `SLAAT-P1-2` | `security`, `python`, `pytest` | L | 90m | `daily` | Backend API, Dex OIDC, token replay, and multi-tenant IDOR adversarial fuzzing. |
| `SLAAT-P1-3` | `spiffe`, `openbao`, `security` | M | 60m | `daily` | SPIFFE identity, OpenBao JWT role bindings, and SVID privilege escalation testing. |
| `SLAAT-P1-4` | `security`, `cgroup`, `ebpf`, `bash` | M | 60m | `daily` | Sentinel eBPF monitoring, cgroup-freeze, and Landlock sandbox containment escape probing. |
| `SLAAT-P1-GOV` | `architecture`, `testing`, `bash` | L | 90m | `daily` | Phase 1 Governor Gate: synthesize attack findings, generate vulnerability dossier, and merge to integration branch. |
| `SLAAT-P2-PRE` | `research`, `bash` | S | 30m | `daily` | Phase 2 Pre-Flight: triage Phase 1 vulnerability dossier and structure remediation plan. |
| `SLAAT-P2-1` | `kubernetes`, `security`, `bash` | M | 60m | `daily` | Ingress route hardening, NetworkPolicy microsegmentation, and network boundary fixes. |
| `SLAAT-P2-2` | `security`, `python`, `pytest` | L | 90m | `daily` | Backend API auth hardening, tenant claim validation, and enrollment security fixes. |
| `SLAAT-P2-3` | `spiffe`, `openbao`, `security` | M | 60m | `daily` | SPIFFE Workload API and OpenBao JWT role binding policy tightening. |
| `SLAAT-P2-4` | `security`, `cgroup`, `ebpf`, `bash` | M | 60m | `daily` | Sentinel containment, Landlock LSM policy enforcement, and sandbox escape fixes. |
| `SLAAT-P2-GOV` | `architecture`, `testing`, `bash` | L | 90m | `daily` | Phase 2 Governor Gate: reconcile remediations, verify build integrity, and run unit regression suites. |
| `SLAAT-P3-PRE` | `research`, `bash` | S | 30m | `daily` | Phase 3 Pre-Flight: clean cluster attestation, database refresh, and pre-test calibration. |
| `SLAAT-P3-1` | `security`, `testing`, `bash` | L | 90m | `daily` | Full adversarial attack replay against hardened platform; assert zero exploits succeed. |
| `SLAAT-P3-2` | `testing`, `bash`, `python` | L | 90m | `daily` | Whole-platform multiplane acceptance testing and comprehensive regression suite. |
| `SLAAT-P3-GOV` | `architecture`, `testing`, `bash` | L | 90m | `daily` | Final Mission Governor Gate: final certification report, errata ledger consolidation, and delivery sign-off. |

### Spec: Work Decomposition

| Phase | ID | Title | Depends On | Prompt Summary | Tests | Size | Agent | Result | Est. Cost | Tokens | Elapsed | AI URI |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | :-------- | :----- | :------ | :--- |
| P1 | `SLAAT-P1-PRE` | Phase 1 Pre-Flight Check & Baseline Assessment | none | Verify repository baseline, clean git status, cluster readiness, test fixtures, and adversarial probe tooling. | `unit` | `S` | `daily` | not started | $0.00 | 0 | 0s | none |
| P1 | `SLAAT-P1-1` | Ingress Gateway & Network Isolation Attack Probing | `SLAAT-P1-PRE` | Probe Envoy Gateway HTTPRoutes, TLS certificate termination, and NetworkPolicy isolation across all namespaces. | `integration` | `M` | `daily` | not started | $0.00 | 0 | 0s | none |
| P1 | `SLAAT-P1-2` | Backend API & Multi-Tenant IDOR Adversarial Fuzzing | `SLAAT-P1-PRE` | Fuzz FastAPI routes, Dex OIDC authentication, Bearer token replay, tenant isolation, and enrollment endpoints. | `contract` | `L` | `daily` | not started | $0.00 | 0 | 0s | none |
| P1 | `SLAAT-P1-3` | SPIFFE Identity & OpenBao JWT Privilege Escalation Probing | `SLAAT-P1-PRE` | Probe SPIRE Workload API policies, OpenBao JWT roles, token TTLs, and cross-tenant credential delegation risks. | `integration` | `M` | `daily` | not started | $0.00 | 0 | 0s | none |
| P1 | `SLAAT-P1-4` | Sentinel eBPF & Landlock Sandbox Confinement Escape Attacks | `SLAAT-P1-PRE` | Execute sandbox breakout probes, test cgroup freeze enforcement, and probe Landlock LSM containment. | `integration` | `M` | `daily` | not started | $0.00 | 0 | 0s | none |
| P1 | `SLAAT-P1-GOV` | Phase 1 Governor Gate: Vulnerability Dossier & Attack Log | `SLAAT-P1-1`, `SLAAT-P1-2`, `SLAAT-P1-3`, `SLAAT-P1-4` | Aggregate all adversarial probe results, compile vulnerability dossier, and merge evidence to integration branch. | `e2e` | `L` | `daily` | not started | $0.00 | 0 | 0s | none |
| P2 | `SLAAT-P2-PRE` | Phase 2 Pre-Flight Check & Remediation Triage | `SLAAT-P1-GOV` | Triage Phase 1 vulnerability dossier, reproduce confirmed failure modes, and prepare remediation branches. | `unit` | `S` | `daily` | not started | $0.00 | 0 | 0s | none |
| P2 | `SLAAT-P2-1` | Ingress Route Protection & Network Microsegmentation Fixes | `SLAAT-P2-PRE` | Harden Envoy Gateway routing, seal unauthenticated bypass paths, and tighten NetworkPolicy rules. | `integration` | `M` | `daily` | not started | $0.00 | 0 | 0s | none |
| P2 | `SLAAT-P2-2` | Backend API Auth, Token Expiry & Tenant IDOR Fixes | `SLAAT-P2-PRE` | Remediate API authorization flaws, enforce strict tenant token boundaries, and secure agent enrollment. | `contract` | `L` | `daily` | not started | $0.00 | 0 | 0s | none |
| P2 | `SLAAT-P2-3` | SPIFFE Workload API & OpenBao Policy Hardening Fixes | `SLAAT-P2-PRE` | Restrict OpenBao JWT role claims, enforce short token lifetimes, and eliminate wildcard SPIFFE selectors. | `integration` | `M` | `daily` | not started | $0.00 | 0 | 0s | none |
| P2 | `SLAAT-P2-4` | Agent Sandbox Confinement & Landlock LSM Policy Fixes | `SLAAT-P2-PRE` | Seal sandbox breakout vectors, enforce Landlock filesystem rules, and harden eBPF detection alarms. | `integration` | `M` | `daily` | not started | $0.00 | 0 | 0s | none |
| P2 | `SLAAT-P2-GOV` | Phase 2 Governor Gate: Remediations Integration & Rebuild | `SLAAT-P2-1`, `SLAAT-P2-2`, `SLAAT-P2-3`, `SLAAT-P2-4` | Reconcile all remediations, verify clean compilation and unit tests, and prove invariant boundary compliance. | `e2e` | `L` | `daily` | not started | $0.00 | 0 | 0s | none |
| P3 | `SLAAT-P3-PRE` | Phase 3 Pre-Flight Check & Test Environment Refresh | `SLAAT-P2-GOV` | Re-attest fresh Kind cluster, reset database state, and calibrate re-test execution rigs. | `unit` | `S` | `daily` | not started | $0.00 | 0 | 0s | none |
| P3 | `SLAAT-P3-1` | Full Adversarial Attack Replay & Exploit Defense Verification | `SLAAT-P3-PRE` | Replay 100% of Phase 1 adversarial probes against hardened platform; verify all attacks fail cleanly. | `integration` | `L` | `daily` | not started | $0.00 | 0 | 0s | none |
| P3 | `SLAAT-P3-2` | Whole-Platform Acceptance & Multiplane Regression Suite | `SLAAT-P3-PRE` | Execute whole-platform test pyramid including `make test-all-offline`, live acceptance, and SuperCred tests. | `e2e` | `L` | `daily` | not started | $0.00 | 0 | 0s | none |
| P3 | `SLAAT-P3-GOV` | Final Mission Governor Gate: Certification & Hand-Off | `SLAAT-P3-1`, `SLAAT-P3-2` | Generate final certification report, consolidate errata ledgers, verify clean git status, and close mission. | `e2e` | `L` | `daily` | not started | $0.00 | 0 | 0s | none |

### Spec: Errata

#### Errata — SLAAT-P1-PRE (preflight)
<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->
**Created:** 2026-10-01T23:25:43+01:00
**Last Updated:** 2026-10-01T23:29:45+01:00

##### Task identity
- Card: `SLAAT-P1-PRE` (kanban `ec835`)
- Shortcode: `SLAAT`
**Status:** pass
- Task base: `73499882e3e68a69dddf4ef27aee217b8a502d7b` (detached). Card commits were rebased onto `refs/heads/integration/slaat-whole-system-adversarial` @ `47d124eec7ebd0cbf95c72bd2a461818b6813d45`, so integration fast-forwards to them. Without the rebase the merge hit an add/add conflict on this proposal, because integration carries rebased copies of the two proposal commits. Canonical repo is `/home/andy/src/cp/osramp-demo`; this worktree's `.cline` path resolves to `/home/andy/src/.worktrees/ec835/osramp-demo`.
- Result: environment validated and pre-attack baseline captured. Pre-existing reds and environment hazards are recorded, not fixed. No production files were changed.
**Phase 1 can proceed:** yes

##### Deliverable verification
- `scripts/slaat-preflight.sh` → exit `0`, `status: pass`. Proof at `docs/slaat/p1-pre/preflight-env.json`.
  - Tools: bats 1.13.0, go 1.26.2, pytest 9.1.1 (uv, py3.12), uv 0.5.10, kubectl v1.36.0, curl 8.20.0, jq 1.8.1.
  - `go env` reports `GOCACHE`/`GOMODCACHE` overridden and `CGO_ENABLED=0`.
- Cluster `kind-osramp` (read-only checks): 1/1 node Ready, `inf-signalloom/postgresql` 1/1, `registry/zot` 1/1, `make healthcheck` green.
- `scripts/slaat-baseline.sh` captured 15 slices. Per-slice results are in `docs/slaat/p1-pre/baseline-summary.tsv`, with the analysis in `docs/slaat/p1-pre/baseline.md`.
- Acceptance commands:
  - `make test-postgres-persistence`: 7/7.
  - `make test-zot-cache`: 3/3.
  - `make healthcheck`: green.
  - **`make test-eap-offline`: red, rc 2.** pytest 4 failed / 246 passed. ROUTELIVE test 11 not ok: the dashboard calls `/api/discovery/claim`, which the running portal does not serve.
  - **`make test-all-offline`: not measurable in a worktree.** Stage 1 Go was clean (105 ok, 0 FAIL), then stage 2 `bun install` stopped with `EEXIST` through a shared `node_modules` symlink (hazard 1 below).
- Attack slices:
  - Ingress: 14/15.
  - API: fe-signalloom pytest 19 failed / 2347 passed / 94 skipped; authz-liveness 3/3.
  - SPIFFE: agent-trust 8/8; bao-spire-proof 7/7.
  - Containment: stun-sentinel Go (12 packages), signalloom-stun-sentinel Go (3 packages) and nono-probe Go all green; olly sentinel pytest 45/45; tetragon bats 27/27.
- `ajm-auto-kanban/Tools/kanban-check.sh`:
  - `link-check --shortcode SLAAT` → exit 0, CRITICAL=0 FAIL=0 WARN=0.
  - `doctor` → UNHEALTHY, with two exceptions attributed and not blocking:
    - DOC-3: the principal checkout holds another session's uncommitted files.
    - DOC-6: this card's 5× spawn flap, already root-caused in `slaat-governor-log.md` as a `kpai` interactive-PTY exit.

##### Drift and findings
- **Base drift (resolved by rebase, not blocking).** The card base `73499882` was 4 behind and diverged from integration `47d124ee`; its 2 proposal commits are patch-equivalent to integration's `21e1ad5a`/`99352ba6`. After the rebase HEAD is ahead 2, behind 0.
  - Integration carries `924e359a` (sentinel Kustomization per-cluster overlay) and `47d124ee` (sentinel image canonical tag).
  - Peer session `osramp-demo-65` reports `ab392c5f` (stun-sentinel RoleBinding single owner) on `feat/signal-loop-and-bootstrap-refactor` and already live on `kind-osramp`, so the integration ref is one commit behind what is deployed. Moving the ref is the Governor's decision.
- **Pre-existing EAP/API reds.** These are leads for `SLAAT-P1-2`; the details are in `docs/slaat/p1-pre/baseline.md`.
  - 9 authenticated routes sit outside the tenant-scope sweep.
  - 15 mutating routes have no audit decision.
  - 2 in-memory audit writes: `agents.py:181` and `discovery.py:264`.
  - The `GET /api/v1/discovery/workloads` DB-route entry checks nothing.
- **Live cluster state (checked read-only).**
  - `fe-signalloom/signal-ingest` runs `signal-ingest:local`. The peer says this image is pre-auth and has no `SIGNAL_AUTH`.
  - `stun-sentinel` DaemonSet runs `signalloom-stun-sentinel:v0.2.0` at 1/1.
  - The postgresql pod was recreated at `2026-10-01T20:59:35Z`. The peer reports `agent_registry` was emptied by the persistence rollout.
- **Controller stalled (peer-reported).** `osramp-demo-65` reports that the SLAAT supervisor cron has not ticked since 2026-10-01T22:01Z, because its host session `osramp-demo-b2` exited. Nothing advances the board until the governor lease is re-hosted. That peer will not run `bun install` while SLAAT cards are active.
- **Hazards for later cards.**
  1. Four `node_modules` dirs are symlinks into the principal checkout, so `bun install` in a worktree mutates another tree. `slaat-preflight.sh` now warns on these.
  2. Suites rewrite two tracked evidence files: `redteam_cascade_ceiling.json` and `sler-p6-3-acceptance-runtime.jsonl`. Both were reverted here.
  3. Without `UV_CACHE_DIR`, `uv run` fails because `~/.cache/uv` is sandbox-denied.
  4. `scripts/kanban-check.sh` points at the removed `ajm-cline-kanban` path (rc 127).
