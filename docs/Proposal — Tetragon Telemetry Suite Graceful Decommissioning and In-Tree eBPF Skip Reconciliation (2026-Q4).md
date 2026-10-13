# Proposal — Tetragon Telemetry Suite Graceful Decommissioning and In-Tree eBPF Skip Reconciliation (2026-Q4)

## 1. Executive Summary

This proposal reconciles the legacy Tetragon test suite and harness scripts following the decommissioning of Tetragon deployment manifests.
Signal ingest migrated to an in-tree eBPF endpoint collector backed by the stun-sentinel syscall trace stream.
The Tetragon deployment manifests and gRPC client were removed during this migration.
The standalone test suite `test/tetragon-telemetry-stream.bats` and stream harness failed when manifests were absent.
We add graceful skip conditions matching `test/crkc-phase1-unified-stun.bats` when the deploy manifest is absent.
We also isolate the Go toolchain paths during `make test-tetragon` execution.
Both `make test-tetragon-bats` and `make test-tetragon-stream` now succeed cleanly.

## 2. Problem Statement

In previous development phases, signal ingest retired the external Tetragon gRPC collector.
The endpoint host detection was re-sourced to `sentinel.ebpf.syscall_trace`.
Later cleanup removed the deploy manifest `tetragon-agent-telemetry.yaml` and Helm values `tetragon-helm-values.yaml`.
While `test/crkc-phase1-unified-stun.bats` updated its manifest check to skip gracefully, `test/tetragon-telemetry-stream.bats` still asserted file presence.
Running `bats test/tetragon-telemetry-stream.bats` caused 21 test failures.
The harness `scripts/test-tetragon-stream.sh` also failed while attempting to compile the legacy mock server.
Furthermore, `make test-all-offline` executes `test-tetragon-bats` and `test-tetragon-stream`.
These failures blocked offline validation runs.

## 3. Implementation Details

We update `test/tetragon-telemetry-stream.bats` setup.
When the deploy manifest `tetragon-agent-telemetry.yaml` is absent, the suite skips with an informative notification.
We update `scripts/test-tetragon-stream.sh` to check for manifest presence before launching builds.
If the manifest is missing, the script logs the retirement and exits with code 0.
In `Makefile`, we update `test-tetragon` to provide isolated Go environment variables for `collectors/ebpf` tests.
We conditionally skip the standalone `test/mocks` build when the manifest is missing.
The in-tree `collectors/ebpf` unit tests continue to run and pass all assertions.

## 4. Verification Record

- We verified `bats test/tetragon-telemetry-stream.bats` completes with 0 failures and 27 skips.
- We verified `./scripts/test-tetragon-stream.sh 1000` exits with status 0.
- We verified `make test-tetragon` runs all 10 in-tree eBPF tests with clean pass.
- We verified all 10 tests pass in `bats test/crkc-phase1-unified-stun.bats`.
- We verified all 6 tests pass in `bats test/terraform-dual-lane-registration.bats`.
- We verified all 10 tests pass in `bats d2-signalloom/test/bats-registry-coverage.bats`.
- We verified all 7 tests pass in `bats test/docs-index-sync.bats`.
- We verified `scripts/docs-lint.sh` passes on `docs/README.md` and this proposal.
