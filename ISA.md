---
task: "SLER-P6-1: Execute purple-team containment escape suite across all planes"
project: "osramp-demo"
slug: "sler-p6-1"
effort: "E4"
effort_source: "explicit"
phase: "complete"
progress: "37/37"
mode: "algorithm"
started: "2026-09-15T09:07:49+01:00"
updated: "2026-09-15T09:14:00+01:00"
---

# ISA: SLER-P6-1 Multi-Plane Purple-Team Adversarial Containment Escape Suite

## Problem
Prior to Phase 6, the purple-team adversarial test runner `scripts/run-redteam-suite.sh` and BATS suite `test/crkc-adversarial-redteam.bats` only contained 15 scenarios exclusively covering the `freeze` and `mesh` (TC eBPF) planes. The remaining three critical enforcement planes — **OpenBao** (credential/lease revocation), **SPIRE** (workload identity eviction), and **Admission** (dynamic webhook pod block), plus **Fleet Orchestration** (idempotent multi-plane cascade) — had zero adversarial escape scenarios in the red-team runner. Any claim of "zero escape rate" across the mission was unfalsifiable without exercising all five planes under genuine adversarial stress.

## Vision
The purple-team adversarial runner executes a comprehensive 24-scenario suite across all five enforcement planes (`freeze`, `mesh`, `bao`, `spire`, `admission`), with scenario-level metadata tagging, automated self-checking preventing silent coverage regression, per-plane escape counting, combined simultaneous multi-plane attack validation, and strict alignment with P5-2's published denial matrix. The suite runs cleanly and fast in CI, fails loudly if dependencies are unreachable, and proves cryptographically and empirically that escape rate is zero.

## Out of Scope
- Contacting live customer infrastructure or production clusters.
- Modifying SLDP identity derivation or external key schemas.
- Ingesting customer sensitive payload contents, prompt text, or raw secrets.
- Inventing aspirational latency figures ungrounded in P5-2's certified denial matrix.

## Principles
1. **Falsifiable Claims**: Escape rate zero must be proven through active adversarial scenario execution, never asserted by omission.
2. **Ground Truth Alignment**: Every timing threshold must match P5-2's published denial matrix figures (`freeze`: 18ms p99 / 0ms residual; `mesh`: 10ms p99 / 0ms residual; `openbao`: 15ms p99 / 300s residual; `spire`: 2.0ms p99 / 300s residual; `admission`: 2.28ms p99 / 0ms residual).
3. **Fail-Closed Verification**: Both admission enforcement and test harness integrity must fail closed (loud non-zero exit) under partial outages.
4. **Self-Guarding Coverage**: Scenario metadata tags and programmatic self-checks must prevent coverage from silently regressing below the five-plane matrix.
5. **Transparent Per-Plane Observability**: Output and metrics must expose per-plane escape counts individually, not only an aggregated number.

## Constraints
1. **Schema Consistency**: Metrics JSON must conform to `sler.signalloom.io/v1alpha1` and retain `.metrics.process_escapes` compatibility.
2. **BATS Test Integration**: All scenarios must be verifiable via `bats test/crkc-adversarial-redteam.bats`.
3. **Fast CI Runtime**: Full suite execution must remain under 30 seconds to be practical in CI pipelines.
4. **Combined Attack Representation**: Multi-plane attacks (e.g. OpenBao + Mesh) must be tagged for both planes and counted towards both in coverage audits.

## Goal
Expand `scripts/run-redteam-suite.sh` and `test/crkc-adversarial-redteam.bats` to 24 adversarial attack scenarios covering all five enforcement planes (`freeze`, `mesh`, `bao`, `spire`, `admission`), embed scenario plane metadata and self-checks, prove zero process escapes across all planes, and publish complete proof in `docs/signalloom/sler-p6-1-proof.md`.

## Criteria
- [x] ISC-1: Update `scripts/run-redteam-suite.sh` with scenario metadata schema including `plane` / `planes` category tags (`freeze`, `mesh`, `bao`, `spire`, `admission`).
- [x] ISC-2: Add OpenBao post-revocation credential lease replay escape scenario (`scenario-16`) asserting failure <= 15ms (p99 guaranteed denial).
- [x] ISC-3: Add SPIRE post-eviction cached SVID replay escape scenario (`scenario-17`) asserting rejection after worst-case residual window (300s JWT / 3600s X.509) and eviction in <= 2.0ms.
- [x] ISC-4: Add Admission controller contained pod reconstitution & rescheduling escape scenario (`scenario-18`) asserting 403 rejection in <= 3ms (2.28ms p99).
- [x] ISC-5: Add Admission controller fail-closed policy scenario under simulated webhook unavailability (`scenario-19`) asserting rejection.
- [x] ISC-6: Add Fleet orchestration concurrent double-apply race scenario (`scenario-20`) asserting idempotency deduplication.
- [x] ISC-7: Add Combined multi-plane simultaneous attack scenario (`scenario-21`) asserting simultaneous containment across OpenBao and Mesh with dual-plane tagging.
- [x] ISC-8: Add Governance resume operator key verification scenario (`scenario-22`) asserting cryptographic signature validation against real deployed operator keys.
- [x] ISC-9: Add Purple-team test runner environment resilience scenario (`scenario-23`) asserting loud failure when required plane clients are unreachable.
- [x] ISC-10: Add Five-plane coverage matrix self-check scenario (`scenario-24`) failing the run if any of `freeze`, `mesh`, `bao`, `spire`, `admission` has 0 scenarios.
- [x] ISC-11: Update `scripts/run-redteam-suite.sh` metrics to compute and emit both aggregate `process_escapes` and per-plane escape counts (`escapes_by_plane`).
- [x] ISC-12: Update `scripts/run-redteam-suite.sh` stdout summary to print per-plane escape breakdowns individually in the console output.
- [x] ISC-13: Extend `test/crkc-adversarial-redteam.bats` with BATS tests covering OpenBao scenario-16.
- [x] ISC-14: Extend `test/crkc-adversarial-redteam.bats` with BATS tests covering SPIRE scenario-17.
- [x] ISC-15: Extend `test/crkc-adversarial-redteam.bats` with BATS tests covering Admission scenario-18.
- [x] ISC-16: Extend `test/crkc-adversarial-redteam.bats` with BATS tests covering Admission fail-closed scenario-19.
- [x] ISC-17: Extend `test/crkc-adversarial-redteam.bats` with BATS tests covering Fleet idempotency scenario-20.
- [x] ISC-18: Extend `test/crkc-adversarial-redteam.bats` with BATS tests covering Combined-plane scenario-21.
- [x] ISC-19: Extend `test/crkc-adversarial-redteam.bats` with BATS tests covering Governance resume operator key scenario-22.
- [x] ISC-20: Extend `test/crkc-adversarial-redteam.bats` with BATS tests covering Runner resilience scenario-23.
- [x] ISC-21: Extend `test/crkc-adversarial-redteam.bats` with BATS tests covering Five-plane coverage self-check scenario-24.
- [x] ISC-22: Extend `test/crkc-adversarial-redteam.bats` with BATS assertions verifying per-plane escape counts are all 0 in `.metrics.escapes_by_plane`.
- [x] ISC-23: Add regression test asserting that if any of the 5 plane tags is missing or has 0 scenarios, the runner fails.
- [x] ISC-24: Pass `bash scripts/run-redteam-suite.sh` with 0 failures and record actual runtime.
- [x] ISC-25: Pass `bats test/crkc-adversarial-redteam.bats` with 0 failures.
- [x] ISC-26: Verify `grep -n '"name"' scripts/run-redteam-suite.sh` finds all 24 scenarios.
- [x] ISC-27: Verify `grep -n 'process_escapes' test/crkc-adversarial-redteam.bats` matches assertions.
- [x] ISC-28: Verify `grep -n 'plane' scripts/run-redteam-suite.sh` matches plane metadata.
- [x] ISC-29: Generate comprehensive proof document `docs/signalloom/sler-p6-1-proof.md` with per-plane escape metrics and timing data.
- [x] ISC-30: Append qualified `Errata — SLER-P6-1` block with `status=pass` in proposal note.
- [x] ISC-31: Update `Result` column in proposal Work Decomposition table.
- [x] ISC-32: Create conventional git commit for SLER-P6-1 in worktree.
- [x] ISC-33: Anti: Must NOT claim escape rate zero without executing the expanded five-plane suite.
- [x] ISC-34: Anti: Must NOT weaken failing assertions rather than reporting failure.
- [x] ISC-35: Anti: Must NOT use aspirational numbers instead of P5-2 published denial matrix figures.
- [x] ISC-36: Anti: Must NOT allow coverage to silently drop below 5 planes in future runs.
- [x] ISC-37: Anti: Must NOT omit per-plane breakdown from output or evidence.

## Test Strategy
- isc | type | check | threshold | tool
- ISC-1..12 | script/json | Execute `scripts/run-redteam-suite.sh` | exit=0, valid json, 24 scenarios | Bash, jq
- ISC-13..23 | bats | Execute `bats test/crkc-adversarial-redteam.bats` | 27 tests pass, 0 fail | bats
- ISC-24..28 | verification | Grep & syntax validation | all regex match | grep
- ISC-29 | doc | Verify `docs/signalloom/sler-p6-1-proof.md` | full proof metrics present | Read
- ISC-30..32 | governance | Errata + Result update + git commit | clean commit SHA | obsidian-read/modify, git

## Features
- expanded_redteam_runner | Expand `scripts/run-redteam-suite.sh` to 24 scenarios with 5 plane tags | satisfies ISC-1..12 | depends_on none | parallelizable no
- bats_adversarial_suite | Extend `test/crkc-adversarial-redteam.bats` with per-scenario & per-plane checks | satisfies ISC-13..23 | depends_on expanded_redteam_runner | parallelizable no
- proof_and_governance | Author `docs/signalloom/sler-p6-1-proof.md`, update proposal errata & decomposition table | satisfies ISC-29..32 | depends_on bats_adversarial_suite | parallelizable no

## Decisions
- 2026-09-15: Selected 24 total attack scenarios (15 existing freeze/mesh + 9 new covering OpenBao, SPIRE, Admission, Idempotency, Combined attack, Operator Key, Runner Resilience, and Coverage Self-Check).
- 2026-09-15: Tagged combined scenario `scenario-21` with both `bao` and `mesh` so it contributes to both planes in the self-check and per-plane coverage counts.
- 2026-09-15: Formatted per-plane metrics as `.metrics.escapes_by_plane` with fields `freeze`, `mesh`, `bao`, `spire`, `admission`, all asserted to be 0.

## Changelog
- 2026-09-15: Initialized SLER-P6-1 ISA for purple-team containment escape suite expansion.
- 2026-09-15: Executed 24/24 scenarios with 0 escapes across all 5 planes, verified via 27/27 BATS tests.

## Verification
- ISC-1..12: `bash scripts/run-redteam-suite.sh` executed cleanly (24/24 passed, 0 escapes).
- ISC-13..23: `bats test/crkc-adversarial-redteam.bats` passed (27/27 tests passed).
- ISC-24..28: All grep and runtime assertions verified.
- ISC-29: `docs/signalloom/sler-p6-1-proof.md` created.
