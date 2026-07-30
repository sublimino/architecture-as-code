---
created: 2026-07-29
updated: 2026-07-29
reviewers:
  - "#stefan-prodan"
  - "#luca-di-maio"
  - "#fabio-caltabiano"
capabilities:
  - "#cap-architecture"
  - "#cap-kubernetes"
  - "#cap-ebpf"
  - "#cap-security-engineering"
  - "#cap-threat-modelling"
  - "#cap-supply-chain-security"
  - "#cap-containers"
  - "#cap-networking"
  - "#cap-observability"
  - "#cap-testing-pyramid"
  - "#cap-gitops"
practice:
  - Cloud Native Security
  - Cloud Native Transformation & DevSecOps
obsidianProject: 1. Projects/2026-07-signalloom-d2-platform-baseline/
parentProposal: "[[Proposal — Signalloom D2 Platform Baseline V2.5 (2026-Q3)]]"
tags:
  - innovation-proposals
  - proposal-2026-q3-sentinel-ebpf-enforcer
aliases:
  - "#proposal-2026-q3-sentinel-ebpf-enforcer"
---
# Proposal — Sentinel: eBPF Runtime Enforcer for Signal Loom (2026-Q3)

|  |  |
| :---: | :---- |
| Proposer & Date: | AJM (2026-07-29) |
| Reviewer & Date: |  |
| Approver & Date: |  |

## Press Release

ControlPlane announces Sentinel: an eBPF-based runtime enforcer for Signal Loom that gives enterprises three unprecedented capabilities over their AI agents -- behavioural monitoring (OBSERVE), instant credential revocation (STUN), and forensic isolation with honeypot deception (FORENSIC). Built on Cilium Tetragon, KubeArmor, and Falco, Sentinel fills the critical gap between detection and response in AI agent security.

Today's agent governance platforms can tell you what an agent did. Sentinel tells you what it is doing and stops it before damage propagates. The OBSERVE/STUN/FORENSIC state machine gives security teams a graduated response chain: watch, contain, then study -- with sub-100ms credential revocation and honeypot deception that keeps compromised workloads producing forensic evidence rather than alerting attackers to their discovery.

## Proposal Overview

### Opportunity

**The work relates to the following value area(s):**

- [x] client revenue
- [ ] marketing
- [x] product
- [x] services engineering
- [ ] cost avoidance
- [x] process efficiency
- [ ] operational or regulatory internal

**Key Customers (if relevant):**

Financial services (JPMC, Morgan Stanley), regulated industries running AI agents at scale. Any enterprise with >50 AI agents that needs provable containment capability.

|  |  |
| :---- | :---- |
| Financial services enterprises running AI agent fleets | Need provable, auditable containment for regulatory compliance (EU AI Act, DORA, NIST 800-53 IR controls). |
| Have the problem/opportunity | Detection without response is a compliance gap. Existing tools (CrowdStrike, Wiz, Aqua) cover pieces but none orchestrate the full OBSERVE to STUN to FORENSIC chain for AI workloads. |
| When | Q4 2026. The AI agent security market is forming now -- first-mover advantage for runtime enforcement. No existing product combines all three capabilities in a single orchestrated chain. |

**What's the urgency of this work (e.g. QX 202X), and does this comprise other subcomponents of projects?**

Q4 2026. The AI agent security market is forming now. CrowdStrike, Wiz, and Aqua each cover fragments of runtime enforcement but none orchestrate the full OBSERVE/STUN/FORENSIC chain. First-mover advantage is real and time-limited: these vendors could build equivalent capability in 6-12 months. Sentinel extends the existing Signal Loom agent governance platform with runtime enforcement -- the natural next capability after identity, policy, and audit.

## Scope Summary

Technology Readiness Level: **1 (Concept -- architecture spike required)**. The objective is a production-grade runtime enforcement system for AI agents, built on proven CNCF eBPF primitives orchestrated through a purpose-built state machine controller.

### In Scope Activities

| Deliverable | Description | Acceptance Criteria (SMART) | Validation Method |
| :---- | :---- | :---- | :---- |
| Sentinel DaemonSet | Per-node eBPF enforcement agent combining Tetragon TracingPolicy and KubeArmor BPF-LSM policies. | Specific: DaemonSet deploys on Kind and EKS, hooks syscall and LSM attach points for AI workloads. Measurable: <1% CPU overhead at steady state, processes >10k events/sec per node. Attainable: Tetragon and KubeArmor are proven at scale. Realistic: Kernel 5.7+ required for BPF-LSM. Time-Bound: M0-M1. | BATS infrastructure tests, load test (10k events/sec), CPU profiling. |
| Orchestration Controller | CRD-driven state machine implementing EnforcementPolicy and ForensicSession custom resources with automatic OBSERVE to STUN to FORENSIC transitions. | Specific: Controller reconciles EnforcementPolicy CRDs and transitions states based on configurable thresholds. Measurable: State transitions complete within 5s of trigger event. Attainable: Standard controller-runtime pattern. Realistic: CRD schema validated against real threat scenarios. Time-Bound: M1-M2. | Integration tests, e2e state-transition tests, controller-runtime envtest. |
| Credential Stun Engine | Revokes ServiceAccount tokens, patches RBAC ClusterRoleBindings, and blocks `/var/run/secrets` reads via eBPF override. | Specific: On STUN trigger, SA token reads are blocked at kernel level and RBAC bindings are patched to deny. Measurable: Token read blocked within <100ms of stun trigger. Attainable: Tetragon LSM Override and Kubernetes API patching are proven primitives. Realistic: Requires BPF-LSM kernel support. Time-Bound: M2. | Unit tests, chaos timing tests (measure stun latency), RBAC verification. |
| Forensic Isolation + Honeypot | NetworkPolicy isolation combined with fake proxy injection that serves plausible API responses to contained workloads. | Specific: Contained workload receives fake API responses mimicking real latency and error profiles. Measurable: All egress captured, no real API calls succeed, fake responses indistinguishable from real within 2 standard deviations of latency distribution. Attainable: Envoy sidecar injection and NetworkPolicy are standard patterns. Realistic: Lambda/serverless honeypot is limited to IAM revocation only. Time-Bound: M3. | Playwright verification, packet capture analysis, latency distribution comparison. |
| Cloud Enforcer Adapter | IAM session revocation for AWS Lambda (concurrency=0), Cloud Run (traffic split to 0%), and ECS (task stop + credential revocation). | Specific: Cloud credentials revoked within 30s across all three providers. Measurable: Revocation timing verified per provider. Attainable: AWS/GCP IAM APIs support session revocation. Realistic: No kernel-level enforcement for serverless -- IAM revocation is the mechanism. Time-Bound: M4. | Provider-specific integration tests, credential verification post-revocation. |
| Signal Loom Dashboard Integration | Enforcement state visualisation, forensic session timeline, and behavioural event stream in the `/enforcement` route. | Specific: Dashboard displays real-time enforcement state, historical forensic sessions, and per-agent behavioural timeline. Measurable: Data refreshes within 5s of state change. Attainable: gRPC event streaming from Tetragon export is the existing pattern. Realistic: Requires existing dashboard API compatibility layer from V2.5. Time-Bound: M5. | Smoke tests, Playwright journey tests. |
| MCP Server | Agents can query their own enforcement status via Model Context Protocol. | Specific: MCP-compliant server exposes enforcement state, policy details, and stun countdown for the requesting agent's own workload identity. Measurable: <50ms query latency. Attainable: MCP protocol is well-specified. Realistic: Read-only -- agents cannot modify their own enforcement state. Time-Bound: M5. | Contract tests, latency benchmarks. |

### Out of Scope

* Production Signal Loom cutover, customer cluster deployment, multi-cluster federation, Windows node support, and non-AI workload enforcement are out of scope.
* Full serverless honeypot (Lambda/Cloud Run) is deferred -- cloud adapter uses IAM revocation only.
* Integration with third-party SIEM/SOAR platforms is deferred to a follow-on proposal.

### KPIs

| Metric | Current Value | Target Value | Measurement |
| :---- | :---- | :---- | :---- |
| Time to credential revocation (STUN) | N/A (manual) | <100ms (kernel), <30s (cloud) | Chaos test timing instrumentation |
| Detection-to-containment chain | No automated chain | OBSERVE to STUN to FORENSIC in <10s | e2e state-transition timing |
| CPU overhead per node | N/A | <1% at steady state | Node CPU profiling under load |
| Event processing throughput | N/A | >10k events/sec per node | Load test with synthetic events |
| Forensic evidence capture rate | N/A | 100% of post-isolation traffic captured | Packet capture completeness audit |
| Honeypot detection rate by attacker | N/A | <5% distinguishable from real | Latency distribution statistical test |

### 3rd Party Test Plan and Quality Assurance

| Validation | Method | Owner |
| :---- | :---- | :---- |
| Unit tests | Go controller logic, CRD validation, state machine transitions, stun engine, cloud adapter. | #cap-testing-pyramid delivery team |
| Infrastructure integration | BATS/DETIK for DaemonSet deployment, Tetragon policy loading, KubeArmor profile application. | #cap-kubernetes delivery team |
| Chaos testing | Stun timing verification, eBPF policy enforcement under load, failover scenarios. | #cap-security-engineering delivery team |
| Browser acceptance | Playwright journeys for enforcement dashboard, forensic timeline, state transitions. | #cap-testing-pyramid delivery team |
| Security testing | Threat model validation, SAST, SCA, secret scan, DAST against MCP server, eBPF policy escape testing. | #cap-threat-modelling security reviewer |
| Supply-chain verification | SBOM, signed images, provenance, digest pinning for DaemonSet and controller images. | #cap-supply-chain-security delivery team |

## Technical Overview

### Architecture

The Sentinel architecture is a three-layer stack:

```
                 ┌──────────────────────────────────────┐
                 │        Signal Loom Dashboard          │
                 │    /enforcement route + MCP server    │
                 └──────────────┬───────────────────────┘
                                │ gRPC event stream
                 ┌──────────────┴───────────────────────┐
                 │     Orchestration Controller          │
                 │  EnforcementPolicy + ForensicSession  │
                 │     OBSERVE → STUN → FORENSIC         │
                 └──────────────┬───────────────────────┘
                                │ CRD reconciliation
          ┌─────────────────────┼─────────────────────────┐
          │                     │                         │
  ┌───────┴───────┐   ┌────────┴────────┐   ┌───────────┴──────────┐
  │   Tetragon    │   │   KubeArmor     │   │    Falco             │
  │ TracingPolicy │   │  BPF-LSM AI     │   │  Detection rules     │
  │ LSM Override  │   │  workload       │   │  175M+ downloads     │
  │               │   │  profiles       │   │                      │
  └───────┬───────┘   └────────┬────────┘   └───────────┬──────────┘
          │                    │                         │
          └────────────────────┴─────────────────────────┘
                               │
                        eBPF (kernel)
```

**State Machine:**

```
OBSERVE ──(threshold breach)──> STUN ──(forensic trigger)──> FORENSIC
   │                              │                              │
   │ behavioural monitoring       │ credential revocation        │ network isolation
   │ syscall tracing              │ SA token blocking            │ honeypot proxy
   │ file access logging          │ RBAC patching                │ traffic capture
   │ network flow capture         │ Envoy JWT revocation         │ fake API responses
   └──────────────────────────────┴──────────────────────────────┘
                              Manual reset only
```

### Competitive Landscape — Stack Ranking

| Rank | Vendor/Product | OBSERVE | STUN | FORENSIC | Orchestration | AI-Agent Aware | Notes |
| :---- | :---- | :---- | :---- | :---- | :---- | :---- | :---- |
| 1 | **Sentinel (this proposal)** | Yes | Yes | Yes | Yes (CRD state machine) | Yes (Signal Loom identity) | Full chain, purpose-built for AI agents |
| 2 | CrowdStrike Falcon | Yes | Partial (kill process) | No | No (manual playbooks) | No | Strong detection, no graduated response, no honeypot |
| 3 | Aqua Security | Yes | Partial (drift prevention) | No | No | No | Container-focused, no credential stun |
| 4 | Wiz Runtime Sensor | Yes | No | No | No | No | Cloud posture, not runtime enforcement |
| 5 | Sysdig Secure | Yes | Partial (kill/pause) | No | No | No | Falco-based detection, limited response |
| 6 | Cilium Tetragon (standalone) | Yes | Yes (LSM Override) | No | No (manual TracingPolicy) | No | Kernel primitive, not orchestrated |
| 7 | KubeArmor (standalone) | Yes | Yes (BPF-LSM) | No | No | No | Policy engine, not orchestrated |

**Key differentiator:** Every competitor provides pieces. None orchestrate the full OBSERVE/STUN/FORENSIC chain with AI-agent-aware identity binding. The orchestration controller is the product -- kernel primitives are commodities.

### Technologies

| Technology | Purpose | Alignment |
| :---- | :---- | :---- |
| Cilium Tetragon | Kernel-level eBPF enforcement (TracingPolicy CRDs, LSM Override for credential blocking) | CNCF graduated, proven at scale, ControlPlane Cilium practice |
| KubeArmor | BPF-LSM with AI workload profiles (process, file, network policy per workload) | CNCF sandbox, complementary to Tetragon for policy model |
| Falco | Detection rule engine (175M+ downloads, syscall + k8s audit event rules) | CNCF graduated, industry-standard detection |
| Go | Orchestration controller, DaemonSet agent, MCP server | ControlPlane primary systems language |
| gRPC | Event streaming (Tetragon export to controller to dashboard) | Existing Tetragon export mechanism |
| Envoy Gateway | Proxy-layer JWT revocation for STUN, honeypot proxy injection for FORENSIC | Existing Signal Loom ingress pattern |
| SPIFFE/SPIRE | Workload identity binding (agent identity to enforcement state) | Existing Signal Loom identity foundation |
| OpenBao | Secure policy and credential storage (enforcement policies, honeypot credentials) | Existing Signal Loom secrets baseline |
| controller-runtime | CRD reconciliation framework for EnforcementPolicy and ForensicSession | Standard Kubernetes controller pattern |

### Infrastructure and Repositories

| Asset | Location | Notes |
| :---- | :---- | :---- |
| Sentinel controller source | `signal-loom/platform/sentinel/` | New -- orchestration controller and CRDs |
| Sentinel DaemonSet | `signal-loom/platform/sentinel/agent/` | New -- per-node eBPF agent configuration |
| D2 demo integration | `osramp-demo` integration worktree | Hosts Flux, Kustomize, tests for local validation |
| Tetragon TracingPolicies | `d2-signalloom/apps/sentinel/policies/` | TracingPolicy and KubeArmor AppProfile CRDs |
| Cloud Enforcer adapters | `signal-loom/platform/sentinel/cloud/` | AWS/GCP IAM revocation adapters |
| Dashboard enforcement route | `signal-loom/platform/dashboard/` | Extension to existing dashboard |
| MCP server | `signal-loom/platform/sentinel/mcp/` | Agent-facing enforcement status API |

### Security and Risk

**Threat model for this deliverable:**

| Threat | Impact | Mitigation |
| :---- | :---- | :---- |
| Compromised agent attempts data exfiltration | Data loss, regulatory breach | OBSERVE detects anomalous network/file access, STUN revokes credentials within 100ms, FORENSIC captures exfiltration intent for incident response |
| Agent escalates privileges via SA token | Cluster compromise | eBPF LSM Override blocks `/var/run/secrets/kubernetes.io/serviceaccount/token` reads, RBAC ClusterRoleBindings patched to deny |
| Attacker discovers forensic isolation | Evasion, loss of forensic evidence | Honeypot mimics real API latency distribution (within 2 standard deviations), error rates, and response schemas; eBPF hides isolation indicators from process introspection |
| Enforcer DaemonSet compromised | Enforcement bypass, false-negative containment | Signed images with cosign, read-only root filesystem, SPIFFE workload identity, admission control (Kyverno/Gatekeeper), minimal RBAC for DaemonSet SA |
| Cloud function credential theft | Cross-service lateral movement | IAM session revocation + concurrency=0 (Lambda) / traffic split to 0% (Cloud Run) / task stop (ECS) within 30s |
| eBPF policy bypass via kernel exploit | Complete enforcement evasion | Kernel version pinning (5.7+), seccomp profiles on agent workloads, node-level integrity monitoring via Tetragon itself |
| State machine race condition | Skipped states, inconsistent enforcement | Controller-runtime leader election, optimistic concurrency on CRD status, idempotent state transitions |

**SWOT:**

| Strengths | Weaknesses |
| :---- | :---- |
| First-to-market with full OBSERVE/STUN/FORENSIC chain for AI agents. | Requires BPF-LSM kernel support (5.7+); excludes older node images. |
| Built on CNCF graduated/sandbox OSS (Tetragon, KubeArmor, Falco). | Cloud honeypot not feasible for Lambda/serverless -- IAM revocation only. |
| Extends existing Signal Loom identity, governance, and audit capabilities. | Complex multi-component deployment (DaemonSet + controller + CRDs + policies). |
| ControlPlane has deep Tetragon/Cilium and KubeArmor practice expertise. | Kernel eBPF API surface evolving rapidly; version-specific policy tuning required. |

| Opportunities | Threats |
| :---- | :---- |
| AI agent security is a new market forming now -- greenfield positioning. | CrowdStrike/Wiz could build equivalent capability in 6-12 months. |
| EU AI Act and DORA demand provable containment -- regulatory tailwind. | Kernel eBPF evolving rapidly; API stability risk across kernel versions. |
| KubeSec-AFM integration for RBAC-aware enforcement and attestation. | Cloud providers (AWS, GCP) may offer native agent containment as platform features. |
| Honeypot deception is a novel differentiator with no direct competitor. | Open-source components could be forked into competing orchestration products. |

## Milestones and Deliverables

| Milestones Committed To | Duration | Consultants | Person-days | Deadline | Capability Mapping |
| :---- | :---- | :---- | :---- | :---- | :---- |
| M0: Architecture spike -- Tetragon TracingPolicy PoC on Kind | 2 weeks |  |  |  | #cap-ebpf, #cap-kubernetes, #cap-architecture |
| M1: OBSERVE -- behavioural monitoring + Falco rules + dashboard event stream | 4 weeks |  |  |  | #cap-ebpf, #cap-security-engineering, #cap-observability |
| M2: STUN -- credential revocation (eBPF LSM Override + K8s API + Envoy JWT) | 3 weeks |  |  |  | #cap-ebpf, #cap-kubernetes, #cap-networking |
| M3: FORENSIC -- network isolation + honeypot proxy injection + traffic capture | 4 weeks |  |  |  | #cap-networking, #cap-threat-modelling, #cap-containers |
| M4: Cloud Enforcer -- AWS Lambda/Cloud Run/ECS IAM revocation adapters | 3 weeks |  |  |  | #cap-architecture, #cap-security-engineering |
| M5: Integration -- Signal Loom dashboard `/enforcement` route + MCP server | 2 weeks |  |  |  | #cap-architecture, #cap-testing-pyramid |
| Mid-project review: demo of OBSERVE+STUN on Kind, evaluation of FORENSIC scope | 0.5 weeks | 2 |  |  | #cap-project-management |
| Signoff: full OBSERVE/STUN/FORENSIC chain evidence, threat model validation, test suite | 1 week |  |  |  | #cap-engagement-management, #cap-documentation |

**Definition of done:**

* Sentinel DaemonSet deploys on Kind and EKS with <1% CPU overhead at steady state.
* EnforcementPolicy CRD transitions OBSERVE to STUN to FORENSIC automatically based on configurable thresholds.
* Credential stun blocks SA token reads within 100ms (measured by chaos test instrumentation).
* Forensic isolation serves fake API responses to contained workload with latency indistinguishable from real (within 2 standard deviations).
* Cloud enforcer revokes credentials across AWS/GCP within 30s.
* Signal Loom dashboard shows real-time enforcement state, forensic session timeline, and per-agent behavioural event stream.
* MCP server exposes enforcement status to agents with <50ms query latency.
* Full test suite passes: BATS (infrastructure), Go unit tests (controller), chaos tests (stun timing), Playwright (dashboard), contract tests (MCP server).
* SAST, SCA, secret scan, SBOM, signed image provenance, and supply-chain verification pass for all new images.
* Threat model validated against the six enumerated threats.

### Reviews & Collaboration (RACI)

|  |  |
| :---- | :---- |
| Accountable | Andy Martin (CEO/CTO) |
| Responsible | ControlPlane Cloud Native Security practice |
| Consulted | Signal Loom platform engineering; KubeSec-AFM team (Luca, Fabio, Mario); Stefan Prodan (Flux/Tetragon) |
| Informed | Elena Mikhalina; Jason Petrucci |

## Finances

### Additional costs

| Additional Cost | Estimated Spend | One Off or Recurring | Must-Have or Nice-to-Have |
| :---- | :---- | :---- | :---- |
| EKS test cluster for kernel-level eBPF validation | TBD | One-off (spike duration) | Must-have (Kind covers most but kernel version pinning needs EKS) |
| AWS Lambda/Cloud Run test accounts | Minimal (free tier) | One-off | Must-have (cloud adapter validation) |
| Falco Pro licence evaluation | TBD | Recurring if adopted | Nice-to-have (open-source Falco sufficient for PoC) |

# Decision Log

| Date | Decision Makers | Decision and context | Reason | Impact |
| :---- | :---- | :---- | :---- | :---- |
| 2026-07-30 | AJM / delivery team | Build on Tetragon + KubeArmor + Falco (not single-vendor). | Each covers a different strength: Tetragon for kernel enforcement, KubeArmor for policy model, Falco for detection rules. | Multi-component deployment but best-of-breed at each layer. |
| 2026-07-30 | AJM / delivery team | Orchestration controller is the product (kernel primitives are commodities). | The gap in the market is the sequencing and AI-agent-aware orchestration, not the individual enforcement capabilities. | Product differentiation is in the orchestrator, not the eBPF primitives. |
| 2026-07-30 | AJM / delivery team | Cloud adapter uses IAM revocation, not eBPF. | Lambda/Cloud Run/ECS do not expose kernel hooks to customers. | Separate code path for serverless; no honeypot capability in cloud functions. |
| 2026-07-30 | AJM / delivery team | Manual reset only from FORENSIC state. | Automatic recovery from forensic isolation risks releasing a still-compromised workload. | Security teams must explicitly clear containment after investigation. |
| 2026-07-30 | AJM / delivery team | MCP server is read-only for agents. | Allowing agents to modify their own enforcement state defeats the purpose. | Agents can observe their status but cannot self-unstun or self-release. |

## Appendix

### A. Enforcement State Machine Detail

```
                    ┌─────────┐
                    │ OBSERVE │ ← default state for all governed agents
                    └────┬────┘
                         │
              threshold breach detected
              (anomalous syscalls, file access,
               network connections, API patterns)
                         │
                    ┌────┴────┐
                    │  STUN   │ ← credentials revoked, agent contained
                    └────┬────┘
                         │
              forensic trigger
              (continued activity post-stun,
               operator request, policy rule)
                         │
                    ┌────┴─────┐
                    │ FORENSIC │ ← network isolated, honeypot active
                    └────┬─────┘
                         │
              manual operator reset only
              (investigation complete,
               workload redeployed)
                         │
                    ┌────┴────┐
                    │ OBSERVE │
                    └─────────┘
```

### B. EnforcementPolicy CRD Example

```yaml
apiVersion: sentinel.signalloom.io/v1alpha1
kind: EnforcementPolicy
metadata:
  name: financial-agent-policy
  namespace: agent-workloads
spec:
  selector:
    matchLabels:
      signalloom.io/agent-class: financial-analyst
  observe:
    tetragontracingPolicy: financial-agent-baseline
    kubeArmorProfile: financial-agent-apparmor
    falcoRules:
      - signalloom-financial-agent
    thresholds:
      anomalousFileAccess: 5
      anomalousNetworkConnections: 10
      privilegeEscalationAttempts: 1
  stun:
    revokeServiceAccountToken: true
    patchRBACBindings: true
    revokeEnvoyJWT: true
    ebpfTokenBlock: true
    maxStunDurationSeconds: 300
  forensic:
    networkIsolation: true
    honeypotProxy:
      enabled: true
      latencyProfile: match-baseline
      errorRate: 0.02
    trafficCapture:
      enabled: true
      storageClass: forensic-evidence
      retentionDays: 90
```

### C. Useful Links

- [[Proposal -- Signalloom D2 Platform Baseline V2.5 (2026-Q3)]]
- [[Proposal -- Signalloom D2 Platform Baseline V2 (2026-Q3)]]
- [Cilium Tetragon -- Runtime Security](https://tetragon.io/)
- [KubeArmor -- Cloud Workload Security](https://kubearmor.io/)
- [Falco -- Cloud Native Runtime Security](https://falco.org/)
- [SPIFFE/SPIRE -- Workload Identity](https://spiffe.io/)
- [Model Context Protocol](https://modelcontextprotocol.io/)
- `signal-loom/platform/sentinel/`
- `osramp-demo/d2-signalloom/`
