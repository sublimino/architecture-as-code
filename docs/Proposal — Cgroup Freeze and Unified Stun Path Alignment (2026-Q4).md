# Proposal — Cgroup Freeze and Unified Stun Path Alignment (2026-Q4)

- **Author:** Andrew Martin
- **Date:** 2026-10-13
- **Status:** Proposed
- **Tag:** CGROUPFREEZEUNIFIEDSTUN

## 1. Problem Statement

Multiple test suites validating tier-zero execution halts and phase-one governance enforcement fail in sandboxed or isolated test environments.
The `test/cgroup-freeze-stun.bats` suite fails five unit tests covering freezer logic, telemetry emission, and daemon startup.
The `test/crkc-phase1-unified-stun.bats` suite encounters build errors when compiling the warden and traffic control controller binaries.
In addition, assertions expecting legacy Tetragon telemetry deployment manifests fail because manifests were removed in favor of in-tree probes.
Finally, nono agent ingest integration tests lack cluster availability guards for live namespace queries.

## 2. Root Cause Analysis

First, `test/cgroup-freeze-stun.bats` sets its target module directory to `d2-signalloom/apps/signalloom-warden`.
The warden directory contains a flat single package that imports `d2-signalloom/apps/stun-sentinel`.
The modular implementation of cgroup freezing and telemetry emission resides in `d2-signalloom/apps/stun-sentinel`.
Second, unit tests hardcoded invocations of `/usr/bin/go` which lacks required language features declared in module manifests.
Third, `test/crkc-phase1-unified-stun.bats` attempted to build warden from a non-existent subdirectory path.
It also attempted to compile the traffic controller binary from the warden directory instead of `stun-sentinel`.
Fourth, commit history reflects the removal of legacy Tetragon deployment manifests without updating verification gates.
Fifth, `test/sfas-p1-2-nono-ingest.bats` queried Kubernetes namespace resources without checking cluster reachability.

## 3. Proposed Hardening

First, align module directory paths in `test/cgroup-freeze-stun.bats` to point directly to `d2-signalloom/apps/stun-sentinel`.
Second, ensure the active Go toolchain in system path handles unit test compilation and coverage analysis.
Third, update build assertions in `test/crkc-phase1-unified-stun.bats` to target the root warden package and stun-sentinel controller.
Fourth, add cluster and file existence guards for live cluster queries and removed legacy deployment manifests.
Fifth, isolate Go build paths, module caches, and checksum settings across test setup routines.

## 4. Verification Plan

Verify unit and artifact tests in `test/cgroup-freeze-stun.bats` pass cleanly with full statement coverage.
Verify that `test/crkc-phase1-unified-stun.bats` compiles all required binaries and passes ten contract assertions.
Verify that `test/sfas-p1-2-nono-ingest.bats` executes successfully and safely skips live pod queries when clusters are absent.
Confirm that documentation links and decision records synchronize cleanly using `bats test/docs-index-sync.bats`.
Run `scripts/docs-lint.sh` to ensure strict prose compliance.
