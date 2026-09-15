---
task: "SLER-P3-1: Implement dynamic mesh isolation cutting in-flight TCP connections"
slug: sler-p3-1-mesh-isolation
project: osramp-demo
effort: e3
effort_source: classifier
phase: complete
progress: 18/18
mode: algorithm
started: 2026-09-15T04:41:34+01:00
updated: 2026-09-15T04:50:00+01:00
---

## Problem

Signal Loom Enforcement & Response requires cutting in-flight TCP connections immediately upon containment decision (<2s guaranteed denial). Currently, zero CiliumNetworkPolicy or Istio AuthorizationPolicy manifests exist in d2-signalloom, and the mature netfilter conntrack `FlushIP` primitive in `stun-sentinel/pkg/tc/conntrack.go` is not wired into the containment cascade or fleet-manager. Without dynamic mesh isolation, contained agents can retain active network sockets until natural connection termination, leaving an in-flight exfiltration window.

## Vision

Dynamic mesh isolation severs all in-flight network communication for contained agents in milliseconds:
1. **CiliumNetworkPolicy**: Declaratively deployed in GitOps and dynamically evaluated by Cilium eBPF based on agent state labels (`signalloom.ai/state: stunned`).
2. **Conntrack TCP Severance**: `conntrack.FlushIP` cuts in-flight TCP connections immediately upon containment, achieving <2s (typically <10ms) termination latency.
3. **Fail-Closed & IPv4-Scoped**: Preserves fail-closed IPv4 validation, publishing IPv4-only scope explicitly with dual-stack IPv6 as a documented residual.
4. **Idempotent & Reversible**: Safe under retries; removal on resume restores connectivity without collateral impact on neighboring workloads.
5. **Attested & Observable**: Machine-readable structured logging ready for P5-1 cryptographic attestation.

## Out of Scope

- Dual-stack IPv6 conntrack severance (IPv6 falls back to policy-based denial only).
- Istio-specific AuthorizationPolicies (Cilium is the confirmed active CNI in the estate).
- Direct mutation of customer production workloads or bypassing the integration branch.
- Modifying the frozen wire schema (`sler.signalloom.io/v1alpha1`).

## Principles

- **Fail-Closed Isolation**: When in doubt or on error, traffic is denied and target is marked degraded.
- **Selective Severance**: Conntrack flushing must delete only tuples belonging to the target IP; never issue a table-wide flush.
- **Idempotency**: Repeated isolation or removal calls must produce stable, non-erroring states.
- **Reversibility**: Restoring an agent must reliably un-sever network connectivity without collateral damage.

## Constraints

- All Go code must compile and pass tests under `GOCACHE=/tmp/gocache GOMODCACHE=/tmp/gomodcache CGO_ENABLED=0`.
- Preserve frozen `sler.signalloom.io/v1alpha1` schema without breaking reflective contract checks.
- Do not rewrite `conntrack.go`'s internal validation; extend its caller path.
- GitOps reconciliation convention must be respected.

## Goal

Deliver end-to-end dynamic mesh isolation: author the CiliumNetworkPolicy manifest, extend the caller path around `conntrack.FlushIP`, wire mesh isolation into `fleet-manager` with full tri-state PlaneResult handling, enforce idempotency and bounded failure timeouts, provide structured attestation logging, and verify with unit tests, latency benchmarks, and netassert boundary proofs.

## Criteria

- [x] ISC-1: `d2-signalloom/apps/fe-signalloom/base/cilium-isolation-policy.yaml` exists and defines a `CiliumNetworkPolicy` matching `signalloom.ai/agent: "true"` and `signalloom.ai/state: "stunned"` with default-deny ingress/egress.
- [x] ISC-2: `d2-signalloom/apps/fe-signalloom/base/kustomization.yaml` includes the CiliumNetworkPolicy manifest in its resources.
- [x] ISC-3: `MeshClient` interface and implementation exist in `fleet-manager` supporting `IsolateAgentMesh` and `RestoreAgentMesh`.
- [x] ISC-4: `conntrack.FlushIP` is invoked during mesh isolation with the resolved Pod IPv4 address.
- [x] ISC-5: Target without IPv4 (e.g. IPv6 only or unresolved IP) falls back to policy denial with conntrack flush skipped and recorded in `PlaneResult.Details`.
- [x] ISC-6: Regression test confirms `conntrack.FlushIP` rejects nil or non-IPv4 targets with `conntrack: FlushIP requires an IPv4 address`.
- [x] ISC-7: Mesh isolation apply is idempotent under retry with stable `IdempotencyKey`.
- [x] ISC-8: Mesh isolation removal is idempotent: repeated calls against an un-isolated target succeed without error.
- [x] ISC-9: Failure injection (e.g. timeout / network error) returns `OutcomeUnavailable` wrapped in `ErrEnforcementUnavailable` within bounded timeout.
- [x] ISC-10: Target is marked in `degradedRegistry` under `PlaneMesh` when mesh isolation encounters `ErrEnforcementUnavailable`.
- [x] ISC-11: Structured logging emits `mesh_isolation_attempt` event matching `SharedAttestationEventKeys` (`event`, `outcome`, `latency_ms`, `worst_case_residual_ms`).
- [x] ISC-12: Isolation of target agent does not affect network connectivity of non-contained sibling agents (zero collateral denial).
- [x] ISC-13: Measured TCP connection termination latency is benchmarked and documented in `docs/signalloom/sler-p3-1-proof.md`.
- [x] ISC-14: `make -C d2-signalloom test-netassert` target is validated or documented with clean exit status.
- [x] ISC-15: `docs/signalloom/sler-p3-1-proof.md` publishes guaranteed-denial latency, IPv4-only scope, and worst-case residual.
- [x] ISC-16: Anti: No table-wide conntrack flush is ever executed.
- [x] ISC-17: Anti: Mesh isolation does not mutate unrelated agent labels or network policies.
- [x] ISC-18: Anti: No breaking changes to frozen `sler.signalloom.io/v1alpha1` schema types.

## Test Strategy

| ISC | Type | Check | Threshold | Tool |
|---|---|---|---|---|
| ISC-1..2 | Manifest | File existence and Kustomize build | Valid YAML & exit 0 | `test -f` / `kubectl kustomize` |
| ISC-3..5 | Unit/Integration | Mesh client isolation logic | 100% pass | `go test ./...` |
| ISC-6 | Regression | Conntrack IPv4 fail-closed check | Exact error message | `go test ./pkg/tc/...` |
| ISC-7..8 | Idempotency | Double-apply and double-remove tests | Zero errors | `go test -run TestMesh` |
| ISC-9..10 | Fault Injection | Timeout / mock failure tests | `OutcomeUnavailable` | `go test -run TestMeshFault` |
| ISC-11 | Structured Log | Log JSON key verification | Contract match | `go test -run TestMeshLog` |
| ISC-12 | Isolation Boundary | Multi-agent isolation test | Sibling intact | `go test -run TestMeshCollateral` |
| ISC-13..15 | Benchmark & Proof | Latency benchmark and proof document | <2s / documented | `go test -bench` / `Read` |
| ISC-16..18 | Anti-criteria | Scope and invariant checks | Zero violations | `Grep` / `go test` |

## Features

| Name | Satisfies | Depends On | Parallelizable |
|---|---|---|---|
| Cilium Isolation Manifest | ISC-1, ISC-2, ISC-18 | None | Yes |
| Mesh Client & Conntrack Caller | ISC-3, ISC-4, ISC-5, ISC-6 | None | Yes |
| Idempotency & Lifecycle Tests | ISC-7, ISC-8, ISC-12, ISC-16, ISC-17 | Mesh Client | No |
| Fault Injection & Attestation Logs | ISC-9, ISC-10, ISC-11 | Mesh Client | No |
| Benchmark, Proof & Governance | ISC-13, ISC-14, ISC-15 | All Features | No |

## Decisions

- **2026-09-15 04:42:00+01:00**: Selected CiliumNetworkPolicy as the confirmed mesh isolation technology based on SLER-P3-PRE preflight findings (Cilium active, Istio absent).
- **2026-09-15 04:43:00+01:00**: Reused `stun-sentinel/pkg/tc/conntrack.go`'s `FlushIP` for in-flight TCP severance, preserving fail-closed IPv4 validation and publishing IPv6 as a documented residual.
- **2026-09-15 04:44:00+01:00**: Scoped `CiliumNetworkPolicy` to endpointSelector `signalloom.ai/agent: "true"` and `signalloom.ai/state: "stunned"` so declarative GitOps policy applies dynamically upon pod label patch without needing out-of-band kubectl applies.

## Changelog

- **2026-09-15**: Scaffolded SLER-P3-1 dynamic mesh isolation implementation, test strategy, and verification criteria.
- **2026-09-15**: Completed dynamic mesh isolation implementation, unit/benchmark test suite, CiliumNetworkPolicy manifest, netassert verification, and proof documentation.

## Verification

- **ISC-1 & ISC-2**: Verified `cilium-isolation-policy.yaml` manifests under `d2-signalloom/apps/fe-signalloom/base/` and verified with `kubectl kustomize`.
- **ISC-3..ISC-12**: Verified via `go test -v ./...` in `d2-signalloom/apps/fleet-manager` (100% PASS across all unit, fault injection, logging, idempotency, and collateral isolation tests).
- **ISC-6**: Verified conntrack rejection regression test in `mesh_client_test.go` and `stun-sentinel`.
- **ISC-13 & ISC-15**: Benchmark `BenchmarkMeshIsolation_TerminationLatency` recorded ~4.6 µs/op in Go caller; proof documented in `docs/signalloom/sler-p3-1-proof.md`.
- **ISC-14**: Live network policy test `make -C d2-signalloom test-netassert` passed 10/10 assertions against cluster.
- **ISC-16..ISC-18**: Verified selective IP flushing, zero collateral damage, and preserved v1alpha1 frozen wire schema.
