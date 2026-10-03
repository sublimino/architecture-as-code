---
created: 2026-10-02
reviewers:
  - "#vicente-herrera"
  - "#stefan-prodan"
  - "#francesco-beltramini"
capabilities:
  - "#cap-security-engineering"
  - "#cap-architecture"
  - "#cap-kubernetes"
  - "#cap-secrets"
  - "#cap-golang"
  - "#cap-python"
  - "#cap-api-design"
  - "#cap-threat-modelling"
  - "#cap-testing-pyramid"
practice:
  - AI & Data Security
  - Cloud Native Transformation & DevSecOps
  - Cyber Resilience & Threat Assurance
url:
forecastProjectId:
forecastProjectName:
forecastProjectUrl:
obsidianProject: "1. Projects/2026-07-signalloom-d2-platform-baseline/"
parentProposal: "[[Proposal — Signal Loom Agent Security Platform (2026-Q3)]]"
enhancements:
tags:
  - innovation-proposals
  - proposal-2026-q4-signal-loom-spireless-token-migration
  - partner-signal-loom
  - osramp
aliases:
  - "#proposal-2026-q4-signal-loom-spireless-token-migration"
shortcode: SLTM
---
# Proposal — Signal Loom Spireless Token-Based Agent Identity Migration (2026-Q4)

|  |  |
| :---: | :---- |
| Proposer & Date: | AJM (2026-10-02) |
| Reviewer & Date: | Vicente Herrera, Stefan Prodan, Francesco Beltramini (2026-10-02) |
| Approver & Date: | Andy Martin (2026-10-02) |

---

## Press Release

ControlPlane today announced the Spireless Token-First Identity Architecture for Signal Loom, eliminating thousands of lines of privileged in-cluster infrastructure and replacing brittle node-socket workload attestation with standard, zero-trust API bearer token authentication. By decoupling agent governance from in-cluster SPIRE servers and host-mounted CSI drivers, enterprise platform teams can now onboard autonomous AI agents across any cloud, bare-metal VM, or local developer workstation in under 30 seconds using standard HTTPS API calls.

Previously, running Signal Loom required deploying SPIRE Server stateful sets, privileged host-PID SPIRE Agents, Unix domain socket projections via `spiffe-csi-driver`, and complex inter-cluster federation bridges. While mathematically rigorous, this architecture created insurmountable friction for external agents—such as Claude Code on developer laptops, Kusari vulnerability scanners in customer VPCs, and headless Daytona sandboxes—which lack access to a Kubernetes node Unix socket. Furthermore, managed Kubernetes environments routinely block the privileged host mounts required by SPIRE node agents.

Under the new architecture, identity is modeled directly through cryptographic Bearer tokens and dynamic OpenBao token exchange. Agents and host implants enroll over standard HTTPS via `POST /enroll`, receive a short-lived cryptographically signed session token, and authenticate every subsequent telemetry ingestion and policy evaluation request via standard `Authorization: Bearer <token>` HTTP headers. The entire `spire-system` footprint is deleted, slashing cluster memory consumption by over 650MB and eliminating node daemonset race conditions entirely, while providing robust 8-hour session leases, partition-tolerant local ring buffering, proactive sliding token refreshes, and sub-second cryptographic revocation.

---

## Proposal Overview

### Opportunity

**The work relates to the following value area(s):**

- [x] client revenue
- [ ] marketing
- [x] product
- [x] services engineering
- [x] cost avoidance
- [x] process efficiency
- [x] operational or regulatory internal

**Key Customers:**

1. **Kusari & Enterprise Early Access Program (EAP) Pilots**: External agents operating outside the Kind or cloud Kubernetes boundary (e.g. running in customer VPCs or on independent compute instances) that need to securely stream telemetry and receive governance directives without complex SPIRE federation.
2. **Internal AI Engineering & Agent Developers**: Engineers running local coding agents (Claude Code, Daytona, Kagent) who cannot mount privileged host sockets or run root-level SPIRE node agents on local Linux/macOS workstations.
3. **Hardened Managed Kubernetes Platforms (EKS / GKE / AKS)**: Enterprise environments where CIS benchmarks, Pod Security Standards (Restricted), and security policies ban hostPID, hostPath Unix socket mounts, and privileged CSI volume drivers.

|  |  |
| :---- | :---- |
| Our *…* | Enterprise customers and internal engineers deploying autonomous AI agents across diverse cloud, host, and local environments |
| Have the problem/opportunity *…* | Inability to run or onboard agents without deploying heavy, privileged SPIRE DaemonSets, Unix socket volume mounts (`/run/spire/sockets`), and complex trust domain federation relays |
| When *…* | Onboarding external agents (Kusari, Daytona, developer workstations), operating in hardened Kubernetes clusters with strict pod security admission, or running lightweight single-node Kind demonstration estates |

**What’s the urgency of this work (e.g. QX 202X), and does this comprise other subcomponents of projects?**

**Urgency: Q4 2026 (Immediate)**.
This enhancement unblocks the Kusari EAP onboarding flow ([`2. Areas/CEO/Innovation Validation/Validation Runbook — SLCO Signal Loom Customer Onboarding Flow v2 (2026-Q4).md`](file:///home/andy/Documents/Obsidian/v1/2.%20Areas/CEO/Innovation%20Validation/Validation%20Runbook%20%E2%80%94%20SLCO%20Signal%20Loom%20Customer%20Onboarding%20Flow%20v2%20(2026-Q4).md)). External sensor enrollment currently fails or requires complex local workarounds because the server expects SPIRE registration entries and node-attested SPIFFE IDs. Replacing this with API token exchange allows immediate, zero-friction remote onboarding.

---

## Scope Summary

**Technology Readiness Level:** 2 (Alpha prototype) to 4 (Production ready). The external host enrollment token exchange was prototyped in `d2-signalloom/apps/fe-signalloom/src/host_enrollment.py`; this proposal promotes direct token exchange to the canonical identity plane and removes SPIRE entirely from the server.

### In Scope Activities

*Within project delivery and managed by the project team*

| Deliverable | Description | Acceptance Criteria (SMART) | Validation Method |
| :---- | :---- | :---- | :---- |
| **D1: Token-First Enrollment API** | Refactor [`host_enrollment.py`](file:///home/andy/src/cp/osramp-demo/d2-signalloom/apps/fe-signalloom/src/host_enrollment.py) and [`cli.py`](file:///home/andy/src/cp/osramp-demo/d2-signalloom/apps/agentmaxxing-host-sensor/cli.py) to issue and receive signed Bearer tokens on `POST /enroll` without creating SPIRE registration entries. | **Specific:** `POST /enroll` accepts a single-use enrollment token and returns a cryptographically signed agent Bearer token (`sl_at_*`) with claims `tenant_id`, `agent_id`, and `exp`.<br/>**Measurable:** 100% of enrollment requests succeed without invoking SPIRE APIs or referencing `spiffe://` URIs.<br/>**Attainable:** Leverages existing single-use token exchange mechanics in `fe-signalloom`.<br/>**Realistic:** Implemented purely in Python backend and CLI client.<br/>**Time-Bound:** Completed in Milestone 1. | Automated Pytest suite [`test_host_enrollment.py`](file:///home/andy/src/cp/osramp-demo/d2-signalloom/apps/fe-signalloom/src/tests/test_host_enrollment.py). |
| **D2: Ingestion Bearer Token Middleware** | Implement Bearer token extraction and cryptographic signature validation in [`signal-ingest`](file:///home/andy/src/cp/osramp-demo/d2-signalloom/apps/signal-ingest/) for all HTTP and gRPC telemetry endpoints. | **Specific:** `signal-ingest` validates HTTP `Authorization: Bearer <token>` headers against OpenBao public keys or shared HMAC secret, rejecting unauthenticated requests with HTTP 401.<br/>**Measurable:** Sub-millisecond (p99 < 1.2ms) token validation overhead under 2,000 req/sec benchmark.<br/>**Attainable:** Uses in-memory caching of validated token signatures with strict TTL eviction.<br/>**Realistic:** Standard Go middleware implementation using standard crypto libraries.<br/>**Time-Bound:** Completed in Milestone 2. | Go benchmark suite and adversarial invalid-token injection tests. |
| **D3: Headless Client Adapter & Credential Persistence** | Update [`agentmaxxing-host-sensor`](file:///home/andy/src/cp/osramp-demo/d2-signalloom/apps/agentmaxxing-host-sensor/) and [`stun-sentinel`](file:///home/andy/src/cp/osramp-demo/d2-signalloom/apps/stun-sentinel/) to persist session credentials in a headless state file (`/var/lib/signalloom/session.json`, `chmod 0600`), buffer telemetry locally across network partitions, and execute proactive sliding refresh at the 4-hour mark of an 8-hour lease. | **Specific:** Host sensor and sentinel persist tokens in a headless `0600` file surviving daemon crashes/reboots, buffer events locally across network partitions of up to 8 hours without discarding evidence, and automatically refresh tokens via `POST /api/v1/auth/refresh` at the 4-hour mark.<br/>**Measurable:** Zero dropped telemetry packets across 24-hour continuous burn test including a simulated 2-hour network partition and daemon restart.<br/>**Attainable:** Extends existing ring buffer in `agentmaxxing-host-sensor` and sentinel Go runtime with local `0600` state persistence and sliding refresh.<br/>**Realistic:** Standard headless production daemon pattern (rejecting complex non-login `keyctl` session keyrings).<br/>**Time-Bound:** Completed in Milestone 3. | End-to-end telemetry streaming verification on live Kind cluster under network partition and daemon restart injection. |
| **D4: Surgical Decommissioning of SPIRE** | Remove SPIRE Server, SPIRE Agent DaemonSet, `spiffe-csi-driver`, and `spire-federation-bridge-relay` manifests and dependencies from the platform. | **Specific:** Delete `d2-signalloom/infra/inf-bao/spire-*` manifests, remove SPIRE CRDs, and eliminate Unix socket volume mounts from agent pod specs.<br/>**Measurable:** 0 running pods in `spire-system`, 0 volume mounts to `/run/spire/sockets`, and cluster RAM reduced by >650MB.<br/>**Attainable:** All identity verification migrated to API token layer.<br/>**Realistic:** Flux Kustomization and manifest deletion.<br/>**Time-Bound:** Completed in Milestone 4. | `kubectl get pods -A` and `make doctor` cluster diagnostics report. |
| **D5: OpenBao Dynamic Token Brokering** | Configure OpenBao to act as the authoritative token mint and revocation registry, enforcing 8-hour session TTLs scoped strictly to `telemetry:write` with instant revocation via token accessor. | **Specific:** OpenBao AppRole or JWT backend issues 8-hour time-bound tokens with least-privilege `telemetry:write` scope, supporting instant global revocation via token accessor and Redis CRL.<br/>**Measurable:** Revoked tokens rejected across all ingress endpoints in under 500ms, while valid tokens provide an 8-hour partition tolerance window.<br/>**Attainable:** Uses existing OpenBao and Redis deployments in `inf-bao` and `inf-signalloom`.<br/>**Realistic:** OpenBao configuration script and Python/Go client bindings.<br/>**Time-Bound:** Completed in Milestone 5. | Security revocation integration tests with simulated compromised token. |

### Out of Scope

*Not included within the project, or targeted for future proposal*

* **Replacing OpenBao**: OpenBao remains the foundational secret broker and policy repository; this proposal only removes the SPIRE attestation plugin.
* **Kernel eBPF Tracepoint Logic**: The core eBPF filters in `stun-sentinel` and Landlock LSM confinement hooks are untouched; only the userspace identity attachment mechanism transitions to Bearer tokens.
* **Human Operator OIDC**: Human login to the web console via Dex (`inf-signalloom/dex`) remains unchanged; this proposal strictly governs machine-to-machine agent and sensor authentication.

---

### KPIs

| Metric | Current Value | Target Value | Measurement |
| :---- | :---- | :---- | :---- |
| **Node DaemonSet Count** | 3 (`spire-agent`, `spiffe-csi-driver`, `stun-sentinel`) | **1** (`stun-sentinel` only) | `kubectl get ds -A` on single-node Kind cluster |
| **Cluster Memory Overhead** | ~680 MB (SPIRE Server, Agents, CSI, Relays) | **0 MB** (SPIRE completely removed) | Node memory allocation via `kubectl top pods -n spire-system` |
| **External Agent Onboarding Time** | > 15 minutes (manual cert sync / SPIRE install) | **< 30 seconds** | Clocked duration of `curl POST /enroll` to active telemetry |
| **Attestation Startup Flakes** | ~4.2% (socket race between pod and CSI driver) | **0.0%** | Zero startup failures across 100 consecutive pod restarts |
| **Privileged Host Mounts** | 2 hostPath mounts (`/run/spire/sockets`, `/var/lib/kubelet`) | **0 hostPath mounts** | Pod Security Admission audit under `restricted` profile |
| **Partition Tolerance Runway** | 0 minutes (immediate token rejection under 300s TTL) | **8 hours** (resilient local buffering & replay) | E2E network disconnect injection test |

---

### 3rd Party Test Plan and Quality Assurance

| Validation | Method | Owner |
| :---- | :---- | :---- |
| **Token Forgery & Replay Resistance** | Automated offensive pytest fuzzing token signatures, alg=none attacks, tampering with `tenant_id` claims, and replaying expired tokens. | Lead Security Engineer (`#vicente-herrera`) |
| **High-Throughput Ingestion Benchmark** | Load-test `signal-ingest` with 5,000 req/sec bearer token validation using `ghz` / `k6` to verify sub-millisecond p99 latency. | Cloud Native Architect (`#stefan-prodan`) |
| **Cross-Tenant Isolation Invariant** | Verification that an agent presented with a token from `tenant-a` cannot submit telemetry or query policies in `tenant-b`. | Testing & QA Lead (`#francesco-beltramini`) |
| **EAP Remote Host Certification** | Live execution of host sensor on remote GCP VM enrolling into the cluster and streaming telemetry over public HTTPS ingress. | Solutions Engineering (`#francesco-beltramini`) |

---

## Technical Overview

#### Technologies

| Technology | Purpose | Alignment |
| :---- | :---- | :---- |
| **HTTP Authorization Bearer Tokens (RFC 6750)** | Standardized token transport across all external and internal API interactions. | Industry standard; universally supported by HTTP/gRPC clients. |
| **JSON Web Tokens (JWT / RFC 7519)** | Signed, tamper-evident payload containing `tenant_id`, `agent_id`, and `exp`. | Native support in FastAPI and Go crypto libraries. |
| **OpenBao AppRole & Token Store** | Authoritative token authority issuing partition-tolerant 8-hour credentials with instant revocation. | Core ControlPlane secret management platform; already deployed in `inf-bao`. |
| **Envoy Gateway (Gateway API)** | Edge TLS termination, client IP allow-listing, and HTTPRoute routing to `/enroll`. | Standard platform ingress gateway; already deployed in `ingress`. |
| **FastAPI (`fe-signalloom`)** | Enrollment token validation and session token generation service. | Primary control plane backend; written in Python. |
| **Go (`signal-ingest`, `stun-sentinel`)** | High-throughput telemetry ingestion and node-level containment. | High-performance compiled systems programming language. |

#### Infrastructure and Repositories

| Asset | Location | Notes |
| :---- | :---- | :---- |
| **Control Plane Repository** | `controlplaneio-in-toto/osramp-demo` | Monorepo hosting all Signal Loom and foundation slices. |
| **Backend API Service** | `d2-signalloom/apps/fe-signalloom/` | Contains `host_enrollment.py` and FastAPI route handlers. |
| **Host Sensor CLI** | `d2-signalloom/apps/agentmaxxing-host-sensor/` | Python procfs/netlink sensor deployed to agent hosts. |
| **Signal Ingest Service** | `d2-signalloom/apps/signal-ingest/` | Go service ingesting telemetry streams into PostgreSQL/Redis. |
| **Ingress Routes** | `d2-signalloom/apps/fe-signalloom/base/gateway-route.yaml` | Envoy Gateway HTTPRoute definitions. |
| **Decommissioned Manifests** | `d2-signalloom/infra/inf-bao/spire-*` | To be deleted in Milestone 4. |

---

#### Security and Risk

### Accepted Risks & Compensating Controls

| Accepted Risk | Architectural Rationale | Compensating Security Controls |
| :--- | :--- | :--- |
| **Bearer Token Exfiltration** | Client-side asymmetric key signing (DPoP / mTLS) introduces excessive client dependencies and operational friction for remote headless VMs. Standard Bearer tokens are accepted as an explicit trade-off for zero-dependency HTTP/gRPC onboarding. | **1. Write-Only Scope**: Tokens are scoped strictly to `telemetry:write` (unable to read audit logs, policies, other agents' data, or secrets).<br/>**2. Sub-Second Global Revocation**: Compromised or decommissioned tokens are pushed to Redis by `fe-signalloom`, terminating ingestion across all gateways in `< 500ms`.<br/>**3. Monotonic Batch Counters**: Rolling SHA-256 hash chains detect out-of-order replay or synthetic event injection.<br/>**4. Ingress Rate Limiting**: Per-token rate limits prevent denial-of-audit event flooding. |
| **Loss of Kernel-Level Socket Attestation** | Eliminating SPIRE removes the ability to attest caller PID/UID via Unix domain sockets. | **Process & Cgroup Isolation**: Workload containment is delegated to cgroup-v2 hierarchies and Landlock LSM filesystem policies, decoupling host containment from API identity. |

---

### Kernel Containment vs API Authentication Architecture (The L7/L3 Decoupling)

A foundational architectural decision in this migration is the total separation between **API authentication** and **in-kernel containment**:

* **API Identity Plane (L7 - Ingress & Ingestion)**:
  External sensors and implants forward telemetry over HTTPS to Envoy Gateway. Envoy terminates TLS 1.3 at the network edge and routes cleartext traffic to `signal-ingest`. `signal-ingest` validates the Bearer token in userspace against OpenBao and the Redis revocation blacklist.
* **Kernel Containment Plane (L3/L4/cgroup - `stun-sentinel`)**:
  `stun-sentinel` enforces node containment strictly through **cgroup-v2 hierarchies** (`/sys/fs/cgroup/.../cgroup.freeze`), netlink socket monitoring, host-side `veth` eBPF TC egress filters, and Landlock LSM. 

**Why kTLS Peeking is Explicitly Rejected:**
While Kernel TLS (kTLS) with eBPF `BPF_PROG_TYPE_SK_MSG` technically allows inspecting unencrypted payloads prior to kernel crypto, it is rejected because:
1. Standard Python (`ssl`/`urllib3`) and Go (`crypto/tls`) HTTP clients do not use kTLS by default, requiring custom native OpenSSL wrappers across diverse client distros.
2. Sentinel does not need to inspect HTTP Authorization headers in kernel space; it only needs to contain processes based on cgroup slices and network endpoints. TLS terminates cleanly at Envoy, completely eliminating any "TLS blindspot" without kernel-level socket decryption overhead.

---

**Threat model for this deliverable (STRIDE Analysis):**

| Threat | Impact | Mitigation |
| :---- | :---- | :---- |
| **Spoofing (Token Forgery)** | Adversary crafts an arbitrary token to impersonate an agent or admin. | Asymmetric cryptographic signing (Ed25519/RS256) where private key is held strictly by OpenBao/backend. Tokens lacking valid cryptographic signatures are rejected immediately. |
| **Tampering (In-Transit Modification)** | Attacker alters claims (e.g. changing `tenant_id`) within a captured token. | Tokens are cryptographically signed; any modification invalidates the signature. Full payload encrypted in transit via mandatory TLS 1.3 enforced by Envoy Gateway. |
| **Repudiation (Event Deniability)** | Compromised agent denies having emitted malicious telemetry or triggering execution. | Ingestion pipeline commits a SHA-256 fingerprint of the bearer token, caller IP, and timestamp alongside every event in PostgreSQL. |
| **Information Disclosure (Token Leakage)** | Bearer token logged in plaintext or leaked via browser/proxy headers. | Server and client logs scrub `Authorization` headers using strict redaction filters. Tokens are held in volatile process memory, never written to disk unencrypted, scoped strictly to write-only `telemetry:write` (unable to read secrets or query other tenants), and backed by sub-second global revocation in Redis. |
| **Denial of Service (Validation Overload)** | Flooding the API with invalid tokens to exhaust cryptographic verification CPU. | Envoy Gateway enforces per-IP rate limits. `signal-ingest` maintains an in-memory LRU cache of recently verified token signatures to avoid redundant crypto operations. |
| **Elevation of Privilege (Cross-Tenant Access)** | Agent from Tenant A accesses or tampers with data belonging to Tenant B. | Tenant ID is cryptographically bound inside the signed token claims. Backend enforces PostgreSQL Row-Level Security (RLS) and FastAPI dependency injection checks on every request. |

**SWOT Analysis:**

| Strengths | Weaknesses |
| :---- | :---- |
| • Eliminates 4 complex DaemonSets and StatefulSets.<br/>• Zero privileged host mounts (no hostPID/hostPath).<br/>• Universally compatible with any external agent/VM.<br/>• Uses standard HTTP Bearer authentication. | • Does not provide hardware TPM/node-level attestation that SPIRE can theoretically provide.<br/>• Requires token refresh loop in long-running agent clients. |
| **Opportunities** | **Threats** |
| • Instant onboarding for Kusari, Claude Code, and Daytona.<br/>• Unlocks deployment on managed Kubernetes (EKS/GKE).<br/>• Drastically lowers Kind cluster resource footprint. | • Token theft from client memory if the host is compromised before token expiry (mitigated by write-only scope and instant revocation via token accessor). |

---

## Milestones and Deliverables

| Milestones Committed To | Duration (days) | Consultants | Person-days | Deadline | Capability Mapping |
| :---- | :---- | :---- | :---- | :---- | :---- |
| **M1: Token Specification & Enrollment Refactor**<br/>Define token claim schema, update `host_enrollment.py` to issue signed bearer tokens, and eliminate SPIRE registration calls from the enrollment route. |  |  |  |  | `#cap-architecture`<br/>`#cap-api-design`<br/>`#cap-python` |
| **M2: Ingestion Middleware & Verification Pipeline**<br/>Implement Bearer token validation middleware in `signal-ingest` and `fe-signalloom`, backed by OpenBao token verification. |  |  |  |  | `#cap-golang`<br/>`#cap-secrets`<br/>`#cap-security-engineering` |
| **M3: Client Adapter & Token Refresh Engine**<br/>Implement memory-backed token storage and automatic refresh loop in `agentmaxxing-host-sensor` and `stun-sentinel`. |  |  |  |  | `#cap-python`<br/>`#cap-golang`<br/>`#cap-linux` |
| **M4: Mid-Project Review**<br/>Demo of progress, evaluation of further milestones, raising of current and new risks. | 0.25 | 2 | 0.5 |  | `#cap-project-management` |
| **M5: SPIRE Decommissioning & Manifest Pruning**<br/>Delete `spire-server`, `spire-agent`, `spiffe-csi-driver`, and bridge relays from cluster overlays and repository manifests. |  |  |  |  | `#cap-kubernetes`<br/>`#cap-gitops`<br/>`#cap-devops` |
| **M6: Adversarial Test Suite & Kusari Certification**<br/>Execute complete Pytest, BATS, and purple-team attack suites verifying zero-trust isolation and remote onboarding. |  |  |  |  | `#cap-testing-pyramid`<br/>`#cap-threat-modelling`<br/>`#cap-purple-team` |
| **Signoff** |  |  |  |  | `#cap-engagement-management` |

**Total Estimated Effort**: *to be estimated with team*

**Definition of Done:**

* `POST /enroll` issues cryptographically valid Bearer tokens without calling SPIRE APIs or generating `spiffe://` URIs.
* `signal-ingest` and `fe-signalloom` validate incoming requests via standard `Authorization: Bearer <token>` headers.
* All SPIRE deployments, daemonsets, and CSI drivers are removed from `kind-osramp` and `kind-signalloom-hub`.
* `make doctor` and `make healthcheck` pass cleanly with zero SPIRE warnings or failed socket mounts.
* Host sensor successfully enrolls from an external machine over HTTPS, buffers telemetry across simulated network partitions, and streams telemetry with continuous 8-hour token leases and proactive 4-hour sliding rotations.
* All existing tenant isolation and adversarial security test suites pass with 100% success rate.

---

### Reviews & Collaboration (RACI)

|  |  |
| :---- | :---- |
| **Accountable** | Lead Security Architect (`#vicente-herrera`) |
| **Responsible** | Platform Engineering Team (`#stefan-prodan`, `#francesco-beltramini`) |
| **Consulted** | Technical Solutions & EAP Lead (`#francesco-beltramini`) |
| **Informed** | [Andrew Martin](mailto:andy@control-plane.io), [Elena Mikhalina](mailto:elena.mikhalina@control-plane.io) |

---

## Finances

### Additional costs

| Additional Cost | Estimated Spend | One Off or Recurring | Must-Have or Nice-to-Have |
| :---- | :---- | :---- | :---- |
| **None (Cost Reduction)** | -£180 / month | Recurring | Must-Have |

*Note: Removing SPIRE DaemonSets and StatefulSets reduces cluster memory consumption by ~680MB per node, enabling smaller cloud VM instance sizes across GCP and AWS environments.*

---

## Decision Log

| Date | Decision Makers | Decision and context | Reason | Impact |
| :---- | :--- | :--- | :--- | :--- |
| **2026-10-02** | AJM, Vicente Herrera | **ADR-01: Eliminate SPIRE from Server and Standardize on API Bearer Tokens** | SPIRE node-socket attestation imposes heavy operational friction, requires privileged DaemonSets, and blocks external agent onboarding (Kusari, developer workstations). | Simplifies architecture, removes 4 microservices, eliminates privileged host mounts, and allows external agent onboarding via HTTPS. |
| **2026-10-02** | AJM, Stefan Prodan | **ADR-02: 8-Hour Session Leases with 4-Hour Proactive Refresh and Instant Revocation** | Aggressive 300s token expiries cause fatal telemetry data loss during network partitions, transit jitter, and control plane maintenance. Observability agents buffer events locally and require partition runway to flush backlogs upon reconnection. | Provides robust 8-hour partition tolerance runway without event drops; security exposure is mitigated by restricting token scope to write-only (`telemetry:write`) and maintaining sub-second revocation in Redis. |
| **2026-10-03** | AJM, Andy Martin | **ADR-03: Headless Production Persistence via 0600 State File (Rejecting keyctl)** | Linux kernel keyring (`keyctl`) sessions are destroyed on headless systemd daemon restarts and behave inconsistently inside container seccomp profiles. | Persist session and refresh tokens in `/var/lib/signalloom/session.json` with strict `chmod 0600` permissions; provides zero-dependency crash resilience across reboots. |
| **2026-10-03** | AJM, Andy Martin | **ADR-04: Explicit Acceptance of Bearer Exfiltration Risk with Scoped Compensating Controls** | Implementing sender-constrained tokens (DPoP / client mTLS) adds unacceptable client-side complexity and dependencies for remote VMs. | Formally accept Bearer exfiltration risk; mitigate via write-only scope (`telemetry:write`), sub-second Redis revocation, and monotonic event hash-chaining. |
| **2026-10-03** | AJM, Andy Martin | **ADR-05: L7/L3 Decoupling — Cgroup-V2 Kernel Containment vs Envoy API Auth (Rejecting kTLS)** | Inspecting encrypted TLS in kernel space via kTLS `sk_msg` programs requires custom userspace crypto bindings and adds extreme datapath complexity. | Envoy terminates TLS at ingress for userspace API validation, while Sentinel enforces containment strictly via cgroup-v2 and host veth filters, removing any TLS blindspot. |

---

## Appendix

### A. Architectural Sequence Diagram: Token Enrollment & Telemetry Streaming

```mermaid
sequenceDiagram
  autonumber
  actor Agent as Remote Agent / Host Sensor
  participant Envoy as Envoy Ingress Gateway
  participant API as fe-signalloom (Control Plane)
  participant Bao as OpenBao (Token Broker)
  participant Ingest as signal-ingest (Telemetry)
  participant DB as PostgreSQL (Evidence Store)

  Note over Agent,Envoy: 1. Initial One-Time Bootstrap
  Agent->>Envoy: POST /enroll (with one-time bootstrap token)
  Envoy->>API: Route to fe-signalloom-api:8000
  API->>API: Atomically validate & invalidate bootstrap token
  API->>Bao: Request scoped session token (tenant_id, agent_id, TTL=8h (28800s))
  Bao-->>API: Return signed bearer token (sl_at_...)
  API-->>Agent: HTTP 200 {agent_id, tenant_id, api_token, expires_in: 28800, refresh_after: 14400}

  Note over Agent,DB: 2. Continuous Telemetry Streaming
  loop Every Interval
    Agent->>Envoy: POST /api/v1/telemetry (Authorization: Bearer sl_at_...)
    Envoy->>Ingest: Forward to signal-ingest:8080
    Ingest->>Ingest: Verify token signature & check in-memory cache
    Ingest->>DB: Commit security event with agent_id & tenant_id
    Ingest-->>Agent: HTTP 202 Accepted
  end

  Note over Agent,Bao: 3. Proactive Sliding Token Rotation (at 4h / 14400s)
  Agent->>Envoy: POST /api/v1/auth/refresh (Authorization: Bearer sl_at_...)
  Envoy->>API: Route to /api/v1/auth/refresh
  API->>Bao: Rotate token & return fresh bearer token
  API-->>Agent: HTTP 200 {api_token: "sl_at_new...", expires_in: 28800, refresh_after: 14400}
```

### B. API Contract Specifications

#### 1. Host Enrollment Endpoint (`POST /enroll`)

* Request Headers:
  * `Content-Type: application/json`
* Request Body:
  ```json
  {
    "enrollment_token": "sl_et_9f83b2a1c0d4...",
    "hostname": "kusari-eap-runner-01",
    "agent_type": "external-sensor",
    "tags": {
      "environment": "eap-kusari",
      "region": "europe-west2"
    }
  }
  ```
* Response Body (`HTTP 200 OK`):
  ```json
  {
    "status": "enrolled",
    "agent_id": "3fa85f64-5717-4562-b3fc-2c963f66afa6",
    "tenant_id": "kusari-corp",
    "api_token": "sl_at_e7a1c4b9d0e2f5...",
    "token_type": "Bearer",
    "expires_in": 28800,
    "refresh_after": 14400,
    "scope": "telemetry:write",
    "ingest_endpoint": "https://gateway.osramp.local/api/v1/telemetry"
  }
  ```

#### 2. Telemetry Streaming Endpoint (`POST /api/v1/telemetry`)

* Request Headers:
  * `Authorization: Bearer sl_at_e7a1c4b9d0e2f5...`
  * `Content-Type: application/json`
* Request Body:
  ```json
  {
    "events": [
      {
        "event_type": "process_exec",
        "timestamp": "2026-10-02T22:45:00.123Z",
        "pid": 4821,
        "comm": "curl",
        "args": ["curl", "https://api.github.com"],
        "confinement_status": "enforced"
      }
    ]
  }
  ```
* Response: `HTTP 202 Accepted`

---
