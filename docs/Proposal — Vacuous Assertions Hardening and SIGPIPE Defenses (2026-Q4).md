# Proposal — Vacuous Assertions Hardening and SIGPIPE Defenses (2026-Q4)

## Context
The platform guards against hollow tests through `scripts/check-vacuous-assertions.sh` and `test/vacuous-assertions.bats`.
These scanners detect pipelines that discard failure exit codes or invert verdicts through early `grep -q` exits under `pipefail`.
They also ensure that allowlist entries remain live and accurately describe the codebase.

## Problem Statement
The allowlist in `scripts/vacuous-assertions.allow` contains a stale anchor for `d2-signalloom/apps/stun-sentinel/bpf/build.sh`.
The line was parameterized from a static section name to `$sec`.
This causes allowlist validation to fail.
In `scripts/package-tenant-bundle.sh`, a `mapfile` process substitution populates `listed_paths` without an emptiness guard before driving a loop.
This triggers rule VAC007.
In `scripts/admission-demo.sh` and `test/slsi-bundle-seal-falsification.sh`, commands pipe output into `grep -q` under `pipefail`.
Early `grep` termination causes SIGPIPE, inverting verdicts to false negatives under rule VAC008.
Finally, `scripts/check-vacuous-assertions.sh` and `test/no-exec-probes-in-tests.bats` omit `.cache` from directory prune lists.

## Objectives
1. Update `scripts/vacuous-assertions.allow` line 76 to anchor on `grep -q "$sec"`.
2. Add a non-emptiness check after `mapfile` in `scripts/package-tenant-bundle.sh`.
3. Eliminate pipefail-coupled `grep -q` pipelines in `admission-demo.sh` and `slsi-bundle-seal-falsification.sh` using herestrings.
4. Add `.cache` to the `find` prune expressions in `scripts/check-vacuous-assertions.sh` and `test/no-exec-probes-in-tests.bats`.
5. Ensure all 62 tests in `test/vacuous-assertions.bats` pass cleanly.

## Proposed Changes

### 1. Re-anchor Stun Sentinel BPF Build Allowlist Entry
Update line 76 of `scripts/vacuous-assertions.allow`.
Replace `grep -q "classifier/drop"` with `grep -q "$sec"`.

### 2. Tenant Bundle Manifest Emptiness Assertion
In `scripts/package-tenant-bundle.sh`, add a check after `mapfile -t listed_paths`.
Confirm `listed_paths` contains at least one entry before iterating.

### 3. Replace Piped grep -q with Herestrings
In `scripts/admission-demo.sh`, capture `kubectl api-resources` output into a variable.
Evaluate presence using a herestring with `grep -q`.
In `test/slsi-bundle-seal-falsification.sh`, replace piped `printf` and `echo` invocations with herestrings.

### 4. Prune Cache Directory in Scanners
Add `-o -name .cache` to `scripts/check-vacuous-assertions.sh` line 194.
Add `-name .cache -prune` to `test/no-exec-probes-in-tests.bats` lines 118-120.

## Verification Plan
1. Run `./scripts/check-vacuous-assertions.sh` to confirm zero vacuous assertion findings.
2. Run `bats test/vacuous-assertions.bats` to confirm all 62 tests pass.
3. Run `bats test/docs-index-sync.bats` to confirm documentation index synchronization.
4. Run `./scripts/docs-lint.sh` to confirm documentation style compliance.
