# Proposal — BATS Test Go Cache Isolation and Dashboard TypeScript Alignment (2026-Q4)

- **Author:** Andrew Martin
- **Date:** 2026-10-13
- **Status:** Proposed
- **Tag:** BATSGOCACHEDASHBOARDTS

## 1. Problem Statement

Multiple test suites across the repository fail when executed in non-root or sandboxed runner environments.
When the environment exports a read-only Go path, tests invoking Go subcommands encounter permission errors.
The Go checksum database verification fails because the default directory cannot be opened.
In addition, the dashboard build fails during TypeScript compilation.
Missing properties on kernel telemetry types cause type errors during page compilation.
The connector client test asserts an obsolete property name rather than the valid field defined in the connector interface.

## 2. Root Cause Analysis

In sandbox runners and developer workstations, the default Go path can point to a root-owned directory.
When tests invoke `go test` without isolated directory variables, Go attempts writes to this protected hierarchy.
The checksum client attempts to open the default checksum database directory and returns permission denied.
Test suites like `workspace-identity-streaming.bats` and `software-factory-governance.bats` lacked explicit path remapping.
Similarly, `sltm-probe-apikey.bats` only checked for unset Go paths rather than protected paths.
In the frontend dashboard, `SentinelKernelTelemetry` in `src/types/api.ts` omitted `cgroup_frozen` and `tc_drop_active`.
These properties were referenced in `AgentActivityTab.tsx` and declared in `src/data/agentDiscovery.ts`.
Finally, `connectorsClient.test.ts` asserted `auth_ok` instead of the typed `valid` property.

## 3. Proposed Hardening

First, update test suite setup functions to detect read-only Go paths.
When the Go path points to a protected hierarchy, remap it to a temporary path.
Export isolated cache paths and disable external checksum database network checks.
Second, update `fair-api-parity.bats` to match dynamic client fixture route counts.
Gate durable port-forward checks on whether the background service is running on the host.
Third, declare `cgroup_frozen` and `tc_drop_active` on `SentinelKernelTelemetry` in `src/types/api.ts`.
Fourth, align `connectorsClient.test.ts` to assert the canonical `valid` boolean field.

## 4. Verification Plan

Verify all updated BATS suites pass cleanly without permission errors.
Run `bun run build` in `d2-signalloom/apps/dashboard-signalloom` to verify zero TypeScript errors.
Run `scripts/netebpf-p2-preflight.sh` to confirm full pass across all four checks.
Verify documentation links and index synchronization via `bats test/docs-index-sync.bats`.
Run `scripts/docs-lint.sh` to ensure compliance with documentation prose rules.
