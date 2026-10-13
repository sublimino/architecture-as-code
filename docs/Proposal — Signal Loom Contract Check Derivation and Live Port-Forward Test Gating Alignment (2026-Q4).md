# Proposal — Signal Loom Contract Check Derivation and Live Port-Forward Test Gating Alignment (2026-Q4)

- **Author:** Andrew Martin
- **Date:** 2026-10-13
- **Status:** Proposed
- **Tag:** CONTRACTDERIVATIONLIVEPORTFORWARD

## 1. Problem Statement

Delivery contract verification validates that working branches descend from authorised integration branches before workload deployment.
When an integration branch merges into the release branch, subsequent development branches incorporate its full commit history.
However, contract derivation checks failed on merged branches because the merge base became reachable from the release branch.
Simultaneously, the port-forward service and acceptance test suites failed in offline environments lacking running cluster components.
Unconditional assertion of live HTTP endpoints caused false test failures.

## 2. Root Cause Analysis

First, `scripts/signalloom-contract-check.sh` inspected the merge base between HEAD and the contract integration branch.
The script rejected any merge base that was an ancestor of the release branch.
Once the integration branch was merged into the release branch, this condition rejected all descendants of that integration branch.
Second, `test/signalloom-portforward.bats` asserted active service status and HTTP 200 responses without checking service health.
When running without an active cluster, `systemctl` reports inactive states and curl fails.
Third, `test/signalloom-autoclaim.bats` and `test/sfas-live-acceptance.bats` invoked `return 1` inside test setup functions on cluster absence.
In BATS, returning non-zero from `setup_file` causes execution failure rather than graceful test skipping.

## 3. Proposed Hardening

First, update `scripts/signalloom-contract-check.sh` to recognise ancestor relationships directly.
If the contract branch is an ancestor of HEAD, accept the worktree as an integration descendant.
Second, add live service readiness guards to `test/signalloom-portforward.bats`.
Skip endpoint assertions when the systemd user service is inactive or unresponsive.
Third, convert `setup_file` error exits in live acceptance suites to skip invocations.
This ensures test suites report clear skip notices when run without active Kubernetes infrastructure.

## 4. Verification Plan

Run `make signalloom-contract-check` to verify contract validation passes.
Run `bats test/signalloom-preflight.bats` to confirm five out of five preflight tests pass.
Run `bats test/signalloom-portforward.bats` to confirm nine out of nine port-forward tests pass.
Run `bats test/signalloom-autoclaim.bats` and `bats test/sfas-live-acceptance.bats` to confirm clean execution and skipping.
Run `bats test/docs-index-sync.bats` and `scripts/docs-lint.sh` to verify documentation synchronisation.
Run `scripts/lint-pipefail-grep-q.sh` and `scripts/check-vacuous-assertions.sh` to confirm zero regression across static analysis checks.
