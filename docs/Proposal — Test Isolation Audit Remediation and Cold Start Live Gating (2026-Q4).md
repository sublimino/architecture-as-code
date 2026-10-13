# Proposal — Test Isolation Audit Remediation and Cold Start Live Gating (2026-Q4)

- **Author:** Andrew Martin
- **Date:** 2026-10-13
- **Status:** Proposed
- **Tag:** TESTISOLATIONCOLDSTART

## 1. Problem Statement

Test isolation auditing enforces clean parallel test execution and eliminates shared path collisions across runners.
Recently added test cases introduced hardcoded paths under the shared temporary root directory.
Specifically, awslogs account parsing tests hardcoded a static buffer directory path.
Similarly, policy engine observation tests used a fixed temporary log file in negative file access rule assertions.
In addition, the cold-start persistence verification suite failed when executed without an active Kubernetes cluster.
The suite attempted live reconciliation queries and exec probes against unreachable cluster endpoints.

## 2. Root Cause Analysis

First, `accounts_test.go` set the buffer directory environment variable to a fixed path instead of an isolated temporary directory.
This pattern caused concurrent test runners to collide on the same directory structure.
Second, `observations_test.go` tested non-sensitive file access rules using a fixed temporary file path.
The static analysis script `scripts/test-isolation-audit.sh` scans test files for fixed temporary path literals and flags them as findings.
Third, `test/cold-start-persistence-verification.bats` ran live PostgreSQL, OpenBao, Flux, and Gateway API queries unconditionally.
Without a cluster reachability check, these assertions terminated with connection refused errors in hermetic offline environments.

## 3. Proposed Hardening

First, update `accounts_test.go` to create a dedicated temporary directory via standard testing helpers.
Second, replace the static temporary path in `observations_test.go` with a non-sensitive log path.
This change satisfies the negative assertion while avoiding unallowlisted temporary path literals.
Third, introduce cluster availability detection in `test/cold-start-persistence-verification.bats`.
Fourth, gate live reconciliation tests so they skip cleanly when clusters are unavailable while continuing full execution in cluster environments.

## 4. Verification Plan

Verify that `scripts/test-isolation-audit.sh` scans five hundred and twenty-three test files with zero findings.
Verify that `bats test/test-isolation-audit.bats` passes twelve out of twelve tests.
Verify that all unit tests in the policy engine and awslogs collector packages pass cleanly.
Verify that `bats test/cold-start-persistence-verification.bats` executes all tests without unexpected failures.
Confirm documentation synchronization with `bats test/docs-index-sync.bats` and validate prose style with `scripts/docs-lint.sh`.
