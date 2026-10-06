---
tags:
  - enhancement-proposals
  - policy-engine
  - aws-ingest
  - signalloom
  - kusari
date: 2026-10-03
status: v2 signed off 2026-10-06 (Andy); P5 close-out and live validation decomposed, cards on integration/slaws-v0.2.0
author: Signal Loom Architecture Team
parentProposal: "[[Proposal — Signal Loom Unified Telemetry Architecture (2026-Q3)|Signal Loom Unified Telemetry Architecture]]"
updated: 2026-10-06T08:05
---

# Proposal — Signal Loom AWS Telemetry Ingest & Multilayer Policy Engine Beta (2026-Q3)

## Executive Summary

> **Executive Summary:** Signal Loom will ingest CloudTrail, IAM and VPC Flow telemetry from customer AWS accounts (first pilot: Kusari) through a read-only cross-account role, project each record to a fixed label contract, persist it losslessly in FrostDB (Parquet on a persistent volume, DuckDB-readable as a last resort), and evaluate it with a **two-stage CEL policy pipeline** at the shared ingestion sink: stateless predicates per observation produce findings; windowed counters over findings produce decisions. Findings and decisions are stored as observations in the same store, so live evaluation, boot-time warm-up and regression replay over the backlog are one code path. Policy bundles are versioned files reconciled by Flux. The pilot never writes into the customer account; every action is a stored decision, an alert, or a recommendation.

**v2 (2026-10-04)** supersedes v1 after a code review against `integration/slaws-v0.1.0` at `83b7f6e3` and a decision grill. Cedar is removed. The engine extension is restated as new plumbing. Delivery order is inverted: durable store and contract first, evaluator second, live AWS last. §8 records the code findings and §9 the decisions, so cards start from what exists rather than from v1's description.

---

## 1. Problem & Strategic Context

As Signal Loom supports external pilot customers such as **Kusari**, signal collection must extend past local Kubernetes and eBPF sensors to public-cloud control-plane telemetry:

1. **Multi-account AWS ingestion.** Kusari runs workloads in isolated AWS accounts. Signal Loom needs a zero-agent, read-only mechanism to ingest CloudTrail events, IAM changes and VPC Flow Logs.
2. **No loss.** Every ingested cloud event must survive pod restarts and backend outages and remain queryable for regression analysis when a new policy ships.
3. **Cross-layer policy.** Attackers cross boundaries: stolen IAM credentials, agent tool calls (KAgent), unexpected egress. A single policy pipeline must evaluate cloud, host, network, identity, SaaS and behavioural observations with one vocabulary, and must stay responsive: decisions are made against the stream, with historical awareness carried as findings, not as raw-disk queries.

---

## 2. Ingest & Storage Architecture

### 2.1 AWS Telemetry Collector

`d2-signalloom/apps/signal-ingest/collectors/awslogs/` is a `collectors.Collector` registered through `NewRegistryFromEnvWithReceiver`, mode-gated by `COLLECTOR_AWSLOGS_MODE=live|fixture|off` exactly like `gcpaudit` and `baoaudit`. One collector instance per customer account, configured with `{tenant_id, role_arn, external_id, queue_url, region}`.

```
┌──────────────────────────┐
│  Customer AWS account    │   CloudTrail / IAM / VPC Flow → S3 (system of record for raw events)
│  S3 ──► SQS notification │
└────────────┬─────────────┘
             │ sts:AssumeRole (read-only, external ID)
             ▼
┌─────────────────────────────────────────────────────────────┐
│ awslogs collector (one per account, tenant from config)     │
│  poll SQS ─► fetch S3 object ─► project to label contract   │
│  ─► transport buffer (bounded, counted eviction)            │
│  ─► IngestionSink (tenant binder, label allowlist)          │
│  SQS delete only after Store.Append returns                 │
└────────────┬────────────────────────────────────────────────┘
             ▼
┌──────────────────────────┐      ┌────────────────────────────┐
│ FrostDB (Parquet, PVC)   │◄────►│ Policy pipeline (§3)       │
│ raw + findings+decisions │      │ reads stream, writes back   │
└──────────────────────────┘      └────────────────────────────┘
```

- **Read-only trust.** The assumed role grants `s3:GetObject`, `sqs:ReceiveMessage`, `sqs:DeleteMessage` and nothing else. Signal Loom never writes into the customer account.
- **Projection, not payload.** Each record is projected to the label contract in §2.3. `description` is a one-line summary. `raw_evidence_ref` is the S3 object key plus record index; the customer bucket remains the system of record for raw events. In fixture mode the ref points into `collectors/awslogs/testdata/`.
- **Transport buffer.** `DiskRingBuffer` guarantees nothing past the sink. It is bounded, its eviction is a counted metric and a finding, never silent, and its acknowledgement point is after `Store.Append`, so a buffer loss is always replayable from S3.
- **Locally for the EAP** there is no S3. Fixture mode replays recorded records; the Parquet directory on disk is the only durable copy, which is why §2.2 is a P1 deliverable.

### 2.2 Storage

All observations, from every collector and from `POST /api/v1/observations`, land in one `store.SignalStore`. The deployed store becomes `FrostDBStore`:

| Setting | v1 state at `83b7f6e3` | v2 requirement |
| :--- | :--- | :--- |
| `SIGNAL_STORE` | unset, so `MemoryStore` | `frostdb`, binary built with `-tags frostdb` |
| `signal-store` volume | `emptyDir` | PersistentVolumeClaim |
| Segment schema | v2 pseudonymised (HMAC actor columns) | unchanged; cloud events add no raw-identity column |
| Reader of last resort | none | DuckDB over the Parquet directory, documented in a runbook |
| Retention | reaper per tenant | unchanged; findings and decisions follow the same reaper |

### 2.3 Label contract (binding for P1-4 and for every policy rule)

The contract is documented once in `collectors/awslogs/contract_doc.go` and asserted by `contract_test.go`. Keys are additive only.

| Key | CloudTrail | IAM | VPC Flow |
| :--- | :--- | :--- | :--- |
| `tenant_id` | from collector config | same | same |
| `provider` | `aws` | `aws` | `aws` |
| `aws_account_id` | `recipientAccountId` | same | `account-id` |
| `aws_region` | `awsRegion` | same | region of the flow log |
| `event_source` | `eventSource` | `iam.amazonaws.com` | `vpcflow` |
| `event_name` | `eventName` | `eventName` | `ACCEPT` / `REJECT` |
| `error_code` | `errorCode` if present | same | — |
| `resource_type`, `resource_name` | first `resources[]` entry | policy / user / role | ENI id |
| `source_ip` | `sourceIPAddress` | same | `srcaddr` |
| `dst_ip`, `dst_port`, `protocol`, `bytes` | — | — | flow tuple |
| actor | `ActorHint` from `userIdentity.arn`, pseudonymised by the store | same | — |

**Negative contract:** no key or value may carry `sessionToken`, `accessKeyId`, `requestParameters`, `responseElements` or any raw JSON body. A fixture containing a session token is a required test and must never reach `Store.Append` in any column.

---

## 3. Policy Pipeline

Policy evaluates at the shared `collectors.IngestionSink`, so every collector and the HTTP path are covered and nothing bypasses it. Evaluation never blocks the write: **store first, decide second.**

```
 observation ──► Store.Append ──► Stage 1: CEL predicate per observation (stateless)
                                      │ emits Finding{rule_id, bundle_version, tenant, actor, severity}
                                      ▼
                                  Store.Append(finding as observation, source=policy_finding)
                                      │
                                      ▼
                                  Stage 2: windowed counters over findings (in-memory per tenant)
                                      │ "3 × rule X for actor A in 10 min" ─► Decision
                                      ▼
                                  Store.Append(decision as observation) ─► alert webhook ─► Weave
```

- **Stage 1** is cheap and touches no disk. A single network anomaly is a finding, not an incident.
- **Stage 2** reads findings only, never raw observations: the problem space shrinks at each stage. Windows are declared per rule; the longest declared window bounds boot-time warm-up, which is a `QueryRange` over `source == "policy_finding"`.
- **Disk on the hot path is forbidden by default.** A rule may name an enrichment query explicitly; replay and warm-up are the only other readers.
- **Multi-layer correlation** lives in stage 2: a cloud finding and a behavioural finding share the pseudonymised actor key. `correlation/engine.go` becomes a consumer of findings rather than a pairwise evaluator over stored observations.
- **Staged enforcement.** Every bundle runs shadow → warn → enforce. Enforce means the decision is stored and alerted and the observation is labelled `policy_decision`; nothing is dropped and nothing in the customer account is touched.

### 3.1 Layers

The model defines seven layers (`model/signal.go:16-24`). The proposal addresses six; `protocol` stays out of scope. The stale `// out of scope` comment on `LayerCloudControlPlane` is deleted in P1; the constant is already in `InScopeLayers()`.

| Layer | Sources | First rule targets |
| :--- | :--- | :--- |
| `cloud_control_plane` | AWS CloudTrail, IAM; GCP audit (existing) | `CreatePolicyVersion`, `AttachUserPolicy`, `CreateAccessKey` by non-break-glass identities |
| `network_egress` | VPC Flow, Envoy access logs, eBPF socket filter | REJECT bursts, egress to unapproved CIDRs |
| `endpoint_host` | Tetragon, nono, auditd | unexpected `execve`, privilege escalation |
| `identity_authorization` | OpenBao audit, SPIRE | secret retrieval bursts |
| `application_saas` | Workspace, M365 | existing SFDP rules |
| `behavioural` | KAgent, agent tool calls | out-of-bounds action sequences |

---

## 4. Policy Language and Engine

**CEL only. Cedar is removed.** Cedar answers "may principal P do action A on resource R" against an entity store; nothing here asks permission. The need is predicates over an event stream with time windows, which CEL already does in three places in this repo (policy-engine, correlation, the VAP compiler in `pkg/policy`). Entitlement checks ("was this ARN allowed to `CreateAccessKey`") are a CEL rule over `obs.labels` plus an allowlist variable. FAIR scoring stays for decisions. P3-PRE becomes a one-page ADR recording this.

### 4.1 Observation vocabulary

A new shared package `d2-signalloom/pkg/obscel` owns one CEL environment exporting `obs` as a typed map: `id, timestamp, layer, source, fidelity, confidence, tenant_id, actor (pseudonym), labels (map<string,string>)`, plus `window` helpers for stage 2. Both engines use it; a conformance test compiles every shipped rule against it. Missing-key semantics are `has(obs.labels.k)` with absent keys evaluating false, never erroring, so an unlabelled record cannot become a denial by accident.

### 4.2 Sample rules

```cel
// Stage 1: IAM privilege change by a non-break-glass identity
obs.layer == "cloud_control_plane" &&
obs.labels.event_source == "iam.amazonaws.com" &&
obs.labels.event_name in ["CreatePolicyVersion", "AttachUserPolicy", "PutUserPolicy", "CreateAccessKey"] &&
!(obs.actor in bundle.vars.break_glass_actors)
```

```yaml
# Stage 2: declared in the bundle, not in CEL
- id: iam-change-burst
  over: finding.rule_id == "iam-priv-change"
  key: [tenant_id, actor]
  window: 10m
  threshold: 3
  severity: high
```

### 4.3 Engine changes (new plumbing, not configuration)

`policy-engine` today evaluates `{agent, request, manifest, object}` (`cel_eval.go:25-30`), knows nothing of `Observation`, keeps bundles in two in-memory maps, and has no authentication. v2 adds: an `obs` input via `pkg/obscel`; a `PolicyEvaluator` interface used in-process by signal-ingest through the existing `replace` directive; bundle loading from files at boot (§4.4); key-based auth on the HTTP API, which is retained for dry-run and shadow evaluation from the dashboard only.

### 4.4 Bundle governance

Bundles are versioned files under `policy/bundles/<tenant>/<name>.yaml`, Flux-reconciled into a ConfigMap and loaded at boot the way frameworks are. Version monotonicity is checked in CI. Every rule change is a reviewed commit. `POST /api/v1/policies/bundles` registers a dry-run bundle only and never persists.

---

## 5. Delivery Roadmap

| Phase | Milestone | Scope | Target |
| :--- | :--- | :--- | :--- |
| **P0** | Baseline | Six acceptance commands on `f906be8f`; the `awslogs` scaffold (`899d2609`) is recorded as a stub: synthetic poll, `Pop` fabricates records, no WAL read, no fsync, `ModeLive` hardcoded, unregistered. | done, see §8 |
| **P1** | Durable store and contract | FrostDB on a PVC in the manifests; seven-layer flip; label contract with the negative test; shared tenant binder on both ingest paths; collector registered in fixture mode. | 2026-10-08 |
| **P2** | Two-stage evaluator | `pkg/obscel`; stage 1 at the sink; findings as observations; stage 2 windows with boot warm-up; first Kusari bundle in git; regression replay command; shadow → warn → enforce. | 2026-10-14 |
| **P3** | Live AWS collector | SQS, S3, `sts:AssumeRole` behind interfaces with fakes; delete-after-Append; eviction metrics; read-only trust document for Kusari. | 2026-10-17 |
| **P4-GOV** | Release and audit | Fixture e2e on `kind-osramp` twice; Weave shows cloud layer and findings; DuckDB runbook executed against the PVC. | 2026-10-21 |
| **P5** | v2 close-out and live validation | Live AWS lab behind IaC and an operator profile; multi-account from env plus DLQ/redrive; GuardDuty via EventBridge; pseudonym-consistent dry-run and correlator review; CI parity and `-race` evidence attached. | 2026-10-10 |

---

## 6. Verification & Test Strategy

1. **Offline acceptance, every phase:** the six commands in the constitution, run twice with identical totals.
2. **Contract:** `contract_test.go` asserts every documented key for every fixture and asserts the negative contract (no token, no raw body, in any column).
3. **Durability:** SIGKILL the pod between `Store.Append` and SQS delete in a fake; assert the record is present exactly once after restart and the SQS message is re-delivered and deduplicated.
4. **Evaluation:** fixture corpus drives stage 1 and stage 2; a mutation that disables the bundle turns the e2e red; replay over the corpus equals live results byte-for-byte.
5. **Warm-up:** restart with findings on disk; stage 2 reproduces the same decision on the next matching finding.
6. **Benchmarks:** `go test -bench` for stage 1 per-observation latency, recorded in errata, never a gate.

---

## 7. Related Proposals & Documentation

- [[Proposal — Signal Loom Unified Telemetry Architecture (2026-Q3)]]
- [[Proposal — Signal Fusion Actor-Resolution Spine (2026-Q3)]]
- [[Proposal — Signal Fusion K8s Audit Collector (2026-Q3)]]
- [[Proposal — Signal Fusion Workspace & M365 Ingest (2026-Q3)]]

---

## 8. Code Reality at `83b7f6e3` (review of 2026-10-03)

Findings that v1 contradicted, with locations, so cards start from the code:

- `policy-engine/cel_eval.go:25-30` declares `agent, request, object, manifest` only. There is no `obs`. `Labels` is not projected into CEL in either engine (`correlation/engine.go:126`). The v1 sample rule compiles nowhere.
- `policy-engine` does not import `signal-ingest/model`; signal-ingest never calls `policy-engine`. The only coupling is a Go import of `policy-engine/fair` via `signal-ingest/go.mod:83`.
- Bundle store is two in-memory maps (`store.go:20-34`), no auth, tenant from a caller-asserted `X-Tenant-ID` (`handlers.go:22-28`). Routes `/api/v1/policies/{evaluate,bundles,rollback}` exist (`main.go:220-222`).
- `fair/` is Monte Carlo over beta-PERT triples keyed to framework checks; it has no Observation input.
- `pkg/policy` is the ValidatingAdmissionPolicy and nono/Landlock invariant compiler, imported only by `cmd/policy-compiler`. It is not an event engine.
- `awslogs`: `Pop` fabricates constant records and never reads the WAL (`diskring.go:163-168`); no `Sync()`; no replay on restart; unbounded file growth; `Mode()` returns `ModeLive` (`collector.go:72-74`); `Stop() error` does not satisfy `collectors.Stopper`; not registered; no AWS SDK in `go.mod`; raw payload written to `description` (`collector.go:142`).
- `LayerCloudControlPlane` is in `InScopeLayers()` (`signal.go:47`) with a stale `// out of scope` comment (`:22`); `api/handlers.go:808` still reports the layer as not deployed; `store/` has no per-layer schema. No CLOUDAUDIT artefact exists beyond receipt JSON at the repo root.
- `api/batch_chain.go` is in-memory gap and replay classification, not a spool. No spool exists.
- Base deployment sets `SIGNAL_STORE_DIR=/data/signals` but not `SIGNAL_STORE=frostdb`; the volume is `emptyDir` (`base/deployment.yaml:83,152`). The deployed store is `MemoryStore`.
- Admission on the HTTP path is real (tenant binding `api/tenancy_grants.go:179-204`, `Validate()`, store-side label allowlist under `frostdb` tag). The in-process `StoreSink` path has no tenant binder.
- `workspacesaas/contract_doc.go` documents layer/actor/timestamp obligations against CEL rules, not label keys.

## 9. Decisions (grill of 2026-10-04)

| # | Decision |
| :--- | :--- |
| D1 | No loss for any source. FrostDB on the hot path, Parquet on a PVC, DuckDB as last-resort reader, backlog regression queries required. |
| D2 | Streaming-first evaluation. Stage 1 stateless predicate per observation emits findings; stage 2 windowed counters over findings only. Disk is for warm-up, named enrichment and replay. |
| D3 | Findings and decisions are observations in the same store (`source=policy_finding`, `policy_decision`). Stage 2 windows in memory per tenant, rebuilt on boot for the longest declared window. |
| D4 | Projected label set only on disk; one-line `description`; `raw_evidence_ref` to the S3 object in the customer bucket. Negative contract enforced by test. |
| D5 | Read-only assumed role. Actions: stored decision, alert webhook with bounded retry, Weave finding. Revocation is a recommendation payload. |
| D6 | Bundles are Flux-reconciled files under `policy/bundles/<tenant>/`, loaded at boot. API registration is dry-run only and gains key auth. |
| D7 | Tenant from collector config, one `awslogs` instance per account, one binder shared by HTTP and in-process paths. |
| D8 | Order: durable store and contract first, evaluator second, live AWS third. |
| D9 | CEL only; Cedar removed. P3-PRE records the ADR. |
| D10 | v2 is signed off (2026-10-06). ISC-31 (eviction timestamp is the buffered record\x27s receipt time) and ISC-26 (label values are free text within a closed key set) are accepted as designed. The two named flaky tests are fixed, not tolerated: key-reload watcher baseline (`75448e38`), tombstone entropy fields (`d48ab659`). |
| D11 | Multi-account from env: `COLLECTOR_AWSLOGS_ACCOUNTS` is a JSON list of `{account_id, role_arn, external_id, queue_url, tenant_id}`; the registry builds one `awslogs` instance per entry (D7 unchanged: one instance per account, tenant from collector config). An invalid entry refuses boot; the single-account env keys remain as the one-entry form. |
| D12 | Dead-letter: the lab IaC attaches an SQS redrive policy (`maxReceiveCount` 5) to the notification queue; a poisoned body is counted `discarded` and left to the DLQ; `signal-ingest awslogs redrive` replays the DLQ through the same projection, deduped by the derived `Observation.ID`. |
| D13 | Live validation never changes D5: no manifest in this repository selects live mode. The lab is `scripts/slaws-live-lab.sh` over Terraform under `infra/aws/slaws-lab/`, run by an operator with an AWS profile; a card without credentials stops and reports the exact command rather than fabricating a run. |

---
## Appendix

### Spec: Shared Patterns

#### Mission identity
- Canonical repository: `/home/andy/src/cp/osramp-demo`
- Shortcode: `SLAWS`
- Integration branch: `refs/heads/integration/slaws-v0.1.0`, cut from `feat/signal-loop-and-bootstrap-refactor`, advanced to `f906be8f` on 2026-10-04 (the §8 code review was taken at `83b7f6e3`; P0 re-confirms each finding at the new tip).
- Target components: `d2-signalloom/apps/signal-ingest/{collectors/awslogs,collectors/registry.go,collectors/sink.go,model,store,correlation}`, `d2-signalloom/apps/policy-engine/{cel_eval.go,store.go,handlers.go,fair}`, new `d2-signalloom/pkg/obscel`, `policy/bundles/`, `d2-signalloom/apps/dashboard-signalloom/src/pages/WeavePage.tsx`.
- Acceptance commands (offline, every phase): `KUBECONFIG=/dev/null make test-signal-ingest`; `KUBECONFIG=/dev/null make test-signal-ingest-frostdb`; `cd d2-signalloom/apps/policy-engine && go test -count=1 ./...`; `KUBECONFIG=/dev/null make test-sldc-offline`; `bash scripts/check-old-probe-name.sh`; `KUBECONFIG=/dev/null make docs-lint`.
- No work has started on this board. `899d2609` predates it and is a stub (§8), not a baseline.

#### Architectural constitution
- **One collector, one seam.** `awslogs` is a `collectors.Collector` (`Name/Mode/Start/Stop()`) registered through `NewRegistryFromEnvWithReceiver`, mode-gated by `COLLECTOR_AWSLOGS_MODE=live|fixture|off`, `off` by default in every manifest. One instance per customer account; tenant comes from its config.
- **Store first, decide second.** Policy evaluates at `IngestionSink` after `Store.Append`. No evaluation blocks a write. No evaluator reads raw observations from disk on the hot path.
- **Findings are observations.** Stage 1 output is written back with `source=policy_finding`; stage 2 output with `source=policy_decision`. One store, one schema, one retention reaper, one replay path.
- **Fixture mode is the test mode.** Recorded CloudTrail, IAM and VPC Flow records live under `collectors/awslogs/testdata/` and drive every test. `live` is never exercised by a card.
- **The buffer is transport.** `DiskRingBuffer` guarantees nothing past the sink. Eviction is counted and emitted as a finding. SQS delete happens after `Store.Append` returns.
- **Projection only.** The label contract (§2.3) is the only shape a cloud record takes on disk. The negative contract is a test.
- **One tenant binder.** The HTTP binder in `api/tenancy_grants.go` and the in-process sink wrapper call the same function.
- **One CEL vocabulary.** `pkg/obscel` is the only CEL environment for observations. Every shipped rule compiles against it in CI.
- **Policy is git.** Bundles are files under `policy/bundles/<tenant>/`, Flux-reconciled, loaded at boot. The API registers dry-run bundles only.
- **Read-only in the customer account.** The assumed role has three permissions and no write path exists in any card.
- **Tests first, mutation second.** Every card writes its failing test before the change and records at least one mutation the test kills. Benchmarks are recorded, never gates.
- **No live AWS, no cost, no egress** from any card. AWS endpoints are fakes behind interfaces.
- **Commit discipline.** Unsigned, scoped conventional commits (`feat(awslogs): …`, `test(policy-engine): …`); never amend after reporting; the lead merges on report.

### Spec: Capability Plan

| Logical ID | Selected skills | Agent role | Size | Ceiling | CPAI agent | Rationale |
| :--- | :--- | :--- | :--- | ---: | :--- | :--- |
| P0 | ajm-auto-kanban; context-mode | Baseline engineer | S | 45m | antigravity | Prove harness, branch and the six acceptance commands on `f906be8f`; confirm §8 still holds at the new tip. |
| P1-PRE | ripwire; context-mode | Pre-flight analyst | S | 60m | antigravity | Map the sink, the HTTP tenant binder, the FrostDB factory and manifests; file:line table for P1. |
| P1-1 | context-mode; Hardening | Go platform engineer | M | 120m | antigravity | `SIGNAL_STORE=frostdb`, `-tags frostdb` build, PVC in manifests, DuckDB runbook; seven-layer flip. |
| P1-2 | context-mode; Hardening | Go collector engineer | M | 120m | antigravity | Register `awslogs` with mode gating, fixture mode, `Stopper` fix, per-account config with tenant. |
| P1-3 | context-mode; ThreatModel | Go model engineer | M | 150m | antigravity | Label contract, projection, negative contract test, `raw_evidence_ref`, `contract_doc.go`. |
| P1-4 | Hardening; Science | Go reliability engineer | M | 120m | antigravity | Shared tenant binder on `StoreSink`; transport buffer bounded with counted eviction; ack-after-Append. |
| P1-GOV | ajm-auto-kanban; Cato | Governor | S | 60m | antigravity | Merge P1, acceptance twice, errata, Phase 1 patterns. |
| P2-PRE | ripwire; context-mode | Pre-flight analyst | S | 60m | antigravity | Extension points in `cel_eval.go`, `store.go`, `correlation/engine.go`; design `pkg/obscel`. |
| P2-1 | context-mode; Hardening | Go policy engineer | M | 150m | antigravity | `pkg/obscel` with conformance test; `PolicyEvaluator` interface; stage 1 at the sink; findings written back. |
| P2-2 | context-mode; Science | Go policy engineer | M | 150m | antigravity | Stage 2 windows, boot warm-up, first Kusari bundle under `policy/bundles/kusari/`, shadow → warn → enforce. |
| P2-3 | context-mode; ThreatModel | Go enforcement engineer | M | 120m | antigravity | Decision as observation, alert webhook with bounded retry, counters, regression replay command. |
| P2-GOV | ajm-auto-kanban; Cato | Governor | S | 60m | antigravity | Merge P2, acceptance twice, mutation proof: disabled bundle turns the e2e red; replay equals live. |
| P3-PRE | FirstPrinciples | Decision analyst | S | 45m | antigravity | ADR `docs/signalloom/adr/slaws-policy-language.md`: CEL only, Cedar rejected, with the reasoning in §4. |
| P3-1 | context-mode; ThreatModel | Go cloud engineer | M | 150m | antigravity | `SQSClient`/`S3Fetcher`/`STSAssumer` interfaces, `aws-sdk-go-v2` live impl, fakes, external-ID enforcement, delete-after-Append. |
| P3-2 | Hardening; Science | Go reliability engineer | M | 120m | antigravity | SIGKILL durability test, exactly-once after restart, eviction finding, bundle auth on the API. |
| P3-GOV | ajm-auto-kanban; Cato | Governor | S | 60m | antigravity | Merge P3, acceptance twice, ADR cited, trust document template in docs. |
| P4-GOV | ajm-auto-kanban; Interceptor | Governor | S | 90m | antigravity | Fixture e2e on `kind-osramp` twice; Weave shows cloud layer and findings; DuckDB runbook executed. |
| P5-PRE | ripwire; context-mode | Pre-flight analyst | S | 60m | antigravity | Baseline the seven acceptance commands and CI parity on `integration/slaws-v0.2.0`; attach the `-race` evidence; file:line map of the live seams, account config, GuardDuty gap and dry-run actor path. |
| P5-1 | context-mode; ThreatModel; Hardening | Go cloud engineer | M | 150m | antigravity | Live AWS lab: Terraform for the read-only role, bucket, queue; `scripts/slaws-live-lab.sh` drives live mode end to end; refuses without credentials. |
| P5-2 | context-mode; Hardening | Go collector engineer | M | 150m | antigravity | `COLLECTOR_AWSLOGS_ACCOUNTS` fan-out, DLQ redrive policy in IaC, `awslogs redrive` command with derived-ID dedupe. |
| P5-3 | context-mode; ThreatModel | Go model engineer | M | 120m | antigravity | GuardDuty EventBridge envelope projected to Â§2.3 under `aws:guardduty`; fixture, contract rows, one bundle rule, replay equals live. |
| P5-4 | context-mode; Science | Go policy engineer | M | 120m | antigravity | Dry-run evaluates on pseudonymised actors like live; `actor_account_id` bounded or dropped; review idempotency and read-key proof made non-vacuous. |
| P5-GOV | ajm-auto-kanban; Interceptor; Cato | Governor | S | 90m | antigravity | Merge P5 in order; acceptance twice plus parity; Weave evidence; Phase 5 patterns; close v2.1. |

### Spec: Work Decomposition

| Logical ID | Role | Atomic task | Depends on | Exact tests or evidence | Size | Agent | Result / metric | Est. Cost | Tokens | Elapsed | AI URI |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :-------- | :----- | :------ | :--- |
| P0 | baseline | Run the six acceptance commands on `integration/slaws-v0.1.0` at `f906be8f`; record totals; `kanban-check.sh doctor`; confirm each §8 finding with file:line. | — | Six commands rc 0; totals and §8 confirmation in errata | S | antigravity | — | — | — | — | — |
| P1-PRE | preflight | Table of the sink (`collectors/sink.go`), HTTP tenant binder (`api/tenancy_grants.go`), store factory, manifests; name the exact edits for P1-1..P1-4. | P0 | File:line table; no code change | S | antigravity | — | — | — | — | — |
| P1-1 | implementation | `SIGNAL_STORE=frostdb` and PVC in `base/deployment.yaml`; `-tags frostdb` in the image build; delete the stale comment on `LayerCloudControlPlane`; fix `api/handlers.go:808`; DuckDB runbook under `docs/signalloom/`. | P1-PRE | `make test-signal-ingest-frostdb`; deploy render test asserts PVC; runbook executed once against a local Parquet dir | M | antigravity | — | — | — | — | — |
| P1-2 | implementation | Register `awslogs` in `NewRegistryFromEnvWithReceiver` behind `COLLECTOR_AWSLOGS_MODE`; fixture mode reads `testdata/*.json`; `Stop()` satisfies `Stopper`; `AWSCollectorConfig` carries `tenant_id`. | P1-PRE | `registry_lifecycle_test.go` and `mode_matrix_test.go` rows for awslogs; mutation dropping the mode gate fails | M | antigravity | — | — | — | — | — |
| P1-3 | implementation | Project CloudTrail, IAM and VPC Flow to `model.Observation` per §2.3; one-line `description`; `raw_evidence_ref`; `contract_doc.go`; negative contract. | P1-2 | `contract_test.go` asserts every key and the negative contract against a fixture with a session token; `make test-signal-ingest` | M | antigravity | — | — | — | — | — |
| P1-4 | implementation | Extract the HTTP tenant binder into a function used by a `StoreSink` wrapper; bound `DiskRingBuffer`, count eviction, emit it as a finding; move SQS ack to after `Store.Append`. | P1-2 | Binder test on both paths; eviction counter test; `go test -race ./collectors/...` | M | antigravity | — | — | — | — | — |
| P1-GOV | governor | Merge P1-1..P1-4; acceptance twice with identical totals; `### Spec: Shared Patterns — Phase 1`. | P1-3, P1-4 | Acceptance x2; errata | S | antigravity | — | — | — | — | — |
| P2-PRE | preflight | Read `cel_eval.go`, `store.go:371-440`, `correlation/engine.go:109-126`; design `pkg/obscel` (env, `obs` map, `has` semantics, conformance test); record extension points. | P1-GOV | Design note with file:line; no code change | S | antigravity | — | — | — | — | — |
| P2-1 | implementation | `pkg/obscel`; `PolicyEvaluator` interface in policy-engine using it; stage 1 at the sink after `Store.Append`; findings written back with `source=policy_finding`. | P2-PRE | Conformance test compiles every rule; sink test shows finding stored; `-bench` per observation in errata | M | antigravity | — | — | — | — | — |
| P2-2 | implementation | Stage 2 windows keyed by tenant+actor+rule with declared window and threshold; boot warm-up from `QueryRange`; first bundle at `policy/bundles/kusari/iam-change.yaml`; shadow → warn → enforce mode in bundle metadata. | P2-1 | Window test; restart warm-up test; bundle loaded at boot test; mode transition test | M | antigravity | — | — | — | — | — |
| P2-3 | implementation | Decision written as observation; alert webhook with bounded retry; counters; `signal-ingest replay --bundle --from --to` command producing identical findings to live. | P2-2 | Webhook retry test with fake server; replay equals live on the corpus | M | antigravity | — | — | — | — | — |
| P2-GOV | governor | Merge P2; acceptance twice; mutation proof: disabled bundle turns the fixture e2e red; replay-equals-live recorded. | P2-3 | Acceptance x2; mutation log | S | antigravity | — | — | — | — | — |
| P3-PRE | preflight | ADR: CEL only, Cedar rejected (authorisation language, entity store, second schema), FAIR retained for decisions. | P2-GOV | `docs/signalloom/adr/slaws-policy-language.md` | S | antigravity | — | — | — | — | — |
| P3-1 | implementation | `SQSClient`/`S3Fetcher`/`STSAssumer` interfaces; `aws-sdk-go-v2` live implementation; fakes; external-ID enforcement; delete-after-Append. | P1-GOV | Unit tests with fakes: poll, fetch, assume-role failure, delete only after Append; no network in tests | M | antigravity | — | — | — | — | — |
| P3-2 | implementation | SIGKILL durability test between Append and delete; exactly-once after restart; key-based auth on `/api/v1/policies/*`; dry-run-only semantics on bundle registration. | P3-1, P2-GOV | Crash test; auth test; registration never persists test | M | antigravity | — | — | — | — | — |
| P3-GOV | governor | Merge P3; acceptance twice; ADR cited; read-only trust document template committed. | P3-2 | Acceptance x2 | S | antigravity | — | — | — | — | — |
| P4-GOV | governor | `COLLECTOR_AWSLOGS_MODE=fixture` on `kind-osramp`; Weave shows cloud layer and findings; fixture e2e twice; DuckDB runbook executed against the PVC. | P3-GOV | Fixture e2e x2; Interceptor screenshot; runbook output | S | antigravity | — | — | — | — | — |
| P5-PRE | preflight | On `integration/slaws-v0.2.0`: run the seven acceptance commands and `scripts/check-ci-build-parity.sh`; attach the `go test -race` evidence (golang:1.27 container, zero `DATA RACE` lines, kubectl-dependent manifest tests named) to errata; table with file:line of the live seams (`collectors/awslogs/live*.go`), the account and queue config surface, the GuardDuty/EventBridge fixture gap, and the policy-engine dry-run actor comparison. | — | Seven commands rc 0 with totals; parity rc 0, 0 defects; file:line table; no code change | S | antigravity | pass: 7 legs + 1 extra rc 0 (3596/3641/458/700/4957/687/118/103), diff totals.key empty; parity rc 0 (19 BUILT/RAN, 1 OPT-OUT, 0 defects); race 0 warnings in golang:1.27; seam map in docs/signalloom/slaws-p5-preflight-proof.md | — | — | — | — |
| P5-1 | implementation | Live AWS lab per D13: Terraform under `infra/aws/slaws-lab/` for the read-only cross-account role (from `docs/signalloom/slaws-kusari-trust-policy.md`, external ID enforced), a lab bucket with CloudTrail-shaped objects, an SQS queue with S3 notifications and the D12 redrive policy; `scripts/slaws-live-lab.sh` runs signal-ingest in `COLLECTOR_AWSLOGS_MODE=live` with `SIGNAL_DEV_MODE=true`, asserts one object becomes observations through the Â§2.3 projection and that the SQS message is deleted only after `Store.Append`; refuses without credentials and prints the operator command. | P5-PRE | bats for the script (refusal, args, dry-run); `terraform validate`; unit tests at the live seams with fakes; a recorded live run in errata when credentials are present, otherwise STOP-and-report naming the command | M | antigravity | â | â | â | â | â |
| P5-2 | implementation | Multi-account and DLQ per D11/D12: `COLLECTOR_AWSLOGS_ACCOUNTS` parsed into one `awslogs` instance per entry with its own tenant binding and credentials; invalid or duplicate entries refuse boot; `signal-ingest awslogs redrive --queue <dlq-url>` replays DLQ messages through the same projection with derived-ID dedupe and counts `redriven`; manifests gain the env and a rendered example. | P5-PRE | Unit tests: N entries â N collectors with distinct tenants; invalid entry refuses boot with the offending index; redrive dedupes a replayed object; `deploy_render_test` renders the env; counters asserted | M | antigravity | â | â | â | â | â |
| P5-3 | implementation | GuardDuty via EventBridge: project the envelope (`detail-type: GuardDuty Finding`, `detail.severity`, `detail.type`, `detail.resource`) to Â§2.3 observations with `source=aws:guardduty` and a one-line `description`; fixture under `collectors/awslogs/testdata/`; `contract_doc.go` rows; bundle rule `guardduty-high-severity` under `policy/bundles/kusari/`; replay equals live on the extended corpus. | P5-PRE | `contract_test.go` rows for the fixture; negative contract (no raw body, no token) holds; fixture e2e emits the finding; replay-equals-live byte-identical | M | antigravity | â | â | â | â | â |
| P5-4 | implementation | Pseudonym-consistent dry-run and correlator review: policy-engine dry-run bundle registration evaluates with the same pseudonymised `obs.actor` the live path sees (no cleartext comparison); `actor_account_id` is either dropped from the on-disk label set or bounded and justified in Â§2.3; decision review idempotency covers changed-note replay and distinct reviewers; the read-key proof is restated so the superadmin gate cannot make it vacuous. | P5-PRE | Tests: dry-run and live produce identical findings on the corpus; label contract negative test updated; review idempotency cases; read-key test fails when the gate is removed | M | antigravity | â | â | â | â | â |
| P5-GOV | governor | Merge P5-1..P5-4 in order; the seven acceptance commands twice with identical totals plus `scripts/check-ci-build-parity.sh`; Weave cloud-layer evidence via Interceptor when installed, otherwise the jev route evidence; `### Spec: Shared Patterns â Phase 5`; status line closes v2.1. | P5-1, P5-2, P5-3, P5-4 | Acceptance x2 identical; parity rc 0; evidence paths; errata | S | antigravity | â | â | â | â | â |

### Spec: Errata

_Cards append `#### Errata — SLAWS-<ID>` blocks here in delivery order. v2 supersedes v1 on 2026-10-04 after the §8 review and §9 grill; v1's P0 "scaffold merged" claim is withdrawn._

#### Errata — SLAWS-P0 (2026-10-04)

- Baseline at `f906be8f`: all six acceptance commands rc 0 (signal-ingest 1067 pass, frostdb 1115, policy-engine 4 packages, sldc-offline 732, probe-name 0 findings, docs-lint 673 clean). Every §8 finding re-confirmed at that tip.
- Seam commit `6ebfcbee` landed `pkg/obscel` (skeleton + determinism contract), `collectors.BindTenant` stub, `make test-obscel`, `scripts/slaws-acceptance.sh`, and `replace` directives in both apps. Dependency direction fixed: both apps import `pkg/obscel`; neither imports the other.
- The integration branch carried the v1 proposal until `94dd3905`; workers were re-pointed at v2.

#### Errata — SLAWS-P1-1 (2026-10-04, branch `slaws-store-durable-w1`, merged `a3ec3863`)

- §2.2 did not name where `-tags frostdb` lands: `d2-signalloom/apps/signal-ingest/Dockerfile`, with the image build context moved from `d2-signalloom/apps/` to `d2-signalloom/` so `pkg/obscel` is inside it (`scripts/signalfusion-images.sh`). `internal/imagetag` now hashes frostdb-tagged inputs and `pkg/obscel`; before this card the shared module was unpinned.
- Runbook path: `docs/signalloom/runbooks/slaws-duckdb-last-resort.md` (real DuckDB output over a Parquet dir; 15 columns, actors as `hmac_*`, `description` plaintext).
- Telemetry-gap entry for `cloud_control_plane` was reworded, not removed: `api/handlers_test.go` pins "5 of 7 layers active"; promoting the layer to covered is a separate change once a collector feeds it.
- Inherited defects, not fixed: `TestKeyReloadWatchReloadDetectsSymlinkSwap` is load-flaky; ~50 files in the module are not gofmt-clean at base.

#### Errata — SLAWS-P1-2/P1-3/P1-4 (2026-10-04, branch `slaws-awslogs-collector-w2`, merged `b200787a`)

- WAL format bumped to `SLRBV2` (length-prefixed JSON frames); v1 files fail loudly. The ring buffers the raw S3 object, so replay re-projects with current code. Unclean exit is at-least-once by design; derived `Observation.ID` dedupes. Ack ordering is durable → sink → ack → release via `Peek`/`Commit`.
- `go test -race` cannot run in the build sandbox (no cgo). Concurrency tests substitute; a `-race` run outside the sandbox is a required follow-up (ISA ISC-35, deferred).
- Multi-account per deployment is supported in code (`NewAWSLogsCollectorWithConfig`) but only one account is wired from env; an indexed env scheme is a decision for the pilot.
- `TestTombstonePublishesThresholdNotMeasurement` (`privacy/tombstone/tombstone_test.go:265`) is flaky by construction (~0.3%): it asserts a four-digit number is absent from a document that contains random hex. Not touched.

#### Errata — SLAWS-P2-1 engine side / P3-2 auth (2026-10-04, branch `feat/slaws/obscel-evaluator`, merged `850ca7f3`)

- `obs` is a native CEL type, so a misspelt field is a compile error `Conform` catches at load. Bare `obs.labels.k` on an absent key is a CEL error; `has(obs.labels.k)` is the binding idiom and the shipped bundle uses it. §4.1's "bare access never errors" is withdrawn.
- §4.2's stage-2 YAML sample used `over: finding.rule_id == …`; the frozen type is `Window.OverRule`, so the key is `over_rule: iam-priv-change`. `CreateAccessKey` is its own rule (`access-key-created`) so the burst window does not double-count one event.
- `vars.X` and `bundle.vars.X` both compile. `LoadBundleDir` is fail-closed; `main` exits on a malformed bundle. `/api/v1/policies` (bare) is key-guarded too.
- Bundles reach the engine via `scripts/render-policy-bundles.sh` → `policy-engine/base/bundles-configmap.yaml` (`make policy-bundles-render`), mounted at `/etc/policy-engine/bundles`; a test fails when the render is stale; the loader skips kubelet `..data` directories (`7f804725`).
- Bench: `BenchmarkEvaluateObservation` ≈ 11 µs per observation for the three-rule bundle (≈ 3.7 µs per rule), recorded, not a gate.

#### Errata — SLAWS-P1-4 binder (2026-10-04, lead, `daa0e7da`)

- Worker W3 produced nothing; the lead built the card. `tenancy.BindObservations` is the rule; `api.bindWriteTenancy` and `collectors.BindTenant` both call it and surface `tenancy.ErrTenantMismatch`.
- Forge (GPT-5.4 via `codex exec`) could not run: Codex's bwrap sandbox needs `CLONE_NEWUSER`, denied here. Attempting to escape the sandbox was refused; all cards were built by Claude engineers natively.

#### Errata — SLAWS-P2-1/P2-2/P2-3 pipeline (2026-10-04, branch `slaws-pipeline-w5`, merged `18a2b4bf`)

- Stage 1 runs at the sink after the write (`policy.NewSink`); findings and decisions are written back as observations (`policy_finding`, `policy_decision`). HTTP ingest is routed through `policy.Store.Append`, a store wrapper that keeps the batch atomic, not a handler edit.
- Replay: `signal-ingest replay --bundles <dir> --from <RFC3339> --to <RFC3339> [--tenant t] --out <file>`; runbook `docs/signalloom/runbooks/slaws-policy-replay.md`. Replay equals live on the fixture corpus; the comparison includes decisions by line count because a shared-projection bug would cancel on both sides of a byte comparison.
- Warm-up cannot rebuild a window keyed on `labels.<k>` because stored findings carry the closed policy label set; `Warm` warns per such window. The shipped bundle keys on `[tenant_id, actor]`.
- The FrostDB label allow-list refused every finding and decision write (`bundle_id`, `bundle_version`, `source_observation_id`, `mode`, `window_id`, `count`, `finding_ids`); fixed by the lead in `store/label_allowlist.go` (`1dbdcac6`). One replay mutation (removing the skip-own-output filter) survives because the sink's own source guard already refuses to evaluate findings; recorded as defence in depth.
- Counters compose into the existing metrics handler; no new route. Both apps share namespace `fe-signalloom`; signal-ingest mounts the existing `policy-engine-bundles` ConfigMap (`optional: true`).

#### Errata — SLAWS-P3-1/P3-2 live AWS (2026-10-04, branch `slaws-aws-live-w6`, merged `ec931148`)

- `live` imports `awslogs`, so the core package cannot import `live`; live mode is wired by `awslogs.SetLiveClientFactory` from `live`'s `init` and a blank import in `collectors/awslogs_adapter.go`, guarded by a test that fails if the import is removed.
- Crash test: the child process SIGKILLs itself inside the sink after the durable write and before the ack; a file-backed SQS fake survives the child. Exactly-once in the store is proven by derived IDs.
- `aws-sdk-go-v2` was already indirect at v1.16.0 via `thanos-io/objstore`; it is now direct at v1.47.1 with `config`, `credentials`, `service/{s3,sqs,sts}`. Wider blast radius than the five named modules; full suite green.

#### Errata — SLAWS pull-path fixes (2026-10-04, branch `slaws-pull-fixes-w7`, merged `2bfbba03`)

- A notification naming no object (`s3:TestEvent`, unrelated event) is acknowledged and counted (`discarded`); a non-JSON body is not deleted and is counted separately so a poisoned queue stays visible.
- A record replayed from the WAL whose receipt handle SQS rejects as stale is released without ack (`stale_ack` counter) and left to redelivery, where the derived `Observation.ID` dedupes. A non-stale delete failure still keeps the record buffered.
- One notification parser in the core package, URL-decoding keys; `live` delegates to it.
- Pull-only is asserted in code: the live clients call exactly `ReceiveMessage`, `DeleteMessage`, `GetObject`, `AssumeRole`; fixture mode never invokes the client factory.

#### Errata — closing fixes after the advisor review (2026-10-04, lead, `672d8818`, `254ecc5c`)

- **No silent store downgrade.** A binary built without `-tags frostdb` now refuses `SIGNAL_STORE=frostdb` at boot (`store/factory.go`, `!frostdb`) instead of running in memory; `main` exits. `store.HasFrostDB` exposes the build tag; the sentinel store contract test asserts the refusal in untagged builds and persistence under the tag.
- **Replay feedback loop pinned.** `policy/replay_loop_test.go`: a match-all rule over a store holding one raw observation, one stored finding and one stored decision replays to exactly one finding. The invariant is held by two guards (replay input filter and the sink's source guard); disabling one is masked by the other, disabling both fails the test. W5's surviving mutation is therefore a composite invariant with a test, not an unpinned one.
- **Counted acceptance.** `scripts/slaws-acceptance.sh` runs policy-engine with `-v` so tests are counted, records `HEAD` at the start and end of every run, and records `make test-obscel` as a seventh line beyond the six (pkg/obscel is its own module; none of the six reaches it). The two counted runs are at tip `4151c8b5` (HEAD recorded at start and end of each run, run 2's tree dirty only by this errata draft):

| Command | Run 1 | Run 2 |
| :--- | :--- | :--- |
| `make test-signal-ingest` | rc 0, 3330 pass, 0 fail | rc 0, 3330 pass, 0 fail |
| `make test-signal-ingest-frostdb` | rc 0, 3376 pass, 0 fail | rc 0, 3376 pass, 0 fail |
| policy-engine `go test -v ./...` | rc 0, 458 pass, 0 fail | rc 0, 458 pass, 0 fail |
| `make test-sldc-offline` | rc 0, 681 pass, 0 fail | rc 0, 681 pass, 0 fail |
| `scripts/check-old-probe-name.sh` | rc 0 | rc 0 |
| `make docs-lint` | rc 0 | rc 0 |
| beyond the six: `make test-obscel` | rc 0, 97 pass | rc 0, 97 pass |

`diff totals.key` between the runs: identical. The fixture e2e (policy package, including the empty-bundles mutation gate) ran green inside both tagged and untagged signal-ingest commands in both runs.
- **Known flaky tests, pre-existing, named for the operator:** `TestKeyReloadWatchReloadDetectsSymlinkSwap` (load-sensitive 10 s deadline) and `TestTombstonePublishesThresholdNotMeasurement` (`privacy/tombstone/tombstone_test.go:265`, asserts a four-digit number is absent from a document containing random hex, about 0.3 % per run). A red acceptance on one of these two is not a SLAWS regression.

#### Errata — Cato round 2 fixes and the final counted runs (2026-10-04, lead, `632fcf8d`, `1efe1de1`)

- Cato (gpt-5.6-sol via codex, code in scope, 154 KB bundle) found no tenant-binding bypass and no critical issue. Two code findings fixed: the plaintext `description` repeated the principal ARN that the store pseudonymises in `ActorHint` (now omitted, test asserts it); an unprojectable object was acknowledged with only a log line and a counter (now a `projection_failure` observation naming the object is stored first; if the store refuses it nothing is acknowledged).
- Accepted as designed, recorded: label values (`source_ip`, resource names, `error_code`) are the §2.3 projection chosen in D4; the eviction observation's timestamp is the buffered record's receipt time because eviction is an operational event; ISC-35 `-race` remains deferred to a run outside the sandbox.
- Final counted runs at tip `1efe1de1`, clean tree at start and end of both:

| Command | Run 3 | Run 4 |
| :--- | :--- | :--- |
| `make test-signal-ingest` | rc 0, 3336 pass, 0 fail | rc 0, 3336 pass, 0 fail |
| `make test-signal-ingest-frostdb` | rc 0, 3382 pass, 0 fail | rc 0, 3382 pass, 0 fail |
| policy-engine `go test -v ./...` | rc 0, 458 pass, 0 fail | rc 0, 458 pass, 0 fail |
| `make test-sldc-offline` | rc 0, 681 pass, 0 fail | rc 0, 681 pass, 0 fail |
| `scripts/check-old-probe-name.sh` | rc 0 | rc 0 |
| `make docs-lint` | rc 0 | rc 0 |
| beyond the six: `make test-obscel` | rc 0, 97 pass | rc 0, 97 pass |

`diff totals.key`: identical. The only commit after `1efe1de1` is this errata (docs-lint re-run clean on it). Earlier pairs (`4151c8b5`: 3330 / 3376 / 458 / 681; `f39b3bbd`: 3326 / 3374) are superseded.
- Process notes: `632fcf8d` landed with one red test because `PollOnce` drains inline; fixed in `1efe1de1` before any run was counted. A `git checkout -- .` earlier reverted an unstaged allow-list fix while leaving a mutated untracked test in place; both were caught by re-running the suites and corrected in follow-up commits (`1dbdcac6`, `b1aec847`). Never rely on `checkout` to restore a mutation applied to an untracked file.

#### Errata — Cato round 3 and the final counted runs (2026-10-04, lead, `f8d96455`, `89d1f938`)

- Cato round 3 (second and last re-call under the Algorithm's conflict cap) showed the round-2 fixes were incomplete and both gaps are now closed: the `type` label key the collector's `projection_failure` and `buffer_eviction` records carry was not in the FrostDB allow-list (admitted, frostdb-tagged test appends both shapes; mutation killed); a resource ARN that names a principal and the source IP still reached the plaintext description through `resource_name` (description now names the event and resource type only; test asserts no ARN, account id or IP; values remain labels per D4).
- Dispositions Andy inherits, stated plainly: ISC-31 (eviction record timestamp is the buffered record's receipt time) and ISC-26 (label values are unconstrained free text within a closed key set) are accepted by design and recorded here, not resolved; ISC-35 (`go test -race`) remains deferred to a run outside the sandbox; the ISA claims 71/72 on that basis.
- Final counted runs at code tip `89d1f938`, clean tree at start and end of each. Run 6 of the day failed on `TestKeyReloadWatchReloadDetectsSymlinkSwap` alone (pre-existing ten-second deadline, load-sensitive, named above), so the pair was repeated unchanged:

| Command | Run 7 | Run 8 |
| :--- | :--- | :--- |
| `make test-signal-ingest` | rc 0, 3338 pass, 0 fail | rc 0, 3338 pass, 0 fail |
| `make test-signal-ingest-frostdb` | rc 0, 3386 pass, 0 fail | rc 0, 3386 pass, 0 fail |
| policy-engine `go test -v ./...` | rc 0, 458 pass, 0 fail | rc 0, 458 pass, 0 fail |
| `make test-sldc-offline` | rc 0, 681 pass, 0 fail | rc 0, 681 pass, 0 fail |
| `scripts/check-old-probe-name.sh` | rc 0 | rc 0 |
| `make docs-lint` | rc 0 | rc 0 |
| beyond the six: `make test-obscel` | rc 0, 97 pass | rc 0, 97 pass |

`diff totals.key`: identical. Run 5 (same tip) also passed with the same totals. The only commit after `89d1f938` is this errata; `git diff --name-only 89d1f938..HEAD` names this file alone and is recorded in the ISA artefacts. All earlier pairs are superseded.

#### Errata — kind-osramp leg, P4-GOV (2026-10-05, lead, branch `slaws/p4-gov-cluster`)

- Run with Andy's explicit authorisation; the kubeconfig was taken from kind through Docker because the session profile denies `~/.kube/config`. Fixture mode only; no AWS account was touched.
- Four defects visible only in-cluster, all fixed and tested: (1) no manifest supplied `SIGNAL_SEGMENT_PSEUDONYM_KEY`, so the FrostDB store failed closed at boot: Secret `signal-ingest-segment-pseudonym` is minted by `make signal-segment-key` (called from the standup) and read by `secretKeyRef`; (2) the FrostDB label allow-list lacked the §2.3 awslogs keys, so fixture ingestion was refused at observation 0: admitted, with a frostdb-tagged test appending the whole fixture corpus; (3) no overlay selected fixture mode: `fe-signalloom/local` sets `COLLECTOR_AWSLOGS_MODE=fixture`, `AWSLOGS_TENANT_ID=kusari`; (4) the store appended every row again on restart (12→24, 4→8): `collectors.DedupeSink` (bounded set, warmed from the durable store at boot, composed binder → dedupe → policy → store, findings and decisions through the same seam) plus `store.DedupeByID` on the query, replay and warm-up read paths. A replay can no longer manufacture a stage-2 burst.
- Also found by the hub lifecycle spec (other session): the bundles ConfigMap added to `policy-engine/base` in `7f804725` is applied by the SuperCred demo runner, whose Role had no configmaps verbs; the Role fix is on the feature line owned by that session.
- Result at image `src-1c311f837f98534a`: rollout clean; store type frostdb on the bound 10Gi PVC; bundle `kusari-iam-change` 1.0.0 loaded; collector `awslogs` fixture mode; store via the read API: cloud_control_plane 12 distinct rows (aws:iam 6, aws:cloudtrail 2, policy_finding 4), network_egress 4 (aws:vpcflow 3, policy_finding 1); 5 findings, 0 decisions (the corpus has no three qualifying IAM events by one actor within 10 min); actor pseudonymised; label keys exactly the §2.3 set. After `rollout restart`: identical ID sets, identical finding list, counts unchanged; boot log `warmed_ids=449`. Evidence `/tmp/slaws/live/snap{A,B}.json`, pod logs.
- Rebase onto the other session's tip (2026-10-05): its `a1be9c95` landed the same pseudonymisation-key Secret wiring (same Secret and env names, with `scripts/signal-segment-key.sh`, a bats test and a 512Mi memory limit after six OOM kills) and `d11579ee` granted the demo runner its ConfigMap verbs, so the lead's duplicate commit and render-test entry were dropped at rebase; the allow-list keys, fixture overlay, idempotent ingest and errata remain. Image re-pinned on the merged tree.
- Counted acceptance on the cluster-leg tree (`10fe7eb3`, empty caches, twice): signal-ingest 3394/0, frostdb 3446/0, policy-engine 458/0, probe-name clean, docs-lint clean, obscel 97/0 in both runs. `make test-sldc-offline` 699 pass with 4 then 2 failures, all in the warden packages (`TestSpoolRetainsBatchesAcrossIngestOutage`, `TestLocalFreezeWritesAWardenCaptureWithTheTwoSpecAnalogues`): both fail identically on the other session's own tip `a8acbf97` at the same moment (load average 10 to 15 from concurrent sessions, a root `stun-sentinel` process and headless Chrome runs), both packages are byte-identical between the trees, and both passed at `42790625` earlier in the day. They are load-sensitive warden tests, not SLAWS; the pair should be repeated when the host is quiet.
- Not done: no Weave screenshot (the Interceptor daemon is not installed on this host; the page streams the same observations verified through the API). Pushes to GitHub are blocked for both sessions by the gpg ssh agent refusing to sign; all commits are local on `slaws/p4-gov-cluster` and the cluster artefacts were pushed from that tree.

#### Errata — wave two: correctness and alignment, Kusari e2e, decision review (2026-10-05, lead, integration `slaws2`)

- **Alignment gate** (`scripts/docs-tests-alignment.sh`, `make test-alignment`, in `docs-lint-test` and recorded beyond the six in the acceptance script): every Go test name, bats file, spec, script, make target and runbook command a living doc names must exist; walkthrough steps map to acceptance spec strings via `test/fixtures/walkthrough-map.tsv`. First real run: 61 findings, 60 of them checker defects fixed and pinned, one genuine drift (this errata named a make target that did not exist). Two walkthrough gaps recorded in `docs/signalloom/alignment-gaps.md` rather than invented tests.
- **Isolation**: `test/lib/freeport.bash`, three Go test sites and one bats site changed (the bats one silently skipped under concurrency and still exited 0); `scripts/test-isolation-audit.sh` with a reasoned allow-list (70 entries, four admissible categories); `scripts/parallel-acceptance.sh` runs two acceptance instances concurrently. The spool test had 1.7x headroom under fsync-and-fork load and is now `TEST_TIMEOUT_SCALE`-aware (10/10 at scale 10); the warden capture test was not reproduced and its change is precautionary. Any test-only edit under the two sentinel apps moves the sentinel image tag because the Dockerfile copies whole module directories.
- **Jev exploration**: route surface derived from `App.tsx` (44 routes), isolated dashboard in demo mode on a random port outside the ranges other suites use, per-iteration reports, coverage assertion that refuses a short route list; browser mode drives real Chromium with console, page-error, error-boundary and same-origin 5xx oracles. Fetch mode alone reported 44/44 while blind to 16 redirecting routes and to render failures.
- **Kusari e2e** (`make test-kusari-e2e`): eight extra AWS signals as fixtures, bundle `kusari-cloud-signals` 1.0.0 (8 rules, 3 windows), 47-observation corpus → 62 findings / 3 decisions, deterministic synthetic stream with a false-positive gate (3,000 benign → 0), live tier behind `KUSARI_LIVE=1`, walkthrough `docs/EAP/kusari-e2e.md`. Open: GuardDuty findings arrive as an EventBridge envelope that projects to zero observations silently (pinned); `vpc-reject-burst-5m` warm-up collapses without keyed dimensions (addressed by WG below).
- **Replay versus live under pseudonymisation**: FrostDB v2 stores only the actor HMAC, so replay evaluated `obs.actor == ""`: live 62/3, replay 64/2, allowlisted operators fired on replay and actor-keyed windows collapsed. Decision: the pseudonym is the actor identity everywhere in policy; bundle actor lists are declared (`actor_vars:`) and pseudonymised at load; the cross-account rule compares a new `actor_account_id` label against `aws_account_id` instead of parsing the actor ARN. Landed: FrostDB live 62/3 and replay 62/3, 65 canonical lines byte-identical; MemoryStore unchanged; findings and decisions carry `actor_pseudonym`; keyed label values are carried onto stored findings so a `labels.<k>` window warms correctly (the earlier text saying it over-counts was wrong, it under-counted). Known limit: policy-engine's dry-run surface has no store pseudonymiser, so it compares cleartext actors with verbatim allowlists; live evaluation compares pseudonyms.
- **Proof on the integration tip `04526434`**: counted acceptance twice with empty caches, identical totals (signal-ingest 3596/0, frostdb 3641/0, policy-engine 458/0, sldc-offline 700/0, probe clean, docs-lint clean, obscel 118/0, alignment clean) while `make test-bot-loop MODE=browser N=3` ran concurrently (45/45 routes rendered each iteration, no defects). Cluster: image `src-e973fa72a62d1856` on kind-osramp with both kusari bundles loaded (11 rules, 4 windows), 10 findings over the default fixture corpus, dedupe warmed from 20,823 rows. Two concurrent full acceptance passes (`scripts/parallel-acceptance.sh`, `TEST_TIMEOUT_SCALE=2`) both passed with identical totals in 327 s; the script's first run had failed identically in both passes because it wrote its scratch inside the repository (socket paths too long, a dirty tree), which was its own defect, not interference, and is fixed.
- **Decision review**: `GET /api/v1/policy/{findings,decisions,rates}` and `POST /api/v1/policy/decisions/{id}/review` behind `policy:read` and `policy:review`; reviews are `policy_review` observations with derived IDs; gateway proxy `/api/signals/policy/*` with the review gate on superadmin for now; the gateway key gained both permissions. List limit is capped at 100 by the enumeration budget, not the contract's 500.
- **Dashboard `/signals`**: Live and Decisions tabs over a shared 5/10/30/90 m window, rates chart per layer, live feed, decision cards with a three-verdict review and a mandatory note; the page never renders payload-like labels or raw evidence refs. 53 tests.

#### Errata — image pin discipline (lead)

- Every merge that touches signal-ingest sources, `go.mod`, the Dockerfile or `pkg/obscel` moves the immutable image tag; the lead re-pinned after each wave (`432cae1e`, `936b401c`, `81fb97e8`, `bcf7de3f`, final `f39b3bbd`). The zot build site in `d2-signalloom/Makefile` and the image-tag bats probe were updated to the new build context (`5383a747`).

#### Errata — v2 sign-off and P5 preparation (2026-10-06, sensai, `b9177c3f`, `d48ab659`)

- **CI parity green.** `scripts/check-ci-build-parity.sh` reported two TOO LATE (`sldc-ingest-keys`, `fleet-manager-keys` minted after `demo-signalloom-afm-up`) and five MISSING steps against `demo-signalloom-up`. `scripts/ci/vm-pipeline.sh` now mints all five keys at the top of stage [4/7] under retry and builds the security and function images beside the two `-C` publishes stage 1d cannot see. Result: 19 BUILT/RAN, 1 OPT-OUT, 0 defects; `test/ci-build-parity.bats` and the two other pipeline-asserting suites 90/90 (`b9177c3f`).
- **Tombstone flake fixed, not tolerated.** `TestTombstonePublishesThresholdNotMeasurement` searched the whole document for the digits of the population; four CSPRNG-derived hex fields spelled them in about 0.3% of runs. The test now sets the entropy fields aside and asserts the deterministic remainder is identical between populations; 3000 consecutive runs green, `mutation-check.sh` still kills the population mutation (`d48ab659`). Image pin unchanged (`src-940e65d16a917ad3`; tests are outside the fingerprint). The key-reload watcher flake was already fixed at `75448e38`.
- **Race evidence (ISC-35).** `go test -race -count=1 ./...` for signal-ingest in a `golang:1.27` container with the module root mounted: zero `WARNING: DATA RACE` lines across 27 packages. The failing tests in that run are environmental (manifest renders need `kubectl`; imagetag and trust-document tests read the repository), not races. Rerun with the repository mounted: 31 packages ok, zero `DATA RACE` lines; the one failing package is `signal-ingest` root, all eight failures `deploy_render_test.go` needing `kubectl` (absent in the container). Logs: `/tmp/slaws-race/race.log`, `race2.log`.
- **Sign-off.** Andy signed off v2 on 2026-10-06 ("sign off v2 and create the SLAWS cards"); D10 records the inherited dispositions. P5 (close-out and live validation) is decomposed above with D11–D13 and is the mission on `integration/slaws-v0.2.0`.
- Stamp: 2026-10-06 08:02:51 +0100.

#### Errata — SLAWS-P5-PRE (2026-10-06, branch slaws-p5-pre, integration/slaws-v0.2.0, `f4c1326937a83c374d712bd344c28ff266c724a0`)

- **Created:** `2026-10-06 09:04:47+01:00`
- **Last Updated:** `2026-10-06 09:04:47+01:00`
- **Proof record:** [`docs/signalloom/slaws-p5-preflight-proof.md`](signalloom/slaws-p5-preflight-proof.md)
- **Verified baseline:** Two consecutive passes of `scripts/slaws-acceptance.sh` with clean tree (`dirty=0`) and empty caches (`GOCACHE=/tmp/gocache`, `GOMODCACHE=/tmp/gomodcache`, `CGO_ENABLED=0`, `KUBECONFIG=/dev/null`). `diff totals.key` is empty.

| Command | Run 1 | Run 2 |
| :--- | :--- | :--- |
| `make test-signal-ingest` | rc 0, 3596 pass, 0 fail (39s) | rc 0, 3596 pass, 0 fail (57s) |
| `make test-signal-ingest-frostdb` | rc 0, 3641 pass, 0 fail (54s) | rc 0, 3641 pass, 0 fail (52s) |
| policy-engine `go test -v ./...` | rc 0, 458 pass, 0 fail (2s) | rc 0, 458 pass, 0 fail (2s) |
| `make test-sldc-offline` | rc 0, 700 pass, 0 fail (363s) | rc 0, 700 pass, 0 fail (298s) |
| `scripts/check-old-probe-name.sh` | rc 0, checked=4957 (2s) | rc 0, checked=4957 (2s) |
| `make docs-lint` | rc 0, checked=687 (8s) | rc 0, checked=687 (7s) |
| beyond the six: `make test-obscel` | rc 0, 118 pass, 0 fail (1s) | rc 0, 118 pass, 0 fail (1s) |
| beyond the six: `make test-alignment` | rc 0, checked=103 (1s) | rc 0, checked=103 (1s) |

- **CI parity:** `scripts/check-ci-build-parity.sh` reports 19 BUILT/RAN, 1 OPT-OUT (`netassert-runner-image`), 0 defects; rc 0. Log at `/tmp/slaws-p5/pre/parity.log`.
- **Race evidence:** `docker run --rm -v "$PWD":/repo -w /repo/d2-signalloom/apps/signal-ingest -e CGO_ENABLED=1 golang:1.27 go test -race -count=1 ./...` (log `/tmp/slaws-p5/pre/race.log`, `/tmp/slaws-p5/evidence/P5-PRE/race.log`) executed across 34 packages with zero `WARNING: DATA RACE` occurrences (`grep -c 'WARNING: DATA RACE'` = 0). 30 packages passed clean; 2 packages had expected environmental failures (root `signal-ingest` 8 manifest tests in `deploy_render_test.go` needing `kubectl`; `internal/imagetag` 1 test needing git repository mount).
- **SIGNAL_DEV_MODE correction for P5-1:** `signal-ingest` never reads `SIGNAL_DEV_MODE` (only `stun-sentinel/pkg/hubclient/hubclient.go:42` consumes it). P5-1 lab script configures `signal-ingest` via standard `COLLECTOR_AWSLOGS_*` variables.
- **Seam map for Phase 5 cards:**

| File:Line | Exported Symbol | Consumed By | Summary |
| :--- | :--- | :--- | :--- |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/aws.go:106` | `ObjectRef` | P5-1, P5-2, P5-3 | S3 bucket & key ref |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/aws.go:121` | `SQSClient` | P5-1, P5-2 | Queue seam (`ReceiveMessages`, `DeleteMessage`) |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/aws.go:131` | `S3Fetcher` | P5-1, P5-2, P5-3 | Object seam (`GetObject`) |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/aws.go:141` | `STSAssumer` | P5-1, P5-2 | Trust seam (`AssumeRole`) |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/collector.go:41` | `NotificationParser` | P5-1, P5-2 | Parser function type |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/collector.go:50` | `LiveClientFactory` | P5-1 | Factory signature for live AWS seams |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/collector.go:62` | `SetLiveClientFactory` | P5-1 | Registration func called by `live` init |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/collector.go:71` | `LiveClientFactoryRegistered` | P5-1 | Factory availability probe |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/collector.go:86` | `Collector` | P5-1, P5-2 | Core collector struct |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/collector.go:327` | `Collector.Health` | P5-1, P5-2 | Live health probe |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/collector.go:341` | `Collector.Stats` | P5-2 | Ingestion & buffer stats counters |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/collector.go:431` | `Collector.pollLoop` | P5-1, P5-2 | Periodic SQS polling loop |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/collector.go:461` | `Collector.PollOnce` | P5-1, P5-2 | Single receive-fetch-buffer-drain cycle |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/collector.go:536` | `Collector.discardMessage` | P5-1, P5-2 | Acknowledges non-object S3 events |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/collector.go:559` | `Collector.Drain` | P5-1, P5-2 | Projects & ingests ring records |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/collector.go:628` | `Collector.ackAndRelease` | P5-1, P5-2 | Deletes SQS message, releases WAL slot |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/collector.go:675` | `projectionFailureObservation` | P5-3 | Emitted on unprojectable object |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/config.go:18` | `Mode` | P5-1, P5-2 | Operational mode (`off`, `fixture`, `live`) |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/config.go:39–46` | `EnvTenantID` .. `EnvRingCapacity` | P5-2 | Single-account env keys (fan-out replaces) |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/config.go:55` | `AWSCollectorConfig` | P5-1, P5-2 | Account collector configuration |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/config.go:108` | `AWSCollectorConfig.Validate` | P5-1, P5-2 | Config validation |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/config.go:140` | `ConfigFromEnv` | P5-2 | Single-account env reader |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/notification.go:76` | `ParseS3Notification` | P5-1, P5-2 | S3 notification JSON / SNS parser |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/project.go:20` | `Origin` | P5-3 | Origin struct (bucket, key, line) |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/project.go:39` | `Projector` | P5-3 | Observation projector |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/project.go:76` | `Projector.Project` | P5-3 | Projection dispatcher |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/project.go:88` | `Projector.ProjectCloudTrail` | P5-3 | CloudTrail / IAM projector |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/project.go:185` | `actorAccountOf` | P5-4 | Extracts actor account from ARN field 4 |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/project.go:238` | `Projector.ProjectVPCFlow` | P5-3 | VPC Flow Logs v2 projector |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/contract_doc.go:90–134` | `LabelTenantID` .. `LabelCount` | P5-3, P5-4 | Documented label keys |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/contract_doc.go:138–142` | `SourceCloudTrail` .. `SourceCollector` | P5-3 | Observation sources |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/contract_doc.go:233` | `ContractKeysFor` | P5-3 | Required / documented label provider |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/contract_kusari_test.go:202` | `TestKusariFixtures_EventBridgeEnvelopeProjectsToNothing` | P5-3 | Pinning test for GuardDuty gap |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/live/live.go:70` | `STSAssumer` | P5-1 | AWS SDK v2 STS Assumer |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/live/live.go:130` | `SQSClient` | P5-1 | AWS SDK v2 SQS Client |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/live/live.go:237` | `S3Fetcher` | P5-1 | AWS SDK v2 S3 Fetcher |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/live/live.go:295` | `Clients` | P5-1 | Live AWS seams set |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/live/live.go:312` | `NewClients` | P5-1 | Constructs seams from AssumeRole |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/live/register.go:17` | `Factory` | P5-1 | Live factory implementation |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/live/register.go:40` | `init()` | P5-1 | Auto-registers live factory |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/live/register.go:41` | `awslogs.SetLiveClientFactory` | P5-1 | Factory registration site |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs_adapter.go:29` | `_ .../awslogs/live` | P5-1 | Blank import linking live mode |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs_adapter.go:39` | `AWSLogsCollector` | P5-1, P5-2 | Adapter to Collector interface |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs_adapter.go:51` | `NewAWSLogsCollector` | P5-2 | Single-account env adapter constructor |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs_adapter.go:56` | `NewAWSLogsCollectorWithConfig` | P5-2 | Explicit config adapter constructor |
| `d2-signalloom/apps/signal-ingest/collectors/registry.go:14` | `Registry` | P5-2 | Collector registry |
| `d2-signalloom/apps/signal-ingest/collectors/registry.go:129` | `NewRegistryFromEnvWithReceiver` | P5-2 | Wires collectors from env |
| `d2-signalloom/apps/signal-ingest/collectors/registry.go:144` | `reg.Register(NewAWSLogsCollector(...))` | P5-2 | AWS logs registration call site |
| `d2-signalloom/apps/policy-engine/observations.go:21` | `EvaluateObservationRequest` | P5-4 | Dry-run request struct |
| `d2-signalloom/apps/policy-engine/observations.go:60` | `HandleEvaluateObservation` | P5-4 | POST `/api/v1/observations/evaluate` |
| `d2-signalloom/apps/policy-engine/observations.go:106` | `h.evaluator.EvaluateObservation(...)` | P5-4 | Divergence 1: evaluates cleartext actor |
| `d2-signalloom/apps/policy-engine/observations.go:129` | `PolicyStore.LoadObservationBundles` | P5-4 | Loads bundles for tenant |
| `d2-signalloom/apps/policy-engine/observations.go:130` | `obscel.LoadBundleDir(dir)` | P5-4 | Divergence 2: actor_vars not pseudonymised |
| `d2-signalloom/apps/signal-ingest/policy/load.go:70` | `LoadBundles` | P5-4 | Ingest bundle loader with `ActorPseudonymiser` |
| `d2-signalloom/apps/signal-ingest/policy/convert.go:55` | `LabelActor` (`actor_pseudonym`) | P5-4 | Finding actor label constant |
| `d2-signalloom/apps/signal-ingest/policy/convert.go:110` | `ActorIdentity` | P5-4 | Maps cleartext ActorHint to HMAC pseudonym |
| `d2-signalloom/apps/signal-ingest/policy/convert.go:136` | `toObscel` | P5-4 | Converts Observation with HMAC actor |

<!-- kanban-check: status=pass proceed=yes blocking_drift=no -->

