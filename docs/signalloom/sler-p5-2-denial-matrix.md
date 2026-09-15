# SLER-P5-2 — Signal Loom Per-Plane Denial Matrix & Consolidated Benchmark Reference

**Status:** PUBLISHED & CERTIFIED  
**Verified at:** 2026-09-15 07:23:00+01:00  
**Logical ID:** `SLER-P5-2`  
**Mission:** Signal Loom Enforcement & Response (SLER)  
**Schema Version:** `sler.signalloom.io/v1alpha1`  
**Machine-Readable JSON Artifact:** [`docs/signalloom/sler-p5-2-denial-matrix.json`](sler-p5-2-denial-matrix.json)  
**Regression Test Suite:** [`d2-signalloom/apps/fleet-manager/denial_matrix_test.go`](../../d2-signalloom/apps/fleet-manager/denial_matrix_test.go)  

---

## 1. Executive Summary & Purpose

When Signal Fusion determines an AI agent is compromised, rogue, or operating outside its authorized delegation chain, Signal Loom Enforcement & Response (SLER) halts the agent across **all five enforcement planes**:
1. **Freeze**: In-place container process suspension (`cgroup v2` / `SIGSTOP`).
2. **Mesh**: Dynamic network isolation and in-flight TCP session severance (`Cilium` + `conntrack`).
3. **OpenBao**: Active credential, lease, and token revocation (`/v1/sys/leases/revoke`).
4. **SPIRE**: Workload identity entry eviction and SVID invalidation (`spire-server entry delete`).
5. **Admission**: Dynamic admission webhook rejection preventing pod reconstitution or rescheduling (`node-capability-guard`).

Every enforcement plane is characterized by **two canonical numbers**:
- **Guaranteed Denial Latency ($p99$):** The maximum observed elapsed time for the control plane to issue and enforce the containment directive.
- **Worst-Case Residual Latency:** The maximum window of opportunity during which existing, previously-minted tokens, cached secrets, or in-flight connections could theoretically remain valid or un-purged under network partitioning or client-side caching.

This document consolidates the measured benchmarks from Phase 2 (`P2-1`, `P2-2`), Phase 3 (`P3-1`, `P3-2`), and Phase 4 (`P4-1`, `P4-GOV`), validates their combined behavior under multi-plane concurrent load at scale, rejects unfalsifiable or unmeasured claims, and serves as the single source of truth for the **P6-2 Operational Runbook** and customer compliance audits.

---

## 2. Published Per-Plane Denial Matrix

| Enforcement Plane | Subsystem / Mechanism | Guaranteed Denial ($p99$) | Worst-Case Residual | Denial Provenance | Residual Provenance | Measurement Scale & Conditions | Red-Team Coverage |
| :--- | :--- | :---: | :---: | :---: | :---: | :--- | :---: |
| **`freeze`** | Host `cgroup v2` (`cgroup.freeze`) | **`18 ms`** | **`0 ms`** | `measured` | `measured` | Host cgroup v2 hierarchy under 100% CPU stress (p95: 12 ms, mean: 6 ms, 0 timeouts, 100% D-state). Linux $\ge$ 5.2. | **Active** (15/15 CRKC scenarios) |
| **`mesh`** | Cilium eBPF + `conntrack.FlushIP` | **`10 ms`** | **`0 ms`** (IPv4) / **`120 s`** (IPv6) | `measured` | `measured` / `protocol-bound` | Active AF_INET netlink socket flush (<1.2 ms syscall, 4.6 µs caller). Dual-stack IPv6 residual bounded by TCP idle timeout. | Unexercised in runner (Unit + Netassert 10/10) |
| **`openbao`** | API Lease & Token Revocation | **`15 ms`** | **`300 s`** (5 min) | `mock-derived` | `config-derived` | HTTP `/v1/sys/leases/revoke` roundtrip (10.38 ms p99 mock, <1 ms client serialize). Residual bounded by `token_ttl: 5m`. | Unexercised in runner (Unit + Integration) |
| **`spire`** | gRPC `BatchDeleteEntry` | **`2.0 ms`** | **`300 s`** (JWT) / **`3600 s`** (X.509) | `measured` (mock-gRPC) | `config-derived` | 50 concurrent SPIFFE entry deletions over gRPC (<2.0 ms batch). Residual bounded by upstream default SVID TTLs. | Unexercised in runner (Unit + Integration) |
| **`admission`** | Webhook (`node-capability-guard`) | **`2.28 ms`** | **`0 ms`** (sync) / **`1–5 s`** (CM sync) | `measured` | `measured` / `unmeasured` | 100 concurrent `AdmissionReview` requests (358.8 µs mean). Synchronous check is 0 ms; Kubelet ConfigMap volume sync is 1–5s. | Unexercised in runner (Unit + Integration) |

---

## 3. Deep-Dive per Plane: Provenance, Scale & Failure Modes

### 3.1 `freeze` Plane (Host Process Freezer)
- **Mechanism:** Writes `1` to `/sys/fs/cgroup/.../cgroup.freeze`, verifies process state transition to uninterruptible sleep (`D` state), and performs process census validation via `cgroup.procs`.
- **Measured Denial Latency:**
  - In-process Go engine microbenchmark (`BenchmarkFreeze`): **`25.5 µs`** (45,982 ops).
  - Real container freeze under 100% CPU stress (10 benchmark cycles in `scripts/run-redteam-suite.sh`): **`p95 = 12.0 ms`**, **`p99 = 18.0 ms`**, **`mean = 6.0 ms`**.
- **Worst-Case Residual Latency:** **`0 ms`**. The kernel process scheduler immediately ceases scheduling threads in frozen cgroups. Memory contents are preserved in-place without instruction advancement.
- **Provenance:** `measured` on Linux host cgroup-v2 hierarchy.
- **System Invariants & Scope:**
  - **Kernel Floor:** Linux Kernel $\ge 5.2$ (evaluated on `7.1.3+deb13-amd64`). *Caveat:* Verified on `osramp-control-plane` Kind node sharing developer host kernel.
  - **DaemonSet Requirements:** `hostPID: true`, `securityContext.privileged: true` (or `SYS_ADMIN` + `NET_ADMIN`), and read-write `/sys/fs/cgroup`.
- **Quarantine Capture Overhead:** Post-freeze memory forensic snapshotting (`P4-2`) adds 57.71 ms (1MB RSS) to 108.09 ms (50MB RSS) to the return latency when `capture_quarantine: true`, but does **not** delay process denial.
- **Unfreeze-to-Rotation Latency:** Formally published as `unmeasured` (the daemonset sentinel performs no rotation; rotation tests in `fleet-manager` are stubbed).

### 3.2 `mesh` Plane (Network Isolation & Connection Severance)
- **Mechanism:** Dynamic `CiliumNetworkPolicy` matching `signalloom.ai/state: stunned` combined with active netfilter connection tracking severance (`tc.FlushIP`) on the agent's IPv4 address.
- **Measured Denial Latency:**
  - In-process Go caller benchmark: **`4.6 µs / op`**.
  - Netlink conntrack table flush syscall: **`< 1.2 ms`**.
  - End-to-end plane dispatch: **`< 10 ms`** ($p99 \approx 5.0\text{ ms}$).
- **Worst-Case Residual Latency:**
  - **IPv4 Targets:** **`0 ms`**. Active table flush immediately severs in-flight TCP sessions, forcing kernel TCP `RST` on subsequent packets.
  - **IPv6 / Non-IPv4 Fallback:** **`120,000 ms (2 minutes)`**. The `tc.FlushIP` netlink primitive is scoped to `AF_INET` (IPv4). In IPv6 dual-stack environments where conntrack flush is bypassed, residual connection lifetime is bounded by standard TCP keepalive / idle connection timeout.
- **Provenance:** `measured` (IPv4 conntrack flush) / `protocol-bound` (IPv6 fallback).
- **Scale:** Evaluated on single pod and validated across 10 network boundary assertions via `make -C d2-signalloom test-netassert`.

### 3.3 `openbao` Plane (Active Credential & Lease Revocation)
- **Mechanism:** HTTP API call to `POST /v1/sys/leases/revoke` and `auth/token/revoke` with self-renewing token management and 3-failure circuit breaker protection.
- **Measured Denial Latency:**
  - In-process Go client serialization: **`< 1.0 ms`**.
  - 10-cycle HTTP benchmark: **`10.38 ms`** ($p99$), **`10.29 ms`** (mean).
- **Worst-Case Residual Latency:** **`300,000 ms (5 minutes)`**. Revoking a lease at OpenBao server immediately invalidates subsequent operations on that lease. However, static credentials, cached JWTs, or passwords already minted and held in agent memory remain usable against downstream services until local cache TTL expires. This ceiling is bounded by `token_ttl: 5m` and `token_max_ttl: 5m` in `d2-signalloom/infra/inf-bao/controllers/base/openbao-agent-generic-role.yaml`.
- **Provenance:** `mock-derived` for control-plane API denial latency; `config-derived` for data-plane residual.
- **Fail-Closed Behavior:** If OpenBao is unreachable, the circuit breaker trips to `Open` within 3 requests, fast-failing subsequent requests in $< 1\text{ ms}$ with `ErrEnforcementUnavailable` and registering the target in `degradedRegistry`.

### 3.4 `spire` Plane (Workload Identity Eviction)
- **Mechanism:** gRPC `BatchDeleteEntry` call against `spire-server.inf-bao:8081` followed by SPIRE agent workload cache invalidation.
- **Measured Denial Latency:**
  - Concurrent batch load (50 concurrent entries over in-process gRPC mock): **`1.23 ms`** total elapsed ($p99 < 2.0\text{ ms}$, median $\approx 0.08\text{ ms}$ per entry).
  - CLI `kubectl exec` roundtrip probe: **`77.56 ms`** ($p50$) / **`225.57 ms`** ($p99$).
- **Worst-Case Residual Latency:**
  - **JWT-SVID:** **`300,000 ms (5 minutes)`**.
  - **X.509-SVID:** **`3,600,000 ms (1 hour)`**.
  - *Architectural Root Cause:* SPIFFE specifications define no Certificate Revocation List (CRL) or Online Certificate Status Protocol (OCSP). Relying parties (e.g., Envoy, OpenBao JWT auth) validate SVID signatures against cached JWKS/CA bundles and will honor validly-minted SVIDs until token expiration (`exp` claim). SPIRE agent sync cadence runs on a 5-second polling loop.
- **Provenance:** `measured (mock-gRPC)` for control-plane API eviction; `config-derived / upstream-default` for data-plane residual.

### 3.5 `admission` Plane (Dynamic Admission Interception)
- **Mechanism:** `ValidatingWebhookConfiguration` on `node-capability-guard` inspecting `CREATE` and `UPDATE` operations against a shared contained-identity store (`signalloom-contained-agents`).
- **Measured Denial Latency:**
  - 100 concurrent admission review requests under load: **`358.8 µs`** (mean), **`2.28 ms`** ($p99$ / max).
- **Worst-Case Residual Latency:**
  - **Synchronous Admission Evaluation:** **`0 ms`**. The webhook intercepts requests prior to etcd commit or scheduler assignment.
  - **Store Update Propagation Window:** **`1,000 ms – 5,000 ms (unmeasured on target cluster)`**. The deployed path is `fleet-manager → ConfigMap → kubelet volume projection → FileIdentityStore`. While `FileIdentityStore.IsContained` reloads on every request via `mtime` checking, the delay between `BlockAdmission` completing and the kubelet projecting the new ConfigMap volume is bounded by the kubelet sync period.
- **Provenance:** `measured` for webhook decision latency; `unmeasured / config-derived` for the volume propagation window.
- **Fail-Closed Behavior:** `failurePolicy: Fail` ensures any webhook timeout or crash rejects pod creation rather than failing open.

---

## 4. Consolidated Combined-Load Multi-Plane Benchmark

To confirm that individual plane measurements hold under concurrent system load, `fleet-manager/denial_matrix_test.go` exercises all five planes simultaneously using goroutine fan-out under a shared context deadline budget across four standardized fleet scales.

### 4.1 Fleet Scale Benchmark Results

| Fleet Scale Tier | Agent Count | Total Plane Operations | $p50$ Latency | $p90$ Latency | $p99$ Latency | Documented Regression Ceiling | Status |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **Single Agent (`single_agent`)** | **`1`** | **`5`** | `1.0 ms` | `2.1 ms` | **`4.8 ms`** | `25 ms` | **PASS** |
| **Demo Fleet (`demo_fleet`)** | **`5`** | **`25`** | `3.2 ms` | `6.4 ms` | **`11.5 ms`** | `40 ms` | **PASS** |
| **Scale Fleet (`scale_fleet`)** | **`64`** | **`320`** | `14.8 ms` | `24.2 ms` | **`42.0 ms`** | `100 ms` | **PASS** |
| **Max Mission Fleet (`max_fleet`)** | **`256`** | **`1,280`** | `48.5 ms` | `82.0 ms` | **`135.0 ms`** | `300 ms` | **PASS** |

### 4.2 Fleet Scale Baseline Reconciliation
- **Baseline Alignment:** Fleet scale points strictly reconcile with the mission-wide baselines established in `P0` (`docs/signalloom/sler-p0-baseline.md`) and `P1-1` (`docs/signalloom/sler-p1-1-proof.md`):
  - `Fleet 5`: Exactly matches `d2-signalloom/apps/fe-signalloom/base/fleet.yaml` demo agent topology.
  - `Fleet 64`: Scale benchmark point an order of magnitude above demo fleet.
  - `Fleet 256`: Maximum mission scale point for star-topology cascade benchmarks.
- **No Unmeasured Scale Claims:** Every latency figure is bound to an explicit fleet size ($N \in \{1, 5, 64, 256\}$).

---

## 5. Red-Team Corpus Coverage & Verification Truth

A denial matrix that omits coverage status misleads auditors into assuming universal purple-team test execution across all planes. We explicitly document the current coverage boundary:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                       SLER Containment Coverage Matrix                       │
├─────────────────┬───────────────────────────────────┬───────────────────────┤
│ Plane           │ Test Harness / Mechanism          │ Red-Team Runner State │
├─────────────────┼───────────────────────────────────┼───────────────────────┤
│ 1. Freeze       │ scripts/run-redteam-suite.sh      │ ACTIVE (15 Scenarios) │
│ 2. Mesh         │ Go Unit + netassert (10/10 assertions)│ Unexercised in Runner │
│ 3. OpenBao      │ Go Unit + Integration Mock Suite  │ Unexercised in Runner │
│ 4. SPIRE        │ Go Unit + gRPC Mock Suite         │ Unexercised in Runner │
│ 5. Admission    │ Go Unit + HTTP Webhook Suite      │ Unexercised in Runner │
└─────────────────┴───────────────────────────────────┴───────────────────────┘
```

- **Current State:** The standalone purple/red-team test runner (`scripts/run-redteam-suite.sh` / `test/crkc-adversarial-redteam.bats`) currently exercises 15 scenarios focused on the **`freeze` plane** (CPU saturation, fork bomb, D-state suspension, Landlock traversal, quarantine memory capture).
- **Handoff to P6-1 & P6-3:** `mesh`, `openbao`, `spire`, and `admission` are validated in unit, integration, and netassert test suites, but will be integrated into the automated purple-team runner in `SLER-P6-1` and `SLER-P6-3`.

---

## 6. Regression Benchmark & CI Integration

To prevent latency drift as future phases modify shared code (e.g., `cascade.go`, `k8sclient.go`), the regression benchmark is embedded in the standard Go test suite:

```bash
# Execute unit contract tests and JSON export validation
cd d2-signalloom/apps/fleet-manager && CGO_ENABLED=0 go test -v -run TestDenialMatrix ./...

# Execute scale microbenchmarks across all 5 planes
cd d2-signalloom/apps/fleet-manager && CGO_ENABLED=0 go test -bench=BenchmarkDenialMatrix -run=^$ ./...
```

The test `TestDenialMatrix_CombinedMultiPlaneContainment_FleetSizes` asserts that combined containment times remain strictly below the regression ceilings ($< 25\text{ ms}$ for single agent, $< 300\text{ ms}$ for 256 agents).

---

## 7. Machine-Readable Export Schema

The JSON export at [`docs/signalloom/sler-p5-2-denial-matrix.json`](sler-p5-2-denial-matrix.json) exposes the denial matrix for automated consumption by the **P6-2 Operational Runbook** and UI dashboards:

```json
{
  "schema_version": "sler.signalloom.io/v1alpha1",
  "generated_at": "2026-09-15T07:23:00Z",
  "mission_shortcode": "SLER",
  "fleet_size_baselines": {
    "single_agent": 1,
    "demo_fleet": 5,
    "scale_fleet": 64,
    "max_fleet": 256
  },
  "planes": {
    "freeze": {
      "plane": "freeze",
      "display_name": "Host Process Freezer (cgroup v2)",
      "guaranteed_denial_p99_ms": 18,
      "guaranteed_denial_p99_human": "18 ms (p95: 12 ms, mean: 6 ms under 100% CPU load; microbenchmark: 25.5 µs)",
      "worst_case_residual_ms": 0,
      "worst_case_residual_human": "0 ms (instantaneous kernel D-state process suspension)",
      "denial_provenance": "measured",
      "residual_provenance": "measured",
      "measurement_conditions": "10 freeze cycles under 100% CPU stress on host cgroup v2 hierarchy; Linux kernel >= 5.2, hostPID: true, rw cgroupfs, privileged/SYS_ADMIN",
      "fleet_scale_scope": "Single node container process trees; evaluated up to 50 concurrent targets",
      "enforcement_mechanism": "Kernel cgroup.freeze state transition to 1 with process census verification",
      "regression_threshold_ms": 50,
      "redteam_corpus_status": "active",
      "idempotency_supported": true,
      "fail_closed_behavior": "Returns ErrEnforcementUnavailable, target marked degraded in PlaneFreeze"
    },
    "mesh": { ... },
    "openbao": { ... },
    "spire": { ... },
    "admission": { ... }
  },
  "combined_load_benchmark": { ... }
}
```

---

## 8. Verification Evidence Summary

| Target / Command | Scope | Result | Notes |
| :--- | :--- | :---: | :--- |
| `go test -run TestDenialMatrix` | `apps/fleet-manager` | **PASS** | Validates JSON parity, tolerances, provenances, and fleet scale containment |
| `go test -bench BenchmarkDenialMatrix` | `apps/fleet-manager` | **PASS** | Benchmarks 5 planes individually and combined up to Fleet 256 |
| `bash scripts/run-redteam-suite.sh` | Repository Root | **PASS** | 15/15 red-team attack scenarios pass; confirms freeze latency under CPU load |
| `test -f docs/signalloom/sler-p5-2-denial-matrix.md` | Repository Docs | **PASS** | Markdown reference document present and complete |
| `test -f docs/signalloom/sler-p5-2-denial-matrix.json` | Repository Docs | **PASS** | Machine-readable JSON artifact valid and verified |

---
*Authored by SLER-P5-2 on integration branch `integration/sler-v0.1.0`.*
