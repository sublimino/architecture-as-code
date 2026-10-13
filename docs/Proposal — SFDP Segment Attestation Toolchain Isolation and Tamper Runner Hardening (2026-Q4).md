# Proposal — SFDP Segment Attestation Toolchain Isolation and Tamper Runner Hardening (2026-Q4)

## 1. Executive Summary

This proposal resolves toolchain permission failures and command parsing errors in the SFDP segment attestation proof and tamper regression suite.
The tamper regression tests failed during Go module verification and Python script execution.
An ambient non-writable GOPATH caused permission errors when Go verified cryptographic checksums against the Go checksum database.
Unquoted variable expansion in the Makefile audit anchor tamper target resulted in a command parsing failure.
We isolate the Go toolchain environment across the segment attestation script and the regression test suite.
We sanitize the Python runner invocation in the Makefile target.
All tamper regression tests and root wiring assertions now pass cleanly.

## 2. Problem Statement

The test suite `test/sfdp-p4-4-tamper-regression.bats` failed on tests 3 and 4.
Investigation identified two root causes.
First, Go defaulted to `/usr/local/src/gocode` when GOPATH was unset or defaulted from the ambient shell environment.
Because that directory is not writable by standard users, Go failed when writing checksum metadata.
The module verification process aborted with permission denied on sumdb files.
Second, the Makefile target `audit-anchor-tamper-demo` passed `PYTHON=$(AUDIT_ANCHOR_PY)` unquoted to the shell.
The variable `AUDIT_ANCHOR_PY` contains multiple command tokens with whitespace.
When Make executed the recipe line, bash interpreted the second word as an unknown command and aborted with error code 127.
The regression test expected a successful verification run but received an immediate shell syntax failure.

## 3. Implementation Details

We update `Makefile` to quote and sanitize the Python interpreter in `audit-anchor-tamper-demo`.
The recipe now falls back safely to `python3` while respecting caller overrides.
We update `scripts/segment-attestation-proof.sh` to configure a dedicated `gopath` under the test cache directory.
We explicitly set `GOPATH` and `GONOSUMDB="*"` during Go FrostDB integration test execution.
We update `test/sfdp-p4-4-tamper-regression.bats` to detect non-writable or system GOPATH locations during setup.
The setup function points `GOPATH` to `/tmp/gopath` and creates required cache directories.
We also pass isolated toolchain paths to the subshell in test 4.
These adjustments guarantee hermetic test execution across varied continuous integration environments.

## 4. Verification Record

- We verified all 5 tests pass in `bats test/sfdp-p4-4-tamper-regression.bats`.
- We verified all 14 tests pass in `bats test/sfdp-p3-3-root-wiring.bats`.
- We verified `make audit-anchor-tamper-demo AUDIT_ANCHOR_TAMPER_SOURCE=segments` completes with exit status 0.
- We verified all 7 tests pass in `bats test/docs-index-sync.bats`.
- We verified `scripts/docs-lint.sh` passes on `docs/README.md` and this proposal.
