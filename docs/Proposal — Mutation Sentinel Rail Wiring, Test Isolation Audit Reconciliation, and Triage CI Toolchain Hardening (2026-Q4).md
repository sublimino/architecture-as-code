# Proposal — Mutation Sentinel Rail Wiring, Test Isolation Audit Reconciliation, and Triage CI Toolchain Hardening (2026-Q4)

## 1. Executive Summary

This proposal wires the shared mutation sentinel safety rail into all mutation proof scripts.
It reconciles the test isolation audit allowlist against recent test toolchain environment additions.
It also isolates the Go toolchain paths in the triage CI worker test suite.
Ambient unwritable system GOPATH locations previously broke Go unit test execution.
Missing sentinel initializations risked unrecovered tree mutations after process interruptions.
All mutation proofs now register unique sentinel guards and arm them before altering files.
The test isolation audit and the triage CI test suites now pass completely.

## 2. Problem Statement

Three distinct test suite failures affected continuous integration and local verification.
First, `test/terraform-mutation-sentinel.bats` failed assertions requiring all mutation proofs to source the shared sentinel helper.
Three mutation proofs lacked `ms_guard_init` declarations: `test/offline-mutation-proof.sh`, `test/verify-cel-money-chaos-mutation-proof.sh`, and `test/verify-cel-mutation-proof.sh`.
Without the sentinel rail, an interrupted test execution could leave mutated files behind without alerting subsequent test runners.
Second, `scripts/test-isolation-audit.sh` detected unallowlisted temporary directory references in `test/agent-identity-binding-vap.bats`.
Those references supplied Go toolchain overrides but lacked documentation entries in `test/fixtures/test-isolation-allowlist.txt`.
Third, `test/triage-ci-worker.bats` failed during Go parser test execution.
The test inherited `/usr/local/src/gocode` from ambient shell environments where the path was not writable.
Go halted with permission denied errors while verifying module checksums.

## 3. Implementation Details

We wire `test/helpers/mutation-sentinel.bash` into the three mutation proof scripts.
In `test/verify-cel-mutation-proof.sh`, we initialize the guard with identifier `verify-cel`.
We arm the guard before modifying files and register an exit trap for automatic cleanup.
In `test/verify-cel-money-chaos-mutation-proof.sh`, we initialize the guard with identifier `verify-cel-money-chaos`.
In `test/offline-mutation-proof.sh`, we initialize the guard with identifier `offline-install`.
We arm the guard in substitution and jq modification helpers.
We replace the ad hoc verification logic with `ms_guard_verify`.
Next, we add allowlist entries with explanatory justifications to `test/fixtures/test-isolation-allowlist.txt`.
Finally, we update `test/triage-ci-worker.bats` setup.
We detect unwritable system GOPATH values and redirect GOPATH to `/tmp/gopath`.
We set `GONOSUMDB="*"`, set `CGO_ENABLED=0`, and ensure required cache directories exist.
We also assert that `main_test.go` exists.

## 4. Verification Record

- We verified all 34 tests pass in `bats test/terraform-mutation-sentinel.bats`.
- We verified all 12 tests pass in `bats test/test-isolation-audit.bats`.
- We verified `scripts/test-isolation-audit.sh` scans 523 test files without errors.
- We verified all 22 tests pass in `bats test/triage-ci-worker.bats`.
- We verified all 7 tests pass in `bats test/docs-index-sync.bats`.
- We verified `scripts/docs-lint.sh` passes on `docs/README.md` and this proposal.
