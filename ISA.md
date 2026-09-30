---
project: osramp-demo
task: "SLDC-P4-GOV: Phase 4 Governor: cAdvisor telemetry pipeline verification"
slug: sldc-p4-gov-cadvisor-telemetry-pipeline-verification
effort: E3
phase: verify
progress: 13/13
mode: algorithm
started: "2026-09-30T09:20:17+01:00"
updated: "2026-09-30T09:30:00+01:00"
---

## Problem
Phase 4 implementations (SLDC-P4-1 and SLDC-P4-2) have implemented the Kubelet cAdvisor proxy poller, rate transformation engine, and real-time `/agents` web cockpit and estate metrics bar. Before certifying Phase 4 and proceeding to Phase 5 (end-to-end purple-team containment verification), governance gate verification must certify clean non-fast-forward merge, verify the three-stage telemetry curve under synthetic load (idle baseline $\to$ provocation spike $\to$ acute freeze flatline), prove exact $0.000 \text{ mCPU}$ flatline within 50ms of cgroup freeze, verify volatile process memory preservation, and confirm error-free web UI rendering across all evaluation tiers.

## Vision
Quantitative proof of container containment without heavyweight external monitoring daemons. Telemetry streams seamlessly from Kubelet cAdvisor proxy to the `/agents` UI cockpit, reflecting live millicore consumption and instantly flatlining to strictly $0.000 \text{ mCPU}$ upon cgroup freeze, backed by empirical mutation testing and cryptographic governance artifacts.

## Out of Scope
- Writing feature implementation code directly in the governor role.
- Merging without verifying live CPU spike during provocation and 0.000 mCPU on freeze.
- Starting Phase 5 purple-team tests before telemetry verification is complete.
- Pushing to remote origin without authorization.

## Principles
- Live Verification Over Theoretical Proof: Real-time telemetry curves must be validated on empirical datasets and automated test probes.
- Fail-Closed Flatline Invariant: Cgroup freeze must force CPU consumption to strictly $0.000 \text{ mCPU}$ within 50ms while preserving volatile resident memory (RSS).
- Empirical Mutation Assurance: Test suites must detect and reject deliberate perturbations to rate calculations or epsilon checks.

## Constraints
- Base Ref: `refs/heads/integration/sldc-v0.1.0`.
- Governor Worktree: Dedicated isolated worktree.
- Commit Signing: Unsigned commits (`--no-gpg-sign`).
- Merge Policy: Non-fast-forward merge (`--no-ff`).

## Goal
Execute Phase 4 Governance gate verification, certify clean integration of Phase 4 deliverables into `integration/sldc-v0.1.0`, validate the complete cAdvisor telemetry pipeline and UI cockpit across all 7 gates, and authorize progression to Phase 5.

## Criteria
- [x] ISC-1: Clean non-fast-forward merge of `feat/sldc-p4-1` and `feat/sldc-p4-2` into `integration/sldc-v0.1.0` with 0 merge conflicts.
- [x] ISC-2: Go telemetry package unit tests (`cadvisor_collector_test.go`) pass 8/8 with sub-millisecond latency.
- [x] ISC-3: Python cAdvisor poller pytest suite (`test_cadvisor_poller.py`) passes 8/8 with 0 failures.
- [x] ISC-4: BATS rate calculation suite (`test/unit/cadvisor-rate-calculation.bats`) passes 12/12 with 0 failures.
- [x] ISC-5: Baseline idle container telemetry measures strictly between 0.1 and 5.0 mCPU with resident memory RSS > 10 MiB.
- [x] ISC-6: Provocation load spike via `/act/cpu-burn` increases reported CPU to > 50 mCPU and peak > 200 mCPU within 2 polling cycles.
- [x] ISC-7: Acute cgroup freeze causes reported CPU rate to drop to strictly 0.000 mCPU within 50ms (measured 18.4ms).
- [x] ISC-8: Full-width `/agents` cockpit renders red STUNNED (CGROUP FROZEN) badge, CONTAINED: FROZEN pill, and exact 0.000 mCPU text.
- [x] ISC-9: SVG sparkline renders horizontal zero flatline without vertical jitter during freeze state.
- [x] ISC-10: Top navigation metrics bar displays live aggregate estate stats and shrinks responsively below 1100px.
- [x] ISC-11: REST `/api/v1/telemetry/agents/{pod}` and SSE streaming handlers authenticate with Bearer tokens without URL tokens and cleanly unregister on disconnect.
- [x] ISC-12: Deliberate mutation of freeze epsilon check ($0.0001\text{s}$) or rate formula causes test failure (falsification proved).
- [x] ISC-13: Forensic process memory invariant (H1) holds: container restart count is strictly 0 and memory RSS variance $\le 2\%$.

## Test Strategy
| ISC | Type | Check | Threshold | Tool |
| :-- | :--- | :---- | :-------- | :--- |
| ISC-1 | Git | `git merge --no-ff` | 0 conflicts | Git |
| ISC-2 | Unit | Go test `pkg/telemetry` | 8/8 pass | `go test` |
| ISC-3 | Unit | Python pytest `test_cadvisor_poller.py` | 8/8 pass | `pytest` |
| ISC-4 | Unit | BATS `cadvisor-rate-calculation.bats` | 12/12 pass | `bats` |
| ISC-5 | Telemetry | Trace dataset stage 1 | $0.1 \le \text{mCPU} \le 5.0$ | Python / JSON |
| ISC-6 | Telemetry | Trace dataset stage 2 | $\text{mCPU} > 200.0$ | Python / JSON |
| ISC-7 | Telemetry | Trace dataset stage 3 | $\text{mCPU} = 0.000, t < 50\text{ms}$ | Python / JSON |
| ISC-8 | UI | Vitest `CockpitTelemetry.test.tsx` | 36/36 pass | Vitest |
| ISC-9 | UI | Playwright `agent-cockpit-telemetry.spec.ts` | 9/9 pass | Playwright |
| ISC-10 | UI | Vitest `TopNavMetrics.test.tsx` | 6/6 pass | Vitest |
| ISC-11 | Protocol | Go `TestTelemetryHandler_RESTAndSSE` | Pass | `go test` |
| ISC-12 | Mutation | Epsilon bypass check | Failure on mutant | Python |
| ISC-13 | Forensic | Memory RSS stability check | $\Delta\text{RSS} \le 2\%$, Restarts = 0 | Python / JSON |

## Features
| Name | Description | Satisfies | Depends On | Parallelizable |
| :--- | :---------- | :-------- | :--------- | :------------- |
| F1 Branch Integration | Non-fast-forward merge of Phase 4 deliverables | ISC-1 | - | No |
| F2 Rate Engine Certification | Multi-runtime verification of cAdvisor rate math | ISC-2, ISC-3, ISC-4 | F1 | Yes |
| F3 Live Curve Verification | Three-stage telemetry dataset assertion | ISC-5, ISC-6, ISC-7, ISC-13 | F2 | No |
| F4 Cockpit UI Certification | Headless browser and component UI tests | ISC-8, ISC-9, ISC-10 | F1 | Yes |
| F5 Protocol & Streaming Gate | REST and SSE streaming endpoints validation | ISC-11 | F2 | Yes |
| F6 Mutation Gate | Deliberate mutation falsification checks | ISC-12 | F2 | Yes |
| F7 Governance Reporting | Authority certification and report generation | ISC-1..13 | F1..F6 | No |

## Decisions
- [2026-09-30T09:22:32+01:00] Executed octopus non-fast-forward merge of `feat/sldc-p4-1` (`557749f9`) and `feat/sldc-p4-2` (`2040d91d`) into `integration/sldc-v0.1.0` (Merge SHA: `bb8f8eab`).
- [2026-09-30T09:26:45+01:00] Configured local node modules for `dashboard-signalloom` and `test/acceptance` under `/tmp/bun-tmp` to ensure sandboxed Playwright and Vitest runners execute hermetically.
- [2026-09-30T09:27:40+01:00] Certified all 7 governance gates in `scripts/test-phase4-governor.sh` with 100% pass rate.
- [2026-09-30T09:28:40+01:00] Verified 13/13 test cases in `test/phase4-governor-verification.bats`.

## Changelog
- **Conjectured:** A 2-second rate calculation window might suffer from jitter without an epsilon threshold.
- **Refuted by:** Unit and live trace experiments demonstrating that kernel cgroup counter fluctuations during freeze produce sub-millisecond deltas ($\approx 0.00005\text{s}$).
- **Learned:** Enforcing the $\epsilon = 0.0001\text{s}$ freeze threshold guarantees exact $0.000 \text{ mCPU}$ flatline while maintaining full sensitivity to active load surges.
- **Criterion now:** ISC-7 and ISC-12 formally mandate the freeze flatline invariant and falsification testing.

## Verification
- ISC-1: `git log -1 bb8f8eab` shows clean merge of `feat/sldc-p4-1` and `feat/sldc-p4-2`.
- ISC-2: `go test -v ./...` in `fe-signalloom/pkg/telemetry` passed 8/8 (0.107s).
- ISC-3: `pytest test_cadvisor_poller.py` passed 8/8 (0.95s).
- ISC-4: `bats test/unit/cadvisor-rate-calculation.bats` passed 12/12.
- ISC-5: `phase4-telemetry-trace.json` stage 1 idle avg is $0.870 \text{ mCPU}$, resident memory $176 \text{ MiB}$.
- ISC-6: `phase4-telemetry-trace.json` stage 2 burn spike peak is $250.000 \text{ mCPU}$.
- ISC-7: `phase4-telemetry-trace.json` stage 3 freeze flatline is exact $0.000 \text{ mCPU}$ with $18.4\text{ms}$ latency.
- ISC-8: Playwright and Vitest tests verify STUNNED badge and $0.000 \text{ mCPU}$ text.
- ISC-9: Playwright spec `agent-cockpit-telemetry.spec.ts` verifies horizontal zero flatline SVG path.
- ISC-10: Vitest `TopNavMetrics.test.tsx` (6/6) and Playwright tests verify estate bar rendering.
- ISC-11: `TestTelemetryHandler_RESTAndSSE` passed in Go collector.
- ISC-12: Deliberate mutation test in `test-phase4-governor.sh` verified mutant detection.
- ISC-13: `phase4-telemetry-trace.json` verifies $0.0\%$ RSS variance and 0 restarts.
