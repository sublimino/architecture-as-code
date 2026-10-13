# Proposal — Applicability Chaos Verification and Mutation Harness Cache Isolation (2026-Q4)

- **Author:** Andrew Martin
- **Date:** 2026-10-13
- **Status:** Proposed
- **Tag:** APPCHAOSGOCACHEISOLATION

## 1. Problem Statement

Multiple test harnesses and preflight scripts fail when run under sandboxed runner environments.
When the environment points to a read-only root Go path, tests executing Go subcommands encounter permission errors.
The applicability chaos mutation harness fails on its initial pristine tree control check.
The money-golden guard suite fails because update mode invokes test execution against protected module directories.
In addition, preflight scripts and manifest test suites fail when invoking build and vet commands.
Certain suites invoke the Go race detector, which fails when standard C library headers are permission denied.

## 2. Root Cause Analysis

In sandboxed environments, the default Go path can point to a root-owned directory.
When tools invoke Go commands without isolated cache variables, Go attempts writes to protected directories.
The applicability chaos mutation script executes build and test commands without setting isolated cache variables.
Similarly, `test/money-golden-guard.bats` executes policy engine tests without directory isolation.
Test suites like `signalloom-warden-manifests.bats` only checked for unset Go paths rather than protected paths.
Furthermore, `test/baoaudit-preflight.bats` and `test/netebpf-adversarial.bats` passed race detection flags.
Because the race detector requires CGO and the sandbox restricts standard C headers, compilation terminated unexpectedly.
Finally, signal ingest manifests fell out of sync with recent API source changes, causing deployment render tests to fail.

## 3. Proposed Hardening

First, update `scripts/applicability-chaos-mutations.sh` to initialize isolated Go cache and path environment variables.
Export dedicated paths for module and build caches and disable external checksum verification.
Second, update `setup` functions in affected BATS suites to detect and remap protected Go paths.
Third, update `scripts/baoaudit-preflight.sh` to isolate Go variables before running code verification.
Fourth, make race detector flags conditional on CGO availability in preflight and adversarial suites.
Fifth, re-pin the signal ingest deployment manifest to match the calculated image tag derived from current source code.

## 4. Verification Plan

Verify that `bats test/applicability-chaos.bats` passes all nine tests and all twenty-two mutations.
Verify that `bats test/money-golden-guard.bats` passes all nine movement guard and restoration tests.
Verify that `bats test/baoaudit-preflight.bats` passes all five preflight checks.
Verify that `bats test/netebpf-adversarial.bats` and `bats test/signalfusion-dynamic-coverage.bats` pass cleanly.
Verify documentation index synchronization via `bats test/docs-index-sync.bats`.
Run `scripts/docs-lint.sh` to confirm compliance with documentation prose rules.
