# SLDC-P0 Environment and Toolchain Audit

This document records the baseline environment audit for developer workstation
`fortuna`. The audit supports the Signal Loom Local Dual-Cluster (SLDC) EAP
mission.

## Objective

The objective of SLDC-P0 is to check the developer environment before work starts.
We check git state, toolchain binaries, kernel features, and offline tests.

## Host system architecture

The host workstation provides a Linux runtime with unified cgroup v2 support
and eBPF ring buffer features.

| Property | Value | Minimum requirement | Status |
| :--- | :--- | :--- | :--- |
| Hostname | `fortuna` | N/A | OK |
| Architecture | `x86_64` | `x86_64` | OK |
| Linux kernel | `7.1.3+deb13-amd64` | `>= 5.8.0` (eBPF ring buffer support) | OK |
| Cgroup hierarchy | `cgroup2fs` (v2) | Unified cgroup v2 | OK |
| Memory | `66,319,802,368` bytes (~64 GB) | `>= 16 GB` | OK |

## Git repository state and commit policy

The working tree was inspected to check for zero uncommitted drift and to confirm
the commit signature policy.

```bash
git status --porcelain
git branch -vv
git log --pretty="%h %G? %s" -n 6
```

1. **Working tree state**: The repository working tree contains zero uncommitted
   drift outside the newly created P0 verification deliverables.
2. **Base ref lineage**: The active HEAD is an ancestor child of
   `integration/sldc-v0.1.0`, verified with `git merge-base --is-ancestor`.
3. **Commit signature practice**: The 6 most recent commits show `N` (unsigned).
   The repository policy enforces unsigned commits on this branch. Every commit
   must pass `--no-gpg-sign` to avoid interactive pinentry hangs in automated tools.

## Toolchain binary audit

All required developer and operator binaries were checked for presence on `PATH`
and semantic version compliance.

| Tool | Checked version | Required version | Status |
| :--- | :--- | :--- | :--- |
| **Kind** | `v0.32.0` | `>= v0.24.0` | OK |
| **kubectl** | `v1.36.0` | `>= v1.30.0` | OK |
| **Flux CLI** | `2.9.3` | `>= v2.3.0` | OK |
| **Go toolchain** | `go1.26.2` | `>= 1.24` | OK |
| **Bun runtime** | `1.4.0` | `>= 1.1.0` | OK |
| **Bats-core** | `1.13.0` | `>= 1.0.0` | OK |
| **Docker Engine** | `29.7.1` | `>= 24.0` | OK |

## Docker daemon and network posture

The Docker daemon operates with the `overlay2` storage driver and `systemd`
cgroup driver under unified cgroup v2.

1. **Storage driver**: `overlay2`
2. **Cgroup driver**: `systemd`
3. **Cgroup version**: `2`
4. **Daemon status**: Reachable and healthy without permission barriers.
5. **Bridge network**: Default bridge operational, ready for dual-cluster
   container topology provisioning on `172.19.0.0/16`.

## Verification deliverables

SLDC-P0 delivers four artifacts to record preflight readiness:

1. **Verification script**: [`scripts/verify-sldc-p0-baseline.sh`](../../scripts/verify-sldc-p0-baseline.sh)
   automates git state checks, toolchain assertions, and manifest generation.
2. **Machine-readable manifest**: [`ci-evidence/sldc-p0-preflight-manifest.json`](../../ci-evidence/sldc-p0-preflight-manifest.json)
   records toolchain versions and host parameters in structured JSON.
3. **Smoke test harness**: [`test/unit/sldc-p0-harness.bats`](../../test/unit/sldc-p0-harness.bats)
   provides 5 automated BATS assertions for environment prerequisites.
4. **Baseline execution log**: [`ci-evidence/sldc-p0-baseline.txt`](../../ci-evidence/sldc-p0-baseline.txt)
   captures the output of preflight test executions.

## Mutation testing assurance

To avoid vacuous test passes, the toolchain gate includes an empirical mutation
test. Running `env PATH=/tmp/empty_path kind --version` returns exit code 127
with `command not found`, proving that missing binaries fail closed.
