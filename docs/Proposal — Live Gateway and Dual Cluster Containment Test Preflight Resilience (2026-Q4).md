# Proposal — Live Gateway and Dual Cluster Containment Test Preflight Resilience (2026-Q4)

- **Author:** Andrew Martin
- **Date:** 2026-10-13
- **Status:** Proposed
- **Tag:** LIVEPREFLIGHTRESILIENCE

## 1. Problem Statement

Test suites targeting live infrastructure components must distinguish between genuine assertion regressions and offline environment constraints.
The adversarial API test suite and dual-cluster containment suite failed during unprivileged and offline test executions.
When the Kubernetes cluster or Envoy Gateway was unreachable, test setup functions exited with fatal errors.
This caused entire test suites to report failure rather than gracefully skipping live assertions.

## 2. Root Cause Analysis

First, `test/api-adversarial.bats` attempted port-forwarding to Envoy Gateway without confirming cluster accessibility.
When the cluster was offline, the suite looped for fifteen seconds before executing `return 1` in `setup_file`.
In BATS, returning non-zero from `setup_file` causes execution failure rather than graceful test skipping.
Second, `test/e2e-dual-cluster-containment.bats` executed cluster-info queries against workload and hub contexts during setup.
If either context was unreachable, the setup function executed `return 1`.
Similarly, inspecting the Docker kind bridge network returned fatal errors when running without Docker permissions.

## 3. Proposed Hardening

First, add Kubernetes node preflight checks in `test/api-adversarial.bats`.
Skip the test suite immediately when `kubectl` or the cluster is unreachable, avoiding fifteen-second connection timeouts.
Second, replace fatal `return 1` statements with `skip` calls in both suites.
When clusters or the Docker kind network cannot be inspected, BATS marks tests as skipped rather than failed.

## 4. Verification Plan

Run `bats test/api-adversarial.bats` to confirm fifteen out of fifteen tests pass or skip cleanly.
Run `bats test/e2e-dual-cluster-containment.bats` to confirm six out of six tests pass or skip cleanly.
Run `bats test/docs-index-sync.bats` and `scripts/docs-lint.sh` to confirm documentation index synchronisation and style compliance.
Run `scripts/lint-pipefail-grep-q.sh` and `scripts/check-vacuous-assertions.sh` to confirm zero regression across static analysis checks.
