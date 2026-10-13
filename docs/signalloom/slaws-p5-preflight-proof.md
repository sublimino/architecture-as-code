# SLAWS Phase 5 Pre-flight Baseline Proof (2026-10-06)

**Mission:** SLAWS (Signal Loom AWS Telemetry Ingest & Multilayer Policy Engine Beta)  
**Phase:** Phase 5 — Close-out and Live Validation  
**Role:** P5-PRE (Pre-flight Baseline Verification)  
**Base Ref:** `refs/heads/integration/slaws-v0.2.0`  
**Base Commit:** `f4c1326937a83c374d712bd344c28ff266c724a0`  
**Working Branch:** `slaws-p5-pre`  
**Status:** PASS (0 code defects, 0 data races, acceptance green x2, parity green)

---

## 1. Executive Summary

This document establishes the verified immutable baseline for every SLAWS Phase 5 task (P5-1 through P5-4 and P5-GOV) on `integration/slaws-v0.2.0` at tip commit `f4c1326937a83c374d712bd344c28ff266c724a0`.

Key verification findings:
1. **Acceptance Baseline:** Two consecutive passes of `scripts/slaws-acceptance.sh` executed cleanly across all eight legs with zero failures and identical `totals.key` digests.
2. **CI Parity:** `scripts/check-build-parity.sh` confirmed 0 defects across 19 BUILT/RAN steps and 1 explicit opt-out (`netassert-runner-image`).
3. **Race Safety:** `go test -race -count=1 ./...` in a `golang:1.27` container over `d2-signalloom/apps/signal-ingest` verified zero `WARNING: DATA RACE` across all packages.
4. **Seam Map:** Published the complete `file:line` symbol map for live AWS collector interfaces, single-account configuration surface, GuardDuty EventBridge projection gap, and policy-engine actor dry-run divergence.
5. **SIGNAL_DEV_MODE Finding:** Confirmed that `signal-ingest` never reads `SIGNAL_DEV_MODE` (only `stun-sentinel/pkg/hubclient/hubclient.go:42` consumes it).

---

## 2. Acceptance Test Execution Evidence

Two independent, clean-tree acceptance runs were executed with empty build caches (`GOCACHE=/tmp/gocache`, `GOMODCACHE=/tmp/gomodcache`, `CGO_ENABLED=0`, `KUBECONFIG=/dev/null`).

### 2.1 Acceptance Leg Results

| Leg | Command | Run 1 Result | Run 2 Result | Status |
| :--- | :--- | :--- | :--- | :--- |
| `signal-ingest` | `make test-signal-ingest` | rc=0, pass=3596, fail=0 (39s) | rc=0, pass=3596, fail=0 (57s) | PASS |
| `signal-ingest-frostdb` | `make test-signal-ingest-frostdb` | rc=0, pass=3641, fail=0 (54s) | rc=0, pass=3641, fail=0 (52s) | PASS |
| `policy-engine` | `cd d2-signalloom/apps/policy-engine && go test -count=1 -v ./...` | rc=0, pass=458, fail=0 (2s) | rc=0, pass=458, fail=0 (2s) | PASS |
| `sldc-offline` | `make test-sldc-offline` | rc=0, pass=700, fail=0 (363s) | rc=0, pass=700, fail=0 (298s) | PASS |
| `probe-name` | `bash scripts/check-old-probe-name.sh` | rc=0, pass=checked=4957, fail=0 (2s) | rc=0, pass=checked=4957, fail=0 (2s) | PASS |
| `docs-lint` | `make docs-lint` | rc=0, pass=checked=687, fail=0 (8s) | rc=0, pass=checked=687, fail=0 (7s) | PASS |
| `obscel-extra` | `make test-obscel` | rc=0, pass=118, fail=0 (1s) | rc=0, pass=118, fail=0 (1s) | PASS |
| `alignment` | `make test-alignment` | rc=0, pass=checked=103, fail=0 (1s) | rc=0, pass=checked=103, fail=0 (1s) | PASS |

### 2.2 Key Diff & Tree Invariants

- **Run 1 `totals.key`:**
  ```text
  timeout_scale=1
  signal-ingest            rc=0 pass=3596 fail=0
  signal-ingest-frostdb    rc=0 pass=3641 fail=0
  policy-engine            rc=0 pass=458 fail=0
  sldc-offline             rc=0 pass=700 fail=0
  probe-name               rc=0 pass=checked=4957 fail=0
  docs-lint                rc=0 pass=checked=687 fail=0
  obscel-extra             rc=0 pass=118 fail=0
  alignment                rc=0 pass=checked=103 fail=0
  ```
- **Run 2 `totals.key`:** Identical to Run 1 (`diff -u run1/totals.key run2/totals.key` exited 0 with empty diff).
- **Run 1 `head.txt`:** `head_start=f4c1326937a83c374d712bd344c28ff266c724a0 dirty=0 timeout_scale=1`, `head_end=f4c1326937a83c374d712bd344c28ff266c724a0`.
- **Run 2 `head.txt`:** `head_start=f4c1326937a83c374d712bd344c28ff266c724a0 dirty=0 timeout_scale=1`, `head_end=f4c1326937a83c374d712bd344c28ff266c724a0`.

---

## 3. CI Build Parity Evidence

Execution: `bash scripts/check-build-parity.sh`  
Exit Code: `0`  
Verdict: `0 defects`  

```text
── steps demo-signalloom-up runs, and whether CI runs them ──

  BUILT       sldc-ingest-keys                         demo-pipeline.sh:258
  BUILT       fleet-manager-keys                       demo-pipeline.sh:259
  BUILT       fleet-operator-keys                      demo-pipeline.sh:260
  BUILT       afm-importer-key                         demo-pipeline.sh:261
  BUILT       signal-segment-key                       demo-pipeline.sh:262
  BUILT       push-local-signalloom                    demo-pipeline.sh:263
  BUILT       signalloom-spire-helper                  demo-pipeline.sh:264
  OPT-OUT     netassert-runner-image                   runtime-only: built on demand by the Scan Now button, which no CI stage presses
  BUILT       signalloom-images                        demo-pipeline.sh:265
  BUILT       demo-signalloom-supercred-images         demo-pipeline.sh:281
  BUILT       demo-signalloom-security-images          demo-pipeline.sh:292
  BUILT       demo-signalloom-function-images          demo-pipeline.sh:293
  BUILT       push-local-fleet                         demo-pipeline.sh:308
  BUILT       push-local-agent-trust                   demo-pipeline.sh:309
  BUILT       demo-signalloom-fleet-image              demo-pipeline.sh:300
  RAN         scripts/signalloom-local.sh:up           demo-pipeline.sh:314
  RAN         scripts/agent-trust-local.sh:up          demo-pipeline.sh:396
  BUILT       demo-signalloom-afm-up                   demo-pipeline.sh:411
  BUILT       check-backends                           demo-pipeline.sh:437

  Every step demo-signalloom-up runs is run or explicitly opted out of by CI.
```

---

## 4. Race Condition Evidence (`go test -race`)

Execution: `docker run --rm -v "$PWD":/repo -w /repo/d2-signalloom/apps/signal-ingest -e CGO_ENABLED=1 golang:1.27 go test -race -count=1 ./...`  
Container Environment: `golang:1.27` (`go version go1.27.1 linux/amd64`)  
Log Artifacts: `/tmp/slaws-p5/pre/race.log`, `/tmp/slaws-p5/evidence/P5-PRE/race.log`  
`WARNING: DATA RACE` Count: `0` (`grep -c 'WARNING: DATA RACE' race.log` returned 0)

### 4.1 Package Breakdown (34 Packages Scanned)

- **30 Packages Passed Cleanly under Race Detector:**
  - `api` (23.3s), `api/audit` (1.2s), `audit` (5.7s), `cmd/segment-verify` (1.0s), `codingagent` (1.4s), `collectors` (2.6s), `collectors/agentnono` (1.6s), `collectors/awslogs` (44.2s), `collectors/awslogs/live` (1.1s), `collectors/awslogs/synth` (1.7s), `collectors/baoaudit` (1.4s), `collectors/ebpf` (1.8s), `collectors/gcpaudit` (1.1s), `collectors/kagent` (1.1s), `collectors/netebpf` (1.0s), `collectors/spirea` (1.1s), `collectors/workspacesaas` (1.4s), `correlation` (80.1s), `e2e` (14.2s), `identity` (2.5s), `model` (1.0s), `pkg/fair` (1.2s), `policy` (2.0s), `privacy` (1.1s), `privacy/tombstone` (14.3s), `pseudonym` (1.0s), `retention` (1.1s), `store` (32.3s), `store/verify` (1.1s), `subjectkey` (1.1s), `tenancy` (1.0s), `transform` (1.0s).
- **2 Packages with No Test Files:**
  - `cmd/image-tag`, `collectors/awslogs/awsfake`.
- **2 Non-Race Environmental Failures (Expected & Accounted For):**
  1. `signal-ingest` root package: 8 test failures in `deploy_render_test.go` (`TestReconciledManifestBootsOnStaticKeysAlone`, `TestReconciledManifestCanStillEnableJWTSVIDs`, `TestReconciledManifestTakesKeyValuesFromSecretsOnly`, `TestReconciledManifestProbesTheProbeListener`, `TestReconciledManifestRunsTheImageBuiltFromThisSource`, `TestEveryShippedKeyIsInTheIssuerRegistry`, `TestEachInClusterCallerMountsItsOwnKey`, `TestReconciledManifestStoresSignalsDurably`) due to `kubectl: executable file not found in $PATH` inside standard Go container.
  2. `internal/imagetag`: 1 test failure in `imagetag_test.go:106` (`TestTagIsTheImmutableSourceForm`) due to `git ls-files` unable to open parent git worktree directory from container mount.

---

## 5. Implementation Seam Table for Phase 5 Cards

Every live seam, interface, factory, configuration variable, and policy converter symbol is indexed below by exact path, line number, and consuming card at tip `f4c1326937a83c374d712bd344c28ff266c724a0`.

| File Path | Line | Exported Symbol / Seam | Description | Consumed By |
| :--- | :--- | :--- | :--- | :--- |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/aws.go` | 106 | `ObjectRef` | S3 bucket & key reference struct | P5-1, P5-2, P5-3 |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/aws.go` | 121 | `SQSClient` | SQS interface: `ReceiveMessages`, `DeleteMessage` | P5-1, P5-2 |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/aws.go` | 131 | `S3Fetcher` | S3 interface: `GetObject` | P5-1, P5-2, P5-3 |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/aws.go` | 141 | `STSAssumer` | STS interface: `AssumeRole` | P5-1, P5-2 |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/collector.go` | 41 | `NotificationParser` | Parser function signature `func(body string) ([]ObjectRef, error)` | P5-1, P5-2 |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/collector.go` | 50 | `LiveClientFactory` | Factory signature for live SQS, S3, STS, and Parser | P5-1 |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/collector.go` | 62 | `SetLiveClientFactory` | Registration function for package `live` init | P5-1 |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/collector.go` | 71 | `LiveClientFactoryRegistered` | Probe asserting live factory availability | P5-1 |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/collector.go` | 86 | `Collector` | Core SQS/S3 ingestion collector struct | P5-1, P5-2 |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/collector.go` | 327 | `Collector.Health` | Live health probe assuming role | P5-1, P5-2 |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/collector.go` | 341 | `Collector.Stats` | Ingestion & eviction counter map provider | P5-2 |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/collector.go` | 431 | `Collector.pollLoop` | Background periodic SQS poller loop | P5-1, P5-2 |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/collector.go` | 461 | `Collector.PollOnce` | Single-cycle receive-fetch-buffer-drain execution | P5-1, P5-2 |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/collector.go` | 536 | `Collector.discardMessage` | Deletes non-object SQS notifications (`s3:TestEvent`) | P5-1, P5-2 |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/collector.go` | 559 | `Collector.Drain` | Projects and ingests ring records; acks after sink | P5-1, P5-2 |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/collector.go` | 628 | `Collector.ackAndRelease` | Deletes SQS message and commits WAL ring slot | P5-1, P5-2 |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/collector.go` | 675 | `projectionFailureObservation` | Durable trace emitted when object cannot project | P5-3 |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/config.go` | 18 | `Mode` | Operational mode (`off`, `fixture`, `live`) | P5-1, P5-2 |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/config.go` | 39–46 | `EnvTenantID` .. `EnvRingCapacity` | Single-account environment variable names | P5-2 |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/config.go` | 55 | `AWSCollectorConfig` | Per-account AWS collector configuration struct | P5-1, P5-2 |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/config.go` | 108 | `AWSCollectorConfig.Validate` | Config validation for live mode prerequisites | P5-1, P5-2 |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/config.go` | 140 | `ConfigFromEnv` | Single-account env reader (fan-out target) | P5-2 |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/notification.go` | 76 | `ParseS3Notification` | Extracts S3 bucket/key refs from raw JSON / SNS body | P5-1, P5-2 |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/project.go` | 20 | `Origin` | Origin metadata (bucket, key, line index) | P5-3 |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/project.go` | 39 | `Projector` | AWS telemetry to Observation projector struct | P5-3 |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/project.go` | 76 | `Projector.Project` | Dispatcher on key extension (`.log`, `.txt`, json) | P5-3 |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/project.go` | 88 | `Projector.ProjectCloudTrail` | Projects CloudTrail / IAM records envelope | P5-3 |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/project.go` | 185 | `actorAccountOf` | Extracts 12-digit account ID from ARN field 4 | P5-4 |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/project.go` | 238 | `Projector.ProjectVPCFlow` | Projects VPC Flow Logs v2 text format | P5-3 |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/contract_doc.go` | 90–134 | `LabelTenantID` .. `LabelCount` | Documented label keys under §2.3 contract | P5-3, P5-4 |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/contract_doc.go` | 138–142 | `SourceCloudTrail` .. `SourceCollector` | Observation source constants | P5-3 |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/contract_doc.go` | 233 | `ContractKeysFor` | Contract required & documented label set provider | P5-3 |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/contract_kusari_test.go` | 202 | `TestKusariFixtures_EventBridgeEnvelopeProjectsToNothing` | Pinned test exposing GuardDuty EventBridge gap | P5-3 |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/live/live.go` | 70 | `STSAssumer` | AWS SDK v2 implementation of `awslogs.STSAssumer` | P5-1 |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/live/live.go` | 130 | `SQSClient` | AWS SDK v2 implementation of `awslogs.SQSClient` | P5-1 |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/live/live.go` | 237 | `S3Fetcher` | AWS SDK v2 implementation of `awslogs.S3Fetcher` | P5-1 |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/live/live.go` | 295 | `Clients` | Set of live AWS seams on one assumed role | P5-1 |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/live/live.go` | 312 | `NewClients` | Builds live seams from STS AssumeRole credentials | P5-1 |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/live/register.go` | 17 | `Factory` | Implements `awslogs.LiveClientFactory` | P5-1 |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs/live/register.go` | 40 | `init()` | Auto-registers live factory into `awslogs` | P5-1 |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs_adapter.go` | 29 | `_ .../awslogs/live` | Blank import linking live mode to binary | P5-1 |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs_adapter.go` | 39 | `AWSLogsCollector` | Adapts `awslogs.Collector` to `collectors.Collector` | P5-1, P5-2 |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs_adapter.go` | 51 | `NewAWSLogsCollector` | Constructs adapter from single-account env | P5-2 |
| `d2-signalloom/apps/signal-ingest/collectors/awslogs_adapter.go` | 56 | `NewAWSLogsCollectorWithConfig` | Constructs adapter from explicit account config | P5-2 |
| `d2-signalloom/apps/signal-ingest/collectors/registry.go` | 14 | `Registry` | Collector registry managing startup and health | P5-2 |
| `d2-signalloom/apps/signal-ingest/collectors/registry.go` | 129 | `NewRegistryFromEnvWithReceiver` | Wires standard collectors from environment | P5-2 |
| `d2-signalloom/apps/signal-ingest/collectors/registry.go` | 144 | `reg.Register(NewAWSLogsCollector(...))` | Registry registration site for awslogs | P5-2 |
| `d2-signalloom/apps/policy-engine/observations.go` | 21 | `EvaluateObservationRequest` | Dry-run evaluate request payload | P5-4 |
| `d2-signalloom/apps/policy-engine/observations.go` | 43 | `ObservationHandlers` | Dry-run observation handler struct | P5-4 |
| `d2-signalloom/apps/policy-engine/observations.go` | 60 | `HandleEvaluateObservation` | POST `/api/v1/observations/evaluate` handler | P5-4 |
| `d2-signalloom/apps/policy-engine/observations.go` | 106 | `h.evaluator.EvaluateObservation(...)` | Divergence 1: evaluates cleartext actor | P5-4 |
| `d2-signalloom/apps/policy-engine/observations.go` | 129 | `PolicyStore.LoadObservationBundles` | Loads tenant bundles from disk mount | P5-4 |
| `d2-signalloom/apps/policy-engine/observations.go` | 130 | `obscel.LoadBundleDir(dir)` | Divergence 2: loads `actor_vars` un-pseudonymised | P5-4 |
| `d2-signalloom/apps/signal-ingest/policy/load.go` | 70 | `LoadBundles` | Authoritative bundle loader with `ActorPseudonymiser` | P5-4 |
| `d2-signalloom/apps/signal-ingest/policy/load.go` | 100–115 | `p.Pseudonym(actor)` | Rewrites `actor_vars` into HMAC pseudonym space | P5-4 |
| `d2-signalloom/apps/signal-ingest/policy/convert.go` | 55 | `LabelActor` (`actor_pseudonym`) | Stored finding label carrying pseudonymous actor | P5-4 |
| `d2-signalloom/apps/signal-ingest/policy/convert.go` | 110 | `ActorIdentity` | Resolves observation HMAC actor pseudonym | P5-4 |
| `d2-signalloom/apps/signal-ingest/policy/convert.go` | 136 | `toObscel` | Projects `model.Observation` to `obscel.Observation` | P5-4 |

---

## 6. Single-Account Environment Configuration Surface (P5-2 Target)

The current baseline reads exactly one account from environment variables via `collectors/awslogs/config.go:140` (`ConfigFromEnv()`):

| Variable Name | `config.go` Line | Purpose | P5-2 Multi-Account Target (`COLLECTOR_AWSLOGS_ACCOUNTS`) |
| :--- | :--- | :--- | :--- |
| `AWSLOGS_TENANT_ID` | 39 | Tenant identifier (defaults to `kusari`) | Encoded per entry: `tenant_id` |
| `AWSLOGS_ROLE_ARN` | 40 | Cross-account IAM role ARN to assume | Encoded per entry: `role_arn` |
| `AWSLOGS_EXTERNAL_ID` | 41 | Secret external ID for STS AssumeRole | Encoded per entry: `external_id` |
| `AWSLOGS_QUEUE_URL` | 42 | SQS queue URL receiving S3 notifications | Encoded per entry: `queue_url` |
| `AWSLOGS_REGION` | 43 | AWS region of SQS queue and S3 bucket | Encoded per entry: `region` |
| `AWSLOGS_BUFFER_DIR` | 44 | Local WAL disk buffer directory path | Partitioned per account: `buffer_dir/<account_id>` |
| `AWSLOGS_MAX_RECORDS` | 45 | SQS poll batch size (1..10) | Optional tuning per account |
| `AWSLOGS_RING_CAPACITY` | 46 | Ring buffer slot capacity | Optional tuning per account |

P5-2 will implement multi-account fan-out by parsing `COLLECTOR_AWSLOGS_ACCOUNTS` (JSON array or delimited entries) into multiple `AWSCollectorConfig` structs, registering one `AWSLogsCollector` instance per account with its own credentials and tenant isolation boundary.

---

## 7. GuardDuty / EventBridge Projection Gap (P5-3 Target)

### 7.1 Gap Analysis
- **Root Cause:** When GuardDuty findings are delivered to S3 via Amazon EventBridge, the JSON payload follows the EventBridge event envelope format (`{ "version": "0", "detail-type": "GuardDuty Finding", "source": "aws.guardduty", "detail": { ... } }`) rather than the CloudTrail `{ "Records": [ ... ] }` structure.
- **Current Behavior:** `Projector.ProjectCloudTrail` (`project.go:88`) unmarshals the body into `cloudTrailFile`. Since the EventBridge envelope lacks a `Records` array, `json.Unmarshal` succeeds with `len(Records) == 0`. The projector returns an empty observation slice (`len(obs) == 0`) with `err == nil`.
- **Failure Mode:** A collector pointed at an S3 bucket receiving EventBridge GuardDuty events acknowledges messages while silently storing zero observations.

### 7.2 Pinning Test
- **Test Symbol:** `TestKusariFixtures_EventBridgeEnvelopeProjectsToNothing` in `d2-signalloom/apps/signal-ingest/collectors/awslogs/contract_kusari_test.go:202`.
- **Fixture File:** `d2-signalloom/apps/signal-ingest/collectors/awslogs/testdata/kusari/guardduty-eventbridge-envelope.json`.
- **Exclusion:** The fixture is explicitly excluded from `KusariFixtureFiles()` in `fixtures_kusari.go:53–63` so that it does not silently suppress replay counts.
- **P5-3 Resolution:** Implement an EventBridge projection parser (`ProjectGuardDuty`), define `SourceGuardDuty = "aws:guardduty"` in `contract_doc.go`, add contract test cases, move the fixture into `KusariFixtureFiles()`, and author the `guardduty-high-severity` rule.

---

## 8. Policy-Engine Dry-Run Actor Divergence (P5-4 Target)

### 8.1 Divergence Analysis

Signal Loom policy evaluation enforces strict GDPR and data protection requirements (SLDP-D4) by evaluating rules exclusively over HMAC-pseudonymised actor identities. However, the `policy-engine` dry-run API currently diverges in two places:

1. **Bundle Loading Divergence:**
   - **Signal-Ingest (Live/Replay):** `policy.LoadBundles` (`signal-ingest/policy/load.go:70,100–115`) accepts a `store.ActorPseudonymiser`. When loading bundles, it iterates over `bundle.ActorVars` and rewrites every declared allowlist entry into its HMAC digest: `b.Vars[varName] = pseudonymList`.
   - **Policy-Engine (Dry-Run):** `PolicyStore.LoadObservationBundles` (`policy-engine/observations.go:129–130`) calls `obscel.LoadBundleDir(dir)` directly without a pseudonymiser. All `actor_vars` in dry-run bundles remain cleartext ARNs.

2. **Observation Evaluation Divergence:**
   - **Signal-Ingest (Live/Replay):** `toObscel` (`signal-ingest/policy/convert.go:136`) calls `ActorIdentity(obs, p)` to hash `obs.ActorHint` into `hmac_actor_hint`. CEL rules evaluate `obs.actor` (pseudonym) against `vars.break_glass_actors` (pseudonyms).
   - **Policy-Engine (Dry-Run):** `ObservationHandlers.HandleEvaluateObservation` (`policy-engine/observations.go:60,106`) passes `req.Observation` directly to `h.evaluator.EvaluateObservation(req.Observation, b)`. `req.Observation.Actor` is evaluated as whatever cleartext string was sent in the HTTP request against the cleartext bundle vars.

### 8.2 P5-4 Resolution
P5-4 will wire the pseudonymiser into `policy-engine`'s `LoadObservationBundles` and `HandleEvaluateObservation`, ensuring that dry-run simulations against `/api/v1/observations/evaluate` evaluate identically to the in-process live ingestion sink.

---

## 9. `SIGNAL_DEV_MODE` Finding (P5-1 Target)

The Proposal Work Decomposition row for P5-1 notes:
> `scripts/slaws-live-lab.sh` runs signal-ingest in `COLLECTOR_AWSLOGS_MODE=live` with `SIGNAL_DEV_MODE=true`

**Finding:** Codebase audit reveals that `signal-ingest` does not read or bind `SIGNAL_DEV_MODE`. The only consumer of `SIGNAL_DEV_MODE` in the repository is `d2-signalloom/apps/stun-sentinel/pkg/hubclient/hubclient.go:42` (where it gates `InsecureSkipVerify = true` for local warden dev).

P5-1 should configure `signal-ingest` using its actual configuration variables (`COLLECTOR_AWSLOGS_MODE=live`, `AWSLOGS_ROLE_ARN`, `AWSLOGS_EXTERNAL_ID`, `AWSLOGS_QUEUE_URL`, `AWSLOGS_REGION`, `AWSLOGS_BUFFER_DIR`) without relying on `SIGNAL_DEV_MODE`.

---

## 10. Verification Conclusion

Phase 5 pre-flight verification is complete and certified:
- Baseline commit `f4c1326937a83c374d712bd344c28ff266c724a0` is green.
- CI build parity is 100% compliant (0 defects).
- Go race condition detection reported 0 data races.
- All live seams and divergence points are fully mapped with exact file:line references.
- Phase 5 tasks (P5-1 through P5-4) are clear to begin execution.
