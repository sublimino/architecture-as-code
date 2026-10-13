# Proposal — Demo Agent Autoclaim Multi-Tenant Pod Discovery Alignment (2026-Q4)

- **Author:** Andrew Martin
- **Date:** 2026-10-13
- **Status:** Proposed
- **Tag:** AUTOCLAIMTENANT

## 1. Problem Statement

The Signal Loom agent auto-claim demonstration script automates workload discovery, Dex credential acquisition, and SPIFFE-authenticated agent registration.
Recent tenant-isolation hardening added strict tenant matching on discovered Kubernetes pods during default runs.
Consequently, offline BATS tests simulating Kubernetes pod discovery failed because stub fixtures omitted tenant annotations.
The runner terminated before evaluating governance controls because no matching workloads survived tenant filtering.

## 2. Root Cause Analysis

In commit 362532b7, `scripts/demo-agent-autoclaim.sh` introduced tenant-aware workload filtering.
When running without an explicit workload flag, the script matches candidate pods against the configured demonstration tenant.
The default demonstration tenant is configured as tenant-demo.
However, the stubbed kubectl responses in `test/demo-agent-autoclaim.bats` provided metadata without tenant labels.
As a result, the jq selector filtered out all candidate workloads.
The execution halted with an error indicating no unclaimed agent was discovered.
This caused downstream tests asserting initial governance controls and complete claim flows to fail prematurely.

## 3. Proposed Hardening

First, align the fake kubectl pod fixtures in `test/demo-agent-autoclaim.bats` with realistic production agent deployments.
Add the `signalloom.ai/tenant` label with value `tenant-demo` to the stubbed pod items.
This ensures default discovery accurately mirrors Kubernetes manifests deployed across the platform.
Second, verify that both unclaimed zero-control edge cases and complete seven-step governance workflows pass cleanly.
Third, validate that workload-specific overrides continue to select explicit targets independent of tenant defaults.

## 4. Verification Plan

Run `bats test/demo-agent-autoclaim.bats` to confirm all eight unit tests pass.
Verify related lifecycle and honesty suites via `bats test/demo-lifecycle.bats test/demo-mission-honesty.bats`.
Confirm documentation index synchronization via `bats test/docs-index-sync.bats`.
Execute `scripts/docs-lint.sh` to validate style conformance.
Confirm clean static checks with `scripts/lint-pipefail-grep-q.sh` and `scripts/check-vacuous-assertions.sh`.
