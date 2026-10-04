// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 ControlPlane Security Authors

// Package policy is the two-stage observation-policy pipeline that runs inside
// signal-ingest (SLAWS v2 §3, D2, D3, D5).
//
// # Where it sits
//
// Stage 1 runs at the shared collectors.IngestionSink, so every collector and
// the HTTP ingest path are covered and nothing bypasses it. The ordering is the
// architectural constitution's "store first, decide second": the observation
// reaches the inner sink BEFORE any rule is evaluated, and no evaluator outcome
// can fail, delay or alter the write.
//
//	observation ──► inner sink (store) ──► stage 1: CEL predicate per observation
//	                                           │ Finding
//	                                           ▼
//	                                       inner sink (source=policy_finding)
//	                                           │
//	                                           ▼
//	                                       stage 2: windowed counters over findings
//	                                           │ Decision
//	                                           ▼
//	                                       inner sink (source=policy_decision) ──► alert
//
// # What this package may not do
//
//   - It may not read the store on the hot path. Warm-up (Windows.Warm) and
//     replay are the only readers; sink_test.go's spyStore turns any other
//     QueryRange into a test failure (ISC-57).
//   - It may not return an evaluator error to the writer. A broken bundle
//     degrades detection; it must never degrade ingest (ISC-46).
//   - It may not call time.Now() for anything that lands in a finding or a
//     decision. Every timestamp comes from an observation (pkg/obscel
//     determinism contract). Metrics and HTTP timeouts are the only clock
//     readers in this package.
//   - It touches nothing in the customer account in any mode, enforce included
//     (D5). Mode changes which decisions alert, never what is acted upon.
//
// # Findings and decisions are observations
//
// Both stages write their output back through the same sink as
// model.Observation with Source=obscel.SourceFinding / SourceDecision (D3), so
// there is one store, one schema, one retention reaper and one replay path. The
// label set on each is closed and documented on findingObservation and
// decisionObservation; a finding does NOT carry the source observation's own
// labels, which is why a window keyed on a labels.<key> dimension is not
// recoverable by warm-up (documented on Windows.Warm).
//
// # Re-entry
//
// Stage 1 is guarded on Source: a policy_finding or policy_decision handed back
// to the sink is stored and never evaluated. Without that guard a bundle whose
// rule can match a finding recurses without bound.
package policy
