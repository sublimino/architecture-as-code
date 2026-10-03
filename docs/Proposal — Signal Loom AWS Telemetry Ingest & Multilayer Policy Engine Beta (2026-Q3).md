---
tags:
  - enhancement-proposals
  - policy-engine
  - aws-ingest
  - signalloom
  - kusari
date: 2026-10-03
status: draft (bootstrap, awaiting sign-off)
author: Signal Loom Architecture Team
parentProposal: "[[Proposal — Signal Loom Unified Telemetry Architecture (2026-Q3)|Signal Loom Unified Telemetry Architecture]]"
updated: 2026-10-03T21:32
---

# Proposal — Signal Loom AWS Telemetry Ingest & Multilayer Policy Engine Beta (2026-Q3)

## Executive Summary

> **Executive Summary:** This proposal outlines the production architecture for pulling real-time AWS CloudTrail, IAM audit, VPC Flow, and S3 telemetry from customer AWS accounts (specifically for the upcoming Kusari pilot deployment), buffering them via a crash-resilient WAL-backed Disk Ring Buffer, and streaming them into the **Signal Loom Multilayer Policy Engine Beta**. The policy engine integrates CEL (Common Expression Language) predicate evaluation with Cedar formal SMT policy verification across 4 distinct telemetry planes (Cloud Control Plane, Endpoint Host, Network Egress, and Behavioural Application).

---

## 1. Problem & Strategic Context

As Signal Loom expands to support external pilot customers such as **Kusari**, security signal collection must span beyond local Kubernetes and eBPF sensors to encompass public cloud infrastructure telemetry. Specifically:
1. **Multi-Account AWS Ingestion:** Kusari operates workloads in isolated AWS accounts. Signal Loom requires a zero-agent, low-latency mechanism to ingest CloudTrail event trails, IAM policy modifications, VPC Flow Logs, and S3 access logs.
2. **Buffer Reliability:** Ingested cloud events must survive ingest node crashes and transient backend outages before commitment to FrostDB or evaluation by the policy engine.
3. **Cross-Plane Policy Enforcement:** Threat actors cross boundaries—e.g., abusing stolen AWS IAM credentials to launch ephemeral EC2 instances, executing unauthorized tool calls via AI agents (KAgent), and egressing data over unexpected network paths. A unified policy engine must correlate actions across **Cloud, Host, Network, and AI Agent** execution contexts.

---

## 2. Telemetry Ingest & Disk Ring Buffer Architecture

### 2.1 AWS Telemetry Collector Design

The AWS Telemetry Collector (`d2-signalloom/apps/signal-ingest/collectors/awslogs/`) implements a dual-worker asynchronous pipeline:

```
┌─────────────────────────┐
│     Customer AWS        │
│ CloudTrail / VPC Flow   │
└────────────┬────────────┘
             │ S3 Object Creation Event
             ▼
┌─────────────────────────┐
│    AWS SQS Notification │
└────────────┬────────────┘
             │ Poll (sts:AssumeRole)
             ▼
┌─────────────────────────────────────────────────────────┐
│ AWSLogCollector (Go)                                   │
│  ├── Worker 1: Poll SQS & Fetch S3 Payload              │
│  └── DiskRingBuffer (WAL-backed Circular Buffer)        │
│       ├── File: telemetry_ring.wal                      │
│       └── In-Memory Index & Drop-Oldest Eviction Policy │
└────────────┬────────────────────────────────────────────┘
             │ Drain Loop
             ▼
┌─────────────────────────┐     ┌─────────────────────────┐
│ Multilayer Policy Engine│ ──► │ FrostDB Columnar Engine │
└─────────────────────────┘     └─────────────────────────┘
```

#### Key Components:
- **Cross-Account Authentication:** Uses AWS Security Token Service (`sts:AssumeRole`) with an external ID (`external_id`) to pull events securely without long-lived access keys.
- **SQS Event Notifications:** S3 bucket notifications deliver log objects to an SQS queue. The collector polls SQS, retrieves log records asynchronously, and commits read markers only after buffer write.
- **Disk Ring Buffer (`DiskRingBuffer`):**
  - **Crash Resilience:** Every record is serialized and written to an append-only WAL (`telemetry_ring.wal`) on disk (`/tmp/signalloom/awslogs_ring`).
  - **Bounded Memory & Drop-Oldest Eviction:** Hard limits on maximum record slots (e.g., 100,000 entries). When full, the oldest unread records are automatically evicted, preventing OOM during high-burst incidents.
  - **Sequence Tracking:** Monotonically increasing sequence IDs track write and read offsets across service restarts.

---

## 3. Multilayer Policy Engine Beta Architecture

The Policy Engine Beta (extends the existing `d2-signalloom/apps/policy-engine/`, never a second engine) evaluates incoming `model.Observation` records across 4 telemetry planes in real time:

```
                                 4-PLANE TELEMETRY INGESTION
                                              │
    ┌──────────────────────┬──────────────────┴───┬──────────────────────┐
    ▼                      ▼                      ▼                      ▼
[Plane 1: Cloud]      [Plane 2: Endpoint]    [Plane 3: Network]    [Plane 4: Application]
AWS CloudTrail / IAM  eBPF Tetragon / Nono   VPC Flow / Envoy      KAgent / Agent Tool Logs
    │                      │                      │                      │
    └──────────────────────┴──────────────────┬───┴──────────────────────┘
                                              │
                                              ▼
                             ┌──────────────────────────────────┐
                             │    CEL Fast Predicate Engine     │  (<10us latency)
                             │  - Rule matching                 │
                             │  - Anomaly pre-filtering         │
                             └────────────────┬─────────────────┘
                                              │ High-risk matches
                                              ▼
                             ┌──────────────────────────────────┐
                             │  Cedar & FAIR SMT Engine         │  (Formal Verification)
                             │  - Entitlement verification      │
                             │  - Risk scoring (0.0 - 1.0)      │
                             └────────────────┬─────────────────┘
                                              │
                                              ▼
                             ┌──────────────────────────────────┐
                             │ Enforcement & Action Dispatcher  │
                             │ - FrostDB Commit                 │
                             │ - Alerting & Revocation Webhooks │
                             └──────────────────────────────────┘
```

### 3.1 Telemetry Planes & Event Mapping

1. **Plane 1: Cloud Control Plane**
   - *Sources:* AWS CloudTrail, IAM Audit Logs, GCP Audit Logs.
   - *Model Layer:* `model.LayerCloudControlPlane`
   - *Policy Target:* IAM role escalations, unauthorized policy versions (`CreatePolicyVersion`), access key generation (`CreateAccessKey`).

2. **Plane 2: Endpoint Host**
   - *Sources:* eBPF Tetragon tracepoints, Nono Landlock sandbox events, Linux auditd.
   - *Model Layer:* `model.LayerEndpointHost`
   - *Policy Target:* Unexpected process spawning (`execve`), privilege escalation, unauthorized binary executions.

3. **Plane 3: Network Egress**
   - *Sources:* AWS VPC Flow Logs, Envoy Gateway access logs, eBPF Socket Filter.
   - *Model Layer:* `model.LayerNetworkEgress`
   - *Policy Target:* Outbound traffic to unapproved IPs/domains, port scans, protocol mismatches.

4. **Plane 4: Behavioural & Application**
   - *Sources:* KAgent tool execution logs, OpenAI/Claude agent tool calls, OpenBao audit trail.
   - *Model Layer:* `model.LayerBehavioural`
   - *Policy Target:* Prompt injection detection, excessive secret retrieval, out-of-bounds agent action sequences.

---

## 4. Policy Evaluation Engine (CEL + Cedar)

### 4.1 Hybrid Policy Pipeline
- **Common Expression Language (CEL):** Used for low-latency, deterministic filter rules executed inline in Go. CEL expressions compile down to ASTs evaluated in $<10\mu s$ per observation.
- **Cedar / FAIR Integration:** Complex authorization checks, multi-attribute access control (ABAC), and formal SMT risk evaluations are deferred to the Cedar evaluation engine, calculating composite risk scores (`0.0` to `1.0`).

### 4.2 Sample Policy Rule (CEL)

```cel
// Rule: Detect IAM privilege escalation by non-admin identity
obs.layer == "cloud_control_plane" &&
obs.source == "aws:cloudtrail" &&
obs.labels["eventName"] in ["CreatePolicyVersion", "AttachUserPolicy", "PutUserPolicy"] &&
!obs.labels["userIdentityArn"].endsWith(":user/admin")
```

---

## 5. Delivery Roadmap & Release Phases

| Phase | Milestone | Scope / Deliverables | Target Date |
| :--- | :--- | :--- | :--- |
| **P0** | **AWS Collector & Ring Buffer** | Scaffold `DiskRingBuffer` and `AWSLogCollector` in `d2-signalloom/apps/signal-ingest/collectors/awslogs/`. Add unit tests. | Scaffold merged (`899d2609`): synthetic poll loop, no SQS/STS, not registered. Real work remains (P1). |
| **P1** | **Kusari SQS Ingestion** | Wire SQS polling and `sts:AssumeRole` authentication for Kusari AWS account. | 2026-10-06 |
| **P2** | **CEL Policy Engine Core** | Extend the existing `policy-engine` `CELEngine` with 4-plane observation variables and rule bundles. | 2026-10-10 |
| **P3** | **Cedar & FAIR Integration** | Integrate Cedar SMT engine for authorization checks and multi-plane correlation. | 2026-10-15 |
| **P4-GOV**| **Live Release & Audit** | Full lifecycle validation, heartbeat monitoring, and automated event reaping. | 2026-10-20 |

---

## 6. Verification & Test Strategy

1. **Go Unit Testing:**
   - Run `go test -v ./...` in `collectors/awslogs` verifying ring buffer push, pop, eviction, and WAL recovery.
2. **Crash Resilience Simulation:**
   - Simulate sudden process SIGKILL during active ring buffer writes and verify 0% data corruption upon restart.
3. **FrostDB Ingestion Benchmarking:**
   - Measure end-to-end throughput from SQS ingest through policy evaluation to FrostDB columnar write ($\ge 10,000\text{ events/sec}$).

---

## 7. Related Proposals & Documentation

- [[Proposal — Signal Loom Unified Telemetry Architecture (2026-Q3)]]
- [[Proposal — Signal Fusion Actor-Resolution Spine (2026-Q3)]]
- [[Proposal — Signal Fusion K8s Audit Collector (2026-Q3)]]
- [[Proposal — Signal Fusion Workspace & M365 Ingest (2026-Q3)]]

---
## Appendix

### Spec: Shared Patterns

#### Mission identity
- Canonical repository: `/home/andy/src/cp/osramp-demo`
- Shortcode: `SLAWS`
- Integration branch: `refs/heads/integration/slaws-v0.1.0`, cut from `feat/signal-loop-and-bootstrap-refactor` at `83b7f6e3` (pushed to origin 2026-10-03).
- Target components: `d2-signalloom/apps/signal-ingest/{collectors/awslogs,collectors/registry.go,model,store,correlation}`, `d2-signalloom/apps/policy-engine/{cel_eval.go,fair,handlers.go}`, `d2-signalloom/apps/dashboard-signalloom/src/pages/WeavePage.tsx`.
- Acceptance commands (offline, every phase): `KUBECONFIG=/dev/null make test-signal-ingest`; `KUBECONFIG=/dev/null make test-signal-ingest-frostdb`; `cd d2-signalloom/apps/policy-engine && go test -count=1 ./...`; `KUBECONFIG=/dev/null make test-sldc-offline`; `bash scripts/check-old-probe-name.sh`; `KUBECONFIG=/dev/null make docs-lint`.
- No work has started on this board. `899d2609` predates it and is the P0 baseline.

#### Architectural constitution
- **One collector, one seam.** `awslogs` is a `collectors.Collector` (`Name/Mode/Start/Stop`) registered through `collectors.NewRegistryFromEnvWithReceiver`, mode-gated by `COLLECTOR_AWSLOGS_MODE=live|fixture|off` exactly like `gcpaudit` and `baoaudit`. It emits `model.Observation` into the shared `collectors.IngestionSink`; it never opens its own HTTP path into signal-ingest.
- **Fixture mode is the test mode.** Recorded CloudTrail, IAM and VPC Flow records live under `collectors/awslogs/testdata/` and drive every unit and e2e test. `live` mode needs `AWS_PROFILE` or `sts:AssumeRole` with an external ID and is never exercised by a card.
- **The ring buffer is a transport buffer, not a second spool.** `DiskRingBuffer` guarantees crash survival between SQS receipt and sink acceptance; durability past the sink is the existing spool / batch-chain contract in `api/batch_chain.go`. Read markers (SQS delete) commit only after `Push` returns.
- **Planes are model layers.** Cloud = `LayerCloudControlPlane` (`source` `aws:cloudtrail`, `aws:iam`), Network = `LayerNetworkEgress` (`aws:vpcflow`), Endpoint = `LayerEndpointHost`, Behavioural = `LayerBehavioural`. Label keys are documented once in `collectors/awslogs/contract_doc.go` (mirroring `workspacesaas/contract_doc.go`) and asserted by a contract test.
- **Policy lives in policy-engine.** Fast predicates are CEL rule bundles registered through `/api/v1/policies/bundles`; risk scoring is `fair/`; nothing new evaluates CEL outside `policy-engine` and `correlation/engine.go`.
- **Inbound credentials are named static keys.** Out-of-process callers of signal-ingest use `Authorization: Bearer <key>` from a `signal-ingest-key-<name>` Secret; the key value never appears in argv, logs, ConfigMaps or git.
- **Tests first, mutation second.** Every card writes its failing test before the change and records at least one mutation that the test kills. Benchmarks use `go test -bench` and record numbers in errata, never as gates.
- **No live AWS, no cost, no egress** from any card. A card that needs an AWS endpoint uses a fake behind the interface.
- **Commit discipline.** Unsigned, scoped conventional commits (`feat(awslogs): …`, `test(policy-engine): …`); never amend after reporting; the lead merges on report.

### Spec: Capability Plan

| Logical ID | Selected skills | Agent role | Size | Ceiling | CPAI agent | Rationale |
| :--- | :--- | :--- | :--- | ---: | :--- | :--- |
| P0 | ajm-auto-kanban; context-mode | Baseline engineer | S | 45m | antigravity | Prove the harness, the integration branch and the six acceptance commands on `83b7f6e3` before any card runs. |
| P1-PRE | ripwire; context-mode | Pre-flight analyst | S | 60m | antigravity | Inventory the `awslogs` scaffold gaps, the registry seam, CLOUDAUDIT's claim on `LayerCloudControlPlane`, and record the layer-scope decision. |
| P1-1 | context-mode; Hardening | Go collector engineer | M | 120m | antigravity | Register `awslogs` with mode gating and a fixture mode; registry lifecycle tests are the existing pattern. |
| P1-2 | context-mode; ThreatModel | Go cloud engineer | M | 150m | antigravity | SQS poll, S3 fetch, `sts:AssumeRole` with external ID behind interfaces with fakes; credential custody via Secret. |
| P1-3 | Hardening; Science | Go reliability engineer | M | 120m | antigravity | WAL recovery under SIGKILL, drop-oldest eviction, sequence continuity; falsifiable crash test. |
| P1-4 | context-mode | Go model engineer | M | 120m | antigravity | CloudTrail/IAM/VPC Flow to `model.Observation` mapping with a contract doc and contract test. |
| P1-GOV | ajm-auto-kanban; Cato | Governor | S | 60m | antigravity | Merge P1, run the acceptance commands twice, reconcile errata, record the layer-scope decision as binding. |
| P2-PRE | ripwire; context-mode | Pre-flight analyst | S | 60m | antigravity | Map `CELEngine`, the bundles API and `correlation/engine.go` so P2 extends rather than forks. |
| P2-1 | context-mode; Hardening | Go policy engineer | M | 150m | antigravity | Four-plane CEL variables and the first rule bundle (IAM escalation, access-key creation, unapproved egress) with `-bench` evidence. |
| P2-2 | context-mode; ThreatModel | Go integration engineer | M | 150m | antigravity | The drain loop evaluates through policy-engine (in-process library or `/api/v1/policies/evaluate` with a named key); fail-closed on evaluator error, recorded. |
| P2-3 | context-mode | Go enforcement engineer | M | 120m | antigravity | Action dispatcher: FrostDB commit of matches, alert webhook with retry, no revocation side effects. |
| P2-GOV | ajm-auto-kanban; Cato | Governor | S | 60m | antigravity | Merge P2, acceptance twice, mutation proof that a disabled rule bundle fails the e2e fixture test. |
| P3-PRE | FirstPrinciples; Research | Decision analyst | S | 90m | antigravity | ADR: cedar-go versus CEL ABAC + FAIR for entitlement checks; measured on the fixture corpus. |
| P3-1 | context-mode; Science | Go risk engineer | M | 120m | antigravity | FAIR 0.0-1.0 scores for cloud-plane matches via the existing `fair/` package; regression fixtures. |
| P3-2 | context-mode | Go policy engineer | M | 150m | antigravity | Entitlement verification per the P3-PRE ADR (Cedar or CEL ABAC); multi-plane correlation rule across cloud + behavioural. |
| P3-GOV | ajm-auto-kanban; Cato | Governor | S | 60m | antigravity | Merge P3, acceptance twice, ADR cited in errata. |
| P4-GOV | ajm-auto-kanban; Interceptor | Governor | S | 90m | antigravity | Final acceptance on `kind-osramp` in fixture mode: Weave shows the cloud plane, e2e fixture suite twice in a row, live tiers of every acceptance command. |

### Spec: Work Decomposition

| Logical ID | Role | Atomic task | Depends on | Exact tests or evidence | Size | Agent | Result / metric | Est. Cost | Tokens | Elapsed | AI URI |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :-------- | :----- | :------ | :--- |
| P0 | baseline | Run every acceptance command on `integration/slaws-v0.1.0` at `83b7f6e3`; record totals; prove the board harness (`kanban-check.sh doctor`). | — | The six acceptance commands, rc 0 each; totals in errata | S | antigravity | — | — | — | — | — |
| P1-PRE | preflight | Inventory `collectors/awslogs` versus the registry seam (`collectors/registry.go`, `main.go:582-600`), list the gaps (no registration, synthetic poll, no SDK), read CLOUDAUDIT's FrostDB `LayerCloudControlPlane` plan, and record the layer-scope decision and label-key contract draft in errata. | P0 | A gap table with file:line; the decision record; no code change | S | antigravity | — | — | — | — | — |
| P1-1 | implementation | Register `awslogs` in `NewRegistryFromEnvWithReceiver` behind `COLLECTOR_AWSLOGS_MODE=live\|fixture\|off`; add fixture mode reading `testdata/*.json`; `off` is the default in every manifest. | P1-PRE | `registry_lifecycle_test.go` cases for awslogs; `go test ./collectors/...`; a mutation that drops the mode gate fails | M | antigravity | — | — | — | — | — |
| P1-2 | implementation | Replace the synthetic poll with `SQSClient`/`S3Fetcher`/`STSAssumer` interfaces, a `live` implementation on `aws-sdk-go-v2` (added to `signal-ingest/go.mod`), fakes for tests, external-ID enforcement, and delete-after-Push semantics. | P1-1 | Unit tests with fakes: poll, fetch, assume-role failure, delete only after Push; no network in tests | M | antigravity | — | — | — | — | — |
| P1-3 | implementation | Harden `DiskRingBuffer`: WAL replay on restart, drop-oldest eviction accounting, monotonic sequence across restart; a crash test that SIGKILLs a child writer mid-batch and asserts zero corruption. | P1-1 | `diskring_test.go` + `diskring_crash_test.go`; `go test -race ./collectors/awslogs/...`; mutation on the eviction branch fails | M | antigravity | — | — | — | — | — |
| P1-4 | implementation | Map CloudTrail, IAM and VPC Flow records to `model.Observation` (`LayerCloudControlPlane`, `LayerNetworkEgress`), `source` values, label keys in `contract_doc.go`, redaction of secrets in payloads. | P1-1 | `contract_test.go` asserting every documented label key; fixture round-trip test; `make test-signal-ingest` | M | antigravity | — | — | — | — | — |
| P1-GOV | governor | Merge P1-1..P1-4 into `integration/slaws-v0.1.0`, run the six acceptance commands twice with identical totals, bind the layer-scope decision, write `### Spec: Shared Patterns — Phase 1`. | P1-2, P1-3, P1-4 | Acceptance commands x2; errata with totals | S | antigravity | — | — | — | — | — |
| P2-PRE | preflight | Read `policy-engine/cel_eval.go`, `handlers.go`, `/api/v1/policies/*`, `fair/`, `pkg/policy` and `correlation/engine.go`; record the extension points, the observation variable schema, and the bundle format for P2. | P1-GOV | Extension-point table with file:line; no code change | S | antigravity | — | — | — | — | — |
| P2-1 | implementation | Extend `CELEngine` with the four-plane observation variables and ship the first rule bundle (IAM escalation, `CreateAccessKey`, unapproved egress); `go test -bench` for per-observation latency. | P2-PRE | `policy_test.go` + `policy_bench_test.go` additions; bundle round-trip through `/api/v1/policies/bundles`; bench numbers in errata | M | antigravity | — | — | — | — | — |
| P2-2 | implementation | The `awslogs` drain loop evaluates each observation through policy-engine (in-process library preferred; else `/api/v1/policies/evaluate` with a `signal-ingest-key-<name>` bearer), fail-closed on evaluator error, with a decision recorded on the observation. | P2-1 | Integration test with a fake evaluator; fail-closed test; no key value in logs (grep test) | M | antigravity | — | — | — | — | — |
| P2-3 | implementation | Action dispatcher: commit matches to FrostDB (`store/`), post an alert webhook with bounded retry, expose counters; no revocation or stun side effects. | P2-2 | FrostDB write test (`-tags frostdb`); webhook retry test with a fake server | M | antigravity | — | — | — | — | — |
| P2-GOV | governor | Merge P2, acceptance twice, mutation proof: disabling the rule bundle makes the fixture e2e red. | P2-3 | Acceptance x2; mutation log | S | antigravity | — | — | — | — | — |
| P3-PRE | preflight | ADR: cedar-go versus CEL ABAC plus FAIR for entitlement verification, measured on the fixture corpus (latency, expressiveness, dependency weight). | P2-GOV | `docs/signalloom/adr/slaws-entitlement.md`; benchmark table | S | antigravity | — | — | — | — | — |
| P3-1 | implementation | FAIR 0.0-1.0 risk scores for cloud-plane matches through `policy-engine/fair/`, with regression fixtures and guard tests. | P3-PRE | `fair/*_test.go` additions; regression fixture; `go test ./fair/...` | M | antigravity | — | — | — | — | — |
| P3-2 | implementation | Entitlement verification per the ADR and one multi-plane correlation rule (cloud `CreateAccessKey` followed by behavioural secret retrieval within 5 min). | P3-PRE, P3-1 | Correlation test on fixtures; ABAC/Cedar test per ADR | M | antigravity | — | — | — | — | — |
| P3-GOV | governor | Merge P3, acceptance twice, ADR cited; `### Spec: Shared Patterns — Phase 3`. | P3-2 | Acceptance x2 | S | antigravity | — | — | — | — | — |
| P4-GOV | governor | Final acceptance on `kind-osramp` in fixture mode: `COLLECTOR_AWSLOGS_MODE=fixture` deployed, Weave renders the cloud plane, the fixture e2e suite passes twice in a row, every acceptance command passes twice. | P3-GOV | Live fixture e2e x2; Interceptor screenshot of Weave cloud plane; acceptance x2 | S | antigravity | — | — | — | — | — |

### Spec: Errata

_No work has started. Cards append `#### Errata — SLAWS-<ID>` blocks here in delivery order._
