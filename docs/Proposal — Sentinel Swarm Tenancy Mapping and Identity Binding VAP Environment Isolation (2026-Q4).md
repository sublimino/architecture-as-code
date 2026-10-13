# Proposal — Sentinel Swarm Tenancy Mapping and Identity Binding VAP Environment Isolation (2026-Q4)

- **Author:** Andrew Martin
- **Date:** 2026-10-13
- **Status:** Proposed
- **Tag:** SENTINELTENANCYVAP

## 1. Problem Statement

The Signal Loom sentinel attributes kernel and cgroup security observations using a static tenant map keyed by namespace and service account.
Recently, an enforced Kusari agent workload was added to the agent swarm under the demo tenant.
However, the sentinel configuration map omitted an entry for this newly introduced agent.
This caused swarm tenancy verification to fail during repository audits.
Concurrently, the ValidatingAdmissionPolicy offline test suite failed when executing Go CEL verification tests.
The test inherited a read-only global Go path without isolated cache directories, resulting in permission errors.

## 2. Root Cause Analysis

First, commits introducing `agent-nono-kusari` added its Kubernetes deployment and service account to the swarm directory.
The Sentinel Tenant Map in `d2-signalloom/infra/agent-swarm/signalloom-warden/configmap.yaml` was not updated to include the new service account.
Because `test/agent-swarm-tenancy.bats` verifies that every agent workload has an explicit mapping, the missing entry caused test failure.
Second, `test/agent-identity-binding-vap.bats` invoked `go test` without unsetting or overriding the ambient root-owned `GOPATH` environment variable.
Because `GOPATH` defaulted to `/usr/local/src/gocode`, the Go toolchain attempted to write checksum database cache entries into a protected directory.
This resulted in permission denied failures during hermetic offline test runs.

## 3. Proposed Hardening

First, add `fe-signalloom-agents/agent-nono-kusari=tenant-demo` to `SENTINEL_TENANT_MAP` in the sentinel configuration map.
This aligns runtime observation attribution with declared deployment tenant labels.
Second, configure isolated Go cache and path environment variables in `test/agent-identity-binding-vap.bats`.
Direct `GOPATH`, `GOCACHE`, and `GOMODCACHE` to user-writable temporary paths.
Prepend the Linuxbrew binary path so the verified Go compiler version runs reliably across offline environments.

## 4. Verification Plan

Run `bats test/agent-swarm-tenancy.bats` to confirm four out of four tenancy attribution tests pass.
Run `bats test/agent-identity-binding-vap.bats` to confirm seven out of seven admission policy and CEL tests pass.
Run `bats test/docs-index-sync.bats` and `scripts/docs-lint.sh` to confirm documentation index synchronisation and style compliance.
Run `scripts/lint-pipefail-grep-q.sh` and `scripts/check-vacuous-assertions.sh` to confirm zero regression across static analysis checks.
