// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

// Package ebpf ingests Tetragon runtime telemetry and normalises it into the
// canonical netebpf.InboundFlowEvent schema consumed by Signal Fusion.
//
// # Role
//
// Tetragon is a telemetry PRODUCER only (CRKC-P1-4). It performs no enforcement:
// containment is owned by the stun-sentinel Tier 0 path (cgroup-v2 freeze, TC
// packet drop) and the Flux Tier 1 path. The TracingPolicy manifests in
// d2-signalloom/deploy/tetragon-agent-telemetry.yaml carry no Sigkill, Override,
// Signal or NotifyEnforcer action, and test/tetragon-telemetry-stream.bats fails
// the build if one is introduced.
//
// # Isolation
//
// This package is deliberately a leaf subpackage under collectors/. The parent
// `collectors` package MUST NOT import it — doing so creates an import cycle,
// because this package imports `collectors` for the shared Mode type. That
// invariant is asserted by TestParentPackageDoesNotImportEbpf.
//
// # Data path
//
//	Tetragon agent
//	  └─ gRPC FineGuidanceSensors/GetEvents  (unix:///var/run/cilium/tetragon/tetragon.sock)
//	     or NDJSON export (tetragon.log)
//	        └─ StreamClient          reconnects with capped exponential backoff
//	           └─ RingBuffer         bounded, counted drop policy, no unbounded queue
//	              └─ Normalizer      Tetragon event → netebpf.InboundFlowEvent
//	                 └─ FlowProcessor (netebpf.LiveNetworkEgressCollector)
//	                    └─ IngestionSink → FrostDB
//
// The InboundFlowEvent struct is NOT modified by this package. Tetragon events
// normalise into the existing schema; the SFDP-P2-4 contract and every sibling
// fixture depend on that struct being stable.
package ebpf
