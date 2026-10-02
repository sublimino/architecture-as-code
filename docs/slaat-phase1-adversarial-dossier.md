# SLAAT Phase 1: Whole-System Adversarial Vulnerability Dossier

Mission: SLAAT (Signal Loom Autonomous Adversarial Testing). Phase 1 probed
five attack surfaces across the OSRAMP and Signal Loom platform. They are
ingress gateway routing, backend API token boundaries, SPIFFE workload
identity, OpenBao secrets access, and kernel agent sandboxing. This dossier
is the authoritative Governor-reconciled record of every finding raised by
cards `SLAAT-P1-1` through `SLAAT-P1-4`. The machine-readable twin of this
document is `ci-evidence/slaat-phase1-consolidated-findings.json`.

Phase 2 (`SLAAT-P2-1` through `SLAAT-P2-4`) remediates every item below.
Phase 3 replays every attack vector against the hardened platform.

## Severity taxonomy

| Severity | Meaning |
| :--- | :--- |
| CRITICAL | An active, exploitable boundary bypass, or a mission invariant violated in a way that gives an attacker material capability today. |
| HIGH | A control is absent or disabled such that a known attack path is open, protected currently only by accident, convention, or a detection gap. |
| MEDIUM | A real defect with bounded or conditional impact: fails closed, needs contention to trigger, or is confined to a non-tenant-facing path. |
| LOW | A hardening gap, availability defect, or stale artifact with no credible path to tenant-boundary compromise. |
| INFO | A coverage gap, accepted demo convention, or observation with no finding attached. |

## Summary by severity

| Severity | Count |
| :--- | :--- |
| CRITICAL | 1 |
| HIGH | 3 |
| MEDIUM | 5 |
| LOW | 11 |
| INFO | 4 |
| **Total** | **24** |

Zero confirmed SQL injection. Zero confirmed JWT verification bypass. Zero
confirmed cross-tenant data leak. Zero unauthorized host escapes. Zero kernel
panics or host instability across all four probe domains.

## Domain 1: Ingress Gateway & Network Isolation (`SLAAT-P1-1`)

Probe suite: `test/adversarial-network-probes.bats` (20/20 passing on two
independent Governor runs). Raw evidence:
`ci-evidence/slaat-p1-1-network-findings.json`,
`ci-evidence/slaat-p1-1-gateway-access-log-sample.jsonl`.

Envoy Gateway's own routing hygiene is confirmed clean. Path traversal,
percent-encoded traversal, double-slash merging, embedded null bytes, and
weak TLS versions are all rejected before any backend is contacted. The
confirmed gaps are all at the Kubernetes NetworkPolicy layer, not the
gateway itself.

| ID | Severity | Finding |
| :--- | :--- | :--- |
| NET-1 | HIGH | The `ingress` namespace, which hosts the Envoy Gateway control plane, carries zero NetworkPolicy. Its metrics port 19001 is reachable from any unprivileged tenant pod with no authentication. |
| NET-2 | MEDIUM | The `backend` namespace carries zero NetworkPolicy. `frontend` can reach `backend`'s MinIO, NATS, and Postgres with no policy on either side. |
| NET-3 | MEDIUM | The `frontend` namespace carries zero NetworkPolicy. |
| NET-4 | LOW | The `fe-k8s-afm` namespace carries zero NetworkPolicy (single pod). |
| NET-5 | LOW | The `cpai` namespace carries zero NetworkPolicy (single pod). |
| NET-6 | LOW | The `kagent` namespace is only partially covered. The controller-to-postgres path is correctly scoped, but `kagent-controller`, `kagent-ui`, and `kagent-tools-metrics` have no Ingress policy and no egress restriction at all. |
| NET-7 | LOW | Platform namespaces (`cert-manager`, `kube-system`, `spire-system`, `local-path-storage`, `registry`) carry zero NetworkPolicy. A blanket default-deny risks breaking core cluster plumbing; this needs a scoped allowlist, not a blind copy of the tenant fix. |
| NET-8 | INFO | No `ClientTrafficPolicy` declares the `X-Forwarded-For` trust boundary. Envoy's current default is safe, but the boundary is implicit. |
| NET-9 | INFO | HTTP/2 pseudo-header manipulation was not exhaustively tested: `curl` cannot forge invalid framing independent of its own library. Recorded as a coverage gap, not asserted clean. |

Confirmed-clean controls are path traversal normalization, percent-encoded
slash rejection, null-byte rejection, TLS 1.0/1.1 refusal, and TLS 1.2/1.3
strong AEAD negotiation. Also confirmed clean: SNI-layer rejection of
unregistered virtual hosts, and Host-header spoofing containment.
`default`, `inf-signalloom`,
`agent-trust-*`, `fe-signalloom*`, `inf-bao`, `flux-system`, `eap-6f82ad81`,
and `stun-pre-probe` all carry a genuine blanket default-deny that held under
direct lateral-movement probing.

## Domain 2: Backend API & Multi-Tenant IDOR (`SLAAT-P1-2`)

Probe suite: `tests/test_adversarial_api_security.py`
(210/210 passing on two independent Governor runs, run from
`d2-signalloom/apps/fe-signalloom/src`). Raw evidence:
`ci-evidence/slaat-p1-2-api-findings.json`,
`ci-evidence/slaat-p1-2-live-probe-evidence.json`. 373 new test cases
total across four suites, plus 7 live read-only probes against the deployed
`fe-signalloom-api` service. Zero exploitable bypasses, zero SQL injection,
zero JWT verification bypass, zero cross-tenant data leak confirmed.

| ID | Severity | Finding |
| :--- | :--- | :--- |
| API-F3 | HIGH | `routers.policies`'s own CEL-validate, evaluate, and bundle routes carry no auth dependency. They are currently unreachable only by router-registration-order accident, not by a deliberate control. |
| API-F1 | MEDIUM | No rate limiting middleware is installed anywhere in the application. |
| API-F2 | LOW | `Settings.cors_allowed_origins` is declared but never wired to `CORSMiddleware`. Fails closed today (browsers enforce same-origin by default), but the configuration is dead. |
| API-F4 | LOW | Ad-hoc per-router error messages occasionally include raw exception text. |
| API-F5 | LOW | A `threading.Lock` is held across an `await` in `enroll_host_handler`'s in-memory fallback path, a latent deadlock and availability risk. |
| API-F6 | LOW | Duplicate router registration inflates route counts and breaks pre-existing inventory-exactness tests. Confirmed pre-existing: reproduced identically with this card's four new files removed from disk. Not caused by this card. |

## Domain 3: SPIFFE Identity & OpenBao JWT Privilege Escalation (`SLAAT-P1-3`)

Probe suite: `test/spiffe-openbao-adversarial.bats` (16/16 passing on two
independent Governor runs). Raw evidence:
`ci-evidence/slaat-p1-3-spiffe-findings.json`,
`ci-evidence/slaat-p1-3-acl-audit-evidence.json`,
`ci-evidence/slaat-p1-3-live-probe-records.json`. 34 live probes executed
against the kind-osramp cluster's SPIRE server, SPIRE agent, and OpenBao
instance.

| ID | Severity | Finding |
| :--- | :--- | :--- |
| SPIFFE-F1 | CRITICAL | The `signalloom-cardvault-agent` and `signalloom-fe-signalloom` OpenBao JWT roles issue 768-hour (32-day) tokens. The mission's Fail-Closed Boundaries invariant requires a 5-minute hard cap on workload credentials. |
| SPIFFE-F2 | MEDIUM | The `signalloom-agent-generic` role's `bound_claims` glob is missing `bound_claims_type=glob`, so it is non-functional and permanently denies all 18 registered fleet agents. Fails closed: an availability defect, not an active bypass. |
| SPIFFE-F3 | LOW | Two of four live SPIRE-registered agent-trust tenant identities have no corresponding OpenBao JWT role. A delegation gap, not a privilege-escalation path. |
| SPIFFE-F4 | LOW | The SPIRE agent runs with `insecure_bootstrap=true` and `skip_kubelet_verification=true`. Demo-appropriate today; flag before any path toward production. |
| SPIFFE-F5 | INFO | `agent-cardvault`'s Workload API socket is mounted via raw `hostPath` rather than the documented `spiffe-csi-driver` ephemeral volume. |
| SPIFFE-F6 | INFO | A static root token (`signalloom-demo-root-token`) is hardcoded across multiple live ConfigMaps and Jobs. Accepted pre-existing demo convention. |

Confirmed-clean controls: unregistered ServiceAccounts are denied an SVID.
Wrong-identity and wrong-audience SVIDs are rejected by OpenBao role
binding. Tampered-signature SVIDs are rejected, and so are `alg:none`
forged tokens. No live registration entry relies on a namespace-only
selector.

## Domain 4: Sentinel eBPF & Landlock Sandbox Confinement (`SLAAT-P1-4`)

Probe suite: `test/landlock-adversarial-escape.bats` (15/15 passing on two
independent Governor runs). Raw evidence:
`ci-evidence/slaat-p1-4-confinement-findings.json`,
`ci-evidence/slaat-p1-4-landlock-escape-probe-records.json`,
`ci-evidence/slaat-p1-4-sentinel-evasion-probe-records.json`,
`ci-evidence/slaat-p1-4-cgroup-adversarial-probe-records.json`. 36 live
probes executed: 16 Landlock escape attempts, 9 sentinel evasion attempts,
11 cgroup-freeze adversarial tests. Zero unauthorized host escapes, zero
kernel panics, zero host instability.

| ID | Severity | Finding |
| :--- | :--- | :--- |
| SENT-F1 | HIGH | The live sentinel's eBPF program attaches only `tp_btf/inet_sock_set_state` (TCP flow state): zero process, ptrace, or namespace-creation visibility. A fuller syscall tracer exists in-repo but is wired into no `cmd/` entrypoint and is not deployed. Evading telemetry via process spawning, `ptrace`, or `unshare` succeeds trivially today because there is no instrumentation for those actions to evade. A detection-scope gap, not a bypass of a working defense. |
| SENT-F2 | MEDIUM | Freezing a cgroup containing a process that has `unshare(CLONE_NEWPID)`'d with `mount_proc` intermittently returned HTTP 504 (2 of 5 runs) against the isolated test instance under shared-node contention. Once the freeze call completes it is unconditionally effective, confirmed by a zero CPU-usage delta and `cgroup.events` reporting `frozen 1` every time. A latency and reliability finding against one workload shape under load, not a containment bypass. |
| SENT-F3 | LOW | The sibling `CRKC-P1-2` harness `scripts/test-cgroup-freezer.sh` is stale against the current binary's auth contract: it sets only `STUN_RESUME_TOKEN` and sends no `Authorization` header, while the binary now bearer-gates `/stun`. Outside this card's merge boundary; belongs to `CRKC-P1-2`. |

Confirmed-clean controls: Landlock denies reads outside the allowed
worktree, even through a symlink. It denies cross-process `/proc`
environment reads and denies `ptrace`-attach to an unrelated process. It
denies new filesystem access after a PID-namespace `unshare`, and it
propagates confinement to child processes. It holds against a background
subshell racing ruleset application.

## Phase 2 remediation backlog

Each finding above names its `remediation_target`. The mapping from Phase 1
domain to Phase 2 card is fixed:

| Phase 1 domain | Findings | Phase 2 card |
| :--- | :--- | :--- |
| Ingress & network isolation | NET-1 .. NET-9 | `SLAAT-P2-1` |
| Backend API & tenant IDOR | API-F1 .. API-F6 | `SLAAT-P2-2` |
| SPIFFE identity & OpenBao | SPIFFE-F1 .. SPIFFE-F6 | `SLAAT-P2-3` |
| Sentinel & Landlock confinement | SENT-F1 .. SENT-F3 | `SLAAT-P2-4` |

Priority order for `SLAAT-P2-PRE` triage, by severity then blast radius:

1. SPIFFE-F1 (CRITICAL): cap the two 32-day OpenBao JWT role TTLs at 5
   minutes.
2. NET-1 (HIGH): default-deny the `ingress` namespace and scope the Gateway
   metrics port.
3. API-F3 (HIGH): add the missing auth dependency to the CEL policy routes.
4. SENT-F1 (HIGH): wire the existing syscall tracer into a deployed
   entrypoint, or accept and document the detection-scope gap before Phase 3.
5. NET-2, NET-3 (MEDIUM): default-deny `backend` and `frontend`.
6. API-F1 (MEDIUM): add rate limiting middleware.
7. SPIFFE-F2 (MEDIUM): fix the `bound_claims_type=glob` omission restoring
   the 18 denied fleet agents.
8. SENT-F2 (MEDIUM): raise or make configurable the freeze-call deadline
   under host contention.
9. All LOW and INFO items fold into the relevant Phase 2 card's hardening
   pass. None blocks Phase 2 start.

F6 (API) and SENT-F3 are confirmed pre-existing defects, not introduced by
any SLAAT Phase 1 card. SENT-F3 belongs to `CRKC-P1-2`, a different
mission, and is out of SLAAT's remediation scope. It is recorded here only
because the probe surfaced it.

## Reproducibility

Every finding above traces to a passing or informational record inside the
JSON files listed per domain. The four Governor-required probe suites were
executed twice, independently, in this worktree, with isolated `/tmp`
cache directories. Both runs produced identical pass counts:
`test/adversarial-network-probes.bats` (20/20),
`tests/test_adversarial_api_security.py` (210/210),
`test/spiffe-openbao-adversarial.bats` (16/16),
`test/landlock-adversarial-escape.bats` (15/15). The machine-readable
consolidated catalog is `ci-evidence/slaat-phase1-consolidated-findings.json`.
