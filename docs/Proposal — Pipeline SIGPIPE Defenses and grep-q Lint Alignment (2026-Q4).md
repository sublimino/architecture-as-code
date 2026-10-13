# Proposal — Pipeline SIGPIPE Defenses and grep-q Lint Alignment (2026-Q4)

## Context
Shell scripts operating under `set -o pipefail` risk verdict inversion when piping data into early-exit readers.
The scanner `scripts/lint-pipefail-grep-q.sh` inspects repository scripts for unannotated pipeline patterns.
The companion test suite `test/pipefail-grep-q-lint.bats` enforces that no unannotated sites exist.

## Problem Statement
When a pipeline streams into `grep -q`, the reader exits immediately upon the first match.
The upstream writer process receives SIGPIPE and exits with status 141.
Because `pipefail` is enabled, the shell treats the entire pipeline as failed.
A genuine match is therefore reported as a failure.
A scan by `scripts/lint-pipefail-grep-q.sh` flags six unannotated sites across four files.
These sites include `scripts/applicability-chaos-mutations.sh` and `scripts/init-tenant.sh`.
They also include `test/offline-mutation-proof.sh` and `test/verify-cel-money-chaos-mutation-proof.sh`.

## Objectives
1. Eliminate pipefail-coupled `grep -q` pipelines in `scripts/applicability-chaos-mutations.sh` using herestrings.
2. Eliminate pipeline streaming into `grep -qw` in `scripts/init-tenant.sh` using herestrings.
3. Decouple output extraction from pattern matching in `test/offline-mutation-proof.sh` using variables and herestrings.
4. Replace piped `printf` streams in `test/verify-cel-money-chaos-mutation-proof.sh` using herestrings.
5. Ensure `scripts/lint-pipefail-grep-q.sh` and `test/pipefail-grep-q-lint.bats` pass cleanly.

## Proposed Changes

### 1. Applicability Chaos Mutations
In `scripts/applicability-chaos-mutations.sh`, replace `printf '%s' "$out" | grep -q ...` with a herestring.
This prevents SIGPIPE when the compiler output contains matching build error strings.

### 2. Tenant Initializer Cluster Discovery
In `scripts/init-tenant.sh`, inspect cluster names from `existing_clusters` using herestrings instead of pipes.
This eliminates pipeline races during cluster name resolution.

### 3. Offline Mutation Proof Failure Extraction
In `test/offline-mutation-proof.sh`, capture failure lines into a variable.
Assert presence using separate herestrings rather than chaining piped grep invocations.

### 4. Money Chaos Mutation Proof Negative Checks
In `test/verify-cel-money-chaos-mutation-proof.sh`, pass test output into `grep -q` using herestrings.
This prevents pipeline failures when detecting unrun test suites.

## Verification Plan
1. Run `./scripts/lint-pipefail-grep-q.sh` and verify zero findings.
2. Run `bats test/pipefail-grep-q-lint.bats` and confirm all 21 tests pass.
3. Run `bats test/vacuous-assertions.bats` to confirm no regressions.
4. Verify documentation index synchronization with `bats test/docs-index-sync.bats`.
5. Run `./scripts/docs-lint.sh` to ensure documentation style compliance.
