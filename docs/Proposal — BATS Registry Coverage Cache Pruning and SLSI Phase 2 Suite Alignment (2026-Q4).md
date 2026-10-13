# Proposal — BATS Registry Coverage Cache Pruning and SLSI Phase 2 Suite Alignment (2026-Q4)

## Context
The repository enforces test registry coverage through `d2-signalloom/test/bats-registry-coverage.bats`.
This guard ensures that every test script and BATS suite belongs to an active runner or has a documented exclusion reason.
The guard prevents orphan proof scripts and uninvoked acceptance suites from escaping notice.

## Problem Statement
The test discovery command in `bats-registry-coverage.bats` line 380 scans directories named `test`.
The command prunes `node_modules`, `.git`, `test_helper`, `.claude`, and `.worktrees`.
However, it omits the `.cache` directory.
When tests create module caches in `.cache/gomodcache`, `find` descends into third-party Go modules.
It flags vendored third-party shell scripts as uninvoked repository proofs.
Additionally, root-owned Kind and Zot volume directories under `.cache` cause permission denied errors.
Furthermore, ten newly added BATS suites are not registered in `root_excluded`.
These include nine SLSI Phase 2 and Phase 3 suites and one documentation diagram focus gate.
These omissions cause tests 19, 20, and 22 in `bats-registry-coverage.bats` to fail.

## Objectives
1. Add `.cache` directory pruning to line 380 of `bats-registry-coverage.bats`.
2. Prevent traversal into vendored module caches and root-owned volume mounts.
3. Register the nine SLSI Phase 2 and Phase 3 suites and `diagram-focus.bats` in `root_excluded`.
4. Document the ownership and execution model for each excluded suite.
5. Ensure all 22 tests in `bats-registry-coverage.bats` pass cleanly.

## Proposed Changes

### 1. Cache Directory Pruning
We update line 380 in `d2-signalloom/test/bats-registry-coverage.bats`.
We add `-o -name .cache` to the `find` prune expression.
This matches the existing convention in `Makefile` line 595.

### 2. SLSI Phase 2/3 and Diagram Focus Registration
We add the ten suites to `root_excluded` in `bats-registry-coverage.bats`:
- `diagram-focus.bats`
- `slsi-adversarial-redteam.bats`
- `slsi-bootstrap-persistence.bats`
- `slsi-diagnostics-bundler.bats`
- `slsi-dual-trust.bats`
- `slsi-host-mounts.bats`
- `slsi-ingress-modes.bats`
- `slsi-tenant-keys.bats`
- `slsi-upgrade-rollback.bats`
- `slsi-zot-preload.bats`

We add comments documenting their ownership by the SLSI programme and documentation checks.

## Verification Plan
1. Run `bats d2-signalloom/test/bats-registry-coverage.bats` to confirm all 22 tests pass.
2. Run `bats test/docs-index-sync.bats` to confirm documentation index synchronization.
3. Run `./scripts/docs-lint.sh` to confirm prose style compliance.
