// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

// Package ebpf projects the stun-sentinel's own eBPF syscall trace onto the
// canonical endpoint_host observation layer consumed by Signal Fusion.
//
// # Role
//
// The sentinel eBPF engine is a telemetry PRODUCER only. It performs no
// enforcement: containment is owned by the stun-sentinel Tier 0 path (cgroup-v2
// freeze, TC packet drop) and the Flux Tier 1 path. This package only normalises
// and projects; it never signals, kills, or overrides.
//
// # Isolation
//
// This package is deliberately a leaf subpackage under collectors/. The parent
// `collectors` package MUST NOT import it — doing so creates an import cycle,
// because this package imports `collectors` for the shared Mode type. That
// invariant is asserted by TestAntiParentPackageDoesNotImportEbpf, and the
// collector is therefore registered from main.go.
//
// # Data path
//
//	stun-sentinel in-kernel eBPF (openat / openat2 / execve + kprobes/tracepoints)
//	  └─ normalised netebpf.InboundFlowEvent, posted to signal-ingest
//	     over POST /api/v1/observations
//	        └─ ProjectEndpoint      InboundFlowEvent → endpoint_host observation
//	           └─ IngestionSink → FrostDB
//
// The live in-collector subscriber to that stream is deferred (Collector returns
// ErrLiveDeferred in ModeLive); fixture mode replays the embedded endpoint corpus
// through the SAME ProjectEndpoint the production path uses.
//
// The InboundFlowEvent struct is NOT modified by this package. Sentinel syscall
// events reuse the existing schema; the SFDP-P2-4 contract and every sibling
// fixture depend on that struct being stable.
package ebpf
