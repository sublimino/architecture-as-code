# Proposal — Flux Workload Coverage Parity and Python YAML Resolver Alignment (2026-Q4)

## Context
GitOps delivery relies on Flux reconciliation to recreate cluster workloads.
The scanner `scripts/flux-workload-coverage.py` verifies that every workload manifest in delivery roots maps to a Flux object.
Unmanaged workloads must appear in `docs/flux-coverage-exceptions.yaml` with explicit justification.
The test suites `test/flux-workload-coverage.bats` and `test/kind-config-heredoc.bats` enforce these constraints offline.

## Problem Statement
The second Kusari agent workload `d2-signalloom/infra/agent-swarm/agent-nono-kusari/deployment.yaml` lacks GitOps reconciliation.
It was documented as unmanaged drift in `docs/flux-coverage.md`.
However, it was omitted from `docs/flux-coverage-exceptions.yaml`.
This omission causes `scripts/flux-workload-coverage.py` to fail.
Additionally, several test invocations execute bare `python3` commands without verifying module availability.
When the default interpreter in `PATH` lacks the `yaml` package, test suites fail immediately with `ModuleNotFoundError`.
This occurs in `test/flux-workload-coverage.bats` and `test/kind-config-heredoc.bats`.

## Objectives
1. Register `agent-nono-kusari/deployment.yaml` in `docs/flux-coverage-exceptions.yaml` as an acknowledged gap.
2. Update the declared gap count in `test/flux-workload-coverage.bats` from 10 to 11.
3. Add interpreter re-execution in `scripts/flux-workload-coverage.py` when the active interpreter lacks `yaml`.
4. Configure resilient Python interpreter resolution in `test/flux-workload-coverage.bats` and `test/kind-config-heredoc.bats`.
5. Verify clean test passes across `flux-workload-coverage.bats` and `kind-config-heredoc.bats`.

## Proposed Changes

### 1. Register Unmanaged Workload Exception
Add `d2-signalloom/infra/agent-swarm/agent-nono-kusari/deployment.yaml` to `docs/flux-coverage-exceptions.yaml`.
Classify the entry as `gap` with details regarding out-of-band demo deployment.

### 2. Update Flux Workload Coverage Count
In `test/flux-workload-coverage.bats`, increment the expected gap count from 10 to 11 in test 10.
This reflects the explicit registration of the unmanaged deployment.

### 3. Add Python YAML Fallback in Scanner
In `scripts/flux-workload-coverage.py`, handle `ImportError` on `import yaml`.
Re-execute with `/usr/bin/python3` if available when the active interpreter lacks the module.

### 4. Resilient Interpreter Selection in Tests
In `test/flux-workload-coverage.bats` and `test/kind-config-heredoc.bats`, dynamically resolve the Python interpreter.
Select an interpreter that successfully loads the `yaml` package.

## Verification Plan
1. Run `scripts/flux-workload-coverage.py` and confirm zero undeclared unmanaged workloads.
2. Run `bats test/flux-workload-coverage.bats` and verify all 10 tests pass.
3. Run `bats test/kind-config-heredoc.bats` and verify all 5 tests pass.
4. Verify documentation index synchronization using `bats test/docs-index-sync.bats`.
5. Check documentation style compliance using `scripts/docs-lint.sh`.
