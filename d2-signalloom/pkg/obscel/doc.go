// Package obscel is the single shared vocabulary and evaluator for Signal Loom
// observation policy (SLAWS v2 §4.1, D2, D3, D9).
//
// Dependency direction is fixed: both apps/signal-ingest and apps/policy-engine
// import this package; neither app imports the other. The CEL environment, the
// bundle format, the in-process Evaluator, and the canonical Finding/Decision
// types live here so stage 1 (per-observation predicates), stage 2 (windowed
// counters over findings), boot-time warm-up and regression replay are one code
// path.
//
// # Determinism contract (binding for every producer and for the replay oracle)
//
// Replay over the backlog must reproduce live output byte for byte under an
// explicit projection (see CanonicalFinding). To make that possible:
//
//   - Finding.ID is derived: sha256(tenant_id | rule_id | bundle_version | source observation id),
//     hex, never a random UUID.
//   - Finding.Timestamp is the source observation's Timestamp, never time.Now().
//   - Decision.ID is derived from tenant_id | rule_id | window key | the IDs of the
//     findings that crossed the threshold, in sorted order.
//   - Labels serialise in sorted key order.
//   - Rules evaluate in sorted rule ID order, never map order.
//   - Actor pseudonymisation uses the configured store key; a per-process salt is a defect.
//   - The replay comparison projects an allowlist of fields (CanonicalFinding);
//     store-assigned fields (ingest time, offsets) never take part.
//
// # Missing-key semantics
//
// `has(obs.labels.k)` on an absent key evaluates to false and never errors, so an
// unlabelled record cannot become a finding or a denial by accident.
package obscel
