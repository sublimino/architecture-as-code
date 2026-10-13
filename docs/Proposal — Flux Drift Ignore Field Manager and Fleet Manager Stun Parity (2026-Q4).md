# Proposal — Flux Drift Ignore Field Manager and Fleet Manager Stun Parity (2026-Q4)

## Context
Flux drift ignore policies protect operational labels and annotations applied out-of-band on workloads.
These labels include containment state, stun reasons, and timestamps.
The test suite `test/flux-drift-ignore.bats` validates RFC 6901 pointer syntax and field manager consistency.

## Problem Statement
Test 4 in `test/flux-drift-ignore.bats` targets `d2-signalloom/apps/fake-integration-proxy/server.py`.
It asserts that the file contains `signalloom.io/stunned` and `signalloom.io/containment-mode`.
However, the fabricated stun handler in `fake-integration-proxy` was retired with HTTP 410 Gone in commit `2c1f5753`.
The operational containment cascade moved to `d2-signalloom/apps/fleet-manager`.
In `fleet-manager`, `PodPatchFieldManager = "flux-client-side-apply"` and stun labels are actively maintained.
Because `test/flux-drift-ignore.bats` never migrated to fleet-manager, test 4 fails deterministically.
Additionally, `scripts/test-flux-drift-ignore.sh` executes 50 continuous reconciliations under this field manager.
The test suite omits this script from its list of verified mutation tools.

## Objectives
1. Update test 4 in `test/flux-drift-ignore.bats` to verify `fleet-manager` containment field manager and label constants.
2. Verify that `fake-integration-proxy` continues to declare `field_manager: str = "flux-client-side-apply"` as fallback.
3. Include `scripts/test-flux-drift-ignore.sh` in the lifecycle scripts tested for `--field-manager=flux-client-side-apply`.
4. Ensure all tests in `test/flux-drift-ignore.bats` pass cleanly without regressions.

## Proposed Changes

### 1. Align Stun Writer Assertions in Test Suite
In `test/flux-drift-ignore.bats`, update test 4.
Verify `PodPatchFieldManager = "flux-client-side-apply"` in `fleet-manager/enforcement.go`.
Verify `FieldManager: PodPatchFieldManager` in `fleet-manager/k8sclient.go`.
Verify `StunnedLabel` and `ContainmentModeLabel` definitions in `fleet-manager/enforcement.go`.
Verify `field_manager: str = "flux-client-side-apply"` in `fake-integration-proxy/server.py`.

### 2. Expand Lifecycle Script Inventory
In `test/flux-drift-ignore.bats`, update test 6.
Add `${REPO_ROOT}/scripts/test-flux-drift-ignore.sh` to the array of checked scripts.

## Verification Plan
1. Run `bats test/flux-drift-ignore.bats` to confirm all tests pass cleanly.
2. Run `bats test/docs-index-sync.bats` to verify documentation indexing.
3. Run `scripts/docs-lint.sh` on the proposal and index documentation.
4. Run `scripts/lint-pipefail-grep-q.sh` and `scripts/check-vacuous-assertions.sh`.
